import type {
  RunView,
  TaskView,
  TaskSummary,
  WorkbenchSnapshot,
  WorkspaceView,
} from "../bridge/contracts.ts";
import type { WorkbenchState } from "./store.ts";
import { navigableTasks } from "./task-visibility.ts";

type TaskNavigation = TaskView | TaskSummary;

export function selectActiveTask(state: WorkbenchState): TaskView | null {
  return (
    state.snapshot.tasks.find((task) => task.id === state.activeTaskId) ?? null
  );
}

export function isRunInFlight(task: TaskView | null): boolean {
  return task?.currentRunPhase != null;
}

export function pendingInputContinuation(
  task: TaskView | null,
): RunView | null {
  const run = task?.runs.at(-1);
  return run?.additionalInputs.some((input) => input.state === "continuing")
    ? run
    : null;
}

function activeCompact(task: TaskNavigation) {
  if (!("compacts" in task))
    return task.activeCompactPhase === null
      ? null
      : { phase: task.activeCompactPhase };
  return task.activeOperation?.kind === "compact"
    ? (task.compacts.find(
        (compact) => compact.operationId === task.activeOperation?.id,
      ) ?? null)
    : null;
}

function permissionReviewInProgress(task: TaskNavigation): boolean {
  return (
    task.currentRunPhase === "waiting_ui" &&
    task.permissionReviewState === "reviewing"
  );
}

export function orderedProjects(workspaces: readonly WorkspaceView[]) {
  return workspaces
    .filter(
      (workspace) => workspace.kind === "manual" && !workspace.projectRemoved,
    )
    .sort((left, right) => {
      const leftOrder = BigInt(left.recentOrder);
      const rightOrder = BigInt(right.recentOrder);
      return rightOrder > leftOrder ? 1 : rightOrder < leftOrder ? -1 : 0;
    });
}

export function orderedTasks<T extends TaskNavigation>(tasks: T[]): T[] {
  const byRecent = (left: T, right: T) => {
    const leftOrder = BigInt(left.recentOrder);
    const rightOrder = BigInt(right.recentOrder);
    if (rightOrder !== leftOrder) return rightOrder > leftOrder ? 1 : -1;
    const leftId = BigInt(left.id);
    const rightId = BigInt(right.id);
    return leftId < rightId ? -1 : leftId > rightId ? 1 : 0;
  };
  const priority = (task: T) => {
    if (
      task.currentRunPhase === "waiting_ui" &&
      !permissionReviewInProgress(task)
    )
      return 0;
    const compact = activeCompact(task);
    if (
      task.currentRunPhase === "running" ||
      task.currentRunPhase === "stopping" ||
      permissionReviewInProgress(task) ||
      compact?.phase === "compacting" ||
      compact?.phase === "stopping" ||
      task.activeOperation?.kind === "restore"
    )
      return 1;
    if (task.currentRunPhase === "queued" || compact?.phase === "queued")
      return 2;
    return 3;
  };

  return tasks
    .filter((task) => !task.archived)
    .sort(
      (left, right) =>
        priority(left) - priority(right) || byRecent(left, right),
    );
}

export type TaskDisplayState =
  | { kind: "permission_review" }
  | {
      kind: "phase";
      value: NonNullable<TaskView["currentRunPhase"]>;
    }
  | { kind: "lifecycle"; value: Exclude<TaskView["lifecycle"], "open"> }
  | { kind: "compact_phase"; value: "queued" | "compacting" | "stopping" }
  | { kind: "recovery" }
  | { kind: "archived" }
  | {
      kind: "outcome";
      value: NonNullable<RunView["terminal"]>["outcome"];
    }
  | { kind: "ready" };

export function lastTerminalRun(task: TaskView): RunView | null {
  for (let index = task.runs.length - 1; index >= 0; index -= 1) {
    const run = task.runs[index]!;
    if (run.terminal) return run;
  }
  return null;
}

export function taskDisplayState(task: TaskNavigation): TaskDisplayState {
  if (permissionReviewInProgress(task)) return { kind: "permission_review" };
  if (task.currentRunPhase)
    return { kind: "phase", value: task.currentRunPhase };
  const compact = activeCompact(task);
  if (
    compact?.phase === "queued" ||
    compact?.phase === "compacting" ||
    compact?.phase === "stopping"
  )
    return { kind: "compact_phase", value: compact.phase };
  if (task.activeOperation?.kind === "restore") return { kind: "recovery" };
  if (task.lifecycle !== "open")
    return { kind: "lifecycle", value: task.lifecycle };
  if (task.archived) return { kind: "archived" };
  const terminal =
    "runs" in task ? lastTerminalRun(task)?.terminal : task.latestTerminal;
  if (terminal) return { kind: "outcome", value: terminal.outcome };
  return { kind: "ready" };
}

export type SearchResult = {
  key: string;
  kind: "task" | "instruction" | "completion";
  archived: boolean;
  taskId: string;
  title: string;
  detail: string;
};

export function searchWorkbench(
  snapshot: WorkbenchSnapshot,
  query: string,
): SearchResult[] {
  if (
    !query.trim() ||
    !snapshot.scope.search ||
    snapshot.scope.searchQuery !== query.trim() ||
    snapshot.searchIndex?.stale
  )
    return [];
  return (snapshot.searchIndex?.results ?? []).flatMap((hit) => {
    const task = snapshot.taskIndex.find((task) => task.id === hit.taskId);
    if (!task) return [];
    return [
      {
        key: `${hit.kind}:${hit.taskId}:${hit.runId ?? "title"}:${hit.part}`,
        kind: hit.kind,
        taskId: hit.taskId,
        archived: task.archived,
        title: task.title,
        detail: hit.detail,
      },
    ];
  });
}

export function boundedSearchQuery(query: string): string {
  let result = "";
  let bytes = 0;
  const encoder = new TextEncoder();
  for (const codepoint of query) {
    const size = encoder.encode(codepoint).length;
    if (bytes + size > 256) break;
    result += codepoint;
    bytes += size;
  }
  return result;
}
