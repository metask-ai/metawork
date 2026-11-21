// Runs the execution link desktop acceptance, and compares its memory with a
// build that still ran AgentCore in the window process. Windows and macOS.
//
//   $env:METAWORK_EXECUTION_LINK_BASELINE_APP_CWD = "<baseline>\zig-out\bin"
//   node scripts/execution-link-acceptance.mjs
//   $env:METAWORK_EXECUTION_LINK_MEMORY_ROUNDS = "3"; node scripts/execution-link-acceptance.mjs
//
// The baseline is the automation Debug artifact of a build from before the
// execution process was the default (the merge base with main), built in its
// own checkout and copied under this one, since the harness only runs an
// application inside the repository (for example
// `.zig-cache/execution-link-baseline/bin`); this build has no in-process
// mode to compare against.
//
// Builds this checkout's automation Debug artifact once (skipped when
// `METAWORK_VERTICAL_PREBUILT=1`), then runs the AgentCore vertical harness
// in its `METAWORK_EXECUTION_LINK_ONLY` scope once per build per round,
// alternating which goes first, because other work on the machine moves a
// single sample. The baseline run only measures: idle, one Task, quit. Every
// run uses the harness's own temporary platform home and opens the MetaWork
// Automation window until it quits by itself.
//
// Evidence: `.zig-cache/execution-link-desktop/<build>-<round>.json` per run
// and `summary.json` with the medians and the verdict. Exits non-zero when a
// run fails or a memory target is exceeded.

import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { buildAutomationDebugArtifact } from "./build.mjs";

if (process.platform !== "win32" && process.platform !== "darwin")
  throw new Error("execution-link-acceptance.mjs requires Windows or macOS");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const evidenceDir = path.join(root, ".zig-cache", "execution-link-desktop");
const rounds = Number(process.env.METAWORK_EXECUTION_LINK_MEMORY_ROUNDS ?? 1);
if (!Number.isInteger(rounds) || rounds < 1)
  throw new Error(
    "METAWORK_EXECUTION_LINK_MEMORY_ROUNDS must be a positive integer",
  );

const baselineAppCwd = process.env.METAWORK_EXECUTION_LINK_BASELINE_APP_CWD;
if (!baselineAppCwd)
  throw new Error(
    "METAWORK_EXECUTION_LINK_BASELINE_APP_CWD must name the baseline build's zig-out\\bin",
  );

const MiB = 1024 * 1024;
/// The step's memory targets, as deltas of this build over the baseline.
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
    METAWORK_TEST_APP_CWD:
      mode === "linked" ? path.join("zig-out", "bin") : baselineAppCwd,
    METAWORK_EXECUTION_LINK_EVIDENCE: evidencePath,
  };
  if (mode === "baseline") {
    env.METAWORK_EXECUTION_LINK_BASELINE = "1";
    env.METAWORK_TEST_APP_BINARY = path.join(
      baselineAppCwd,
      process.platform === "win32" ? "metawork.exe" : "metawork",
    );
  } else {
    delete env.METAWORK_EXECUTION_LINK_BASELINE;
    delete env.METAWORK_TEST_APP_BINARY;
  }
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
            `${mode}, round ${round}: harness exited ${code ?? signal}`,
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

const samples = { linked: [], baseline: [] };
for (let round = 1; round <= rounds; round += 1) {
  const order =
    round % 2 === 1 ? ["linked", "baseline"] : ["baseline", "linked"];
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
  ["linked", "baseline"].map((mode) => [
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
  fields.map((field) => [
    field,
    medians.linked[field] - medians.baseline[field],
  ]),
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
    `${field.padEnd(26)} linked ${String(mib(medians.linked[field])).padStart(7)} MiB  baseline ${String(mib(medians.baseline[field])).padStart(7)} MiB  delta ${String(mib(deltas[field])).padStart(6)} MiB  target <= ${mib(targets[field])} MiB\n`,
  );
if (exceeded.length > 0) {
  process.stderr.write(`memory targets exceeded: ${exceeded.join(", ")}\n`);
  process.exit(1);
}
process.stdout.write(
  `Execution link acceptance passed over ${rounds} round(s); evidence in ${evidenceDir}\n`,
);
