import type { WorkbenchSnapshot } from "../bridge/contracts.ts";

export type WorkbenchState = {
  snapshot: WorkbenchSnapshot;
  activeTaskId: string | null;
  activeWorkspaceRoot: string | null;
  draftOpen: boolean;
  draftWorkspaceRoot: string | null;
};

export type WorkbenchAction =
  | { type: "snapshot.accepted"; snapshot: WorkbenchSnapshot }
  | { type: "task.selected"; taskId: string }
  | { type: "workspace.selected"; workspaceRoot: string }
  | { type: "task.draft.opened"; workspaceRoot: string | null }
  | { type: "task.draft.closed" };

export const initialWorkbenchState: WorkbenchState = {
  snapshot: {
    revision: "0",
    account: {
      sessionState: "restoring",
      executionState: "none",
      operation: "none",
      readiness: "checking",
      primaryAction: "none",
      canCancel: false,
      accountId: "",
      displayName: "",
      apiKeys: [],
      models: [],
      selectedApiKeyId: "",
      selectedModel: "",
      canCreateTask: false,
      errorCode: "none",
      safeDiagnostic: "",
      catalogGeneration: "0",
      executionGeneration: "0",
    },
    tasks: [],
  },
  activeTaskId: null,
  activeWorkspaceRoot: null,
  draftOpen: false,
  draftWorkspaceRoot: null,
};

export function workbenchReducer(
  state: WorkbenchState,
  action: WorkbenchAction,
): WorkbenchState {
  if (action.type === "task.selected") {
    const task = state.snapshot.tasks.find(
      (candidate) => candidate.id === action.taskId,
    );
    if (!task) return state;
    return {
      ...state,
      activeTaskId: action.taskId,
      activeWorkspaceRoot: task.workspaceRoot,
      draftOpen: false,
      draftWorkspaceRoot: null,
    };
  }
  if (action.type === "task.draft.opened")
    return {
      ...state,
      activeTaskId: null,
      activeWorkspaceRoot: action.workspaceRoot ?? state.activeWorkspaceRoot,
      draftOpen: true,
      draftWorkspaceRoot: action.workspaceRoot,
    };
  if (action.type === "task.draft.closed")
    return {
      ...state,
      activeTaskId: null,
      draftOpen: false,
      draftWorkspaceRoot: null,
    };
  if (action.type === "workspace.selected") {
    if (!action.workspaceRoot) return state;
    const activeTaskId =
      state.snapshot.tasks.find(
        (task) => task.workspaceRoot === action.workspaceRoot && !task.archived,
      )?.id ??
      state.snapshot.tasks.find(
        (task) => task.workspaceRoot === action.workspaceRoot,
      )?.id ??
      null;
    return {
      ...state,
      activeWorkspaceRoot: action.workspaceRoot,
      activeTaskId,
      draftOpen: activeTaskId === null,
      draftWorkspaceRoot: activeTaskId === null ? action.workspaceRoot : null,
    };
  }
  if (state.draftOpen)
    return {
      ...state,
      snapshot: action.snapshot,
      activeTaskId: null,
      activeWorkspaceRoot:
        state.draftWorkspaceRoot ?? state.activeWorkspaceRoot,
    };
  const requestedWorkspace = state.activeWorkspaceRoot;
  const activeTaskStillExists = action.snapshot.tasks.some(
    (task) => task.id === state.activeTaskId,
  );
  const activeTaskId = activeTaskStillExists
    ? state.activeTaskId
    : (action.snapshot.tasks.find(
        (task) => task.workspaceRoot === requestedWorkspace && !task.archived,
      )?.id ??
      action.snapshot.tasks.find(
        (task) => task.workspaceRoot === requestedWorkspace,
      )?.id ??
      action.snapshot.tasks.find((task) => !task.archived)?.id ??
      action.snapshot.tasks[0]?.id ??
      null);
  const activeTask = action.snapshot.tasks.find(
    (task) => task.id === activeTaskId,
  );
  return {
    snapshot: action.snapshot,
    activeTaskId,
    activeWorkspaceRoot:
      state.activeWorkspaceRoot ?? activeTask?.workspaceRoot ?? null,
    draftOpen: false,
    draftWorkspaceRoot: null,
  };
}
