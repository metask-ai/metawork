import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const defaultArtifact = path.join(root, "zig-out", "bin", "metawork");
const artifact = process.argv[2]
  ? path.resolve(root, process.argv[2])
  : existsSync(defaultArtifact)
    ? defaultArtifact
    : `${defaultArtifact}.exe`;
const bytes = await readFile(artifact);

const forbidden = [
  "zero://inline",
  "metawork:agent-events",
  "metawork.events.ack",
  "metawork.events.fetch",
  "metawork.gate5.emitFixture",
  "metawork.gate5.worker_wake",
  '"fixture":"inline"',
  '"fixture":"object"',
];

for (const token of forbidden) {
  if (bytes.includes(Buffer.from(token)))
    throw new Error(
      `release Native artifact contains automation token ${token}: ${artifact}`,
    );
}

console.log(`verified Native release automation isolation: ${artifact}`);
