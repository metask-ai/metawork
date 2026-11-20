// Runs the execution link desktop acceptance with the development switch on
// and off, and compares their memory against the step's targets. Windows.
//
//   node scripts/execution-link-acceptance.mjs
//   $env:METAWORK_EXECUTION_LINK_MEMORY_ROUNDS = "3"; node scripts/execution-link-acceptance.mjs
//
// Builds the automation Debug artifact once (skipped when
// `METAWORK_VERTICAL_PREBUILT=1`), then runs the AgentCore vertical harness
// in its `METAWORK_EXECUTION_LINK_ONLY` scope once per mode per round,
// alternating which mode goes first, because other work on the machine moves
// a single sample. Every run uses the harness's own temporary platform home
// and opens the MetaWork Automation window until it quits by itself.
//
// Evidence: `.zig-cache/execution-link-desktop/<mode>-<round>.json` per run
// and `summary.json` with the medians and the verdict. Exits non-zero when a
// run fails or a memory target is exceeded.

import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { buildAutomationDebugArtifact } from "./build.mjs";

if (process.platform !== "win32")
  throw new Error("execution-link-acceptance.mjs requires Windows");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const evidenceDir = path.join(root, ".zig-cache", "execution-link-desktop");
const rounds = Number(process.env.METAWORK_EXECUTION_LINK_MEMORY_ROUNDS ?? 1);
if (!Number.isInteger(rounds) || rounds < 1)
  throw new Error(
    "METAWORK_EXECUTION_LINK_MEMORY_ROUNDS must be a positive integer",
  );

const MiB = 1024 * 1024;
/// The step's memory targets, as deltas of the linked mode over in process.
const targets = {
  idleWorkingSetBytes: 2 * MiB,
  idlePrivateBytes: 2 * MiB,
  afterTaskWorkingSetBytes: 30 * MiB,
  afterTaskPrivateBytes: 64 * MiB,
};

if (process.env.METAWORK_VERTICAL_PREBUILT !== "1")
  await buildAutomationDebugArtifact(root);
await mkdir(evidenceDir, { recursive: true });

function runHarness(mode, round) {
  const evidencePath = path.join(evidenceDir, `${mode}-${round}.json`);
  const env = {
    ...process.env,
    METAWORK_EXECUTION_LINK_ONLY: "1",
    METAWORK_VERTICAL_PREBUILT: "1",
    METAWORK_TEST_APP_CWD: path.join("zig-out", "bin"),
    METAWORK_EXECUTION_LINK_EVIDENCE: evidencePath,
  };
  if (mode === "on") env.METAWORK_DEV_EXECUTION_LINK = "1";
  else delete env.METAWORK_DEV_EXECUTION_LINK;
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [path.join(root, "scripts", "test-agentcore-vertical-macos.mjs")],
      { cwd: root, env, stdio: "inherit" },
    );
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolve(evidencePath);
      else
        reject(
          new Error(
            `switch ${mode}, round ${round}: harness exited ${code ?? signal}`,
          ),
        );
    });
  });
}

const sum = (memory, field) =>
  Object.values(memory).reduce((total, process) => total + process[field], 0);

function median(values) {
  const sorted = [...values].sort((first, second) => first - second);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

const samples = { on: [], off: [] };
for (let round = 1; round <= rounds; round += 1) {
  const order = round % 2 === 1 ? ["on", "off"] : ["off", "on"];
  for (const mode of order) {
    const evidencePath = await runHarness(mode, round);
    const evidence = JSON.parse(await readFile(evidencePath, "utf8"));
    samples[mode].push({
      round,
      idleWorkingSetBytes: sum(evidence.idle.memory, "workingSetBytes"),
      idlePrivateBytes: sum(evidence.idle.memory, "privateBytes"),
      afterTaskWorkingSetBytes: sum(
        evidence.afterTask.memory,
        "workingSetBytes",
      ),
      afterTaskPrivateBytes: sum(evidence.afterTask.memory, "privateBytes"),
    });
  }
}

const fields = Object.keys(targets);
const medians = Object.fromEntries(
  ["on", "off"].map((mode) => [
    mode,
    Object.fromEntries(
      fields.map((field) => [
        field,
        median(samples[mode].map((sample) => sample[field])),
      ]),
    ),
  ]),
);
const deltas = Object.fromEntries(
  fields.map((field) => [field, medians.on[field] - medians.off[field]]),
);
const exceeded = fields.filter((field) => deltas[field] > targets[field]);
const mib = (bytes) => Math.round((bytes / MiB) * 10) / 10;

const summary = { rounds, samples, medians, deltas, targets, exceeded };
await writeFile(
  path.join(evidenceDir, "summary.json"),
  JSON.stringify(summary, null, 2),
);
for (const field of fields)
  process.stdout.write(
    `${field.padEnd(26)} on ${String(mib(medians.on[field])).padStart(7)} MiB  off ${String(mib(medians.off[field])).padStart(7)} MiB  delta ${String(mib(deltas[field])).padStart(6)} MiB  target <= ${mib(targets[field])} MiB\n`,
  );
if (exceeded.length > 0) {
  process.stderr.write(`memory targets exceeded: ${exceeded.join(", ")}\n`);
  process.exit(1);
}
process.stdout.write(
  `Execution link acceptance passed in both modes over ${rounds} round(s); evidence in ${evidenceDir}\n`,
);
