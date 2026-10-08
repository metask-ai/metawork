import type {
  TaskCreateReason,
  TaskCreateResult,
  NewTaskModelSelectionIntent,
  ApprovalMode,
  TaskRestoreReason,
  TaskRunInput,
  TaskRunReason,
  TaskRunResult,
  TaskWorkspaceIntent,
} from "../../bridge/contracts.ts";

export type TaskSubmissionClient = {
  createTask: (
    workspace: TaskWorkspaceIntent,
    expectedExecutionGeneration: string,
    expectedSelectionRevision: string,
    modelSelection: NewTaskModelSelectionIntent | null,
    expectedSkillCatalogRevision: string | null,
    expectedSkillSelectionRevision: string | null,
    approvalMode: ApprovalMode,
  ) => Promise<TaskCreateResult>;
  run: (
    taskId: string,
    expectedBindingEpoch: string,
    input: TaskRunInput,
  ) => Promise<TaskRunResult>;
};

export type EnsureTaskContinuationResult =
  | { kind: "ready"; bindingEpoch: string }
  | { kind: "rejected"; reason: TaskRestoreReason }
  | { kind: "failed"; error: unknown };

export type TaskSubmissionResult =
  | { kind: "started"; taskId: string; created: boolean }
  | { kind: "create_rejected"; reason: TaskCreateReason }
  | { kind: "create_failed"; error: unknown }
  | {
      kind: "run_rejected";
      taskId: string;
      created: boolean;
      reason: TaskRunReason;
    }
  | {
      kind: "continuation_rejected";
      taskId: string;
      created: boolean;
      reason: TaskRestoreReason;
    }
  | {
      kind: "continuation_failed";
      taskId: string;
      created: boolean;
      error: unknown;
    }
  | { kind: "run_failed"; taskId: string; created: boolean; error: unknown };

export async function submitTaskInstruction({
  client,
  taskId,
  workspace,
  expectedExecutionGeneration,
  expectedSelectionRevision,
  modelSelection,
  expectedBindingEpoch,
  approvalMode,
  input,
  continuationRecoveryAvailable = false,
  ensureContinuation,
  onTaskCreated,
}: {
  client: TaskSubmissionClient;
  taskId: string | null;
  workspace: TaskWorkspaceIntent;
  expectedExecutionGeneration: string;
  expectedSelectionRevision: string;
  modelSelection: NewTaskModelSelectionIntent | null;
  expectedBindingEpoch: string | null;
  approvalMode: ApprovalMode;
  input: TaskRunInput;
  continuationRecoveryAvailable?: boolean;
  ensureContinuation?: (
    taskId: string,
    expectedBindingEpoch: string,
  ) => Promise<EnsureTaskContinuationResult>;
  onTaskCreated: (taskId: string) => void;
}): Promise<TaskSubmissionResult> {
  let targetTaskId = taskId;
  let targetBindingEpoch = expectedBindingEpoch;
  let created = false;
  if (!targetTaskId) {
    try {
      const createdTask = await client.createTask(
        workspace,
        expectedExecutionGeneration,
        expectedSelectionRevision,
        modelSelection,
        input.kind === "skill" ? input.catalogRevision : null,
        input.kind === "skill" ? input.selectionRevision : null,
        approvalMode,
      );
      if (!createdTask.accepted)
        return { kind: "create_rejected", reason: createdTask.reason };
      targetTaskId = createdTask.taskId;
      targetBindingEpoch = createdTask.bindingEpoch;
    } catch (error) {
      return { kind: "create_failed", error };
    }
    created = true;
    onTaskCreated(targetTaskId);
  }

  if (!targetBindingEpoch)
    return {
      kind: "run_failed",
      taskId: targetTaskId,
      created,
      error: new Error("Task execution binding is unavailable"),
    };
  if (continuationRecoveryAvailable) {
    if (!ensureContinuation)
      return {
        kind: "continuation_failed",
        taskId: targetTaskId,
        created,
        error: new Error("Task continuation recovery is unavailable"),
      };
    let continuation: EnsureTaskContinuationResult;
    try {
      continuation = await ensureContinuation(targetTaskId, targetBindingEpoch);
    } catch (error) {
      return {
        kind: "continuation_failed",
        taskId: targetTaskId,
        created,
        error,
      };
    }
    if (continuation.kind === "rejected")
      return {
        kind: "continuation_rejected",
        taskId: targetTaskId,
        created,
        reason: continuation.reason,
      };
    if (continuation.kind === "failed")
      return {
        kind: "continuation_failed",
        taskId: targetTaskId,
        created,
        error: continuation.error,
      };
    targetBindingEpoch = continuation.bindingEpoch;
  }
  try {
    const run = await client.run(targetTaskId, targetBindingEpoch, input);
    if (!run.accepted)
      return {
        kind: "run_rejected",
        taskId: targetTaskId,
        created,
        reason: run.reason,
      };
  } catch (error) {
    return {
      kind: "run_failed",
      taskId: targetTaskId,
      created,
      error,
    };
  }
  return { kind: "started", taskId: targetTaskId, created };
}
