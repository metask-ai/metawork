import type { WorkbenchSnapshot } from "../bridge/contracts.ts";
import { navigableTasks } from "./task-visibility.ts";

export type WorkbenchState = {
  snapshot: WorkbenchSnapshot;
  activeTaskId: string | null;
  draftOpen: boolean;
  draftWorkspaceId: string | null;
};

export type WorkbenchAction =
  | { type: "snapshot.accepted"; snapshot: WorkbenchSnapshot }
  | { type: "task.selected"; taskId: string }
  | { type: "task.draft.opened"; workspaceId: string | null }
  | { type: "task.draft.closed" };

export const initialWorkbenchState: WorkbenchState = {
  snapshot: {
    revision: "0",
    capabilities: {
      taskHistoryPersistence: false,
      taskHistoryPersistenceHealth: "unavailable",
      conversationRecovery: false,
      executionRebind: false,
      structuredPlan: false,
      typedOutputs: false,
      typedFileChanges: false,
      persistentWorkspacePermissions: false,
      automaticWorkspaces: false,
      scheduledTasks: false,
      scheduledTaskPersistence: false,
      scheduledTaskPersistenceHealth: "unavailable",
      backgroundScheduleWake: false,
      localSkillManagement: false,
      skillManagementHealth: "unavailable",
      modelConnectionManagement: false,
      modelConnectionSecretCapture: false,
      modelConnectionTest: false,
      mcpManagement: false,
      mcpConnectionApproval: false,
      mcpSecretCapture: false,
      mcpOAuth: false,
    },
    account: {
      state: "checking",
      catalogState: "unavailable",
      executionSource: "metask",
      canCancel: false,
      accountId: "",
      displayName: "",
      apiKeys: [],
      models: [],
      selectedApiKeySelectionId: "",
      selectedModelSelectionId: "",
      candidateApiKeySelectionId: "",
      candidateModelSelectionId: "",
      modelCatalogApiKeySelectionId: "",
      modelConnections: [],
      selectedModelConnectionId: "",
      canCreateTask: false,
      errorCode: "none",
      safeDiagnostic: "",
      catalogGeneration: "0",
      metaskExecutionGeneration: "0",
      executionGeneration: "0",
    },
    skillCatalog: {
      availability: "uninitialized",
      redacted: false,
      revision: null,
      selectionRevision: null,
      skills: [],
      issues: [],
    },
    skillManagement: {
      availability: "unavailable",
      enablementAvailability: "unavailable",
      assets: [],
    },
    mcp: {
      availability: "unavailable",
      managementHealth: "unavailable",
      operation: "idle",
      authorizationOperation: { kind: "idle" },
      desiredGeneration: null,
      runtimeAlignment: "unknown",
      redacted: false,
      servers: [],
    },
    workspaces: [],
    scheduledTasks: [],
    tasks: [],
  },
  activeTaskId: null,
  draftOpen: false,
  draftWorkspaceId: null,
};

export function taskHistoryMutationBlocked(
  health: WorkbenchSnapshot["capabilities"]["taskHistoryPersistenceHealth"],
) {
  return (
    health !== "ready" && health !== "degraded" && health !== "unavailable"
  );
}

export function workbenchReducer(
  state: WorkbenchState,
  action: WorkbenchAction,
): WorkbenchState {
  if (action.type === "task.selected") {
    const task = navigableTasks(state.snapshot).find(
      (candidate) => candidate.id === action.taskId,
    );
    if (!task) return state;
    return {
      ...state,
      activeTaskId: action.taskId,
      draftOpen: false,
      draftWorkspaceId: null,
    };
  }
  if (action.type === "task.draft.opened")
    return {
      ...state,
      activeTaskId: null,
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

  if (state.draftOpen)
    return {
      ...state,
      snapshot: action.snapshot,
      activeTaskId: null,
      // A removed Workspace loses authorization, but its local draft identity
      // must survive so reauthorization can restore the same text.
      draftWorkspaceId: state.draftWorkspaceId,
    };

  const availableTasks = navigableTasks(action.snapshot);
  const activeTaskStillExists = availableTasks.some(
    (task) => task.id === state.activeTaskId,
  );
  // Snapshot hydration restores the history list, not the current
  // conversation route. A Task becomes active only after an explicit user
  // selection; if that selection disappears, return to New task instead of
  // silently opening another historical conversation.
  const activeTaskId = activeTaskStillExists ? state.activeTaskId : null;
  return {
    snapshot: action.snapshot,
    activeTaskId,
    draftOpen: false,
    draftWorkspaceId: null,
  };
}
