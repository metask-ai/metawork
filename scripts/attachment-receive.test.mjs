import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  decodeRendererBridgeConnect,
  decodeAttachmentReceiveResult,
  decodeAttachmentReceiveAcceptance,
} from "../frontend/src/bridge/decode-contracts.ts";
import {
  AttachmentReceive,
  AttachmentCleanupError,
} from "../frontend/src/bridge/attachment-receive.ts";
import { BridgeClient } from "../frontend/src/bridge/client.ts";

const ready = {
  status: "ready",
  attachments: [
    {
      token: "a".repeat(48),
      kind: "file",
      displayName: "a.txt",
      sizeBytes: "7",
    },
  ],
};
const accepted = { status: "accepted" };
const wire = JSON.parse(
  readFileSync(
    new URL("../src/bridge/attachment_receive.fixture", import.meta.url),
    "utf8",
  ),
);

test("Native-emitted receive fixture decodes strictly and client emits its exact payloads", async () => {
  assert.equal(
    decodeRendererBridgeConnect(wire.connect).attachmentInput.mode,
    "file_bytes",
  );
  assert.deepEqual(decodeAttachmentReceiveResult(wire.ready), wire.ready);
  assert.throws(() =>
    decodeRendererBridgeConnect({
      ...wire.connect,
      attachmentInput: { mode: "fallback", maxChunkBytes: "131072" },
    }),
  );
  assert.throws(() =>
    decodeRendererBridgeConnect({
      ...wire.connect,
      attachmentInput: { mode: "file_bytes", maxChunkBytes: "1048576" },
    }),
  );
  assert.throws(() => decodeAttachmentReceiveAcceptance(wire.ready));
  assert.throws(() => decodeAttachmentReceiveResult({ status: "cancelled" }));
  const calls = [];
  const client = new BridgeClient({
    bridge: {
      on: () => () => {},
      invoke: async (command, payload) => {
        if (command === "metawork.events.connect") return wire.connect;
        if (command.endsWith("cancelReceive")) return { released: false };
        calls.push([command, payload]);
        return command.endsWith("finishReceive") ? wire.ready : accepted;
      },
    },
  });
  await client.connect();
  await client.createAttachmentReceive().cancel();
  const operation = client.createAttachmentReceive();
  await operation.run([new File(["abc"], "a.txt")]);
  assert.deepEqual(calls, [
    ["metawork.attachments.beginReceive", wire.begin],
    ["metawork.attachments.appendReceive", wire.append],
    ["metawork.attachments.finishReceive", wire.key],
  ]);
  operation.handoff();
});
const deferred = () => {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
};

test("receive reads and transfers bounded ordered chunks, then hands ownership to the draft", async () => {
  const chunks = [];
  let cancellations = 0;
  const operation = new AttachmentReceive(
    {
      begin: async (files) => {
        assert.deepEqual(files, [
          { name: "a.txt", sizeBytes: "7" },
          { name: "b", sizeBytes: "1" },
        ]);
        return accepted;
      },
      append: async (index, offset, data) => {
        chunks.push([index, offset, atob(data)]);
        return accepted;
      },
      finish: async () => ready,
      cancel: async () => {
        cancellations++;
      },
    },
    3,
  );
  assert.equal(
    await operation.run([new File(["abcdefg"], "a.txt"), new File(["h"], "b")]),
    ready,
  );
  assert.deepEqual(chunks, [
    [0, "0", "abc"],
    [0, "3", "def"],
    [0, "6", "g"],
    [1, "0", "h"],
  ]);
  assert.equal(operation.handoff(), true);
  await operation.cancel();
  assert.equal(cancellations, 0);
});

for (const boundary of ["begin", "append", "finish"]) {
  test(`cancel during ${boundary} ignores its late response and cancels exactly one batch`, async () => {
    const gate = deferred();
    const entered = deferred();
    const calls = [];
    const port = {
      begin: async () => accepted,
      append: async () => accepted,
      finish: async () => ready,
      cancel: async () => {
        calls.push("cancel");
      },
    };
    port[boundary] = () => {
      calls.push(boundary);
      entered.resolve();
      return gate.promise;
    };
    const operation = new AttachmentReceive(port, 3);
    const pending = operation.run([new File(["abc"], "a.txt")]);
    await entered.promise;
    await operation.cancel();
    assert.deepEqual(await pending, { status: "cancelled" });
    gate.resolve(boundary === "finish" ? ready : accepted);
    await operation.cancel();
    assert.equal(operation.handoff(), false);
    assert.deepEqual(calls, [boundary, "cancel"]);
  });
}

test("cancel after finish but before draft handoff still revokes the batch", async () => {
  let cancelled = 0;
  const operation = new AttachmentReceive(
    {
      begin: async () => accepted,
      append: async () => accepted,
      finish: async () => ready,
      cancel: async () => {
        cancelled++;
      },
    },
    3,
  );
  await operation.run([new File(["abc"], "a.txt")]);
  await operation.cancel();
  assert.equal(cancelled, 1);
  assert.equal(operation.handoff(), false);
});

test("unconfirmed cleanup is surfaced for connection replacement", async () => {
  const operation = new AttachmentReceive(
    {
      begin: async () => {
        throw new Error("timeout");
      },
      append: async () => accepted,
      finish: async () => ready,
      cancel: async () => {
        throw new Error("timeout");
      },
    },
    3,
  );
  await assert.rejects(
    operation.run([new File(["abc"], "a.txt")]),
    AttachmentCleanupError,
  );
});

test("byte mode has no native-drop consumer and timeouts cancel the known generation/batch without replay", async () => {
  const calls = [];
  let subscriptions = 0;
  const client = new BridgeClient({
    commandTimeoutMs: 10,
    bridge: {
      on: () => {
        subscriptions++;
        return () => {};
      },
      invoke: async (command, payload) => {
        calls.push([command, payload]);
        if (command === "metawork.events.connect")
          return {
            accepted: true,
            contractId: "metawork.renderer-bridge",
            contractRevision: 1,
            generation: "4",
            error: null,
            attachmentInput: { mode: "file_bytes", maxChunkBytes: "131072" },
          };
        if (command === "metawork.attachments.beginReceive")
          return new Promise(() => {});
        if (command === "metawork.attachments.cancelReceive")
          return { released: true };
        throw new Error(command);
      },
    },
  });
  await client.connect();
  client.onFileDrop(() => assert.fail("duplicate input"));
  assert.equal(subscriptions, 0);
  await assert.rejects(
    client.createAttachmentReceive().run([new File(["x"], "a.txt")]),
    /timed out/,
  );
  assert.deepEqual(calls.slice(1), [
    [
      "metawork.attachments.beginReceive",
      {
        generation: "4",
        batchId: "1",
        files: [{ name: "a.txt", sizeBytes: "1" }],
      },
    ],
    ["metawork.attachments.cancelReceive", { generation: "4", batchId: "1" }],
  ]);
});
