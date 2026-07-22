import assert from "node:assert/strict";
import test from "node:test";

import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";
import {
  accountMutationBlocksTaskAdmission,
  PendingScopes,
} from "../frontend/src/workbench/pendingScopes.ts";

function task(id, workspaceRoot, archived = false) {
  return {
    id,
    title: "",
    workspaceRoot,
    lifecycle: "open",
    continuationAvailable: true,
    archived,
    closeFailed: false,
    currentRunId: "0",
    currentRunPhase: null,
    lastRunOutcome: null,
    cause: null,
    runs: [],
    pendingUi: null,
  };
}

function snapshot(revision, tasks) {
  return {
    revision,
    account: initialWorkbenchState.snapshot.account,
    tasks,
  };
}

test("pending scopes isolate unrelated mutations and reject duplicate admission", () => {
  const pending = new PendingScopes();
  assert.equal(pending.begin("task:2"), true);
  assert.equal(pending.begin("task:2"), false);
  assert.equal(pending.begin("task:3"), true);
  assert.equal(pending.has("task:2"), true);
  assert.equal(pending.has("task:3"), true);

  assert.equal(pending.move("task:2", "task:4"), true);
  assert.equal(pending.has("task:2"), false);
  assert.equal(pending.has("task:4"), true);
  assert.equal(pending.move("task:4", "task:3"), false);
  assert.equal(pending.has("task:4"), true);

  assert.equal(pending.end("task:3"), true);
  assert.equal(pending.has("task:4"), true);
  assert.equal(pending.end("task:4"), true);
});

test("account mutations block only New task admission", () => {
  assert.equal(accountMutationBlocksTaskAdmission(true, true), true);
  assert.equal(accountMutationBlocksTaskAdmission(false, true), false);
  assert.equal(accountMutationBlocksTaskAdmission(true, false), false);
});

test("the Workbench store selects the first Task and preserves a valid choice", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      task("2", "/repo/alpha"),
      task("3", "/repo/beta"),
    ]),
  });
  assert.equal(accepted.activeTaskId, "2");
  assert.equal(accepted.activeWorkspaceRoot, "/repo/alpha");

  const selected = workbenchReducer(accepted, {
    type: "task.selected",
    taskId: "3",
  });
  assert.equal(selected.activeTaskId, "3");
  assert.equal(selected.activeWorkspaceRoot, "/repo/beta");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [
      task("3", "/repo/beta"),
      task("4", "/repo/alpha"),
    ]),
  });
  assert.equal(refreshed.activeTaskId, "3");
});

test("workspace selection chooses a visible local Task and never leaks another workspace", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      task("2", "/repo/alpha"),
      task("3", "/repo/beta", true),
      task("4", "/repo/beta"),
    ]),
  });
  const selected = workbenchReducer(accepted, {
    type: "workspace.selected",
    workspaceRoot: "/repo/beta",
  });
  assert.equal(selected.activeWorkspaceRoot, "/repo/beta");
  assert.equal(selected.activeTaskId, "4");

  const newWorkspace = workbenchReducer(selected, {
    type: "workspace.selected",
    workspaceRoot: "/repo/new",
  });
  assert.equal(newWorkspace.activeWorkspaceRoot, "/repo/new");
  assert.equal(newWorkspace.activeTaskId, null);
  assert.equal(newWorkspace.draftOpen, true);
  assert.equal(newWorkspace.draftWorkspaceRoot, "/repo/new");
});

test("the Workbench store rejects unknown Tasks and falls back within the current workspace", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      task("2", "/repo/alpha"),
      task("3", "/repo/alpha"),
      task("4", "/repo/beta"),
    ]),
  });
  assert.equal(
    workbenchReducer(accepted, {
      type: "task.selected",
      taskId: "99",
    }),
    accepted,
  );
  const removed = workbenchReducer(accepted, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [
      task("3", "/repo/alpha"),
      task("4", "/repo/beta"),
    ]),
  });
  assert.equal(removed.activeTaskId, "3");
});

test("a new Task stays a Renderer draft until first send creates an authoritative Task", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "/repo/alpha")]),
  });
  const draft = workbenchReducer(accepted, {
    type: "task.draft.opened",
    workspaceRoot: "/repo/alpha",
  });
  assert.equal(draft.activeTaskId, null);
  assert.equal(draft.activeWorkspaceRoot, "/repo/alpha");
  assert.equal(draft.draftOpen, true);
  assert.equal(draft.draftWorkspaceRoot, "/repo/alpha");

  const refreshed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [
      task("2", "/repo/alpha"),
      task("3", "/repo/beta"),
    ]),
  });
  assert.equal(refreshed.activeTaskId, null);
  assert.equal(refreshed.draftOpen, true);
  assert.equal(refreshed.draftWorkspaceRoot, "/repo/alpha");

  const selected = workbenchReducer(refreshed, {
    type: "task.selected",
    taskId: "2",
  });
  assert.equal(selected.activeTaskId, "2");
  assert.equal(selected.draftOpen, false);
  assert.equal(selected.draftWorkspaceRoot, null);
});

test("an unscoped New task survives snapshots without inventing a Workspace", () => {
  const draft = workbenchReducer(initialWorkbenchState, {
    type: "task.draft.opened",
    workspaceRoot: null,
  });
  assert.equal(draft.activeTaskId, null);
  assert.equal(draft.activeWorkspaceRoot, null);
  assert.equal(draft.draftOpen, true);
  assert.equal(draft.draftWorkspaceRoot, null);

  const refreshed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "/repo/alpha")]),
  });
  assert.equal(refreshed.activeTaskId, null);
  assert.equal(refreshed.activeWorkspaceRoot, null);
  assert.equal(refreshed.draftOpen, true);
  assert.equal(refreshed.draftWorkspaceRoot, null);
});
