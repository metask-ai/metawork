import type {
  FileReferenceView,
  TaskView,
  RunManifest,
} from "../../bridge/contracts.ts";
import { findRunFileReference } from "../../workbench/run-file-references.ts";

type RunTarget = { taskId: string; runId: string };

export type TaskPanelTarget =
  | { kind: "empty" }
  | (RunTarget & { kind: "preview"; referenceId: string })
  | (RunTarget & { kind: "review" });

export type TaskPanelPreviewTab = RunTarget & {
  kind: "preview";
  tabId: string;
  referenceId: string;
  title: string;
  displayPath: string;
};

export type TaskPanelReviewTab = RunTarget & {
  kind: "review";
  tabId: string;
};

export type TaskPanelTab = TaskPanelPreviewTab | TaskPanelReviewTab;

export type TaskPanelSession = {
  taskId: string | null;
  tabs: TaskPanelTab[];
  activeTabId: string | null;
};

export const emptyTaskPanelTarget: TaskPanelTarget = { kind: "empty" };
export const emptyTaskPanelSession: TaskPanelSession = {
  taskId: null,
  tabs: [],
  activeTabId: null,
};

function tabId(parts: string[]): string {
  return JSON.stringify(parts);
}

export function createTaskPanelPreviewTab(
  taskId: string,
  runId: string,
  reference: FileReferenceView,
): TaskPanelPreviewTab {
  return {
    kind: "preview",
    tabId: tabId(["preview", taskId, runId, reference.id]),
    taskId,
    runId,
    referenceId: reference.id,
    title: reference.title,
    displayPath: reference.displayPath,
  };
}

export function createTaskPanelReviewTab(
  taskId: string,
  runId: string,
): TaskPanelReviewTab {
  return {
    kind: "review",
    tabId: tabId(["review", taskId]),
    taskId,
    runId,
  };
}

export function taskPanelTabTarget(tab: TaskPanelTab): TaskPanelTarget {
  return tab.kind === "preview"
    ? {
        kind: "preview",
        taskId: tab.taskId,
        runId: tab.runId,
        referenceId: tab.referenceId,
      }
    : { kind: "review", taskId: tab.taskId, runId: tab.runId };
}

export function activeTaskPanelTab(
  session: TaskPanelSession,
): TaskPanelTab | null {
  return session.tabs.find((tab) => tab.tabId === session.activeTabId) ?? null;
}

function resolveTaskPanelTab(
  tab: TaskPanelTab,
  task: TaskView | null,
  typedFileChanges: boolean,
  manifest?: readonly RunManifest[],
): TaskPanelTab | null {
  if (!task || tab.taskId !== task.id) return null;
  const run = task.runs.find((candidate) => candidate.id === tab.runId);
  if (tab.kind === "review" && !typedFileChanges) return null;
  if (!run)
    return manifest?.some((entry) => entry.id === tab.runId) ? tab : null;
  if (tab.kind === "preview") {
    const reference = findRunFileReference(run, tab.referenceId);
    return reference
      ? createTaskPanelPreviewTab(task.id, run.id, reference)
      : null;
  }
  if (!typedFileChanges || !run.fileChanges?.changes.length) return null;
  return createTaskPanelReviewTab(task.id, run.id);
}

function sameTaskPanelTab(left: TaskPanelTab, right: TaskPanelTab): boolean {
  return (
    left.kind === right.kind &&
    left.tabId === right.tabId &&
    left.taskId === right.taskId &&
    left.runId === right.runId &&
    (left.kind === "review" ||
      (right.kind === "preview" &&
        left.referenceId === right.referenceId &&
        left.title === right.title &&
        left.displayPath === right.displayPath))
  );
}

