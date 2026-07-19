import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { assertNativeAutomationIsolation } from "./native-automation-isolation.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const defaultArtifact = path.join(root, "zig-out", "bin", "metawork");
const artifact = process.argv[2]
  ? path.resolve(root, process.argv[2])
  : existsSync(defaultArtifact)
    ? defaultArtifact
    : `${defaultArtifact}.exe`;
const bytes = await readFile(artifact);
assertNativeAutomationIsolation(bytes, artifact);

console.log(`verified Native release automation isolation: ${artifact}`);
