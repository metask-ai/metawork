import {
  approvalFailureReasons,
  type TaskApprovalResultWire,
  type UpdateViewWire,
} from "./generated-wire.ts";
export type UpdateView = UpdateViewWire;
export { approvalFailureReasons };
export type AccountState =
  "checking" | "signed_out" | "authorizing" | "authenticated";
export type ModelsCatalogState =
  | "needs_authentication"
  | "loading"
  | "choosing"
  | "ready"
  | "failed"
  | "unavailable";
export type NewTaskAdmissionState = "unavailable" | "ready" | "replacing";
export type NewTaskAdmissionReason =
  | "none"
  | "custom_provider_persistence_unavailable"
  | "credential_unavailable"
  | "invalid_candidate"
  | "resource_exhausted"
  | "schedule_persistence_unavailable"
  | "schedule_persistence_failed"
  | "schedule_persistence_outcome_unknown";
export type AccountErrorCode =
  | "none"
  | "invalid_command"
  | "invalid_state"
  | "operation_in_progress"
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
  | "metask_platform_unsupported"
  | "credential_store_read_failed"
  | "credential_store_write_failed"
  | "credential_store_delete_failed"
  | "generation_mismatch"
  | "recovery_state_invalid"
  | "refresh_schedule_failed"
  | "local_resource_exhausted"
  | "account_operation_failed";
export type ExecutionCommandErrorCode =
  | "none"
  | "operation_in_progress"
  | "user_cancelled"
  | "generation_mismatch"
  | "no_models"
  | "local_resource_exhausted"
  | "credential_store_write_failed"
  | "custom_provider_invalid"
  | "custom_provider_not_found"
  | "custom_provider_capture_unavailable"
  | "custom_provider_persistence_unavailable"
  | "custom_model_test_unavailable";
export type Protocol =
  | "openai_responses"
  | "anthropic_messages"
  | "openai_chat_completions"
  | "gemini_native";
export const builtinProviderIds = [
  "deepseek",
  "kimi",
  "minimax",
  "glm",
] as const;
export type BuiltinProviderId = (typeof builtinProviderIds)[number];
export type BuiltinProviderPresetView = {
  id: BuiltinProviderId;
  displayName: string;
  protocol: Protocol;
  defaultBaseUrl: string;
  apiKeyUrl: string;
  documentationUrl: string;
};
export const permissionProfiles = ["approval_required", "full_access"] as const;
export type PermissionProfile = (typeof permissionProfiles)[number];
export const approvalModes = ["manual", "auto_review", "full_access"] as const;
export type ApprovalMode = (typeof approvalModes)[number];
export type PermissionInteraction = "interactive" | "noninteractive";
export type CustomProviderState = "configuring" | "ready" | "disabled";
export type CustomModelTestStatus =
  "untested" | "testing" | "connected" | "failed";
export type CustomProviderCredentialStatus =
  "missing" | "ready" | "invalid" | "capture_unavailable";
export type ModelMetadataProvenance =
  "unknown" | "user_declared" | "provider_declared" | "runtime_verified";
