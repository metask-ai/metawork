import type { WorkbenchSnapshot } from "../bridge/contracts.ts";

// A reading goal is a Run identity, not a transport cursor. Cursor lifetime
// ends with its loaded interval; a lost interval is fetched again in pages.
export type HistoryGoal = { taskId: string; oldestRunId: string };
export function historyProgress(
  snapshot: WorkbenchSnapshot,
  taskId: string | null,
  goal: HistoryGoal | null,
) {
  const page = snapshot.taskPage;
  if (!page || page.task.id !== taskId)
    return {
      beforeRunId: null,
      nextBeforeRunId: null,
      loading: taskId !== null,
    };
  const task = snapshot.tasks.find((entry) => entry.id === taskId)!;
  const first = page.runManifest.findIndex(
    (run) => run.id === task.runs[0]?.id,
  );
  const target =
    goal?.taskId === taskId
      ? page.runManifest.findIndex((run) => run.id === goal.oldestRunId)
      : -1;
  const needsPage = first > 0 && target >= 0 && first > target;
  const cursor = first > 0 ? task.runs[0]!.id : null;
  return {
    beforeRunId: needsPage ? cursor : null,
    nextBeforeRunId: cursor,
    loading: needsPage,
  };
}
export function earlierHistoryGoal(
  snapshot: WorkbenchSnapshot,
  taskId: string,
  beforeRunId: string,
): HistoryGoal | null {
  const page = snapshot.taskPage;
  if (!page || page.task.id !== taskId) return null;
  const end = page.runManifest.findIndex((run) => run.id === beforeRunId);
  if (end <= 0) return null;
  return {
    taskId,
    oldestRunId:
      page.runManifest[Math.max(0, end - snapshot.scope.runLimit)]!.id,
  };
}
