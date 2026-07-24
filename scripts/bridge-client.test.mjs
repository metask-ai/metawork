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

test("the hidden-inset titlebar delegates drag to the connected Host window", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { started: true };
    }),
  });

  await client.beginWindowDrag(1);
  assert.deepEqual(calls, [
    { command: "metawork.window.beginDrag", payload: { clicks: 1 } },
  ]);
});

test("visible window controls delegate their exact action to the Host", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      return { completed: true };
    }),
  });

  await client.controlWindow("minimize");
  assert.deepEqual(calls, [
    { command: "metawork.window.control", payload: { action: "minimize" } },
  ]);
});

test("the fixed revision 1 contract carries Host-owned Workspace and generation identities", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridgeWith(async (command, payload) => {
      calls.push({ command, payload });
      if (command === "metawork.account.selectModel")
        return { accepted: true, errorCode: "none", attemptId: "5" };
      if (command === "metawork.workspaces.select")
        return {
          accepted: true,
          workspaceId: "7",
          workspaceEpoch: "29",
          reason: null,
        };
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
      assert.fail(`unexpected command ${command}`);
    }),
  });

  await client.selectModel("model-3", "19", "23");
  assert.deepEqual(await client.selectWorkspace("7", "29"), {
    accepted: true,
    workspaceId: "7",
    workspaceEpoch: "29",
    reason: null,
  });
  assert.deepEqual(await client.createTask("7", "29", "23"), {
    accepted: true,
    taskId: "11",
    bindingEpoch: "13",
    reason: null,
  });
  assert.deepEqual(await client.run("11", "13", "Inspect"), {
    accepted: true,
    taskId: "11",
    runId: "17",
    reason: null,
  });
  assert.deepEqual(calls, [
    {
      command: "metawork.account.selectModel",
      payload: {
        selectionId: "model-3",
        expectedCatalogGeneration: "19",
        expectedExecutionGeneration: "23",
      },
    },
    {
      command: "metawork.workspaces.select",
      payload: { workspaceId: "7", expectedWorkspaceEpoch: "29" },
    },
    {
      command: "metawork.tasks.create",
      payload: {
        workspaceId: "7",
        expectedWorkspaceEpoch: "29",
        expectedExecutionGeneration: "23",
      },
    },
    {
      command: "metawork.tasks.run",
      payload: { taskId: "11", expectedBindingEpoch: "13", prompt: "Inspect" },
    },
  ]);
});
