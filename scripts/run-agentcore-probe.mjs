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
console.log(
  `verified AgentCore ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`,
);

const spikeRoot = path.join(repositoryRoot, "spikes", "agentcore-contract");
const child = spawn(
  "zig",
  [
    "build",
    "test",
    `-Dbundle-root=${bundle.root}`,
    `-Dtarget=${bundle.target}`,
    "-Doptimize=Debug",
  ],
  { cwd: spikeRoot, stdio: "inherit", detached: true },
);

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
if (timedOut) throw new Error("AgentCore contract probe exceeded 30 seconds");
if (exitCode !== 0)
  throw new Error(`AgentCore contract probe failed with exit code ${exitCode}`);
