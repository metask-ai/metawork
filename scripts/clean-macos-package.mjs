import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const packagePath = path.join(
  repositoryRoot,
  "zig-out",
  "package",
  "metawork.app",
);

await rm(packagePath, { recursive: true, force: true });
console.log(`removed previous macOS package: ${packagePath}`);
