export type AccountState =
  "checking" | "signed_out" | "authorizing" | "authenticated";

export type CatalogState =
  "unavailable" | "loading" | "choosing" | "ready" | "failed";

export type ExecutionSource = "metask" | "model_connection";

export type AccountErrorCode =
  | "none"
  | "invalid_command"
  | "invalid_state"
  | "operation_in_progress"
  | "execution_in_use"
  | "session_in_use"
  | "oauth_bind_failed"
  | "oauth_browser_open_failed"
  | "oauth_callback_rejected"
  | "oauth_state_mismatch"
  | "oauth_exchange_failed"
  | "user_cancelled"
  | "deadline_exceeded"
  | "token_refresh_failed"
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
  | "model_connection_invalid"
  | "model_connection_not_found"
  | "model_connection_capture_unavailable"
  | "model_connection_persistence_unavailable"
  | "model_connection_test_unavailable";

export type Provider = "anthropic" | "openai" | "gemini";

export type ModelConnectionProtocol =
  "anthropic_messages" | "openai_chat_completions" | "gemini_native";

export type ModelConnectionState = "configuring" | "ready" | "disabled";

export type ModelConnectionTestStatus =
  "untested" | "testing" | "connected" | "failed";

export type ModelConnectionCredentialStatus =
  "missing" | "ready" | "invalid" | "capture_unavailable";

export type ModelConnectionView = {
  id: string;
  displayName: string;
  protocol: ModelConnectionProtocol;
  normalizedBaseUrl: string;
  state: ModelConnectionState;
  testStatus: ModelConnectionTestStatus;
  credentialStatus: ModelConnectionCredentialStatus;
  enabled: boolean;
  models: { id: string; displayName: string }[];
  selectedModel: string;
  connectionGeneration: string;
};

export type AccountView = {
  state: AccountState;
  catalogState: CatalogState;
  executionSource: ExecutionSource;
  canCancel: boolean;
  accountId: string;
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
  modelConnections: ModelConnectionView[];
  selectedModelConnectionId: string;
  canCreateTask: boolean;
  errorCode: AccountErrorCode;
  safeDiagnostic: string;
  catalogGeneration: string;
  metaskExecutionGeneration: string;
  executionGeneration: string;
};

export type AccountCommandResult = {
  accepted: boolean;
  errorCode: AccountErrorCode;
  attemptId: string | null;
};

export type FileReferencePositionView = {
  line: string;
  column: string;
};

export type FileReferenceRangeView = {
  start: FileReferencePositionView;
  end: FileReferencePositionView;
};

export type FileReferenceView = {
  id: string;
  title: string;
  displayPath: string;
  kind: string;
  range: FileReferenceRangeView | null;
};

export type FilePreview = {
  state:
    | "loading"
    | "ready"
    | "truncated"
    | "missing"
    | "restricted"
    | "unsupported"
    | "error";
  id: string;
  title: string;
  displayPath: string;
  language: string;
  content: string;
  truncated: boolean;
  range: FileReferenceRangeView | null;
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
  fileRefs: FileReferenceView[];
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
      selectionRevision: string;
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
  "agent_failure",
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
  | { kind: "run"; id: string }
  | { kind: "compact"; id: string }
  | { kind: "restore"; id: string };

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
      availableChoices: PermissionChoice[];
    };

export type PermissionChoice =
  "deny_once" | "deny_session" | "allow_once" | "allow_session";

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
  agentRequestId: string;
  permission: PermissionHistory | null;
  detail: string;
  itemCount: number;
  detailTruncated: boolean;
  redacted: boolean;
};

export type PermissionHistory = {
  requestId: string;
  matchedRuleId: string;
  toolNamespace: "builtin" | "host" | "mcp";
  toolName: string;
  toolBinding: string;
  decision: "allow" | "ask" | "deny";
  source:
    | "core_safety"
    | "active_skill"
    | "explicit_deny"
    | "session_deny"
    | "explicit_ask"
    | "explicit_allow"
    | "session_allow"
    | "builtin_classification"
    | "mode_fallback"
    | "callback";
  policyGeneration: string;
  usedSessionRule: boolean;
  callbackOutcome:
    "answered" | "user_cancelled" | "unavailable" | "contract_failure" | null;
};

