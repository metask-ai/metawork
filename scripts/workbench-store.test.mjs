import assert from "node:assert/strict";
import test from "node:test";

import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";
import { PendingScopes } from "../frontend/src/workbench/pendingScopes.ts";
import { navigableTasks } from "../frontend/src/workbench/task-visibility.ts";

function task(id, workspaceId, archived = false) {
  return {
    id,
    title: "",
    workspaceId,
    lifecycle: "open",
    deletionStatus: "idle",
    continuationAvailable: true,
    archived,
    currentRunId: "0",
    currentRunPhase: null,
    lastRunOutcome: null,
    cause: null,
    runs: [],
    pendingUi: null,
  };
}

function workspace(id, kind = "manual") {
  return {
    id,
    kind,
    displayName: `workspace-${id}`,
    canonicalRoot: `/repo/${id}`,
    redacted: false,
    authorization: "available",
    recentOrder: kind === "automatic" ? "0" : id,
    signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
  };
}

function snapshot(revision, tasks, workspaceIds = null) {
  const ids = workspaceIds ?? [
    ...new Set(tasks.map((item) => item.workspaceId)),
  ];
  return {
    revision,
    capabilities: initialWorkbenchState.snapshot.capabilities,
    account: initialWorkbenchState.snapshot.account,
    newTaskAdmission: initialWorkbenchState.snapshot.newTaskAdmission,
    workspaces: ids.map((id) => workspace(id)),
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

test("a signed-out Host snapshot restores an active Run instead of hiding it", () => {
  const running = {
    ...task("2", "1"),
    currentRunId: "7",
    currentRunPhase: "running",
    activeOperation: { kind: "run", id: "7" },
  };
  const restored = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [running]),
  });
  const signedOutSnapshot = {
    ...snapshot("2", [running]),
    account: {
      ...initialWorkbenchState.snapshot.account,
      state: "signed_out",
    },
  };
  const signedOut = workbenchReducer(restored, {
    type: "snapshot.accepted",
    snapshot: signedOutSnapshot,
  });

  assert.equal(signedOut.activeTaskId, null);
  assert.equal(signedOut.snapshot.newTaskAdmission.available, false);
  assert.equal(signedOut.snapshot.tasks[0]?.currentRunPhase, "running");
  assert.deepEqual(signedOut.snapshot.tasks[0]?.activeOperation, {
    kind: "run",
    id: "7",
  });
});

test("snapshot hydration stays on New task until the user selects a Task", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1"), task("3", "2")]),
  });
  assert.equal(accepted.activeTaskId, null);
  assert.equal("activeWorkspaceId" in accepted, false);

  const selected = workbenchReducer(accepted, {
    type: "task.selected",
    taskId: "3",
  });
  assert.equal(selected.activeTaskId, "3");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [task("3", "2"), task("4", "1")]),
  });
  assert.equal(refreshed.activeTaskId, "3");
});

test("active navigation includes only Tasks with a projected Workspace", () => {
  const current = snapshot(
    "1",
    [task("available", "1"), task("orphaned", "2")],
    ["1"],
  );
  assert.deepEqual(
    navigableTasks(current).map((item) => item.id),
    ["available"],
  );
});

test("an automatic Task route survives refresh independently of the draft Workspace", () => {
  const automaticSnapshot = {
    ...snapshot("1", [task("2", "1"), task("3", "9")], ["1"]),
    workspaces: [workspace("1"), workspace("9", "automatic")],
  };
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: automaticSnapshot,
  });
  const selected = workbenchReducer(accepted, {
    type: "task.selected",
    taskId: "3",
  });
  assert.equal(selected.activeTaskId, "3");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: { ...automaticSnapshot, revision: "2" },
  });
  assert.equal(refreshed.activeTaskId, "3");
});

test("the Workbench store rejects unknown Tasks and never switches history implicitly", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1"), task("3", "1"), task("4", "2")]),
  });
  const selected = workbenchReducer(accepted, {
    type: "task.selected",
    taskId: "3",
  });
  assert.equal(
    workbenchReducer(selected, {
      type: "task.selected",
      taskId: "99",
    }),
    selected,
  );
  const removed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [task("4", "2"), task("3", "1")]),
  });
  assert.equal(removed.activeTaskId, "3");
  const disappeared = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: snapshot("3", [task("4", "2")]),
  });
  assert.equal(disappeared.activeTaskId, null);
});

test("a new Task stays a Renderer draft until first send creates an authoritative Task", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1")]),
  });
  const draft = workbenchReducer(accepted, {
    type: "task.draft.opened",
    workspaceId: "1",
  });
  assert.equal(draft.activeTaskId, null);
  assert.equal(draft.draftOpen, true);
  assert.equal(draft.draftWorkspaceId, "1");

  const refreshed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [task("2", "1"), task("3", "2")]),
  });
  assert.equal(refreshed.activeTaskId, null);
  assert.equal(refreshed.draftOpen, true);
  assert.equal(refreshed.draftWorkspaceId, "1");

  const selected = workbenchReducer(refreshed, {
    type: "task.selected",
    taskId: "2",
  });
  assert.equal(selected.activeTaskId, "2");
  assert.equal(selected.draftOpen, false);
  assert.equal(selected.draftWorkspaceId, null);
});

test("an unscoped New task survives snapshots without inventing a Workspace", () => {
  const draft = workbenchReducer(initialWorkbenchState, {
    type: "task.draft.opened",
    workspaceId: null,
  });
  assert.equal(draft.activeTaskId, null);
  assert.equal(draft.draftOpen, true);
  assert.equal(draft.draftWorkspaceId, null);

  const refreshed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1")]),
  });
  assert.equal(refreshed.activeTaskId, null);
  assert.equal(refreshed.draftOpen, true);
  assert.equal(refreshed.draftWorkspaceId, null);
});

test("a removed Workspace leaves orphan history unselected until reauthorization", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1")]),
  });
  const removed = workbenchReducer(accepted, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [task("2", "1")], []),
  });
  assert.equal(removed.activeTaskId, null);
  assert.equal(
    workbenchReducer(removed, { type: "task.selected", taskId: "2" }),
    removed,
  );
});

test("removing a Workspace keeps its New task draft identity", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [], ["1"]),
  });
  const draft = workbenchReducer(accepted, {
    type: "task.draft.opened",
    workspaceId: "1",
  });
  const removed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [], []),
  });
  assert.equal(removed.draftWorkspaceId, "1");
  assert.equal(removed.draftOpen, true);
});
