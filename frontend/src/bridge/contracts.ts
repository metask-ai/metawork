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

export type RunView = {
  id: string;
  phase: RunPhase;
  user: string;
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
  cause:
    | "user_cancel"
    | "timeout"
    | "session_close"
    | "app_shutdown"
    | "event_pipeline_failure"
    | "queue_capacity_failure"
    | "ui_pipeline_failure"
    | "dependency_contract_failure"
    | null;
  usage: {
    input: string;
    output: string;
    cacheRead: string;
    cacheCreation: string;
  };
  tools: ToolView[];
};

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
  lifecycle: "open" | "closing" | "closed";
  continuationAvailable: boolean;
  archived: boolean;
  closeFailed: boolean;
  currentRunId: string;
  currentRunPhase: NonTerminalRunPhase | null;
  lastRunOutcome: RunView["outcome"];
  cause: RunView["cause"];
  runs: RunView[];
  pendingUi: PendingUi | null;
  uiHistory: UiRecord[];
};

export type WorkbenchSnapshot = {
  revision: string;
  capabilities: {
    taskHistoryPersistence: boolean;
    conversationRecovery: boolean;
    executionRebind: boolean;
    structuredPlan: boolean;
    typedOutputs: boolean;
    typedFileChanges: boolean;
    persistentWorkspacePermissions: boolean;
  };
  account: AccountView;
  selectedWorkspaceId: string | null;
  workspaces: WorkspaceView[];
  tasks: TaskView[];
};

export type WorkspaceView = {
  id: string;
  epoch: string;
  displayName: string;
  canonicalRoot: string;
  redacted: boolean;
  authorization: "available" | "removing" | "reauthorization_required";
  lastRemovalFailure: "task_close_failed" | null;
  recentOrder: string;
  signals: {
    running: number;
    attention: number;
    failedOrInterrupted: number;
  };
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
  | "workspace_removing"
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

export type HostSignal = {
  sequence: number;
};

export type WorkspaceChoice =
  { selected: false } | { selected: true; workspaceId: string };

export type UiResponsePayload =
  | { kind: "permission"; permission: "deny_once" | "allow_once" }
  | { kind: "answers"; answers: string[][] };
