import { useEffect, useState } from "react";
import type { FileReferenceView, TaskView } from "../../bridge/contracts.ts";
import {
  activeTaskPanelTab,
  closeTaskPanelTab,
  createTaskPanelPreviewTab,
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
) {
  const [stored, setSession] = useState(emptyTaskPanelSession);
  const session = reconcileTaskPanelSession(stored, task, typedFileChanges);
  const activeTab = activeTaskPanelTab(session);
  useEffect(() => {
    setSession((current) =>
      reconcileTaskPanelSession(current, task, typedFileChanges),
    );
  }, [task, typedFileChanges]);

  function openTab(next: TaskPanelTab | null) {
    if (!next) return;
    setSession((current) =>
      openTaskPanelTab(current, next, task, typedFileChanges),
    );
  }

  return {
    session,
    activeTab,
    target: activeTab ?? emptyTaskPanelTarget,
    openPreview(taskId: string, runId: string, reference: FileReferenceView) {
      openTab(createTaskPanelPreviewTab(taskId, runId, reference));
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
