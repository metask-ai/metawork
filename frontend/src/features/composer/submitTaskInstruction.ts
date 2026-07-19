export type TaskSubmissionClient = {
  createTask: (workspaceGrant: string) => Promise<string>;
  run: (taskId: string, instruction: string) => Promise<unknown>;
};

export type TaskSubmissionResult =
  | { kind: "started"; taskId: string; created: boolean }
  | { kind: "create_failed"; error: unknown }
  | { kind: "run_failed"; taskId: string; created: boolean; error: unknown };

export async function submitTaskInstruction({
  client,
  taskId,
  workspaceGrant,
  instruction,
  onTaskCreated,
}: {
  client: TaskSubmissionClient;
  taskId: string | null;
  workspaceGrant: string;
  instruction: string;
  onTaskCreated: (taskId: string) => void;
}): Promise<TaskSubmissionResult> {
  let targetTaskId = taskId;
  let created = false;
  if (!targetTaskId) {
    if (!workspaceGrant)
      return {
        kind: "create_failed",
        error: new Error("Workspace access is required"),
      };
    try {
      targetTaskId = await client.createTask(workspaceGrant);
    } catch (error) {
      return { kind: "create_failed", error };
    }
    created = true;
    onTaskCreated(targetTaskId);
  }

  try {
    await client.run(targetTaskId, instruction);
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
