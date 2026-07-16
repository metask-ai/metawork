import assert from "node:assert/strict";
import test from "node:test";

import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";

function snapshot(revision, sessionIds) {
  return {
    schemaVersion: 1,
    revision,
    sessions: sessionIds.map((id) => ({ id })),
  };
}

test("the Workbench store selects the first Session and preserves a valid choice", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", ["2", "3"]),
  });
  assert.equal(accepted.activeSessionId, "2");

  const selected = workbenchReducer(accepted, {
    type: "session.selected",
    sessionId: "3",
  });
  assert.equal(selected.activeSessionId, "3");

  const refreshed = workbenchReducer(selected, {
    type: "snapshot.accepted",
    snapshot: snapshot("2", ["3", "4"]),
  });
  assert.equal(refreshed.activeSessionId, "3");
});

test("the Workbench store rejects unknown choices and falls back after removal", () => {
  const accepted = workbenchReducer(initialWorkbenchState, {
    type: "snapshot.accepted",
    snapshot: snapshot("1", ["2", "3"]),
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
    snapshot: snapshot("2", ["3"]),
  });
  assert.equal(removed.activeSessionId, "3");
});
