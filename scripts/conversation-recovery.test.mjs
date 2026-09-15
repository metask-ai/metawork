import assert from "node:assert/strict";
import test from "node:test";

import { ConversationRecoveryCoordinator } from "../frontend/src/app/conversation-recovery.ts";

function task({
  id = "9",
  epoch = "12",
  activeOperation = null,
  continuationAvailable = false,
  continuationUnavailableReason = "session_recovery_required",
} = {}) {
  return {
    id,
    binding: { epoch },
    activeOperation,
    continuationAvailable,
    continuationUnavailableReason,
  };
}

function snapshot(currentTask) {
  return { tasks: currentTask ? [currentTask] : [] };
}

const attempt = {
  taskId: "9",
  attemptId: "31",
  generation: "7",
};

test("a final snapshot observed before waiter registration returns its adopted epoch", async () => {
  const coordinator = new ConversationRecoveryCoordinator();
  coordinator.resetGeneration("7");
  coordinator.observeSnapshot(
    snapshot(
      task({
        epoch: "13",
        continuationAvailable: true,
        continuationUnavailableReason: null,
      }),
    ),
    "7",
  );

  assert.deepEqual(
    await coordinator.waitForAttempt({ ...attempt, timeoutMs: 50 }),
    { kind: "ready", bindingEpoch: "13" },
  );
  coordinator.dispose();
});

test("restore completion accepts both stable and adopted binding epochs", async () => {
  for (const epoch of ["12", "13"]) {
    const coordinator = new ConversationRecoveryCoordinator();
    coordinator.resetGeneration("7");
    coordinator.observeSnapshot(
      snapshot(
        task({
          activeOperation: { kind: "restore", id: "31" },
          continuationUnavailableReason: "session_recovery_in_progress",
        }),
      ),
      "7",
    );
    const waiting = coordinator.waitForAttempt({ ...attempt, timeoutMs: 50 });
    coordinator.observeSnapshot(
      snapshot(
        task({
          epoch,
          continuationAvailable: true,
          continuationUnavailableReason: null,
        }),
      ),
      "7",
    );
    assert.deepEqual(await waiting, { kind: "ready", bindingEpoch: epoch });
    coordinator.dispose();
  }
});

test("coalesced waiters share one attempt and settle from one final snapshot", async () => {
  const coordinator = new ConversationRecoveryCoordinator();
  coordinator.resetGeneration("7");
  coordinator.observeSnapshot(snapshot(task()), "7");
  const first = coordinator.waitForAttempt({ ...attempt, timeoutMs: 50 });
  const second = coordinator.waitForAttempt({ ...attempt, timeoutMs: 50 });
  assert.equal(first, second);

  coordinator.observeSnapshot(
    snapshot(
      task({
        epoch: "13",
        continuationAvailable: true,
        continuationUnavailableReason: null,
      }),
    ),
    "7",
  );
  assert.deepEqual(await first, { kind: "ready", bindingEpoch: "13" });
  coordinator.dispose();
});

test("a different active restore attempt fails closed", async () => {
  const coordinator = new ConversationRecoveryCoordinator();
  coordinator.resetGeneration("7");
  coordinator.observeSnapshot(
    snapshot(
      task({
        activeOperation: { kind: "restore", id: "32" },
        continuationUnavailableReason: "session_recovery_in_progress",
      }),
    ),
    "7",
  );
  const result = await coordinator.waitForAttempt({
    ...attempt,
    timeoutMs: 50,
  });
  assert.equal(result.kind, "failed");
  assert.match(result.error.message, /different conversation restore/);
  coordinator.dispose();
});

test("Task disappearance and terminal recovery failure settle as failures", async () => {
  for (const finalSnapshot of [
    snapshot(null),
    snapshot(
      task({
        continuationUnavailableReason: "session_recovery_failed",
      }),
    ),
  ]) {
    const coordinator = new ConversationRecoveryCoordinator();
    coordinator.resetGeneration("7");
    coordinator.observeSnapshot(snapshot(task()), "7");
    const waiting = coordinator.waitForAttempt({ ...attempt, timeoutMs: 50 });
    coordinator.observeSnapshot(finalSnapshot, "7");
    assert.equal((await waiting).kind, "failed");
    coordinator.dispose();
  }
});

test("connection generation reset and Task navigation cancel outstanding waiters", async () => {
  for (const cancel of [
    (coordinator) => coordinator.resetGeneration("8"),
    (coordinator) => coordinator.cancelExceptTask("10"),
  ]) {
    const coordinator = new ConversationRecoveryCoordinator();
    coordinator.resetGeneration("7");
    coordinator.observeSnapshot(snapshot(task()), "7");
    const waiting = coordinator.waitForAttempt({ ...attempt, timeoutMs: 50 });
    cancel(coordinator);
    assert.equal((await waiting).kind, "cancelled");
    coordinator.dispose();
  }
});

test("timeout stops waiting but a later canonical snapshot remains inspectable", async () => {
  const coordinator = new ConversationRecoveryCoordinator();
  coordinator.resetGeneration("7");
  coordinator.observeSnapshot(snapshot(task()), "7");
  const result = await coordinator.waitForAttempt({ ...attempt, timeoutMs: 1 });
  assert.equal(result.kind, "timeout");

  coordinator.observeSnapshot(
    snapshot(
      task({
        epoch: "13",
        continuationAvailable: true,
        continuationUnavailableReason: null,
      }),
    ),
    "7",
  );
  assert.deepEqual(coordinator.inspectLatest(attempt), {
    kind: "ready",
    bindingEpoch: "13",
  });
  coordinator.dispose();
});
