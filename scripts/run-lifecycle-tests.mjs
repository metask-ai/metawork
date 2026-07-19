import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { validateAgentCoreBundle } from "./agentcore-bundle.mjs";

const bundleRoot = process.env.AGENTCORE_BUNDLE_ROOT;
if (!bundleRoot) throw new Error("AGENTCORE_BUNDLE_ROOT is required");

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const lockPath = path.join(
  repositoryRoot,
  "spikes",
  "agentcore-contract",
  "bundle.lock.json",
);
const expectedManifest = JSON.parse(await readFile(lockPath, "utf8"));
const bundle = await validateAgentCoreBundle(bundleRoot, { expectedManifest });
const testRoot = path.join(repositoryRoot, "tests");
const testFilter = process.env.LIFECYCLE_TEST_FILTER;

const zigArguments = [
  "build",
  "test",
  `-Dbundle-root=${bundle.root}`,
  `-Dtarget=${bundle.target}`,
  "-Doptimize=Debug",
];
if (testFilter) zigArguments.push(`-Dtfilter=${testFilter}`);

const child = spawn("zig", zigArguments, {
  cwd: testRoot,
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
