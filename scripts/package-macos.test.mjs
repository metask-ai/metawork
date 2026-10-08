import assert from "node:assert/strict";
import { readFileSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildDeveloperIdRequirement,
  buildDmgFinderLayoutScript,
  isDeveloperIdApplicationIdentityName,
  localPackageMetadata,
  localProductIdentity,
  macosDistributionForAgentCoreTarget,
  macosPackageTargetIds,
  parseDeveloperIdCertificateReport,
  parseNativePackageMetadata,
  parseNotarySubmission,
  parseTeamIdentifier,
  requireSingleMacosExecutableArchitecture,
  selectDistributionCodeSigningIdentity,
  stageMacosTrayIcon,
  stageMacosMinimumSystemVersion,
  verifyMacosMinimumSystemVersion,
} from "./package-macos.mjs";

const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const secondFingerprint = "FEDCBA9876543210FEDCBA9876543210FEDCBA98";
const teamId = "Z4T2BLNJ8X";
const distributionIdentityName = `Developer ID Application: Developer Name (${teamId})`;

test("distribution DMG metadata comes from the Native product manifest", () => {
  assert.deepEqual(localPackageMetadata, {
    displayName: "MetaWork",
    version: "0.2.0",
  });
  assert.deepEqual(macosDistributionForAgentCoreTarget("aarch64-macos"), {
    artifact: "arm64",
    diskImageName: "metawork-0.2.0-macos-arm64.dmg",
    diskImagePath: fileURLToPath(
      new URL(
        "../zig-out/package/metawork-0.2.0-macos-arm64.dmg",
        import.meta.url,
      ),
    ),
    executable: "arm64",
    targetId: "aarch64-macos",
  });
  assert.equal(
    macosDistributionForAgentCoreTarget("x86_64-macos").diskImageName,
    "metawork-0.2.0-macos-x64.dmg",
  );
  assert.throws(
    () => macosDistributionForAgentCoreTarget("x86_64-windows-gnu"),
    /unsupported macOS package target/u,
  );
  assert.deepEqual(
    parseNativePackageMetadata(
      `.{\n.display_name = "ExampleApp",\n.version = "1.2.3-beta.1",\n}`,
    ),
    { displayName: "ExampleApp", version: "1.2.3-beta.1" },
  );
  assert.throws(
    () =>
      parseNativePackageMetadata(
        `.{\n.display_name = "bad name",\n.version = "latest",\n}`,
      ),
    /invalid native package metadata/u,
  );
});

test("macOS package selection is explicit and defaults to both architectures", () => {
  assert.deepEqual(macosPackageTargetIds(), ["aarch64-macos", "x86_64-macos"]);
  assert.deepEqual(macosPackageTargetIds("all"), [
    "aarch64-macos",
    "x86_64-macos",
  ]);
  assert.deepEqual(macosPackageTargetIds("arm64"), ["aarch64-macos"]);
  assert.deepEqual(macosPackageTargetIds("x64"), ["x86_64-macos"]);
  assert.throws(
    () => macosPackageTargetIds("universal"),
    /expected arm64, x64, or all/u,
  );
});

