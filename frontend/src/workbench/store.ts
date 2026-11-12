import type { WorkbenchSnapshot } from "../bridge/contracts.ts";
import { emptyViewVersions, initialViewScope } from "../bridge/contracts.ts";
import { selectableTask } from "./task-visibility.ts";
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
  | {
      type: "security.invalidated";
      securityEpoch: string;
      generation: string;
    }
  | {
      type: "task.selected";
      taskId: string;
    }
  | {
      type: "task.draft.opened";
      workspaceId: string | null;
    }
  | {
      type: "task.draft.closed";
    };
export const initialWorkbenchState: WorkbenchState = {
  snapshotReceivedAt: null,
  snapshot: {
    revision: "0",
    mcpInstallation: { operations: [], notice: null },
    updates: {
      checkState: "unavailable",
      checkError: "none",
      latestVersion: null,
      updateAvailable: false,
      downloadAvailable: false,
      downloadState: "idle",
      downloadError: "none",
    },
    blockVersions: emptyViewVersions,
    securityEpoch: "1",
    historyEpoch: "1",
    scope: initialViewScope,
    taskIndex: [],
    receipts: [],
    searchIndex: null,
    taskPage: null,
    historyPage: null,
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
      retainedTaskHistoryCount: "0",
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
      availableModes: [],
      defaultMode: "auto_review",
    },
    account: {
      state: "checking",
      canCancel: false,
      accountId: "",
      displayName: "",
      emailHint: "",
      phoneHint: "",
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
      defaultSelection: null,
      defaultSelectionDisplayName: null,
      selectionRevision: "0",
      operation: "idle",
      errorCode: "none",
      builtinProviderPresets: [],
      customProviders: [],
    },
    newTaskAdmission: {
      available: false,
      reason: "workspace_unavailable",
    },
    skillCatalog: {
      availability: "uninitialized",
      redacted: false,
      revision: null,
      selectionRevision: null,
      skills: [],
      issues: [],
    },
    skillManagement: null,
    mcp: null,
    workspaces: [],
    scheduledTasks: null,
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
    if (!selectableTask(state.snapshot, action.taskId)) return state;
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
  if (action.type === "security.invalidated") {
    if (action.generation !== state.connectionGeneration) return state;
    return {
      ...state,
      snapshot: {
        ...initialWorkbenchState.snapshot,
        securityEpoch: action.securityEpoch,
      },
      snapshotReceivedAt: null,
    };
  }
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
  let snapshot = action.snapshot;
  const page = snapshot.taskPage;
  if (page) {
    // Retain only explicitly fetched Runs of this Task. Current header and
    // current Run always come from this commit, including during history reads.
    const previous =
      state.snapshot.securityEpoch === snapshot.securityEpoch &&
      state.snapshot.historyEpoch === snapshot.historyEpoch
        ? state.snapshot.tasks.find((task) => task.id === page.task.id)
        : undefined;
    const previousManifest = new Map(
      state.snapshot.taskPage?.runManifest.map((run) => [
        run.id,
        run.contentVersion,
      ]),
    );
    const confirmed = new Set(
      page.runManifest
        .filter((run) => previousManifest.get(run.id) === run.contentVersion)
        .map((run) => run.id),
    );
    const runs = new Map(
      previous?.runs
        .filter((run) => confirmed.has(run.id))
        .map((run) => [run.id, run]),
    );
    for (const run of snapshot.historyPage?.runs ?? []) runs.set(run.id, run);
    for (const run of page.task.runs) runs.set(run.id, run);
    let first = page.runManifest.length;
    while (first > 0 && runs.has(page.runManifest[first - 1]!.id)) first--;
    snapshot = {
      ...snapshot,
      tasks: [
        {
          ...page.task,
          runs: page.runManifest.slice(first).map((run) => runs.get(run.id)!),
        },
      ],
    };
  }
  if (state.draftOpen)
    return {
      ...state,
      snapshot,
      snapshotReceivedAt: action.receivedAt,
      snapshotGeneration: generation,
      activeTaskId: null,
      // A removed Workspace loses authorization, but its local draft identity
      // must survive so reauthorization can restore the same text.
      draftWorkspaceId: state.draftWorkspaceId,
    };
  // Snapshot hydration restores the history list, not the current
  // conversation route. A Task becomes active only after an explicit user
  // selection; if that selection disappears, return to New task instead of
  // silently opening another historical conversation.
  const activeTaskId =
    state.activeTaskId && selectableTask(snapshot, state.activeTaskId)
      ? state.activeTaskId
      : null;
  return {
    snapshot,
    snapshotReceivedAt: action.receivedAt,
    connectionGeneration: state.connectionGeneration,
    snapshotGeneration: generation,
    activeTaskId,
    draftOpen: false,
    draftWorkspaceId: null,
  };
}
