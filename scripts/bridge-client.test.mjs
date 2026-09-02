import assert from "node:assert/strict";
import test from "node:test";

import {
  BridgeClient,
  BridgeCommandTimeoutError,
  RendererBridgeContractError,
} from "../frontend/src/bridge/client.ts";

function bridgeWith(invoke) {
  return {
    invoke,
    on() {
      return () => undefined;
    },
  };
}

test("Renderer Bridge connect negotiates the exact contract before returning a generation", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return {
        accepted: true,
        contractId: "metawork.renderer-bridge",
        contractRevision: 1,
        generation: "3",
        error: null,
      };
    }),
  });

  assert.equal(await client.connect(), "3");
  assert.deepEqual(calls, [
    {
      command: "metawork.events.connect",
      payload: {
        contractId: "metawork.renderer-bridge",
        contractRevision: 1,
      },
    },
  ]);
});

test("Renderer Bridge mismatch and malformed acceptance are terminal contract failures", async () => {
  for (const [response, code] of [
    [
      {
        accepted: false,
        contractId: "metawork.renderer-bridge",
        contractRevision: 1,
        generation: null,
        error: "revision_mismatch",
      },
      "revision_mismatch",
    ],
    [
      {
        accepted: true,
        contractId: "other.renderer-bridge",
        contractRevision: 1,
        generation: "1",
        error: null,
      },
      "invalid_response",
    ],
  ]) {
    const client = new BridgeClient({
      bridge: bridgeWith(async () => response),
    });
    await assert.rejects(
      client.connect(),
      (error) =>
        error instanceof RendererBridgeContractError && error.code === code,
    );
  }
});

test("Product store recovery uses revision-bound typed commands", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { outcome: "recovered" };
    }),
  });

  assert.deepEqual(await client.recoverTaskHistory("17"), {
    outcome: "recovered",
  });
  assert.deepEqual(await client.recoverScheduledTaskStore("18"), {
    outcome: "recovered",
  });
  assert.deepEqual(calls, [
    {
      command: "metawork.tasks.recoverHistory",
      payload: { expectedRevision: "17" },
    },
    {
      command: "metawork.scheduledTasks.recoverStore",
      payload: { expectedRevision: "18" },
    },
  ]);
});

test("Task model selection carries source-qualified authority", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return {
        accepted: true,
        taskId: "11",
        model: "model-2",
        reason: null,
      };
    }),
  });

  assert.deepEqual(
    await client.selectTaskModel(
      "11",
      "model-1",
      "17",
      { sourceId: "metask:key-1", modelId: "model-2" },
      "19",
      "23",
    ),
    { accepted: true, taskId: "11", model: "model-2", reason: null },
  );
  assert.deepEqual(calls, [
    {
      command: "metawork.tasks.selectModel",
      payload: {
        taskId: "11",
        expectedModel: "model-1",
        expectedExecutionGeneration: "17",
        targetModelRef: {
          sourceId: "metask:key-1",
          modelId: "model-2",
        },
        expectedSourceGeneration: "19",
        expectedCatalogGeneration: "23",
      },
    },
  ]);
});

test("native shortcut events stay behind the Bridge client boundary", () => {
  let listener = null;
  let removed = false;
  const client = new BridgeClient({
    bridge: {
      async invoke() {
        return null;
      },
      on(name, consume) {
        assert.equal(name, "shortcut");
        listener = consume;
        return () => {
          removed = true;
        };
      },
    },
  });
  const received = [];

  const unsubscribe = client.onShortcut((shortcut) => received.push(shortcut));
  listener({ id: "settings.open" });
  unsubscribe();

  assert.deepEqual(received, [{ id: "settings.open" }]);
  assert.equal(removed, true);
});

test("a wedged mutation times out once and is never replayed by the Bridge client", async () => {
  let calls = 0;
  const client = new BridgeClient({
    bridge: bridgeWith(() => {
      calls += 1;
      return new Promise(() => undefined);
    }),
    commandTimeoutMs: 10,
  });

  await assert.rejects(
    client.beginLogin(),
    (error) =>
      error instanceof BridgeCommandTimeoutError &&
      error.command === "metawork.account.beginLogin",
  );
  assert.equal(calls, 1);
});

test("a native Workspace picker remains user-controlled instead of command-timed", async () => {
  const client = new BridgeClient({
    bridge: bridgeWith(
      () =>
        new Promise((resolve) =>
          setTimeout(() => resolve({ selected: false }), 25),
        ),
    ),
    commandTimeoutMs: 5,
  });

  assert.deepEqual(await client.chooseWorkspace(), { selected: false });
});

test("product BridgeClient exposes no native window actions or state", () => {
  const client = new BridgeClient({
    bridge: bridgeWith(async () => null),
  });
  for (const method of [
    "beginWindowDrag",
    "controlWindow",
    "openWindowSystemMenu",
    "windowState",
  ])
    assert.equal(client[method], undefined);
});

