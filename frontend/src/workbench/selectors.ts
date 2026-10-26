import type {
  RunView,
  TaskView,
  TaskSummary,
  WorkbenchSnapshot,
  WorkspaceView,
} from "../bridge/contracts.ts";
import { runInputDisplay } from "./run-input.ts";
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

export type TaskSignals = {
  running: boolean;
  attention: boolean;
  failed: boolean;
};

function permissionReviewInProgress(task: TaskNavigation): boolean {
  return (
    task.currentRunPhase === "waiting_ui" &&
    task.permissionReviewState === "reviewing"
  );
}

export function orderedTasks<T extends TaskNavigation>(tasks: T[]): T[] {
  const byRecent = (left: T, right: T) => {
    const leftOrder = BigInt(left.recentOrder);
    const rightOrder = BigInt(right.recentOrder);
    return rightOrder > leftOrder ? 1 : rightOrder < leftOrder ? -1 : 0;
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

export function taskSignals(task: TaskNavigation): TaskSignals {
  const compact = activeCompact(task);
  const lastCompact =
    "compacts" in task
      ? task.compacts.at(-1)
      : task.lastCompactPhase === null
        ? null
        : { phase: task.lastCompactPhase };
  const terminal =
    "runs" in task
      ? (lastTerminalRun(task)?.terminal ?? null)
      : task.latestTerminal;
  return {
    running:
      task.currentRunPhase === "queued" ||
      task.currentRunPhase === "running" ||
      task.currentRunPhase === "stopping" ||
      permissionReviewInProgress(task) ||
      compact?.phase === "queued" ||
      compact?.phase === "compacting" ||
      compact?.phase === "stopping" ||
      task.activeOperation?.kind === "restore",
    attention:
      task.currentRunPhase === "waiting_ui" &&
      !permissionReviewInProgress(task),
    failed:
      task.deletionStatus === "failed" ||
      terminal?.outcome === "failed" ||
      terminal?.outcome === "dependency_contract_failure" ||
      terminal?.outcome === "interrupted" ||
      (terminal?.cause != null &&
        terminal.cause !== "user_cancel" &&
        terminal.cause !== "session_close") ||
      lastCompact?.phase === "failed",
  };
}

export function workspaceDirectoryLabel(
  workspace: Pick<WorkspaceView, "kind" | "canonicalRoot">,
  defaultLabel: string,
): string {
  return workspace.kind === "automatic"
    ? defaultLabel
    : workspace.canonicalRoot;
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
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return [];
  const results: SearchResult[] = [];
  const matches = (value: string) => value.toLocaleLowerCase().includes(needle);
  const workspaces = new Map(
    snapshot.workspaces.map((workspace) => [workspace.id, workspace]),
  );
  for (const task of navigableTasks(snapshot)) {
    const workspace = workspaces.get(task.workspaceId);
    if (!workspace) continue;
    const title = task.title;
    if (title && matches(title))
      results.push({
        key: `task:${task.id}`,
        kind: "task",
        taskId: task.id,
        archived: task.archived,
        title,
        detail:
          workspace.kind === "automatic"
            ? workspace.displayName
            : workspace.canonicalRoot,
      });
    for (const run of snapshot.searchIndex?.filter(
      (run) => run.taskId === task.id,
    ) ?? []) {
      const input = runInputDisplay(run.input);
      const output = run.output
        ? `${run.output.commentary.join("\n\n")}\n\n${run.output.response}`
        : "";
      if (matches(input))
        results.push({
          key: `instruction:${task.id}:${run.runId}`,
          kind: "instruction",
          taskId: task.id,
          archived: task.archived,
          title,
          detail: input,
        });
      if (run.output !== null && output && matches(output))
        results.push({
          key: `completion:${task.id}:${run.runId}`,
          kind: "completion",
          taskId: task.id,
          archived: task.archived,
          title,
          detail: output,
        });
    }
  }
  return results.slice(0, 50);
}
