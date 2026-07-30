import type {
  TaskCreateReason,
  TaskCreateResult,
  TaskRunInput,
  TaskRunReason,
  TaskRunResult,
} from "../../bridge/contracts.ts";

export type TaskSubmissionClient = {
  createTask: (
    workspaceId: string,
    expectedWorkspaceEpoch: string,
    expectedExecutionGeneration: string,
    expectedSkillCatalogRevision: string | null,
  ) => Promise<TaskCreateResult>;
  run: (
    taskId: string,
    expectedBindingEpoch: string,
    input: TaskRunInput,
  ) => Promise<TaskRunResult>;
};

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
  | { kind: "run_failed"; taskId: string; created: boolean; error: unknown };

export async function submitTaskInstruction({
  client,
  taskId,
  workspaceId,
  expectedWorkspaceEpoch,
  expectedExecutionGeneration,
  expectedBindingEpoch,
  input,
  onTaskCreated,
}: {
  client: TaskSubmissionClient;
  taskId: string | null;
  workspaceId: string;
  expectedWorkspaceEpoch: string;
  expectedExecutionGeneration: string;
  expectedBindingEpoch: string | null;
  input: TaskRunInput;
  onTaskCreated: (taskId: string) => void;
}): Promise<TaskSubmissionResult> {
  let targetTaskId = taskId;
  let targetBindingEpoch = expectedBindingEpoch;
  let created = false;
  if (!targetTaskId) {
    if (!workspaceId || !expectedWorkspaceEpoch)
      return {
        kind: "create_failed",
        error: new Error("Workspace access is required"),
      };
    try {
      const createdTask = await client.createTask(
        workspaceId,
        expectedWorkspaceEpoch,
        expectedExecutionGeneration,
        input.kind === "skill" ? input.catalogRevision : null,
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
