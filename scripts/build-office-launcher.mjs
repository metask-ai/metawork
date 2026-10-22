import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { readPortableExecutableMachine } from "./package-windows.mjs";
import { runChild } from "./run-child-process.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const machines = {
  "x86_64-windows-msvc": 0x8664,
  "aarch64-windows-msvc": 0xaa64,
};

export async function buildOfficeLauncher({ targetId, outputPath, signal }) {
  if (process.platform !== "win32")
    throw new Error("Office launcher build requires Windows");
  if (!Object.hasOwn(machines, targetId))
    throw new Error(`Unsupported Office launcher target: ${targetId}`);
  if (!path.isAbsolute(outputPath))
    throw new Error("Office launcher output must be absolute");
  mkdirSync(path.dirname(outputPath), { recursive: true });
  await runChild(
    "zig",
    [
      "cc",
      "-target",
      targetId,
      "-O2",
      "-Wall",
      "-Wextra",
      "-Werror",
      path.join(root, "src/product/skill/office_runtime/launcher_windows.c"),
      "-o",
      outputPath,
    ],
    {
      cwd: root,
      label: `Office ${targetId} entry build`,
      env: {
        ...process.env,
        ZIG_GLOBAL_CACHE_DIR: path.join(
          root,
          ".zig-cache/office-launcher-zig-global",
        ),
      },
      signal,
    },
  );
  if (readPortableExecutableMachine(outputPath) !== machines[targetId])
    throw new Error(
      "Office launcher PE architecture does not match its target",
    );
  return outputPath;
}

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  if (process.argv.length !== 4)
    throw new Error(
      "Usage: build-office-launcher.mjs <target-id> <absolute-output>",
    );
  await buildOfficeLauncher({
    targetId: process.argv[2],
    outputPath: process.argv[3],
  });
}
