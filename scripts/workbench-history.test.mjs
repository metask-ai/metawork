import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  historyProgress,
  earlierHistoryGoal,
} from "../frontend/src/workbench/history.ts";
import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";
import { productStateFixture } from "./test-support/product-view-fixture.mjs";
const wire = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/product-view.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
function scenario(count) {
  const template = wire.taskPage.task;
  const runs = Array.from({ length: count }, (_, i) => ({
    ...structuredClone(template.runs[0]),
    id: String(i + 1),
    contentVersion: "1",
  }));
  const source = {
    ...wire.context,
    revision: "1",
    workspaces: wire.workspaces,
    tasks: [{ ...structuredClone(template), id: "1", runs }],
  };
  let state = { ...initialWorkbenchState, activeTaskId: "1" };
  const read = (cursor = null) => {
    const scope = {
      ...initialWorkbenchState.snapshot.scope,
      taskId: "1",
      beforeRunId: cursor,
    };
    state = workbenchReducer(state, {
      type: "snapshot.accepted",
      snapshot: productStateFixture(source, scope),
      receivedAt: 1,
    });
  };
  const ids = () => state.snapshot.tasks[0].runs.map((run) => run.id);
  const fill = (goal) => {
    for (let i = 0; i < 10; i++) {
      const progress = historyProgress(state.snapshot, "1", goal);
      if (!progress.beforeRunId) return;
      read(progress.beforeRunId);
    }
    assert.fail(
      "history recovery did not converge within the retained Run bound",
    );
  };
  read();
  return {
    source,
    read,
    fill,
    ids,
    get state() {
      return state;
    },
    set state(value) {
      state = value;
    },
  };
}
test("history restores every middle Run after epoch invalidation and exposes no disjoint transcript", () => {
  const s = scenario(12);
  const goal = { taskId: "1", oldestRunId: "1" };
  s.fill(goal);
  assert.deepEqual(
    s.ids(),
    Array.from({ length: 12 }, (_, i) => String(i + 1)),
  );
  s.source.historyEpoch = "2";
  s.read("5");
  assert.deepEqual(s.ids(), ["9", "10", "11", "12"]);
  s.fill(goal);
  assert.deepEqual(
    s.ids(),
    Array.from({ length: 12 }, (_, i) => String(i + 1)),
  );
  assert.equal(
    historyProgress(s.state.snapshot, "1", goal).nextBeforeRunId,
    null,
  );
});
test("admission moving the current page retains the boundary Run between history and latest", () => {
  const s = scenario(8);
  const goal = earlierHistoryGoal(s.state.snapshot, "1", "5");
  s.fill(goal);
  assert.equal(s.ids().length, 8);
  s.source.tasks[0].runs.push({
    ...structuredClone(s.source.tasks[0].runs.at(-1)),
    id: "9",
  });
  s.read();
  s.fill(goal);
  assert.deepEqual(s.ids(), ["1", "2", "3", "4", "5", "6", "7", "8", "9"]);
});
test("unmounted Task bodies recover to the saved reading goal using bounded pages", () => {
  const s = scenario(16);
  const goal = { taskId: "1", oldestRunId: "1" };
  s.fill(goal);
  const unloaded = {
    ...s.state.snapshot,
    taskPage: null,
    historyPage: null,
    tasks: [],
  };
  s.state = workbenchReducer(s.state, {
    type: "snapshot.accepted",
    snapshot: unloaded,
    receivedAt: 2,
  });
  assert.deepEqual(s.state.snapshot.tasks, []);
  s.read();
  s.fill(goal);
  assert.deepEqual(
    s.ids(),
    Array.from({ length: 16 }, (_, i) => String(i + 1)),
  );
});
test("changed historical content is re-fetched without presenting a gap or retaining its old body", () => {
  const s = scenario(12);
  const goal = { taskId: "1", oldestRunId: "1" };
  s.fill(goal);
  s.source.tasks[0].runs[5].contentVersion = "2";
  s.source.tasks[0].runs[5].output.response = "changed";
  s.read();
  assert.deepEqual(s.ids(), ["7", "8", "9", "10", "11", "12"]);
  s.fill(goal);
  assert.equal(s.state.snapshot.tasks[0].runs[5].output.response, "changed");
  assert.deepEqual(
    s.ids(),
    Array.from({ length: 12 }, (_, i) => String(i + 1)),
  );
});
