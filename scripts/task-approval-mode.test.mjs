import { decodeProductStateFixture as decodeWorkbenchSnapshot } from "./test-support/decode-product-state-fixture.mjs";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { TaskApprovalRequests } from "../frontend/src/features/approvals/mode-state.ts";
import { decodeTaskApprovalModeResult } from "../frontend/src/bridge/decode-contracts.ts";
import { BridgeClient } from "../frontend/src/bridge/client.ts";
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
function task(overrides = {}) {
  return {
    ...structuredClone(fixture.tasks[0]),
    availableApprovalModes: ["manual", "auto_review", "full_access"],
    ...overrides,
  };
}
function snapshot(task, revision = "2") {
  return {
    ...structuredClone(fixture),
    revision,
    tasks: task ? [task] : [],
    taskIndex: task ? [{ id: task.id }] : [],
  };
}
function requests() {
  const state = new TaskApprovalRequests();
  state.reset("1");
  state.observe(snapshot(task(), "1"), "1");
  return state;
}

test("approval request acceptance waits for committed mode and revision, with duplicate suppression", () => {
  const state = requests();
  const initial = task();
  const intent = state.begin(initial, "full_access");
  assert.ok(intent);
  assert.equal(state.begin(initial, "auto_review"), null);
  state.accept(intent, "2");
  assert.equal(state.view()[initial.id].phase, "awaiting_snapshot");
  assert.deepEqual(
    state.observe(
      snapshot(
        task({
          availableApprovalModes: [],
          approvalChange: {
            revision: "2",
            targetMode: "full_access",
            state: "pending",
          },
        }),
      ),
      "1",
    ),
    [],
  );
  assert.deepEqual(
    state.observe(
      snapshot(
        task({ approvalRevision: "2", approvalMode: "full_access" }),
        "3",
      ),
      "1",
    ),
    [{ taskId: initial.id, outcome: "completed" }],
  );
  state.accept(intent, "2");
  state.requireSync(intent);
  assert.deepEqual(state.view(), {});
});

test("failure retries cannot consume the old result before Host accepts or publishes this intent", () => {
  const state = requests();
  const failed = task({
    approvalResult: { revision: "2", outcome: "failed", reason: "busy" },
  });
  const intent = state.begin(failed, "auto_review");
  assert.deepEqual(state.observe(snapshot(failed, "1"), "1"), []);
  assert.deepEqual(state.observe(snapshot(failed, "2"), "1"), []);
  state.accept(intent, "2");
  assert.deepEqual(state.observe(snapshot(failed, "3"), "1"), [
    { taskId: failed.id, outcome: "failed", reason: "busy" },
  ]);
  assert.ok(state.begin(failed, "auto_review"));
});

test("Snapshot can resolve before command acknowledgement and generations discard late responses", () => {
  const state = requests();
  const intent = state.begin(task(), "auto_review");
  assert.deepEqual(
    state.observe(
      snapshot(task({ approvalRevision: "2", approvalMode: "auto_review" })),
      "1",
    ),
    [{ taskId: "3", outcome: "completed" }],
  );
  state.accept(intent, "2");
  assert.deepEqual(state.view(), {});
  const later = state.begin(
    task({ approvalRevision: "2", approvalMode: "auto_review" }),
    "manual",
  );
  state.reset("2");
  state.accept(later, "3");
  state.requireSync(later);
  assert.deepEqual(
    state.observe(snapshot(task({ approvalRevision: "3" })), "1"),
    [],
  );
  assert.deepEqual(state.view(), {});
});

test("timeout only requests synchronization; unknown or recovering Host state keeps the intent locked", () => {
  for (const phase of ["pending", "recovering", "outcome_unknown"]) {
    const state = requests();
    const intent = state.begin(task(), "full_access");
    state.requireSync(intent);
    assert.equal(state.view()["3"].phase, "sync_required");
    assert.deepEqual(
      state.observe(
        snapshot(
          task({
            binding: { ...task().binding, epoch: "2" },
            availableApprovalModes: [],
            approvalChange: {
              revision: "2",
              targetMode: "full_access",
              state: phase,
            },
          }),
        ),
        "1",
      ),
      [],
    );
    assert.equal(state.begin(task(), "manual"), null);
    assert.deepEqual(
      state.observe(
        snapshot(
          task({ approvalRevision: "2", approvalMode: "full_access" }),
          "3",
        ),
        "1",
      ),
      [{ taskId: "3", outcome: "completed" }],
    );
  }
  const state = requests();
  const intent = state.begin(task(), "auto_review");
  state.requireSync(intent);
  assert.deepEqual(state.observe(snapshot(task()), "1"), []);
  assert.deepEqual(state.unconfirmed(intent), {
    taskId: "3",
    outcome: "not_confirmed",
  });
  assert.ok(state.begin(task(), "auto_review"));
});

