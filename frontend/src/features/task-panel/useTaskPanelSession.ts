import { useEffect, useReducer } from "react";

import type { TaskView } from "../../bridge/contracts.ts";
import {
  initialTaskPanelSessionState,
  reduceTaskPanelSession,
  type TaskPanelResourceTarget,
  type TaskPanelReviewTarget,
  type TaskPanelTab,
} from "./task-panel-state.ts";

export function useTaskPanelSession(task: TaskView | null) {
  const [state, dispatch] = useReducer(
    reduceTaskPanelSession,
    initialTaskPanelSessionState,
  );
  const taskId = task?.id ?? null;
  const stateBelongsToTask = taskId !== null && state.activeTaskId === taskId;

  useEffect(() => {
    if (!task) {
      dispatch({ type: "task.cleared" });
      return;
    }
    dispatch({
      type: "task.observed",
      taskId: task.id,
    });
  }, [taskId]);

  return {
    activeTab: stateBelongsToTask ? state.activeTab : "overview",
    review: stateBelongsToTask ? state.review : null,
    resource: stateBelongsToTask ? state.resource : null,
    openOverview() {
      if (taskId) dispatch({ type: "overview.opened", taskId });
    },
    close() {
      dispatch({ type: "content.cleared" });
    },
    openReview(target: TaskPanelReviewTarget) {
      dispatch({ type: "review.opened", target });
    },
    closeReview() {
      if (taskId) dispatch({ type: "review.closed", taskId });
    },
    openResource(target: TaskPanelResourceTarget) {
      dispatch({ type: "resource.opened", target });
    },
    closeResource() {
      if (taskId) dispatch({ type: "resource.closed", taskId });
    },
    activate(tab: TaskPanelTab) {
      if (taskId) dispatch({ type: "tab.activated", taskId, tab });
    },
  };
}