export type TaskView = {
  id: string;
  recentOrder: string;
  title: string;
  workspaceId: string;
  binding: {
    epoch: string;
    availability: "available" | "unavailable";
    provider: Provider;
    model: string;
    executionGeneration: string;
    unavailableReason: "runtime_detached" | null;
  };
  skillCatalog: SkillCatalogView;
  lifecycle: "open" | "closing";
  deletionStatus: "idle" | "deleting" | "failed";
  continuationAvailable: boolean;
  continuationUnavailableReason:
    | "session_poisoned"
    | "closing"
    | "task_archived"
    | "session_recovery_required"
    | "session_recovery_in_progress"
    | "session_recovery_failed"
    | "persistence_unavailable"
    | "checkpoint_unavailable"
    | "execution_mismatch"
    | "workspace_unavailable"
    | "authority_unavailable"
    | "runtime_unavailable"
    | null;
  continuationRecoveryAvailable: boolean;
  archived: boolean;
  restorePermission: {
    restoredRules: string;
    invalidatedRules: string;
  } | null;
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
      | "degraded"
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
    automaticWorkspaces: boolean;
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
    modelConnectionManagement: boolean;
    modelConnectionSecretCapture: boolean;
    modelConnectionTest: boolean;
    mcpManagement: boolean;
    mcpConnectionApproval: boolean;
    mcpSecretCapture: boolean;
    mcpOAuth: boolean;
  };
  account: AccountView;
  skillCatalog: SkillCatalogView;
  skillManagement: SkillManagementView;
  mcp: McpManagementView;
  workspaces: WorkspaceView[];
  scheduledTasks: ScheduledTaskView[];
  tasks: TaskView[];
};

export type WorkspaceView = {
  id: string;
  epoch: string;
  kind: "manual" | "automatic";
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
  selectionRevision: string | null;
  skills: {
    skillId: string;
    invocationName: string;
    displayName: string;
    description: string;
    argumentNames: string[];
    maxValues: number;
    enabled: boolean;
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
  enablementAvailability: WorkbenchSnapshot["capabilities"]["skillManagementHealth"];
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
    skillPolicyKey: string | null;
    invocationName: string;
    displayName: string;
    description: string;
    argumentNames: string[];
    maxValues: number;
    canExport: boolean;
    canReimport: boolean;
    canUninstall: boolean;
    canRetry: boolean;
    enabled: boolean | null;
    enablementState: "inherit" | "enabled" | "disabled" | null;
    canSetEnabled: boolean;
    selectionRevision: string | null;
    issueCodes: SkillCatalogView["issues"][number]["code"][];
  }[];
};

export const mcpAvailabilities = ["unavailable", "ready", "degraded"] as const;
export const mcpManagementHealthValues = [
  "unavailable",
  "ready",
  "recovery_required",
  "outcome_unknown",
] as const;
export const mcpRuntimeAlignmentValues = [
  "current",
  "restart_required",
  "unknown",
] as const;
export const mcpConfigurationApplyValues = [
  "idle",
  "applying",
  "failed",
] as const;
export const mcpRuntimeStatusValues = [
  "not_loaded",
  "ready",
  "disabled",
  "needs_authentication",
  "unreachable",
  "invalid_catalog",
] as const;
export const mcpNewTaskAccessValues = [
  "available",
  "not_allowed",
  "restart_required",
  "unavailable",
] as const;
export const mcpAuthorizationStatusValues = [
  "not_required",
  "missing_static_secret",
  "missing_oauth_client_secret",
  "client_registration_required",
  "consent_required",
  "authorizing",
  "ready",
  "reauth_required",
  "capability_unavailable",
] as const;
export const mcpAuthorizationPhaseValues = [
  "discovering",
  "awaiting_consent",
  "registering",
  "awaiting_browser",
  "exchanging",
  "refreshing",
  "cancelling",
] as const;

export type McpSecretSlot =
  | { kind: "stdio_environment" | "http_header"; name: string }
  | { kind: "oauth_client_secret" };

export type McpStdioConnectionInput = {
  displayName: string;
  negotiation: "automatic" | "modern_only" | "compat_only";
  timeoutMs: number;
  command: string;
  arguments: string[];
  cwd: string | null;
  environmentNames: string[];
};

export type McpHttpConnectionInput = {
  displayName: string;
  negotiation: "automatic" | "modern_only" | "compat_only";
  timeoutMs: number;
  endpoint: string;
  authMode: "none" | "static" | "oauth";
  headerNames: string[];
  registration:
    | null
    | { kind: "automatic" }
    | {
        kind: "pre_registered";
        clientId: string;
        tokenEndpointAuthMethod:
          "none" | "client_secret_basic" | "client_secret_post";
      };
};

