import assert from "node:assert/strict";
import test from "node:test";

import {
  BridgeClient,
  BridgeCommandTimeoutError,
} from "../frontend/src/bridge/client.ts";

function bridgeWith(invoke) {
  return {
    invoke,
    on() {
      return () => undefined;
    },
  };
}

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
