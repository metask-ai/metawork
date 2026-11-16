import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile, rename, rm } from "node:fs/promises";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { format } from "prettier";

const root = fileURLToPath(new URL("../", import.meta.url));
const destination = path.join(root, "frontend/src/bridge/generated-wire.ts");

// Every module this generator compiles is b.graph.host and none of them
// consume the AgentCore bundle, but build.zig verifies the bundle for the
// resolved target in its configure phase, on every `zig build` whatever step
// was asked for. With no -Dtarget the build injects the host architecture, so
// on a machine that staged only the bundle it is packaging for - an x64 runner
// building the ARM64 installer - generating the wire demanded a bundle nobody
// staged and panicked before the step ran. A caller that has already verified
// a bundle therefore names its target here, exactly as the main build does;
// one building for the host names none and keeps the build's own default.
export function rendererWireBuildArguments(globalCache, target) {
  const args = [
    "build",
    "generate-renderer-wire",
    "--global-cache-dir",
    globalCache,
  ];
  // The canonical Zig target from the verified bundle manifest, which is what
  // scripts/package-windows.mjs hands the main build, and never the short
  // AgentCore target id: naming the same target as the build it precedes is
  // the whole point of passing one.
  if (target !== undefined) args.push(`-Dtarget=${target}`);
  return args;
}

export async function generateRendererWire({
  check = false,
  signal,
  target,
} = {}) {
  const globalCache = path.resolve(
    root,
    process.env.ZIG_GLOBAL_CACHE_DIR || ".zig-cache/global",
  );
  // Zig 0.16.0 needs this directory before fetching ZIP dependencies.
  await mkdir(path.join(globalCache, "tmp"), { recursive: true });
  const { stdout } = await promisify(execFile)(
    "zig",
    rendererWireBuildArguments(globalCache, target),
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
