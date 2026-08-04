export type AccountSessionState =
  | "restoring"
  | "signed_out"
  | "authorizing"
  | "authenticated"
  | "refreshing"
  | "reauth_required"
  | "shutting_down";

export type ExecutionState =
  "none" | "preparing" | "ready" | "reconfiguring" | "invalid";

export type AccountOperation =
  | "none"
  | "oauth_callback"
  | "token_exchange"
  | "loading_keys"
  | "selecting_key"
  | "loading_models"
  | "selecting_model"
  | "persisting"
  | "logging_out";

export type AccountReadiness =
  | "checking"
  | "sign_in_required"
  | "preparing"
  | "choice_required"
  | "ready"
  | "needs_attention"
  | "restart_required";

export type AccountPrimaryAction =
  | "none"
  | "sign_in"
  | "reopen_login"
  | "choose_api_key"
  | "choose_model"
  | "retry_catalog"
  | "reauthenticate"
  | "restart";

export type AccountErrorCode =
  | "none"
  | "invalid_command"
  | "invalid_state"
  | "operation_in_progress"
  | "execution_in_use"
  | "oauth_bind_failed"
  | "oauth_browser_open_failed"
  | "oauth_callback_rejected"
  | "oauth_state_mismatch"
  | "oauth_exchange_failed"
  | "user_cancelled"
  | "deadline_exceeded"
  | "token_refresh_failed"
  | "account_mismatch"
  | "metask_unauthorized"
  | "metask_rate_limited"
  | "metask_service_unavailable"
  | "metask_protocol_invalid"
  | "catalog_too_large"
  | "catalog_field_too_large"
  | "no_api_keys"
  | "no_models"
  | "execution_target_invalid"
  | "execution_config_invalid"
  | "credential_store_read_failed"
  | "credential_store_write_failed"
  | "credential_store_delete_failed"
  | "generation_mismatch"
  | "recovery_state_invalid"
  | "local_resource_exhausted"
  | "dependency_contract_invalid"
  | "shutting_down";

export type Provider = "anthropic" | "openai";

export type AccountView = {
  sessionState: AccountSessionState;
  executionState: ExecutionState;
  operation: AccountOperation;
  readiness: AccountReadiness;
  primaryAction: AccountPrimaryAction;
  canCancel: boolean;
  accountId: string;
  profileId: string;
  displayName: string;
  apiKeys: {
    selectionId: string;
    name: string;
    suffix: string;
    provider: Provider;
  }[];
  models: { selectionId: string; displayName: string }[];
  selectedApiKeySelectionId: string;
  selectedModelSelectionId: string;
  candidateApiKeySelectionId: string;
  candidateModelSelectionId: string;
  modelCatalogApiKeySelectionId: string;
  canCreateTask: boolean;
  errorCode: AccountErrorCode;
  safeDiagnostic: string;
  catalogGeneration: string;
  executionGeneration: string;
};

export type AccountCommandResult = {
  accepted: boolean;
  errorCode: AccountErrorCode;
  attemptId: string | null;
};

export type ToolView = {
  id: string;
  order: string;
  name: string;
  input: string;
  progress: string;
  content: string;
  state: "running" | "completed" | "failed";
  isError: boolean;
  elapsedMs: string;
  inputTruncated: boolean;
  progressTruncated: boolean;
  contentTruncated: boolean;
  redacted: boolean;
};

export type RunPhase =
  | "queued"
  | "running"
  | "waiting_ui"
  | "stopping"
  | "completed"
  | "stopped"
  | "cancelled"
  | "interrupted"
  | "failed";

export type NonTerminalRunPhase = Extract<
  RunPhase,
  "queued" | "running" | "waiting_ui" | "stopping"
>;

export type TaskRunInput =
  | {
      kind: "text";
      text: string;
    }
  | {
      kind: "skill";
      skillId: string;
      catalogRevision: string;
      argumentValues: string[];
    };

export type ScheduledTaskRecurrence =
  | { kind: "once"; atUnixSeconds: string }
  | {
      kind: "interval";
      startAtUnixSeconds: string;
      everySeconds: string;
    };

