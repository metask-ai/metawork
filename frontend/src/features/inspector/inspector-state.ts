import type { TaskView } from "../../bridge/contracts.ts";

export type InspectorSection = "attention" | "summary" | "tools" | "usage";

type TaskInspectorMemory = {
  open: boolean;
  handledAttentionIds: Readonly<Record<string, true>>;
};

export type InspectorSessionState = Record<string, TaskInspectorMemory>;

export type InspectorSessionAction =
  | {
      type: "task.observed";
      taskId: string;
      attentionId: string | null;
    }
  | { type: "panel.opened"; taskId: string }
  | { type: "panel.closed"; taskId: string };

const emptyMemory: TaskInspectorMemory = {
  open: false,
  handledAttentionIds: {},
};

export function taskHasInspectorFacts(task: TaskView | null): boolean {
  return Boolean(task && (task.pendingUi !== null || task.runs.length > 0));
}

export function inspectorOpenForTask(
  state: InspectorSessionState,
  taskId: string | null,
): boolean {
  return taskId !== null && Boolean(state[taskId]?.open);
}

export function reduceInspectorSession(
  state: InspectorSessionState,
  action: InspectorSessionAction,
): InspectorSessionState {
  const current = state[action.taskId] ?? emptyMemory;
  if (action.type === "task.observed") {
    if (
      action.attentionId === null ||
      current.handledAttentionIds[action.attentionId] === true
    )
      return state;
    return {
      ...state,
      [action.taskId]: {
        open: true,
        handledAttentionIds: {
          ...current.handledAttentionIds,
          [action.attentionId]: true,
        },
      },
    };
  }
  const open = action.type === "panel.opened";
  if (open === current.open) return state;
  return {
    ...state,
    [action.taskId]: { ...current, open },
  };
}
