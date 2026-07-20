export const WORKBENCH_SCHEMA_VERSION = 6 as const;

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

export type AccountView = {
  sessionState: AccountSessionState;
  executionState: ExecutionState;
  operation: AccountOperation;
  accountId: string;
  displayName: string;
  apiKeys: { id: string; name: string; suffix: string }[];
  models: { id: string; displayName: string }[];
  selectedApiKeyId: string;
  selectedModel: string;
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
  title: string;
  workspaceRoot: string;
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
  schemaVersion: typeof WORKBENCH_SCHEMA_VERSION;
  revision: string;
  account: AccountView;
  tasks: TaskView[];
};

export type HostSignal = {
  sequence: number;
};

export type WorkspaceChoice =
  | { selected: false }
  | { selected: true; workspaceRoot: string; grant: string };

export type UiResponsePayload =
  | { kind: "permission"; permission: "deny_once" | "allow_once" }
  | { kind: "answers"; answers: string[] };
