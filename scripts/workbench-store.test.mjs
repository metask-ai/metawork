import assert from "node:assert/strict";
import test from "node:test";

import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";

function session(id, workspaceRoot, archived = false) {
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

function snapshot(revision, sessions) {
  return { schemaVersion: 4, revision, sessions };
}

test("the Workbench store selects the first Task and preserves a valid choice", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      session("2", "/repo/alpha"),
      session("3", "/repo/beta"),
    ]),
  });
  assert.equal(accepted.activeSessionId, "2");
  assert.equal(accepted.activeWorkspaceRoot, "/repo/alpha");

  const selected = workbenchReducer(accepted, {
    type: "session.selected",
    sessionId: "3",
  });
  assert.equal(selected.activeSessionId, "3");
  assert.equal(selected.activeWorkspaceRoot, "/repo/beta");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [
      session("3", "/repo/beta"),
      session("4", "/repo/alpha"),
    ]),
  });
  assert.equal(refreshed.activeSessionId, "3");
});

test("workspace selection chooses a visible local Task and never leaks another workspace", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      session("2", "/repo/alpha"),
      session("3", "/repo/beta", true),
      session("4", "/repo/beta"),
    ]),
  });
  const selected = workbenchReducer(accepted, {
    type: "workspace.selected",
    workspaceRoot: "/repo/beta",
  });
  assert.equal(selected.activeWorkspaceRoot, "/repo/beta");
  assert.equal(selected.activeSessionId, "4");

  const newWorkspace = workbenchReducer(selected, {
    type: "workspace.selected",
    workspaceRoot: "/repo/new",
  });
  assert.equal(newWorkspace.activeWorkspaceRoot, "/repo/new");
  assert.equal(newWorkspace.activeSessionId, null);
});

test("the Workbench store rejects unknown Tasks and falls back within the current workspace", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [
      session("2", "/repo/alpha"),
      session("3", "/repo/alpha"),
      session("4", "/repo/beta"),
    ]),
  });
  assert.equal(
    workbenchReducer(accepted, {
      type: "session.selected",
      sessionId: "99",
    }),
    accepted,
  );
  const removed = workbenchReducer(accepted, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [
      session("3", "/repo/alpha"),
      session("4", "/repo/beta"),
    ]),
  });
  assert.equal(removed.activeSessionId, "3");
});

test("a new Task stays a Renderer draft until first send creates an authoritative Session", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", [session("2", "/repo/alpha")]),
  });
  const draft = workbenchReducer(accepted, {
    type: "task.draft.opened",
    workspaceRoot: "/repo/alpha",
  });
  assert.equal(draft.activeSessionId, null);
  assert.equal(draft.activeWorkspaceRoot, "/repo/alpha");
  assert.equal(draft.draftWorkspaceRoot, "/repo/alpha");

  const refreshed = workbenchReducer(draft, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", [
      session("2", "/repo/alpha"),
      session("3", "/repo/beta"),
    ]),
  });
  assert.equal(refreshed.activeSessionId, null);
  assert.equal(refreshed.draftWorkspaceRoot, "/repo/alpha");

  const selected = workbenchReducer(refreshed, {
    type: "session.selected",
    sessionId: "2",
  });
  assert.equal(selected.activeSessionId, "2");
  assert.equal(selected.draftWorkspaceRoot, null);
});
