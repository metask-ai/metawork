import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, rmSync } from "node:fs";
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

export function parseNativePackageMetadata(manifest) {
  const displayName = manifest.match(
    /^\s*\.display_name = "([^"]+)",?$/mu,
  )?.[1];
  const version = manifest.match(/^\s*\.version = "([^"]+)",?$/mu)?.[1];
  if (
    !displayName ||
    !/^[A-Za-z0-9._-]+$/u.test(displayName) ||
    !version ||
    !/^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$/u.test(version)
  ) {
    throw new Error("app.zon has invalid native package metadata");
  }
  return Object.freeze({ displayName, version });
}

const appManifest = readFileSync(path.join(repositoryRoot, "app.zon"), "utf8");
export const localProductIdentity = parseNativeProductIdentity(appManifest);
export const localPackageMetadata = parseNativePackageMetadata(appManifest);

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
const packagedAppPath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  `${localProductIdentity.executableName}.app`,
);
const packageArtifactStem = `${localPackageMetadata.displayName}-${localPackageMetadata.version}-macos-arm64`;
const notarizationArchivePath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  `${packageArtifactStem}-notary.zip`,
);
const distributionArchivePath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  `${packageArtifactStem}.zip`,
);
const notarizationProfile = "metawork-notary";
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
    input: options.input,
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

export function isDeveloperIdApplicationIdentityName(name) {
  return /^Developer ID Application: .+ \([A-Z0-9]{10}\)$/u.test(name);
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

export function selectDistributionCodeSigningIdentity(
  output,
  configuredFingerprint = null,
) {
  const candidates = parseCodeSigningIdentities(output).filter(({ name }) =>
    isDeveloperIdApplicationIdentityName(name),
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
      `Expected exactly one valid Developer ID Application Code Signing identity${qualifier}, found ${matching.length}. See docs/macos-local-development.md.`,
    );
  }
  return matching[0];
}

export function parseDeveloperIdCertificateReport(output) {
  const fingerprint = output
    .match(/^sha1 Fingerprint=([0-9A-F:]+)$/imu)?.[1]
    ?.replaceAll(":", "")
    .toUpperCase();
  const subject = output.match(/^subject=(.+)$/imu)?.[1];
  const teamId = subject?.match(/(?:^|,)OU=([A-Z0-9]{10})(?:,|$)/u)?.[1];
  if (!fingerprint || !/^[0-9A-F]{40}$/u.test(fingerprint) || !teamId) {
    throw new Error(
      "Developer ID certificate report did not contain one SHA-1 fingerprint and Team ID",
    );
  }
  return { fingerprint, teamId };
}

export function parseNotarySubmission(output) {
  let value;
  try {
    value = JSON.parse(output);
  } catch {
    throw new Error("notarytool submission output is not valid JSON");
  }
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    typeof value.id !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(
      value.id,
    ) ||
    typeof value.status !== "string" ||
    !["Accepted", "Invalid", "In Progress", "Rejected"].includes(value.status)
  ) {
    throw new Error("notarytool submission output has an invalid shape");
  }
  return Object.freeze({ id: value.id, status: value.status });
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

