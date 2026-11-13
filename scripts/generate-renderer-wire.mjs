import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile, rename, rm } from "node:fs/promises";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { format } from "prettier";

const root = fileURLToPath(new URL("../", import.meta.url));
const destination = path.join(root, "frontend/src/bridge/generated-wire.ts");

export async function generateRendererWire({ check = false, signal } = {}) {
  const globalCache = path.resolve(
    root,
    process.env.ZIG_GLOBAL_CACHE_DIR || ".zig-cache/global",
  );
  // Zig 0.16.0 needs this directory before fetching ZIP dependencies.
  await mkdir(path.join(globalCache, "tmp"), { recursive: true });
  const { stdout } = await promisify(execFile)(
    "zig",
    ["build", "generate-renderer-wire", "--global-cache-dir", globalCache],
    { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024, signal },
  );
  const expected = await format(stdout, { parser: "typescript" });
  const actual = await readFile(destination, "utf8").catch((error) => {
    if (error.code === "ENOENT") return null;
    throw error;
  });
  if (actual === expected) return;
  if (check)
    throw new Error(
      "Generated Renderer wire is stale; regenerate with npm run build:debug or npm run dev.",
    );
  const temporary = `${destination}.${process.pid}.tmp`;
  try {
    await writeFile(temporary, expected);
    await rename(temporary, destination);
  } finally {
    await rm(temporary, { force: true });
  }
}

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  if (process.argv.slice(2).some((argument) => argument !== "--check"))
    throw new Error("usage: generate-renderer-wire.mjs [--check]");
  await generateRendererWire({ check: process.argv.includes("--check") });
}