export type CustomProviderView = {
  id: string;
  builtinProviderId: BuiltinProviderId | null;
  displayName: string;
  protocol: Protocol;
  normalizedBaseUrl: string;
  state: CustomProviderState;
  credentialStatus: CustomProviderCredentialStatus;
  enabled: boolean;
  models: {
    id: string;
    displayName: string;
    metadata: ModelMetadata;
    metadataProvenance: ModelMetadataProvenance;
    testStatus: CustomModelTestStatus;
    ready: boolean;
  }[];
  providerRevision: string;
  sourceGeneration: string;
  catalogGeneration: string;
};
export type ModelRef = {
  sourceId: string;
  modelId: string;
};
/** Server declarations only; null means unknown, not unsupported. */
export type ModelMetadata = {
  maxInputTokens: string | null;
  maxOutputTokens: string | null;
  capabilities: {
    textInput: boolean | null;
    audioInput: boolean | null;
    videoInput: boolean | null;
    output: {
      text: boolean | null;
      image: boolean | null;
      audio: boolean | null;
      video: boolean | null;
      embedding: boolean | null;
    };
    imageInput: boolean | null;
    pdfInput: boolean | null;
    batch: boolean | null;
    citations: boolean | null;
    codeExecution: boolean | null;
    structuredOutputs: boolean | null;
    thinking: {
      supported: boolean | null;
      adaptive: boolean | null;
      enabled: boolean | null;
    };
    effort: {
      supported: boolean | null;
      low: boolean | null;
      medium: boolean | null;
      high: boolean | null;
      max: boolean | null;
    };
    contextManagement: {
      supported: boolean | null;
      clearThinking20251015: boolean | null;
      clearToolUses20250919: boolean | null;
      compact20260112: boolean | null;
    };
  };
};
export type AccountView = {
  state: AccountState;
  canCancel: boolean;
  accountId: string;
  displayName: string;
  emailHint: string;
  phoneHint: string;
  concurrencyLimit: number | null;
  errorCode: AccountErrorCode;
  safeDiagnostic: string;
  summary: {
    operation: "idle" | "refreshing";
    usageEligibility: "unknown" | "disabled" | "enabled";
    wallet: {
      availability: "unavailable" | "loading" | "ready" | "stale";
      balanceU: string | null;
      syncedAt: string | null;
      errorCode: AccountErrorCode;
      safeDiagnostic: string;
    };
    usage: {
      availability: "unavailable" | "loading" | "ready" | "stale";
      today: {
        inputTokens: string;
        outputTokens: string;
        cacheCreationTokens: string;
        cacheReadTokens: string;
        totalTokens: string;
        actualCostU: string;
      } | null;
      total: {
        totalTokens: string;
        actualCostU: string;
      } | null;
      syncedAt: string | null;
      errorCode: AccountErrorCode;
      safeDiagnostic: string;
    };
    history: {
      availability: "unavailable" | "loading" | "ready" | "stale";
      startDate: string | null;
      endDate: string | null;
      days: Array<{
        date: string;
        inputTokens: string;
        outputTokens: string;
        cacheCreationTokens: string;
        cacheReadTokens: string;
        totalTokens: string;
        actualCostU: string;
      }>;
      syncedAt: string | null;
      errorCode: AccountErrorCode;
      safeDiagnostic: string;
    };
  };
};
export type ModelsErrorCode =
  | "none"
  | "authorization_unavailable"
  | "persistence_unavailable"
  | "catalog_unavailable"
  | "catalog_invalid"
  | "catalog_too_large"
  | "no_models"
  | "operation_in_progress"
  | "local_resource_exhausted";
export type CatalogModelView = {
  id: string;
  displayName: string;
  metadata: ModelMetadata;
  metadataProvenance: ModelMetadataProvenance;
};
export type ModelsView = {
  availability: ModelsCatalogState;
  persistenceHealth: "ready" | "recovery_required" | "unavailable";
  providers: {
    id: string;
    displayName: string;
    recommended: boolean;
    catalogState: ModelsCatalogState;
    principalRef: string;
    models: CatalogModelView[];
    catalogGeneration: string;
    sourceGeneration: string;
    errorCode: ModelsErrorCode;
    safeDiagnostic: string;
  }[];
  metaskSelection: ModelRef | null;
  metaskSelectionRevision: string;
  defaultSelection: ModelRef | null;
  selectionRevision: string;
  operation: "idle" | "refreshing_catalog";
  errorCode: ModelsErrorCode;
  builtinProviderPresets: BuiltinProviderPresetView[];
  customProviders: CustomProviderView[];
};
export type NewTaskAdmissionView = {
  available: boolean;
  reason: NewTaskAdmissionReason;
  activeModelRef: ModelRef | null;
  activeProtocol: Protocol | null;
  activeGeneration: string;
  activeSelectionRevision: string;
  state: NewTaskAdmissionState;
};
export type AccountCommandResult = {
  accepted: boolean;
  errorCode: AccountErrorCode;
  attemptId: string | null;
};
export type ExecutionCommandResult = {
  accepted: boolean;
  errorCode: ExecutionCommandErrorCode;
  attemptId: null;
};
export type PresentationAnchor = {
  afterOutputCount: number;
  presentationOrder: string;
};
export type FileReferenceView = {
  presentationAnchor?: PresentationAnchor | null;
  generatedImage?: true;
  id: string;
  title: string;
  displayPath: string;
};
export type PreviewMediaType = "image/png" | "image/jpeg" | "image/webp";
export type FilePreviewImage = {
  readonly id: string;
  readonly mediaType: PreviewMediaType;
  readonly width: number;
  readonly height: number;
  readonly src: string;
  readonly securityEpoch: string;
  valid: () => boolean;
  subscribe: (changed: () => void) => () => void;
  beginDecode: (signal: AbortSignal) => Promise<() => void>;
};
export type FilePreview = {
  image?: FilePreviewImage;
  state:
    "ready" | "missing" | "restricted" | "unsupported" | "changing" | "error";
  content: string;
  truncated: boolean;
  redacted: boolean;
  reason?: "capacity" | "image_limit" | "animated_image";
  release?: () => void;
};
export type FilePreviewResponse = Omit<
  FilePreview,
  "image" | "state" | "reason" | "release"
