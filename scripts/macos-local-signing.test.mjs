import assert from "node:assert/strict";
import test from "node:test";

import {
  buildAppleDevelopmentRequirement,
  buildCanonicalDesignatedRequirement,
  buildDeveloperIdRequirement,
  buildDmgFinderLayoutScript,
  isAppleDevelopmentIdentityName,
  isDeveloperIdApplicationIdentityName,
  localDistributionDiskImageName,
  localPackageMetadata,
  localProductIdentity,
  parseCodeDirectoryIdentifier,
  parseCodeSigningIdentities,
  parseDeveloperIdCertificateReport,
  parseDesignatedRequirement,
  parseLocalSigningConfig,
  parseNativeProductIdentity,
  parseNativePackageMetadata,
  parseNotarySubmission,
  parseTeamIdentifier,
  selectDistributionCodeSigningIdentity,
  selectLocalCodeSigningIdentity,
  validateCanonicalDesignatedRequirement,
} from "./macos-local-signing.mjs";
import { xcodeContentsForDeveloperDirectory } from "./setup-macos-local-signing.mjs";

const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const secondFingerprint = "FEDCBA9876543210FEDCBA9876543210FEDCBA98";
const certificateSuffix = "6L6UHLW8L7";
const teamId = "Z4T2BLNJ8X";
const identityName = `Apple Development: developer@example.com (${certificateSuffix})`;
const distributionIdentityName = `Developer ID Application: Developer Name (${teamId})`;

test("local signing reads the existing Native product identity", () => {
  assert.deepEqual(localProductIdentity, {
    bundleId: "com.metask.metawork.dev",
    executableName: "metawork",
  });
  assert.deepEqual(
    parseNativeProductIdentity(
      `.{\n.id = "example.product.dev",\n.name = "product",\n}`,
    ),
    { bundleId: "example.product.dev", executableName: "product" },
  );
  assert.throws(
    () =>
      parseNativeProductIdentity(`.{ .id = "invalid", .name = "bad name" }`),
    /invalid native product identity/u,
  );
});

