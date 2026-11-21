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
//   4. an MCP server configured through the Bridge is reached from the child:
//      a Task calls its tool, the server process belongs to the window
//      process, and after the child is ended the next one is given the
//      server again and the tool still works;
//   5. a normal quit leaves no child behind, and no MCP server;
// and with it off:
//   6. no child ever exists, and a Task completes as before.
//
// Processes are only ever ended by PID. Nothing here reads or writes outside
// the harness's temporary platform home.

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
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

/// Every process whose command line mentions `marker`, with its parent.
async function processesMentioning(marker) {
  return asArray(
    await powershellJson(
      `ConvertTo-Json -Compress -Depth 2 -InputObject @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*${marker}*' -and $_.Name -eq 'node.exe' } | Select-Object ProcessId,ParentProcessId)`,
    ),
  ).map((row) => ({ pid: row.ProcessId, parentPid: row.ParentProcessId }));
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

/// One MCP tool call in a new Task, approved by hand. A Session that is
/// still preparing its catalog refuses the Run without starting it, and only
/// that refusal is retried.
async function mcpToolCall({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  taskId,
  label,
}) {
  const seen = {};
  provider.enqueue(
    (payload) => {
      const selected = payload.tools.filter((tool) =>
        tool.name.startsWith("mcp__"),
      );
      seen.offeredTools = selected.map((tool) => tool.name);
      assert.equal(selected.length, 1, JSON.stringify(seen.offeredTools));
      return toolSse(label, `${label}-call`, selected[0].name, {
        text: `echo-${label}`,
      });
    },
    (payload) => {
      const results = payload.messages
        .at(-1)
        .content.filter((part) => part.type === "tool_result");
      seen.toolResult = results[0];
      assert.equal(results.length, 1);
      assert.equal(
        results[0].is_error ?? false,
        false,
        JSON.stringify(results[0]),
      );
      assert.ok(JSON.stringify(results[0].content).includes(`echo-${label}`));
      return textSse(`${label}-done`, "MCP call completed");
    },
  );
  const started = await poll(
    async () => {
      const current = (await snapshot()).tasks.find(
        (task) => task.id === taskId,
      );
      const result = await invoke("metawork.tasks.run", {
        taskId,
        expectedBindingEpoch: current.binding.epoch,
        input: { kind: "text", text: label },
      });
      if (result.accepted) return result;
      assert.equal(result.runId, null);
      assert.equal(result.reason, "catalog_loading", JSON.stringify(result));
      return null;
    },
    runTimeoutMs,
    `${label}: Session catalog`,
  );
  const pending = await poll(
    async () => {
      const current = (await snapshot()).tasks.find(
        (task) => task.id === taskId,
      );
      return current.pendingUi?.runId === started.runId
        ? current.pendingUi
        : null;
    },
    runTimeoutMs,
    `${label}: permission`,
  );
  assert.equal(pending.kind, "permission");
  const answer = await invoke("metawork.tasks.respondUi", {
    taskId,
    runId: started.runId,
    requestId: pending.requestId,
    kind: "permission",
    permission: "allow_once",
  });
  assert.equal(answer.answered, true, JSON.stringify(answer));
  const finished = await poll(
    async () => {
      const current = (await snapshot()).tasks.find(
        (task) => task.id === taskId,
      );
      const run = current.runs.find((item) => item.id === started.runId);
      return run?.terminal && !current.activeOperation ? run : null;
    },
    runTimeoutMs,
    `${label}: terminal`,
  );
  assert.equal(
    finished.terminal.outcome,
    "completed",
    JSON.stringify(finished.terminal),
  );
  return { runId: started.runId, offeredTools: seen.offeredTools };
}

async function verifyMcp({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  appPid,
  workspaceId,
  workspaceEpoch,
  repositoryRoot,
  fixtureRoot,
  record,
}) {
  const tracePath = path.join(fixtureRoot, "execution-link-mcp.jsonl");
  const marker = "execution-link-mcp.jsonl";
  const mcpView = async () => (await snapshot({ mcpOnly: true })).mcp;
  const toolCalls = async () => {
    const text = await readFile(tracePath, "utf8").catch(() => "");
    return text
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
      .filter(
        (event) =>
          event.direction === "request" &&
          event.message?.method === "tools/call",
      ).length;
  };
  const initial = await mcpView();
  assert.equal(initial.managementHealth, "ready");
  const created = await invoke("metawork.mcp.createStdioServer", {
    expectedDesiredGeneration: initial.desiredGeneration,
    displayName: "Execution link MCP fixture",
    negotiation: "modern_only",
    timeoutMs: 8000,
    command: process.execPath,
    arguments: [
      path.join(repositoryRoot, "tests/fixtures/mcp_server.mjs"),
      "--transport",
      "stdio",
      "--protocol",
      "2026-07-28",
      "--ttl-ms",
      "60000",
      "--trace",
      tracePath,
    ],
    cwd: null,
    environmentNames: [],
  });
  assert.equal(created.outcome, "saved", JSON.stringify(created));
  let lastView;
  const connected = await poll(
    async () => {
      const current = await mcpView();
      lastView = current;
      return current.runtimeAlignment === "current" &&
        current.configurationApply === "idle" &&
        current.servers[0]?.runtimeStatus === "ready"
        ? current
        : null;
    },
    runTimeoutMs,
    "the MCP server is applied and activated",
  ).catch((error) => {
    throw new Error(`${error.message}: ${JSON.stringify(lastView)}`);
  });
  const allowed = await invoke("metawork.mcp.setAllowedTools", {
    expectedDesiredGeneration: connected.desiredGeneration,
    serverId: connected.servers[0].id,
    toolNames: ["echo"],
  });
  assert.equal(allowed.outcome, "saved", JSON.stringify(allowed));
  await poll(
    async () => (await mcpView()).servers[0]?.newTaskAccess === "available",
    runTimeoutMs,
    "MCP new Task access",
  );
  const createTask = async () => {
    const result = await invoke("metawork.tasks.create", {
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
    assert.equal(result.accepted, true, JSON.stringify(result));
    assert.deepEqual(result.mcpAuthority, {
      kind: "ready",
      selection: "selected",
    });
    // Named, so its first message is not sent for an automatic title the
    // fixture model does not expect.
    await invoke("metawork.tasks.rename", {
      taskId: result.taskId,
      title: "Execution link MCP verification",
    });
    return result.taskId;
  };

  const taskId = await createTask();
  const first = await mcpToolCall({
    invoke,
    snapshot,
    poll,
    provider,
    textSse,
    toolSse,
    taskId,
    label: "mcp-linked-first",
  });
  assert.equal(await toolCalls(), 1, "the call reached the MCP server");
  const hosts = await executionHosts(appPid);
  assert.equal(hosts.length, 1, JSON.stringify(hosts));
  // The server is the window's: started by its transport, not by the
  // execution process, which reaches it only through the link.
  const servers = await processesMentioning(marker);
  assert.equal(servers.length, 1, JSON.stringify(servers));
  assert.equal(
    servers[0].parentPid,
    appPid,
    JSON.stringify({ servers, appPid, hosts }),
  );
  record("mcp tool call", { hosts, servers, ...first });

  // A new execution process is given the same server. Product hears that
  // the catalog it held went with the old one and refreshes it, which starts
  // the new process; the next Task then has the tool again.
  await execFileAsync("taskkill", ["/PID", String(hosts[0].pid), "/F"], {
    windowsHide: true,
  });
  const refreshedHosts = await poll(
    async () => {
      const current = await executionHosts(appPid);
      const view = await mcpView();
      return current.length === 1 &&
        current[0].pid !== hosts[0].pid &&
        view.servers[0]?.newTaskAccess === "available"
        ? current
        : null;
    },
    runTimeoutMs,
    "the MCP catalog is refreshed in a new execution process",
  );
  record("mcp catalog refreshed after the kill", { hosts: refreshedHosts });
  const nextTask = await createTask();
  const second = await mcpToolCall({
    invoke,
    snapshot,
    poll,
    provider,
    textSse,
    toolSse,
    taskId: nextTask,
    label: "mcp-linked-after-kill",
  });
  assert.equal(
    await toolCalls(),
    2,
    "the call after the kill reached the MCP server",
  );
  const nextHosts = await executionHosts(appPid);
  assert.equal(nextHosts.length, 1, JSON.stringify(nextHosts));
  assert.notEqual(nextHosts[0].pid, hosts[0].pid);
  const serversAfter = await processesMentioning(marker);
  record("mcp tool call after the execution process was replaced", {
    hosts: nextHosts,
    servers: serversAfter,
    ...second,
  });
  return {
    hostPids: [hosts[0].pid, nextHosts[0].pid],
    serverPids: [
      ...new Set([...servers, ...serversAfter].map((server) => server.pid)),
    ],
    serverParentIsWindow: true,
    toolCalls: 2,
  };
}

export async function runExecutionLinkVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  sse,
  app,
  repositoryRoot,
  fixtureRoot,
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

    // 4. MCP, reached from the execution process through the window's
    // transport.
    evidence.mcp = await verifyMcp({
      invoke,
      snapshot,
      poll,
      provider,
      textSse,
      toolSse,
      appPid,
      workspaceId,
      workspaceEpoch,
      repositoryRoot,
      fixtureRoot,
      record,
    });
    const mcpServers = evidence.mcp.serverPids;

    // 5. A normal quit leaves no execution process behind, and no MCP
    // server.
    await stopApplication("execution link acceptance, switch on");
    // The harness's `poll` refuses to run once the application has exited,
    // which is exactly the state this waits in, so the wait is its own.
    const children = [
      firstHost.pid,
      secondHosts[0].pid,
      ...evidence.mcp.hostPids,
      ...mcpServers,
    ];
    let leftover = children;
    for (let waited = 0; waited <= 10_000; waited += 200) {
      leftover = (await processCounters(children)).map((row) => row.Id);
      if (leftover.length === 0) break;
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assert.deepEqual(
      leftover,
      [],
      "no execution process or MCP server outlives a normal quit",
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
