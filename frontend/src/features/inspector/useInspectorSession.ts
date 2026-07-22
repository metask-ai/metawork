import { useEffect, useReducer } from "react";

import type { TaskView } from "../../bridge/contracts.ts";
import {
  inspectorOpenForTask,
  reduceInspectorSession,
  taskHasInspectorFacts,
} from "./inspector-state.ts";

export function useInspectorSession(task: TaskView | null) {
  const [state, dispatch] = useReducer(reduceInspectorSession, {});
  const taskId = task?.id ?? null;
  const available = taskHasInspectorFacts(task);
  const open = available && inspectorOpenForTask(state, taskId);

  useEffect(() => {
    if (!task) return;
    dispatch({
      type: "task.observed",
      taskId: task.id,
      attentionId: task.pendingUi
        ? `${task.pendingUi.runId}:${task.pendingUi.requestId}`
        : null,
    });
  }, [task?.id, task?.pendingUi?.runId, task?.pendingUi?.requestId]);

  return {
    available,
    open,
    show() {
      if (taskId) dispatch({ type: "panel.opened", taskId });
    },
    hide() {
      if (taskId) dispatch({ type: "panel.closed", taskId });
    },
  };
}
