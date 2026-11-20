// Desktop acceptance for the development switch that runs AgentCore in its
// own process (issue 197, step one). Windows only.
//
// Selected by `METAWORK_EXECUTION_LINK_ONLY=1` inside the AgentCore vertical
// harness, which owns the isolated platform home, the automation build and
// the fixture model; the mode under test is whatever
// `METAWORK_DEV_EXECUTION_LINK` says in the harness's environment, which the
// application inherits. `scripts/execution-link-acceptance.mjs` runs both
// modes and compares their memory.
//
// With the switch on it checks the five acceptance points:
//   1. an ordinary Task completes and an `--execution-host` child exists;
//   2. ending that child by PID mid-reply leaves the window up, and the cut
//      reply is interrupted, recorded as incomplete and out of the
//      conversation;
//   3. the next message starts a new child, numbered above the dead one, and
//      carries the conversation on from the checkpoint;
//   4. a normal quit leaves no child behind;
// and with it off:
//   5. no child ever exists, and a Task completes as before.
//
// Processes are only ever ended by PID. Nothing here reads or writes outside
// the harness's temporary platform home.

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { processCounters } from "./memory-growth-vertical.mjs";
import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";

const execFileAsync = promisify(execFile);
const settleMs = 3000;
const runTimeoutMs = 60_000;

// The harness's title fixture accepts exactly this first input.
const firstInput = "Review";
const codeWord = "PELICAN";
const cutMarker = "CUTMARK";