test(
  "packaged minimum macOS version replaces the SDK default and rejects drift",
  {
    skip: process.platform !== "darwin",
  },
  async () => {
    const appPath = await mkdtemp(path.join(tmpdir(), "metawork-minimum-os-"));
    try {
      mkdirSync(path.join(appPath, "Contents", "MacOS"), { recursive: true });
      const executable = Buffer.alloc(56);
      executable.writeUInt32LE(0xfeedfacf, 0);
      executable.writeUInt32LE(1, 16);
      executable.writeUInt32LE(24, 20);
      executable.writeUInt32LE(0x32, 32);
      executable.writeUInt32LE(24, 36);
      executable.writeUInt32LE(1, 40);
      executable.writeUInt32LE(13 << 16, 44);
      writeFileSync(
        path.join(
          appPath,
          "Contents",
          "MacOS",
          localProductIdentity.executableName,
        ),
        executable,
      );
      const plistPath = path.join(appPath, "Contents", "Info.plist");
      writeFileSync(
        plistPath,
        '<?xml version="1.0"?><plist version="1.0"><dict><key>LSMinimumSystemVersion</key><string>11.0</string><key>CFBundleName</key><string>MetaWork</string></dict></plist>',
      );
      assert.equal(stageMacosMinimumSystemVersion(appPath), "13.0");
      assert.equal(verifyMacosMinimumSystemVersion(appPath), "13.0");
      assert.equal(
        execFileSync(
          "/usr/bin/plutil",
          ["-extract", "CFBundleName", "raw", "-o", "-", plistPath],
          { encoding: "utf8" },
        ).trim(),
        "MetaWork",
      );
      execFileSync("/usr/bin/plutil", [
        "-replace",
        "LSMinimumSystemVersion",
        "-string",
        "11.0",
        plistPath,
      ]);
      assert.throws(
        () => verifyMacosMinimumSystemVersion(appPath),
        /LSMinimumSystemVersion is 11\.0, expected 13\.0/u,
      );
    } finally {
      rmSync(appPath, { recursive: true, force: true });
    }
  },
);

test("macOS package architecture gate rejects mislabeled and universal executables", () => {
  assert.equal(
    requireSingleMacosExecutableArchitecture(
      "Non-fat file: metawork is architecture: x86_64\n",
      "x86_64",
    ),
    "x86_64",
  );
  assert.equal(
    requireSingleMacosExecutableArchitecture(
      "Non-fat file: metawork is architecture: arm64\n",
      "arm64",
    ),
    "arm64",
  );
  assert.throws(
    () =>
      requireSingleMacosExecutableArchitecture(
        "Non-fat file: metawork is architecture: arm64\n",
        "x86_64",
      ),
    /expected only x86_64/u,
  );
  assert.throws(
    () =>
      requireSingleMacosExecutableArchitecture(
        "Architectures in the fat file: metawork are: x86_64 arm64\n",
        "x86_64",
      ),
    /expected only x86_64/u,
  );
});

