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

test("Skill source commands carry only fixed ID intent and exact revision or recovery token", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { applied: true, revision: "18446744073709551615", reason: null };
    }),
  });
  assert.equal(
    (await client.setSkillSourceEnabled("claude", true, "7")).revision,
    "18446744073709551615",
  );
  await client.recoverSkillSourceSettings("reread", "9");
  await client.recoverSkillSourceSettings("reset", "10");
  assert.deepEqual(calls, [
    {
      command: "metawork.skills.setSourceEnabled",
      payload: {
        sourceId: "claude",
        enabled: true,
        expectedRevision: "7",
      },
    },
    {
      command: "metawork.skills.recoverSourceSettings",
      payload: { action: "reread", expectedRecoveryToken: "9" },
    },
    {
      command: "metawork.skills.recoverSourceSettings",
      payload: { action: "reset", expectedRecoveryToken: "10" },
    },
  ]);
});

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
        attachmentInput: { mode: "native_paths", maxChunkBytes: "131072" },
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

test("Account summary refresh uses the exact empty revision-one command", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { accepted: true, errorCode: "none", attemptId: "19" };
    }),
  });
  assert.deepEqual(await client.refreshAccountSummary(), {
    accepted: true,
    errorCode: "none",
    attemptId: "19",
  });
  assert.deepEqual(calls, [
    { command: "metawork.account.refreshSummary", payload: {} },
  ]);
});

test("Account recharge opens through one fixed empty-payload command", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { accepted: true, errorCode: "none", attemptId: null };
    }),
  });
  assert.deepEqual(await client.openAccountRecharge(), {
    accepted: true,
    errorCode: "none",
    attemptId: null,
  });
  assert.deepEqual(calls, [
    { command: "metawork.account.openRecharge", payload: {} },
  ]);
});

test("External links use one typed Host command and decode its closed outcome set", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { outcome: "opened" };
    }),
  });

  assert.deepEqual(await client.openExternalLink("https://example.com/a?q=1"), {
    outcome: "opened",
  });
  assert.deepEqual(calls, [
    {
      command: "metawork.host.links.openExternal",
      payload: { url: "https://example.com/a?q=1" },
    },
  ]);
});

test("External link outcomes fail closed when the Host changes shape", async () => {
  const client = new BridgeClient({
    bridge: bridgeWith(async () => ({ outcome: "maybe" })),
  });
  await assert.rejects(client.openExternalLink("https://example.com"));
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

test("Task completion acknowledgement preserves exact Task and Run identity", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { taskId: "11", runId: "17", marked: true };
    }),
  });

  assert.deepEqual(await client.markTaskCompletionSeen("11", "17"), {
    taskId: "11",
    runId: "17",
    marked: true,
  });
  assert.deepEqual(calls, [
    {
      command: "metawork.tasks.markCompletionSeen",
      payload: { taskId: "11", runId: "17" },
    },
  ]);

  const mismatched = new BridgeClient({
    bridge: bridgeWith(async () => ({
      taskId: "11",
      runId: "18",
      marked: false,
    })),
  });
  await assert.rejects(mismatched.markTaskCompletionSeen("11", "17"));
});

test("attachment release carries only its opaque grant", async () => {
  const calls = [];
  const token = "a".repeat(48);
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { released: true };
    }),
  });
  assert.deepEqual(await client.releaseAttachment(token), { released: true });
  assert.deepEqual(calls, [
    { command: "metawork.attachments.release", payload: { token } },
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
        selectionRevision: "18",
        reason: null,
      };
    }),
  });

  assert.deepEqual(
    await client.selectTaskModel(
      "11",
      "17",
      { sourceId: "metask", modelId: "model-2" },
      "19",
      "23",
    ),
    { accepted: true, taskId: "11", selectionRevision: "18", reason: null },
  );
  assert.deepEqual(calls, [
    {
      command: "metawork.tasks.selectModel",
      payload: {
        taskId: "11",
        expectedSelectionRevision: "17",
        targetModelRef: {
          sourceId: "metask",
          modelId: "model-2",
        },
        expectedSourceGeneration: "19",
        expectedCatalogGeneration: "23",
      },
    },
  ]);
});

