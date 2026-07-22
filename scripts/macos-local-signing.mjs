import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

export function parseNativeProductIdentity(manifest) {
  const bundleId = manifest.match(/^\s*\.id = "([^"]+)",?$/mu)?.[1];
  const executableName = manifest.match(/^\s*\.name = "([^"]+)",?$/mu)?.[1];
  if (
    !bundleId ||
    !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(bundleId) ||
    !executableName ||
    !/^[A-Za-z0-9._-]+$/u.test(executableName)
  ) {
    throw new Error("app.zon has an invalid native product identity");
  }
  return Object.freeze({ bundleId, executableName });
}

export const localProductIdentity = parseNativeProductIdentity(
  readFileSync(path.join(repositoryRoot, "app.zon"), "utf8"),
);

export const localSigningConfigPath = path.join(
  repositoryRoot,
  ".metawork-local-signing.json",
);
const executablePath = path.join(
  repositoryRoot,
  "zig-out",
  "bin",
  localProductIdentity.executableName,
);
const nativeDispatcher = path.join(
  repositoryRoot,
  "node_modules",
  "@native-sdk",
  "cli",
  "bin",
  "native.js",
);

export function localSigningKeychainPath() {
  const keychainPath = path.join(
    homedir(),
    "Library",
    "Keychains",
    "login.keychain-db",
  );
  if (!existsSync(keychainPath)) {
    throw new Error(`login keychain does not exist: ${keychainPath}`);
  }
  return keychainPath;
}

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

export function parseCodeSigningIdentities(output) {
  const identities = [];
  for (const line of output.split(/\r?\n/u)) {
    const match = line.match(/^\s*\d+\)\s+([0-9a-f]{40})\s+"([^"]+)"\s*$/iu);
    if (match) {
      identities.push({ fingerprint: match[1].toUpperCase(), name: match[2] });
    }
  }
  return identities;
}

export function isAppleDevelopmentIdentityName(name) {
  return /^Apple Development: .+$/u.test(name);
}

export function selectLocalCodeSigningIdentity(
  output,
  configuredFingerprint = null,
) {
  const candidates = parseCodeSigningIdentities(output).filter(({ name }) =>
    isAppleDevelopmentIdentityName(name),
  );
  const matching = configuredFingerprint
    ? candidates.filter(
        ({ fingerprint }) =>
          fingerprint === configuredFingerprint.toUpperCase(),
      )
    : candidates;
  if (matching.length !== 1) {
    const qualifier = configuredFingerprint
      ? ` matching configured fingerprint ${configuredFingerprint.toUpperCase()}`
      : "";
    throw new Error(
      `Expected exactly one valid Apple Development Code Signing identity${qualifier}, found ${matching.length}. See docs/macos-local-development.md.`,
    );
  }
  return matching[0];
}

export function parseLocalSigningConfig(bytes) {
  let value;
  try {
    value = JSON.parse(bytes);
  } catch {
    throw new Error("local signing selection is not valid JSON");
  }
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).sort().join(",") !==
      "fingerprint,name,schemaVersion,teamId" ||
    value.schemaVersion !== 1 ||
    typeof value.fingerprint !== "string" ||
    !/^[0-9A-F]{40}$/u.test(value.fingerprint) ||
    typeof value.name !== "string" ||
    !isAppleDevelopmentIdentityName(value.name) ||
    typeof value.teamId !== "string" ||
    !/^[A-Z0-9]{10}$/u.test(value.teamId)
  ) {
    throw new Error("local signing selection has an invalid schema");
  }
  return Object.freeze({
    schemaVersion: 1,
    fingerprint: value.fingerprint,
    name: value.name,
    teamId: value.teamId,
  });
}

export function parseCodeDirectoryIdentifier(output) {
  const match = output.match(/^Identifier=(.+)$/mu);
  if (!match) throw new Error("codesign output did not contain Identifier");
  return match[1].trim();
}

export function parseTeamIdentifier(output) {
  const match = output.match(/^TeamIdentifier=(.+)$/mu);
  if (!match) throw new Error("codesign output did not contain TeamIdentifier");
  const teamId = match[1].trim();
  if (!/^[A-Z0-9]{10}$/u.test(teamId)) {
    throw new Error(
      `code signature has no Apple-issued Team Identifier: ${teamId}`,
    );
  }
  return teamId;
}

export function validateDesignatedRequirement(output, expectedIdentifier) {
  const requirement = output
    .split(/\r?\n/u)
    .find((line) => line.startsWith("designated =>"));
  if (!requirement) {
    throw new Error("codesign output did not contain a designated requirement");
  }
  if (requirement.includes("cdhash")) {
    throw new Error(
      "designated requirement is still tied to a changing CDHash",
    );
  }
  if (!requirement.includes(`identifier "${expectedIdentifier}"`)) {
    throw new Error(
      `designated requirement does not bind identifier ${expectedIdentifier}`,
    );
  }
  if (!requirement.includes("anchor apple generic")) {
    throw new Error(
      "designated requirement is not anchored to the Apple signing chain",
    );
  }
  return requirement;
}

