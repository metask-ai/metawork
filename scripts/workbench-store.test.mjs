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
import { WorkspaceNavigationIntents } from "../frontend/src/workbench/workspace-navigation-intents.ts";

function task(id, workspaceId, archived = false) {
  return {
    id,
    title: "",
    workspaceId,
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

function workspace(id, origin = "user") {
  return {
    id,
    origin,
    displayName: `workspace-${id}`,
    canonicalRoot: `/repo/${id}`,
    redacted: false,
    authorization: "available",
    recentOrder: origin === "managed" ? "0" : id,
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
    selectedWorkspaceId: ids[0] ?? null,
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

test("account mutations block only New task admission", () => {
  assert.equal(accountMutationBlocksTaskAdmission(true, true), true);
  assert.equal(accountMutationBlocksTaskAdmission(false, true), false);
  assert.equal(accountMutationBlocksTaskAdmission(true, false), false);
});

test("Workspace navigation retains only the latest explicit user intent", () => {
  const intents = new WorkspaceNavigationIntents();
  const first = intents.begin({
    workspaceId: "2",
    workspaceEpoch: "4",
    target: { kind: "draft", migratableDraftId: null },
  });
  const latest = intents.queue({
    workspaceId: "1",
    workspaceEpoch: "7",
    target: { kind: "navigation", taskId: "9" },
  });
  const newest = intents.queue({
    workspaceId: "3",
    workspaceEpoch: "2",
    target: { kind: "navigation", taskId: "11" },
  });

  assert.equal(intents.isCurrent(first), false);
  assert.equal(intents.isCurrent(latest), false);
  assert.equal(intents.isCurrent(newest), true);
  assert.deepEqual(intents.takeQueued(), newest);
  assert.equal(intents.takeQueued(), null);
});

test("an unscoped New task invalidates an in-flight Workspace destination", () => {
  const intents = new WorkspaceNavigationIntents();
  const navigation = intents.begin({
    workspaceId: "2",
    workspaceEpoch: "4",
    target: { kind: "navigation", taskId: "9" },
  });

  intents.invalidate();

  assert.equal(intents.isCurrent(navigation), false);
  assert.equal(intents.takeQueued(), null);
});

test("the Workbench store selects the first Task and preserves a valid choice", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1"), task("3", "2")]),
  });
  assert.equal(accepted.activeTaskId, "2");
  assert.equal(accepted.activeWorkspaceId, "1");

  const beta = workbenchReducer(accepted, {
    type: "workspace.selected",
    workspaceId: "2",
  });
  const selected = workbenchReducer(beta, {
    type: "task.selected",
    taskId: "3",
  });
  assert.equal(selected.activeTaskId, "3");
  assert.equal(selected.activeWorkspaceId, "2");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: {
      ...snapshot("2", [task("3", "2"), task("4", "1")]),
      selectedWorkspaceId: "2",
    },
  });
  assert.equal(refreshed.activeTaskId, "3");
});

test("workspace selection chooses a visible local Task and never leaks another workspace", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      task("2", "1"),
      task("3", "2", true),
      task("4", "2"),
    ]),
  });
  const selected = workbenchReducer(accepted, {
    type: "workspace.selected",
    workspaceId: "2",
  });
  assert.equal(selected.activeWorkspaceId, "2");
  assert.equal(selected.activeTaskId, "4");

  const withEmptyWorkspace = {
    ...selected,
    snapshot: snapshot("2", selected.snapshot.tasks, ["1", "2", "3"]),
  };
  const newWorkspace = workbenchReducer(withEmptyWorkspace, {
    type: "workspace.selected",
    workspaceId: "3",
  });
  assert.equal(newWorkspace.activeWorkspaceId, "3");
  assert.equal(newWorkspace.activeTaskId, null);
  assert.equal(newWorkspace.draftOpen, true);
  assert.equal(newWorkspace.draftWorkspaceId, "3");
});

test("a managed Task route survives refresh without becoming the selected user Workspace", () => {
  const managedSnapshot = {
    ...snapshot("1", [task("2", "1"), task("3", "9")], ["1"]),
    selectedWorkspaceId: "1",
    workspaces: [workspace("1"), workspace("9", "managed")],
  };
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: managedSnapshot,
  });
  const selected = workbenchReducer(accepted, {
    type: "task.selected",
    taskId: "3",
  });
  assert.equal(selected.activeTaskId, "3");
  assert.equal(selected.activeWorkspaceId, "9");
  assert.equal(selected.snapshot.selectedWorkspaceId, "1");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: { ...managedSnapshot, revision: "2" },
  });
  assert.equal(refreshed.activeTaskId, "3");
  assert.equal(refreshed.activeWorkspaceId, "9");
  assert.equal(refreshed.snapshot.selectedWorkspaceId, "1");
  assert.equal(
    workbenchReducer(refreshed, {
      type: "workspace.selected",
      workspaceId: "9",
    }),
    refreshed,
  );
});

test("the Workbench store rejects unknown Tasks and falls back within the current workspace", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1"), task("3", "1"), task("4", "2")]),
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
    snapshot: snapshot("2", [task("3", "1"), task("4", "2")]),
  });
  assert.equal(removed.activeTaskId, "3");
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
  assert.equal(draft.activeWorkspaceId, "1");
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
  assert.equal(draft.activeWorkspaceId, null);
  assert.equal(draft.draftOpen, true);
  assert.equal(draft.draftWorkspaceId, null);

  const refreshed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [task("2", "1")]),
  });
  assert.equal(refreshed.activeTaskId, null);
  assert.equal(refreshed.activeWorkspaceId, null);
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
  assert.equal(removed.activeWorkspaceId, null);
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
  assert.equal(removed.activeWorkspaceId, null);
  assert.equal(removed.draftWorkspaceId, "1");
  assert.equal(removed.draftOpen, true);
});
