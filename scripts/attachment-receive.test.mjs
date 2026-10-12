import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  decodeAttachmentReceiveResult,
  decodeAttachmentReceiveAcceptance,
} from "../frontend/src/bridge/decode-contracts.ts";
import {
  AttachmentAddOperation,
  AttachmentCleanupError,
} from "../frontend/src/bridge/attachment-receive.ts";
import {
  BridgeClient,
  BridgeCommandTimeoutError,
} from "../frontend/src/bridge/client.ts";
const oldWire = JSON.parse(
  readFileSync(
    new URL("../src/bridge/attachment_receive.fixture", import.meta.url),
    "utf8",
  ),
);
const wire = JSON.parse(
  readFileSync(
    new URL("../src/bridge/attachment_add.fixture", import.meta.url),
    "utf8",
  ),
);
const accepted = { status: "accepted" };
const cleaned = { status: "cleaned", released: true };
const ready = wire.ready;
const deferred = () => {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
};
const byteSource = () => ({
  kind: "file_bytes",
  files: [new File(["abc"], "a.txt")],
});
const port = (overrides = {}) => ({
  begin: async () => accepted,
  append: async () => accepted,
  finish: async () => ready,
  cancel: async () => cleaned,
  recover: async () => {},
  ...overrides,
});
test("legacy revision 1 receive fixture remains an exact wire contract", () => {
  assert.deepEqual(decodeAttachmentReceiveResult(oldWire.ready), oldWire.ready);
  assert.throws(() => decodeAttachmentReceiveAcceptance(oldWire.ready));
  assert.throws(() => decodeAttachmentReceiveResult({ status: "cancelled" }));
});
test("client emits the unified Native-tested fixture for a fresh scoped batch", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: {
      on: () => () => {},
      invoke: async (command, payload) => {
        if (command === "metawork.events.connect") return oldWire.connect;
        calls.push([command, payload]);
        if (command.endsWith("cancelAdd")) return cleaned;
        return command.endsWith("finishAdd") ? ready : accepted;
      },
    },
  });
  await client.connect();
  await client.createAttachmentAdd(async () => {}).cancel();
  await client.createAttachmentAdd(async () => {}).cancel();
  calls.length = 0;
  const op = client.createAttachmentAdd(async () => {});
  assert.deepEqual(await op.run(byteSource()), ready);
  assert.deepEqual(calls, [
    ["metawork.attachments.beginAdd", wire.begin],
    ["metawork.attachments.appendAdd", wire.append],
    ["metawork.attachments.finishAdd", wire.key],
  ]);
  assert.equal(
    op.handoff(() => true),
    true,
  );
});
test("DOM reads start after reservation and each write acknowledgement bounds the next chunk", async () => {
  const begin = deferred(),
    write = deferred(),
    entered = deferred(),
    chunks = [];
  let reads = 0;
  const file = new File(["abcdefg"], "a.txt");
  const slice = file.slice.bind(file);
  file.slice = (...args) => {
    reads++;
    return slice(...args);
  };
  const op = new AttachmentAddOperation(
    port({
      begin: () => begin.promise,
      append: async (index, offset, data) => {
        chunks.push([index, offset, atob(data)]);
        entered.resolve();
        if (chunks.length === 1) await write.promise;
        return accepted;
      },
    }),
    3,
  );
  const pending = op.run({ kind: "file_bytes", files: [file] });
  assert.equal(reads, 0);
  begin.resolve(accepted);
  await entered.promise;
  assert.equal(reads, 1);
  write.resolve();
  await pending;
  assert.deepEqual(chunks, [
    [0, "0", "abc"],
    [0, "3", "def"],
    [0, "6", "g"],
  ]);
  assert.equal(
    op.handoff(() => true),
    true,
  );
});
for (const source of [
  { kind: "picker" },
  { kind: "native_paths", paths: ["C:\tmp\a.txt"] },
  byteSource(),
]) {
  test(
    source.kind +
      " shares ready-only boolean handoff and cancellation ownership",
    async () => {
      let cancellations = 0;
      const op = new AttachmentAddOperation(
        port({
          begin: async () => (source.kind === "file_bytes" ? accepted : ready),
          cancel: async () => {
            cancellations++;
            return cleaned;
          },
        }),
        3,
      );
      assert.equal(
        op.handoff(() => assert.fail("before ready")),
        false,
      );
      assert.deepEqual(await op.run(source), ready);
      assert.equal(
        op.handoff(() => false),
        false,
      );
      await op.cancel();
      assert.equal(cancellations, 1);
      assert.equal(
        op.handoff(() => assert.fail("after cancel")),
        false,
      );
      const success = new AttachmentAddOperation(
        port({
          begin: async () => (source.kind === "file_bytes" ? accepted : ready),
          cancel: async () => assert.fail("draft owns batch"),
        }),
        3,
      );
      await success.run(source);
      assert.equal(
        success.handoff(() => true),
        true,
      );
      await success.cancel();
    },
  );
}
for (const boundary of ["begin", "append", "finish"]) {
  test(
    "cancel during " + boundary + " joins cleanup and ignores late responses",
    async () => {
      const gate = deferred(),
        entered = deferred(),
        cleanup = deferred(),
        views = [];
      let cancellations = 0;
      const io = port({
        cancel: () => {
          cancellations++;
          return cleanup.promise;
        },
      });
      io[boundary] = () => {
        entered.resolve();
        return gate.promise;
      };
      const op = new AttachmentAddOperation(io, 3);
      const pending = op.run(byteSource(), (v) => views.push(v));
      await entered.promise;
      const cancelled = op.cancel();
      assert.equal(views.at(-1), "cancelling");
      assert.equal(
        op.handoff(() => assert.fail()),
        false,
      );
      cleanup.resolve(cleaned);
      await cancelled;
      assert.deepEqual(await pending, { status: "cancelled" });
      gate.resolve(boundary === "finish" ? ready : accepted);
      await Promise.resolve();
      assert.equal(
        op.handoff(() => assert.fail()),
        false,
      );
      await op.cancel();
      assert.equal(cancellations, 1);
    },
  );
}
test("DOM source read errors retain their meaning and cleanup failure is explicit", async () => {
  const file = {
    name: "a.txt",
    size: 1,
    slice: () => ({
      arrayBuffer: async () => {
        throw new Error("source unreadable");
      },
    }),
  };
  const op = new AttachmentAddOperation(port(), 3);
  assert.deepEqual(await op.run({ kind: "file_bytes", files: [file] }), {
    status: "rejected",
    reason: "read_failed",
  });
  const failed = new AttachmentAddOperation(
    port({
      begin: async () => ({ status: "rejected", reason: "unsupported_type" }),
      cancel: async () => ({ status: "cleanup_failed" }),
    }),
    3,
  );
  assert.deepEqual(await failed.run(byteSource()), {
    status: "rejected",
    reason: "cleanup_failed",
  });
  assert.equal(failed.primaryFailure.reason, "unsupported_type");
});
test("begin and finish can outlive the short command budget without replay", async () => {
  const calls = [];
  const client = new BridgeClient({
    commandTimeoutMs: 5,
    bridge: {
      on: () => () => {},
      invoke: async (command, payload) => {
        if (command === "metawork.events.connect") return oldWire.connect;
        calls.push(command);
        if (command.endsWith("beginAdd") || command.endsWith("finishAdd"))
          await new Promise((r) => setTimeout(r, 20));
        return command.endsWith("finishAdd") ? ready : accepted;
      },
    },
  });
  await client.connect();
  const op = client.createAttachmentAdd(async () => assert.fail("no recovery"));
  await op.run(byteSource());
  assert.equal(
    op.handoff(() => true),
    true,
  );
  assert.equal(calls.length, 3);
});
test("a timed out chunk is cancelled once and its raw late write is never replayed", async () => {
  const late = deferred(),
    calls = [];
  const client = new BridgeClient({
    commandTimeoutMs: 5,
    bridge: {
      on: () => () => {},
      invoke: async (command, payload) => {
        if (command === "metawork.events.connect") return oldWire.connect;
        calls.push(command);
        if (command.endsWith("appendAdd")) return late.promise;
        if (command.endsWith("cancelAdd")) return cleaned;
        return accepted;
      },
    },
  });
  await client.connect();
  const op = client.createAttachmentAdd(async () =>
    assert.fail("cleanup was confirmed"),
  );
  await assert.rejects(op.run(byteSource()), BridgeCommandTimeoutError);
  late.resolve(accepted);
  assert.equal(
    op.handoff(() => true),
    false,
  );
  assert.deepEqual(calls, [
    "metawork.attachments.beginAdd",
    "metawork.attachments.appendAdd",
    "metawork.attachments.cancelAdd",
  ]);
});
test("cancel timeout recovers immediately without waiting for a late picker response", async () => {
  const begin = deferred(),
    entered = deferred();
  let recoveries = 0;
  const client = new BridgeClient({
    commandTimeoutMs: 5,
    bridge: {
      on: () => () => {},
      invoke: async (command) => {
        if (command === "metawork.events.connect") return oldWire.connect;
        if (command.endsWith("beginAdd")) {
          entered.resolve();
          return begin.promise;
        }
        return new Promise(() => {});
      },
    },
  });
  await client.connect();
  const op = client.createAttachmentAdd(async () => {
    recoveries++;
  });
  const pending = assert.rejects(
    op.run({ kind: "picker" }),
    AttachmentCleanupError,
  );
  await entered.promise;
  await assert.rejects(op.cancel(), AttachmentCleanupError);
  await pending;
  assert.equal(recoveries, 1);
  begin.resolve(ready);
  assert.equal(
    op.handoff(() => assert.fail("late draft commit")),
    false,
  );
});
test("byte mode never subscribes to the alternate native drop path", async () => {
  let subscriptions = 0;
  const client = new BridgeClient({
    bridge: {
      on: () => {
        subscriptions++;
        return () => {};
      },
      invoke: async () => oldWire.connect,
    },
  });
  await client.connect();
  client.onFileDrop(() => assert.fail());
  assert.equal(subscriptions, 0);
});

