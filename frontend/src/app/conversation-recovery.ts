import type { WorkbenchSnapshot } from "../bridge/contracts.ts";

export type ConversationRecoveryResult =
  | { kind: "ready"; bindingEpoch: string }
  | { kind: "failed"; error: Error }
  | { kind: "cancelled"; error: Error }
  | { kind: "timeout"; error: Error };

export type ConversationRecoveryInspection =
  ConversationRecoveryResult | { kind: "waiting" };

export type ConversationRecoveryAttempt = {
  taskId: string;
  attemptId: string;
  generation: string;
};

type RecoverySnapshot = Pick<WorkbenchSnapshot, "tasks">;

type RecoveryWaiter = ConversationRecoveryAttempt & {
  promise: Promise<ConversationRecoveryResult>;
  resolve: (result: ConversationRecoveryResult) => void;
  timeout: ReturnType<typeof setTimeout>;
};

function recoveryError(message: string) {
  return new Error(message);
}

export class ConversationRecoveryCoordinator {
  private generation = "0";
  private latestSnapshot: RecoverySnapshot | null = null;
  private readonly waiters = new Map<string, RecoveryWaiter>();

  resetGeneration(generation: string) {
    if (generation === this.generation) return;
    this.cancelAll("The Host connection changed during conversation restore");
    this.generation = generation;
    this.latestSnapshot = null;
  }

  observeSnapshot(snapshot: RecoverySnapshot, generation: string) {
    if (generation !== this.generation) return;
    this.latestSnapshot = snapshot;
    for (const [key, waiter] of this.waiters) {
      const result = this.inspectLatest(waiter);
      if (result.kind !== "waiting") this.settle(key, result);
    }
  }

  inspectLatest(
    attempt: ConversationRecoveryAttempt,
  ): ConversationRecoveryInspection {
    if (attempt.generation !== this.generation)
      return {
        kind: "cancelled",
        error: recoveryError(
          "The Host connection changed during conversation restore",
        ),
      };
    if (!this.latestSnapshot) return { kind: "waiting" };

    const task = this.latestSnapshot.tasks.find(
      (candidate) => candidate.id === attempt.taskId,
    );
    if (!task)
      return {
        kind: "failed",
        error: recoveryError(
          "The Task disappeared during conversation restore",
        ),
      };

    if (task.activeOperation?.kind === "restore") {
      if (task.activeOperation.id === attempt.attemptId)
        return { kind: "waiting" };
      return {
        kind: "failed",
        error: recoveryError("A different conversation restore is active"),
      };
    }
    if (task.activeOperation)
      return {
        kind: "failed",
        error: recoveryError(
          "A different Task operation started during conversation restore",
        ),
      };
    if (task.continuationAvailable)
      return { kind: "ready", bindingEpoch: task.binding.epoch };
    if (task.continuationUnavailableReason === "session_recovery_required")
      return { kind: "waiting" };

    return {
      kind: "failed",
      error: recoveryError(
        task.continuationUnavailableReason ??
          "Conversation restore did not produce a usable Session",
      ),
    };
  }

  waitForAttempt(
    attempt: ConversationRecoveryAttempt & { timeoutMs: number },
  ): Promise<ConversationRecoveryResult> {
    const inspection = this.inspectLatest(attempt);
    if (inspection.kind !== "waiting") return Promise.resolve(inspection);

    const key = this.waiterKey(attempt);
    const existing = this.waiters.get(key);
    if (existing) return existing.promise;

    let resolveWaiter!: (result: ConversationRecoveryResult) => void;
    const promise = new Promise<ConversationRecoveryResult>((resolve) => {
      resolveWaiter = resolve;
    });
    const timeout = setTimeout(() => {
      this.settle(key, {
        kind: "timeout",
        error: recoveryError("Timed out waiting for conversation restore"),
      });
    }, attempt.timeoutMs);
    this.waiters.set(key, {
      taskId: attempt.taskId,
      attemptId: attempt.attemptId,
      generation: attempt.generation,
      promise,
      resolve: resolveWaiter,
      timeout,
    });
    return promise;
  }

  cancelExceptTask(taskId: string | null) {
    for (const [key, waiter] of this.waiters) {
      if (taskId !== null && waiter.taskId === taskId) continue;
      this.settle(key, {
        kind: "cancelled",
        error: recoveryError(
          "The active Task changed during conversation restore",
        ),
      });
    }
  }

  dispose() {
    this.cancelAll("Conversation restore coordination was disposed");
    this.generation = "0";
    this.latestSnapshot = null;
  }

  private waiterKey(attempt: ConversationRecoveryAttempt) {
    return `${attempt.generation}:${attempt.taskId}:${attempt.attemptId}`;
  }

  private settle(key: string, result: ConversationRecoveryResult) {
    const waiter = this.waiters.get(key);
    if (!waiter) return;
    this.waiters.delete(key);
    clearTimeout(waiter.timeout);
    waiter.resolve(result);
  }

  private cancelAll(message: string) {
    for (const key of [...this.waiters.keys()])
      this.settle(key, {
        kind: "cancelled",
        error: recoveryError(message),
      });
  }
}
