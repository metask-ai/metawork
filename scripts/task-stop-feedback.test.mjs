import assert from "node:assert/strict";
import test from "node:test";
import { TaskStopFeedbackController } from "../frontend/src/app/task-stop-feedback.ts";
import { PendingScopes } from "../frontend/src/workbench/pendingScopes.ts";

const run = (id, phase = "running", submissionId) => ({
  id,
  phase,
  terminal: [
    "completed",
    "failed",
    "cancelled",
    "interrupted",
    "stopped",
  ].includes(phase)
    ? { outcome: phase }
    : null,
  submission: submissionId ? { operationId: submissionId } : null,
});
const task = (runs, currentRunId = runs.at(-1)?.id) => ({
  id: "t1",
  currentRunId,
  currentRunPhase: "running",
  runs,
  compacts: [],
});

test("retiring a connection clears its stop latch before a new operation", () => {
  const pending = new PendingScopes();
  assert.equal(pending.begin("t1"), true);
  pending.clear();
  assert.equal(pending.has("t1"), false);
  assert.equal(pending.begin("t1"), true);
});
function setup() {
  let entries = [];
  const controller = new TaskStopFeedbackController((next) => {
    entries = next;
  });
  return { controller, entries: () => entries };
}

test("stop timeout is settled only by the exact Run; later replies cannot revive it", () => {
  const f = setup();
  const token = f.controller.begin("task:t1", task([run("r1")]), []);
  f.controller.settle(token, "unknown");
  f.controller.observe({ tasks: [task([run("r2", "completed")])] });
  assert.equal(f.entries()[0].runId, "r1");
  assert.equal(f.entries()[0].phase, "unknown");
  f.controller.observe({ tasks: [task([run("r1", "completed"), run("r2")])] });
  assert.deepEqual(f.entries(), []);
  f.controller.settle(token, "failed");
  assert.deepEqual(f.entries(), []);
});

test("stopping and every terminal retire uncertainty without claiming stop success", () => {
  for (const phase of [
    "stopping",
    "completed",
    "failed",
    "stopped",
    "cancelled",
    "interrupted",
  ]) {
    const f = setup();
    const token = f.controller.begin("task:t1", task([run("r1")]), []);
    f.controller.settle(token, "unknown");
    f.controller.observe({ tasks: [task([run("r1", phase)])] });
    assert.deepEqual(f.entries(), [], phase);
  }
});

test("first submission handoff binds only a pre-stop submission, never a later Run", () => {
  const f = setup();
  const token = f.controller.begin("draft:1", null, ["before-stop"]);
  assert.equal(f.controller.requesting("draft:1", null), true);
  f.controller.target(token, "t1");
  assert.equal(f.controller.requesting("task:t1", "t1"), true);
  f.controller.settle(token, "unknown");
  f.controller.observe({
    tasks: [task([run("r2", "completed", "after-stop")])],
  });
  assert.equal(f.entries()[0].runId, null);
  f.controller.observe({
    tasks: [task([run("r1", "interrupted", "before-stop"), run("r2")])],
  });
  assert.deepEqual(f.entries(), []);
});

test("generation reset and newer operations invalidate stale callbacks", () => {
  const f = setup();
  const old = f.controller.begin("task:t1", task([run("r1")]), []);
  const next = f.controller.begin("task:t1", task([run("r2")]), []);
  f.controller.settle(old, "failed");
  assert.equal(f.entries()[0], next);
  f.controller.reset();
  f.controller.target(next, "t2");
  f.controller.settle(next, "unknown");
  assert.deepEqual(f.entries(), []);
});

test("missing Task or Run and repeated successful reads are not stop evidence", () => {
  const f = setup();
  const token = f.controller.begin("task:t1", task([run("r1")]), []);
  f.controller.settle(token, "awaiting");
  for (const tasks of [[], [task([])], [task([run("r1")])]]) {
    f.controller.observe({ tasks });
    assert.equal(f.entries()[0].phase, "awaiting");
  }
});
