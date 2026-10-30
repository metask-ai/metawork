import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { localArchiveEnvironment } from "./archive-environment.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const environment = localArchiveEnvironment(root);
if (!environment.METAWORK_LOCAL_ARCHIVE_PYTHON)
  throw new Error("Prepare the archive environment with archive:setup first.");
execFileSync(
  environment.METAWORK_LOCAL_ARCHIVE_PYTHON,
  ["-B", "scripts/check-office-archives.py"],
  { cwd: root, env: environment, timeout: 60_000, stdio: "inherit" },
);
execFileSync(process.execPath, ["scripts/build-office-skills.mjs", "--check"], {
  cwd: root,
  stdio: "inherit",
});