export type ScheduledTaskView = {
  id: string;
  epoch: string;
  title: string;
  titleRedacted: boolean;
  enabled: boolean;
  health: "ready" | "paused" | "needs_attention" | "completed";
  failureReason:
    | "previous_task_running"
    | "execution_changed"
    | "workspace_unavailable"
    | "capacity_reached"
    | "shutting_down"
    | "task_start_failed"
    | "timer_unavailable"
    | "persistence_failed"
    | "host_interrupted"
    | null;
  execution: {
    generation: string;
    provider: Provider;
    model: string;
  };
  input: { kind: "text"; text: string; redacted: boolean };
  recurrence: ScheduledTaskRecurrence;
  nextRunAtUnixSeconds: string | null;
  occurrences: Array<{
    plannedAtUnixSeconds: string;
    triggeredAtUnixSeconds: string;
    source: "timer" | "manual";
    result: "claimed" | "submitted" | "skipped" | "rejected";
    taskId: string | null;
    reason: ScheduledTaskView["failureReason"];
    taskOutcome:
      | "completed"
      | "stopped"
      | "cancelled"
      | "interrupted"
      | "failed"
      | "dependency_contract_failure"
      | null;
  }>;
};

export type ScheduledTaskMutation = {
  title: string;
  expectedExecutionGeneration: string;
  input: Extract<TaskRunInput, { kind: "text" }>;
  recurrence: ScheduledTaskRecurrence;
};

export type RunInputView =
  | {
      kind: "text";
      text: string;
      redacted: boolean;
    }
  | {
      kind: "skill";
      skillId: string;
      catalogRevision: string;
      invocationName: string;
      displayName: string;
      argumentValues: string[];
      redacted: boolean;
    };

export const runCauses = [
  "user_cancel",
  "timeout",
  "session_close",
  "app_shutdown",
  "event_pipeline_failure",
  "queue_capacity_failure",
  "ui_pipeline_failure",
  "dependency_contract_failure",
  "stale_catalog",
  "skill_not_found",
  "invalid_skill_arguments",
  "skill_policy_violation",
  "skill_unavailable",
  "resource_limit",
] as const;

export type RunCause = (typeof runCauses)[number];

export type RunView = {
  id: string;
  phase: RunPhase;
  input: RunInputView;
  assistant: string;
  assistantRedacted: boolean;
  status: string;
  outcome:
    | "completed"
    | "stopped"
    | "cancelled"
    | "interrupted"
    | "failed"
    | "dependency_contract_failure"
    | null;
  cause: RunCause | null;
  usage: {
    input: string;
    output: string;
    cacheRead: string;
    cacheCreation: string;
  };
  tools: ToolView[];
};

export type CompactPhase =
  | "queued"
  | "compacting"
  | "stopping"
  | "compacted"
  | "no_change"
  | "degraded"
  | "aborted"
  | "interrupted"
  | "failed";

export const compactCauses = [
  "user_cancel",
  "session_close",
  "app_shutdown",
  "resource_limit",
  "agent_failure",
  "dependency_contract_failure",
] as const;

export type CompactCause = (typeof compactCauses)[number];

export type CompactView = {
  operationId: string;
  afterRunId: string;
  phase: CompactPhase;
  cause: CompactCause | null;
  beforeContextTokens: string;
  afterContextTokens: string;
  usage: {
    input: string;
    output: string;
    cacheRead: string;
    cacheCreation: string;
  };
};

export type ActiveOperation =
  { kind: "run"; id: string } | { kind: "compact"; id: string };

export type AskOption = {
  label: string;
  description: string;
  preview: string;
};

export type AskQuestion = {
  question: string;
  header: string;
  multi: boolean;
  options: AskOption[];
};

export type PendingUi =
  | {
      requestId: string;
      runId: string;
      order: string;
      redacted: boolean;
      kind: "ask_question";
      questions: AskQuestion[];
    }
  | {
      requestId: string;
      runId: string;
      order: string;
      redacted: boolean;
      kind: "permission";
      tool: string;
      args: string;
    };

export type UiRecord = {
  requestId: string;
  runId: string;
  order: string;
  kind: "ask_question" | "permission";
  state:
    | "answered"
    | "allowed_once"
    | "allowed_always"
    | "denied"
    | "denied_session"
    | "cancelled";
  detail: string;
  itemCount: number;
  detailTruncated: boolean;
  redacted: boolean;
};

