import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { readProbeProductState } from "./probe-product-state.mjs";
import { productViewFixture } from "./test-support/product-view-fixture.mjs";
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
function host(state) {
  let encoded;
  let id = 0;
  const scopes = [];
  return {
    scopes,
    async invoke(command, payload) {
      if (command === "metawork.workbench.snapshot") {
        const { known, ...scope } = payload;
        assert.equal(known.securityEpoch, "0");
        assert.equal(
          Object.values(known.versions).every((value) => value === "0"),
          true,
        );
        scopes.push(scope);
        encoded = Buffer.from(JSON.stringify(productViewFixture(state, scope)));
        return {
          snapshotId: String(++id),
          bytes: encoded.length,
          chunkBytes: 256,
        };
      }
      assert.equal(command, "metawork.workbench.snapshot.chunk");
      const offset = Number(payload.offset),
        data = encoded.subarray(offset, offset + 256);
      return {
        snapshotId: String(id),
        offset,
        bytes: data.length,
        data: data.toString("base64"),
      };
    },
  };
}
test("desktop verification uses bounded scopes and current strict decoding", async () => {
  const state = structuredClone(fixture);
  const second = structuredClone(state.tasks[0]);
  second.id = "4";
  second.title = "second task";
  second.recentOrder = "2";
  state.tasks.push(second);
  const bridge = host(state);
  const result = await readProbeProductState(bridge.invoke);
  assert.deepEqual(
    result.tasks.map((task) => task.id),
    state.tasks.map((task) => task.id),
  );
  assert.equal(result.tasks[0].runs[0].id, fixture.tasks[0].runs[0].id);
  assert.equal(
    bridge.scopes.every((scope) => scope.runLimit <= 4),
    true,
  );
  assert.deepEqual(
    bridge.scopes
      .filter((scope) => scope.management !== "none")
      .map((scope) => scope.management),
    ["skills", "mcp", "schedules"],
  );
  const selectedBridge = host(state);
  const selected = await readProbeProductState(selectedBridge.invoke, {
    taskId: second.id,
  });
  assert.deepEqual(
    selected.tasks.map((task) => task.id),
    [second.id],
  );
  assert.deepEqual(selected.taskIndex, result.taskIndex);
  assert.ok(
    selectedBridge.scopes.every(
      (scope) => scope.taskId === null || scope.taskId === second.id,
    ),
  );
  const rootBridge = host(state);
  const rootOnly = await readProbeProductState(rootBridge.invoke, {
    taskId: null,
  });
  assert.deepEqual(rootOnly.tasks, []);
  assert.deepEqual(rootOnly.taskIndex, result.taskIndex);
  assert.ok(rootBridge.scopes.every((scope) => scope.taskId === null));
});
test("desktop verification rejects credentials and unavailable transport instead of reading an old shape", async () => {
  const state = structuredClone(fixture);
  state.tasks[0].title = "probe-credential";
  const bridge = host(state);
  await assert.rejects(
    readProbeProductState(bridge.invoke, { forbidden: ["probe-credential"] }),
    /credential reached/,
  );
  await assert.rejects(
    readProbeProductState(bridge.invoke, {
      forbidden: ["probe-credential"],
      taskId: state.tasks[0].id,
      includeManagement: false,
    }),
    /credential reached/,
  );
  await assert.rejects(
    readProbeProductState(async () => null),
    (error) => error.retryableSnapshotRead === true,
  );
});

test("live Task polling collects the selected Task without unrelated management pages", async () => {
  const state = structuredClone(fixture);
  const second = structuredClone(state.tasks[0]);
  second.id = "4";
  second.recentOrder = "2";
  state.tasks.push(second);
  const bridge = host(state);
  const result = await readProbeProductState(bridge.invoke, {
    taskId: second.id,
    includeManagement: false,
  });
  assert.deepEqual(
    result.tasks.map((task) => task.id),
    [second.id],
  );
  assert.deepEqual(
    result.taskIndex.map((task) => task.id),
    state.tasks.map((task) => task.id),
  );
  assert.ok(bridge.scopes.every((scope) => scope.management === "none"));
  assert.ok(
    bridge.scopes.every(
      (scope) => scope.taskId === null || scope.taskId === second.id,
    ),
  );
});

test("Run observations retain the Task view revision when later scopes advance", async () => {
  const state = structuredClone(fixture);
  const bridge = host(state);
  const observed = [];
  const originalRevision = state.revision;
  const originalTitle = state.tasks[0].title;
  const result = await readProbeProductState(
    async (command, payload) => {
      if (
        command === "metawork.workbench.snapshot" &&
        payload.management === "skills"
      ) {
        state.revision = String(BigInt(originalRevision) + 1n);
        state.tasks[0].title = "changed after the Task view";
      }
      return bridge.invoke(command, payload);
    },
    {
      observeTaskView({ revision, task }) {
        observed.push({ revision, title: task.title });
      },
    },
  );
  assert.equal(result.revision, state.revision);
  assert.notEqual(result.revision, originalRevision);
  assert.deepEqual(observed, [
    { revision: originalRevision, title: originalTitle },
  ]);
  assert.equal(result.tasks[0].title, originalTitle);
});
