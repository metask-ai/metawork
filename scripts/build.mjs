import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { runChild } from "./run-child-process.mjs";
import { verifyFrontendBuild } from "./verify-frontend-build.mjs";
import { verifyNativeAutomationIsolation } from "./verify-native-automation-isolation.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

export const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);

// Both dispatchers are invoked through process.execPath because callers outside
// an npm script do not inherit node_modules/.bin on PATH.
const viteCli = path.join(
  repositoryRoot,
  "node_modules",
  "vite",
  "bin",
  "vite.js",
);
export const nativeCli = path.join(
  repositoryRoot,
  "node_modules",
  "@native-sdk",
  "cli",
  "bin",
  "native.js",
);

export async function buildFrontend(root = repositoryRoot) {
  await runChild(process.execPath, [viteCli, "build"], {
    cwd: path.join(root, "frontend"),
    label: "Renderer build",
    timeoutMs: null,
  });
  await verifyFrontendBuild(root);
}

export async function buildNative(
  root = repositoryRoot,
  { optimize, target, automation = false } = {},
) {
  if (!target) throw new Error("Native build requires a verified target");
  const args = [
    nativeCli,
    "build",
    ".",
    "--yes",
    `-Dtarget=${target}`,
    `-Doptimize=${optimize}`,
    `-Dartifact=${automation ? "automation" : "development"}`,
  ];
  if (automation) args.push("-Dautomation=true");
  await runChild(process.execPath, args, {
    cwd: root,
    label: `Native ${optimize}${automation ? " automation" : ""} build`,
    timeoutMs: null,
  });
}

// The automation-enabled Debug artifact every real desktop harness runs against.
export async function buildAutomationDebugArtifact(root = repositoryRoot) {
  const bundle = await verifyStagedAgentCoreBundle(root);
  await buildFrontend(root);
  await buildNative(root, {
    optimize: "Debug",
    target: bundle.target,
    automation: true,
  });
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
if (isMain) {
  const [mode, targetId] = process.argv.slice(2);
  if (
    (process.argv.length !== 3 && process.argv.length !== 4) ||
    (mode !== "debug" && mode !== "release")
  )
    throw new Error(
      "usage: node scripts/build.mjs debug|release [agentcore-target-id]",
    );

  const bundle = await verifyStagedAgentCoreBundle(
    repositoryRoot,
    targetId ? { targetId } : undefined,
  );
  await buildFrontend(repositoryRoot);
  if (mode === "debug") {
    await buildNative(repositoryRoot, {
      optimize: "Debug",
      target: bundle.target,
    });
  } else {
    await buildNative(repositoryRoot, {
      optimize: "ReleaseFast",
      target: bundle.target,
    });
    await verifyNativeAutomationIsolation();
  }
}
