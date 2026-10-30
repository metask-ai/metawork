import { useEffect, useState } from "react";
import type {
  FileReferenceView,
  TaskView,
  RunManifest,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import {
  activeTaskPanelTab,
  closeTaskPanelTab,
  createTaskPanelPreviewTab,
  createTaskPanelWorkspaceTab,
  createTaskPanelReviewTab,
  emptyTaskPanelSession,
  emptyTaskPanelTarget,
  openTaskPanelTab,
  reconcileTaskPanelSession,
  selectTaskPanelTab,
  targetToTaskPanelTab,
  type TaskPanelTab,
  type TaskPanelTarget,
} from "./task-panel-state.ts";

export function useTaskPanelTarget(
  task: TaskView | null,
  typedFileChanges: boolean,
  manifest?: readonly RunManifest[],
  workspace: WorkspaceView | null = null,
) {
  const [stored, setSession] = useState(emptyTaskPanelSession);
  function authorized(current: typeof stored) {
    const tabs = current.tabs.filter(
      (tab) =>
        tab.kind !== "workspace" ||
        (task?.lifecycle === "open" &&
          task.deletionStatus === "idle" &&
          workspace?.authorization === "available" &&
          !workspace.redacted &&
          tab.workspaceId === workspace.id &&
          tab.workspaceEpoch === workspace.epoch),
    );
    return tabs.length === current.tabs.length ? current : { ...current, tabs };
  }
  const session = reconcileTaskPanelSession(
    authorized(stored),
    task,
    typedFileChanges,
    manifest,
  );
  const activeTab = activeTaskPanelTab(session);
  useEffect(() => {
    setSession((current) =>
      reconcileTaskPanelSession(
        authorized(current),
        task,
        typedFileChanges,
        manifest,
      ),
    );
  }, [task, typedFileChanges, manifest, workspace]);

  function openTab(next: TaskPanelTab | null) {
    if (!next) return;
    if (
      next.kind === "workspace" &&
      (task?.lifecycle !== "open" ||
        task.deletionStatus !== "idle" ||
        workspace?.authorization !== "available" ||
        workspace.redacted ||
        next.workspaceId !== workspace.id ||
        next.workspaceEpoch !== workspace.epoch)
    )
      return;
    setSession((current) =>
      openTaskPanelTab(current, next, task, typedFileChanges, manifest),
    );
  }

  return {
    session,
    activeTab,
    waitingForRun: Boolean(
      activeTab &&
      activeTab.kind !== "workspace" &&
      !task?.runs.some((run) => run.id === activeTab.runId),
    ),
    target: activeTab ?? emptyTaskPanelTarget,
    openPreview(taskId: string, runId: string, reference: FileReferenceView) {
      openTab(createTaskPanelPreviewTab(taskId, runId, reference));
    },
    openWorkspace(
      taskId: string,
      workspaceId: string,
      workspaceEpoch: string,
      path: string,
    ) {
      openTab(
        createTaskPanelWorkspaceTab(taskId, workspaceId, workspaceEpoch, path),
      );
    },
    openReview(taskId: string, runId: string) {
      openTab(createTaskPanelReviewTab(taskId, runId));
    },
    selectTab(tabId: string) {
      setSession((current) => selectTaskPanelTab(current, tabId));
    },
    closeTab(tabId: string) {
      setSession((current) => closeTaskPanelTab(current, tabId));
    },
    selectTarget(next: TaskPanelTarget) {
      if (next.kind === "empty") {
        setSession(emptyTaskPanelSession);
        return;
      }
      openTab(targetToTaskPanelTab(next, task));
    },
    clearTarget() {
      setSession(emptyTaskPanelSession);
    },
  };
}
