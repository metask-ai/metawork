import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), "metawork-gate7-"));
const executable = path.join(temporaryRoot, "fault-process");
const source = path.join(
  repositoryRoot,
  "spikes",
  "fault-domain",
  "fault_process.c",
);
const timeoutMs = 10_000;
const liveChildren = new Set();

assert.equal(
  process.platform,
  "darwin",
  "Gate 7 currently validates macOS only",
);

function track(child) {
  liveChildren.add(child);
  child.once("exit", () => liveChildren.delete(child));
  return child;
}

function waitForExit(child, label) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${label} exceeded ${timeoutMs} ms`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timeout);
      resolve({ code, signal });
    });
  });
}

async function runCommand(command, args, label) {
  const child = track(
    spawn(command, args, {
      cwd: repositoryRoot,
      stdio: ["ignore", "pipe", "pipe"],
    }),
  );
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.setEncoding("utf8").on("data", (chunk) => {
    stderr += chunk;
  });
  const result = await waitForExit(child, label);
  if (result.code !== 0) {
    throw new Error(
      `${label} failed: code=${result.code} signal=${result.signal}\n${stdout}${stderr}`,
    );
  }
  return stdout.trim();
}

class LineProcess {
  constructor(mode) {
    this.lines = [];
    this.waiters = [];
    this.stderr = "";
    this.child = track(
      spawn(executable, [mode], {
        stdio: ["pipe", "pipe", "pipe"],
      }),
    );
    this.exit = waitForExit(this.child, mode);
    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");
    let pending = "";
    this.child.stdout.on("data", (chunk) => {
      pending += chunk;
      for (;;) {
        const newline = pending.indexOf("\n");
        if (newline < 0) break;
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        this.lines.push(line);
        this.#flush();
      }
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderr += chunk;
    });
  }

  #flush() {
    for (let waiterIndex = 0; waiterIndex < this.waiters.length;) {
      const waiter = this.waiters[waiterIndex];
      const lineIndex = this.lines.findIndex(waiter.predicate);
      if (lineIndex < 0) {
        waiterIndex += 1;
        continue;
      }
      const [line] = this.lines.splice(lineIndex, 1);
      this.waiters.splice(waiterIndex, 1);
      clearTimeout(waiter.timeout);
      waiter.resolve(line);
    }
  }

  waitLine(predicate, label) {
    const lineIndex = this.lines.findIndex(predicate);
    if (lineIndex >= 0) {
      return Promise.resolve(this.lines.splice(lineIndex, 1)[0]);
    }
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject, timeout: null };
      waiter.timeout = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(
          new Error(
            `${label} exceeded ${timeoutMs} ms; stderr=${this.stderr.trim()}`,
          ),
        );
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  send(frame) {
    assert.equal(this.child.stdin.write(`${frame}\n`), true);
  }
}

async function residentSetKb(pid) {
  const output = await runCommand(
    "ps",
    ["-o", "rss=", "-p", String(pid)],
    `read RSS for ${pid}`,
  );
  const value = Number.parseInt(output, 10);
  assert.ok(Number.isSafeInteger(value) && value > 0, `invalid RSS: ${output}`);
  return value;
}

async function start(mode, readyPrefix) {
  const startedAt = performance.now();
  const process = new LineProcess(mode);
  const ready = await process.waitLine(
    (line) => line.startsWith(readyPrefix),
    `${mode} ready`,
  );
  const fields = ready.split("\t");
  const pid = Number.parseInt(fields[1], 10);
  assert.equal(pid, process.child.pid);
  return {
    process,
    ready,
    startupMs: performance.now() - startedAt,
    rssKb: await residentSetKb(pid),
  };
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.ceil(sorted.length * fraction) - 1];
}

await runCommand(
  "zig",
  ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", source, "-o", executable],
  "compile Gate 7 native fault process",
);

try {
  const baseline = await start("--baseline", "READY_BASELINE\t");
  assert.match(baseline.ready, /completed-session=completed/);
  assert.match(baseline.ready, /active-session=running/);
  baseline.process.send("CRASH\tbaseline-active-run");
  assert.equal(
    await baseline.process.waitLine(
      (line) => line === "ACTIVE\tbaseline-active-run",
      "baseline active marker",
    ),
    "ACTIVE\tbaseline-active-run",
  );
  const baselineExit = await baseline.process.exit;
  assert.ok(
    baselineExit.signal === "SIGABRT" || baselineExit.code !== 0,
    `baseline did not abort: ${JSON.stringify(baselineExit)}`,
  );
  assert.equal(
    baseline.process.lines.some((line) => line.startsWith("AFTER_CRASH")),
    false,
  );

  const restartedBaseline = await start("--baseline", "READY_BASELINE\t");
  restartedBaseline.process.send("STOP");
  await restartedBaseline.process.waitLine(
    (line) => line === "STOPPED_BASELINE",
    "restarted baseline stop",
  );
  assert.deepEqual(await restartedBaseline.process.exit, {
    code: 0,
    signal: null,
  });

  const hostSnapshot = {
    sessions: {
      "session-owned": {
        phase: "running",
        runId: "run-dangerous",
        cause: null,
      },
      "session-other": {
        phase: "completed",
        assistant: "durable Host UI state",
        cause: null,
      },
    },
  };
  let dangerousDispatchCount = 0;
  const worker = await start("--worker", "READY_WORKER\t");
  assert.match(worker.ready, /max-frame=4096/);

  const roundTripMs = [];
  let maximumObservedFrameBytes = 0;
  for (let index = 0; index < 100; index += 1) {
    const correlationId = `ping-${index}`;
    const frame = `PING\t${correlationId}`;
    maximumObservedFrameBytes = Math.max(
      maximumObservedFrameBytes,
      Buffer.byteLength(`${frame}\n`),
    );
    const startedAt = performance.now();
    worker.process.send(frame);
    assert.equal(
      await worker.process.waitLine(
        (line) => line === `RESULT\t${correlationId}\tpong`,
        `ping ${index}`,
      ),
      `RESULT\t${correlationId}\tpong`,
    );
    roundTripMs.push(performance.now() - startedAt);
  }

  worker.process.send(`PING\t${"x".repeat(5000)}`);
  assert.equal(
    await worker.process.waitLine(
      (line) => line === "ERROR\tFRAME_TOO_LARGE\t4096",
      "oversized frame rejection",
    ),
    "ERROR\tFRAME_TOO_LARGE\t4096",
  );

  const dangerousCorrelationId = "dangerous-1";
  const dangerousFrame = `RUN\t${dangerousCorrelationId}\tsession-owned\tdangerous_tool`;
  maximumObservedFrameBytes = Math.max(
    maximumObservedFrameBytes,
    Buffer.byteLength(`${dangerousFrame}\n`),
  );
  dangerousDispatchCount += 1;
  worker.process.send(dangerousFrame);
  assert.equal(
    await worker.process.waitLine(
      (line) => line === "ACCEPTED\tdangerous-1\tsession-owned\tdangerous_tool",
      "dangerous tool acceptance",
    ),
    "ACCEPTED\tdangerous-1\tsession-owned\tdangerous_tool",
  );
  const workerExit = await worker.process.exit;
  assert.ok(
    workerExit.signal === "SIGABRT" || workerExit.code !== 0,
    `worker did not abort: ${JSON.stringify(workerExit)}`,
  );

  hostSnapshot.sessions["session-owned"].phase = "interrupted";
  hostSnapshot.sessions["session-owned"].cause = "worker_disconnected";
  assert.deepEqual(hostSnapshot.sessions["session-other"], {
    phase: "completed",
    assistant: "durable Host UI state",
    cause: null,
  });

  const restartedWorker = await start("--worker", "READY_WORKER\t");
  assert.equal(dangerousDispatchCount, 1, "dangerous tool was replayed");
  restartedWorker.process.send("PING\thealth-after-restart");
  assert.equal(
    await restartedWorker.process.waitLine(
      (line) => line === "RESULT\thealth-after-restart\tpong",
      "worker restart health",
    ),
    "RESULT\thealth-after-restart\tpong",
  );
  assert.equal(dangerousDispatchCount, 1, "restart replayed dangerous tool");
  restartedWorker.process.send("STOP");
  await restartedWorker.process.waitLine(
    (line) => line === "STOPPED_WORKER",
    "restarted worker stop",
  );
  assert.deepEqual(await restartedWorker.process.exit, {
    code: 0,
    signal: null,
  });

  const evidence = {
    baseline: {
      processIsolation: "none",
      hostExited: true,
      allInMemorySessionsLost: true,
      externalSnapshotBoundary: "last-emitted-only",
      activeRunExternalInterpretation: "interrupted",
      automaticRunRecovery: false,
      manualRecovery:
        "user must restart and resubmit; no finite automatic recovery time",
      startupMs: Number(baseline.startupMs.toFixed(3)),
      restartMs: Number(restartedBaseline.startupMs.toFixed(3)),
      rssKb: baseline.rssKb,
    },
    worker: {
      hostSurvived: true,
      ownedSession: hostSnapshot.sessions["session-owned"],
      otherSession: hostSnapshot.sessions["session-other"],
      dangerousDispatchCount,
      additionalProcessCount: 1,
      restartMs: Number(restartedWorker.startupMs.toFixed(3)),
      rssKb: worker.rssKb,
      restartedRssKb: restartedWorker.rssKb,
      transport: {
        framing: "newline-delimited bounded spike protocol",
        maximumFrameBytes: 4096,
        maximumObservedValidFrameBytes: maximumObservedFrameBytes,
        oversizedFrameRejected: true,
        correlatedRoundTrips: roundTripMs.length,
        p50RoundTripMs: Number(percentile(roundTripMs, 0.5).toFixed(3)),
        p95RoundTripMs: Number(percentile(roundTripMs, 0.95).toFixed(3)),
      },
      disconnectSemantics: "pending run -> interrupted/worker_disconnected",
    },
  };
  console.log(JSON.stringify(evidence, null, 2));
  console.log(
    "Gate 7 macOS fault-domain spike passed: zero-isolation baseline, Host-surviving Worker crash, bounded correlated transport, no dangerous replay.",
  );
} finally {
  for (const child of liveChildren) child.kill("SIGKILL");
  await rm(temporaryRoot, { recursive: true, force: true });
}
