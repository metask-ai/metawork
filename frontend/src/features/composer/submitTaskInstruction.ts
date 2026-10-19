import type {
  TaskCreateResult,
  TaskRunInput,
  SendInputResult,
  TaskView,
  TaskCreateReason,
  SendInputReason,
} from "../../bridge/contracts.ts";

export type TaskSubmissionResult =
  | { kind: "accepted"; taskId: string }
  | { kind: "rejected"; taskId: string; reason: SendInputReason }
  | { kind: "unknown"; taskId: string | null }
  | { kind: "create_rejected"; reason: TaskCreateReason }
  | { kind: "cancelled"; taskId: string | null };

type SessionOptions = {
  taskId: string | null;
  create: () => Promise<TaskCreateResult>;
  send: (
    operationId: string,
    taskId: string,
    input: TaskRunInput,
  ) => Promise<SendInputResult>;
  stop: (taskId: string) => Promise<unknown>;
  current: () => boolean;
  onCreated: (taskId: string) => void;
};

/** Renderer owns identity acquisition, never execution readiness or preparation. */
export class TaskSubmissionSession {
  private creation: Promise<TaskCreateResult> | null = null;
  private taskId: string | null;
  private pending = new Set<{
    cancelled: boolean;
    delivered: boolean;
    onCancelled: () => void;
  }>();

  private options: SessionOptions;

  constructor(options: SessionOptions) {
    this.options = options;
    this.taskId = options.taskId;
  }

  private identity(): Promise<TaskCreateResult> {
    if (!this.creation) {
      try {
        this.creation = this.options.create().then((result) => {
          if (result.accepted) {
            this.taskId = result.taskId;
            if (this.options.current()) this.options.onCreated(result.taskId);
          }
          return result;
        });
      } catch (error) {
        this.creation = Promise.reject(error);
      }
    }
    return this.creation;
  }

  async submit(
    operationId: string,
    input: TaskRunInput,
    onTarget: (taskId: string) => void,
    onCancelled: () => void = () => undefined,
  ): Promise<TaskSubmissionResult> {
    if (this.pending.size >= 64)
      return { kind: "create_rejected", reason: "capacity_reached" };
    const entry = { cancelled: false, delivered: false, onCancelled };
    this.pending.add(entry);
    try {
      let taskId = this.taskId;
      if (!taskId) {
        const created = await this.identity();
        if (!created.accepted)
          return { kind: "create_rejected", reason: created.reason };
        taskId = created.taskId;
      }
      if (entry.cancelled) return { kind: "cancelled", taskId };
      if (!this.options.current()) return { kind: "unknown", taskId };
      entry.delivered = true;
      onTarget(taskId);
      // Invoked in click/identity-promise registration order, independently
      // of all preceding send responses. The Bridge owns transport ordering.
      const result = await this.options.send(operationId, taskId, input);
      if (!this.options.current()) return { kind: "unknown", taskId };
      return result.outcome === "accepted"
        ? { kind: "accepted", taskId }
        : { kind: "rejected", taskId, reason: result.reason };
    } catch {
      return { kind: "unknown", taskId: this.taskId };
    } finally {
      this.pending.delete(entry);
    }
  }

  async stop(): Promise<void> {
    for (const entry of this.pending)
      if (!entry.delivered && !entry.cancelled) {
        entry.cancelled = true;
        entry.onCancelled();
      }
    if (this.taskId) {
      await this.options.stop(this.taskId);
      return;
    }
    if (!this.creation) return;
    // This callback precedes sends clicked after stop while creation is pending.
    const created = await this.creation;
    if (created.accepted && this.options.current())
      await this.options.stop(created.taskId);
  }
}

export function taskHasSubmission(
  task: TaskView | undefined,
  operationId: string,
): boolean {
  return Boolean(
    task &&
    (task.inputSubmissions.some(
      (record) => record.submission.operationId === operationId,
    ) ||
      task.runs.some(
        (run) =>
          run.submission?.operationId === operationId ||
          run.additionalInputs.some(
            (record) => record.operationId === operationId,
          ),
      )),
  );
}