export type TaskView = {
  id: string;
  recentOrder: string;
  title: string;
  workspaceId: string;
  binding: {
    epoch: string;
    availability: "available" | "unavailable";
    accountId: string;
    profileId: string;
    accountDisplayName: string;
    apiKeySelectionId: string;
    apiKeyName: string;
    apiKeySuffix: string;
    provider: Provider;
    modelSelectionId: string;
    modelDisplayName: string;
    executionGeneration: string;
    unavailableReason: "credential_released" | null;
  };
  skillCatalog: SkillCatalogView;
  lifecycle: "open" | "closing" | "closed";
  continuationAvailable: boolean;
  continuationUnavailableReason:
    | "session_poisoned"
    | "event_projection_failure"
    | "closing"
    | "closed"
    | "session_recovery_unsupported"
    | null;
  archived: boolean;
  closeFailed: boolean;
  activeOperation: ActiveOperation | null;
  currentRunId: string;
  currentRunPhase: NonTerminalRunPhase | null;
  lastRunOutcome: RunView["outcome"];
  cause: RunView["cause"];
  runs: RunView[];
  compacts: CompactView[];
  pendingUi: PendingUi | null;
  uiHistory: UiRecord[];
};

export type WorkbenchSnapshot = {
  revision: string;
  capabilities: {
    taskHistoryPersistence: boolean;
    taskHistoryPersistenceHealth:
      | "unavailable"
      | "ready"
      | "read_failed"
      | "corrupt"
      | "write_failed"
      | "outcome_unknown";
    conversationRecovery: boolean;
    executionRebind: boolean;
    structuredPlan: boolean;
    typedOutputs: boolean;
    typedFileChanges: boolean;
    persistentWorkspacePermissions: boolean;
    managedWorkspaces: boolean;
    scheduledTasks: boolean;
    scheduledTaskPersistence: boolean;
    scheduledTaskPersistenceHealth:
      | "unavailable"
      | "ready"
      | "read_failed"
      | "corrupt"
      | "write_failed"
      | "outcome_unknown";
    backgroundScheduleWake: boolean;
    localSkillManagement: boolean;
    skillManagementHealth:
      | "unavailable"
      | "ready"
      | "read_failed"
      | "corrupt"
      | "write_failed"
      | "outcome_unknown";
    mcpManagement: boolean;
  };
  account: AccountView;
  skillCatalog: SkillCatalogView;
  skillManagement: SkillManagementView;
  mcp: McpManagementView;
  selectedWorkspaceId: string | null;
  workspaces: WorkspaceView[];
  scheduledTasks: ScheduledTaskView[];
  tasks: TaskView[];
};

export type WorkspaceView = {
  id: string;
  epoch: string;
  origin: "user" | "managed";
  displayName: string;
  canonicalRoot: string;
  redacted: boolean;
  authorization: "available" | "removing" | "reauthorization_required";
  lastRemovalFailure: "task_close_failed" | null;
  skillCatalog: SkillCatalogView;
  recentOrder: string;
  signals: {
    running: number;
    attention: number;
    failedOrInterrupted: number;
  };
};

export type SkillCatalogAvailability =
  "uninitialized" | "loading" | "ready" | "degraded" | "unavailable";

export type SkillCatalogView = {
  availability: SkillCatalogAvailability;
  redacted: boolean;
  revision: string | null;
  skills: {
    skillId: string;
    invocationName: string;
    displayName: string;
    description: string;
    argumentNames: string[];
    maxValues: number;
  }[];
  issues: {
    code:
      | "invalid_definition"
      | "source_conflict"
      | "invalid_resource"
      | "invalid_invocation_name";
    invocationName: string | null;
  }[];
};

export type SkillManagementView = {
  availability: WorkbenchSnapshot["capabilities"]["skillManagementHealth"];
  assets: {
    installId: string | null;
    sourceKind: "local_package" | "local_directory" | "external";
    scope:
      | { kind: "personal"; workspaceId: null; workspaceEpoch: null }
      | {
          kind: "project";
          workspaceId: string;
          workspaceEpoch: string;
        }
      | { kind: "external"; workspaceId: null; workspaceEpoch: null };
    managementState: "ready" | "pending_verification" | "externally_managed";
    skillId: string | null;
    invocationName: string;
    displayName: string;
    description: string;
    argumentNames: string[];
    maxValues: number;
    canExport: boolean;
    canReimport: boolean;
    canUninstall: boolean;
    canRetry: boolean;
    issueCodes: SkillCatalogView["issues"][number]["code"][];
  }[];
};

