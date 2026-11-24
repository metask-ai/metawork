import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { BridgeClient } from "../frontend/src/bridge/client.ts";
import {
  decodeFileActionResult,
  decodeFileActionCancel,
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

test("Output registration sends only its recorded change identity", async () => {
  const changeId = "change-3-1-2";
  let state = "registered";
  const client = new BridgeClient({
    bridge: bridge(async (command, payload) => {
      if (command === "metawork.events.connect") return connect();
      assert.equal(command, "metawork.outputs.register");
      assert.deepEqual(payload, {
        generation: "1",
        operationId: payload.operationId,
        taskId: "3",
        runId: "7",
        changeId,
      });
      return { generation: "1", operationId: payload.operationId, state };
    }),
  });
  await client.connect();
  const register = () =>
    client.registerOutput("3", "7", changeId, new AbortController().signal);
  assert.equal(await register(), "registered");
  state = "ready";
  await assert.rejects(register);
});

test("Output action shared Host fixture is exact and malformed or authoritative extras fail", () => {
  assert.deepEqual(decodeFileActionResult(fixture.result), fixture.result);
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
      decodeFileActionResult({ ...fixture.result, ...change }),
    );
  assert.deepEqual(
    decodeFileActionCancel({
      generation: "1",
      operationId: "1",
      cancelled: true,
    }),
    { generation: "1", operationId: "1", cancelled: true },
  );
  assert.throws(() =>
    decodeFileActionCancel({
      generation: "1",
      operationId: "1",
      cancelled: "true",
    }),
  );
});
test("File actions address every identity by the same command and carry no path of their own", async () => {
  const calls = [];
  const done = {
    open: "opened",
    reveal: "revealed",
    copy_path: "path_copied",
    check_current: "ready",
    save: "saved",
    check: "ready",
  };
  const client = new BridgeClient({
    bridge: bridge(async (command, payload) => {
      calls.push({ command, payload });
      if (command === "metawork.events.connect") return connect();
      return {
        generation: "1",
        operationId: payload.operationId,
        state: done[payload.action],
      };
    }),
  });
  await client.connect();
  const targets = [
    {
      kind: "reference",
      taskId: "3",
      runId: "7",
      fileReferenceId: "file-3-1-1-1",
    },
    fixture.request.target,
    {
      kind: "workspace",
      taskId: "3",
      workspaceId: "2",
      workspaceEpoch: "1",
      path: "docs/说明.md",
    },
  ];
  for (const target of targets)
    for (const action of Object.keys(done)) {
      assert.equal(
        await client.fileAction(target, action, new AbortController().signal),
        done[action],
      );
      const call = calls.at(-1);
      assert.equal(call.command, "metawork.files.action");
      assert.deepEqual(call.payload, {
        generation: "1",
        operationId: String(calls.length - 1),
        target,
        action,
      });
    }
});

test("A file action accepts only its own success and the failures it can have", async () => {
  const success = [
    "opened",
    "revealed",
    "path_copied",
    "ready",
    "saved",
    "registered",
  ];
  const saveOnly = ["save_failed", "target_changed", "cleanup_failed"];
  const shared = ["busy", "missing", "restricted", "changed", "failed"];
  const done = {
    open: "opened",
    reveal: "revealed",
    copy_path: "path_copied",
    check_current: "ready",
    save: "saved",
    check: "ready",
  };
  let state;
  const client = new BridgeClient({
    bridge: bridge(async (command, payload) =>
      command === "metawork.events.connect"
        ? connect()
        : command === "metawork.files.cancelAction"
          ? { ...payload, cancelled: false }
          : { generation: "1", operationId: payload.operationId, state },
    ),
  });
  await client.connect();
  for (const action of Object.keys(done))
    for (state of [...success, ...saveOnly, ...shared]) {
      const allowed =
        state === done[action] ||
        shared.includes(state) ||
        (action === "save" && saveOnly.includes(state));
      const run = client.fileAction(
        fixture.request.target,
        action,
        new AbortController().signal,
      );
      if (allowed) assert.equal(await run, state);
      else await assert.rejects(run, undefined, `${action} answered ${state}`);
    }
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
    await client.fileAction(
      fixture.request.target,
      "check",
      new AbortController().signal,
    ),
    "ready",
  );
  assert.deepEqual(calls[1], {
    command: "metawork.files.action",
    payload: fixture.request,
  });
  assert.equal(
    await client.fileAction(
      fixture.request.target,
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
      broken.fileAction(
        fixture.request.target,
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
      if (command === "metawork.files.cancelAction")
        return { ...payload, cancelled: true };
      return new Promise((r) => {
        resolve = r;
      });
    }),
  });
  await client.connect();
  const abort = new AbortController();
  const result = client.fileAction(
    fixture.request.target,
    "reveal",
    abort.signal,
  );
  abort.abort();
  abort.abort();
  resolve({ ...fixture.result, state: "revealed" });
  await assert.rejects(result, { name: "AbortError" });
  assert.deepEqual(
    calls.filter((x) => x.command === "metawork.files.cancelAction"),
    [
      {
        command: "metawork.files.cancelAction",
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
      if (command === "metawork.files.cancelAction") {
        cancels.push(payload);
        return { ...payload, cancelled: true };
      }
      return new Promise((r) => {
        resolve = r;
      });
    }),
  });
  await client.connect();
  const pending = client.fileAction(
    fixture.request.target,
    "check",
    new AbortController().signal,
  );
  generation = "2";
  await client.connect();
  resolve(fixture.result);
  await assert.rejects(pending, { name: "AbortError" });
  assert.deepEqual(cancels, []);
});

test("Save results remain truthful after a cancellation request is too late", async () => {
  for (const state of [
    "saved",
    "save_failed",
    "target_changed",
    "cleanup_failed",
    "cancelled",
  ]) {
    let finish;
    const calls = [];
    const client = new BridgeClient({
      bridge: bridge(async (command, payload) => {
        calls.push({ command, payload });
        if (command === "metawork.events.connect") return connect();
        if (command === "metawork.files.cancelAction")
          return { ...payload, cancelled: state === "cancelled" };
        return new Promise((resolve) => {
          finish = resolve;
        });
      }),
    });
    await client.connect();
    const abort = new AbortController();
    const pending = client.fileAction(
      fixture.request.target,
      "save",
      abort.signal,
    );
    abort.abort();
    finish({ ...fixture.result, state });
    assert.equal(await pending, state);
    assert.equal(calls[1].payload.action, "save");
    assert.equal(Object.hasOwn(calls[1].payload, "path"), false);
  }
});
test("Save shared fixture is strict and cannot masquerade as a read or reveal response", async () => {
  const wire = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/output-save.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(decodeFileActionResult(wire.result), wire.result);
  assert.deepEqual(
    decodeFileActionCancel(wire.cancelTooLate),
    wire.cancelTooLate,
  );
  const client = new BridgeClient({
    bridge: bridge(async (command) =>
      command === "metawork.events.connect"
        ? connect()
        : { ...fixture.result, state: "saved" },
    ),
  });
  await client.connect();
  await assert.rejects(
    client.fileAction(
      fixture.request.target,
      "check",
      new AbortController().signal,
    ),
  );
});
