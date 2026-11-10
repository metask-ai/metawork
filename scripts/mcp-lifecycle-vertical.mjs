import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
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
  protocolVersion = "2026-07-28",
  transport = "http",
}) {
  assert.ok(
    ["2026-07-28", "2025-11-25", "2025-06-18"].includes(protocolVersion),
  );
  assert.ok(["http", "stdio"].includes(transport));
  const tracePath = path.join(fixtureRoot, "mcp-desktop.jsonl");
  const gate = path.join(fixtureRoot, "mcp-refresh");
  await writeFile(`${gate}.release`, "release");
  const argumentsFor = (kind) => [
    path.join(repositoryRoot, "tests/fixtures/mcp_server.mjs"),
    "--transport",
    kind,
    "--protocol",
    protocolVersion,
    "--ttl-ms",
    "30000",
    "--trace",
    tracePath,
    "--refresh-gate",
    gate,
  ];
  // STDIO is launched and owned by the real Application transport; the
  // external listener is needed only for HTTP.
  const server =
    transport === "http"
      ? spawn(process.execPath, argumentsFor("http"), {
          stdio: ["ignore", "pipe", "pipe"],
        })
      : null;
  let output = "";
  let failure;
  let exit;
  server?.stdout.setEncoding("utf8");
  server?.stdout.on("data", (chunk) => {
    output += chunk;
  });
  server?.stderr.on("data", () => {
    failure ??= new Error("MCP fixture wrote to stderr");
  });
  server?.once("error", (error) => {
    failure = error;
  });
  const exited = server
    ? new Promise((resolve) =>
        server.once("exit", (code, signal) => {
          exit = { code, signal };
          resolve(exit);
        }),
      )
    : Promise.resolve();
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
    (await snapshot({ taskId: id })).tasks.find((item) => item.id === id);
  const mcpView = async () => (await snapshot({ mcpOnly: true })).mcp;
  try {
    const endpoint =
      transport === "http"
        ? await wait(
            async () => {
              const line = output.split("\n").find(Boolean);
              return line ? JSON.parse(line).endpoint : null;
            },
            10_000,
            "MCP fixture listener",
          )
        : null;
    const initial = await mcpView();
    assert.equal(initial.managementHealth, "ready");
    const common = {
      expectedDesiredGeneration: initial.desiredGeneration,
      displayName: "Desktop MCP fixture",
      negotiation:
        protocolVersion === "2026-07-28" ? "modern_only" : "automatic",
      timeoutMs: 8000,
    };
    if (transport === "http") {
      const draft = {
        expectedDesiredGeneration: initial.desiredGeneration,
        displayName: common.displayName,
        endpoint,
      };
      const rejected = await invoke("metawork.mcp.probeHttpDraft", {
        ...draft,
        endpoint: new URL("/missing", endpoint).href,
      });
      assert.deepEqual(rejected, { outcome: "failed" });
      assert.deepEqual(await invoke("metawork.mcp.probeHttpDraft", draft), {
        outcome: "connected",
      });
      assert.deepEqual(
        await invoke("metawork.mcp.probeHttpDraft", {
          ...draft,
          endpoint: new URL("/mcp/draft-entry", endpoint).href,
        }),
        {
          outcome: "redirected",
          endpoint: new URL("/mcp/draft-test", endpoint).href,
        },
      );
      assert.deepEqual(
        await invoke("metawork.mcp.probeHttpDraft", {
          ...draft,
          endpoint: new URL("/mcp/cross-origin/", endpoint).href,
        }),
        { outcome: "failed" },
      );
      assert.deepEqual(
        await invoke("metawork.mcp.probeHttpDraft", {
          ...draft,
          endpoint: new URL("/mcp/draft-test", endpoint).href,
        }),
        { outcome: "authentication_required" },
      );
      assert.deepEqual(
        await invoke("metawork.mcp.verifyAndAddHttpDraft", {
          ...draft,
          endpoint: new URL("/mcp/draft-test", endpoint).href,
          headers: [
            { name: "Authorization", value: "Bearer wrong-fixture-token" },
          ],
        }),
        { outcome: "failed" },
      );
      const afterProbe = await mcpView();
      assert.equal(afterProbe.desiredGeneration, initial.desiredGeneration);
      assert.deepEqual(afterProbe.servers, initial.servers);
    }
    const created =
      transport === "http"
        ? await invoke("metawork.mcp.verifyAndAddHttpDraft", {
            expectedDesiredGeneration: initial.desiredGeneration,
            displayName: common.displayName,
            endpoint,
            headers: [],
          })
        : await invoke("metawork.mcp.createStdioServer", {
            ...common,
            command: process.execPath,
            arguments: argumentsFor("stdio"),
            cwd: null,
            environmentNames: [],
          });
    assert.equal(created.outcome, "saved", JSON.stringify(created));
    const connected = await wait(
      async () => {
        const current = await mcpView();
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
      async () => (await mcpView()).servers[0]?.newTaskAccess === "available",
      10_000,
      "MCP new Task authority",
    );
    const chosen = await invoke("metawork.workspaces.choose", {});
    const workspace = (await snapshot()).workspaces.find(
      (item) => item.id === chosen?.workspaceId,
    );
    assert.ok(workspace, "Workspace choice must have a committed identity");
    // The model selection is unchanged throughout this fixture. Reuse its
    // captured CAS input so creation at the held refresh boundary is a single
    // Bridge mutation, as it is for an already-rendered New Task form.
    const modelSnapshot = await snapshot();
    const create = async (approvalMode = "manual") => {
      const result = await invoke("metawork.tasks.create", {
        workspace: {
          kind: "manual",
          workspaceId: workspace.id,
          expectedWorkspaceEpoch: workspace.epoch,
        },

        modelSelection: fixtureModelSelection(modelSnapshot),
        expectedSkillCatalogRevision: null,
        expectedSkillSelectionRevision: null,
        approvalMode,
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
    const run = async (taskId, label, automatic = false) => {
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
      // A fresh Session can still be preparing its catalog. Only a definite
      // non-admission with no Run may be retried; never replay accepted input.
      const started = await wait(
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
          assert.equal(
            result.reason,
            "catalog_loading",
            JSON.stringify(result),
          );
          return null;
        },
        10_000,
        "fresh MCP Session catalog preparation",
      );
      assert.equal(started.accepted, true, JSON.stringify(started));
      let pending = null;
      if (!automatic) {
        pending = await wait(
          async () => {
            const current = await task(taskId);
            return current.pendingUi?.runId === started.runId
              ? current.pendingUi
              : null;
          },
          60_000,
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
      }
      const finished = await wait(
        async () => {
          const current = await task(taskId);
          if (automatic) {
            assert.notEqual(
              current.permissionReviewState,
              "needs_user",
              "MCP permission must reach the reviewer without human handoff",
            );
          }
          const last = current.runs.find((item) => item.id === started.runId);
          return last?.terminal && !current.activeOperation ? current : null;
        },
        60_000,
        `${label} terminal`,
      );
      assert.equal(
        finished.runs.find((item) => item.id === started.runId).phase,
        "completed",
      );
      const record = finished.uiHistory.find(
        (entry) => entry.runId === started.runId && entry.kind === "permission",
      );
      assert.equal(record.permission.toolNamespace, "mcp");
      if (automatic) {
        assert.equal(finished.approvalMode, "auto_review");
        assert.equal(finished.pendingUi, null);
        assert.equal(record.answeredBy, "reviewer");
        assert.equal(record.state, "allowed_once");
        assert.equal(record.review.outcome, "allow_once");
        assert.equal(record.permission.usedSessionRule, false);
      }
      return {
        runId: started.runId,
        requestId: pending?.requestId ?? record.requestId,
        bindingEpoch: finished.binding.epoch,
      };
    };
    const originalTask = await create();
    const firstRun = await run(originalTask, "before-default-ttl");
    const initialLists = (await requests("tools/list")).length;
    // STDIO refresh may open a new owned child. Its in-process list counter
    // starts over, so arm the transport-independent IO pause explicitly.
    await writeFile(`${gate}.armed`, "armed");
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
    const during = await mcpView();
    assert.equal(during.operation, "idle");
    assert.equal(during.servers[0].newTaskAccess, "available");
    assert.equal(
      (await requests("tools/list")).length,
      initialLists + 1,
      "only one shared refresh can reach the held IO boundary",
    );
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
    const listRequests = await requests("tools/list");
    const finalLists = listRequests.length;
    const automatic = listRequests.slice(initialLists);
    const refreshIntervalsMs = automatic
      .slice(1)
      .map((item, index) => item.observedAtMs - automatic[index].observedAtMs);
    // CLI collection can outlast a second normal 25-second period. Count it,
    // and check actual server arrival times rather than assuming one period.
    // The one-second allowance covers observation/descriptor rounding.
    assert.ok(
      refreshIntervalsMs.every((interval) => interval >= 24_000),
      "snapshot polling must not accelerate the default-TTL schedule",
    );
    const final = await mcpView();
    assert.equal(final.servers[0].newTaskAccess, "available");
    assert.equal(provider.mcpReviewRequests, 0);
    const automaticTask = await create("auto_review");
    const automaticFirst = await run(
      automaticTask,
      "mcp-automatic-first",
      true,
    );
    const automaticSecond = await run(
      automaticTask,
      "mcp-automatic-second",
      true,
    );
    assert.notEqual(automaticFirst.requestId, automaticSecond.requestId);
    assert.equal(automaticFirst.bindingEpoch, automaticSecond.bindingEpoch);
    assert.equal(provider.mcpReviewRequests, 2);
    assert.equal((await requests("tools/call")).length, 5);
    const report = {
      protocol: protocolVersion,
      transport,
      ttlMs: 30_000,
      proactiveAtMs,
      observedDurationMs: Date.now() - originalReadyAt,
      initialToolsLists: initialLists,
      finalToolsLists: finalLists,
      automaticRefreshes: automatic.length,
      refreshIntervalsMs,
      actualToolCalls: 5,
      automaticReviews: provider.mcpReviewRequests,
      automaticHumanAnswers: 0,
      automaticDistinctRequests:
        automaticFirst.requestId !== automaticSecond.requestId,
      originalTaskRuns: 2,
      distinctOnceRequests: firstRun.requestId !== secondRun.requestId,
      originalBindingPreserved:
        secondRun.bindingEpoch === firstRun.bindingEpoch,
      createdDuringRefresh: "ready(selected)",
      validBackgroundOperation: during.operation,
      limits: [
        "Local synthetic MCP and Provider; does not qualify remote OAuth quotas or canonical origin isolation.",
      ],
    };
    await mkdir(evidenceDir, { recursive: true });
    await writeFile(
      path.join(
        evidenceDir,
        `mcp-desktop-${protocolVersion}-${transport}.json`,
      ),
      `${JSON.stringify(report, null, 2)}\n`,
    );
    console.log(`MCP desktop lifecycle passed: ${JSON.stringify(report)}`);
  } finally {
    await writeFile(`${gate}.release`, "release");
    if (!exit) server?.kill("SIGTERM");
    await exited;
  }
}