> & {
  state: FilePreview["state"] | "busy" | "stale_security";
  reason?: "image_limit" | "animated_image";
  image?: {
    token: string;
    mediaType: PreviewMediaType;
    sizeBytes: number;
    width: number;
    height: number;
    chunkBytes: number;
    securityEpoch: string;
  };
};
export type FilePreviewLoadOptions = {
  signal?: AbortSignal;
  priority?: "interactive" | "prefetch";
};
export type FileChangeView = {
  id: string;
  order: string;
  kind: "created" | "modified" | "deleted" | "moved";
  status: "applied" | "partial";
  displayPath: string;
  fromDisplayPath: string | null;
  beforeBytes: string;
  afterBytes: string;
  diffAvailable: boolean;
  diffComplete: boolean;
  redacted: boolean;
};
export type RunFileChanges = {
  observation: "collecting" | "complete" | "incomplete";
  changes: FileChangeView[];
};
export type FileChangeDiffResult =
  | {
      status: "ready";
      content: string;
      complete: boolean;
      redacted: boolean;
    }
  | {
      status: "unavailable";
      reason: "not_recorded" | "capacity" | "missing" | "corrupt";
      content: "";
    };
export type ToolPresentation =
  | {
      kind: "read";
      target: string;
      offset: string | null;
      limit: string | null;
    }
  | {
      kind: "write" | "edit";
      target: string;
    }
  | {
      kind: "glob";
      pattern: string;
      scope: string | null;
    }
  | {
      kind: "grep";
      pattern: string;
      scope: string | null;
      include: string | null;
    }
  | {
      kind: "bash_output";
      jobId: string;
      result: {
        status: "running" | "exited" | "killed";
        stdout: string;
        stderr: string;
        stdoutIncomplete: boolean;
        stderrIncomplete: boolean;
      } | null;
    }
  | {
      kind: "kill_shell";
      jobId: string;
    }
  | {
      kind: "web_search";
      query: string;
    }
  | {
      kind: "web_fetch";
      url: string;
      prompt: string | null;
      result: {
        url: string;
        bytes: string | null;
        content: string;
      } | null;
    };
export type ToolView = {
  bash: {
    command: string | null;
    description: string | null;
    result: {
      exitCode: number;
      stdout: string;
      stderr: string;
      stdoutIncomplete: boolean;
      stderrIncomplete: boolean;
    } | null;
  } | null;
  presentation: ToolPresentation | null;
  errorDetail: string | null;
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
    }
  | {
      kind: "multimodal";
      text: string;
      attachmentTokens: string[];
    };
export type AttachmentDescriptor =
  | {
      token: string;
      kind: "image";
      format: "png" | "jpeg" | "webp";
      displayName: string;
      sizeBytes: string;
    }
  | {
      token: string;
      kind: "file";
      displayName: string;
      sizeBytes: string;
    };
export type AttachmentChooseResult =
  | {
      status: "cancelled";
    }
  | {
      status: "ready";
      attachments: AttachmentDescriptor[];
    }
  | {
      status: "rejected";
      reason:
        | "unsupported_type"
        | "file_too_large"
        | "text_file_too_large"
        | "too_many_files"
        | "staging_capacity"
        | "read_failed"
        | "file_changed"
        | "shutting_down";
    };
export type AttachmentAddResult =
  | AttachmentChooseResult
  | {
      status: "rejected";
      reason:
        "invalid_transfer" | "stale_transfer" | "input_busy" | "cleanup_failed";
    };
export type AttachmentAddAcceptance =
  | {
      status: "accepted";
    }
  | Exclude<
      AttachmentAddResult,
      {
        status: "ready";
      }
    >;
export type AttachmentAddBeginResult =
  | AttachmentAddResult
  | {
      status: "accepted";
    };
export type AttachmentCancelResult =
  | {
      status: "cleaned";
      released: boolean;
    }
  | {
      status: "cleanup_failed";
    };
export type AttachmentReceiveResult =
  | AttachmentChooseResult
  | {
      status: "rejected";
      reason: "invalid_transfer" | "stale_transfer";
    };
export type ScheduledTaskRecurrence =
  | {
      kind: "once";
      atUnixSeconds: string;
    }
  | {
      kind: "interval";
      startAtUnixSeconds: string;
      everySeconds: string;
    };
export type ScheduledTaskBinding = {
  modelRef: ModelRef;
  sourceGeneration: string;
  selectionRevision: string;
  protocol: Protocol;
};
export type ScheduledTaskStoredBinding = {
  status: "bound";
} & ScheduledTaskBinding;
export type ScheduledTaskView = {
  id: string;
  epoch: string;
  title: string;
  titleRedacted: boolean;
  permissionProfile: PermissionProfile;
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
    | "permission_required"
    | null;
  binding: ScheduledTaskStoredBinding;
  input: {
    kind: "text";
    text: string;
    redacted: boolean;
  };
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
      | "unavailable"
      | null;
  }>;
};
export type ScheduledTaskMutation = {
  title: string;
  binding: ScheduledTaskBinding;
  permissionProfile: PermissionProfile;
  input: Extract<
    TaskRunInput,
    {
      kind: "text";
    }
  >;
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
    }
  | {
      kind: "multimodal";
      text: string | null;
      attachments: Array<
        | {
            kind: "image";
            format: "png" | "jpeg" | "webp";
            displayName: string;
            sizeBytes: string;
            redacted: boolean;
          }
        | {
            kind: "file";
            displayName: string;
            sizeBytes: string;
            redacted: boolean;
          }
      >;
      redacted: boolean;
    };
