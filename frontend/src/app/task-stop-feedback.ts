import type { TaskView, WorkbenchSnapshot } from "../bridge/contracts.ts";

export type TaskStopFeedback = {
  scope: string;
  taskId: string | null;
  runId: string | null;
  compactId: string | null;
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
    const token: TaskStopFeedback = {
      scope,
      taskId: task?.id ?? null,
      runId: task?.currentRunPhase ? task.currentRunId : null,
      compactId:
        task?.activeOperation?.kind === "compact"
          ? task.activeOperation.id
          : null,
      submissionIds,
      phase: "requesting",
    };
    this.entries = this.entries.filter((entry) =>
      task ? entry.taskId !== task.id : entry.scope !== scope,
    );
    this.entries.push(token);
    this.changed();
    return token;
  }

  requesting(scope: string, taskId: string | null) {
    return this.entries.some(
      (entry) =>
        entry.phase === "requesting" &&
        (taskId ? entry.taskId === taskId : entry.scope === scope),
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
      // A newly created Task may only bind through a pre-stop submission.
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
      if (
        (run && (run.phase === "stopping" || run.terminal !== null)) ||
        (compact &&
          compact.phase !== "queued" &&
          compact.phase !== "compacting")
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
}