test("ABA and binding replacement cannot confirm the wrong approval intent", () => {
  const state = requests();
  state.begin(task(), "auto_review");
  assert.deepEqual(
    state.observe(
      snapshot(task({ approvalRevision: "3", approvalMode: "manual" })),
      "1",
    ),
    [{ taskId: "3", outcome: "superseded" }],
  );
  const other = state.begin(task({ approvalRevision: "3" }), "auto_review");
  assert.throws(() => state.accept(other, "2"), /revision mismatch/);
  assert.deepEqual(
    state.observe(
      snapshot(
        task({
          approvalRevision: "3",
          binding: { ...task().binding, epoch: "8" },
        }),
        "3",
      ),
      "1",
    ),
    [{ taskId: "3", outcome: "superseded" }],
  );
  state.begin(task(), "auto_review");
  assert.deepEqual(state.observe(snapshot(null, "4"), "1"), [
    { taskId: "3", outcome: "missing" },
  ]);
});

test("availability is per target and Host-owned; unsupported tasks and no-ops do not send", () => {
  const state = requests();
  assert.equal(
    state.begin(task({ availableApprovalModes: [] }), "auto_review"),
    null,
  );
  assert.equal(state.begin(task(), "manual"), null);
  assert.equal(
    state.begin(
      task({ availableApprovalModes: ["manual", "auto_review"] }),
      "full_access",
    ),
    null,
  );
  assert.ok(
    state.begin(
      task({ availableApprovalModes: ["manual", "auto_review"] }),
      "auto_review",
    ),
  );
});

test("approval command is strict, identity-bound and transports the two exact CAS tokens once", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: {
      invoke: async (command, payload) => {
        calls.push({ command, payload });
        return {
          accepted: true,
          taskId: "3",
          approvalRevision: "2",
          reason: null,
        };
      },
      on() {
        return () => {};
      },
    },
  });
  assert.equal(
    (await client.setApprovalMode("3", "auto_review", "7", "1"))
      .approvalRevision,
    "2",
  );
  assert.deepEqual(calls, [
    {
      command: "metawork.tasks.setApprovalMode",
      payload: {
        taskId: "3",
        targetMode: "auto_review",
        expectedBindingEpoch: "7",
        expectedApprovalRevision: "1",
      },
    },
  ]);
  for (const bad of [
    { accepted: true, taskId: "4", approvalRevision: "2", reason: null },
    { accepted: true, taskId: "3", approvalRevision: "0", reason: null },
    { accepted: true, taskId: "3", approvalRevision: "02", reason: null },
    { accepted: true, taskId: "3", approvalRevision: "2", reason: "busy" },
    { accepted: false, taskId: "3", approvalRevision: "2", reason: "busy" },
    { accepted: false, taskId: "3", approvalRevision: null, reason: "unknown" },
  ])
    assert.throws(() => decodeTaskApprovalModeResult(bad, "3"));
});

test("strict Snapshot preserves approval availability, operation and terminal truth", () => {
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(fixture));
  const pending = snapshot(
    task({
      availableApprovalModes: [],
      approvalChange: {
        revision: "2",
        targetMode: "full_access",
        state: "pending",
      },
    }),
  );
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(pending));
  for (const mutate of [
    (t) => {
      delete t.approvalRevision;
    },
    (t) => {
      t.approvalRevision = "0";
    },
    (t) => {
      t.availableApprovalModes = ["manual", "manual"];
    },
    (t) => {
      t.approvalChange.extra = true;
    },
    (t) => {
      t.approvalChange.revision = "9";
    },
    (t) => {
      t.approvalChange.state = "done";
    },
    (t) => {
      t.availableApprovalModes = ["auto_review"];
    },
    (t) => {
      t.approvalResult = { revision: "2", outcome: "completed", reason: null };
    },
  ]) {
    const invalid = structuredClone(pending);
    mutate(invalid.tasks[0]);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
});