export type McpManagementView = {
  availability: "unavailable" | "ready" | "degraded";
  redacted: boolean;
  generation: string | null;
  servers: {
    id: string;
    displayName: string;
    namespace: string;
    transport: "stdio" | "streamable_http";
    status:
      | "ready"
      | "disabled"
      | "needs_authentication"
      | "unreachable"
      | "invalid_catalog";
    safeDiagnostic: string;
    tools: { name: string }[];
  }[];
};

export type WorkspaceMutationReason =
  | "workspace_changed"
  | "workspace_unavailable"
  | "workspace_removing"
  | "capacity_reached"
  | "removal_failed";

export type WorkspaceMutationResult =
  | {
      accepted: true;
      workspaceId: string;
      workspaceEpoch: string;
      reason: null;
    }
  | {
      accepted: false;
      workspaceId: string;
      workspaceEpoch: null;
      reason: WorkspaceMutationReason;
    };

export type TaskCreateReason =
  | "execution_changed"
  | "execution_unavailable"
  | "workspace_changed"
  | "workspace_unavailable"
  | "workspace_removing"
  | "catalog_loading"
  | "catalog_unavailable"
  | "stale_catalog"
  | "capacity_reached"
  | "shutting_down";

export type TaskCreateResult =
  | {
      accepted: true;
      taskId: string;
      bindingEpoch: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: null;
      bindingEpoch: null;
      reason: TaskCreateReason;
    };

export type TaskRunReason =
  | "binding_changed"
  | "binding_unavailable"
  | "task_unavailable"
  | "task_busy"
  | "workspace_unavailable"
  | "workspace_changed"
  | "workspace_removing"
  | "catalog_unavailable"
  | "stale_catalog"
  | "skill_not_found"
  | "invalid_skill_arguments"
  | "capacity_reached"
  | "shutting_down";

export type TaskRunResult =
  | {
      accepted: true;
      taskId: string;
      runId: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: string;
      runId: null;
      reason: TaskRunReason;
    };

export type TaskCompactReason =
  | "binding_changed"
  | "binding_unavailable"
  | "task_unavailable"
  | "task_busy"
  | "no_history"
  | "capacity_reached"
  | "shutting_down";

export type TaskCompactResult =
  | {
      accepted: true;
      taskId: string;
      operationId: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: string;
      operationId: null;
      reason: TaskCompactReason;
    };

export type CatalogRefreshReason =
  | "workspace_changed"
  | "binding_changed"
  | "workspace_unavailable"
  | "workspace_removing"
  | "task_unavailable"
  | "task_busy"
  | "catalog_loading"
  | "catalog_unavailable"
  | "capacity_reached"
  | "shutting_down";

export type CatalogRefreshResult<Identity extends "workspaceId" | "taskId"> = {
  accepted: boolean;
  reason: CatalogRefreshReason | null;
} & Record<Identity, string>;

export type SkillCatalogRefreshResult = {
  accepted: boolean;
  reason: CatalogRefreshReason | null;
};

export type HostSignal = {
  sequence: number;
};

export type WorkspaceChoice =
  { selected: false } | { selected: true; workspaceId: string };

export type SkillImportPreview =
  | { selected: false }
  | {
      selected: true;
      previewId: string;
      sourceKind: "local_package" | "local_directory";
      invocationName: string;
      displayName: string;
      description: string;
      fileCount: number;
      totalBytes: number;
    };

export type SkillMutationReason =
  | "invalid_scope"
  | "invalid_preview"
  | "source_changed"
  | "asset_unavailable"
  | "state_changed"
  | "target_exists"
  | "busy"
  | "catalog_loading"
  | "workspace_changed"
  | "workspace_unavailable"
  | "capacity_reached"
  | "shutting_down"
  | "local_storage_failed";

export type SkillMutationResult =
  | {
      accepted: true;
      installId: string;
      verificationPending: boolean;
      reason: null;
    }
  | {
      accepted: false;
      installId: null;
      verificationPending: false;
      reason: SkillMutationReason;
    };

export type SkillExportResult =
  | { exported: true; fileName: string; reason: null }
  | { exported: false; fileName: null; reason: string };

export type SkillDetailResult =
  | {
      available: true;
      definition: string;
      fileCount: number;
      totalBytes: number;
      reason: null;
    }
  | {
      available: false;
      definition: null;
      fileCount: 0;
      totalBytes: 0;
      reason: string;
    };

export type UiResponsePayload =
  | { kind: "permission"; permission: "deny_once" | "allow_once" }
  | { kind: "answers"; answers: string[][] };