export const runCauses = [
  "user_cancel",
  "timeout",
  "session_close",
  "app_shutdown",
  "event_pipeline_failure",
  "event_payload_too_large",
  "queue_capacity_failure",
  "ui_pipeline_failure",
  "permission_required",
  "agent_failure",
  "provider_failure",
  "tool_failure",
  "image_input_unsupported",
  "dependency_contract_failure",
  "stale_catalog",
  "skill_not_found",
  "invalid_skill_arguments",
  "skill_policy_violation",
  "skill_unavailable",
  "resource_limit",
] as const;
export type RunCause = (typeof runCauses)[number];
export type RunOutcome =
  | "completed"
  | "stopped"
  | "cancelled"
  | "interrupted"
  | "failed"
  | "dependency_contract_failure";
export type RunTerminal = {
  outcome: RunOutcome;
  cause: RunCause | null;
  diagnosticDisposition: "absent" | "withheld";
};
export type RunOutput = {
  commentary: string[];
  response: string;
  responseKind: "final" | "partial" | null;
  provisional: string;
  redacted: boolean;
  provisionalRedacted: boolean;
};
export type RunActivity =
  | {
      kind: "queued";
    }
  | {
      kind: "starting";
    }
  | {
      kind: "waiting_model";
    }
  | {
      kind: "thinking";
    }
  | {
      kind: "writing_response";
    }
  | {
      kind: "executing_tools";
      inFlight: string | null;
    }
  | {
      kind: "retrying_provider";
      attempt: string | null;
      max: string | null;
      delayMs: string | null;
    }
  | {
      kind: "waiting_user";
    }
  | {
      kind: "compacting_context";
    }
  | {
      kind: "finalizing";
    }
  | {
      kind: "stopping";
    };
export type ConversationCoverage = "included" | "excluded";
export const outputActionStates = [
  "ready",
  "revealed",
  "saved",
  "save_failed",
  "target_changed",
  "cleanup_failed",
  "busy",
  "missing",
  "restricted",
  "changed",
  "too_large",
  "cancelled",
  "timed_out",
  "stale_security",
  "unavailable",
  "failed",
] as const;
export type OutputActionState = (typeof outputActionStates)[number];
export type OutputAction = "check" | "reveal" | "save";
export type OutputActionHandler = (
  taskId: string,
  runId: string,
  outputId: string,
  action: OutputAction,
  signal: AbortSignal,
) => Promise<OutputActionState>;
export type DeliveredOutputView = {
  id: string;
  displayPath: string;
  sizeBytes: string;
  redacted: boolean;
};
export type RunView = {
  submission: InputSubmission | null;
  elapsedMs: string | null;
  submittedAtUnixMs: string | null;
  finishedAtUnixMs: string | null;
  id: string;
  conversationCoverage: ConversationCoverage;
  phase: RunPhase;
  permissionProfile: PermissionProfile;
  permissionInteraction: PermissionInteraction;
  execution: {
    generation: string;
    protocol: Protocol;
    model: string;
  };
  input: RunInputView;
  additionalInputs: AdditionalInputView[];
  output: RunOutput;
  activity: RunActivity | null;
  terminal: RunTerminal | null;
  usage: {
    input: string;
    output: string;
    cacheRead: string;
    cacheCreation: string;
  };
  tools: ToolView[];
  fileChanges: RunFileChanges | null;
  outputs: DeliveredOutputView[];
};
export type ConversationContext = {
  pressure: {
    sourceRunId: string;
    currentTokens: string;
    warningThreshold: string;
    autoCompactThreshold: string;
    blockingLimit: string;
    severity: "warning" | "critical";
  } | null;
  lastAutoCompact: {
    sourceRunId: string;
    dropped: string;
    kept: string;
    beforeTokens: string;
    afterTokens: string;
  } | null;
};
export const compactPhases = [
  "queued",
  "compacting",
  "stopping",
  "compacted",
  "no_change",
  "degraded",
  "aborted",
  "interrupted",
  "failed",
] as const;
export type CompactPhase = (typeof compactPhases)[number];
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
  conversationCoverage: ConversationCoverage;
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
  | {
      kind: "run";
      id: string;
    }
  | {
      kind: "compact";
      id: string;
    }
  | {
      kind: "restore";
      id: string;
    };
