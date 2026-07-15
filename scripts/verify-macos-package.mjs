import { createHash } from "node:crypto";
import { readdir, readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const sourceAssets = path.join(repositoryRoot, "frontend", "dist");
const appRoot = path.join(repositoryRoot, "zig-out", "package", "metawork.app");
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

const infoPlist = await readFile(
  path.join(appRoot, "Contents", "Info.plist"),
  "utf8",
);
for (const requiredValue of ["dev.metawork.desktop", "MetaWork", "0.0.1"]) {
  if (!infoPlist.includes(requiredValue)) {
    throw new Error(`Info.plist is missing ${requiredValue}`);
  }
}

console.log(
  `verified macOS package executable, metadata, and ${sourceFiles.length} exact Renderer assets`,
);
