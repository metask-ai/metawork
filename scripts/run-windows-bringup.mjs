import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { runChild } from "./run-child-process.mjs";

if (process.platform !== "win32") {
  throw new Error("run-windows-bringup.mjs requires Windows");
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Steps are script paths, not npm script names: package.json stays a thin entry
// surface instead of being this orchestrator's runtime dependency, and renaming
// an entry can no longer break the baseline at run time.
const steps = [
  ["run-tests.mjs", []],
  ["run-lifecycle-tests.mjs", []],
  ["build.mjs", ["debug"]],
  ["test-model-connection-readiness-windows.mjs", []],
  ["run-agentcore-restore-probe.mjs", ["--staged"]],
  ["run-agentcore-vertical-windows.mjs", []],
  ["build.mjs", ["release"]],
];

for (const [script, args] of steps) {
  await runChild(
    process.execPath,
    [path.join(root, "scripts", script), ...args],
    {
      cwd: root,
      label: `Windows bring-up step ${[script, ...args].join(" ")}`,
      timeoutMs: null,
    },
  );
}

console.log(
  "Windows integration baseline passed: staged exact GNU bundle, bundle guards, lifecycle, Model Connection readiness, staged SDK probe, Native Debug/Release, and AgentCore vertical automation.",
);
