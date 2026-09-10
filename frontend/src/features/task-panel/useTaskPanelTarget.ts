import { useEffect, useState } from "react";
import type { TaskView } from "../../bridge/contracts.ts";
import {
  emptyTaskPanelTarget,
  resolveTaskPanelTarget,
  type TaskPanelTarget,
} from "./task-panel-state.ts";

export function useTaskPanelTarget(
  task: TaskView | null,
  typedFileChanges: boolean,
) {
  const [stored, setTarget] = useState<TaskPanelTarget>(emptyTaskPanelTarget);
  const target = resolveTaskPanelTarget(stored, task, typedFileChanges);
  useEffect(() => {
    setTarget((current) =>
      resolveTaskPanelTarget(current, task, typedFileChanges),
    );
  }, [task, typedFileChanges]);
  return {
    target,
    selectTarget(next: TaskPanelTarget) {
      setTarget(resolveTaskPanelTarget(next, task, typedFileChanges));
    },
    clearTarget() {
      setTarget(emptyTaskPanelTarget);
    },
  };
}
