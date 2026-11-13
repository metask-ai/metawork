import { readdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { nativeCli, repositoryRoot } from "./build.mjs";
import { runChild } from "./run-child-process.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";
import { generateRendererWire } from "./generate-renderer-wire.mjs";

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
  await generateRendererWire({ check: true });
  await runChild(process.execPath, [typescriptCli, "--noEmit"], {
    cwd: path.join(root, "frontend"),
    label: "Renderer typecheck",
    timeoutMs: null,
  });
}

export async function runNodeTests(root = repositoryRoot) {
  const files = await discoverNodeTests(root);
  if (files.length === 0) throw new Error("no scripts/*.test.mjs were found");
  await runChild(process.execPath, ["--test", ...files], {
    cwd: root,
    label: "Node tests",
    timeoutMs: null,
  });
}

export async function runNativeTests(root, bundle) {
  const ripgrep = path.join(
    bundle.root,
    bundle.manifest.runtime_assets[0].path,
  );
  await runChild(
    process.execPath,
    [nativeCli, "test", ".", "--yes", `-Dtarget=${bundle.target}`],
    {
      cwd: root,
      label: "Native test graph",
      env: { ...process.env, RG_BIN: ripgrep },
      timeoutMs: null,
    },
  );
}

export async function runTestPhases(phases) {
  const failures = [];
  for (const run of phases) {
    try {
      await run();
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length !== 0) {
    throw new AggregateError(failures, "repository test phases failed");
  }
}

export async function runRepositoryTests(root = repositoryRoot) {
  const bundle = await verifyStagedAgentCoreBundle(root);
  await typecheckRenderer(root);
  await runTestPhases([
    () => runNodeTests(root),
    () => runNativeTests(root, bundle),
  ]);
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) await runRepositoryTests();
