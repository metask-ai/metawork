import type { TaskView } from "../../bridge/contracts.ts";
import { findRunFileReference } from "../../workbench/run-file-references.ts";

type RunTarget = { taskId: string; runId: string };
export type TaskPanelTarget =
  | { kind: "empty" }
  | (RunTarget & { kind: "preview"; referenceId: string })
  | (RunTarget & { kind: "review" });

export const emptyTaskPanelTarget: TaskPanelTarget = { kind: "empty" };

// Gate the render itself: an effect alone would briefly paint stale details.
export function resolveTaskPanelTarget(
  target: TaskPanelTarget,
  task: TaskView | null,
  typedFileChanges: boolean,
): TaskPanelTarget {
  if (target.kind === "empty") return target;
  if (!task || target.taskId !== task.id) return emptyTaskPanelTarget;
  const run = task.runs.find((candidate) => candidate.id === target.runId);
  if (!run) return emptyTaskPanelTarget;
  if (target.kind === "preview")
    return findRunFileReference(run, target.referenceId)
      ? target
      : emptyTaskPanelTarget;
  if (!typedFileChanges || !run.fileChanges?.changes.length)
    return emptyTaskPanelTarget;
  return target;
}
