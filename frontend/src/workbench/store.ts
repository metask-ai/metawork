import type { WorkbenchSnapshot } from "../bridge/contracts.ts";

export type WorkbenchState = {
  snapshot: WorkbenchSnapshot;
  activeTaskId: string | null;
  activeWorkspaceId: string | null;
  draftOpen: boolean;
  draftWorkspaceId: string | null;
};

export type WorkbenchAction =
  | { type: "snapshot.accepted"; snapshot: WorkbenchSnapshot }
  | { type: "task.selected"; taskId: string }
  | { type: "workspace.selected"; workspaceId: string }
  | { type: "task.draft.opened"; workspaceId: string | null }
  | { type: "task.draft.closed" };

export const initialWorkbenchState: WorkbenchState = {
  snapshot: {
    revision: "0",
    capabilities: {
      taskHistoryPersistence: false,
      conversationRecovery: false,
      executionRebind: false,
      structuredPlan: false,
      typedOutputs: false,
      typedFileChanges: false,
      persistentWorkspacePermissions: false,
    },
    account: {
      sessionState: "restoring",
      executionState: "none",
      operation: "none",
      readiness: "checking",
      primaryAction: "none",
      canCancel: false,
      accountId: "",
      profileId: "",
      displayName: "",
      apiKeys: [],
      models: [],
      selectedApiKeySelectionId: "",
      selectedModelSelectionId: "",
      candidateApiKeySelectionId: "",
      candidateModelSelectionId: "",
      modelCatalogApiKeySelectionId: "",
      canCreateTask: false,
      errorCode: "none",
      safeDiagnostic: "",
      catalogGeneration: "0",
      executionGeneration: "0",
    },
    selectedWorkspaceId: null,
    workspaces: [],
    tasks: [],
  },
  activeTaskId: null,
  activeWorkspaceId: null,
  draftOpen: false,
  draftWorkspaceId: null,
};

function firstTaskInWorkspace(
  snapshot: WorkbenchSnapshot,
  workspaceId: string | null,
) {
  if (workspaceId === null) return null;
  return (
    snapshot.tasks.find(
      (task) => task.workspaceId === workspaceId && !task.archived,
    )?.id ??
    snapshot.tasks.find((task) => task.workspaceId === workspaceId)?.id ??
    null
  );
}

export function workbenchReducer(
  state: WorkbenchState,
  action: WorkbenchAction,
): WorkbenchState {
  if (action.type === "task.selected") {
    const task = state.snapshot.tasks.find(
      (candidate) => candidate.id === action.taskId,
    );
    if (
      !task ||
      !state.snapshot.workspaces.some(({ id }) => id === task.workspaceId)
    )
      return state;
    return {
      ...state,
      activeTaskId: action.taskId,
      activeWorkspaceId: task.workspaceId,
      draftOpen: false,
      draftWorkspaceId: null,
    };
  }
  if (action.type === "task.draft.opened")
    return {
      ...state,
      activeTaskId: null,
      activeWorkspaceId: action.workspaceId ?? state.activeWorkspaceId,
      draftOpen: true,
      draftWorkspaceId: action.workspaceId,
    };
  if (action.type === "task.draft.closed")
    return {
      ...state,
      activeTaskId: null,
      draftOpen: false,
      draftWorkspaceId: null,
    };
  if (action.type === "workspace.selected") {
    if (!state.snapshot.workspaces.some(({ id }) => id === action.workspaceId))
      return state;
    const activeTaskId = firstTaskInWorkspace(
      state.snapshot,
      action.workspaceId,
    );
    return {
      ...state,
      activeWorkspaceId: action.workspaceId,
      activeTaskId,
      draftOpen: activeTaskId === null,
      draftWorkspaceId: activeTaskId === null ? action.workspaceId : null,
    };
  }

  const workspaceIds = new Set(action.snapshot.workspaces.map(({ id }) => id));
  const retainedWorkspaceId = action.snapshot.selectedWorkspaceId;
  if (state.draftOpen)
    return {
      ...state,
      snapshot: action.snapshot,
      activeTaskId: null,
      activeWorkspaceId:
        state.draftWorkspaceId !== null &&
        workspaceIds.has(state.draftWorkspaceId)
          ? state.draftWorkspaceId
          : null,
      // A removed Workspace disappears from navigation, but its local draft
      // identity must survive so reauthorization can restore the same text.
      draftWorkspaceId: state.draftWorkspaceId,
    };

  const activeTaskStillExists = action.snapshot.tasks.some(
    (task) =>
      task.id === state.activeTaskId &&
      task.workspaceId === retainedWorkspaceId &&
      workspaceIds.has(task.workspaceId),
  );
  const activeTaskId = activeTaskStillExists
    ? state.activeTaskId
    : (firstTaskInWorkspace(action.snapshot, retainedWorkspaceId) ??
      action.snapshot.tasks.find(
        (task) => workspaceIds.has(task.workspaceId) && !task.archived,
      )?.id ??
      action.snapshot.tasks.find((task) => workspaceIds.has(task.workspaceId))
        ?.id ??
      null);
  const activeTask = action.snapshot.tasks.find(
    (task) => task.id === activeTaskId,
  );
  return {
    snapshot: action.snapshot,
    activeTaskId,
    activeWorkspaceId: activeTask?.workspaceId ?? retainedWorkspaceId ?? null,
    draftOpen: false,
    draftWorkspaceId: null,
  };
}