function asArray(value) {
  if (value === null || value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

async function powershellJson(command) {
  const { stdout } = await execFileAsync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", command],
    { maxBuffer: 16 * 1024 * 1024, windowsHide: true },
  );
  const payload = stdout.trim().split(/\r?\n/).at(-1) ?? "";
  return payload.length === 0 ? null : JSON.parse(payload);
}

/// The application's `--execution-host` children, with their command lines.
export async function executionHosts(appPid) {
  return asArray(
    await powershellJson(
      `ConvertTo-Json -Compress -Depth 2 -InputObject @(Get-CimInstance Win32_Process -Filter "ParentProcessId=${appPid}" | Where-Object { $_.CommandLine -like '*--execution-host*' } | Select-Object ProcessId,CommandLine)`,
    ),
  ).map((row) => ({ pid: row.ProcessId, commandLine: row.CommandLine }));
}

async function memory(pids) {
  const rows = await processCounters(pids);
  return Object.fromEntries(
    rows.map((row) => [
      String(row.Id),
      {
        workingSetBytes: row.WorkingSet64,
        privateBytes: row.PrivateMemorySize64,
        threads: row.ThreadCount,
      },
    ]),
  );
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/// Text that stops before its end and waits there until the process
/// streaming it is ended.
function heldSse(sse, messageId, text, hold) {
  const body = sse([
    {
      type: "message_start",
      message: {
        id: messageId,
        role: "assistant",
        model: "fixture",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  ]);
  return {
    body,
    frameDelayMs: 0,
    initialDelayMs: 0,
    async beforeFrame(frame) {
      if (frame.includes("content_block_stop")) await hold;
    },
  };
}

export async function runExecutionLinkVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  sse,
  app,
  workspaceId,
  workspaceEpoch,
  stopApplication,
  readCheckpoint,
  evidencePath,
}) {
  assert.equal(
    process.platform,
    "win32",
    "the execution link acceptance runs on Windows",
  );
  const linked = process.env.METAWORK_DEV_EXECUTION_LINK === "1";
  const appPid = app.pid;
  const evidence = {
    mode: linked ? "linked" : "in_process",
    appPid,
    steps: [],
  };
  const record = (step, facts) => {
    evidence.steps.push({ step, ...facts });
    process.stdout.write(`execution link: ${step} ${JSON.stringify(facts)}\n`);
  };
  const write = async () => {
    await mkdir(path.dirname(evidencePath), { recursive: true });
    await writeFile(evidencePath, JSON.stringify(evidence, null, 2));
  };

  const taskOf = async (taskId) =>
    (await snapshot()).tasks.find((task) => task.id === taskId);
  const createTask = async () => {
    const created = await invoke("metawork.tasks.create", {
      projectId: null,
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      modelSelection: fixtureModelSelection(await snapshot()),
      expectedSkillCatalogRevision: null,
      expectedSkillSelectionRevision: null,
      approvalMode: "manual",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    return created.taskId;
  };
  const send = async (taskId, operationId, text) => {
    const sent = await invoke("metawork.tasks.sendInput", {
      taskId,
      operationId,
      input: { kind: "text", text },
    });
    assert.equal(sent.outcome, "accepted", JSON.stringify(sent));
  };
  const lastRunCompleted = (taskId, count) =>
    poll(
      async () => {
        const task = await taskOf(taskId);
        return task?.activeOperation === null &&
          task.runs.length === count &&
          task.runs.at(-1)?.terminal?.outcome === "completed"
          ? task.runs.at(-1)
          : null;
      },
      runTimeoutMs,
      `Task ${taskId} run ${count} completed`,
    );

  try {
    // Idle: nothing needs the execution process yet.
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    const idleHosts = await executionHosts(appPid);
    assert.deepEqual(
      idleHosts,
      [],
      "no execution process before a Task needs one",
    );
    evidence.idle = { hosts: idleHosts, memory: await memory([appPid]) };
    record("idle", evidence.idle);

    // 1. An ordinary Task.
    const taskId = await createTask();
    provider.enqueue(
      textSse("link-turn-1", `Noted: the code word is ${codeWord}.`),
    );
    await send(taskId, "link-turn-1", firstInput);
    await lastRunCompleted(taskId, 1);
    const firstHosts = await executionHosts(appPid);
    if (linked) {
      assert.equal(
        firstHosts.length,
        1,
        `one execution process: ${JSON.stringify(firstHosts)}`,
      );
    } else {
      assert.deepEqual(
        firstHosts,
        [],
        "the switch is off: no execution process",
      );
    }
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    evidence.afterTask = {
      hosts: firstHosts,
      memory: await memory([appPid, ...firstHosts.map((host) => host.pid)]),
    };
    record("one task completed", evidence.afterTask);

    if (!linked) {
      await stopApplication("execution link acceptance, switch off");
      evidence.quit = { exitedCleanly: true, hostsAfterQuit: [] };
      record("quit", evidence.quit);
      await write();
      return evidence;
    }

    // The conversation the next process has to carry on is in a checkpoint.
    const firstHost = firstHosts[0];
    evidence.turnOneCheckpoint = await poll(
      async () => {
        const blob = (await readCheckpoint(taskId))?.checkpoint?.blob;
        return blob && String(blob.generation) !== "0" ? blob : null;
      },
      runTimeoutMs,
      "turn one checkpoint",
    );
    record("turn one checkpoint", evidence.turnOneCheckpoint);

    // 2. End the child by PID while a reply is streaming.
    let release;
    const hold = new Promise((resolve) => {
      release = resolve;
    });
    provider.enqueue(
      heldSse(sse, "link-turn-2", `Partial reply ${cutMarker}`, hold),
    );
    await send(taskId, "link-turn-2", "Tell me the code word again, slowly.");
    await poll(
      async () => {
        const run = (await taskOf(taskId))?.runs.at(-1);
        const output = run?.output;
        return output &&
          (output.provisional.includes(cutMarker) ||
            output.response.includes(cutMarker))
          ? true
          : null;
      },
      runTimeoutMs,
      "partial reply visible",
    );
    const { stdout: killed } = await execFileAsync(
      "taskkill",
      ["/PID", String(firstHost.pid), "/F"],
      { windowsHide: true },
    );
    record("ended by PID", { pid: firstHost.pid, taskkill: killed.trim() });
    const cut = await poll(
      async () => {
        const run = (await taskOf(taskId))?.runs[1];
        return run?.terminal ? run : null;
      },
      runTimeoutMs,
      "cut run terminal",
    );
    release();
    assert.ok(
      alive(appPid),
      "the window process outlives its execution process",
    );
    assert.equal(
      cut.terminal.outcome,
      "interrupted",
      JSON.stringify(cut.terminal),
    );
    assert.equal(
      cut.terminal.recordingIncomplete,
      true,
      JSON.stringify(cut.terminal),
    );
    assert.equal(cut.conversationCoverage, "excluded", JSON.stringify(cut));
    const afterKill = await executionHosts(appPid);
    assert.deepEqual(afterKill, [], "no execution process until one is needed");
    evidence.cut = {
      windowAlive: true,
      terminal: cut.terminal,
      conversationCoverage: cut.conversationCoverage,
      visibleOutput: cut.output.response || cut.output.provisional,
      hostsAfterKill: afterKill,
    };
    record("cut run", evidence.cut);

    // 3. The next message: a new process, carrying the conversation on.
    const seen = {};
    provider.enqueue((payload) => {
      const text = JSON.stringify(payload.messages);
      seen.modelSawTurnOne = text.includes(codeWord);
      seen.modelSawCutReply = text.includes(cutMarker);
      return textSse("link-turn-3", `The code word was ${codeWord}.`);
    });
    await send(taskId, "link-turn-3", "What was the code word?");
    await lastRunCompleted(taskId, 3);
    const secondHosts = await executionHosts(appPid);
    assert.equal(secondHosts.length, 1, JSON.stringify(secondHosts));
    assert.notEqual(secondHosts[0].pid, firstHost.pid);
    assert.match(secondHosts[0].commandLine, /--session-id-floor=4294967296/);
    assert.equal(seen.modelSawTurnOne, true, "the model saw turn one");
    assert.equal(
      seen.modelSawCutReply,
      false,
      "the model did not see the cut reply",
    );
    evidence.resumed = { hosts: secondHosts, ...seen };
    record("resumed", evidence.resumed);
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    evidence.afterResume = {
      memory: await memory([appPid, secondHosts[0].pid]),
    };
    record("after resume", evidence.afterResume);

    // 4. A normal quit leaves no execution process behind.
    await stopApplication("execution link acceptance, switch on");
    // The harness's `poll` refuses to run once the application has exited,
    // which is exactly the state this waits in, so the wait is its own.
    const children = [firstHost.pid, secondHosts[0].pid];
    let leftover = children;
    for (let waited = 0; waited <= 10_000; waited += 200) {
      leftover = (await processCounters(children)).map((row) => row.Id);
      if (leftover.length === 0) break;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assert.deepEqual(
      leftover,
      [],
      "no execution process outlives a normal quit",
    );
    evidence.quit = { exitedCleanly: true, hostsAfterQuit: leftover };
    record("quit", evidence.quit);
    await write();
    return evidence;
  } catch (error) {
    evidence.error = String(error?.stack ?? error);
    await write();
    throw error;
  }
}
