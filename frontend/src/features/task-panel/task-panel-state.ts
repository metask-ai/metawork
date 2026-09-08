import type { TaskView } from "../../bridge/contracts.ts";

export type TaskPanelTab = "overview" | "review" | "resource";

export type TaskOverviewSection =
  "attention" | "summary" | "diagnostics" | "work_process" | "usage";

export type TaskPanelReviewTarget = {
  taskId: string;
  runId: string;
};

type TaskPanelResourceBase = {
  taskId: string;
  runId: string;
  displayPath: string;
  returnTab: "overview" | "review";
};

export type TaskPanelResourceTarget =
  | (TaskPanelResourceBase & {
      kind: "preview";
      resourceId: string;
    })
  | (TaskPanelResourceBase & {
      kind: "diff";
      resourceId: string;
    });

type TaskPanelMemory = {
  open: boolean;
  handledAttentionIds: Readonly<Record<string, true>>;
};

export type TaskPanelSessionState = {
  activeTaskId: string | null;
  activeTab: TaskPanelTab;
  review: TaskPanelReviewTarget | null;
  resource: TaskPanelResourceTarget | null;
  tasks: Record<string, TaskPanelMemory>;
};

export type TaskPanelSessionAction =
  | {
      type: "task.observed";
      taskId: string;
      attentionId: string | null;
    }
  | { type: "task.cleared" }
  | { type: "overview.opened"; taskId: string }
  | { type: "panel.closed"; taskId: string }
  | { type: "review.opened"; target: TaskPanelReviewTarget }
  | { type: "review.closed"; taskId: string }
  | { type: "resource.opened"; target: TaskPanelResourceTarget }
  | { type: "resource.closed"; taskId: string }
  | { type: "tab.activated"; taskId: string; tab: TaskPanelTab };

export const initialTaskPanelSessionState: TaskPanelSessionState = {
  activeTaskId: null,
  activeTab: "overview",
  review: null,
  resource: null,
  tasks: {},
};

const emptyMemory: TaskPanelMemory = {
  open: false,
  handledAttentionIds: {},
};

export function taskHasPanelFacts(task: TaskView | null): boolean {
  return Boolean(task && (task.pendingUi !== null || task.runs.length > 0));
}

export function taskPanelOpenForTask(
  state: TaskPanelSessionState,
  taskId: string | null,
): boolean {
  return taskId !== null && Boolean(state.tasks[taskId]?.open);
}

function targetsSameRun(
  left: { taskId: string; runId: string },
  right: { taskId: string; runId: string },
) {
  return left.taskId === right.taskId && left.runId === right.runId;
}

export function reduceTaskPanelSession(
  state: TaskPanelSessionState,
  action: TaskPanelSessionAction,
): TaskPanelSessionState {
  if (action.type === "task.cleared") {
    if (state.activeTaskId === null) return state;
    return {
      ...state,
      activeTaskId: null,
      activeTab: "overview",
      review: null,
      resource: null,
    };
  }

  if (action.type === "task.observed") {
    const current = state.tasks[action.taskId] ?? emptyMemory;
    const attentionIsNew =
      action.attentionId !== null &&
      current.handledAttentionIds[action.attentionId] !== true;
    const taskChanged = state.activeTaskId !== action.taskId;
    const nextMemory = attentionIsNew
      ? {
          open: true,
          handledAttentionIds: {
            ...current.handledAttentionIds,
            [action.attentionId as string]: true as const,
          },
        }
      : current;

    if (!taskChanged && !attentionIsNew) return state;
    return {
      ...state,
      activeTaskId: action.taskId,
      activeTab: taskChanged ? "overview" : state.activeTab,
      review: taskChanged ? null : state.review,
      resource: taskChanged ? null : state.resource,
      tasks:
        nextMemory === current
          ? state.tasks
          : { ...state.tasks, [action.taskId]: nextMemory },
    };
  }

  const taskId =
    action.type === "review.opened" || action.type === "resource.opened"
      ? action.target.taskId
      : action.taskId;
  const current = state.tasks[taskId] ?? emptyMemory;

  if (action.type === "panel.closed") {
    return {
      ...state,
      activeTab: "overview",
      review: null,
      resource: null,
      tasks: { ...state.tasks, [taskId]: { ...current, open: false } },
    };
  }

  if (action.type === "overview.opened") {
    return {
      ...state,
      activeTaskId: taskId,
      activeTab: "overview",
      tasks: { ...state.tasks, [taskId]: { ...current, open: true } },
    };
  }

  if (action.type === "review.opened") {
    return {
      ...state,
      activeTaskId: taskId,
      activeTab: "review",
      review: action.target,
      resource: null,
      tasks: { ...state.tasks, [taskId]: { ...current, open: true } },
    };
  }

  if (action.type === "resource.opened") {
    const review =
      state.review && targetsSameRun(state.review, action.target)
        ? state.review
        : null;
    const target =
      action.target.returnTab === "review" && review === null
        ? { ...action.target, returnTab: "overview" as const }
        : action.target;
    return {
      ...state,
      activeTaskId: taskId,
      activeTab: "resource",
      review,
      resource: target,
      tasks: { ...state.tasks, [taskId]: { ...current, open: true } },
    };
  }

  if (action.type === "review.closed") {
    const resource = state.resource?.kind === "diff" ? null : state.resource;
    return {
      ...state,
      activeTab:
        state.activeTab === "review" || resource === null
          ? "overview"
          : state.activeTab,
      review: null,
      resource,
    };
  }

  if (action.type === "resource.closed") {
    const returnToReview =
      state.resource?.returnTab === "review" && state.review !== null;
    return {
      ...state,
      activeTab: returnToReview ? "review" : "overview",
      resource: null,
    };
  }

  if (action.tab === "review" && state.review === null) return state;
  if (action.tab === "resource" && state.resource === null) return state;
  return { ...state, activeTab: action.tab };
}
