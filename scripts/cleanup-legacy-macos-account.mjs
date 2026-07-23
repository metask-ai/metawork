import { spawnSync } from "node:child_process";
import { existsSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const loginKeychainPath = path.join(
  homedir(),
  "Library",
  "Keychains",
  "login.keychain-db",
);

export const legacyMacosAccountPersistence = Object.freeze({
  service: "dev.metawork.account.v2",
  accounts: Object.freeze([
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
  ]),
  manifestPath: path.join(
    homedir(),
    "Library",
    "Application Support",
    "MetaWork",
    "account",
    "manifest.v2",
  ),
});

function requireMacos() {
  if (process.platform !== "darwin") {
    throw new Error(
      "legacy MetaWork Account cleanup is only available on macOS",
    );
  }
}

function combinedOutput(result) {
  return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

export function isMissingKeychainItem(result) {
  return result.status === 44;
}

function deleteLegacyCredential(account) {
  const result = spawnSync(
    "/usr/bin/security",
    [
      "delete-generic-password",
      "-s",
      legacyMacosAccountPersistence.service,
      "-a",
      account,
      loginKeychainPath,
    ],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: "pipe",
    },
  );
  if (result.error) throw result.error;
  if (result.status === 0) return true;
  if (isMissingKeychainItem(result)) return false;
  throw new Error(
    `security delete-generic-password failed for legacy account ${account} with exit code ${result.status}\n${combinedOutput(result).trim()}`,
  );
}

function cleanupLegacyAccountPersistence() {
  requireMacos();
  let removedCredentials = 0;
  for (const account of legacyMacosAccountPersistence.accounts) {
    if (deleteLegacyCredential(account)) removedCredentials += 1;
  }
  const removedManifest = existsSync(
    legacyMacosAccountPersistence.manifestPath,
  );
  if (removedManifest) unlinkSync(legacyMacosAccountPersistence.manifestPath);
  console.log(
    `Removed ${removedCredentials} legacy Keychain item(s) and ${removedManifest ? "the" : "no"} legacy manifest. Current macOS Account storage was not modified.`,
  );
}

const invokedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (invokedPath === import.meta.url) {
  try {
    if (process.argv.length !== 2) {
      throw new Error("usage: node scripts/cleanup-legacy-macos-account.mjs");
    }
    cleanupLegacyAccountPersistence();
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