export function parseSigningAuthorities(output) {
  return [...output.matchAll(/^Authority=(.+)$/gmu)].map((match) =>
    match[1].trim(),
  );
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

export function buildDeveloperIdRequirement(identifier, teamId, identityName) {
  if (
    !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/u.test(identifier) ||
    !/^[A-Z0-9]{10}$/u.test(teamId) ||
    !isDeveloperIdApplicationIdentityName(identityName) ||
    /["\\]/u.test(identityName)
  ) {
    throw new Error(
      "cannot build a Developer ID requirement from invalid identity metadata",
    );
  }
  return `identifier "${identifier}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${identityName}"`;
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

export function resolveDistributionIdentity() {
  requireMacos();
  const identities = run(
    "/usr/bin/security",
    ["find-identity", "-v", "-p", "codesigning", localSigningKeychainPath()],
    { capture: true },
  );
  const identity = selectDistributionCodeSigningIdentity(
    combinedOutput(identities),
  );
  const certificate = run(
    "/usr/bin/security",
    ["find-certificate", "-c", identity.name, "-p", localSigningKeychainPath()],
    { capture: true },
  );
  const report = run(
    "/usr/bin/openssl",
    [
      "x509",
      "-noout",
      "-fingerprint",
      "-sha1",
      "-subject",
      "-nameopt",
      "RFC2253",
    ],
    { capture: true, input: certificate.stdout },
  );
  const metadata = parseDeveloperIdCertificateReport(combinedOutput(report));
  if (metadata.fingerprint !== identity.fingerprint) {
    throw new Error(
      `Developer ID certificate fingerprint is ${metadata.fingerprint}, expected ${identity.fingerprint}`,
    );
  }
  return { ...identity, teamId: metadata.teamId };
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

export function verifyDeveloperIdSignature(
  targetPath,
  identity,
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
  if (teamId !== identity.teamId) {
    throw new Error(`TeamIdentifier is ${teamId}, expected ${identity.teamId}`);
  }
  const authorities = parseSigningAuthorities(report);
  if (authorities[0] !== identity.name) {
    throw new Error(
      `code signature leaf authority is ${authorities[0] ?? "missing"}, expected ${identity.name}`,
    );
  }
  if (!/^Timestamp=.+$/mu.test(report)) {
    throw new Error("Developer ID code signature has no trusted timestamp");
  }
  if (!/^CodeDirectory .*flags=.*\(runtime\)/mu.test(report)) {
    throw new Error("Developer ID code signature has no hardened runtime flag");
  }

  const policy = buildDeveloperIdRequirement(
    expectedIdentifier,
    identity.teamId,
    identity.name,
  );
  run("/usr/bin/codesign", [...verifyArgs, `-R=${policy}`, targetPath], {
    capture: true,
  });
  return { authorities, identifier, policy, report, teamId };
}

export function signWithDeveloperId(targetPath, identity, options = {}) {
  requireMacos();
  requireTarget(targetPath);
  const identifier = options.identifier ?? localProductIdentity.bundleId;
  const args = [
    "--force",
    "--sign",
    identity.fingerprint,
    "--identifier",
    identifier,
    "--options",
    "runtime",
    "--timestamp",
  ];
  if (options.preserveEntitlements) {
    args.push("--preserve-metadata=entitlements");
  }
  args.push(targetPath);
  run("/usr/bin/codesign", args);
  return verifyDeveloperIdSignature(targetPath, identity, identifier, {
    deep: options.deep,
  });
}

function signExecutable(identity) {
  return signWithStableRequirement(executablePath, identity);
}

function runNative(args) {
  requireTarget(nativeDispatcher);
  run(process.execPath, [nativeDispatcher, ...args]);
}

function runNode(script, args = []) {
  run(process.execPath, [path.join(repositoryRoot, script), ...args]);
}

function createAppArchive(targetPath) {
  rmSync(targetPath, { force: true });
  run("/usr/bin/ditto", [
    "-c",
    "-k",
    "--sequesterRsrc",
    "--keepParent",
    packagedAppPath,
    targetPath,
  ]);
  run("/usr/bin/unzip", ["-tq", targetPath], { capture: true });
}

function notarizePackage() {
  createAppArchive(notarizationArchivePath);
  const result = run(
    "/usr/bin/xcrun",
    [
      "notarytool",
      "submit",
      notarizationArchivePath,
      "--keychain-profile",
      notarizationProfile,
      "--wait",
      "--timeout",
      "2h",
      "--output-format",
      "json",
      "--no-progress",
    ],
    { capture: true },
  );
  const submission = parseNotarySubmission(result.stdout);
  if (submission.status !== "Accepted") {
    throw new Error(
      `Apple notarization ${submission.id} finished with status ${submission.status}; inspect it with xcrun notarytool log ${submission.id} --keychain-profile ${notarizationProfile}`,
    );
  }

  run("/usr/bin/xcrun", ["stapler", "staple", "-v", packagedAppPath]);
  run("/usr/bin/xcrun", ["stapler", "validate", "-v", packagedAppPath]);
  run("/usr/sbin/spctl", [
    "--assess",
    "--type",
    "execute",
    "--verbose=4",
    packagedAppPath,
  ]);
  createAppArchive(distributionArchivePath);
  rmSync(notarizationArchivePath, { force: true });

  const digest = createHash("sha256")
    .update(readFileSync(distributionArchivePath))
    .digest("hex");
  return { archivePath: distributionArchivePath, digest, submission };
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
  const identity = resolveDistributionIdentity();
  rmSync(distributionArchivePath, { force: true });
  rmSync(notarizationArchivePath, { force: true });
  runNode("scripts/build.mjs", ["release"]);
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
  const signature = signWithDeveloperId(packagedAppPath, identity, {
    deep: true,
    preserveEntitlements: true,
  });
  runNode("scripts/verify-macos-package.mjs");
  const notarized = notarizePackage();
  verifyDeveloperIdSignature(packagedAppPath, identity, undefined, {
    deep: true,
  });
  console.log(
    `built Developer ID signed and notarized package ${packagedAppPath} (${signature.policy})`,
  );
  console.log(
    `Apple notarization ${notarized.submission.id} accepted; final archive ${notarized.archivePath} (sha256=${notarized.digest})`,
  );
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
