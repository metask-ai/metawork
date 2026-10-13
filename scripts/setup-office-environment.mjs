import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { officeEnvironmentPath } from "./office-environment.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (
    !["--python", "--soffice", "--pdftoppm", "--pandoc"].includes(key) ||
    !value ||
    options.has(key)
  )
    throw new Error(
      "Usage: node scripts/setup-office-environment.mjs --python /path/to/python3.12 --soffice /path/to/soffice --pdftoppm /path/to/pdftoppm [--pandoc /path/to/pandoc]",
    );
  if (!path.isAbsolute(value) || !existsSync(value))
    throw new Error(`${key} must name an existing absolute executable path`);
  if (
    key !== "--python" &&
    path.basename(value).replace(/\.exe$/i, "") !== key.slice(2)
  )
    throw new Error(
      `${key} executable must keep its command name for Skill PATH lookup`,
    );
  options.set(key, value);
}
for (const required of ["--python", "--soffice", "--pdftoppm"])
  if (!options.has(required))
    throw new Error(`Missing required ${required} executable`);
function run(command, args, capture = false) {
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: capture ? "pipe" : "inherit",
    encoding: "utf8",
    env: {
      ...process.env,
      PIP_CACHE_DIR: path.join(
        root,
        ".zig-cache",
        "office-runtime",
        "pip-cache",
      ),
    },
    timeout: capture ? 30_000 : 20 * 60_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(
      `${path.basename(command)} failed (${result.status}): ${result.stderr ?? ""}`,
    );
  return result.stdout;
}
const version = run(
  options.get("--python"),
  ["-c", "import sys; print('.'.join(map(str, sys.version_info[:2])))"],
  true,
).trim();
if (version !== "3.12")
  throw new Error(
    `Local Office setup requires Python 3.12, received ${version}`,
  );
const runtime = path.dirname(officeEnvironmentPath(root));
const venv = path.join(runtime, "venv");
mkdirSync(runtime, { recursive: true });
rmSync(officeEnvironmentPath(root), { force: true });
run(options.get("--python"), ["-m", "venv", venv]);
const python = path.join(
  venv,
  process.platform === "win32" ? "Scripts/python.exe" : "bin/python",
);
run(python, [
  "-m",
  "pip",
  "install",
  "--no-deps",
  "--disable-pip-version-check",
  "-r",
  path.join(root, "scripts", "office-requirements.txt"),
]);
run(python, ["-m", "pip", "check"]);
run(python, [
  "-c",
  "import pandas, openpyxl, lxml.etree, defusedxml, PIL, markitdown",
]);
run(options.get("--soffice"), ["--version"], true);
run(options.get("--pdftoppm"), ["-v"], true);
if (options.has("--pandoc")) run(options.get("--pandoc"), ["--version"], true);
const toolDirectories = [
  ...new Set(
    ["--soffice", "--pdftoppm", "--pandoc"]
      .filter((key) => options.has(key))
      .map((key) => path.dirname(options.get(key))),
  ),
];
writeFileSync(
  officeEnvironmentPath(root),
  JSON.stringify({ schema: 1, python, toolDirectories }, null, 2) + "\n",
);
console.log(`Local Office environment ready: ${runtime}`);