test("Custom Provider and model commands carry split source-qualified revisions", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { accepted: true, errorCode: "none", attemptId: null };
    }),
  });

  await client.createCustomProvider({
    displayName: "Provider",
    protocol: "openai_responses",
    normalizedBaseUrl: "https://api.example.com/v1/responses",
    apiKey: "create-secret",
  });
  await client.createBuiltinProvider({
    providerId: "deepseek",
    baseUrl: "https://api.deepseek.com",
    apiKey: "builtin-secret",
  });
  await client.updateBuiltinProviderBaseUrl({
    providerId: "source-2",
    expectedProviderRevision: "29",
    baseUrl: "https://gateway.example.com/deepseek/v1",
  });
  await client.updateCustomProvider({
    providerId: "source-1",
    expectedProviderRevision: "2",
    displayName: "Provider 2",
    protocol: "openai_responses",
    normalizedBaseUrl: "https://api.example.com/v1/responses",
  });
  await client.replaceCustomProviderCredential(
    "source-1",
    "3",
    "replacement-secret",
  );
  await client.testCustomModel("source-1", "3", "model-a", "5", "7");
  await client.addCustomModel({
    providerId: "source-1",
    expectedProviderRevision: "3",
    expectedCatalogGeneration: "7",
    model: { id: "model-b" },
  });
  await client.replaceCustomModel({
    selection: { sourceId: "source-1", modelId: "model-b" },
    expectedProviderRevision: "11",
    expectedCatalogGeneration: "13",
    replacement: { id: "model-c" },
  });
  await client.removeCustomModel({
    selection: { sourceId: "source-1", modelId: "model-c" },
    expectedProviderRevision: "17",
    expectedCatalogGeneration: "19",
  });
  await client.removeCustomProvider("source-1", "23");

  assert.deepEqual(calls, [
    {
      command: "metawork.models.customProviders.create",
      payload: {
        displayName: "Provider",
        protocol: "openai_responses",
        normalizedBaseUrl: "https://api.example.com/v1/responses",
        apiKey: "create-secret",
      },
    },
    {
      command: "metawork.models.builtinProviders.create",
      payload: {
        providerId: "deepseek",
        baseUrl: "https://api.deepseek.com",
        apiKey: "builtin-secret",
      },
    },
    {
      command: "metawork.models.builtinProviders.updateBaseUrl",
      payload: {
        providerId: "source-2",
        expectedProviderRevision: "29",
        baseUrl: "https://gateway.example.com/deepseek/v1",
      },
    },
    {
      command: "metawork.models.customProviders.update",
      payload: {
        providerId: "source-1",
        expectedProviderRevision: "2",
        displayName: "Provider 2",
        protocol: "openai_responses",
        normalizedBaseUrl: "https://api.example.com/v1/responses",
      },
    },
    {
      command: "metawork.models.customProviders.replaceCredential",
      payload: {
        providerId: "source-1",
        expectedProviderRevision: "3",
        apiKey: "replacement-secret",
      },
    },
    {
      command: "metawork.models.customModels.test",
      payload: {
        model: { sourceId: "source-1", modelId: "model-a" },
        expectedProviderRevision: "3",
        expectedSourceGeneration: "5",
        expectedCatalogGeneration: "7",
      },
    },
    {
      command: "metawork.models.customModels.add",
      payload: {
        providerId: "source-1",
        expectedProviderRevision: "3",
        expectedCatalogGeneration: "7",
        model: { id: "model-b" },
      },
    },
    {
      command: "metawork.models.customModels.replace",
      payload: {
        selection: { sourceId: "source-1", modelId: "model-b" },
        expectedProviderRevision: "11",
        expectedCatalogGeneration: "13",
        replacement: { id: "model-c" },
      },
    },
    {
      command: "metawork.models.customModels.remove",
      payload: {
        selection: { sourceId: "source-1", modelId: "model-c" },
        expectedProviderRevision: "17",
        expectedCatalogGeneration: "19",
      },
    },
    {
      command: "metawork.models.customProviders.remove",
      payload: { providerId: "source-1", expectedProviderRevision: "23" },
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

test("native file drops stay behind the Bridge client boundary", async () => {
  let listener = null;
  const client = new BridgeClient({
    bridge: {
      async invoke() {
        return {
          accepted: true,
          contractId: "metawork.renderer-bridge",
          contractRevision: 1,
          generation: "3",
          error: null,
          attachmentInput: { mode: "native_paths", maxChunkBytes: "131072" },
        };
      },
      on(name, consume) {
        assert.equal(name, "drop:files");
        listener = consume;
        return () => undefined;
      },
    },
  });
  const received = [];
  await client.connect();
  client.onFileDrop((paths) => received.push(paths));
  listener({ windowId: 1, paths: ["C:\\work\\notes.txt"] });
  assert.deepEqual(received, [["C:\\work\\notes.txt"]]);
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

test("Account refresh retry uses one explicit empty-payload command", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { accepted: true, errorCode: "none", attemptId: null };
    }),
  });

  assert.deepEqual(await client.retryAccountRefresh(), {
    accepted: true,
    errorCode: "none",
    attemptId: null,
  });
  assert.deepEqual(calls, [
    { command: "metawork.account.retryRefresh", payload: {} },
  ]);
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
  await client.captureMcpSecret(
    "7",
    "server-1",
    {
      kind: "oauth_client_secret",
    },
    "fixture-client-secret",
  );
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
        secret: "fixture-client-secret",
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
          mcpAuthority: { kind: "ready", selection: "none" },
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
      assert.fail(`unexpected command ${command}`);
    }),
  });

  await client.configureMetaskSelection({
    sourceId: "metask",
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
      "27",
      {
        targetModelRef: { sourceId: "metask", modelId: "model-4" },
        expectedSourceGeneration: "31",
        expectedCatalogGeneration: "37",
      },
      null,
      null,
      "manual",
    ),
    {
      accepted: true,
      taskId: "11",
      bindingEpoch: "13",
      mcpAuthority: { kind: "ready", selection: "none" },
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
  assert.deepEqual(calls, [
    {
      command: "metawork.models.configureMetaskSelection",
      payload: {
        sourceId: "metask",
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
        expectedSelectionRevision: "27",
        modelSelection: {
          targetModelRef: { sourceId: "metask", modelId: "model-4" },
          expectedSourceGeneration: "31",
          expectedCatalogGeneration: "37",
        },
        expectedSkillCatalogRevision: null,
        expectedSkillSelectionRevision: null,
        approvalMode: "manual",
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
  ]);
});

test("Models recovery and global default commands preserve their exact revision payloads", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { accepted: true, errorCode: "none", attemptId: null };
    }),
  });

  assert.deepEqual(await client.resetModelsStore("41"), {
    accepted: true,
    errorCode: "none",
    attemptId: null,
  });
  assert.deepEqual(
    await client.selectModelsDefault({
      sourceId: "metask",
      modelId: "model-1",
      expectedSelectionRevision: "43",
      expectedSourceGeneration: "47",
      expectedCatalogGeneration: "53",
    }),
    { accepted: true, errorCode: "none", attemptId: null },
  );
  assert.deepEqual(calls, [
    {
      command: "metawork.models.resetStore",
      payload: { expectedRevision: "41" },
    },
    {
      command: "metawork.models.selectDefault",
      payload: {
        sourceId: "metask",
        modelId: "model-1",
        expectedSelectionRevision: "43",
        expectedSourceGeneration: "47",
        expectedCatalogGeneration: "53",
      },
    },
  ]);
});

