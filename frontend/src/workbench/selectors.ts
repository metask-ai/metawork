import type {
  RunView,
  TaskView,
  WorkbenchSnapshot,
  WorkspaceView,
} from "../bridge/contracts.ts";
import { runInputDisplay } from "./run-input.ts";
import type { WorkbenchState } from "./store.ts";
import { navigableTasks } from "./task-visibility.ts";

export function selectActiveTask(state: WorkbenchState): TaskView | null {
  return (
    state.snapshot.tasks.find((task) => task.id === state.activeTaskId) ?? null
  );
}

export function isRunInFlight(task: TaskView | null): boolean {
  return task?.currentRunPhase != null;
}

function activeCompact(task: TaskView) {
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

export type TaskGroupKind =
  "attention" | "running" | "queued" | "recent" | "archived";

export type TaskGroup = {
  kind: TaskGroupKind;
  tasks: TaskView[];
};

export function taskGroups(
  tasks: TaskView[],
  showArchived: boolean,
): TaskGroup[] {
  const byRecent = (left: TaskView, right: TaskView) => {
    const leftOrder = BigInt(left.recentOrder);
    const rightOrder = BigInt(right.recentOrder);
    return rightOrder > leftOrder ? 1 : rightOrder < leftOrder ? -1 : 0;
  };
  const active = tasks.filter((task) => !task.archived);
  const orderedGroups: TaskGroup[] = [
    {
      kind: "attention",
      tasks: active
        .filter((task) => task.currentRunPhase === "waiting_ui")
        .sort(byRecent),
    },
    {
      kind: "running",
      tasks: active
        .filter((task) => {
          const compact = activeCompact(task);
          return (
            task.currentRunPhase === "running" ||
            task.currentRunPhase === "stopping" ||
            compact?.phase === "compacting" ||
            compact?.phase === "stopping" ||
            task.activeOperation?.kind === "restore"
          );
        })
        .sort(byRecent),
    },
    {
      kind: "queued",
      tasks: active
        .filter(
          (task) =>
            task.currentRunPhase === "queued" ||
            activeCompact(task)?.phase === "queued",
        )
        .sort(byRecent),
    },
    {
      kind: "recent",
      tasks: active
        .filter(
          (task) =>
            task.currentRunPhase === null && task.activeOperation == null,
        )
        .sort(byRecent),
    },
  ];
  const groups = orderedGroups.filter((group) => group.tasks.length > 0);
  if (showArchived) {
    const archived = tasks.filter((task) => task.archived).sort(byRecent);
    if (archived.length > 0) groups.push({ kind: "archived", tasks: archived });
  }
  return groups;
}

export type TaskDisplayState =
  | {
      kind: "phase";
      value: NonNullable<TaskView["currentRunPhase"]>;
    }
  | { kind: "lifecycle"; value: Exclude<TaskView["lifecycle"], "open"> }
  | { kind: "compact_phase"; value: "queued" | "compacting" | "stopping" }
  | { kind: "recovery" }
  | { kind: "archived" }
  | { kind: "outcome"; value: NonNullable<TaskView["lastRunOutcome"]> }
  | { kind: "ready" };

export function taskDisplayState(task: TaskView): TaskDisplayState {
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
  if (task.lastRunOutcome)
    return { kind: "outcome", value: task.lastRunOutcome };
  return { kind: "ready" };
}

export function taskSignals(task: TaskView): TaskSignals {
  const compact = activeCompact(task);
  const lastCompact = task.compacts.at(-1);
  return {
    running:
      task.currentRunPhase === "queued" ||
      task.currentRunPhase === "running" ||
      task.currentRunPhase === "stopping" ||
      compact?.phase === "queued" ||
      compact?.phase === "compacting" ||
      compact?.phase === "stopping" ||
      task.activeOperation?.kind === "restore",
    attention: task.currentRunPhase === "waiting_ui",
    failed:
      task.lastRunOutcome === "failed" ||
      task.lastRunOutcome === "dependency_contract_failure" ||
      task.lastRunOutcome === "interrupted" ||
      (task.cause !== null &&
        task.cause !== "user_cancel" &&
        task.cause !== "session_close") ||
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
        title,
        detail:
          workspace.kind === "automatic"
            ? workspace.displayName
            : workspace.canonicalRoot,
      });
    for (const run of task.runs) {
      const input = runInputDisplay(run.input);
      if (matches(input))
        results.push({
          key: `instruction:${task.id}:${run.id}`,
          kind: "instruction",
          taskId: task.id,
          title,
          detail: input,
        });
      if (
        run.outcome === "completed" &&
        run.assistant &&
        matches(run.assistant)
      )
        results.push({
          key: `completion:${task.id}:${run.id}`,
          kind: "completion",
          taskId: task.id,
          title,
          detail: run.assistant,
        });
    }
  }
  return results.slice(0, 50);
}
