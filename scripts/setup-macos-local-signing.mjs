import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdtempSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  isAppleDevelopmentIdentityName,
  localProductIdentity,
  localSigningConfigPath,
  localSigningKeychainPath,
  parseCodeSigningIdentities,
  selectLocalCodeSigningIdentity,
  signWithStableRequirement,
  verifyAppleSignature,
} from "./macos-local-signing.mjs";

const setupProbeIdentifier = `${localProductIdentity.bundleId}.setup`;
const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const bundledWwdrG3RelativePath = path.join(
  "SharedFrameworks",
  "DVTFoundation.framework",
  "Versions",
  "A",
  "Resources",
  "AppleWWDRCA-2030.cer",
);
const standardXcodeContentsPath = path.join(
  "/Applications",
  "Xcode.app",
  "Contents",
);
function combinedOutput(result) {
  return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = options.capture ? `\n${combinedOutput(result).trim()}` : "";
    throw new Error(
      `${path.basename(command)} ${args.join(" ")} failed with exit code ${result.status}${detail}`,
    );
  }
  return result;
}

export function xcodeContentsForDeveloperDirectory(developerDirectory) {
  const normalized = path.posix.resolve(developerDirectory);
  const contents = path.posix.dirname(normalized);
  const application = path.posix.dirname(contents);
  if (
    path.posix.basename(normalized) !== "Developer" ||
    path.posix.basename(contents) !== "Contents" ||
    !path.posix.basename(application).endsWith(".app")
  ) {
    return null;
  }
  return contents;
}

function selectedXcodeContentsPath() {
  const result = spawnSync("/usr/bin/xcode-select", ["-p"], {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: "pipe",
  });
  if (result.error || result.status !== 0) return null;
  const developerDirectory = result.stdout.trim();
  return developerDirectory
    ? xcodeContentsForDeveloperDirectory(developerDirectory)
    : null;
}

function resolveBundledWwdrG3Path() {
  const candidates = [selectedXcodeContentsPath(), standardXcodeContentsPath]
    .filter((candidate) => candidate !== null)
    .map((contents) => path.join(contents, bundledWwdrG3RelativePath));
  return candidates.find((candidate) => existsSync(candidate)) ?? null;
}

function requireMacos() {
  if (process.platform !== "darwin") {
    throw new Error(
      "local MetaWork code signing setup is only available on macOS",
    );
  }
}

function createSecureTemporaryDirectory() {
  const directory = mkdtempSync(path.join(tmpdir(), "metawork-local-signing-"));
  chmodSync(directory, 0o700);
  let removed = false;
  const cleanup = () => {
    if (removed) return;
    removed = true;
    rmSync(directory, { recursive: true, force: true });
  };
  const signalHandlers = new Map();
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    const handler = () => {
      cleanup();
      process.removeListener(signal, handler);
      process.kill(process.pid, signal);
    };
    signalHandlers.set(signal, handler);
    process.once(signal, handler);
  }
  process.once("exit", cleanup);
  return {
    directory,
    dispose() {
      process.removeListener("exit", cleanup);
      for (const [signal, handler] of signalHandlers) {
        process.removeListener(signal, handler);
      }
      cleanup();
    },
  };
}

function identityOutput(policy) {
  const result = run(
    "/usr/bin/security",
    ["find-identity", "-v", "-p", policy, localSigningKeychainPath()],
    { capture: true },
  );
  return combinedOutput(result);
}

function appleDevelopmentCandidates(output) {
  return parseCodeSigningIdentities(output).filter(({ name }) =>
    isAppleDevelopmentIdentityName(name),
  );
}

