import type { SessionView, WorkbenchSnapshot } from "../host/contracts.ts";
import type { WorkbenchState } from "./store.ts";

export function selectActiveSession(state: WorkbenchState): SessionView | null {
  return (
    state.snapshot.sessions.find(
      (session) => session.id === state.activeSessionId,
    ) ?? null
  );
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

export function taskSignals(session: SessionView): TaskSignals {
  return {
    running:
      session.currentRunPhase === "queued" ||
      session.currentRunPhase === "running" ||
      session.currentRunPhase === "stopping",
    attention: session.currentRunPhase === "waiting_ui",
    failed:
      session.lastRunOutcome === "failed" ||
      session.lastRunOutcome === "dependency_contract_failure" ||
      session.lastRunOutcome === "interrupted" ||
      (session.cause !== null &&
        session.cause !== "user_cancel" &&
        session.cause !== "session_close"),
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
  for (const session of snapshot.sessions) {
    let summary = summaries.get(session.workspaceRoot);
    if (!summary) {
      summary = {
        root: session.workspaceRoot,
        label: workspaceLabel(session.workspaceRoot),
        taskCount: 0,
        running: 0,
        attention: 0,
        failed: 0,
      };
      summaries.set(session.workspaceRoot, summary);
    }
    if (session.archived) continue;
    const signals = taskSignals(session);
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
    selectActiveSession(state)?.workspaceRoot ??
    state.snapshot.sessions[0]?.workspaceRoot ??
    null
  );
}

export type SearchResult = {
  key: string;
  kind: "workspace" | "task" | "instruction" | "completion";
  sessionId: string | null;
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
  for (const session of snapshot.sessions) {
    if (
      !seenWorkspaces.has(session.workspaceRoot) &&
      (matches(session.workspaceRoot) ||
        matches(workspaceLabel(session.workspaceRoot)))
    ) {
      seenWorkspaces.add(session.workspaceRoot);
      results.push({
        key: `workspace:${session.workspaceRoot}`,
        kind: "workspace",
        sessionId: null,
        workspaceRoot: session.workspaceRoot,
        title: workspaceLabel(session.workspaceRoot),
        detail: session.workspaceRoot,
      });
    }
    const title = session.title;
    if (title && matches(title))
      results.push({
        key: `task:${session.id}`,
        kind: "task",
        sessionId: session.id,
        workspaceRoot: session.workspaceRoot,
        title,
        detail: session.workspaceRoot,
      });
    for (const run of session.runs) {
      if (matches(run.user))
        results.push({
          key: `instruction:${session.id}:${run.id}`,
          kind: "instruction",
          sessionId: session.id,
          workspaceRoot: session.workspaceRoot,
          title,
          detail: run.user,
        });
      if (
        run.outcome === "completed" &&
        run.assistant &&
        matches(run.assistant)
      )
        results.push({
          key: `completion:${session.id}:${run.id}`,
          kind: "completion",
          sessionId: session.id,
          workspaceRoot: session.workspaceRoot,
          title,
          detail: run.assistant,
        });
    }
  }
  return results.slice(0, 50);
}
