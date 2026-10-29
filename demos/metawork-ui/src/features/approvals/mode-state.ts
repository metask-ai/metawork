import type {
  ApprovalMode,
  TaskView,
  WorkbenchSnapshot,
  ApprovalFailureReason,
} from "../../bridge/contracts.ts";

export type ApprovalIntent = {
  taskId: string;
  targetMode: ApprovalMode;
  bindingEpoch: string;
  revision: string;
  nextRevision: string;
  generation: string;
  observedAtRevision: string;
};
export type ApprovalRequest = {
  intent: ApprovalIntent;
  phase: "sending" | "awaiting_snapshot" | "sync_required";
  observedPending: boolean;
};
export type ApprovalObservation = {
  taskId: string;
  outcome: "completed" | "failed" | "superseded" | "missing" | "not_confirmed";
  reason?: ApprovalFailureReason;
};

/** Owns only Renderer command races. All mode and availability facts come from Host. */
export class TaskApprovalRequests {
  private generation = "0";
  private snapshotRevision = "0";
  private requests = new Map<string, ApprovalRequest>();

  reset(generation: string) {
    this.generation = generation;
    this.snapshotRevision = "0";
    this.requests.clear();
  }

  view(): Record<string, ApprovalRequest> {
    return Object.fromEntries(this.requests);
  }

  begin(task: TaskView, targetMode: ApprovalMode): ApprovalIntent | null {
    if (
      this.requests.has(task.id) ||
      task.approvalChange ||
      task.approvalMode === targetMode ||
      !task.availableApprovalModes.includes(targetMode)
    )
      return null;
    const intent: ApprovalIntent = {
      taskId: task.id,
      targetMode,
      bindingEpoch: task.binding.epoch,
      revision: task.approvalRevision,
      nextRevision: (BigInt(task.approvalRevision) + 1n).toString(),
      generation: this.generation,
      observedAtRevision: this.snapshotRevision,
    };
    this.requests.set(task.id, {
      intent,
      phase: "sending",
      observedPending: false,
    });
    return intent;
  }

  current(intent: ApprovalIntent): boolean {
    return (
      intent.generation === this.generation &&
      this.requests.get(intent.taskId)?.intent === intent
    );
  }

  accept(intent: ApprovalIntent, revision: string) {
    if (!this.current(intent)) return;
    if (revision !== intent.nextRevision)
      throw new Error("Approval intent revision mismatch");
    this.requests.set(intent.taskId, {
      ...this.requests.get(intent.taskId)!,
      phase: "awaiting_snapshot",
    });
  }

  reject(intent: ApprovalIntent) {
    if (this.current(intent)) this.requests.delete(intent.taskId);
  }

  requireSync(intent: ApprovalIntent) {
    if (this.current(intent))
      this.requests.set(intent.taskId, {
        ...this.requests.get(intent.taskId)!,
        phase: "sync_required",
      });
  }

  observe(
    snapshot: WorkbenchSnapshot,
    generation: string,
  ): ApprovalObservation[] {
    if (generation !== this.generation) return [];
    this.snapshotRevision = snapshot.revision;
    const results: ApprovalObservation[] = [];
    for (const [taskId, request] of this.requests) {
      if (
        BigInt(snapshot.revision) <= BigInt(request.intent.observedAtRevision)
      )
        continue;
      const task = snapshot.tasks.find((entry) => entry.id === taskId);
      if (!task && snapshot.taskIndex.some((entry) => entry.id === taskId))
        continue;
      const { intent } = request;
      let result: ApprovalObservation | null = null;
      if (!task) result = { taskId, outcome: "missing" };
      else if (task.approvalChange?.revision === intent.nextRevision) {
        this.requests.set(taskId, { ...request, observedPending: true });
        continue;
      } else if (BigInt(task.approvalRevision) >= BigInt(intent.nextRevision)) {
        result = {
          taskId,
          outcome:
            task.approvalRevision === intent.nextRevision &&
            task.approvalMode === intent.targetMode
              ? "completed"
              : "superseded",
        };
      } else if (
        (request.phase === "awaiting_snapshot" || request.observedPending) &&
        task.approvalResult?.revision === intent.nextRevision &&
        task.approvalResult.outcome === "failed"
      ) {
        result = {
          taskId,
          outcome: "failed",
          reason: task.approvalResult.reason,
        };
      } else if (task.binding.epoch !== intent.bindingEpoch)
        result = { taskId, outcome: "superseded" };
      if (result) {
        this.requests.delete(taskId);
        results.push(result);
      }
    }
    return results;
  }

  /** Only an explicit user refresh can release a request with no terminal evidence. */
  unconfirmed(intent: ApprovalIntent): ApprovalObservation | null {
    if (!this.current(intent)) return null;
    this.requests.delete(intent.taskId);
    return { taskId: intent.taskId, outcome: "not_confirmed" };
  }
}
