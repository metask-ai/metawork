import type {
  RunView,
  TaskView,
  WorkbenchSnapshot,
} from "../bridge/contracts.ts";
import type { WorkbenchState } from "./store.ts";

export function selectActiveTask(state: WorkbenchState): TaskView | null {
  return (
    state.snapshot.tasks.find((task) => task.id === state.activeTaskId) ?? null
  );
}

export function isRunInFlight(task: TaskView | null): boolean {
  return task?.currentRunPhase != null;
}

export type WorkspaceSummary = {
  root: string;
  label: string;
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

export type TaskDisplayState =
  | {
      kind: "phase";
      value: NonNullable<TaskView["currentRunPhase"]>;
    }
  | { kind: "lifecycle"; value: Exclude<TaskView["lifecycle"], "open"> }
  | { kind: "archived" }
  | { kind: "outcome"; value: NonNullable<TaskView["lastRunOutcome"]> }
  | { kind: "ready" };

export function taskDisplayState(task: TaskView): TaskDisplayState {
  if (task.currentRunPhase)
    return { kind: "phase", value: task.currentRunPhase };
  if (task.lifecycle !== "open")
    return { kind: "lifecycle", value: task.lifecycle };
  if (task.archived) return { kind: "archived" };
  if (task.lastRunOutcome)
    return { kind: "outcome", value: task.lastRunOutcome };
  return { kind: "ready" };
}

export function taskSignals(task: TaskView): TaskSignals {
  return {
    running:
      task.currentRunPhase === "queued" ||
      task.currentRunPhase === "running" ||
      task.currentRunPhase === "stopping",
    attention: task.currentRunPhase === "waiting_ui",
    failed:
      task.lastRunOutcome === "failed" ||
      task.lastRunOutcome === "dependency_contract_failure" ||
      task.lastRunOutcome === "interrupted" ||
      (task.cause !== null &&
        task.cause !== "user_cancel" &&
        task.cause !== "session_close"),
  };
}

export function workspaceLabel(root: string): string {
  const normalized = root.replaceAll("\\", "/").replace(/\/+$/, "");
  return normalized.split("/").filter(Boolean).at(-1) ?? root;
}

export function workspaceSummaries(
  snapshot: WorkbenchSnapshot,
): WorkspaceSummary[] {
  const summaries = new Map<string, WorkspaceSummary>();
  for (const task of snapshot.tasks) {
    let summary = summaries.get(task.workspaceRoot);
    if (!summary) {
      summary = {
        root: task.workspaceRoot,
        label: workspaceLabel(task.workspaceRoot),
        taskCount: 0,
        running: 0,
        attention: 0,
        failed: 0,
      };
      summaries.set(task.workspaceRoot, summary);
    }
    if (task.archived) continue;
    const signals = taskSignals(task);
    summary.taskCount += 1;
    if (signals.running) summary.running += 1;
    if (signals.attention) summary.attention += 1;
    if (signals.failed) summary.failed += 1;
  }
  return [...summaries.values()];
}

export function selectCurrentWorkspace(state: WorkbenchState): string | null {
  return (
    state.activeWorkspaceRoot ??
    selectActiveTask(state)?.workspaceRoot ??
    state.snapshot.tasks[0]?.workspaceRoot ??
    null
  );
}

export type TaskActivity = {
  currentRun: RunView | null;
  tokenTotal: bigint;
};

export function taskActivity(task: TaskView | null): TaskActivity {
  if (!task) return { currentRun: null, tokenTotal: 0n };
  let tokenTotal = 0n;
  for (const run of task.runs) {
    try {
      tokenTotal += BigInt(run.usage.input) + BigInt(run.usage.output);
    } catch {
      // Exact decoding already validates wire integers; keep this selector
      // fail-safe for isolated fixtures and future call sites.
    }
  }
  return {
    currentRun: task.runs.find((run) => run.id === task.currentRunId) ?? null,
    tokenTotal,
  };
}

export type SearchResult = {
  key: string;
  kind: "workspace" | "task" | "instruction" | "completion";
  taskId: string | null;
  workspaceRoot: string;
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
  const seenWorkspaces = new Set<string>();
  const matches = (value: string) => value.toLocaleLowerCase().includes(needle);
  for (const task of snapshot.tasks) {
    if (
      !seenWorkspaces.has(task.workspaceRoot) &&
      (matches(task.workspaceRoot) ||
        matches(workspaceLabel(task.workspaceRoot)))
    ) {
      seenWorkspaces.add(task.workspaceRoot);
      results.push({
        key: `workspace:${task.workspaceRoot}`,
        kind: "workspace",
        taskId: null,
        workspaceRoot: task.workspaceRoot,
        title: workspaceLabel(task.workspaceRoot),
        detail: task.workspaceRoot,
      });
    }
    const title = task.title;
    if (title && matches(title))
      results.push({
        key: `task:${task.id}`,
        kind: "task",
        taskId: task.id,
        workspaceRoot: task.workspaceRoot,
        title,
        detail: task.workspaceRoot,
      });
    for (const run of task.runs) {
      if (matches(run.user))
        results.push({
          key: `instruction:${task.id}:${run.id}`,
          kind: "instruction",
          taskId: task.id,
          workspaceRoot: task.workspaceRoot,
          title,
          detail: run.user,
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
          workspaceRoot: task.workspaceRoot,
          title,
          detail: run.assistant,
        });
    }
  }
  return results.slice(0, 50);
}
