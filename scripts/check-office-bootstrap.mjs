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
const executable = path.join(cache, "office-bootstrap.exe");
await runChild(
  "zig",
  [
    "build-exe",
    "--dep",
    "office_component_archive",
    "-Mroot=tests/office_component_bootstrap.zig",
    "-Moffice_component_archive=src/app/office_component_archive.zig",
    "-lc",
    "-O",
    "ReleaseSafe",
    `-femit-bin=${executable}`,
  ],
  {
    cwd: root,
    label: "Office native bootstrap qualification build",
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
const parent = mkdtempSync(path.join(cache, "run-"));
await runChild(
  executable,
  [process.argv[2], process.argv[2] + ".json", parent],
  {
    cwd: root,
    label: "Office native bootstrap actual archive",
    timeoutMs: null,
  },
);
console.log(
  `Verified native bootstrap output: ${path.join(parent, "component")}`,
);