test("MCP management uses only typed revision 1 commands", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      if (command === "metawork.mcp.applyConfiguration")
        return { outcome: "started" };
      if (command === "metawork.mcp.refreshCatalog")
        return { outcome: "started" };
      if (command === "metawork.mcp.testConnection")
        return { outcome: "started" };
      if (command === "metawork.mcp.authorizeOAuth")
        return { outcome: "started", operationId: "oauth-op" };
      if (command === "metawork.mcp.cancelAuthorization")
        return { outcome: "cancelled" };
      return { outcome: "saved", desiredGeneration: "8" };
    }),
  });

  const http = {
    displayName: "Search",
    negotiation: "automatic",
    timeoutMs: 30000,
    endpoint: "https://mcp.example.test",
    authMode: "oauth",
    headerNames: [],
    registration: { kind: "automatic" },
  };
  await client.createMcpStdioServer("7", {
    displayName: "Files",
    negotiation: "modern_only",
    timeoutMs: 5000,
    command: "mcp-files",
    arguments: ["--safe"],
    cwd: null,
    environmentNames: ["TOKEN"],
  });
  await client.createMcpHttpServer("7", http);
  await client.updateMcpHttpConnection("7", "server-1", http);
  await client.renameMcpServer("7", "server-1", "Search API");
  await client.approveMcpConnection("7", "server-1");
  await client.captureMcpSecret("7", "server-1", {
    kind: "oauth_client_secret",
  });
  await client.authorizeMcpOAuth("7", "server-1");
  await client.cancelMcpAuthorization("oauth-op");
  await client.setMcpServerEnabled("7", "server-1", true);
  await client.setMcpAllowedTools("7", "server-1", ["search", "fetch"]);
  await client.removeMcpServer("7", "server-1");
  await client.testMcpConnection("7", "server-1");
  await client.applyMcpConfiguration();
  await client.refreshMcpCatalog();

  assert.deepEqual(calls, [
    {
      command: "metawork.mcp.createStdioServer",
      payload: {
        expectedDesiredGeneration: "7",
        displayName: "Files",
        negotiation: "modern_only",
        timeoutMs: 5000,
        command: "mcp-files",
        arguments: ["--safe"],
        cwd: null,
        environmentNames: ["TOKEN"],
      },
    },
    {
      command: "metawork.mcp.createHttpServer",
      payload: {
        expectedDesiredGeneration: "7",
        ...http,
      },
    },
    {
      command: "metawork.mcp.updateHttpConnection",
      payload: {
        expectedDesiredGeneration: "7",
        serverId: "server-1",
        ...http,
      },
    },
    {
      command: "metawork.mcp.renameServer",
      payload: {
        expectedDesiredGeneration: "7",
        serverId: "server-1",
        displayName: "Search API",
      },
    },
    {
      command: "metawork.mcp.approveConnection",
      payload: { expectedDesiredGeneration: "7", serverId: "server-1" },
    },
    {
      command: "metawork.mcp.captureSecret",
      payload: {
        expectedDesiredGeneration: "7",
        serverId: "server-1",
        slot: { kind: "oauth_client_secret" },
      },
    },
    {
      command: "metawork.mcp.authorizeOAuth",
      payload: { expectedDesiredGeneration: "7", serverId: "server-1" },
    },
    {
      command: "metawork.mcp.cancelAuthorization",
      payload: { operationId: "oauth-op" },
    },
    {
      command: "metawork.mcp.setServerEnabled",
      payload: {
        expectedDesiredGeneration: "7",
        serverId: "server-1",
        enabled: true,
      },
    },
    {
      command: "metawork.mcp.setAllowedTools",
      payload: {
        expectedDesiredGeneration: "7",
        serverId: "server-1",
        toolNames: ["search", "fetch"],
      },
    },
    {
      command: "metawork.mcp.removeServer",
      payload: { expectedDesiredGeneration: "7", serverId: "server-1" },
    },
    {
      command: "metawork.mcp.testConnection",
      payload: { expectedDesiredGeneration: "7", serverId: "server-1" },
    },
    { command: "metawork.mcp.applyConfiguration", payload: {} },
    { command: "metawork.mcp.refreshCatalog", payload: {} },
  ]);
});

