import type {
  RunView,
  TaskView,
  WorkbenchSnapshot,
  WorkspaceView,
} from "../bridge/contracts.ts";
import { runInputDisplay } from "./run-input.ts";
import type { WorkbenchState } from "./store.ts";

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

export type WorkspaceSummary = {
  id: string;
  canonicalRoot: string;
  label: string;
  authorization: "available" | "removing" | "reauthorization_required";
  lastRemovalFailure: "task_close_failed" | null;
  taskCount: number;
  running: number;
  attention: number;
  failed: number;
};

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

export function sidebarTasks(
  snapshot: WorkbenchSnapshot,
  selectedUserWorkspaceId: string | null,
): TaskView[] {
  const managedWorkspaceIds = new Set(
    snapshot.workspaces
      .filter((workspace) => workspace.origin === "managed")
      .map((workspace) => workspace.id),
  );
  return snapshot.tasks.filter(
    (task) =>
      task.workspaceId === selectedUserWorkspaceId ||
      managedWorkspaceIds.has(task.workspaceId),
  );
}

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
            compact?.phase === "stopping"
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
      compact?.phase === "stopping",
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

export function workspaceLabel(root: string): string {
  const normalized = root.replaceAll("\\", "/").replace(/\/+$/, "");
  return normalized.split("/").filter(Boolean).at(-1) ?? root;
}

export function workspaceDirectoryLabel(
  workspace: Pick<WorkspaceView, "origin" | "canonicalRoot">,
  defaultLabel: string,
): string {
  return workspace.origin === "managed"
    ? defaultLabel
    : workspace.canonicalRoot;
}

export function workspaceSummaries(
  snapshot: WorkbenchSnapshot,
): WorkspaceSummary[] {
  return [...snapshot.workspaces]
    .filter((workspace) => workspace.origin === "user")
    .sort((left, right) => {
      const leftOrder = BigInt(left.recentOrder);
      const rightOrder = BigInt(right.recentOrder);
      return rightOrder > leftOrder ? 1 : rightOrder < leftOrder ? -1 : 0;
    })
    .map((workspace) => ({
      id: workspace.id,
      canonicalRoot: workspace.canonicalRoot,
      label: workspace.displayName || workspaceLabel(workspace.canonicalRoot),
      authorization: workspace.authorization,
      lastRemovalFailure: workspace.lastRemovalFailure,
      taskCount: snapshot.tasks.filter(
        (task) => task.workspaceId === workspace.id && !task.archived,
      ).length,
      running: workspace.signals.running,
      attention: workspace.signals.attention,
      failed: workspace.signals.failedOrInterrupted,
    }));
}

export function selectCurrentWorkspace(state: WorkbenchState): string | null {
  return (
    state.activeWorkspaceId ??
    selectActiveTask(state)?.workspaceId ??
    state.snapshot.selectedWorkspaceId ??
    null
  );
}

export type SearchResult = {
  key: string;
  kind: "workspace" | "task" | "instruction" | "completion";
  taskId: string | null;
  workspaceId: string;
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
  for (const workspace of snapshot.workspaces.filter(
    (candidate) => candidate.origin === "user",
  )) {
    if (matches(workspace.canonicalRoot) || matches(workspace.displayName))
      results.push({
        key: `workspace:${workspace.id}`,
        kind: "workspace",
        taskId: null,
        workspaceId: workspace.id,
        title: workspace.displayName || workspaceLabel(workspace.canonicalRoot),
        detail: workspace.canonicalRoot,
      });
  }
  for (const task of snapshot.tasks) {
    const workspace = workspaces.get(task.workspaceId);
    if (!workspace) continue;
    const title = task.title;
    if (title && matches(title))
      results.push({
        key: `task:${task.id}`,
        kind: "task",
        taskId: task.id,
        workspaceId: task.workspaceId,
        title,
        detail:
          workspace.origin === "managed"
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
          workspaceId: task.workspaceId,
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
          workspaceId: task.workspaceId,
          title,
          detail: run.assistant,
        });
    }
  }
  return results.slice(0, 50);
}
