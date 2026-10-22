import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { BridgeClient } from "../frontend/src/bridge/client.ts";
import {
  decodeOutputActionResult,
  decodeOutputActionCancel,
} from "../frontend/src/bridge/decode-contracts.ts";
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/output-action.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
const connect = (generation = "1") => ({
  accepted: true,
  contractId: "metawork.renderer-bridge",
  contractRevision: 1,
  generation,
  error: null,
  attachmentInput: { mode: "native_paths", maxChunkBytes: "131072" },
});
const bridge = (invoke) => ({ invoke, on: () => () => {} });
test("Output action shared Host fixture is exact and malformed or authoritative extras fail", () => {
  assert.deepEqual(decodeOutputActionResult(fixture.result), fixture.result);
  for (const change of [
    { generation: "0" },
    { generation: 1 },
    { operationId: "01" },
    { operationId: "18446744073709551616" },
    { state: "open" },
    { path: "C:/secret" },
    { sha256: "secret" },
  ])
    assert.throws(() =>
      decodeOutputActionResult({ ...fixture.result, ...change }),
    );
  assert.deepEqual(
    decodeOutputActionCancel({
      generation: "1",
      operationId: "1",
      cancelled: true,
    }),
    { generation: "1", operationId: "1", cancelled: true },
  );
  assert.throws(() =>
    decodeOutputActionCancel({
      generation: "1",
      operationId: "1",
      cancelled: "true",
    }),
  );
});
test("Output client submits scoped ID intent and checks result identity and action", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: bridge(async (command, payload) => {
      calls.push({ command, payload });
      if (command === "metawork.events.connect") return connect();
      return {
        ...fixture.result,
        operationId: payload.operationId,
        state: payload.action === "reveal" ? "revealed" : "ready",
      };
    }),
  });
  await client.connect();
  assert.equal(
    await client.outputAction(
      "3",
      "7",
      fixture.request.outputId,
      "check",
      new AbortController().signal,
    ),
    "ready",
  );
  assert.deepEqual(calls[1], {
    command: "metawork.outputs.action",
    payload: fixture.request,
  });
  assert.equal(
    await client.outputAction(
      "3",
      "7",
      fixture.request.outputId,
      "reveal",
      new AbortController().signal,
    ),
    "revealed",
  );
  assert.equal(calls[2].payload.operationId, "2");
  for (const changed of [
    { generation: "2" },
    { operationId: "2" },
    { state: "revealed" },
  ]) {
    const broken = new BridgeClient({
      bridge: bridge(async (command) =>
        command === "metawork.events.connect"
          ? connect()
          : { ...fixture.result, ...changed },
      ),
    });
    await broken.connect();
    await assert.rejects(
      broken.outputAction(
        "3",
        "7",
        fixture.request.outputId,
        "check",
        new AbortController().signal,
      ),
    );
  }
});
test("Output client cancellation is scoped and issued once, and ignores late success", async () => {
  const calls = [];
  let resolve;
  const client = new BridgeClient({
    bridge: bridge(async (command, payload) => {
      calls.push({ command, payload });
      if (command === "metawork.events.connect") return connect();
      if (command === "metawork.outputs.cancel")
        return { ...payload, cancelled: true };
      return new Promise((r) => {
        resolve = r;
      });
    }),
  });
  await client.connect();
  const abort = new AbortController();
  const result = client.outputAction(
    "3",
    "7",
    fixture.request.outputId,
    "reveal",
    abort.signal,
  );
  abort.abort();
  abort.abort();
  resolve({ ...fixture.result, state: "revealed" });
  await assert.rejects(result, { name: "AbortError" });
  assert.deepEqual(
    calls.filter((x) => x.command === "metawork.outputs.cancel"),
    [
      {
        command: "metawork.outputs.cancel",
        payload: { generation: "1", operationId: "1" },
      },
    ],
  );
});
test("Output client rejects an old connection response and never cancels in the replacement connection", async () => {
  let generation = "1";
  let resolve;
  const cancels = [];
  const client = new BridgeClient({
    bridge: bridge(async (command, payload) => {
      if (command === "metawork.events.connect") return connect(generation);
      if (command === "metawork.outputs.cancel") {
        cancels.push(payload);
        return { ...payload, cancelled: true };
      }
      return new Promise((r) => {
        resolve = r;
      });
    }),
  });
  await client.connect();
  const pending = client.outputAction(
    "3",
    "7",
    fixture.request.outputId,
    "check",
    new AbortController().signal,
  );
  generation = "2";
  await client.connect();
  resolve(fixture.result);
  await assert.rejects(pending, { name: "AbortError" });
  assert.deepEqual(cancels, []);
});
