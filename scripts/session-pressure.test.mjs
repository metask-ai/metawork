import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  decodeTaskCreateResult,
  decodeTaskRestoreResult,
} from "../frontend/src/bridge/decode-contracts.ts";
import { TaskSubmissionSession } from "../frontend/src/features/composer/submitTaskInstruction.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/session-pressure.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

test("Session rejection fixture strictly preserves the blocking Task", () => {
  assert.deepEqual(decodeTaskCreateResult(fixture.create), fixture.create);
  assert.deepEqual(
    decodeTaskRestoreResult(fixture.restore, "3"),
    fixture.restore,
  );
  for (const reason of ["session_releasing", "session_capacity"]) {
    const { blockingTaskId, ...create } = fixture.create;
    assert.equal(decodeTaskCreateResult({ ...create, reason }).reason, reason);
    const { blockingTaskId: _, ...restore } = fixture.restore;
    assert.equal(
      decodeTaskRestoreResult({ ...restore, reason }, "3").reason,
      reason,
    );
    assert.throws(() => decodeTaskCreateResult({ ...fixture.create, reason }));
    assert.throws(() =>
      decodeTaskRestoreResult({ ...fixture.restore, reason }, "3"),
    );
  }
  for (const blockingTaskId of [
    undefined,
    null,
    "0",
    "07",
    "18446744073709551616",
  ]) {
    assert.throws(() =>
      decodeTaskCreateResult({ ...fixture.create, blockingTaskId }),
    );
    assert.throws(() =>
      decodeTaskRestoreResult({ ...fixture.restore, blockingTaskId }, "3"),
    );
  }
});

test("A definite creation rejection permits one later explicit retry, without sending rejected input", async () => {
  let creates = 0;
  const sends = [];
  const session = new TaskSubmissionSession({
    taskId: null,
    current: () => true,
    onCreated() {},
    stop: async () => {},
    create: async () =>
      ++creates === 1
        ? fixture.create
        : {
            accepted: true,
            taskId: "8",
            bindingEpoch: "1",
            mcpAuthority: { kind: "unavailable", selection: null },
            reason: null,
          },
    send: async (operationId, taskId, input) => {
      sends.push({ operationId, taskId, input });
      return { outcome: "accepted", taskId, operationId, reason: null };
    },
  });
  const input = { kind: "text", text: "Keep my draft" };
  assert.deepEqual(await session.submit("first", input, () => {}), {
    kind: "create_rejected",
    reason: "session_close_failed",
    blockingTaskId: "7",
  });
  assert.equal(creates, 1);
  assert.deepEqual(sends, []);
  assert.deepEqual(await session.submit("retry", input, () => {}), {
    kind: "accepted",
    taskId: "8",
  });
  assert.equal(creates, 2);
  assert.deepEqual(sends, [{ operationId: "retry", taskId: "8", input }]);
});

test("An unknown creation is never replayed on a later submit", async () => {
  let creates = 0;
  const session = new TaskSubmissionSession({
    taskId: null,
    current: () => true,
    onCreated() {},
    stop: async () => {},
    create: async () => {
      creates++;
      throw new Error("response lost");
    },
    send: async () => {
      throw new Error("must not send");
    },
  });
  for (const operationId of ["first", "later"])
    assert.deepEqual(
      await session.submit(
        operationId,
        { kind: "text", text: "draft" },
        () => {},
      ),
      {
        kind: "unknown",
        taskId: null,
      },
    );
  assert.equal(creates, 1);
});

test("Messages already waiting on one rejected creation are never automatically retried", async () => {
  let rejectCreation;
  let creates = 0;
  const sent = [];
  const first = new Promise((resolve) => {
    rejectCreation = resolve;
  });
  const session = new TaskSubmissionSession({
    taskId: null,
    current: () => true,
    onCreated() {},
    stop: async () => {},
    create: () =>
      ++creates === 1
        ? first
        : Promise.resolve({
            accepted: true,
            taskId: "8",
            bindingEpoch: "1",
            mcpAuthority: { kind: "unavailable", selection: null },
            reason: null,
          }),
    send: async (operationId, taskId) => {
      sent.push(operationId);
      return { outcome: "accepted", taskId, operationId, reason: null };
    },
  });
  const a = session.submit("A", { kind: "text", text: "first" }, () => {});
  const b = session.submit("B", { kind: "text", text: "second" }, () => {});
  assert.equal(creates, 1);
  rejectCreation({
    accepted: false,
    taskId: null,
    bindingEpoch: null,
    mcpAuthority: null,
    reason: "session_releasing",
  });
  assert.deepEqual(
    (await Promise.all([a, b])).map((result) => result.kind),
    ["create_rejected", "create_rejected"],
  );
  assert.equal(creates, 1);
  assert.deepEqual(sent, []);
  await session.submit(
    "C",
    { kind: "text", text: "new explicit intent" },
    () => {},
  );
  assert.equal(creates, 2);
  assert.deepEqual(sent, ["C"]);
});
