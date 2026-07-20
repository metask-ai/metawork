import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import process from "node:process";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const bundle = await verifyStagedAgentCoreBundle(repositoryRoot);
const testFilter = process.env.LIFECYCLE_TEST_FILTER;
const zigArguments = [
  "build",
  "test-lifecycle",
  `-Dtarget=${bundle.target}`,
  "-Doptimize=Debug",
];
if (testFilter) zigArguments.push(`-Dtfilter=${testFilter}`);

const child = spawn("zig", zigArguments, {
  cwd: repositoryRoot,
  stdio: "inherit",
  detached: true,
});
let timedOut = false;
const timeout = setTimeout(() => {
  timedOut = true;
  try {
    if (child.pid) process.kill(-child.pid, "SIGKILL");
  } catch {
    child.kill("SIGKILL");
  }
}, 30_000);
let exitCode;
try {
  exitCode = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", resolve);
  });
} finally {
  clearTimeout(timeout);
}
if (timedOut) throw new Error("Lifecycle tests exceeded 30 seconds");
if (exitCode !== 0)
  throw new Error(`Lifecycle tests failed with exit code ${exitCode}`);
