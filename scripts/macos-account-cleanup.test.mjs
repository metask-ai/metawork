import assert from "node:assert/strict";
import test from "node:test";

import {
  isMissingKeychainItem,
  legacyMacosAccountPersistence,
} from "./cleanup-legacy-macos-account.mjs";

test("legacy macOS Account cleanup owns the exact retired persistence set", () => {
  assert.equal(
    legacyMacosAccountPersistence.service,
    "dev.metawork.account.v2",
  );
  assert.deepEqual(legacyMacosAccountPersistence.accounts, [
    "oauth/A/access",
    "oauth/A/refresh",
    "oauth/A/marker",
    "oauth/B/access",
    "oauth/B/refresh",
    "oauth/B/marker",
    "execution/A/api-key",
    "execution/A/marker",
    "execution/B/api-key",
    "execution/B/marker",
  ]);
  assert.match(legacyMacosAccountPersistence.manifestPath, /manifest\.v2$/u);
});

test("legacy macOS Account cleanup treats only Keychain item-not-found as idempotent", () => {
  assert.equal(
    isMissingKeychainItem({
      status: 44,
      stderr:
        "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n",
    }),
    true,
  );
  assert.equal(
    isMissingKeychainItem({ status: 45, stderr: "permission denied" }),
    false,
  );
});
