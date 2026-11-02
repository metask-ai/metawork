import assert from "node:assert/strict";
import test from "node:test";
import {
  attentionStatus,
  beginFeedback,
  createFeedbackState,
  dismissFeedback,
  feedbackTokenCurrent,
  observeFeedback,
  publishStatus,
  quietStatus,
  resetFeedback,
  selectCommandBarFeedback,
  settleFeedback,
  statusVisibleInCommandBar,
} from "../frontend/src/app/command-bar-status.ts";

const context = {
  route: "workbench",
  settingsOpen: false,
  taskId: "t1",
  workspaceId: "w1",
};
const account = attentionStatus("account.command_failed", { scope: "account" });
const connection = attentionStatus("connection.refresh_failed", {
  scope: "connection",
});

test("migrated local results stay outside global feedback and legacy scope replacement", () => {
  const status = {
    ...attentionStatus("workspace.selection_failed", {
      scope: "workspace",
      workspaceId: null,
    }),
    local: true,
  };
  let state = observeFeedback(
    createFeedbackState(),
    "workspace:selection:draft1",
    "result",
    status,
  );
  state = publishStatus(
    state,
    quietStatus("workspace.grant_confirmed", {
      scope: "workspace",
      workspaceId: "w1",
    }),
  );
  assert.equal(statusVisibleInCommandBar(status, context), false);
  assert.equal(selectCommandBarFeedback(state, context).length, 0);
  assert.equal(state.entries["workspace:selection:draft1"].id, status.id);
});

test("independent Task operation results coexist and one success cannot retire the other", () => {
  const audience = { scope: "task", taskId: "t1" };
  const first = beginFeedback(createFeedbackState(), "compact:t1", {
    ...quietStatus("feedback.pending", audience),
    local: true,
  });
  let state = settleFeedback(first.state, first.token, {
    ...attentionStatus("compact.start_failed", audience),
    local: true,
  });
  const second = beginFeedback(state, "task-model:t1", {
    ...quietStatus("feedback.pending", audience),
    local: true,
  });
  state = settleFeedback(second.state, second.token, null);
  assert.equal(state.entries["compact:t1"].id, "compact.start_failed");
  assert.equal(selectCommandBarFeedback(state, context).length, 0);
});

test("Skills excludes workspace feedback from candidates and announcements while connection stays first", () => {
  const workspace = attentionStatus("workspace.selection_failed", {
    scope: "workspace",
    workspaceId: null,
  });
  let state = publishStatus(createFeedbackState(), workspace);
  state = publishStatus(
    state,
    attentionStatus("workspace.selection_failed", {
      scope: "workspace",
      workspaceId: "w1",
    }),
  );
  state = observeFeedback(state, "connection", "condition", connection);
  state = publishStatus(
    state,
    attentionStatus("skills.catalog_refresh_failed", { scope: "skills" }),
  );
  state = observeFeedback(state, "account", "result", account);
  const skills = { ...context, route: "skills" };
  assert.deepEqual(
    selectCommandBarFeedback(state, skills).map((entry) => entry.key),
    ["connection", "legacy:skills", "account"],
  );
  assert.equal(statusVisibleInCommandBar(workspace, skills), false);
  assert.deepEqual(
    selectCommandBarFeedback(state, { ...skills, settingsOpen: true }).map(
      (entry) => entry.key,
    ),
    ["connection", "account"],
  );
  assert.deepEqual(
    selectCommandBarFeedback(state, context).map((entry) => entry.key),
    ["connection", "legacy:workspace:w1", "legacy:workspace:*", "account"],
  );
});

test("connection recovery retires only its condition, not an independent account result", () => {
  let state = observeFeedback(
    createFeedbackState(),
    "account",
    "result",
    account,
  );
  state = observeFeedback(state, "connection", "condition", connection);
  assert.deepEqual(
    selectCommandBarFeedback(state, context).map((e) => e.key),
    ["connection", "account"],
  );
  state = observeFeedback(state, "connection", "condition", null);
  assert.deepEqual(
    selectCommandBarFeedback(state, context).map((e) => e.key),
    ["account"],
  );
});