for (const source of [{ kind: "picker" }, byteSource()]) {
  test(`busy ${source.kind} admission preserves its rejection without connection recovery`, async () => {
    const calls = [];
    const client = new BridgeClient({
      bridge: {
        on: () => () => {},
        invoke: async (command, payload) => {
          if (command === "metawork.events.connect") return oldWire.connect;
          calls.push({ command, payload });
          if (command.endsWith("beginAdd"))
            return { status: "rejected", reason: "input_busy" };
          if (command.endsWith("cancelAdd"))
            return { status: "cleaned", released: false };
          assert.fail(`Unexpected command: ${command}`);
        },
      },
    });
    await client.connect();
    const op = client.createAttachmentAdd(async () =>
      assert.fail("An unrelated batch must not force connection recovery"),
    );
    assert.deepEqual(await op.run(source), {
      status: "rejected",
      reason: "input_busy",
    });
    assert.equal(calls.length, 2);
    assert.equal(calls[0].command, "metawork.attachments.beginAdd");
    assert.equal(calls[1].command, "metawork.attachments.cancelAdd");
    assert.deepEqual(calls[1].payload, {
      generation: calls[0].payload.generation,
      batchId: calls[0].payload.batchId,
    });
    assert.equal(op.primaryFailure.reason, "input_busy");
  });
}
