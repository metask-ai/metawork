import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { access, mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

// Drives the real Application coordinator and owner timer through the existing
// desktop automation Bridge. Only the local MCP server and model are fixtures.
export async function runMcpLifecycleVertical({
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
  repositoryRoot,
  fixtureRoot,
  evidenceDir,
}) {
  const tracePath = path.join(fixtureRoot, "mcp-desktop.jsonl");
  const gate = path.join(fixtureRoot, "mcp-refresh");
  await writeFile(`${gate}.release`, "release");
  const server = spawn(
    process.execPath,
    [
      path.join(repositoryRoot, "tests/fixtures/mcp_server.mjs"),
      "--transport",
      "http",
      "--protocol",
      "2026-07-28",
      "--ttl-ms",
      "30000",
      "--trace",
      tracePath,
      "--refresh-gate",
      gate,
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  let output = "";
  let failure;
  let exit;
  server.stdout.setEncoding("utf8");
  server.stdout.on("data", (chunk) => {
    output += chunk;
  });
  server.stderr.on("data", () => {
    failure ??= new Error("MCP fixture wrote to stderr");
  });
  server.once("error", (error) => {
    failure = error;
  });
  const exited = new Promise((resolve) =>
    server.once("exit", (code, signal) => {
      exit = { code, signal };
      resolve(exit);
    }),
  );
  const wait = (operation, duration, label) =>
    poll(
      async () => {
        if (failure) throw failure;
        if (exit)
          throw new Error(`MCP fixture exited: ${JSON.stringify(exit)}`);
        return operation();
      },
      duration,
      label,
    );
  const trace = async () =>
    (await readFile(tracePath, "utf8"))
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  const requests = async (method) =>
    (await trace()).filter(
      (event) =>
        event.direction === "request" && event.message?.method === method,
    );
  const task = async (id) =>
    (await snapshot()).tasks.find((item) => item.id === id);
  try {
    const endpoint = await wait(
      async () => {
        const line = output.split("\n").find(Boolean);
        return line ? JSON.parse(line).endpoint : null;
      },
      10_000,
      "MCP fixture listener",
    );
    const initial = (await snapshot()).mcp;
    assert.equal(initial.managementHealth, "ready");
    const created = await invoke("metawork.mcp.createHttpServer", {
      expectedDesiredGeneration: initial.desiredGeneration,
      displayName: "Desktop MCP fixture",
      negotiation: "modern_only",
      timeoutMs: 8000,
      endpoint,
      authMode: "none",
      headerNames: [],
    });
    assert.equal(created.outcome, "saved", JSON.stringify(created));
    const connected = await wait(
      async () => {
        const current = (await snapshot()).mcp;
        return current.runtimeAlignment === "current" &&
          current.configurationApply === "idle" &&
          current.servers[0]?.runtimeStatus === "ready"
          ? current
          : null;
      },
      15_000,
      "Application applies and activates MCP",
    );
    const originalReadyAt = Date.now();
    const serverId = connected.servers[0].id;
    const allowed = await invoke("metawork.mcp.setAllowedTools", {
      expectedDesiredGeneration: connected.desiredGeneration,
      serverId,
      toolNames: ["echo"],
    });
    assert.equal(allowed.outcome, "saved", JSON.stringify(allowed));
    await wait(
      async () =>
        (await snapshot()).mcp.servers[0]?.newTaskAccess === "available",
      10_000,
      "MCP new Task authority",
    );
    const chosen = await invoke("metawork.workspaces.choose", {});
    const workspace = (await snapshot()).workspaces.find(
      (item) => item.id === chosen?.workspaceId,
    );
    assert.ok(workspace, "Workspace choice must have a committed identity");
    const create = async () => {
      const admission = (await snapshot()).newTaskAdmission;
      const result = await invoke("metawork.tasks.create", {
        workspace: {
          kind: "manual",
          workspaceId: workspace.id,
          expectedWorkspaceEpoch: workspace.epoch,
        },
        expectedExecutionGeneration: admission.activeGeneration,
        expectedSelectionRevision: admission.activeSelectionRevision,
        modelSelection: null,
        expectedSkillCatalogRevision: null,
        expectedSkillSelectionRevision: null,
        approvalMode: "manual",
      });
      assert.equal(result.accepted, true, JSON.stringify(result));
      assert.deepEqual(result.mcpAuthority, {
        kind: "ready",
        selection: "selected",
      });
      await invoke("metawork.tasks.rename", {
        taskId: result.taskId,
        title: "MCP lifecycle verification",
      });
      return result.taskId;
    };
    const run = async (taskId, label) => {
      provider.enqueue(
        (payload) => {
          const selected = payload.tools.filter((tool) =>
            tool.name.startsWith("mcp__"),
          );
          assert.equal(selected.length, 1);
          return toolSse(label, `${label}-call`, selected[0].name, {
            text: "desktop-echo",
          });
        },
        (payload) => {
          const results = payload.messages
            .at(-1)
            .content.filter((part) => part.type === "tool_result");
          assert.equal(results.length, 1);
          assert.equal(results[0].is_error ?? false, false);
          assert.ok(
            JSON.stringify(results[0].content).includes("desktop-echo"),
          );
          return textSse(`${label}-done`, "MCP desktop completed");
        },
      );
      const before = await task(taskId);
      const started = await invoke("metawork.tasks.run", {
        taskId,
        expectedBindingEpoch: before.binding.epoch,
        input: { kind: "text", text: label },
      });
      assert.equal(started.accepted, true, JSON.stringify(started));
      const pending = await wait(
        async () => {
          const current = await task(taskId);
          return current.pendingUi?.runId === started.runId
            ? current.pendingUi
            : null;
        },
        15_000,
        `${label} permission`,
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
      const finished = await wait(
        async () => {
          const current = await task(taskId);
          const last = current.runs.find((item) => item.id === started.runId);
          return last?.terminal && !current.activeOperation ? current : null;
        },
        15_000,
        `${label} terminal`,
      );
      assert.equal(
        finished.runs.find((item) => item.id === started.runId).phase,
        "completed",
      );
      return {
        runId: started.runId,
        requestId: pending.requestId,
        bindingEpoch: finished.binding.epoch,
      };
    };
    const originalTask = await create();
    const firstRun = await run(originalTask, "before-default-ttl");
    const initialLists = (await requests("tools/list")).length;
    await unlink(`${gate}.release`);
    await unlink(`${gate}.waiting`).catch((error) => {
      if (error.code !== "ENOENT") throw error;
    });
    await wait(
      async () => {
        try {
          await access(`${gate}.waiting`);
          return true;
        } catch {
          return false;
        }
      },
      32_000,
      "default 30-second proactive timer reaches Core IO",
    );
    const proactiveAtMs = Date.now() - originalReadyAt;
    const during = (await snapshot()).mcp;
    assert.equal(during.operation, "idle");
    assert.equal(during.servers[0].newTaskAccess, "available");
    const duringTask = await create();
    await writeFile(`${gate}.release`, "release");
    await wait(
      async () => Date.now() - originalReadyAt >= 32_000,
      35_000,
      "cross original default TTL",
    );
    const secondRun = await run(originalTask, "after-default-ttl");
    assert.equal(secondRun.bindingEpoch, firstRun.bindingEpoch);
    assert.notEqual(secondRun.requestId, firstRun.requestId);
    await run(duringTask, "created-during-proactive-refresh");
    assert.equal((await task(originalTask)).runs.length, 2);
    assert.equal((await requests("tools/call")).length, 3);
    const finalLists = (await requests("tools/list")).length;
    assert.equal(
      finalLists,
      initialLists + 1,
      "one automatic full refresh, independent of snapshot polling",
    );
    const final = (await snapshot()).mcp;
    assert.equal(final.servers[0].newTaskAccess, "available");
    const report = {
      protocol: "2026-07-28",
      ttlMs: 30_000,
      proactiveAtMs,
      observedDurationMs: Date.now() - originalReadyAt,
      initialToolsLists: initialLists,
      finalToolsLists: finalLists,
      actualToolCalls: 3,
      originalTaskRuns: 2,
      distinctOnceRequests: firstRun.requestId !== secondRun.requestId,
      originalBindingPreserved:
        secondRun.bindingEpoch === firstRun.bindingEpoch,
      createdDuringRefresh: "ready(selected)",
      validBackgroundOperation: during.operation,
      limits: [
        "Local synthetic HTTP and Provider; does not qualify remote OAuth quotas or canonical origin isolation.",
      ],
    };
    await mkdir(evidenceDir, { recursive: true });
    await writeFile(
      path.join(evidenceDir, "mcp-desktop-report.json"),
      `${JSON.stringify(report, null, 2)}\n`,
    );
    console.log(`MCP desktop lifecycle passed: ${JSON.stringify(report)}`);
  } finally {
    await writeFile(`${gate}.release`, "release");
    if (!exit) server.kill("SIGTERM");
    await exited;
  }
}
