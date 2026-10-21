import type { TaskSummary, WorkbenchSnapshot } from "../bridge/contracts.ts";

/**
 * A Task participates in active navigation only while its owning Workspace is
 * present in the same canonical snapshot. Workspace removal preserves history
 * but deliberately removes that history from active navigation.
 */
export function navigableTasks(snapshot: WorkbenchSnapshot): TaskSummary[] {
  const workspaceIds = new Set(
    snapshot.workspaces.map((workspace) => workspace.id),
  );
  return snapshot.taskIndex.filter((task) =>
    workspaceIds.has(task.workspaceId),
  );
}