export type PendingUi = {
  requestId: string;
  runId: string;
  order: string;
  redacted: boolean;
  kind: "permission";
  toolNamespace: "builtin" | "host" | "mcp";
  tool: string;
  toolBinding: string;
  args: string;
  presentation:
    | { kind: "command"; command: string; description: string | null }
    | { kind: "read" | "write" | "edit" | "web_fetch"; target: string }
    | null;
  availableChoices: PermissionChoice[];
  policyGeneration: string;
  canonicalArgumentsDigest: string;
  candidate:
    | {
        ruleId: string;
        scope: "exact_arguments";
      }
    | {
        ruleId: string;
        scope: "file_target";
        target: string;
      }
    | null;
};
export type PermissionChoice =
  "deny_once" | "deny_session" | "allow_once" | "allow_session";
export type UiRecord = {
  answeredBy: "user" | "reviewer" | null;
  reviewReason: string | null;
  requestId: string;
  runId: string;
  order: string;
  kind: "permission";
  state:
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
  canonicalArgumentsDigest: string;
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
export type TaskMcpAuthority =
  | {
      kind: "ready";
      selection: "selected" | "none";
    }
  | {
      kind: "unavailable";
      selection: null;
    };
export type TaskModelSelectionAvailability =
  "available" | "catalog_loading" | "catalog_unavailable" | "task_unavailable";
export type ApprovalFailureReason = (typeof approvalFailureReasons)[number];
export type TaskApprovalChange = {
  revision: string;
  targetMode: ApprovalMode;
  state: "pending" | "recovering" | "outcome_unknown";
};
export type TaskApprovalResult = TaskApprovalResultWire &
  (
    | {
        outcome: "completed";
        reason: null;
      }
    | {
        outcome: "failed";
        reason: ApprovalFailureReason;
      }
  );
export const sendInputReasons = [
  "session_releasing",
  "session_capacity",
  "session_close_failed",
  "binding_changed",
  "binding_unavailable",
  "task_unavailable",
  "task_busy",
  "workspace_unavailable",
  "workspace_changed",
  "workspace_removing",
  "catalog_loading",
  "catalog_unavailable",
  "stale_catalog",
  "skill_not_found",
  "skill_unavailable",
  "invalid_skill_arguments",
  "missing_instruction",
  "unsupported_input",
  "unsupported_attachment",
  "capacity_reached",
  "shutting_down",
  "run_changed",
  "run_not_ready",
  "run_stopping",
  "too_late",
  "invalid_input",
  "resource_limit",
  "checkpoint_budget_required",
  "admission_failed",
  "continuation_cancelled",
  "combined_input_too_large",
  "checkpoint_failed",
  "schedule_failed",
] as const;
export type SendInputReason = (typeof sendInputReasons)[number];
export type SendInputResult = {
  operationId: string;
  taskId: string;
} & (
  | {
      outcome: "accepted";
      reason: null;
    }
  | {
      outcome: "rejected";
      reason: SendInputReason;
    }
);
export type InputSubmission = {
  presentationOrder: string | null;
  operationId: string;
  receivedAtUnixMs: string | null;
  anchorRunId: string | null;
  afterOutputCount: number;
};
export type WaitingInputView = {
  submission: InputSubmission;
  input: RunInputView;
  state: "waiting" | "failed" | "cancelled" | "interrupted";
  reason: SendInputReason | null;
  blockingTaskId?: string;
};
export type AdditionalInputView = {
  submission: InputSubmission | null;
  id: string;
  afterOutputCount: number;
  operationId: string;
  text: string;
  redacted: boolean;
  sequence: number | null;
  adoptedTurn: number | null;
  order: string | null;
  state:
    | "pending"
    | "adopted"
    | "unadopted"
    | "unknown"
    | "continuing"
    | "transferred";
  transferredToRunId: string | null;
  continuationReason: SendInputReason | null;
};
export type TaskView = {
  inputReady: boolean;
  inputAcceptance: {
    available: boolean;
    reason: SendInputReason | null;
  };
  inputSubmissions: WaitingInputView[];
  approvalMode: ApprovalMode;
  approvalRevision: string;
  availableApprovalModes: ApprovalMode[];
  approvalChange: TaskApprovalChange | null;
  approvalResult: TaskApprovalResult | null;
  permissionReviewState: "idle" | "reviewing" | "needs_user";
  permissionReviewExplanation: {
    cause:
      | "unavailable"
      | "reviewer_concern"
      | "context_incomplete"
      | "timeout"
      | "call_failed"
      | "invalid_response"
      | "capacity"
      | "unsupported_tool"
      | "input_changed"
      | "state_changed";
    reason: string | null;
  } | null;
  id: string;
  recentOrder: string;
  title: string;
  workspaceId: string;
  permissionProfile: PermissionProfile;
  binding: {
    epoch: string;
    availability: "available" | "unavailable";
    protocol: Protocol;
    model: string;
    executionGeneration: string;
    unavailableReason: "runtime_detached" | null;
  };
  modelIntent: {
    modelRef: ModelRef;
    selectionRevision: string;
    state: "committed" | "outcome_unknown";
  } | null;
  modelSelectionAvailability: TaskModelSelectionAvailability;
  mcpAuthority: TaskMcpAuthority;
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
    | "execution_rebind_required"
    | "workspace_unavailable"
    | "authority_unavailable"
    | "runtime_unavailable"
    | "history_read_only"
    | null;
  continuationRecoveryAvailable: boolean;
  archived: boolean;
  unreadCompletionRunId: string | null;
  restorePermission: {
    restoredRules: string;
    invalidatedRules: string;
  } | null;
  activeOperation: ActiveOperation | null;
  currentRunId: string;
  currentRunPhase: NonTerminalRunPhase | null;
  context: ConversationContext;
  runs: RunView[];
  compacts: CompactView[];
  pendingUi: PendingUi | null;
  uiHistory: UiRecord[];
};
export type SearchCursor = {
  revision: string;
  securityEpoch: string;
  task: string;
  run: string;
  part: string;
  offset: string;
};
export type SearchHit = {
  taskId: string;
  runId: string | null;
  part: string;
  kind: "task" | "instruction" | "completion";
  detail: string;
};
export type SearchPage = {
  stale: boolean;
  results: SearchHit[];
  nextCursor: SearchCursor | null;
};
export type ViewScope = {
  taskId: string | null;
  beforeRunId: string | null;
  runLimit: number;
  management: "none" | "skills" | "mcp" | "schedules";
  search: boolean;
  searchQuery: string;
  searchCursor: SearchCursor | null;
  receipts: {
    taskId: string;
    operationId: string;
  }[];
};
export const initialViewScope: ViewScope = {
  taskId: null,
  beforeRunId: null,
  runLimit: 4,
  management: "none",
  search: false,
  searchQuery: "",
  searchCursor: null,
  receipts: [],
};
export function sameViewPageScope(a: ViewScope, b: ViewScope): boolean {
  return (
    a.taskId === b.taskId &&
    a.beforeRunId === b.beforeRunId &&
    a.runLimit === b.runLimit &&
    a.management === b.management &&
    a.search === b.search &&
    a.searchQuery === b.searchQuery &&
    JSON.stringify(a.searchCursor) === JSON.stringify(b.searchCursor)
  );
}
export function sameViewScope(a: ViewScope, b: ViewScope): boolean {
  return (
    sameViewPageScope(a, b) &&
    a.receipts.length === b.receipts.length &&
    a.receipts.every(
      (query, index) =>
        query.taskId === b.receipts[index]!.taskId &&
        query.operationId === b.receipts[index]!.operationId,
    )
  );
}
export function cloneViewScope(scope: ViewScope): ViewScope {
  return {
    ...scope,
    searchCursor: scope.searchCursor ? { ...scope.searchCursor } : null,
    receipts: scope.receipts.map((query) => ({ ...query })),
  };
}
export type RunManifest = Pick<
  RunView,
  "id" | "phase" | "permissionProfile" | "permissionInteraction" | "terminal"
> & {
  contentVersion: string;
};
export type TaskSummary = Pick<
  TaskView,
  | "id"
  | "recentOrder"
  | "title"
  | "workspaceId"
  | "archived"
  | "lifecycle"
  | "deletionStatus"
  | "permissionReviewState"
  | "currentRunPhase"
  | "activeOperation"
  | "unreadCompletionRunId"
> & {
  historyReadOnly: boolean;
  activeCompactPhase: CompactView["phase"] | null;
  lastCompactPhase: CompactView["phase"] | null;
  latestTerminal: Pick<
    NonNullable<RunView["terminal"]>,
    "outcome" | "cause"
  > | null;
};
export const viewBlockNames = [
  "context",
  "workspaces",
  "taskIndex",
  "taskPage",
  "historyPage",
  "management",
  "searchIndex",
] as const;
export type ViewBlockName = (typeof viewBlockNames)[number];
export type ViewVersions = Record<ViewBlockName, string>;
export const emptyViewVersions: ViewVersions = {
  context: "0",
  workspaces: "0",
  taskIndex: "0",
  taskPage: "0",
  historyPage: "0",
  management: "0",
  searchIndex: "0",
};
export type WorkbenchSnapshot = {
  updates: UpdateView;
  revision: string;
  blockVersions: ViewVersions;
  securityEpoch: string;
  historyEpoch: string;
  scope: ViewScope;
  taskIndex: TaskSummary[];
  receipts: {
    taskId: string;
    operationId: string;
    observed: boolean;
  }[];
  searchIndex: SearchPage | null;
  taskPage: {
    beforeRunId: string | null;
    nextBeforeRunId: string | null;
    runManifest: RunManifest[];
    task: TaskView;
  } | null;
  historyPage: {
    beforeRunId: string;
    nextBeforeRunId: string | null;
    runs: RunView[];
  } | null;
  automaticWorkspaceRoot: {
    generation: string;
    mode: "system_default" | "custom" | null;
    canonicalRoot: string | null;
    health:
      | "ready"
      | "path_unavailable"
      | "persistence_unavailable"
      | "read_failed"
      | "corrupt"
      | "write_failed"
      | "outcome_unknown";
    redacted: boolean;
    canChoose: boolean;
    canReset: boolean;
    canRetry: boolean;
  };
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
    taskHistoryRecoveryAvailable: boolean;
    /** Saved Tasks this version cannot open; kept unchanged on disk. */
    retainedTaskHistoryCount: string;
    conversationRecovery: boolean;
    executionRebind: boolean;
    structuredPlan: boolean;
    typedOutputs: boolean;
    typedFileChanges: boolean;
    persistentWorkspacePermissions: boolean;
    permissionProfiles: boolean;
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
    scheduledTaskRecoveryAvailable: boolean;
    backgroundScheduleWake: boolean;
    localSkillManagement: boolean;
    skillManagementHealth:
      | "unavailable"
      | "ready"
      | "read_failed"
      | "corrupt"
      | "write_failed"
      | "outcome_unknown";
    customProviderManagement: boolean;
    customProviderSecretCapture: boolean;
    customModelTest: boolean;
    mcpManagement: boolean;
    mcpConnectionApproval: boolean;
    mcpSecretCapture: boolean;
    mcpSecretMaxBytes: number;
    mcpOAuth: boolean;
    attachments: {
      enabled: boolean;
      imageFormats: Array<"png" | "jpeg" | "webp">;
      maxFiles: string;
      maxFileBytes: string;
      maxStagedBytes: string;
    };
  };
  permissions: {
    availableModes: ApprovalMode[];
    defaultMode: ApprovalMode;
    availableProfiles: PermissionProfile[];
    defaultProfile: PermissionProfile;
  };
  account: AccountView;
  models: ModelsView;
  newTaskAdmission: NewTaskAdmissionView;
  skillCatalog: SkillCatalogView;
  skillManagement: SkillManagementView | null;
  mcp: McpManagementView | null;
  workspaces: WorkspaceView[];
  scheduledTasks: ScheduledTaskView[] | null;
  tasks: TaskView[];
};
export type AutomaticWorkspaceRootMutationResult = {
  outcome: "applied" | "cancelled";
};
export type PersistenceRecoveryOutcome =
  | "recovered"
  | "stale_revision"
  | "not_required"
  | "unavailable"
  | "failed"
  | "outcome_unknown"
  | "shutting_down";
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
  skillSourceDiscovery: SkillSourceDiscovery;
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
    skillPolicyKey: string;
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
export const skillSourceBrands = ["claude", "codex"] as const;
export type SkillSourceBrand = (typeof skillSourceBrands)[number];
export const skillSourceIds = [
  "compat.claude.user",
  "compat.claude.workspace",
  "compat.codex.user",
  "compat.codex.workspace",
] as const;
export type SkillSourceId = (typeof skillSourceIds)[number];
export const skillSourceHealthStates = [
  "unavailable",
  "ready",
  "read_failed",
  "corrupt",
  "missing",
  "unsupported_schema",
  "too_large",
  "write_failed",
  "outcome_unknown",
] as const;
export const skillSourceCheckStates = [
  "disabled",
  "checking",
  "missing",
  "checked",
  "error",
] as const;
export const skillSourceCheckReasons = [
  "unreadable",
  "unsupported_entry",
  "changed",
] as const;
export const skillSourceSettingsReasons = [
  "stale_revision",
  "busy",
  "source_settings_unavailable",
  "write_failed",
  "persistence_outcome_unknown",
  "stale_recovery_token",
  "recovery_not_allowed",
  "read_failed",
  "revision_exhausted",
  "shutting_down",
] as const;
export const skillOriginEcosystems = ["agents", "claude", "codex"] as const;
export const skillOriginScopes = ["personal", "project"] as const;
export type SkillSourceRootId =
  SkillSourceId | "agents.user.default" | "agents.workspace.default";