test("Run wire preserves expanded UTF-8 text with JSON escapes", async () => {
  const text = '界\n"'.repeat(52428) + "xxxx";
  assert.equal(new TextEncoder().encode(text).byteLength, 256 * 1024);
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      assert.equal(command, "metawork.tasks.run");
      assert.equal(JSON.parse(JSON.stringify(payload)).input.text, text);
      return { accepted: true, taskId: "1", runId: "2", reason: null };
    }),
  });
  await client.run("1", "1", { kind: "text", text });
});

test("sendInput addresses Task acceptance and validates its exact operation", async () => {
  const calls = [];
  const receipt = {
    operationId: "input-1",
    taskId: "1",
    outcome: "accepted",
    reason: null,
  };
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return receipt;
    }),
  });
  const input = { kind: "text", text: "follow up" };
  assert.deepEqual(await client.sendInput("input-1", "1", input), receipt);
  assert.deepEqual(calls, [
    {
      command: "metawork.tasks.sendInput",
      payload: { operationId: "input-1", taskId: "1", input },
    },
  ]);
  for (const change of [
    { operationId: "other" },
    { taskId: "2" },
    { outcome: "submitted" },
    { reason: "task_busy" },
  ]) {
    const original = { ...receipt };
    Object.assign(receipt, change);
    await assert.rejects(client.sendInput("input-1", "1", input));
    Object.assign(receipt, original);
  }
});

test("input timeout and late response never resend or retarget", async () => {
  let resolve,
    calls = 0;
  const client = new BridgeClient({
    commandTimeoutMs: 1,
    bridge: bridgeWith(() => {
      calls++;
      return new Promise((done) => {
        resolve = done;
      });
    }),
  });
  await assert.rejects(
    client.sendInput("lost", "1", { kind: "text", text: "next" }),
    BridgeCommandTimeoutError,
  );
  assert.equal(calls, 1);
  resolve({
    operationId: "lost",
    taskId: "1",
    outcome: "accepted",
    reason: null,
  });
  await new Promise((done) => setTimeout(done, 2));
  assert.equal(calls, 1);
});

test("image model settings send only nullable model intent and decimal CAS", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { accepted: true, errorCode: "none", attemptId: null };
    }),
  });
  await client.configureMetaskImageSelection({
    modelId: "image-model",
    expectedSelectionRevision: "0",
    expectedCatalogGeneration: "7",
  });
  await client.configureMetaskImageSelection({
    modelId: null,
    expectedSelectionRevision: "18446744073709551615",
    expectedCatalogGeneration: "7",
  });
  assert.deepEqual(calls, [
    {
      command: "metawork.models.configureMetaskImageSelection",
      payload: {
        modelId: "image-model",
        expectedSelectionRevision: "0",
        expectedCatalogGeneration: "7",
      },
    },
    {
      command: "metawork.models.configureMetaskImageSelection",
      payload: {
        modelId: null,
        expectedSelectionRevision: "18446744073709551615",
        expectedCatalogGeneration: "7",
      },
    },
  ]);
});