test("distribution DMG metadata comes from the Native product manifest", () => {
  assert.deepEqual(localPackageMetadata, {
    displayName: "MetaWork",
    version: "0.1.1",
  });
  assert.equal(
    localDistributionDiskImageName,
    "metawork-0.1.1-macos-arm64.dmg",
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

test("distribution DMG Finder layout presents left-to-right installation", () => {
  const script = buildDmgFinderLayoutScript('/tmp/layout "target"');
  assert.match(script, /set targetWindow to front window/u);
  assert.equal(
    script.match(/bounds of targetWindow to \{100, 100, 760, 500\}/gu)?.length,
    2,
  );
  assert.match(script, /bounds of targetWindow to \{100, 100, 760, 500\}/u);
  assert.match(script, /position of item "MetaWork\.app".*\{170, 190\}/u);
  assert.match(script, /position of item "Applications".*\{490, 190\}/u);
  assert.match(script, /POSIX file "\/tmp\/layout \\"target\\""/u);
  assert.throws(
    () => buildDmgFinderLayoutScript("/tmp/invalid\0path"),
    /contains NUL/u,
  );
});

test("local signing identity selection accepts one Apple Development identity", () => {
  const output = `
  1) ${fingerprint} "${identityName}"
     1 valid identities found
`;
  assert.deepEqual(parseCodeSigningIdentities(output), [
    { fingerprint, name: identityName },
  ]);
  assert.equal(isAppleDevelopmentIdentityName(identityName), true);
  assert.deepEqual(selectLocalCodeSigningIdentity(output), {
    fingerprint,
    name: identityName,
  });
});

test("identity display-name suffix is not treated as TeamIdentifier", () => {
  assert.notEqual(certificateSuffix, teamId);
  const config = {
    schemaVersion: 1,
    fingerprint,
    name: identityName,
    teamId,
  };
  assert.deepEqual(parseLocalSigningConfig(JSON.stringify(config)), config);
});

test("local signing identity selection rejects self-signed, missing, and ambiguous identities", () => {
  const selfSigned = `1) ${fingerprint} "MetaWork Local Development"`;
  assert.throws(
    () => selectLocalCodeSigningIdentity(selfSigned),
    /Apple Development.*found 0/u,
  );
  assert.throws(
    () => selectLocalCodeSigningIdentity("0 valid identities found"),
    /found 0/u,
  );
  const duplicate = `
  1) ${fingerprint} "${identityName}"
  2) ${secondFingerprint} "Apple Development: Second Developer (A1B2C3D4E5)"
     2 valid identities found
`;
  assert.throws(() => selectLocalCodeSigningIdentity(duplicate), /found 2/u);
  assert.deepEqual(selectLocalCodeSigningIdentity(duplicate, fingerprint), {
    fingerprint,
    name: identityName,
  });
});

test("distribution signing selects only one Developer ID Application identity", () => {
  const output = `
  1) ${fingerprint} "${identityName}"
  2) ${secondFingerprint} "${distributionIdentityName}"
     2 valid identities found
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
        `1) ${fingerprint} "${identityName}"`,
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

test("local signing selection config has one strict schema", () => {
  const config = {
    schemaVersion: 1,
    fingerprint,
    name: identityName,
    teamId,
  };
  assert.deepEqual(parseLocalSigningConfig(JSON.stringify(config)), config);
  assert.throws(() => parseLocalSigningConfig("not json"), /not valid JSON/u);
  assert.throws(
    () => parseLocalSigningConfig(JSON.stringify({ ...config, extra: true })),
    /invalid schema/u,
  );
  assert.throws(
    () =>
      parseLocalSigningConfig(
        JSON.stringify({ ...config, name: "MetaWork Local Development" }),
      ),
    /invalid schema/u,
  );
  assert.throws(
    () =>
      parseLocalSigningConfig(JSON.stringify({ ...config, teamId: "not set" })),
    /invalid schema/u,
  );
});

test("signature report requires an Apple-issued TeamIdentifier", () => {
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

test("designated requirement parser rejects unstable CDHash identity", () => {
  const report = `
Identifier=${localProductIdentity.bundleId}
designated => cdhash H"0123456789abcdef"
`;
  assert.equal(
    parseCodeDirectoryIdentifier(report),
    localProductIdentity.bundleId,
  );
  assert.throws(() => parseDesignatedRequirement(report), /unstable CDHash/u);
});

test("designated requirement parsing does not depend on Apple's textual certificate chain", () => {
  const requirement = `designated => identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.CN] = "${identityName}" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`;
  const report = `Identifier=${localProductIdentity.bundleId}\n${requirement}\n`;
  assert.equal(parseDesignatedRequirement(report), requirement);
  assert.equal(
    parseDesignatedRequirement(
      `${requirement} and certificate 1[subject.OU] = "Apple Worldwide Developer Relations"`,
    ),
    `${requirement} and certificate 1[subject.OU] = "Apple Worldwide Developer Relations"`,
  );
  assert.throws(
    () => parseDesignatedRequirement("Identifier=missing"),
    /contained 0 designated requirements/u,
  );
  assert.throws(
    () =>
      parseDesignatedRequirement(
        `${requirement}\ndesignated => identifier "duplicate"`,
      ),
    /contained 2 designated requirements/u,
  );
});

test("canonical designated requirement validation rejects every other embedded policy", () => {
  const canonical = buildCanonicalDesignatedRequirement(
    localProductIdentity.bundleId,
    teamId,
    identityName,
  );
  assert.equal(
    validateCanonicalDesignatedRequirement(
      `Identifier=${localProductIdentity.bundleId}\n${canonical}\n`,
      canonical,
    ),
    canonical,
  );
  for (const weak of [
    "designated => true",
    `designated => identifier "${localProductIdentity.bundleId}" or true`,
    `designated => identifier "${localProductIdentity.bundleId}"`,
  ]) {
    assert.throws(
      () => validateCanonicalDesignatedRequirement(weak, canonical),
      /not the canonical MetaWork requirement/u,
    );
  }
});

test("Apple Development verification policy binds identifier, Apple anchor, Team, and certificate", () => {
  assert.equal(
    buildAppleDevelopmentRequirement(
      localProductIdentity.bundleId,
      teamId,
      identityName,
    ),
    `identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${identityName}"`,
  );
  assert.throws(
    () => buildAppleDevelopmentRequirement("invalid", teamId, identityName),
    /invalid identity metadata/u,
  );
  assert.throws(
    () =>
      buildAppleDevelopmentRequirement(
        localProductIdentity.bundleId,
        teamId,
        'Apple Development: invalid "name"',
      ),
    /invalid identity metadata/u,
  );
  assert.equal(
    buildCanonicalDesignatedRequirement(
      localProductIdentity.bundleId,
      teamId,
      identityName,
    ),
    `designated => identifier "${localProductIdentity.bundleId}" and anchor apple generic and certificate leaf[subject.OU] = ${teamId} and certificate leaf[subject.CN] = "${identityName}"`,
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
        identityName,
      ),
    /invalid identity metadata/u,
  );
});

test("Xcode WWDR lookup follows the selected developer directory", () => {
  assert.equal(
    xcodeContentsForDeveloperDirectory(
      "/Applications/Xcode-beta.app/Contents/Developer",
    ),
    "/Applications/Xcode-beta.app/Contents",
  );
  assert.equal(
    xcodeContentsForDeveloperDirectory("/Library/Developer/CommandLineTools"),
    null,
  );
});