// Gate the render itself: an effect alone would briefly paint stale details.
export function reconcileTaskPanelSession(
  session: TaskPanelSession,
  task: TaskView | null,
  typedFileChanges: boolean,
  manifest?: readonly RunManifest[],
): TaskPanelSession {
  if (!task || session.taskId !== task.id) return emptyTaskPanelSession;

  const resolved = new Map<string, TaskPanelTab>();
  for (const tab of session.tabs) {
    const next = resolveTaskPanelTab(tab, task, typedFileChanges, manifest);
    if (next) resolved.set(tab.tabId, next);
  }
  const tabs = session.tabs.flatMap((tab) => {
    const next = resolved.get(tab.tabId);
    return next ? [next] : [];
  });
  if (tabs.length === 0)
    return session.tabs.length === 0 && session.activeTabId === null
      ? session
      : { taskId: task.id, tabs: [], activeTabId: null };
  if (session.activeTabId && resolved.has(session.activeTabId)) {
    const unchanged =
      tabs.length === session.tabs.length &&
      tabs.every((tab, index) => sameTaskPanelTab(tab, session.tabs[index]!));
    return unchanged
      ? session
      : { taskId: task.id, tabs, activeTabId: session.activeTabId };
  }

  const removedIndex = session.tabs.findIndex(
    (tab) => tab.tabId === session.activeTabId,
  );
  const candidates = [
    ...session.tabs.slice(Math.max(removedIndex + 1, 0)),
    ...session.tabs.slice(0, Math.max(removedIndex, 0)).reverse(),
  ];
  const fallback = candidates.find((tab) => resolved.has(tab.tabId));
  return {
    taskId: task.id,
    tabs,
    activeTabId: fallback?.tabId ?? tabs[0]!.tabId,
  };
}

export function openTaskPanelTab(
  session: TaskPanelSession,
  next: TaskPanelTab,
  task: TaskView | null,
  typedFileChanges: boolean,
  manifest?: readonly RunManifest[],
): TaskPanelSession {
  const resolved = resolveTaskPanelTab(next, task, typedFileChanges);
  if (!resolved)
    return reconcileTaskPanelSession(session, task, typedFileChanges, manifest);
  const current =
    session.taskId === resolved.taskId
      ? reconcileTaskPanelSession(session, task, typedFileChanges, manifest)
      : { taskId: resolved.taskId, tabs: [], activeTabId: null };
  const existingIndex =
    resolved.kind === "review"
      ? current.tabs.findIndex((tab) => tab.kind === "review")
      : current.tabs.findIndex((tab) => tab.tabId === resolved.tabId);
  if (existingIndex < 0)
    return {
      taskId: resolved.taskId,
      tabs: [...current.tabs, resolved],
      activeTabId: resolved.tabId,
    };
  const existing = current.tabs[existingIndex]!;
  const tabs = [...current.tabs];
  tabs[existingIndex] =
    resolved.kind === "review"
      ? { ...resolved, tabId: existing.tabId }
      : resolved;
  return { taskId: resolved.taskId, tabs, activeTabId: existing.tabId };
}

export function selectTaskPanelTab(
  session: TaskPanelSession,
  nextTabId: string,
): TaskPanelSession {
  return session.tabs.some((tab) => tab.tabId === nextTabId)
    ? { ...session, activeTabId: nextTabId }
    : session;
}

export function closeTaskPanelTab(
  session: TaskPanelSession,
  closedTabId: string,
): TaskPanelSession {
  const index = session.tabs.findIndex((tab) => tab.tabId === closedTabId);
  if (index < 0) return session;
  const tabs = session.tabs.filter((tab) => tab.tabId !== closedTabId);
  if (session.activeTabId !== closedTabId) return { ...session, tabs };
  return {
    ...session,
    tabs,
    activeTabId: tabs[index]?.tabId ?? tabs[index - 1]?.tabId ?? null,
  };
}

export function targetToTaskPanelTab(
  target: Exclude<TaskPanelTarget, { kind: "empty" }>,
  task: TaskView | null,
): TaskPanelTab | null {
  if (!task || task.id !== target.taskId) return null;
  const run = task.runs.find((candidate) => candidate.id === target.runId);
  if (!run) return null;
  if (target.kind === "review")
    return createTaskPanelReviewTab(target.taskId, target.runId);
  const reference = findRunFileReference(run, target.referenceId);
  return reference
    ? createTaskPanelPreviewTab(target.taskId, target.runId, reference)
    : null;
}

export function resolveTaskPanelTarget(
  target: TaskPanelTarget,
  task: TaskView | null,
  typedFileChanges: boolean,
): TaskPanelTarget {
  if (target.kind === "empty") return target;
  const tab = targetToTaskPanelTab(target, task);
  return tab && resolveTaskPanelTab(tab, task, typedFileChanges)
    ? target
    : emptyTaskPanelTarget;
}
