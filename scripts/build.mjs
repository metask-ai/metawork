import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { runChild } from "./run-child-process.mjs";
import { verifyFrontendBuild } from "./verify-frontend-build.mjs";
import { verifyNativeAutomationIsolation } from "./verify-native-automation-isolation.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";
import { generateRendererWire } from "./generate-renderer-wire.mjs";

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

export async function buildFrontend(
  root = repositoryRoot,
  { outDir, signal } = {},
) {
  await generateRendererWire({ signal });
  const args = [viteCli, "build"];
  if (outDir) args.push("--outDir", outDir);
  await runChild(process.execPath, args, {
    cwd: path.join(root, "frontend"),
    label: "Renderer build",
    timeoutMs: null,
    signal,
  });
  await verifyFrontendBuild(root, { outDir });
}

export async function buildNative(
  root = repositoryRoot,
  {
    optimize,
    target,
    automation = false,
    automaticUpdateCheck = false,
    installPrefix,
    frontendDir,
    signal,
  } = {},
) {
  if (!target) throw new Error("Native build requires a verified target");
  if (automation && automaticUpdateCheck)
    throw new Error(
      "automation artifacts must not enable official update checks",
    );
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
  if (automaticUpdateCheck) args.push("-Dautomatic-update-check=true");
  if (installPrefix) args.push(`-Dinstall-prefix=${installPrefix}`);
  if (frontendDir) args.push(`-Dfrontend-dist=${frontendDir}`);
  await runChild(process.execPath, args, {
    cwd: root,
    label: `Native ${optimize}${automation ? " automation" : ""} build`,
    timeoutMs: null,
    signal,
  });
}

// The automation-enabled Debug artifact every real desktop harness runs against.
export async function buildAutomationDebugArtifact(
  root = repositoryRoot,
  { targetId } = {},
) {
  const bundle = await verifyStagedAgentCoreBundle(
    root,
    targetId ? { targetId } : undefined,
  );
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
export function parseBuildArguments(args) {
  const [mode, ...rest] = args;
  const automaticUpdateCheck = rest.includes("--automatic-update-check");
  const targets = rest.filter((value) => value !== "--automatic-update-check");
  if (
    (mode !== "debug" && mode !== "release") ||
    targets.length > 1 ||
    targets.some((value) => value.startsWith("--")) ||
    rest.filter((value) => value === "--automatic-update-check").length > 1 ||
    (automaticUpdateCheck && mode !== "release")
  )
    throw new Error(
      "usage: node scripts/build.mjs debug|release [agentcore-target-id] [--automatic-update-check]",
    );
  return { mode, targetId: targets[0], automaticUpdateCheck };
}

if (isMain) {
  const { mode, targetId, automaticUpdateCheck } = parseBuildArguments(
    process.argv.slice(2),
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
      automaticUpdateCheck,
    });
    await verifyNativeAutomationIsolation();
  }
}
