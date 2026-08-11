import { readdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { nativeCli, repositoryRoot } from "./build.mjs";
import { runChild } from "./run-child-process.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

const typescriptCli = path.join(
  repositoryRoot,
  "node_modules",
  "typescript",
  "bin",
  "tsc",
);

// Discovery, not a registry: every scripts/*.test.mjs runs. Adding a test file
// is the whole registration step, and no manifest can drift out of date.
export async function discoverNodeTests(root = repositoryRoot) {
  const entries = await readdir(path.join(root, "scripts"));
  return entries
    .filter((name) => name.endsWith(".test.mjs"))
    .sort()
    .map((name) => path.posix.join("scripts", name));
}

export async function typecheckRenderer(root = repositoryRoot) {
  await runChild(process.execPath, [typescriptCli, "--noEmit"], {
    cwd: path.join(root, "frontend"),
    label: "Renderer typecheck",
    timeoutMs: null,
  });
}

export async function runNodeTests(root = repositoryRoot) {
  const files = await discoverNodeTests(root);
  if (files.length === 0) throw new Error("no scripts/*.test.mjs were found");
  // The flag is a no-op on Node 22.18+ but is still required at the 22.15
  // engines floor, where type stripping is not yet on by default.
  await runChild(
    process.execPath,
    ["--experimental-strip-types", "--test", ...files],
    { cwd: root, label: "Node tests", timeoutMs: null },
  );
}

export async function runNativeTests(root = repositoryRoot) {
  await runChild(process.execPath, [nativeCli, "test", ".", "--yes"], {
    cwd: root,
    label: "Native test graph",
    timeoutMs: null,
  });
}

export async function runRepositoryTests(root = repositoryRoot) {
  await verifyStagedAgentCoreBundle(root);
  await typecheckRenderer(root);
  await runNodeTests(root);
  await runNativeTests(root);
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) await runRepositoryTests();