test("the fixed revision 1 contract keeps Models selection separate from Product execution identity", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      if (command === "metawork.models.configureMetaskSelection")
        return { accepted: true, errorCode: "none", attemptId: null };
      if (command === "metawork.tasks.create")
        return {
          accepted: true,
          taskId: "11",
          bindingEpoch: "13",
          reason: null,
        };
      if (command === "metawork.tasks.run")
        return {
          accepted: true,
          taskId: "11",
          runId: "17",
          reason: null,
        };
      if (command === "metawork.tasks.compact")
        return {
          accepted: true,
          taskId: "11",
          operationId: "19",
          reason: null,
        };
      if (command === "metawork.tasks.restore")
        return {
          accepted: true,
          taskId: "11",
          attemptId: "23",
          reason: null,
        };
      if (command === "metawork.tasks.cancelCompact")
        return {
          taskId: "11",
          operationId: "19",
          cancelRequested: true,
        };
      if (command === "metawork.workspaces.refreshSkillCatalog")
        return { accepted: true, workspaceId: "7", reason: null };
      if (command === "metawork.skills.refreshCatalog")
        return { accepted: true, reason: null };
      if (command === "metawork.skills.setEnabled")
        return { applied: true, selectionRevision: "37", reason: null };
      if (command === "metawork.tasks.refreshSkillCatalog")
        return {
          accepted: false,
          taskId: "11",
          reason: "catalog_unavailable",
        };
      if (command === "metawork.permissions.setDefaultProfile")
        return { changed: true, defaultProfile: "full_access" };
      assert.fail(`unexpected command ${command}`);
    }),
  });

  await client.configureMetaskSelection({
    sourceId: "metask:key-1",
    modelId: "model-3",
    expectedMetaskSelectionRevision: "17",
    expectedCatalogGeneration: "19",
  });
  assert.deepEqual(
    await client.createTask(
      {
        kind: "manual",
        workspaceId: "7",
        expectedWorkspaceEpoch: "29",
      },
      "23",
      null,
      null,
      "approval_required",
    ),
    {
      accepted: true,
      taskId: "11",
      bindingEpoch: "13",
      reason: null,
    },
  );
  assert.deepEqual(
    await client.run("11", "13", {
      kind: "skill",
      skillId: "builtin.review",
      catalogRevision: "catalog-revision",
      selectionRevision: "31",
      argumentValues: ["src/main.zig"],
    }),
    {
      accepted: true,
      taskId: "11",
      runId: "17",
      reason: null,
    },
  );
  assert.deepEqual(await client.compact("11", "13"), {
    accepted: true,
    taskId: "11",
    operationId: "19",
    reason: null,
  });
  assert.deepEqual(await client.restoreTask("11", "13"), {
    accepted: true,
    taskId: "11",
    attemptId: "23",
    reason: null,
  });
  await client.cancelCompact("11", "19");
  assert.deepEqual(await client.refreshWorkspaceSkillCatalog("7", "29"), {
    accepted: true,
    workspaceId: "7",
    reason: null,
  });
  assert.deepEqual(await client.refreshSkillCatalog(), {
    accepted: true,
    reason: null,
  });
  assert.deepEqual(
    await client.setSkillEnabled(
      {
        scope: "project",
        workspaceId: "7",
        expectedWorkspaceEpoch: "29",
      },
      "review",
      "disabled",
      "catalog-revision",
      "31",
    ),
    { applied: true, selectionRevision: "37", reason: null },
  );
  assert.deepEqual(await client.refreshTaskSkillCatalog("11", "13"), {
    accepted: false,
    taskId: "11",
    reason: "catalog_unavailable",
  });
  assert.deepEqual(await client.setDefaultPermissionProfile("full_access"), {
    changed: true,
    defaultProfile: "full_access",
  });
  assert.deepEqual(calls, [
    {
      command: "metawork.models.configureMetaskSelection",
      payload: {
        sourceId: "metask:key-1",
        modelId: "model-3",
        expectedMetaskSelectionRevision: "17",
        expectedCatalogGeneration: "19",
      },
    },
    {
      command: "metawork.tasks.create",
      payload: {
        workspace: {
          kind: "manual",
          workspaceId: "7",
          expectedWorkspaceEpoch: "29",
        },
        expectedExecutionGeneration: "23",
        expectedSkillCatalogRevision: null,
        expectedSkillSelectionRevision: null,
        permissionProfile: "approval_required",
      },
    },
    {
      command: "metawork.tasks.run",
      payload: {
        taskId: "11",
        expectedBindingEpoch: "13",
        input: {
          kind: "skill",
          skillId: "builtin.review",
          catalogRevision: "catalog-revision",
          selectionRevision: "31",
          argumentValues: ["src/main.zig"],
        },
      },
    },
    {
      command: "metawork.tasks.compact",
      payload: { taskId: "11", expectedBindingEpoch: "13" },
    },
    {
      command: "metawork.tasks.restore",
      payload: { taskId: "11", expectedBindingEpoch: "13" },
    },
    {
      command: "metawork.tasks.cancelCompact",
      payload: { taskId: "11", operationId: "19" },
    },
    {
      command: "metawork.workspaces.refreshSkillCatalog",
      payload: { workspaceId: "7", expectedWorkspaceEpoch: "29" },
    },
    {
      command: "metawork.skills.refreshCatalog",
      payload: {},
    },
    {
      command: "metawork.skills.setEnabled",
      payload: {
        scope: "project",
        workspaceId: "7",
        expectedWorkspaceEpoch: "29",
        skillPolicyKey: "review",
        state: "disabled",
        expectedCatalogRevision: "catalog-revision",
        expectedSelectionRevision: "31",
      },
    },
    {
      command: "metawork.tasks.refreshSkillCatalog",
      payload: { taskId: "11", expectedBindingEpoch: "13" },
    },
    {
      command: "metawork.permissions.setDefaultProfile",
      payload: { permissionProfile: "full_access" },
    },
  ]);
});