function requireMacos() {
  if (process.platform !== "darwin") {
    throw new Error("local MetaWork code signing is only available on macOS");
  }
}

export function resolveIdentity() {
  requireMacos();
  if (!existsSync(localSigningConfigPath)) {
    throw new Error(
      `local signing selection is missing: ${localSigningConfigPath}. Run npm run setup:macos-signing.`,
    );
  }
  const config = parseLocalSigningConfig(
    readFileSync(localSigningConfigPath, "utf8"),
  );
  const result = run(
    "/usr/bin/security",
    ["find-identity", "-v", "-p", "codesigning", localSigningKeychainPath()],
    { capture: true },
  );
  const identity = selectLocalCodeSigningIdentity(
    combinedOutput(result),
    config.fingerprint,
  );
  if (identity.name !== config.name) {
    throw new Error(
      "configured Apple Development identity metadata changed; rerun npm run setup:macos-signing",
    );
  }
  return { ...identity, teamId: config.teamId };
}

function requireTarget(targetPath) {
  if (!existsSync(targetPath)) {
    throw new Error(`signing target does not exist: ${targetPath}`);
  }
}

function signatureReport(targetPath) {
  const result = run(
    "/usr/bin/codesign",
    ["--display", "--verbose=4", "--requirements", "-", targetPath],
    { capture: true },
  );
  return combinedOutput(result);
}

export function verifyStableSignature(
  targetPath,
  expectedIdentifier = localProductIdentity.bundleId,
  options = {},
) {
  requireMacos();
  requireTarget(targetPath);
  const verifyArgs = ["--verify", "--strict", "--verbose=2"];
  if (options.deep) verifyArgs.push("--deep");
  verifyArgs.push(targetPath);
  run("/usr/bin/codesign", verifyArgs, { capture: true });
  const report = signatureReport(targetPath);
  const identifier = parseCodeDirectoryIdentifier(report);
  if (identifier !== expectedIdentifier) {
    throw new Error(
      `CodeDirectory identifier is ${identifier}, expected ${expectedIdentifier}`,
    );
  }
  const teamId = parseTeamIdentifier(report);
  if (options.expectedTeamId && teamId !== options.expectedTeamId) {
    throw new Error(
      `TeamIdentifier is ${teamId}, expected ${options.expectedTeamId}`,
    );
  }
  const requirement = validateDesignatedRequirement(report, expectedIdentifier);
  return { identifier, requirement, teamId };
}

function signExecutable(identity) {
  requireTarget(executablePath);
  run("/usr/bin/codesign", [
    "--force",
    "--sign",
    identity.fingerprint,
    "--identifier",
    localProductIdentity.bundleId,
    "--timestamp=none",
    executablePath,
  ]);
  return verifyStableSignature(executablePath, localProductIdentity.bundleId, {
    expectedTeamId: identity.teamId,
  });
}

function runNative(args) {
  requireTarget(nativeDispatcher);
  run(process.execPath, [nativeDispatcher, ...args]);
}

function runNpm(args) {
  run(process.platform === "win32" ? "npm.cmd" : "npm", args);
}

function runNode(script) {
  run(process.execPath, [path.join(repositoryRoot, script)]);
}

function runDevelopment() {
  if (process.platform !== "darwin") {
    runNative(["dev", ".", "--yes"]);
    return;
  }
  const identity = resolveIdentity();
  runNative(["build", ".", "--yes", "-Doptimize=Debug"]);
  const signature = signExecutable(identity);
  console.log(
    `verified local development signature ${identity.fingerprint} (${signature.requirement})`,
  );
  runNative(["dev", "--manifest", "app.zon", "--binary", executablePath]);
}

function packageMacos() {
  requireMacos();
  const identity = resolveIdentity();
  runNpm(["run", "build:release"]);
  runNode("scripts/clean-macos-package.mjs");
  runNative([
    "package",
    "--target",
    "macos",
    "--assets",
    "frontend/dist",
    "--signing",
    "identity",
    "--identity",
    identity.fingerprint,
    "--team-id",
    identity.teamId,
  ]);
  runNode("scripts/verify-macos-package.mjs");
}

function main() {
  const command = process.argv[2];
  switch (command) {
    case "dev":
      runDevelopment();
      break;
    case "package":
      packageMacos();
      break;
    default:
      throw new Error(
        "usage: node scripts/macos-local-signing.mjs dev|package",
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
