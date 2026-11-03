import type { TaskView, WorkbenchSnapshot } from "../bridge/contracts.ts";

export type TaskStopFeedback = {
  scope: string;
  taskId: string | null;
  runId: string | null;
  compactId: string | null;
  restoreId: string | null;
  waitingSubmissionIds: readonly string[];
  submissionIds: readonly string[];
  phase: "requesting" | "awaiting" | "unknown" | "failed";
  diagnostic?: string;
};

/** Session-only operation identity; observing an outcome never claims causality. */
export class TaskStopFeedbackController {
  private entries: TaskStopFeedback[] = [];
  private readonly publish: (entries: TaskStopFeedback[]) => void;

  constructor(publish: (entries: TaskStopFeedback[]) => void) {
    this.publish = publish;
  }

  private changed() {
    this.publish([...this.entries]);
  }

  begin(scope: string, task: TaskView | null, submissionIds: string[]) {
    const waitingSubmissionIds =
      task?.inputSubmissions
        .filter((input) => input.state === "waiting")
        .map((input) => input.submission.operationId) ?? [];
    const token: TaskStopFeedback = {
      scope,
      taskId: task?.id ?? null,
      runId: task?.currentRunPhase ? task.currentRunId : null,
      compactId:
        task?.activeOperation?.kind === "compact"
          ? task.activeOperation.id
          : null,
      restoreId:
        task?.activeOperation?.kind === "restore"
          ? task.activeOperation.id
          : null,
      waitingSubmissionIds,
      submissionIds: [...new Set([...submissionIds, ...waitingSubmissionIds])],
      phase: "requesting",
    };
    this.entries = this.entries.filter((entry) =>
      task ? entry.taskId !== task.id : entry.scope !== scope,
    );
    this.entries.push(token);
    this.changed();
    return token;
  }

  pending(scope: string, task: TaskView | null) {
    return this.entries.some(
      (entry) =>
        (entry.phase === "requesting" || entry.phase === "awaiting") &&
        (task ? entry.taskId === task.id : entry.scope === scope) &&
        (entry.phase === "requesting" ||
          !task ||
          (!entry.runId &&
            !entry.compactId &&
            !task.currentRunPhase &&
            task.activeOperation === null) ||
          (entry.runId !== null && entry.runId === task.currentRunId) ||
          (task.activeOperation?.kind === "compact" &&
            entry.compactId === task.activeOperation.id) ||
          (task.activeOperation?.kind === "restore" &&
            entry.restoreId === task.activeOperation.id)),
    );
  }

  target(token: TaskStopFeedback, taskId: string) {
    if (!this.entries.includes(token)) return;
    token.taskId = taskId;
    this.changed();
  }

  settle(
    token: TaskStopFeedback,
    phase: TaskStopFeedback["phase"],
    diagnostic?: string,
  ) {
    if (!this.entries.includes(token)) return;
    token.phase = phase;
    token.diagnostic = diagnostic;
    this.changed();
  }

  retire(token: TaskStopFeedback) {
    if (!this.entries.includes(token)) return;
    this.entries = this.entries.filter((entry) => entry !== token);
    this.changed();
  }

  observe(snapshot: WorkbenchSnapshot) {
    let changed = false;
    this.entries = this.entries.filter((entry) => {
      const task = snapshot.tasks.find(
        (candidate) => candidate.id === entry.taskId,
      );
      if (!task) return true;
      // A Run may only bind through an input known before this stop request.
      if (!entry.runId) {
        const run = task.runs.find(
          (candidate) =>
            candidate.submission &&
            entry.submissionIds.includes(candidate.submission.operationId),
        );
        if (run) {
          entry.runId = run.id;
          changed = true;
        }
      }
      const manifest =
        snapshot.taskPage?.task.id === task.id
          ? snapshot.taskPage.runManifest.find(
              (candidate) => candidate.id === entry.runId,
            )
          : undefined;
      const run =
        manifest ?? task.runs.find((candidate) => candidate.id === entry.runId);
      const compact = task.compacts.find(
        (candidate) => candidate.operationId === entry.compactId,
      );
      const preparationFinished =
        !entry.runId &&
        !entry.compactId &&
        (entry.restoreId !== null || entry.waitingSubmissionIds.length > 0) &&
        !(
          task.activeOperation?.kind === "restore" &&
          task.activeOperation.id === entry.restoreId
        ) &&
        entry.waitingSubmissionIds.every((id) =>
          task.inputSubmissions.some(
            (input) =>
              input.submission.operationId === id && input.state !== "waiting",
          ),
        );
      if (
        (run && (run.phase === "stopping" || run.terminal !== null)) ||
        (compact &&
          compact.phase !== "queued" &&
          compact.phase !== "compacting") ||
        preparationFinished
      ) {
        changed = true;
        return false;
      }
      return true;
    });
    if (changed) this.changed();
  }

  reset() {
    this.entries = [];
    this.changed();
  }

  clearDiagnostics() {
    let changed = false;
    for (const entry of this.entries) {
      if (entry.diagnostic !== undefined) {
        delete entry.diagnostic;
        changed = true;
      }
    }
    if (changed) this.changed();
  }
}
