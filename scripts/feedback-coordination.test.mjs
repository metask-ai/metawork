import assert from "node:assert/strict";
import test from "node:test";
import {
  attentionStatus,
  beginFeedback,
  createFeedbackState,
  clearSecurityFeedback,
  dismissFeedback,
  feedbackTokenCurrent,
  observeFeedback,
  quietStatus,
  resetFeedback,
  selectCommandBarFeedback,
  settleFeedback,
  statusVisibleInCommandBar,
} from "../frontend/src/app/command-bar-status.ts";

const account = attentionStatus("account.command_failed", { scope: "account" });
const connection = attentionStatus("connection.refresh_failed", {
  scope: "connection",
});

test("local business feedback stays outside the global collection even after another source succeeds", () => {
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
  state = observeFeedback(state, "account", "result", account);
  state = observeFeedback(state, "connection", "condition", null);
  assert.equal(statusVisibleInCommandBar(status), false);
  assert.deepEqual(
    selectCommandBarFeedback(state).map((entry) => entry.key),
    ["account"],
  );
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
  assert.equal(selectCommandBarFeedback(state).length, 0);
});

test("global ranking keeps connection first and rejects local scopes without route-dependent fallbacks", () => {
  let state = observeFeedback(
    createFeedbackState(),
    "account",
    "result",
    account,
  );
  state = observeFeedback(
    state,
    "skills:refresh",
    "result",
    attentionStatus("skills.catalog_refresh_failed", { scope: "skills" }),
  );
  state = observeFeedback(
    state,
    "workspace:selection",
    "result",
    attentionStatus("workspace.selection_failed", {
      scope: "workspace",
      workspaceId: "w1",
    }),
  );
  state = observeFeedback(state, "connection", "condition", connection);
  assert.deepEqual(
    selectCommandBarFeedback(state).map((entry) => entry.key),
    ["connection", "account"],
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
    selectCommandBarFeedback(state).map((e) => e.key),
    ["connection", "account"],
  );
  state = observeFeedback(state, "connection", "condition", null);
  assert.deepEqual(
    selectCommandBarFeedback(state).map((e) => e.key),
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
  assert.equal(selectCommandBarFeedback(repeated).length, 0);
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
  assert.equal(selectCommandBarFeedback(state).length, 1);
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
  assert.equal(selectCommandBarFeedback(state).length, 1);
});

test("retiring one source cannot remove an independent result on the same object", () => {
  let state = observeFeedback(
    createFeedbackState(),
    "account:operation",
    "result",
    account,
  );
  state = observeFeedback(
    state,
    "account:recharge",
    "result",
    attentionStatus("account.recharge_open_failed", { scope: "account" }),
  );
  state = observeFeedback(state, "account:recharge", "result", null);
  assert.deepEqual(
    selectCommandBarFeedback(state).map((entry) => entry.key),
    ["account:operation"],
  );
});

test("Task results are retained locally without a path into the global collection", () => {
  let state = observeFeedback(createFeedbackState(), "stop:t2", "result", {
    ...attentionStatus("run.stop_failed", { scope: "task", taskId: "t2" }),
    local: true,
  });
  state = observeFeedback(state, "account", "result", account);
  assert.deepEqual(
    selectCommandBarFeedback(state).map((entry) => entry.key),
    ["account"],
  );
  assert.equal(state.entries["stop:t2"].audience.taskId, "t2");
});

test("security cleaning preserves non-Account tokens, cycles and dismissal but clears all diagnostic copies", () => {
  let state = observeFeedback(createFeedbackState(), "account", "result", {
    ...account,
    diagnostic: "old account diagnostic",
  });
  const started = beginFeedback(state, "compact:t1", {
    ...attentionStatus("run.compact_failed", { scope: "task", taskId: "t1" }),
    diagnostic: "old diagnostic",
  });
  state = settleFeedback(started.state, started.token, {
    ...attentionStatus("run.compact_failed", { scope: "task", taskId: "t1" }),
    diagnostic: "old diagnostic",
  });
  state = dismissFeedback(state, started.token.key, started.token.cycle);
  state = clearSecurityFeedback(state);
  assert.equal(state.epoch, started.token.epoch);
  assert.equal(feedbackTokenCurrent(state, started.token), true);
  assert.equal(state.entries["compact:t1"].dismissed, true);
  assert.equal(state.entries["compact:t1"].diagnostic, undefined);
  assert.equal(state.entries.account, undefined);
  assert.equal(state.announcement, null);
  state = settleFeedback(
    state,
    started.token,
    attentionStatus("feedback.unconfirmed", { scope: "task", taskId: "t1" }),
  );
  assert.equal(state.entries["compact:t1"].id, "feedback.unconfirmed");
});
