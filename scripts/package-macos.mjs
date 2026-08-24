import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  rmSync,
  statSync,
  symlinkSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import {
  parseNativePackageMetadata,
  parseNativeProductIdentity,
  readNativePackageManifest,
} from "./package-metadata.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

export { parseNativePackageMetadata, parseNativeProductIdentity };

const packageManifest = readNativePackageManifest(repositoryRoot);
export const localProductIdentity = packageManifest.identity;
export const localPackageMetadata = packageManifest.metadata;

const packagedAppPath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  `${localProductIdentity.executableName}.app`,
);
const trayIconSourcePath = path.join(
  repositoryRoot,
  "assets",
  "icons",
  "tray-icon.png",
);
const packagedTrayIconPath = path.join(
  packagedAppPath,
  "Contents",
  "Resources",
  "assets",
  "icons",
  "tray-icon.png",
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

function distributionSigningKeychainPath() {
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

export function macosDistributionForAgentCoreTarget(targetId) {
  const architecture =
    targetId === "aarch64-macos"
      ? { artifact: "arm64", executable: "arm64" }
      : targetId === "x86_64-macos"
        ? { artifact: "x64", executable: "x86_64" }
        : null;
  if (!architecture) {
    throw new Error(`unsupported macOS package target: ${targetId}`);
  }
  const diskImageName = `${localProductIdentity.executableName}-${localPackageMetadata.version}-macos-${architecture.artifact}.dmg`;
  return Object.freeze({
    ...architecture,
    diskImageName,
    diskImagePath: path.join(
      repositoryRoot,
      "zig-out",
      "package",
      diskImageName,
    ),
    targetId,
  });
}

export function macosPackageTargetIds(selection = "all") {
  if (selection === "all") return ["aarch64-macos", "x86_64-macos"];
  if (selection === "arm64") return ["aarch64-macos"];
  if (selection === "x64") return ["x86_64-macos"];
  throw new Error(
    `unsupported macOS package architecture: ${selection}; expected arm64, x64, or all`,
  );
}

export function requireSingleMacosExecutableArchitecture(output, expected) {
  const nonFat = output.match(/\bis architecture:\s*([A-Za-z0-9_]+)\s*$/mu);
  const fat = output.match(/\bare:\s*([A-Za-z0-9_ ]+)\s*$/mu);
  const architectures = nonFat
    ? [nonFat[1]]
    : fat
      ? fat[1].trim().split(/\s+/u)
      : [];
  if (architectures.length !== 1 || architectures[0] !== expected) {
    throw new Error(
      `packaged macOS executable architectures are ${architectures.join(", ") || "unknown"}, expected only ${expected}`,
    );
  }
  return architectures[0];
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

export function isDeveloperIdApplicationIdentityName(name) {
  return /^Developer ID Application: .+ \([A-Z0-9]{10}\)$/u.test(name);
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

function requireMacos() {
  if (process.platform !== "darwin") {
    throw new Error("local MetaWork code signing is only available on macOS");
  }
}

export function resolveDistributionIdentity() {
  requireMacos();
  const identities = run(
    "/usr/bin/security",
    [
      "find-identity",
      "-v",
      "-p",
      "codesigning",
      distributionSigningKeychainPath(),
    ],
    { capture: true },
  );
  const identity = selectDistributionCodeSigningIdentity(
    combinedOutput(identities),
  );
  const certificate = run(
    "/usr/bin/security",
    [
      "find-certificate",
      "-c",
      identity.name,
      "-p",
      distributionSigningKeychainPath(),
    ],
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
}

function runNative(args) {
  requireTarget(nativeDispatcher);
  run(process.execPath, [nativeDispatcher, ...args]);
}

function runNode(script, args = []) {
  run(process.execPath, [path.join(repositoryRoot, script), ...args]);
}

export function stageMacosTrayIcon(
  sourcePath = trayIconSourcePath,
  targetPath = packagedTrayIconPath,
) {
  if (!existsSync(sourcePath)) {
    throw new Error(`macOS tray icon is missing: ${sourcePath}`);
  }
  mkdirSync(path.dirname(targetPath), { recursive: true });
  copyFileSync(sourcePath, targetPath);
  if (!existsSync(targetPath)) {
    throw new Error(`macOS tray icon was not staged: ${targetPath}`);
  }
  return targetPath;
}

function regularFiles(root, directory = root) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...regularFiles(root, absolutePath));
    } else if (entry.isFile()) {
      files.push(path.relative(root, absolutePath));
    }
  }
  return files.sort();
}

function fileDigest(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function verifyPackagedMacosExecutableArchitecture(expectedArchitecture) {
  const executable = path.join(
    packagedAppPath,
    "Contents",
    "MacOS",
    localProductIdentity.executableName,
  );
  if (statSync(executable).size === 0) {
    throw new Error(`packaged executable is empty: ${executable}`);
  }
  const report = run("/usr/bin/lipo", ["-info", executable], {
    capture: true,
  });
  return requireSingleMacosExecutableArchitecture(
    combinedOutput(report),
    expectedArchitecture,
  );
}

function verifyPackagedMacosApp(identity) {
  const sourceAssets = path.join(repositoryRoot, "frontend", "dist");
  const packagedAssets = path.join(
    packagedAppPath,
    "Contents",
    "Resources",
    "frontend",
    "dist",
  );
  const sourceFiles = regularFiles(sourceAssets);
  const packagedFiles = regularFiles(packagedAssets).filter(
    (file) => file !== "asset-manifest.zon",
  );
  if (JSON.stringify(sourceFiles) !== JSON.stringify(packagedFiles)) {
    throw new Error("packaged Renderer file set differs from frontend/dist");
  }
  for (const relativePath of sourceFiles) {
    if (
      fileDigest(path.join(sourceAssets, relativePath)) !==
      fileDigest(path.join(packagedAssets, relativePath))
    ) {
      throw new Error(`packaged Renderer asset differs: ${relativePath}`);
    }
  }
  const trayBytes = readFileSync(packagedTrayIconPath);
  if (
    trayBytes.length < 24 ||
    trayBytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a" ||
    trayBytes.subarray(12, 16).toString("ascii") !== "IHDR" ||
    trayBytes.readUInt32BE(16) !== 64 ||
    trayBytes.readUInt32BE(20) !== 64 ||
    fileDigest(trayIconSourcePath) !== fileDigest(packagedTrayIconPath)
  ) {
    throw new Error("packaged macOS tray icon is not the exact 64x64 PNG");
  }
  const plist = path.join(packagedAppPath, "Contents", "Info.plist");
  for (const [key, expected] of [
    ["CFBundleIdentifier", localProductIdentity.bundleId],
    ["CFBundleExecutable", localProductIdentity.executableName],
    ["CFBundleDisplayName", localPackageMetadata.displayName],
    ["CFBundleShortVersionString", localPackageMetadata.version],
  ]) {
    const actual = run(
      "/usr/bin/plutil",
      ["-extract", key, "raw", "-o", "-", plist],
      { capture: true },
    ).stdout.trim();
    if (actual !== expected) {
      throw new Error(`Info.plist ${key} is ${actual}, expected ${expected}`);
    }
  }
  return verifyDeveloperIdSignature(
    packagedAppPath,
    identity,
    localProductIdentity.bundleId,
    { deep: true },
  );
}

function verifyDeveloperIdDiskImageSignature(targetPath, identity) {
  run(
    "/usr/bin/codesign",
    ["--verify", "--strict", "--verbose=2", targetPath],
    {
      capture: true,
    },
  );
  const report = signatureReport(targetPath);
  const teamId = parseTeamIdentifier(report);
  if (teamId !== identity.teamId) {
    throw new Error(
      `DMG TeamIdentifier is ${teamId}, expected ${identity.teamId}`,
    );
  }
  const authorities = parseSigningAuthorities(report);
  if (authorities[0] !== identity.name) {
    throw new Error(
      `DMG code signature leaf authority is ${authorities[0] ?? "missing"}, expected ${identity.name}`,
    );
  }
  if (!/^Timestamp=.+$/mu.test(report)) {
    throw new Error("Developer ID DMG code signature has no trusted timestamp");
  }
  return { authorities, report, teamId };
}

function appleScriptString(value) {
  if (value.includes("\0")) throw new Error("AppleScript string contains NUL");
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

export function buildDmgFinderLayoutScript(mountPoint) {
  const target = appleScriptString(mountPoint);
  const appName = appleScriptString(`${localPackageMetadata.displayName}.app`);
  return `
tell application "Finder"
  set targetFolder to folder (POSIX file "${target}" as alias)
  open targetFolder
  delay 1
  set targetWindow to front window
  set current view of targetWindow to icon view
  set toolbar visible of targetWindow to false
  set statusbar visible of targetWindow to false
  set pathbar visible of targetWindow to false
  set bounds of targetWindow to {100, 100, 700, 440}
  set viewOptions to icon view options of targetWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 112
  set text size of viewOptions to 13
  set position of item "${appName}" of targetFolder to {165, 135}
  set position of item "Applications" of targetFolder to {435, 135}
  close targetWindow
  open targetFolder
  set targetWindow to front window
  delay 1
  set statusbar visible of targetWindow to false
  set bounds of targetWindow to {100, 100, 690, 430}
  delay 1
  set bounds of targetWindow to {100, 100, 700, 440}
  update targetFolder without registering applications
  delay 1
  close targetWindow
  delay 2
end tell
`;
}

function createDistributionDiskImage(identity, targetPath) {
  const workRoot = mkdtempSync(path.join(tmpdir(), "metawork-dmg-build-"));
  const stagingRoot = path.join(workRoot, "source");
  const mountPoint = path.join(workRoot, "mount");
  const writableDiskImagePath = path.join(workRoot, "layout.dmg");
  mkdirSync(stagingRoot);
  mkdirSync(mountPoint);
  let attached = false;
  try {
    const stagedAppPath = path.join(
      stagingRoot,
      `${localPackageMetadata.displayName}.app`,
    );
    run("/usr/bin/ditto", [packagedAppPath, stagedAppPath]);
    symlinkSync("/Applications", path.join(stagingRoot, "Applications"));
    run("/usr/bin/hdiutil", [
      "create",
      "-volname",
      localPackageMetadata.displayName,
      "-srcfolder",
      stagingRoot,
      "-format",
      "UDRW",
      "-fs",
      "HFS+",
      "-ov",
      writableDiskImagePath,
    ]);
    run(
      "/usr/bin/hdiutil",
      [
        "attach",
        "-readwrite",
        "-noverify",
        "-noautoopen",
        "-mountpoint",
        mountPoint,
        writableDiskImagePath,
      ],
      { capture: true },
    );
    attached = true;
    run("/usr/bin/osascript", ["-e", buildDmgFinderLayoutScript(mountPoint)]);
    run("/bin/sync", []);
    if (!existsSync(path.join(mountPoint, ".DS_Store"))) {
      throw new Error("Finder did not persist the DMG layout to .DS_Store");
    }
    for (const runtimeMetadata of [
      ".fseventsd",
      ".Spotlight-V100",
      ".Trashes",
    ]) {
      rmSync(path.join(mountPoint, runtimeMetadata), {
        recursive: true,
        force: true,
      });
    }
    run("/bin/sync", []);
    run("/usr/bin/hdiutil", ["detach", mountPoint], { capture: true });
    attached = false;
    run("/usr/bin/hdiutil", [
      "convert",
      writableDiskImagePath,
      "-format",
      "UDZO",
      "-ov",
      "-o",
      targetPath,
    ]);
  } finally {
    if (attached) {
      run("/usr/bin/hdiutil", ["detach", mountPoint], { capture: true });
    }
    rmSync(workRoot, { recursive: true, force: true });
  }
  run("/usr/bin/codesign", [
    "--force",
    "--sign",
    identity.fingerprint,
    "--timestamp",
    targetPath,
  ]);
  verifyDeveloperIdDiskImageSignature(targetPath, identity);
  run("/usr/bin/hdiutil", ["verify", targetPath], {
    capture: true,
  });
}

function verifyDistributionDiskImage(identity, targetPath) {
  const mountPoint = mkdtempSync(path.join(tmpdir(), "metawork-dmg-mount-"));
  let attached = false;
  try {
    run(
      "/usr/bin/hdiutil",
      [
        "attach",
        "-readonly",
        "-nobrowse",
        "-mountpoint",
        mountPoint,
        targetPath,
      ],
      { capture: true },
    );
    attached = true;
    const expectedAppName = `${localPackageMetadata.displayName}.app`;
    const entries = readdirSync(mountPoint);
    if (
      entries.sort().join("\n") !==
      [".DS_Store", "Applications", expectedAppName].sort().join("\n")
    ) {
      throw new Error(`DMG has unexpected root entries: ${entries.join(", ")}`);
    }
    const applicationsLink = path.join(mountPoint, "Applications");
    if (
      !lstatSync(applicationsLink).isSymbolicLink() ||
      readlinkSync(applicationsLink) !== "/Applications"
    ) {
      throw new Error(
        "DMG Applications entry is not an exact /Applications symlink",
      );
    }
    verifyDeveloperIdSignature(
      path.join(mountPoint, expectedAppName),
      identity,
      undefined,
      { deep: true },
    );
  } finally {
    if (attached) {
      run("/usr/bin/hdiutil", ["detach", mountPoint], { capture: true });
    }
    rmSync(mountPoint, { recursive: true, force: true });
  }
}

function notarizeDiskImage(identity, distributionDiskImagePath) {
  const result = run(
    "/usr/bin/xcrun",
    [
      "notarytool",
      "submit",
      distributionDiskImagePath,
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

  run("/usr/bin/xcrun", ["stapler", "staple", "-v", distributionDiskImagePath]);
  run("/usr/bin/xcrun", [
    "stapler",
    "validate",
    "-v",
    distributionDiskImagePath,
  ]);
  run("/usr/sbin/spctl", [
    "--assess",
    "--type",
    "open",
    "--context",
    "context:primary-signature",
    "--verbose=4",
    distributionDiskImagePath,
  ]);
  run("/usr/bin/hdiutil", ["verify", distributionDiskImagePath], {
    capture: true,
  });
  verifyDeveloperIdDiskImageSignature(distributionDiskImagePath, identity);
  verifyDistributionDiskImage(identity, distributionDiskImagePath);

  const digest = createHash("sha256")
    .update(readFileSync(distributionDiskImagePath))
    .digest("hex");
  return { artifactPath: distributionDiskImagePath, digest, submission };
}

function buildPackagedMacosApp(identity, distribution) {
  runNode("scripts/build.mjs", ["release", distribution.targetId]);
  rmSync(packagedAppPath, { recursive: true, force: true });
  runNative([
    "package",
    "--target",
    "macos",
    "--assets",
    "frontend/dist",
    "--signing",
    "none",
  ]);
  stageMacosTrayIcon();
  verifyPackagedMacosExecutableArchitecture(distribution.executable);
  signWithDeveloperId(packagedAppPath, identity, {
    preserveEntitlements: true,
  });
  return verifyPackagedMacosApp(identity);
}

async function packageMacos(selection) {
  requireMacos();
  const distributions = macosPackageTargetIds(selection).map(
    macosDistributionForAgentCoreTarget,
  );
  for (const distribution of distributions) {
    await verifyStagedAgentCoreBundle(repositoryRoot, {
      targetId: distribution.targetId,
    });
  }
  for (const distribution of distributions) {
    rmSync(distribution.diskImagePath, { force: true });
  }
  const identity = resolveDistributionIdentity();
  for (const distribution of distributions) {
    const signature = buildPackagedMacosApp(identity, distribution);
    createDistributionDiskImage(identity, distribution.diskImagePath);
    const notarized = notarizeDiskImage(identity, distribution.diskImagePath);
    console.log(
      `built Developer ID signed and notarized ${distribution.artifact} package ${packagedAppPath} (${signature.policy})`,
    );
    console.log(
      `Apple notarization ${notarized.submission.id} accepted; final DMG ${notarized.artifactPath} (sha256=${notarized.digest})`,
    );
  }
}

async function main() {
  if (process.argv.length > 3) {
    throw new Error("usage: npm run package:macos -- [arm64|x64|all]");
  }
  await packageMacos(process.argv[2] ?? "all");
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (invokedPath === import.meta.url) {
  try {
    await main();
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