test("repeated snapshots preserve dismissal and do not announce again", () => {
  let state = observeFeedback(
    createFeedbackState(),
    "account",
    "result",
    account,
  );
  const announcement = state.announcement;
  state = dismissFeedback(state, "account", state.entries.account.cycle);
  const repeated = observeFeedback(state, "account", "result", { ...account });
  assert.equal(repeated, state);
  assert.equal(repeated.announcement, announcement);
  assert.equal(selectCommandBarFeedback(repeated, context).length, 0);
});

test("a new accepted display cycle shows the same error even when the clearing snapshot was coalesced", () => {
  let state = observeFeedback(
    createFeedbackState(),
    "account",
    "result",
    account,
  );
  state = dismissFeedback(state, "account", state.entries.account.cycle);
  const oldAnnouncement = state.announcement.sequence;
  const next = beginFeedback(
    state,
    "account",
    quietStatus("account.updated", { scope: "account" }),
  );
  state = settleFeedback(next.state, next.token, account);
  assert.equal(state.entries.account.dismissed, false);
  assert.ok(state.announcement.sequence > oldAnnouncement);
  assert.equal(selectCommandBarFeedback(state, context).length, 1);
  assert.equal(observeFeedback(state, "account", "result", account), state);
});

test("late results and old dismiss actions cannot replace a newer display cycle", () => {
  const first = beginFeedback(createFeedbackState(), "account", account);
  const second = beginFeedback(first.state, "account", account);
  assert.equal(feedbackTokenCurrent(second.state, first.token), false);
  assert.equal(
    settleFeedback(second.state, first.token, connection),
    second.state,
  );
  assert.equal(
    dismissFeedback(second.state, "account", first.token.cycle),
    second.state,
  );
  assert.equal(feedbackTokenCurrent(second.state, second.token), true);
});

test("security/generation reset invalidates requests even if cycle numbers repeat", () => {
  const old = beginFeedback(createFeedbackState(), "account", account);
  const next = beginFeedback(resetFeedback(old.state), "account", account);
  assert.equal(settleFeedback(next.state, old.token, connection), next.state);
  assert.equal(next.state.announcement, null);
  assert.equal(next.state.entries.account.dismissed, false);
});

test("restored results are readable without announcing a new error", () => {
  const state = observeFeedback(
    createFeedbackState(),
    "account",
    "result",
    account,
    false,
  );
  assert.equal(state.announcement, null);
  assert.equal(selectCommandBarFeedback(state, context).length, 1);
});

test("legacy success replaces only its scope and cannot clear migrated feedback", () => {
  let state = observeFeedback(
    createFeedbackState(),
    "account",
    "result",
    account,
  );
  state = publishStatus(
    state,
    attentionStatus("account.command_rejected", { scope: "account" }),
  );
  state = publishStatus(
    state,
    attentionStatus("workspace.selection_failed", {
      scope: "workspace",
      workspaceId: null,
    }),
  );
  state = publishStatus(
    state,
    quietStatus("account.updated", { scope: "account" }),
  );
  state = publishStatus(
    state,
    quietStatus("workspace.grant_confirmed", {
      scope: "workspace",
      workspaceId: "w1",
    }),
  );
  assert.deepEqual(
    selectCommandBarFeedback(state, context).map((e) => e.key),
    ["account"],
  );
});

test("context filtering preserves other tasks without leaking their feedback", () => {
  let state = publishStatus(
    createFeedbackState(),
    attentionStatus("run.stop_failed", { scope: "task", taskId: "t2" }),
  );
  state = observeFeedback(state, "account", "result", account);
  assert.deepEqual(
    selectCommandBarFeedback(state, context).map((e) => e.key),
    ["account"],
  );
  assert.equal(
    selectCommandBarFeedback(state, { ...context, taskId: "t2" }).length,
    2,
  );
});
