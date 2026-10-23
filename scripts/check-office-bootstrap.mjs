import { mkdirSync, mkdtempSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runChild } from "./run-child-process.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
if (
  process.platform !== "win32" ||
  process.argv.length !== 3 ||
  !path.isAbsolute(process.argv[2])
)
  throw new Error(
    "Usage on Windows: check-office-bootstrap.mjs <absolute-producer-archive.tar.gz>",
  );
const cache = path.join(root, ".zig-cache/office-bootstrap-qualification");
mkdirSync(cache, { recursive: true });
const parent = mkdtempSync(path.join(cache, "run-"));
await runChild(
  "zig",
  [
    "build",
    "office-bootstrap",
    "-Doptimize=ReleaseSafe",
    "--",
    process.argv[2],
    process.argv[2] + ".json",
    parent,
  ],
  {
    cwd: root,
    label: "Office native bootstrap actual archive",
    timeoutMs: null,
    env: {
      ...process.env,
      ZIG_GLOBAL_CACHE_DIR: path.join(
        root,
        ".zig-cache/office-bootstrap-global",
      ),
    },
  },
);
console.log(
  `Verified native bootstrap output: ${path.join(parent, "component")}`,
);
