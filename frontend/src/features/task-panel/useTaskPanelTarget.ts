import { useEffect, useState } from "react";
import type { TaskView } from "../../bridge/contracts.ts";
import {
  emptyTaskPanelTarget,
  resolveTaskPanelTarget,
  type TaskPanelTarget,
} from "./task-panel-state.ts";

export function useTaskPanelTarget(task: TaskView | null) {
  const [stored, setTarget] = useState<TaskPanelTarget>(emptyTaskPanelTarget);
  const target = resolveTaskPanelTarget(stored, task);
  useEffect(() => {
    setTarget((current) => resolveTaskPanelTarget(current, task));
  }, [task]);
  return {
    target,
    selectTarget(next: TaskPanelTarget) {
      setTarget(resolveTaskPanelTarget(next, task));
    },
    clearTarget() {
      setTarget(emptyTaskPanelTarget);
    },
  };
}
