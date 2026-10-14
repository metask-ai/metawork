import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import {
  parseNativeProductIdentity,
  readNativePackageManifest,
} from "./package-metadata.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";
import { localArchiveEnvironment } from "./archive-environment.mjs";
import { localOfficeEnvironment } from "./office-environment.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

export { parseNativeProductIdentity };

const packageManifest = readNativePackageManifest(repositoryRoot);
export const localProductIdentity = packageManifest.identity;
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
    env: {
      ...localArchiveEnvironment(
        repositoryRoot,
        localOfficeEnvironment(repositoryRoot),
      ),
      METAWORK_LOCAL_SKILL_ROOT: path.join(
        repositoryRoot,
        "src",
        "product",
        "skill",
        "assets",
      ),
    },
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
      `Expected exactly one valid Apple Development Code Signing identity${qualifier}, found ${matching.length}. See docs/macos-distribution.md.`,
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

export function buildAppleDevelopmentRequirement(
  identifier,
  teamId,
  identityName,
) {
  if (
    !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(identifier) ||
    !/^[A-Z0-9]{10}$/u.test(teamId) ||
    !isAppleDevelopmentIdentityName(identityName) ||
    /["\\]/u.test(identityName)
  ) {
    throw new Error(
      "cannot build an Apple Development requirement from invalid identity metadata",
    );
  }
  return `identifier "${identifier}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${identityName}"`;
}

export function buildCanonicalDesignatedRequirement(
  identifier,
  teamId,
  identityName,
) {
  return `designated => ${buildAppleDevelopmentRequirement(identifier, teamId, identityName)}`;
}

export function parseDesignatedRequirement(output) {
  const requirements = output
    .split(/\r?\n/u)
    .filter((line) => line.startsWith("designated =>"));
  if (requirements.length !== 1) {
    throw new Error(
      `codesign output contained ${requirements.length} designated requirements, expected 1`,
    );
  }
  const [requirement] = requirements;
  if (/\bcdhash\b/iu.test(requirement)) {
    throw new Error("designated requirement is tied to an unstable CDHash");
  }
  return requirement;
}

export function validateCanonicalDesignatedRequirement(
  output,
  expectedRequirement,
) {
  const actual = parseDesignatedRequirement(output);
  if (actual !== expectedRequirement) {
    throw new Error(
      `designated requirement is not the canonical MetaWork requirement\nactual: ${actual}\nexpected: ${expectedRequirement}`,
    );
  }
  return actual;
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
      `local signing selection is missing: ${localSigningConfigPath}. Run node scripts/setup-macos-local-signing.mjs setup.`,
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
      "configured Apple Development identity metadata changed; rerun node scripts/setup-macos-local-signing.mjs setup",
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

export function verifyAppleSignature(
  targetPath,
  expectedIdentifier = localProductIdentity.bundleId,
  options = {},
) {
  requireMacos();
  requireTarget(targetPath);
  const verifyArgs = ["--verify", "--strict", "--verbose=2"];
  if (options.deep) verifyArgs.push("--deep");
  run("/usr/bin/codesign", [...verifyArgs, targetPath], { capture: true });
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
  if (!options.expectedIdentityName) {
    throw new Error(
      "signature verification requires the selected Apple Development identity name",
    );
  }
  const policy = buildAppleDevelopmentRequirement(
    expectedIdentifier,
    teamId,
    options.expectedIdentityName,
  );
  run("/usr/bin/codesign", [...verifyArgs, `-R=${policy}`, targetPath], {
    capture: true,
  });
  return { identifier, policy, report, teamId };
}

export function verifyStableSignature(
  targetPath,
  expectedIdentifier = localProductIdentity.bundleId,
  options = {},
) {
  const signature = verifyAppleSignature(
    targetPath,
    expectedIdentifier,
    options,
  );
  const expectedRequirement = buildCanonicalDesignatedRequirement(
    expectedIdentifier,
    signature.teamId,
    options.expectedIdentityName,
  );
  const requirement = validateCanonicalDesignatedRequirement(
    signature.report,
    expectedRequirement,
  );
  return { ...signature, requirement };
}

export function signWithStableRequirement(targetPath, identity, options = {}) {
  requireMacos();
  requireTarget(targetPath);
  const identifier = options.identifier ?? localProductIdentity.bundleId;
  const requirement = buildCanonicalDesignatedRequirement(
    identifier,
    identity.teamId,
    identity.name,
  );
  const args = [
    "--force",
    "--sign",
    identity.fingerprint,
    "--identifier",
    identifier,
    "--requirements",
    `=${requirement}`,
    "--timestamp=none",
  ];
  if (options.preserveMetadata) {
    args.push("--preserve-metadata=entitlements,flags");
  }
  args.push(targetPath);
  run("/usr/bin/codesign", args);
  return verifyStableSignature(targetPath, identifier, {
    deep: options.deep,
    expectedIdentityName: identity.name,
    expectedTeamId: identity.teamId,
  });
}

function runNative(args) {
  requireTarget(nativeDispatcher);
  run(process.execPath, [nativeDispatcher, ...args]);
}

async function verifiedAgentCoreTarget() {
  const bundle = await verifyStagedAgentCoreBundle(repositoryRoot);
  console.log(
    `verified staged AgentCore ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`,
  );
  const target = bundle.target;
  if (typeof target !== "string" || target.length === 0) {
    throw new Error("verified AgentCore bundle has no Zig target");
  }
  return target;
}

export async function runDevelopment() {
  const target = await verifiedAgentCoreTarget();
  if (process.platform !== "darwin") {
    runNative(["dev", ".", "--yes", `-Dtarget=${target}`]);
    return;
  }
  const identity = resolveIdentity();
  runNative(["build", ".", "--yes", `-Dtarget=${target}`, "-Doptimize=Debug"]);
  const signature = signWithStableRequirement(executablePath, identity);
  console.log(
    `verified local development signature ${identity.fingerprint} (${signature.requirement})`,
  );
  runNative(["dev", "--manifest", "app.zon", "--binary", executablePath]);
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (invokedPath === import.meta.url) {
  try {
    await runDevelopment();
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