export type SkillSourceDiscovery =
  | {
      sourceId: SkillSourceRootId;
      state: (typeof skillSourceCheckStates)[number];
      reason: (typeof skillSourceCheckReasons)[number] | null;
    }[]
  | null;
export type SkillSourceSettings = {
  revision: string | null;
  health: (typeof skillSourceHealthStates)[number];
  entries: {
    sourceId: SkillSourceId;
    enabled: boolean | null;
    canSetEnabled: boolean;
  }[];
  recovery: {
    canReread: boolean;
    canReset: boolean;
    token: string | null;
  };
};
export type SkillSourceSettingsReason =
  (typeof skillSourceSettingsReasons)[number];
export type SkillSourceSettingsResult =
  | {
      applied: true;
      revision: string;
      reason: null;
    }
  | {
      applied: false;
      revision: null;
      reason: SkillSourceSettingsReason;
    };
export type SkillManagementView = {
  availability: WorkbenchSnapshot["capabilities"]["skillManagementHealth"];
  enablementAvailability: WorkbenchSnapshot["capabilities"]["skillManagementHealth"];
  sourceSettings: SkillSourceSettings;
  personalSourceDiscovery: SkillSourceDiscovery;
  assets: {
    installId: string | null;
    sourceKind: "local_package" | "local_directory" | "external";
    origin: {
      ecosystem: (typeof skillOriginEcosystems)[number];
      scope: (typeof skillOriginScopes)[number];
    } | null;
    scope:
      | {
          kind: "personal";
          workspaceId: null;
        }
      | {
          kind: "project";
          workspaceId: string;
        }
      | {
          kind: "external";
          workspaceId: null;
        };
    managementState:
      | "ready"
      | "pending_verification"
      | "recovery_required"
      | "externally_managed";
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
  | {
      kind: "stdio_environment" | "http_header";
      name: string;
    }
  | {
      kind: "oauth_client_secret";
    };
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
    | {
        kind: "automatic";
      }
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
    | {
        kind: "idle";
      }
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
          environment: {
            name: string;
            status: "missing" | "set";
          }[];
        }
      | {
          kind: "streamable_http";
          endpoint: string;
          headers: {
            name: string;
            status: "missing" | "set";
          }[];
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
  | "model_selection_changed"
  | "stale_catalog"
  | "capacity_reached"
  | "session_releasing"
  | "session_capacity"
  | "session_close_failed"
  | "shutting_down";
export type TaskCreateResult =
  | {
      accepted: true;
      taskId: string;
      bindingEpoch: string;
      mcpAuthority: TaskMcpAuthority;
      reason: null;
    }
  | {
      accepted: false;
      taskId: null;
      bindingEpoch: null;
      mcpAuthority: null;
      reason: TaskCreateReason;
      blockingTaskId?: string;
    };
export type TaskWorkspaceIntent =
  | {
      kind: "automatic";
    }
  | {
      kind: "manual";
      workspaceId: string;
      expectedWorkspaceEpoch: string;
    };
export type NewTaskModelSelectionIntent = {
  targetModelRef: ModelRef;
  expectedSourceGeneration: string;
  expectedCatalogGeneration: string;
};
export type TaskRunReason =
  | "binding_changed"
  | "binding_unavailable"
  | "task_unavailable"
  | "task_busy"
  | "workspace_unavailable"
  | "workspace_changed"
  | "workspace_removing"
  | "catalog_loading"
  | "catalog_unavailable"
  | "stale_catalog"
  | "skill_not_found"
  | "skill_unavailable"
  | "invalid_skill_arguments"
  | "missing_instruction"
  | "unsupported_attachment"
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
export type TaskCompletionSeenResult = {
  taskId: string;
  runId: string;
  marked: boolean;
};
export const taskApprovalModeReasons = [
  "task_not_found",
  "stale_binding",
  "stale_revision",
  "busy",
  "task_closed",
  "unsupported_interaction",
  "unavailable",
  "revision_exhausted",
  "review_exhausted",
  "shutting_down",
] as const;
export type TaskApprovalModeReason = (typeof taskApprovalModeReasons)[number];
export type TaskApprovalModeResult =
  | {
      accepted: true;
      taskId: string;
      approvalRevision: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: string;
      approvalRevision: null;
      reason: TaskApprovalModeReason;
    };
export type TaskModelSelectionReason =
  | "persistence_unavailable"
  | "persistence_failed"
  | "persistence_outcome_unknown"
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
      selectionRevision: string;
      reason: null;
    }
  | {
      accepted: false;
      taskId: string;
      selectionRevision: null;
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
  | "session_releasing"
  | "session_capacity"
  | "session_close_failed"
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
      blockingTaskId?: string;
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
  | {
      selected: false;
    }
  | {
      selected: true;
      workspaceId: string;
    };
export type SkillImportPreview =
  | {
      selected: false;
    }
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
  | {
      applied: true;
      selectionRevision: string;
      reason: null;
    }
  | {
      applied: false;
      selectionRevision: null;
      reason: SkillMutationReason;
    };
export type SkillExportResult =
  | {
      exported: true;
      fileName: string;
      reason: null;
    }
  | {
      exported: false;
      fileName: null;
      reason: string;
    };
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
export type UiResponsePayload = {
  kind: "permission";
  permission: PermissionChoice;
};
