import { execFileSync } from "node:child_process";
import { mkdirSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  archiveEnvironmentPath,
  archiveHelperPath,
  localArchiveEnvironment,
} from "./archive-environment.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [, , option, executable, ...extra] = process.argv;
if (
  option !== "--python" ||
  !executable ||
  !path.isAbsolute(executable) ||
  extra.length
)
  throw new Error(
    "Usage: npm run archive:setup -- --python /absolute/python3.9-or-newer",
  );
const python = realpathSync(executable);
execFileSync(
  python,
  [
    "-B",
    "-c",
    "import sys, argparse, json, shutil, stat, struct, unicodedata, uuid, zipfile, zlib; assert sys.version_info >= (3,9), 'Python 3.9 or newer is required'",
  ],
  { timeout: 30_000, stdio: "inherit" },
);
execFileSync(python, ["-B", archiveHelperPath(root), "--help"], {
  timeout: 30_000,
  stdio: "pipe",
});
const filename = archiveEnvironmentPath(root);
mkdirSync(path.dirname(filename), { recursive: true });
const candidate = `${filename}.${process.pid}.tmp`;
writeFileSync(candidate, JSON.stringify({ schema: 1, python }) + "\n", {
  mode: 0o600,
});
renameSync(candidate, filename);
localArchiveEnvironment(root);
console.log("Local archive environment ready (Python standard library only).");
