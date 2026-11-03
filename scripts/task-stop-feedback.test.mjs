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
  activeOperation: null,
  inputSubmissions: [],
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
  assert.equal(f.controller.pending("draft:1", null), true);
  f.controller.target(token, "t1");
  assert.equal(f.controller.pending("task:t1", task([])), true);
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

test("an exact scoped Run manifest settles stop uncertainty even when its body is outside the loaded history page", () => {
  for (const phase of [
    "stopping",
    "completed",
    "failed",
    "interrupted",
    "stopped",
    "cancelled",
  ]) {
    const f = setup();
    const token = f.controller.begin("task:t1", task([run("r1")]), []);
    f.controller.settle(token, "unknown");
    const other = { ...task([run("r1", phase)]), id: "t2" };
    f.controller.observe({
      tasks: [other],
      taskPage: { task: other, runManifest: [run("r1", phase)] },
    });
    assert.equal(f.entries().length, 1);
    const page = task([run("r2")]);
    f.controller.observe({
      tasks: [page],
      taskPage: { task: page, runManifest: [run("r2", phase)] },
    });
    assert.equal(f.entries().length, 1);
    f.controller.observe({
      tasks: [page],
      taskPage: { task: page, runManifest: [run("r1", phase), run("r2")] },
    });
    assert.deepEqual(f.entries(), [], phase);
  }
});

test("security cleaning preserves stop identity and awaiting admission for its exact target", () => {
  const f = setup();
  const source = task([run("r1")]);
  const token = f.controller.begin("task:t1", source, []);
  f.controller.settle(token, "awaiting", "old diagnostic");
  f.controller.clearDiagnostics();
  assert.equal(f.entries()[0], token);
  assert.equal(token.diagnostic, undefined);
  assert.equal(f.controller.pending("task:t1", source), true);
  assert.equal(f.controller.pending("task:t1", task([run("r2")], "r2")), false);
  f.controller.settle(token, "unknown");
  assert.equal(f.controller.pending("task:t1", source), false);
  f.controller.reset();
  f.controller.settle(token, "failed", "late diagnostic");
  assert.deepEqual(f.entries(), []);
});
