import type { WorkbenchSnapshot } from "../bridge/contracts.ts";
import { skillSourceIds } from "../bridge/contracts.ts";
import { navigableTasks } from "./task-visibility.ts";

export type WorkbenchState = {
  snapshot: WorkbenchSnapshot;
  snapshotReceivedAt: number | null;
  connectionGeneration: string;
  snapshotGeneration: string | null;
  activeTaskId: string | null;
  draftOpen: boolean;
  draftWorkspaceId: string | null;
};

export type WorkbenchAction =
  | {
      type: "generation.started";
      generation: string;
    }
  | {
      type: "snapshot.accepted";
      snapshot: WorkbenchSnapshot;
      receivedAt: number;
      generation?: string;
    }
  | { type: "task.selected"; taskId: string }
  | { type: "task.draft.opened"; workspaceId: string | null }
  | { type: "task.draft.closed" };

export const initialWorkbenchState: WorkbenchState = {
  snapshotReceivedAt: null,
  snapshot: {
    revision: "0",
    automaticWorkspaceRoot: {
      generation: "1",
      mode: null,
      canonicalRoot: null,
      health: "persistence_unavailable",
      redacted: false,
      canChoose: false,
      canReset: false,
      canRetry: false,
    },
    capabilities: {
      taskHistoryPersistence: false,
      taskHistoryPersistenceHealth: "unavailable",
      taskHistoryRecoveryAvailable: false,
      conversationRecovery: false,
      executionRebind: false,
      structuredPlan: false,
      typedOutputs: false,
      typedFileChanges: false,
      permissionProfiles: false,
      persistentWorkspacePermissions: false,
      automaticWorkspaces: false,
      scheduledTasks: false,
      scheduledTaskPersistence: false,
      scheduledTaskPersistenceHealth: "unavailable",
      scheduledTaskRecoveryAvailable: false,
      backgroundScheduleWake: false,
      localSkillManagement: false,
      skillManagementHealth: "unavailable",
      customProviderManagement: false,
      customProviderSecretCapture: false,
      customModelTest: false,
      mcpManagement: false,
      mcpConnectionApproval: false,
      mcpSecretCapture: false,
      mcpSecretMaxBytes: 0,
      mcpOAuth: false,
      attachments: {
        enabled: false,
        imageFormats: [],
        maxFiles: "8",
        maxFileBytes: "3750000",
        maxStagedBytes: "33554432",
      },
    },
    permissions: {
      availableProfiles: [],
      defaultProfile: "approval_required",
    },
    account: {
      state: "checking",
      canCancel: false,
      accountId: "",
      displayName: "",
      emailHint: "",
      concurrencyLimit: null,
      errorCode: "none",
      safeDiagnostic: "",
      summary: {
        operation: "idle",
        usageEligibility: "unknown",
        wallet: {
          availability: "unavailable",
          balanceU: null,
          syncedAt: null,
          errorCode: "none",
          safeDiagnostic: "",
        },
        usage: {
          availability: "unavailable",
          today: null,
          total: null,
          syncedAt: null,
          errorCode: "none",
          safeDiagnostic: "",
        },
        history: {
          availability: "unavailable",
          startDate: null,
          endDate: null,
          days: [],
          syncedAt: null,
          errorCode: "none",
          safeDiagnostic: "",
        },
      },
    },
    models: {
      availability: "needs_authentication",
      persistenceHealth: "unavailable",
      providers: [],
      metaskSelection: null,
      metaskSelectionRevision: "0",
      defaultSelection: null,
      selectionRevision: "0",
      operation: "idle",
      errorCode: "none",
      builtinProviderPresets: [],
      customProviders: [],
    },
    newTaskAdmission: {
      available: false,
      reason: "none",
      activeModelRef: null,
      activeGeneration: "0",
      activeSelectionRevision: "0",
      state: "unavailable",
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
      sourceSettings: {
        revision: null,
        health: "unavailable",
        entries: skillSourceIds.map((sourceId) => ({
          sourceId,
          enabled: null,
          canSetEnabled: false,
        })),
        recovery: { canReread: false, canReset: false, token: null },
      },
      personalSourceDiscovery: null,
      assets: [],
    },
    mcp: {
      availability: "unavailable",
      managementHealth: "unavailable",
      operation: "idle",
      configurationApply: "idle",
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
  connectionGeneration: "0",
  snapshotGeneration: null,
  activeTaskId: null,
  draftOpen: false,
  draftWorkspaceId: null,
};

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

  if (action.type === "generation.started") {
    if (action.generation === state.connectionGeneration) return state;
    return {
      ...state,
      connectionGeneration: action.generation,
      snapshotGeneration: null,
      snapshot: initialWorkbenchState.snapshot,
      snapshotReceivedAt: null,
      activeTaskId: null,
      draftOpen: false,
      draftWorkspaceId: null,
    };
  }

  const generation = action.generation ?? state.connectionGeneration;
  if (generation !== state.connectionGeneration) return state;

  if (state.draftOpen)
    return {
      ...state,
      snapshot: action.snapshot,
      snapshotReceivedAt: action.receivedAt,
      snapshotGeneration: generation,
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
    snapshotReceivedAt: action.receivedAt,
    connectionGeneration: state.connectionGeneration,
    snapshotGeneration: generation,
    activeTaskId,
    draftOpen: false,
    draftWorkspaceId: null,
  };
}
