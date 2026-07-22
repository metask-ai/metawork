import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readdir, readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  localProductIdentity,
  resolveIdentity,
  verifyStableSignature,
} from "./macos-local-signing.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const sourceAssets = path.join(repositoryRoot, "frontend", "dist");
const appRoot = path.join(repositoryRoot, "zig-out", "package", "metawork.app");
const appManifestPath = path.join(repositoryRoot, "app.zon");
const packagedAssets = path.join(
  appRoot,
  "Contents",
  "Resources",
  "frontend",
  "dist",
);

async function regularFiles(root, directory = root) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await regularFiles(root, absolutePath)));
    } else if (entry.isFile()) {
      files.push(path.relative(root, absolutePath));
    }
  }
  return files.sort();
}

async function digest(filePath) {
  return createHash("sha256")
    .update(await readFile(filePath))
    .digest("hex");
}

const sourceFiles = await regularFiles(sourceAssets);
const packagedFiles = (await regularFiles(packagedAssets)).filter(
  (file) => file !== "asset-manifest.zon",
);

if (JSON.stringify(sourceFiles) !== JSON.stringify(packagedFiles)) {
  throw new Error(
    `packaged Renderer file set differs from frontend/dist\nsource=${JSON.stringify(sourceFiles)}\npackage=${JSON.stringify(packagedFiles)}`,
  );
}

for (const relativePath of sourceFiles) {
  const sourceDigest = await digest(path.join(sourceAssets, relativePath));
  const packageDigest = await digest(path.join(packagedAssets, relativePath));
  if (sourceDigest !== packageDigest) {
    throw new Error(`packaged Renderer asset differs: ${relativePath}`);
  }
}

const executablePath = path.join(appRoot, "Contents", "MacOS", "metawork");
if ((await stat(executablePath)).size === 0) {
  throw new Error(`packaged executable is empty: ${executablePath}`);
}

const appManifest = await readFile(appManifestPath, "utf8");
const versionMatch = appManifest.match(/^\s*\.version = "([^"]+)",?$/mu);
if (!versionMatch) {
  throw new Error("app.zon does not contain one parseable product version");
}

const infoPlistPath = path.join(appRoot, "Contents", "Info.plist");
function plistValue(key) {
  return execFileSync(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", infoPlistPath],
    { encoding: "utf8" },
  ).trim();
}

const expectedMetadata = new Map([
  ["CFBundleIdentifier", localProductIdentity.bundleId],
  ["CFBundleExecutable", localProductIdentity.executableName],
  ["CFBundleDisplayName", "MetaWork"],
  ["CFBundleShortVersionString", versionMatch[1]],
]);
for (const [key, expected] of expectedMetadata) {
  const actual = plistValue(key);
  if (actual !== expected) {
    throw new Error(`Info.plist ${key} is ${actual}, expected ${expected}`);
  }
}

const identity = resolveIdentity();
const signature = verifyStableSignature(
  appRoot,
  localProductIdentity.bundleId,
  {
    deep: true,
    expectedIdentityName: identity.name,
    expectedTeamId: identity.teamId,
  },
);

console.log(
  `verified macOS package executable, metadata, stable requirement, and ${sourceFiles.length} exact Renderer assets (${signature.requirement})`,
);
