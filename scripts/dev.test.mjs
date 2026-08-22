import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  buildAppleDevelopmentRequirement,
  buildCanonicalDesignatedRequirement,
  isAppleDevelopmentIdentityName,
  localProductIdentity,
  parseCodeDirectoryIdentifier,
  parseCodeSigningIdentities,
  parseDesignatedRequirement,
  parseLocalSigningConfig,
  parseNativeProductIdentity,
  parseTeamIdentifier,
  selectLocalCodeSigningIdentity,
  validateCanonicalDesignatedRequirement,
} from "./dev.mjs";
import { xcodeContentsForDeveloperDirectory } from "./setup-macos-local-signing.mjs";

const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const secondFingerprint = "FEDCBA9876543210FEDCBA9876543210FEDCBA98";
const certificateSuffix = "6L6UHLW8L7";
const teamId = "Z4T2BLNJ8X";
const identityName = `Apple Development: developer@example.com (${certificateSuffix})`;

test("development signing reads the existing Native product identity", () => {
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

test("development has one cross-platform public entry", () => {
  const packageJson = JSON.parse(
    readFileSync(new URL("../package.json", import.meta.url), "utf8"),
  );
  assert.equal(packageJson.scripts.dev, "node scripts/dev.mjs");
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

test("development signature requires an Apple-issued TeamIdentifier", () => {
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