test("macOS packaging stages the tray icon at its runtime-relative bundle path", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "metawork-tray-icon-"));
  try {
    const source = new URL("../assets/icons/tray-icon.png", import.meta.url);
    const target = path.join(
      root,
      "MetaWork.app",
      "Contents",
      "Resources",
      "assets",
      "icons",
      "tray-icon.png",
    );
    assert.equal(stageMacosTrayIcon(source, target), target);
    assert.deepEqual(readFileSync(target), readFileSync(source));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("macOS packaging has one public owner and signs only after resource staging", () => {
  const packageScript = readFileSync(
    new URL("./package-macos.mjs", import.meta.url),
    "utf8",
  );
  const packageJson = JSON.parse(
    readFileSync(new URL("../package.json", import.meta.url), "utf8"),
  );
  assert.equal(
    packageJson.scripts["package:macos"],
    "node scripts/package-macos.mjs",
  );
  assert.match(
    packageScript,
    /runNode\("scripts\/build\.mjs", \["release", distribution\.targetId\]\)/u,
  );
  assert.match(packageScript, /"--signing",\s*\n\s*"none"/u);
  const appIconStagingIndex = packageScript.indexOf(
    "stageMacosAppIcon(appIconArtifact, packagedAppPath);",
  );
  const minimumVersionStagingIndex = packageScript.indexOf(
    "stageMacosMinimumSystemVersion(packagedAppPath);",
  );
  const stagingIndex = packageScript.indexOf("stageMacosTrayIcon();");
  const agentCoreStagingIndex = packageScript.indexOf(
    "await stageAgentCoreRuntimeAssets(",
  );
  const agentCoreVerificationIndex = packageScript.indexOf(
    "await verifyAgentCoreRuntimeAssets(",
  );
  const licenseResourceIndex = packageScript.indexOf(
    '"Resources",\n      "licenses",',
  );
  const ripgrepSigningIndex = packageScript.indexOf(
    "signWithDeveloperId(ripgrepPath",
  );
  const architectureIndex = packageScript.indexOf(
    "verifyPackagedMacosExecutableArchitecture(distribution.executable);",
  );
  const signingIndex = packageScript.indexOf(
    "signWithDeveloperId(packagedAppPath",
  );
  const sectionCaptureIndex = packageScript.indexOf(
    "const executableSections = macosExecutableSections(",
  );
  const sectionVerificationIndex = packageScript.indexOf(
    "  verifyMacosExecutableSections(",
    signingIndex,
  );
  assert.notEqual(appIconStagingIndex, -1);
  assert.notEqual(stagingIndex, -1);
  assert.notEqual(agentCoreStagingIndex, -1);
  assert.notEqual(agentCoreVerificationIndex, -1);
  assert.notEqual(licenseResourceIndex, -1);
  assert.notEqual(ripgrepSigningIndex, -1);
  assert.notEqual(architectureIndex, -1);
  assert.notEqual(signingIndex, -1);
  assert.notEqual(minimumVersionStagingIndex, -1);
  assert.ok(minimumVersionStagingIndex < signingIndex);
  assert.notEqual(sectionCaptureIndex, -1);
  assert.notEqual(sectionVerificationIndex, -1);
  assert.ok(sectionCaptureIndex < appIconStagingIndex);
  assert.ok(signingIndex < sectionVerificationIndex);
  assert.ok(
    sectionVerificationIndex <
      packageScript.indexOf("    ...verifyPackagedMacosApp("),
  );
  assert.ok(appIconStagingIndex < stagingIndex);
  assert.ok(stagingIndex < agentCoreStagingIndex);
  assert.ok(licenseResourceIndex < agentCoreStagingIndex);
  assert.ok(agentCoreStagingIndex < agentCoreVerificationIndex);
  assert.ok(agentCoreVerificationIndex < ripgrepSigningIndex);
  assert.ok(ripgrepSigningIndex < signingIndex);
  assert.ok(appIconStagingIndex < architectureIndex);
  assert.ok(appIconStagingIndex < signingIndex);
  assert.ok(stagingIndex < signingIndex);
  assert.ok(stagingIndex < architectureIndex);
  assert.ok(architectureIndex < signingIndex);
  assert.doesNotMatch(packageScript, /previewMacosPackage|legacyPackage/u);
});

test("final DMG verification preserves the original build section baseline", () => {
  const packageScript = readFileSync(
    new URL("./package-macos.mjs", import.meta.url),
    "utf8",
  );
  const diskImageVerification = packageScript.slice(
    packageScript.indexOf("function verifyDistributionDiskImage("),
    packageScript.indexOf("function notarizeDiskImage("),
  );
  assert.match(diskImageVerification, /"attach",\s*"-readonly"/u);
  assert.match(
    diskImageVerification,
    /verifyMacosExecutableSections\(\s*executableSections,\s*readFileSync\(\s*path\.join\(\s*mountPoint,/u,
  );
  assert.match(
    diskImageVerification,
    /verifyMacosMinimumSystemVersion\(path\.join\(mountPoint, expectedAppName\)\)/u,
  );
  assert.match(
    packageScript,
    /verifyDistributionDiskImage\(\s*identity,\s*distributionDiskImagePath,\s*executableSections,/u,
  );
  assert.match(
    packageScript,
    /notarizeDiskImage\(\s*identity,\s*distribution\.diskImagePath,\s*signature\.executableSections,/u,
  );
});

test("distribution DMG Finder layout presents left-to-right installation", () => {
  const script = buildDmgFinderLayoutScript('/tmp/layout "target"');
  assert.match(script, /set targetWindow to front window/u);
  assert.equal(
    script.match(/bounds of targetWindow to \{100, 100, 700, 440\}/gu)?.length,
    2,
  );
  assert.match(script, /bounds of targetWindow to \{100, 100, 700, 440\}/u);
  assert.match(script, /position of item "MetaWork\.app".*\{165, 135\}/u);
  assert.match(script, /position of item "Applications".*\{435, 135\}/u);
  assert.match(script, /POSIX file "\/tmp\/layout \\"target\\""/u);
  assert.throws(
    () => buildDmgFinderLayoutScript("/tmp/invalid\0path"),
    /contains NUL/u,
  );
});

test("distribution signing selects only one Developer ID Application identity", () => {
  const output = `
  1) ${secondFingerprint} "${distributionIdentityName}"
     1 valid identities found
`;
  assert.equal(
    isDeveloperIdApplicationIdentityName(distributionIdentityName),
    true,
  );
  assert.deepEqual(selectDistributionCodeSigningIdentity(output), {
    fingerprint: secondFingerprint,
    name: distributionIdentityName,
  });
  assert.throws(
    () =>
      selectDistributionCodeSigningIdentity(
        `1) ${fingerprint} "Apple Distribution: Developer Name (${teamId})"`,
      ),
    /Developer ID Application.*found 0/u,
  );
  assert.throws(
    () =>
      selectDistributionCodeSigningIdentity(
        `${output}\n3) ${fingerprint} "Developer ID Application: Second Developer (${teamId})"`,
      ),
    /found 2/u,
  );
});

test("Developer ID certificate metadata binds the selected fingerprint and Team ID", () => {
  assert.deepEqual(
    parseDeveloperIdCertificateReport(
      `sha1 Fingerprint=01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67\nsubject=CN=${distributionIdentityName},OU=${teamId},O=Developer Name,C=US\n`,
    ),
    { fingerprint, teamId },
  );
  assert.throws(
    () => parseDeveloperIdCertificateReport("subject=CN=missing metadata"),
    /did not contain/u,
  );
});

test("notary submission parser accepts only a typed terminal result", () => {
  const id = "12345678-1234-4abc-8def-1234567890ab";
  assert.deepEqual(
    parseNotarySubmission(
      JSON.stringify({
        id,
        message: "Processing complete",
        status: "Accepted",
      }),
    ),
    { id, status: "Accepted" },
  );
  assert.deepEqual(
    parseNotarySubmission(JSON.stringify({ id, status: "Invalid" })),
    { id, status: "Invalid" },
  );
  assert.throws(() => parseNotarySubmission("not json"), /not valid JSON/u);
  assert.throws(
    () =>
      parseNotarySubmission(JSON.stringify({ id: "bad", status: "Accepted" })),
    /invalid shape/u,
  );
  assert.throws(
    () => parseNotarySubmission(JSON.stringify({ id, status: "Unknown" })),
    /invalid shape/u,
  );
});

test("Developer ID signature report requires an Apple-issued TeamIdentifier", () => {
  assert.equal(parseTeamIdentifier(`TeamIdentifier=${teamId}\n`), teamId);
  assert.throws(
    () => parseTeamIdentifier("TeamIdentifier=not set\n"),
    /no Apple-issued Team Identifier/u,
  );
  assert.throws(
    () => parseTeamIdentifier(`Identifier=${localProductIdentity.bundleId}\n`),
    /did not contain TeamIdentifier/u,
  );
});

test("Developer ID verification policy binds identifier, Apple anchor, Team, and certificate", () => {
  assert.equal(
    buildDeveloperIdRequirement(
      localProductIdentity.bundleId,
      teamId,
      distributionIdentityName,
    ),
    `identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${distributionIdentityName}"`,
  );
  assert.throws(
    () =>
      buildDeveloperIdRequirement(
        localProductIdentity.bundleId,
        teamId,
        `Apple Distribution: Developer Name (${teamId})`,
      ),
    /invalid identity metadata/u,
  );
});
