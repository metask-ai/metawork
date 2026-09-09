export type TaskPanelTab = "overview" | "review" | "resource";

export type TaskOverviewSection =
  "attention" | "summary" | "work_process" | "usage";

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

export type TaskPanelSessionState = {
  activeTaskId: string | null;
  activeTab: TaskPanelTab;
  review: TaskPanelReviewTarget | null;
  resource: TaskPanelResourceTarget | null;
};

export type TaskPanelSessionAction =
  | {
      type: "task.observed";
      taskId: string;
    }
  | { type: "task.cleared" }
  | { type: "overview.opened"; taskId: string }
  | { type: "content.cleared" }
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
};

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
    if (state.activeTaskId === action.taskId) return state;
    return {
      ...initialTaskPanelSessionState,
      activeTaskId: action.taskId,
    };
  }

  if (action.type === "content.cleared") {
    return {
      ...initialTaskPanelSessionState,
      activeTaskId: state.activeTaskId,
    };
  }

  const taskId =
    action.type === "review.opened" || action.type === "resource.opened"
      ? action.target.taskId
      : action.taskId;

  if (action.type === "overview.opened") {
    return {
      ...state,
      activeTaskId: taskId,
      activeTab: "overview",
    };
  }

  if (action.type === "review.opened") {
    return {
      ...state,
      activeTaskId: taskId,
      activeTab: "review",
      review: action.target,
      resource: null,
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
