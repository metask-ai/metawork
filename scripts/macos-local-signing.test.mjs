import assert from "node:assert/strict";
import test from "node:test";

import {
  isAppleDevelopmentIdentityName,
  localProductIdentity,
  parseCodeDirectoryIdentifier,
  parseCodeSigningIdentities,
  parseLocalSigningConfig,
  parseNativeProductIdentity,
  parseTeamIdentifier,
  selectLocalCodeSigningIdentity,
  validateDesignatedRequirement,
} from "./macos-local-signing.mjs";

const fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567";
const secondFingerprint = "FEDCBA9876543210FEDCBA9876543210FEDCBA98";
const certificateSuffix = "6L6UHLW8L7";
const teamId = "Z4T2BLNJ8X";
const identityName = `Apple Development: developer@example.com (${certificateSuffix})`;

test("local signing reads the existing Native product identity", () => {
  assert.deepEqual(localProductIdentity, {
    bundleId: "dev.metawork.desktop",
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

test("stable signature validation rejects ad-hoc CDHash identity", () => {
  const report = `
Identifier=${localProductIdentity.bundleId}
designated => cdhash H"0123456789abcdef"
`;
  assert.equal(
    parseCodeDirectoryIdentifier(report),
    localProductIdentity.bundleId,
  );
  assert.throws(
    () => validateDesignatedRequirement(report, localProductIdentity.bundleId),
    /changing CDHash/u,
  );
});

test("stable signature validation accepts Apple chain and exact identifier", () => {
  const requirement = `designated => identifier "${localProductIdentity.bundleId}" and anchor apple generic`;
  const report = `Identifier=${localProductIdentity.bundleId}\n${requirement}\n`;
  assert.equal(
    validateDesignatedRequirement(report, localProductIdentity.bundleId),
    requirement,
  );
  assert.throws(
    () => validateDesignatedRequirement(report, "com.metask.metawork.beta"),
    /does not bind identifier/u,
  );
  assert.throws(
    () =>
      validateDesignatedRequirement(
        `designated => identifier "${localProductIdentity.bundleId}" and certificate leaf = H"0123"`,
        localProductIdentity.bundleId,
      ),
    /not anchored to the Apple signing chain/u,
  );
});
