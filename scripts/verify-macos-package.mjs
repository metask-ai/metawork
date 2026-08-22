import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readdir, readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  localProductIdentity,
  resolveDistributionIdentity,
  verifyDeveloperIdSignature,
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
const sourceTrayIconPath = path.join(
  repositoryRoot,
  "assets",
  "icons",
  "tray-icon.png",
);
const packagedTrayIconPath = path.join(
  appRoot,
  "Contents",
  "Resources",
  "assets",
  "icons",
  "tray-icon.png",
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

function pngDimensions(bytes) {
  const signature = "89504e470d0a1a0a";
  if (
    bytes.length < 24 ||
    bytes.subarray(0, 8).toString("hex") !== signature ||
    bytes.subarray(12, 16).toString("ascii") !== "IHDR"
  ) {
    throw new Error("macOS tray icon is not a valid PNG header");
  }
  return {
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20),
  };
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

const sourceTrayIcon = await readFile(sourceTrayIconPath);
const packagedTrayIcon = await readFile(packagedTrayIconPath);
const trayDimensions = pngDimensions(packagedTrayIcon);
if (trayDimensions.width !== 64 || trayDimensions.height !== 64) {
  throw new Error(
    `packaged macOS tray icon is ${trayDimensions.width}x${trayDimensions.height}, expected 64x64`,
  );
}
if (
  createHash("sha256").update(sourceTrayIcon).digest("hex") !==
  createHash("sha256").update(packagedTrayIcon).digest("hex")
) {
  throw new Error("packaged macOS tray icon differs from its source asset");
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

const identity = resolveDistributionIdentity();
const signature = verifyDeveloperIdSignature(
  appRoot,
  identity,
  localProductIdentity.bundleId,
  {
    deep: true,
  },
);

console.log(
  `verified macOS package executable, metadata, tray icon, Developer ID signature, trusted timestamp, hardened runtime, and ${sourceFiles.length} exact Renderer assets (${signature.policy})`,
);
