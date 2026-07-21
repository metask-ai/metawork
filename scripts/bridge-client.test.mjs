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
        contractRevision: 2,
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
