import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import process from "node:process";
import { assertNativeAutomationIsolation } from "./native-automation-isolation.mjs";

const defaultRepositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

export function defaultNativeArtifact(repositoryRoot = defaultRepositoryRoot) {
  return path.join(
    repositoryRoot,
    "zig-out",
    "bin",
    process.platform === "win32" ? "metawork.exe" : "metawork",
  );
}

export async function verifyNativeAutomationIsolation(
  artifact = defaultNativeArtifact(),
) {
  const bytes = await readFile(artifact);
  assertNativeAutomationIsolation(bytes, artifact);
  console.log(`verified Native release automation isolation: ${artifact}`);
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const artifact = process.argv[2]
    ? path.resolve(defaultRepositoryRoot, process.argv[2])
    : defaultNativeArtifact();
  await verifyNativeAutomationIsolation(artifact);
}