export type McpManagementView = {
  availability: (typeof mcpAvailabilities)[number];
  managementHealth: (typeof mcpManagementHealthValues)[number];
  operation: "idle" | "saving" | "refreshing";
  configurationApply: (typeof mcpConfigurationApplyValues)[number];
  authorizationOperation:
    | { kind: "idle" }
    | {
        kind: (typeof mcpAuthorizationPhaseValues)[number];
        serverId: string;
        operationId: string;
      };
  desiredGeneration: string | null;
  runtimeAlignment: (typeof mcpRuntimeAlignmentValues)[number];
  redacted: boolean;
  servers: {
    id: string;
    displayName: string;
    namespace: string;
    transport: "stdio" | "streamable_http";
    authMode: "none" | "static" | "oauth";
    negotiation: "automatic" | "modern_only" | "compat_only";
    timeoutMs: number;
    connection:
      | null
      | {
          kind: "stdio";
          command: string;
          arguments: string[];
          cwd: string | null;
          environment: { name: string; status: "missing" | "set" }[];
        }
      | {
          kind: "streamable_http";
          endpoint: string;
          headers: { name: string; status: "missing" | "set" }[];
          registrationKind: "none" | "automatic" | "pre_registered";
          clientId: string | null;
          tokenEndpointAuthMethod:
            "none" | "client_secret_basic" | "client_secret_post" | null;
          clientSecretStatus: "not_required" | "missing" | "set";
        };
    approvalStatus: "unapproved" | "approved";
    authorizationStatus: (typeof mcpAuthorizationStatusValues)[number];
    desiredEnabled: boolean;
    runtimeStatus: (typeof mcpRuntimeStatusValues)[number];
    newTaskAccess: (typeof mcpNewTaskAccessValues)[number];
    safeDiagnostic: string;
    connectionTest: {
      status: "untested" | "testing" | "connected" | "failed";
      toolCount: number;
      issueCount: number;
    };
    tools: {
      name: string;
      discovered: boolean;
      desiredAllowed: boolean;
      availableToNewTasks: boolean;
    }[];
  }[];
};

export type McpMutationResult = {
  outcome:
    | "unchanged"
    | "saved"
    | "saved_recovery_required"
    | "stale_generation"
    | "rejected"
    | "indeterminate"
    | "busy"
    | "cancelled"
    | "capability_unavailable";
  desiredGeneration: string | null;
};

export type McpAuthorizationResult = {
  outcome:
    | "started"
    | "busy"
    | "rejected"
    | "stale_generation"
    | "capability_unavailable";
  operationId: string | null;
};

export type McpAuthorizationCancelResult = {
  outcome:
    | "cancelled"
    | "saved"
    | "saved_recovery_required"
    | "rejected"
    | "indeterminate"
    | "capability_unavailable";
};

export type McpRefreshResult = {
  outcome: "started" | "busy" | "unavailable" | "shutting_down" | "rejected";
};

export type McpConfigurationApplyResult = {
  outcome: "started" | "busy" | "unavailable" | "rejected";
};

export type McpConnectionTestResult = {
  outcome:
    | "started"
    | "busy"
    | "stale_generation"
    | "needs_authentication"
    | "rejected"
    | "unavailable";
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

export type TaskWorkspaceIntent =
  | { kind: "automatic" }
  | {
      kind: "manual";
      workspaceId: string;
      expectedWorkspaceEpoch: string;
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
  | "skill_unavailable"
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

export type TaskModelSelectionReason =
  | "model_changed"
  | "stale_catalog"
  | "task_unavailable"
  | "task_busy"
  | "shutting_down"
  | "capacity_reached";

export type TaskModelSelectionResult =
  | {
      accepted: true;
      taskId: string;
      model: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: string;
      model: null;
      reason: TaskModelSelectionReason;
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

export type TaskRestoreReason =
  | "binding_changed"
  | "task_unavailable"
  | "recovery_unavailable"
  | "capacity_reached"
  | "shutting_down";

export type TaskRestoreResult =
  | {
      accepted: true;
      taskId: string;
      attemptId: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: string;
      attemptId: null;
      reason: TaskRestoreReason;
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

export type SkillEnablementResult =
  | { applied: true; selectionRevision: string; reason: null }
  | {
      applied: false;
      selectionRevision: null;
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
  | { kind: "permission"; permission: PermissionChoice }
  | { kind: "answers"; answers: string[][] };