function resolveRequestedIdentity(fingerprint) {
  if (fingerprint && !/^[0-9a-f]{40}$/iu.test(fingerprint)) {
    throw new Error(
      "Apple Development identity fingerprint must be 40 hex digits",
    );
  }
  const normalizedFingerprint = fingerprint?.toUpperCase() ?? null;
  let output = identityOutput("codesigning");
  if (appleDevelopmentCandidates(output).length !== 0) {
    return selectLocalCodeSigningIdentity(output, normalizedFingerprint);
  }

  const basicOutput = identityOutput("basic");
  if (appleDevelopmentCandidates(basicOutput).length === 0) {
    return selectLocalCodeSigningIdentity(output, normalizedFingerprint);
  }
  selectLocalCodeSigningIdentity(basicOutput, normalizedFingerprint);

  const bundledWwdrG3Path = resolveBundledWwdrG3Path();
  if (!bundledWwdrG3Path) {
    throw new Error(
      "An Apple Development certificate and private key exist, but the Apple WWDR G3 intermediate certificate is missing. Install Worldwide Developer Relations G3 from https://www.apple.com/certificateauthority/ and retry.",
    );
  }
  console.log(
    "Installing Apple's WWDR G3 intermediate certificate from Xcode into the login keychain.",
  );
  run("/usr/bin/security", [
    "add-certificates",
    "-k",
    localSigningKeychainPath(),
    bundledWwdrG3Path,
  ]);
  output = identityOutput("codesigning");
  return selectLocalCodeSigningIdentity(output, normalizedFingerprint);
}

function verifyPrivateKeyAccess(identity, directory) {
  const probePath = path.join(directory, "metawork-signing-probe");
  copyFileSync("/usr/bin/true", probePath);
  chmodSync(probePath, 0o700);
  console.log(
    "macOS may ask once for /usr/bin/codesign to use the Apple Development private key.",
  );
  run("/usr/bin/codesign", [
    "--force",
    "--sign",
    identity.fingerprint,
    "--identifier",
    setupProbeIdentifier,
    "--timestamp=none",
    probePath,
  ]);
  const discovered = verifyAppleSignature(probePath, setupProbeIdentifier, {
    expectedIdentityName: identity.name,
  });
  return signWithStableRequirement(
    probePath,
    { ...identity, teamId: discovered.teamId },
    { identifier: setupProbeIdentifier },
  );
}

function writeSelection(identity, teamId) {
  const temporaryPath = `${localSigningConfigPath}.${process.pid}.tmp`;
  const selection = {
    schemaVersion: 1,
    fingerprint: identity.fingerprint,
    name: identity.name,
    teamId,
  };
  try {
    writeFileSync(temporaryPath, `${JSON.stringify(selection, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    renameSync(temporaryPath, localSigningConfigPath);
    chmodSync(localSigningConfigPath, 0o600);
  } finally {
    if (existsSync(temporaryPath)) unlinkSync(temporaryPath);
  }
}

function setupIdentity(fingerprint) {
  requireMacos();
  const identity = resolveRequestedIdentity(fingerprint);
  const temporary = createSecureTemporaryDirectory();
  try {
    const signature = verifyPrivateKeyAccess(identity, temporary.directory);
    writeSelection(identity, signature.teamId);
    console.log(
      `MetaWork selected Apple Development identity ${identity.fingerprint} (TeamIdentifier=${signature.teamId}).`,
    );
  } finally {
    temporary.dispose();
  }
}

function clearSelection() {
  requireMacos();
  if (existsSync(localSigningConfigPath)) {
    unlinkSync(localSigningConfigPath);
    console.log(`Removed local signing selection ${localSigningConfigPath}.`);
  } else {
    console.log("MetaWork has no local signing selection to clear.");
  }
  console.log("The Apple Development identity was not modified.");
}

function main() {
  const command = process.argv[2] ?? "setup";
  switch (command) {
    case "setup":
      if (process.argv.length > 4) {
        throw new Error(
          "usage: node scripts/setup-macos-local-signing.mjs setup [fingerprint]",
        );
      }
      setupIdentity(process.argv[3] ?? null);
      break;
    case "clear":
      if (process.argv.length !== 3) {
        throw new Error(
          "usage: node scripts/setup-macos-local-signing.mjs clear",
        );
      }
      clearSelection();
      break;
    default:
      throw new Error(
        "usage: node scripts/setup-macos-local-signing.mjs setup [fingerprint]|clear",
      );
  }
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (invokedPath === import.meta.url) {
  try {
    main();
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
