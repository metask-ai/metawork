import type { SearchCursor } from "./contracts.ts";
import { outputActionStates } from "./contracts.ts";
import { decodeTaskApprovalResultWire } from "./generated-wire.ts";
import {
  exactKeys,
  fail,
  record,
  object,
  stringValue,
  booleanValue,
  arrayValue,
  wireId,
  u64WireInteger,
  positiveWireId,
  positiveU64WireId,
  numberValue,
  positiveNumber,
  nonNegativeNumber,
  enumValue,
} from "./wire-codec.ts";
import {
  viewBlockNames,
  type ViewVersions,
  compactPhases,
} from "./contracts.ts";
import {
  sendInputReasons,
  type SendInputResult,
  type InputSubmission,
  type WaitingInputView,
  type AdditionalInputView,
} from "./contracts.ts";
import {
  compactCauses,
  builtinProviderIds,
  permissionProfiles,
  approvalModes,
  taskApprovalModeReasons,
  type TaskApprovalModeResult,
  type TaskApprovalChange,
  type TaskApprovalResult,
  runCauses,
  type AccountCommandResult,
  type BuiltinProviderId,
  type ExecutionCommandResult,
  type AccountView,
  type ModelsView,
  type CatalogModelView,
  type NewTaskAdmissionView,
  type ModelMetadata,
  type ModelMetadataProvenance,
  type CustomProviderCredentialStatus,
  type Protocol,
  type CustomProviderState,
  type CustomModelTestStatus,
  type HostSignal,
  type PendingUi,
  type PermissionHistory,
  type PermissionChoice,
  type CatalogRefreshResult,
  type CompactView,
  type RunInputView,
  type RunActivity,
  type RunView,
  type RunManifest,
  type TaskSummary,
  type ViewScope,
  type AttachmentChooseResult,
  type AttachmentAddResult,
  type AttachmentAddAcceptance,
  type AttachmentAddBeginResult,
  type AttachmentCancelResult,
  type AttachmentReceiveResult,
  type ScheduledTaskView,
  type PersistenceRecoveryOutcome,
  type SkillCatalogView,
  type SkillManagementView,
  type SkillEnablementResult,
  skillSourceIds,
  skillSourceHealthStates,
  skillSourceCheckStates,
  skillSourceCheckReasons,
  skillSourceSettingsReasons,
  skillOriginEcosystems,
  skillOriginScopes,
  type SkillSourceSettings,
  type SkillSourceDiscovery,
  type SkillSourceSettingsResult,
  type McpManagementView,
  type McpMutationResult,
  type McpAuthorizationResult,
  type McpAuthorizationCancelResult,
  type McpRefreshResult,
  type McpConfigurationApplyResult,
  type McpConnectionTestResult,
  mcpAvailabilities,
  mcpManagementHealthValues,
  mcpConfigurationApplyValues,
  mcpRuntimeAlignmentValues,
  mcpRuntimeStatusValues,
  mcpNewTaskAccessValues,
  mcpAuthorizationStatusValues,
  mcpAuthorizationPhaseValues,
  type SkillImportPreview,
  type SkillMutationResult,
  type SkillExportResult,
  type SkillDetailResult,
  type SkillCatalogRefreshResult,
  type TaskView,
  type TaskCreateResult,
  type TaskCompactResult,
  type TaskRestoreResult,
  type TaskRunResult,
  type TaskModelSelectionResult,
  type ToolView,
  type FileReferenceView,
  type FilePreviewResponse,
  type FileChangeDiffResult,
  type UiRecord,
  type WorkbenchSnapshot,
  type AutomaticWorkspaceRootMutationResult,
  type WorkspaceChoice,
  type WorkspaceView,
} from "./contracts.ts";
type JsonObject = Record<string, unknown>;
export function decodeOutputActionResult(value: unknown) {
  const item = object(value, "$", ["generation", "operationId", "state"]);
  return {
    generation: positiveU64WireId(item.generation, "$.generation"),
    operationId: positiveU64WireId(item.operationId, "$.operationId"),
    state: enumValue(item.state, "$.state", outputActionStates),
  };
}
export function decodeOutputActionCancel(value: unknown) {
  const item = object(value, "$", ["generation", "operationId", "cancelled"]);
  return {
    generation: positiveU64WireId(item.generation, "$.generation"),
    operationId: positiveU64WireId(item.operationId, "$.operationId"),
    cancelled: booleanValue(item.cancelled, "$.cancelled"),
  };
}
export function decodeExternalLinkOpenResult(value: unknown) {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", [
      "opened",
      "rejected",
      "unavailable",
    ] as const),
  };
}
const taskLifecycles = ["open", "closing"] as const;
const runPhases = [
  "queued",
  "running",
  "waiting_ui",
  "stopping",
  "completed",
  "stopped",
  "cancelled",
  "interrupted",
  "failed",
] as const;
const nonTerminalRunPhases = [
  "queued",
  "running",
  "waiting_ui",
  "stopping",
] as const;
const nonTerminalCompactPhases = ["queued", "compacting", "stopping"] as const;
const runOutcomes = [
  "completed",
  "stopped",
  "cancelled",
  "interrupted",
  "failed",
  "dependency_contract_failure",
] as const;
const simpleRunActivities = [
  "queued",
  "starting",
  "waiting_model",
  "thinking",
  "writing_response",
  "waiting_user",
  "compacting_context",
  "finalizing",
  "stopping",
] as const;
const uiRecordKinds = ["permission"] as const;
const uiRecordStates = [
  "allowed_once",
  "allowed_always",
  "denied",
  "denied_session",
  "cancelled",
] as const;
const permissionDecisionSources = [
  "core_safety",
  "active_skill",
  "explicit_deny",
  "session_deny",
  "explicit_ask",
  "explicit_allow",
  "session_allow",
  "builtin_classification",
  "mode_fallback",
  "callback",
] as const;
const permissionCallbackOutcomes = [
  "answered",
  "user_cancelled",
  "unavailable",
  "contract_failure",
] as const;
const permissionChoices = [
  "deny_once",
  "deny_session",
  "allow_once",
  "allow_session",
] as const satisfies readonly PermissionChoice[];
const permissionInteractions = ["interactive", "noninteractive"] as const;
const maxCommentarySegmentsPerRun = 256;
const accountStates = [
  "checking",
  "signed_out",
  "authorizing",
  "authenticated",
] as const;
const accountSummaryOperations = ["idle", "refreshing"] as const;
const accountSummaryAvailabilities = [
  "unavailable",
  "loading",
  "ready",
  "stale",
] as const;
const accountUsageEligibilities = ["unknown", "disabled", "enabled"] as const;
const modelsCatalogStates = [
  "needs_authentication",
  "loading",
  "choosing",
  "ready",
  "failed",
  "unavailable",
] as const;
const accountErrorCodes = [
  "none",
  "invalid_command",
  "invalid_state",
  "operation_in_progress",
  "oauth_bind_failed",
  "oauth_browser_open_failed",
  "oauth_callback_rejected",
  "oauth_state_mismatch",
  "oauth_exchange_failed",
  "user_cancelled",
  "deadline_exceeded",
  "token_refresh_failed",
  "metask_unauthorized",
  "metask_rate_limited",
  "metask_service_unavailable",
  "metask_protocol_invalid",
  "metask_platform_unsupported",
  "credential_store_read_failed",
  "credential_store_write_failed",
  "credential_store_delete_failed",
  "generation_mismatch",
  "recovery_state_invalid",
  "refresh_schedule_failed",
  "local_resource_exhausted",
  "account_operation_failed",
] as const;
const modelsErrorCodes = [
  "none",
  "authorization_unavailable",
  "persistence_unavailable",
  "catalog_unavailable",
  "catalog_invalid",
  "catalog_too_large",
  "no_models",
  "operation_in_progress",
  "local_resource_exhausted",
] as const;
const executionCommandErrorCodes = [
  "none",
  "operation_in_progress",
  "user_cancelled",
  "generation_mismatch",
  "no_models",
  "local_resource_exhausted",
  "credential_store_write_failed",
  "custom_provider_invalid",
  "custom_provider_not_found",
  "custom_provider_capture_unavailable",
  "custom_provider_persistence_unavailable",
  "custom_model_test_unavailable",
] as const;
const rendererBridgeConnectErrors = [
  "identity_mismatch",
  "revision_mismatch",
] as const;
const protocols = [
  "openai_responses",
  "anthropic_messages",
  "openai_chat_completions",
  "gemini_native",
] as const;
const newTaskAdmissionStates = ["unavailable", "ready", "replacing"] as const;
const newTaskAdmissionReasons = [
  "none",
  "custom_provider_persistence_unavailable",
  "credential_unavailable",
  "invalid_candidate",
  "resource_exhausted",
  "schedule_persistence_unavailable",
  "schedule_persistence_failed",
  "schedule_persistence_outcome_unknown",
] as const;
const customProviderProtocols = [
  "openai_responses",
  "anthropic_messages",
  "openai_chat_completions",
  "gemini_native",
] as const;
const customProviderStates = ["configuring", "ready", "disabled"] as const;
const customModelTestStatuses = [
  "untested",
  "testing",
  "connected",
  "failed",
] as const;
const modelMetadataProvenances = [
  "unknown",
  "user_declared",
  "provider_declared",
  "runtime_verified",
] as const;
const customProviderCredentialStatuses = [
  "missing",
  "ready",
  "invalid",
  "capture_unavailable",
] as const;
const workspaceAuthorizations = [
  "available",
  "removing",
  "reauthorization_required",
] as const;
const workspaceKinds = ["manual", "automatic"] as const;
const bindingAvailabilities = ["available", "unavailable"] as const;
const skillCatalogAvailabilities = [
  "uninitialized",
  "loading",
  "ready",
  "degraded",
  "unavailable",
] as const;
const skillCatalogIssueCodes = [
  "invalid_definition",
  "source_conflict",
  "invalid_resource",
  "invalid_invocation_name",
] as const;
const scheduledTaskHealth = [
  "ready",
  "paused",
  "needs_attention",
  "completed",
] as const;
const scheduledTaskFailureReasons = [
  "previous_task_running",
  "execution_changed",
  "workspace_unavailable",
  "capacity_reached",
  "shutting_down",
  "task_start_failed",
  "timer_unavailable",
  "persistence_failed",
  "host_interrupted",
  "permission_required",
] as const;
const taskCreateReasons = [
  "execution_changed",
  "execution_unavailable",
  "workspace_changed",
  "workspace_unavailable",
  "workspace_removing",
  "catalog_loading",
  "catalog_unavailable",
  "model_selection_changed",
  "stale_catalog",
  "capacity_reached",
  "shutting_down",
] as const;
const taskRunReasons = [
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
  "unsupported_attachment",
  "capacity_reached",
  "shutting_down",
] as const;
const taskModelSelectionReasons = [
  "persistence_unavailable",
  "persistence_failed",
  "persistence_outcome_unknown",
  "model_changed",
  "stale_catalog",
  "task_unavailable",
  "task_busy",
  "shutting_down",
  "capacity_reached",
] as const;
const taskCompactReasons = [
  "binding_changed",
  "binding_unavailable",
  "task_unavailable",
  "task_busy",
  "no_history",
  "capacity_reached",
  "shutting_down",
] as const;
const taskRestoreReasons = [
  "binding_changed",
  "task_unavailable",
  "recovery_unavailable",
  "capacity_reached",
  "shutting_down",
] as const;
const catalogRefreshReasons = [
  "workspace_changed",
  "binding_changed",
  "workspace_unavailable",
  "workspace_removing",
  "task_unavailable",
  "task_busy",
  "catalog_loading",
  "catalog_unavailable",
  "capacity_reached",
  "shutting_down",
] as const;
function nonEmptyString(value: unknown, path: string) {
  const result = stringValue(value, path);
  if (result.length === 0) fail(path, "expected non-empty string");
  return result;
}
function decimalString(value: unknown, path: string, signed = false) {
  const result = stringValue(value, path);
  const unsignedPattern = /^(0|[1-9][0-9]*)(?:\.[0-9]*[1-9])?$/;
  const signedPattern = /^-?(0|[1-9][0-9]*)(?:\.[0-9]*[1-9])?$/;
  if (
    !(signed ? signedPattern : unsignedPattern).test(result) ||
    result === "-0"
  )
    fail(path, "expected canonical decimal string");
  return result;
}
function nullableDecimalString(value: unknown, path: string, signed = false) {
  return value === null ? null : decimalString(value, path, signed);
}
function nullableWireId(value: unknown, path: string) {
  return value === null ? null : wireId(value, path);
}
function calendarDate(value: unknown, path: string) {
  const result = stringValue(value, path);
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(result);
  if (match === null) fail(path, "expected YYYY-MM-DD calendar date");
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [
    31,
    leap ? 29 : 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];
  if (
    year === 0 ||
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > monthDays[month - 1]!
  )
    fail(path, "expected valid calendar date");
  return result;
}
function nullableCalendarDate(value: unknown, path: string) {
  return value === null ? null : calendarDate(value, path);
}
function calendarDayNumber(value: string) {
  return Math.floor(Date.parse(`${value}T00:00:00Z`) / 86400000);
}
function nonNegativeFiniteNumber(value: unknown, path: string) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
    fail(path, "expected non-negative finite number");
  return value;
}
function nullableObject<T>(
  value: unknown,
  path: string,
  decode: (item: unknown, path: string) => T,
): T | null {
  return value === null ? null : decode(value, path);
}
function nullableEnum<const T extends readonly string[]>(
  value: unknown,
  path: string,
  values: T,
): T[number] | null {
  return value === null ? null : enumValue(value, path, values);
}
function decodeRunInput(value: unknown, path: string): RunInputView {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail(path, "expected object");
  const kind = enumValue((value as JsonObject).kind, `${path}.kind`, [
    "text",
    "skill",
    "multimodal",
  ] as const);
  if (kind === "text") {
    const item = object(value, path, ["kind", "text", "redacted"]);
    return {
      kind,
      text: stringValue(item.text, `${path}.text`),
      redacted: booleanValue(item.redacted, `${path}.redacted`),
    };
  }
  if (kind === "multimodal") {
    const item = object(value, path, [
      "kind",
      "text",
      "attachments",
      "redacted",
    ]);
    const attachments = arrayValue(
      item.attachments,
      `${path}.attachments`,
      (attachmentValue, attachmentPath) => {
        const candidate = attachmentValue as JsonObject;
        const attachmentKind = enumValue(
          candidate?.kind,
          `${attachmentPath}.kind`,
          ["image", "file"] as const,
        );
        const attachment = object(
          attachmentValue,
          attachmentPath,
          attachmentKind === "image"
            ? ["kind", "format", "displayName", "sizeBytes", "redacted"]
            : ["kind", "displayName", "sizeBytes", "redacted"],
        );
        const common = {
          displayName: nonEmptyString(
            attachment.displayName,
            `${attachmentPath}.displayName`,
          ),
          sizeBytes: positiveWireId(
            attachment.sizeBytes,
            `${attachmentPath}.sizeBytes`,
          ),
          redacted: booleanValue(
            attachment.redacted,
            `${attachmentPath}.redacted`,
          ),
        };
        return attachmentKind === "image"
          ? {
              kind: attachmentKind,
              format: enumValue(attachment.format, `${attachmentPath}.format`, [
                "png",
                "jpeg",
                "webp",
              ] as const),
              ...common,
            }
          : { kind: attachmentKind, ...common };
      },
    );
    if (attachments.length === 0)
      fail(`${path}.attachments`, "multimodal input requires attachments");
    return {
      kind,
      text: item.text === null ? null : stringValue(item.text, `${path}.text`),
      attachments,
      redacted: booleanValue(item.redacted, `${path}.redacted`),
    };
  }
  const item = object(value, path, [
    "kind",
    "skillId",
    "catalogRevision",
    "invocationName",
    "displayName",
    "argumentValues",
    "redacted",
  ]);
  return {
    kind,
    skillId: nonEmptyString(item.skillId, `${path}.skillId`),
    catalogRevision: nonEmptyString(
      item.catalogRevision,
      `${path}.catalogRevision`,
    ),
    invocationName: nonEmptyString(
      item.invocationName,
      `${path}.invocationName`,
    ),
    displayName: nonEmptyString(item.displayName, `${path}.displayName`),
    argumentValues: arrayValue(
      item.argumentValues,
      `${path}.argumentValues`,
      stringValue,
    ),
    redacted: booleanValue(item.redacted, `${path}.redacted`),
  };
}
function decodeSkillCatalog(value: unknown, path: string): SkillCatalogView {
  const item = object(value, path, [
    "availability",
    "redacted",
    "revision",
    "selectionRevision",
    "skills",
    "issues",
  ]);
  const availability = enumValue(
    item.availability,
    `${path}.availability`,
    skillCatalogAvailabilities,
  );
  const revision =
    item.revision === null
      ? null
      : nonEmptyString(item.revision, `${path}.revision`);
  const selectionRevision =
    item.selectionRevision === null
      ? null
      : positiveWireId(item.selectionRevision, `${path}.selectionRevision`);
  const skills = arrayValue(
    item.skills,
    `${path}.skills`,
    (value, itemPath) => {
      const skill = object(value, itemPath, [
        "skillId",
        "invocationName",
        "displayName",
        "description",
        "argumentNames",
        "maxValues",
        "enabled",
      ]);
      const argumentNames = arrayValue(
        skill.argumentNames,
        `${itemPath}.argumentNames`,
        nonEmptyString,
      );
      const maxValues = nonNegativeNumber(
        skill.maxValues,
        `${itemPath}.maxValues`,
      );
      if (argumentNames.length > maxValues)
        fail(itemPath, "argument names exceed max values");
      return {
        skillId: nonEmptyString(skill.skillId, `${itemPath}.skillId`),
        invocationName: nonEmptyString(
          skill.invocationName,
          `${itemPath}.invocationName`,
        ),
        displayName: nonEmptyString(
          skill.displayName,
          `${itemPath}.displayName`,
        ),
        description: stringValue(skill.description, `${itemPath}.description`),
        argumentNames,
        maxValues,
        enabled: booleanValue(skill.enabled, `${itemPath}.enabled`),
      };
    },
  );
  const issues = arrayValue(
    item.issues,
    `${path}.issues`,
    (value, itemPath) => {
      const issue = object(value, itemPath, ["code", "invocationName"]);
      return {
        code: enumValue(issue.code, `${itemPath}.code`, skillCatalogIssueCodes),
        invocationName:
          issue.invocationName === null
            ? null
            : nonEmptyString(
                issue.invocationName,
                `${itemPath}.invocationName`,
              ),
      };
    },
  );
  const available = availability === "ready" || availability === "degraded";
  if (available !== (revision !== null))
    fail(path, "availability and revision must agree");
  if (available !== (selectionRevision !== null))
    fail(path, "availability and selection revision must agree");
  if (!available && (skills.length !== 0 || issues.length !== 0))
    fail(path, "an unavailable catalog cannot expose descriptors");
  if (
    (availability === "ready" && issues.length !== 0) ||
    (availability === "degraded" && issues.length === 0)
  )
    fail(path, "catalog health and issues must agree");
  const skillIds = new Set(skills.map((skill) => skill.skillId));
  const invocationNames = new Set(skills.map((skill) => skill.invocationName));
  if (skillIds.size !== skills.length || invocationNames.size !== skills.length)
    fail(path, "catalog skill identities must be unique");
  return {
    availability,
    redacted: booleanValue(item.redacted, `${path}.redacted`),
    revision,
    selectionRevision,
    skills,
    issues,
  };
}
function decodeSkillManagement(
  value: unknown,
  path: string,
): SkillManagementView {
  const item = object(value, path, [
    "availability",
    "enablementAvailability",
    "sourceSettings",
    "personalSourceDiscovery",
    "assets",
  ]);
  const availability = enumValue(item.availability, `${path}.availability`, [
    "unavailable",
    "ready",
    "read_failed",
    "corrupt",
    "write_failed",
    "outcome_unknown",
  ] as const);
  const enablementAvailability = enumValue(
    item.enablementAvailability,
    `${path}.enablementAvailability`,
    [
      "unavailable",
      "ready",
      "read_failed",
      "corrupt",
      "write_failed",
      "outcome_unknown",
    ] as const,
  );
  const assets = arrayValue(
    item.assets,
    `${path}.assets`,
    (value, itemPath) => {
      const asset = object(value, itemPath, [
        "installId",
        "sourceKind",
        "origin",
        "scope",
        "managementState",
        "skillId",
        "skillPolicyKey",
        "invocationName",
        "displayName",
        "description",
        "argumentNames",
        "maxValues",
        "canExport",
        "canReimport",
        "canUninstall",
        "canRetry",
        "enabled",
        "enablementState",
        "canSetEnabled",
        "selectionRevision",
        "issueCodes",
      ]);
      const scopeValue = object(asset.scope, `${itemPath}.scope`, [
        "kind",
        "workspaceId",
      ]);
      const scopeKind = enumValue(scopeValue.kind, `${itemPath}.scope.kind`, [
        "personal",
        "project",
        "external",
      ] as const);
      const scope =
        scopeKind === "project"
          ? {
              kind: scopeKind,
              workspaceId: positiveWireId(
                scopeValue.workspaceId,
                `${itemPath}.scope.workspaceId`,
              ),
            }
          : { kind: scopeKind, workspaceId: null };
      if (scopeKind !== "project" && scopeValue.workspaceId !== null)
        fail(`${itemPath}.scope`, "non-project scope cannot name a workspace");
      return {
        installId:
          asset.installId === null
            ? null
            : nonEmptyString(asset.installId, `${itemPath}.installId`),
        sourceKind: enumValue(asset.sourceKind, `${itemPath}.sourceKind`, [
          "local_package",
          "local_directory",
          "external",
        ] as const),
        origin: decodeSkillOrigin(asset.origin, `${itemPath}.origin`),
        scope,
        managementState: enumValue(
          asset.managementState,
          `${itemPath}.managementState`,
          [
            "ready",
            "pending_verification",
            "recovery_required",
            "externally_managed",
          ] as const,
        ),
        skillId:
          asset.skillId === null
            ? null
            : nonEmptyString(asset.skillId, `${itemPath}.skillId`),
        skillPolicyKey:
          asset.skillPolicyKey === null
            ? null
            : nonEmptyString(
                asset.skillPolicyKey,
                `${itemPath}.skillPolicyKey`,
              ),
        invocationName: nonEmptyString(
          asset.invocationName,
          `${itemPath}.invocationName`,
        ),
        displayName: nonEmptyString(
          asset.displayName,
          `${itemPath}.displayName`,
        ),
        description: stringValue(asset.description, `${itemPath}.description`),
        argumentNames: arrayValue(
          asset.argumentNames,
          `${itemPath}.argumentNames`,
          nonEmptyString,
        ),
        maxValues: nonNegativeNumber(asset.maxValues, `${itemPath}.maxValues`),
        canExport: booleanValue(asset.canExport, `${itemPath}.canExport`),
        canReimport: booleanValue(asset.canReimport, `${itemPath}.canReimport`),
        canUninstall: booleanValue(
          asset.canUninstall,
          `${itemPath}.canUninstall`,
        ),
        canRetry: booleanValue(asset.canRetry, `${itemPath}.canRetry`),
        enabled:
          asset.enabled === null
            ? null
            : booleanValue(asset.enabled, `${itemPath}.enabled`),
        enablementState:
          asset.enablementState === null
            ? null
            : enumValue(asset.enablementState, `${itemPath}.enablementState`, [
                "inherit",
                "enabled",
                "disabled",
              ] as const),
        canSetEnabled: booleanValue(
          asset.canSetEnabled,
          `${itemPath}.canSetEnabled`,
        ),
        selectionRevision:
          asset.selectionRevision === null
            ? null
            : positiveWireId(
                asset.selectionRevision,
                `${itemPath}.selectionRevision`,
              ),
        issueCodes: arrayValue(
          asset.issueCodes,
          `${itemPath}.issueCodes`,
          (value, issuePath) =>
            enumValue(value, issuePath, skillCatalogIssueCodes),
        ),
      };
    },
  );
  for (const asset of assets) {
    if (
      asset.managementState === "recovery_required" &&
      (asset.installId === null ||
        asset.canExport ||
        asset.canReimport ||
        asset.canUninstall)
    )
      fail(
        path,
        "recovery requires a managed asset without ordinary file actions",
      );
    if (
      asset.canRetry &&
      (availability !== "ready" ||
        asset.installId === null ||
        !["recovery_required", "pending_verification"].includes(
          asset.managementState,
        ))
    )
      fail(path, "retry requires trusted management and a recoverable asset");
    const enablementFields = [
      asset.enabled,
      asset.enablementState,
      asset.selectionRevision,
    ];
    const hasAnyEnablement = enablementFields.some((value) => value !== null);
    const hasEnablement = enablementFields.every((value) => value !== null);
    if (hasAnyEnablement !== hasEnablement)
      fail(path, "enablement state and revision must be published together");
    if (asset.canSetEnabled !== hasEnablement)
      fail(path, "settable assets require enablement state and revision");
    if (asset.scope.kind === "personal" && asset.enablementState === "inherit")
      fail(path, "personal assets cannot inherit enablement");
  }
  return {
    availability,
    enablementAvailability,
    sourceSettings: decodeSkillSourceSettings(
      item.sourceSettings,
      `${path}.sourceSettings`,
    ),
    personalSourceDiscovery: decodeSkillSourceDiscovery(
      item.personalSourceDiscovery,
      `${path}.personalSourceDiscovery`,
      "personal",
    ),
    assets,
  } as SkillManagementView;
}
function decodeSkillOrigin(
  value: unknown,
  path: string,
): SkillManagementView["assets"][number]["origin"] {
  if (value === null) return null;
  const item = object(value, path, ["ecosystem", "scope"]);
  return {
    ecosystem: enumValue(
      item.ecosystem,
      `${path}.ecosystem`,
      skillOriginEcosystems,
    ),
    scope: enumValue(item.scope, `${path}.scope`, skillOriginScopes),
  };
}
function decodeSkillSourceSettings(
  value: unknown,
  path: string,
): SkillSourceSettings {
  const item = object(value, path, [
    "revision",
    "health",
    "entries",
    "recovery",
  ]);
  const revision =
    item.revision === null
      ? null
      : positiveWireId(item.revision, `${path}.revision`);
  const health = enumValue(
    item.health,
    `${path}.health`,
    skillSourceHealthStates,
  );
  const entries = arrayValue(
    item.entries,
    `${path}.entries`,
    (value, entryPath) => {
      const entry = object(value, entryPath, [
        "sourceId",
        "enabled",
        "canSetEnabled",
      ]);
      const sourceId = enumValue(
        entry.sourceId,
        `${entryPath}.sourceId`,
        skillSourceIds,
      );
      const enabled = nullableBoolean(entry.enabled, `${entryPath}.enabled`);
      const canSetEnabled = booleanValue(
        entry.canSetEnabled,
        `${entryPath}.canSetEnabled`,
      );
      if (
        (enabled !== null) !== (revision !== null) ||
        (canSetEnabled && enabled === null)
      )
        fail(
          entryPath,
          "source values and revision must describe the same known settings",
        );
      return { sourceId, enabled, canSetEnabled };
    },
  );
  if (
    entries.length !== skillSourceIds.length ||
    new Set(entries.map((entry) => entry.sourceId)).size !==
      skillSourceIds.length
  )
    fail(
      `${path}.entries`,
      "expected each fixed compatibility source exactly once",
    );
  if (
    (health === "ready" && revision === null) ||
    (health !== "ready" && health !== "write_failed" && revision !== null)
  )
    fail(path, "source health must agree with known configuration");
  const rawRecovery = object(item.recovery, `${path}.recovery`, [
    "canReread",
    "canReset",
    "token",
  ]);
  const recovery = {
    canReread: booleanValue(
      rawRecovery.canReread,
      `${path}.recovery.canReread`,
    ),
    canReset: booleanValue(rawRecovery.canReset, `${path}.recovery.canReset`),
    token:
      rawRecovery.token === null
        ? null
        : positiveWireId(rawRecovery.token, `${path}.recovery.token`),
  };
  if (
    recovery.canReread !== (recovery.token !== null) ||
    (revision !== null && recovery.canReread) ||
    (recovery.canReset &&
      (!recovery.canReread || (health !== "corrupt" && health !== "missing")))
  )
    fail(`${path}.recovery`, "invalid source recovery authority");
  return { revision, health, entries, recovery };
}
function decodeSkillSourceDiscovery(
  value: unknown,
  path: string,
  context: "personal" | "project",
): SkillSourceDiscovery {
  if (value === null) return null;
  const expected =
    context === "personal"
      ? ([
          "agents.user.default",
          "compat.claude.user",
          "compat.codex.user",
        ] as const)
      : ([
          "agents.user.default",
          "agents.workspace.default",
          ...skillSourceIds,
        ] as const);
  const checks = arrayValue(value, path, (value, checkPath) => {
    const check = object(value, checkPath, ["sourceId", "state", "reason"]);
    const sourceId = enumValue(
      check.sourceId,
      `${checkPath}.sourceId`,
      expected,
    );
    const state = enumValue(
      check.state,
      `${checkPath}.state`,
      skillSourceCheckStates,
    );
    const reason =
      check.reason === null
        ? null
        : enumValue(
            check.reason,
            `${checkPath}.reason`,
            skillSourceCheckReasons,
          );
    if (
      (state === "error") !== (reason !== null) ||
      (sourceId.startsWith("agents.") && state === "disabled")
    )
      fail(checkPath, "root check state and reason disagree");
    return { sourceId, state, reason };
  });
  if (
    checks.length !== expected.length ||
    new Set(checks.map((check) => check.sourceId)).size !== expected.length
  )
    fail(path, "expected the complete scoped root checks");
  return checks;
}
function assertSourceDiscoverySettings(
  discovery: SkillSourceDiscovery,
  settings: SkillSourceSettings,
  path: string,
): void {
  if (discovery === null) return;
  if (settings.revision === null)
    fail(path, "unknown source settings cannot publish root checks");
  for (const check of discovery) {
    const entry = settings.entries.find(
      (entry) => entry.sourceId === check.sourceId,
    );
    if (entry && (check.state === "disabled") !== (entry.enabled === false))
      fail(path, "root checks must use the committed source selection");
  }
}
function nullableBoolean(value: unknown, path: string): boolean | null {
  return value === null ? null : booleanValue(value, path);
}
function modelTokenLimit(value: unknown, path: string): string | null {
  if (value === null) return null;
  const result = positiveWireId(value, path);
  if (
    result.length > 20 ||
    (result.length === 20 && result > "18446744073709551615")
  )
    fail(path, "expected positive u64 token limit");
  return result;
}
function decodeModelMetadata(value: unknown, path: string): ModelMetadata {
  const item = object(value, path, [
    "maxInputTokens",
    "maxOutputTokens",
    "capabilities",
  ]);
  const capsPath = `${path}.capabilities`;
  const caps = object(item.capabilities, capsPath, [
    "textInput",
    "audioInput",
    "videoInput",
    "output",
    "imageInput",
    "pdfInput",
    "batch",
    "citations",
    "codeExecution",
    "structuredOutputs",
    "thinking",
    "effort",
    "contextManagement",
  ]);
  const output = object(caps.output, `${capsPath}.output`, [
    "text",
    "image",
    "audio",
    "video",
    "embedding",
  ]);
  const thinking = object(caps.thinking, `${capsPath}.thinking`, [
    "supported",
    "adaptive",
    "enabled",
  ]);
  const effort = object(caps.effort, `${capsPath}.effort`, [
    "supported",
    "low",
    "medium",
    "high",
    "max",
  ]);
  const contextManagement = object(
    caps.contextManagement,
    `${capsPath}.contextManagement`,
    [
      "supported",
      "clearThinking20251015",
      "clearToolUses20250919",
      "compact20260112",
    ],
  );
  return {
    maxInputTokens: modelTokenLimit(
      item.maxInputTokens,
      `${path}.maxInputTokens`,
    ),
    maxOutputTokens: modelTokenLimit(
      item.maxOutputTokens,
      `${path}.maxOutputTokens`,
    ),
    capabilities: {
      textInput: nullableBoolean(caps.textInput, `${capsPath}.textInput`),
      audioInput: nullableBoolean(caps.audioInput, `${capsPath}.audioInput`),
      videoInput: nullableBoolean(caps.videoInput, `${capsPath}.videoInput`),
      output: {
        text: nullableBoolean(output.text, `${capsPath}.output.text`),
        image: nullableBoolean(output.image, `${capsPath}.output.image`),
        audio: nullableBoolean(output.audio, `${capsPath}.output.audio`),
        video: nullableBoolean(output.video, `${capsPath}.output.video`),
        embedding: nullableBoolean(
          output.embedding,
          `${capsPath}.output.embedding`,
        ),
      },
      imageInput: nullableBoolean(caps.imageInput, `${capsPath}.imageInput`),
      pdfInput: nullableBoolean(caps.pdfInput, `${capsPath}.pdfInput`),
      batch: nullableBoolean(caps.batch, `${capsPath}.batch`),
      citations: nullableBoolean(caps.citations, `${capsPath}.citations`),
      codeExecution: nullableBoolean(
        caps.codeExecution,
        `${capsPath}.codeExecution`,
      ),
      structuredOutputs: nullableBoolean(
        caps.structuredOutputs,
        `${capsPath}.structuredOutputs`,
      ),
      thinking: {
        supported: nullableBoolean(
          thinking.supported,
          `${capsPath}.thinking.supported`,
        ),
        adaptive: nullableBoolean(
          thinking.adaptive,
          `${capsPath}.thinking.adaptive`,
        ),
        enabled: nullableBoolean(
          thinking.enabled,
          `${capsPath}.thinking.enabled`,
        ),
      },
      effort: {
        supported: nullableBoolean(
          effort.supported,
          `${capsPath}.effort.supported`,
        ),
        low: nullableBoolean(effort.low, `${capsPath}.effort.low`),
        medium: nullableBoolean(effort.medium, `${capsPath}.effort.medium`),
        high: nullableBoolean(effort.high, `${capsPath}.effort.high`),
        max: nullableBoolean(effort.max, `${capsPath}.effort.max`),
      },
      contextManagement: {
        supported: nullableBoolean(
          contextManagement.supported,
          `${capsPath}.contextManagement.supported`,
        ),
        clearThinking20251015: nullableBoolean(
          contextManagement.clearThinking20251015,
          `${capsPath}.contextManagement.clearThinking20251015`,
        ),
        clearToolUses20250919: nullableBoolean(
          contextManagement.clearToolUses20250919,
          `${capsPath}.contextManagement.clearToolUses20250919`,
        ),
        compact20260112: nullableBoolean(
          contextManagement.compact20260112,
          `${capsPath}.contextManagement.compact20260112`,
        ),
      },
    },
  };
}
function decodeAccount(value: unknown, path: string): AccountView {
  const item = object(value, path, [
    "state",
    "canCancel",
    "accountId",
    "displayName",
    "emailHint",
    "phoneHint",
    "concurrencyLimit",
    "errorCode",
    "safeDiagnostic",
    "summary",
  ]);
  const state = enumValue(item.state, `${path}.state`, accountStates);
  const canCancel = booleanValue(item.canCancel, `${path}.canCancel`);
  const accountId = stringValue(item.accountId, `${path}.accountId`);
  const displayName = stringValue(item.displayName, `${path}.displayName`);
  const emailHint = stringValue(item.emailHint, `${path}.emailHint`);
  const phoneHint = stringValue(item.phoneHint, `${path}.phoneHint`);
  const concurrencyLimit =
    item.concurrencyLimit === null
      ? null
      : nonNegativeNumber(item.concurrencyLimit, `${path}.concurrencyLimit`);
  const errorCode = enumValue(
    item.errorCode,
    `${path}.errorCode`,
    accountErrorCodes,
  );
  const safeDiagnostic = stringValue(
    item.safeDiagnostic,
    `${path}.safeDiagnostic`,
  );
  const summaryPath = `${path}.summary`;
  const summaryItem = object(item.summary, summaryPath, [
    "operation",
    "usageEligibility",
    "wallet",
    "usage",
    "history",
  ]);
  const operation = enumValue(
    summaryItem.operation,
    `${summaryPath}.operation`,
    accountSummaryOperations,
  );
  const usageEligibility = enumValue(
    summaryItem.usageEligibility,
    `${summaryPath}.usageEligibility`,
    accountUsageEligibilities,
  );
  const walletPath = `${summaryPath}.wallet`;
  const walletItem = object(summaryItem.wallet, walletPath, [
    "availability",
    "balanceU",
    "syncedAt",
    "errorCode",
    "safeDiagnostic",
  ]);
  const wallet = {
    availability: enumValue(
      walletItem.availability,
      `${walletPath}.availability`,
      accountSummaryAvailabilities,
    ),
    balanceU: nullableDecimalString(
      walletItem.balanceU,
      `${walletPath}.balanceU`,
      true,
    ),
    syncedAt: nullableWireId(walletItem.syncedAt, `${walletPath}.syncedAt`),
    errorCode: enumValue(
      walletItem.errorCode,
      `${walletPath}.errorCode`,
      accountErrorCodes,
    ),
    safeDiagnostic: stringValue(
      walletItem.safeDiagnostic,
      `${walletPath}.safeDiagnostic`,
    ),
  };
  const usagePath = `${summaryPath}.usage`;
  const usageItem = object(summaryItem.usage, usagePath, [
    "availability",
    "today",
    "total",
    "syncedAt",
    "errorCode",
    "safeDiagnostic",
  ]);
  const todayPath = `${usagePath}.today`;
  const today = nullableObject(usageItem.today, todayPath, (value) => {
    const todayItem = object(value, todayPath, [
      "inputTokens",
      "outputTokens",
      "cacheCreationTokens",
      "cacheReadTokens",
      "totalTokens",
      "actualCostU",
    ]);
    return {
      inputTokens: decimalString(
        todayItem.inputTokens,
        `${todayPath}.inputTokens`,
      ),
      outputTokens: decimalString(
        todayItem.outputTokens,
        `${todayPath}.outputTokens`,
      ),
      cacheCreationTokens: decimalString(
        todayItem.cacheCreationTokens,
        `${todayPath}.cacheCreationTokens`,
      ),
      cacheReadTokens: decimalString(
        todayItem.cacheReadTokens,
        `${todayPath}.cacheReadTokens`,
      ),
      totalTokens: decimalString(
        todayItem.totalTokens,
        `${todayPath}.totalTokens`,
      ),
      actualCostU: decimalString(
        todayItem.actualCostU,
        `${todayPath}.actualCostU`,
      ),
    };
  });
  const totalPath = `${usagePath}.total`;
  const total = nullableObject(usageItem.total, totalPath, (value) => {
    const totalItem = object(value, totalPath, ["totalTokens", "actualCostU"]);
    return {
      totalTokens: decimalString(
        totalItem.totalTokens,
        `${totalPath}.totalTokens`,
      ),
      actualCostU: decimalString(
        totalItem.actualCostU,
        `${totalPath}.actualCostU`,
      ),
    };
  });
  const usage = {
    availability: enumValue(
      usageItem.availability,
      `${usagePath}.availability`,
      accountSummaryAvailabilities,
    ),
    today,
    total,
    syncedAt: nullableWireId(usageItem.syncedAt, `${usagePath}.syncedAt`),
    errorCode: enumValue(
      usageItem.errorCode,
      `${usagePath}.errorCode`,
      accountErrorCodes,
    ),
    safeDiagnostic: stringValue(
      usageItem.safeDiagnostic,
      `${usagePath}.safeDiagnostic`,
    ),
  };
  const historyPath = `${summaryPath}.history`;
  const historyItem = object(summaryItem.history, historyPath, [
    "availability",
    "startDate",
    "endDate",
    "days",
    "syncedAt",
    "errorCode",
    "safeDiagnostic",
  ]);
  const history = {
    availability: enumValue(
      historyItem.availability,
      `${historyPath}.availability`,
      accountSummaryAvailabilities,
    ),
    startDate: nullableCalendarDate(
      historyItem.startDate,
      `${historyPath}.startDate`,
    ),
    endDate: nullableCalendarDate(
      historyItem.endDate,
      `${historyPath}.endDate`,
    ),
    days: arrayValue(
      historyItem.days,
      `${historyPath}.days`,
      (value, dayPath) => {
        const day = object(value, dayPath, [
          "date",
          "inputTokens",
          "outputTokens",
          "cacheCreationTokens",
          "cacheReadTokens",
          "totalTokens",
          "actualCostU",
        ]);
        return {
          date: calendarDate(day.date, `${dayPath}.date`),
          inputTokens: decimalString(day.inputTokens, `${dayPath}.inputTokens`),
          outputTokens: decimalString(
            day.outputTokens,
            `${dayPath}.outputTokens`,
          ),
          cacheCreationTokens: decimalString(
            day.cacheCreationTokens,
            `${dayPath}.cacheCreationTokens`,
          ),
          cacheReadTokens: decimalString(
            day.cacheReadTokens,
            `${dayPath}.cacheReadTokens`,
          ),
          totalTokens: decimalString(day.totalTokens, `${dayPath}.totalTokens`),
          actualCostU: decimalString(day.actualCostU, `${dayPath}.actualCostU`),
        };
      },
    ),
    syncedAt: nullableWireId(historyItem.syncedAt, `${historyPath}.syncedAt`),
    errorCode: enumValue(
      historyItem.errorCode,
      `${historyPath}.errorCode`,
      accountErrorCodes,
    ),
    safeDiagnostic: stringValue(
      historyItem.safeDiagnostic,
      `${historyPath}.safeDiagnostic`,
    ),
  };
  if (history.days.length > 371) fail(historyPath, "too many history days");
  if (history.startDate !== null && history.endDate !== null) {
    if (history.startDate > history.endDate)
      fail(historyPath, "history range must be ordered");
    const startDay = calendarDayNumber(history.startDate);
    const rangeDays = calendarDayNumber(history.endDate) - startDay + 1;
    if ((startDay + 3) % 7 !== 0 || rangeDays < 365 || rangeDays > 371)
      fail(historyPath, "history range must align 53 week columns from Monday");
    let previousDate: string | null = null;
    for (const [index, day] of history.days.entries()) {
      if (day.date < history.startDate || day.date > history.endDate)
        fail(
          `${historyPath}.days[${index}]`,
          "history date is outside the range",
        );
      if (previousDate !== null && previousDate >= day.date)
        fail(
          `${historyPath}.days[${index}]`,
          "history dates must be strictly ordered",
        );
      previousDate = day.date;
    }
  }
  if (
    state !== "authenticated" &&
    (accountId.length !== 0 ||
      displayName.length !== 0 ||
      emailHint.length !== 0 ||
      phoneHint.length !== 0 ||
      concurrencyLimit !== null)
  )
    fail(path, "a non-authenticated Account must hide identity");
  if (state === "authenticated" && accountId.length === 0)
    fail(path, "an authenticated Account requires identity");
  if (canCancel && state !== "authorizing")
    fail(path, "cancellation requires active authorization");
  if (errorCode === "none" && safeDiagnostic.length !== 0)
    fail(path, "safe diagnostic requires an Account error");
  if (wallet.errorCode === "none" && wallet.safeDiagnostic.length !== 0)
    fail(walletPath, "safe diagnostic requires an Account error");
  if (usage.errorCode === "none" && usage.safeDiagnostic.length !== 0)
    fail(usagePath, "safe diagnostic requires an Account error");
  if (history.errorCode === "none" && history.safeDiagnostic.length !== 0)
    fail(historyPath, "safe diagnostic requires an Account error");
  if (
    (wallet.availability === "ready" || wallet.availability === "stale") !==
    (wallet.balanceU !== null && wallet.syncedAt !== null)
  )
    fail(walletPath, "summary data must match availability");
  if (
    (usage.availability === "ready" || usage.availability === "stale") !==
    (usage.today !== null && usage.total !== null && usage.syncedAt !== null)
  )
    fail(usagePath, "summary data must match availability");
  const historyCarriesData =
    history.availability === "ready" || history.availability === "stale";
  if (historyCarriesData) {
    if (
      history.startDate === null ||
      history.endDate === null ||
      history.syncedAt === null
    )
      fail(historyPath, "summary data must match availability");
  } else if (
    history.startDate !== null ||
    history.endDate !== null ||
    history.days.length !== 0 ||
    history.syncedAt !== null
  ) {
    fail(historyPath, "summary data must match availability");
  }
  if (
    usageEligibility === "disabled" &&
    (usage.availability !== "unavailable" ||
      usage.errorCode !== "none" ||
      history.availability !== "unavailable" ||
      history.errorCode !== "none")
  )
    fail(usagePath, "disabled usage must remain unavailable");
  if (
    state !== "authenticated" &&
    (operation !== "idle" ||
      usageEligibility !== "unknown" ||
      wallet.availability !== "unavailable" ||
      wallet.errorCode !== "none" ||
      usage.availability !== "unavailable" ||
      usage.errorCode !== "none" ||
      history.availability !== "unavailable" ||
      history.errorCode !== "none")
  )
    fail(summaryPath, "a non-authenticated Account must hide its summary");
  return {
    state,
    canCancel,
    accountId,
    displayName,
    emailHint,
    phoneHint,
    concurrencyLimit,
    errorCode,
    safeDiagnostic,
    summary: { operation, usageEligibility, wallet, usage, history },
  };
}
function decodeModelRef(value: unknown, path: string) {
  if (value === null) return null;
  const item = object(value, path, ["sourceId", "modelId"]);
  const result = {
    sourceId: stringValue(item.sourceId, `${path}.sourceId`),
    modelId: stringValue(item.modelId, `${path}.modelId`),
  };
  if (result.sourceId.length === 0 || result.modelId.length === 0)
    fail(path, "a model reference requires source and model identities");
  return result;
}
function decodeRequiredModelRef(value: unknown, path: string) {
  const result = decodeModelRef(value, path);
  if (result === null) fail(path, "expected model reference");
  return result;
}
function decodeCustomProviders(value: unknown, path: string) {
  const customProviders = arrayValue(value, path, (value, itemPath) => {
    const provider = object(value, itemPath, [
      "id",
      "builtinProviderId",
      "displayName",
      "protocol",
      "normalizedBaseUrl",
      "state",
      "credentialStatus",
      "enabled",
      "providerRevision",
      "sourceGeneration",
      "catalogGeneration",
      "models",
    ]);
    const models = arrayValue(
      provider.models,
      `${itemPath}.models`,
      (modelValue, modelPath) => {
        const model = object(modelValue, modelPath, [
          "id",
          "displayName",
          "metadata",
          "metadataProvenance",
          "testStatus",
          "ready",
        ]);
        return {
          id: stringValue(model.id, `${modelPath}.id`),
          displayName: stringValue(
            model.displayName,
            `${modelPath}.displayName`,
          ),
          metadata: decodeModelMetadata(
            model.metadata,
            `${modelPath}.metadata`,
          ),
          metadataProvenance: enumValue(
            model.metadataProvenance,
            `${modelPath}.metadataProvenance`,
            modelMetadataProvenances,
          ) as ModelMetadataProvenance,
          testStatus: enumValue(
            model.testStatus,
            `${modelPath}.testStatus`,
            customModelTestStatuses,
          ) as CustomModelTestStatus,
          ready: booleanValue(model.ready, `${modelPath}.ready`),
        };
      },
    );
    return {
      id: stringValue(provider.id, `${itemPath}.id`),
      builtinProviderId:
        provider.builtinProviderId === null
          ? null
          : (enumValue(
              provider.builtinProviderId,
              `${itemPath}.builtinProviderId`,
              builtinProviderIds,
            ) as BuiltinProviderId),
      displayName: stringValue(provider.displayName, `${itemPath}.displayName`),
      protocol: enumValue(
        provider.protocol,
        `${itemPath}.protocol`,
        customProviderProtocols,
      ) as Protocol,
      normalizedBaseUrl: stringValue(
        provider.normalizedBaseUrl,
        `${itemPath}.normalizedBaseUrl`,
      ),
      state: enumValue(
        provider.state,
        `${itemPath}.state`,
        customProviderStates,
      ) as CustomProviderState,
      credentialStatus: enumValue(
        provider.credentialStatus,
        `${itemPath}.credentialStatus`,
        customProviderCredentialStatuses,
      ) as CustomProviderCredentialStatus,
      enabled: booleanValue(provider.enabled, `${itemPath}.enabled`),
      providerRevision: wireId(
        provider.providerRevision,
        `${itemPath}.providerRevision`,
      ),
      sourceGeneration: wireId(
        provider.sourceGeneration,
        `${itemPath}.sourceGeneration`,
      ),
      catalogGeneration: wireId(
        provider.catalogGeneration,
        `${itemPath}.catalogGeneration`,
      ),
      models,
    };
  });
  if (
    new Set(customProviders.map((provider) => provider.id)).size !==
    customProviders.length
  )
    fail(path, "provider identities must be unique");
  for (const [index, provider] of customProviders.entries()) {
    const providerPath = `${path}[${index}]`;
    if (
      new Set(provider.models.map((model) => model.id)).size !==
      provider.models.length
    )
      fail(`${providerPath}.models`, "model identities must be unique");
    if (
      provider.state === "ready" &&
      (provider.credentialStatus !== "ready" ||
        !provider.enabled ||
        !provider.models.some((model) => model.ready))
    )
      fail(providerPath, "a ready provider must be verified and usable");
    if (
      provider.state !== "ready" &&
      provider.models.some((model) => model.ready)
    )
      fail(providerPath, "only a ready provider can retain model readiness");
  }
  return customProviders;
}
function decodeCatalogModels(value: unknown, path: string): CatalogModelView[] {
  const models = arrayValue(value, path, (value, modelPath) => {
    const model = object(value, modelPath, [
      "id",
      "displayName",
      "metadata",
      "metadataProvenance",
    ]);
    return {
      id: stringValue(model.id, `${modelPath}.id`),
      displayName: stringValue(model.displayName, `${modelPath}.displayName`),
      metadata: decodeModelMetadata(model.metadata, `${modelPath}.metadata`),
      metadataProvenance: enumValue(
        model.metadataProvenance,
        `${modelPath}.metadataProvenance`,
        modelMetadataProvenances,
      ) as ModelMetadataProvenance,
    };
  });
  if (new Set(models.map((model) => model.id)).size !== models.length)
    fail(path, "model identities must be unique");
  return models;
}
function decodeModels(value: unknown, path: string): ModelsView {
  const item = object(value, path, [
    "availability",
    "persistenceHealth",
    "providers",
    "metaskSelection",
    "metaskSelectionRevision",
    "defaultSelection",
    "selectionRevision",
    "operation",
    "errorCode",
    "builtinProviderPresets",
    "customProviders",
  ]);
  const builtinProviderPresets = arrayValue(
    item.builtinProviderPresets,
    `${path}.builtinProviderPresets`,
    (value, itemPath) => {
      const preset = object(value, itemPath, [
        "id",
        "displayName",
        "protocol",
        "defaultBaseUrl",
        "apiKeyUrl",
        "documentationUrl",
      ]);
      return {
        id: enumValue(
          preset.id,
          `${itemPath}.id`,
          builtinProviderIds,
        ) as BuiltinProviderId,
        displayName: stringValue(preset.displayName, `${itemPath}.displayName`),
        protocol: enumValue(
          preset.protocol,
          `${itemPath}.protocol`,
          customProviderProtocols,
        ) as Protocol,
        defaultBaseUrl: stringValue(
          preset.defaultBaseUrl,
          `${itemPath}.defaultBaseUrl`,
        ),
        apiKeyUrl: stringValue(preset.apiKeyUrl, `${itemPath}.apiKeyUrl`),
        documentationUrl: stringValue(
          preset.documentationUrl,
          `${itemPath}.documentationUrl`,
        ),
      };
    },
  );
  if (
    new Set(builtinProviderPresets.map((preset) => preset.id)).size !==
    builtinProviderPresets.length
  )
    fail(`${path}.builtinProviderPresets`, "preset identities must be unique");
  const providers = arrayValue(
    item.providers,
    `${path}.providers`,
    (value, itemPath) => {
      const provider = object(value, itemPath, [
        "id",
        "displayName",
        "recommended",
        "catalogState",
        "principalRef",
        "models",
        "catalogGeneration",
        "sourceGeneration",
        "errorCode",
        "safeDiagnostic",
      ]);
      const models = decodeCatalogModels(provider.models, `${itemPath}.models`);
      return {
        id: stringValue(provider.id, `${itemPath}.id`),
        displayName: stringValue(
          provider.displayName,
          `${itemPath}.displayName`,
        ),
        recommended: booleanValue(
          provider.recommended,
          `${itemPath}.recommended`,
        ),
        catalogState: enumValue(
          provider.catalogState,
          `${itemPath}.catalogState`,
          modelsCatalogStates,
        ),
        principalRef: stringValue(
          provider.principalRef,
          `${itemPath}.principalRef`,
        ),
        models,
        catalogGeneration: wireId(
          provider.catalogGeneration,
          `${itemPath}.catalogGeneration`,
        ),
        sourceGeneration: wireId(
          provider.sourceGeneration,
          `${itemPath}.sourceGeneration`,
        ),
        errorCode: enumValue(
          provider.errorCode,
          `${itemPath}.errorCode`,
          modelsErrorCodes,
        ),
        safeDiagnostic: stringValue(
          provider.safeDiagnostic,
          `${itemPath}.safeDiagnostic`,
        ),
      };
    },
  );
  if (
    new Set(providers.map((provider) => provider.id)).size !== providers.length
  )
    fail(`${path}.providers`, "provider identities must be unique");
  const metaskSelection = decodeModelRef(
    item.metaskSelection,
    `${path}.metaskSelection`,
  );
  const defaultSelection = decodeModelRef(
    item.defaultSelection,
    `${path}.defaultSelection`,
  );
  // Durable selections are intent. An authoritative ready catalog can
  // exclude them; Host admission and commands validate current membership.
  return {
    availability: enumValue(
      item.availability,
      `${path}.availability`,
      modelsCatalogStates,
    ),
    persistenceHealth: enumValue(
      item.persistenceHealth,
      `${path}.persistenceHealth`,
      ["ready", "recovery_required", "unavailable"] as const,
    ),
    providers,
    metaskSelection,
    metaskSelectionRevision: wireId(
      item.metaskSelectionRevision,
      `${path}.metaskSelectionRevision`,
    ),
    defaultSelection,
    selectionRevision: wireId(
      item.selectionRevision,
      `${path}.selectionRevision`,
    ),
    operation: enumValue(item.operation, `${path}.operation`, [
      "idle",
      "refreshing_catalog",
    ] as const),
    errorCode: enumValue(item.errorCode, `${path}.errorCode`, modelsErrorCodes),
    builtinProviderPresets,
    customProviders: decodeCustomProviders(
      item.customProviders,
      `${path}.customProviders`,
    ),
  };
}
function decodeNewTaskAdmission(
  value: unknown,
  path: string,
): NewTaskAdmissionView {
  const item = object(value, path, [
    "available",
    "reason",
    "activeModelRef",
    "activeGeneration",
    "activeSelectionRevision",
    "state",
  ]);
  const state = enumValue(item.state, `${path}.state`, newTaskAdmissionStates);
  const activeModelRef = decodeModelRef(
    item.activeModelRef,
    `${path}.activeModelRef`,
  );
  const activeGeneration = wireId(
    item.activeGeneration,
    `${path}.activeGeneration`,
  );
  const activeSelectionRevision = wireId(
    item.activeSelectionRevision,
    `${path}.activeSelectionRevision`,
  );
  const available = booleanValue(item.available, `${path}.available`);
  if ((activeModelRef === null) !== (activeGeneration === "0"))
    fail(path, "active model and generation must be present together");
  if (activeModelRef === null && activeSelectionRevision !== "0")
    fail(path, "an absent active model cannot publish a selection revision");
  if (state === "unavailable" && activeModelRef !== null)
    fail(path, "an unavailable admission cannot publish an active model");
  if (state === "ready" && activeModelRef === null)
    fail(path, "a ready admission requires an active model");
  if (state === "replacing" && available)
    fail(path, "a replacing admission cannot admit new Tasks");
  if (available && state !== "ready")
    fail(path, "Task admission requires ready installed authority");
  return {
    available,
    reason: enumValue(item.reason, `${path}.reason`, newTaskAdmissionReasons),
    activeModelRef,
    activeGeneration,
    activeSelectionRevision,
    state,
  };
}
function decodePresentationAnchor(value: unknown, path: string) {
  const item = object(value, path, ["afterOutputCount", "presentationOrder"]);
  const afterOutputCount = nonNegativeNumber(
    item.afterOutputCount,
    `${path}.afterOutputCount`,
  );
  if (afterOutputCount > 257) fail(path, "anchor exceeds output capacity");
  return {
    afterOutputCount,
    presentationOrder: positiveU64WireId(
      item.presentationOrder,
      `${path}.presentationOrder`,
    ),
  };
}
function decodeFileReference(value: unknown, path: string): FileReferenceView {
  const raw = record(value, path);
  const generated = Object.hasOwn(raw, "generatedImage");
  const item = object(value, path, [
    "id",
    "title",
    "displayPath",
    ...(generated ? ["generatedImage", "presentationAnchor"] : []),
  ]);
  if (generated && item.generatedImage !== true)
    fail(path, "invalid generated image attestation");
  return {
    ...(generated
      ? {
          generatedImage: true as const,
          presentationAnchor:
            item.presentationAnchor === null
              ? null
              : decodePresentationAnchor(
                  item.presentationAnchor,
                  `${path}.presentationAnchor`,
                ),
        }
      : {}),
    id: stringValue(item.id, `${path}.id`),
    title: stringValue(item.title, `${path}.title`),
    displayPath: stringValue(item.displayPath, `${path}.displayPath`),
  };
}
export function decodeFilePreview(value: unknown): FilePreviewResponse {
  const raw = record(value, "$");
  const hasImage = Object.hasOwn(raw, "image");
  const hasReason = Object.hasOwn(raw, "reason");
  const item = object(value, "$", [
    ...(hasImage ? ["image"] : []),
    ...(hasReason ? ["reason"] : []),
    "state",
    "content",
    "truncated",
    "redacted",
  ]);
  const state = enumValue(item.state, "$.state", [
    "ready",
    "busy",
    "stale_security",
    "missing",
    "restricted",
    "unsupported",
    "changing",
    "error",
  ] as const);
  const reason = hasReason
    ? enumValue(item.reason, "$.reason", [
        "image_limit",
        "animated_image",
      ] as const)
    : undefined;
  if (reason && state !== "unsupported")
    fail("$.reason", "reason requires unsupported preview");
  const content = stringValue(item.content, "$.content");
  const truncated = booleanValue(item.truncated, "$.truncated");
  const redacted = booleanValue(item.redacted, "$.redacted");
  let image: FilePreviewResponse["image"];
  if (hasImage) {
    const entry = object(item.image, "$.image", [
      "token",
      "mediaType",
      "sizeBytes",
      "width",
      "height",
      "chunkBytes",
      "securityEpoch",
    ]);
    const token = stringValue(entry.token, "$.image.token");
    const mediaType = enumValue(entry.mediaType, "$.image.mediaType", [
      "image/png",
      "image/jpeg",
      "image/webp",
    ] as const);
    const sizeBytes = Number(
      positiveU64WireId(entry.sizeBytes, "$.image.sizeBytes"),
    );
    const chunkBytes = Number(
      positiveU64WireId(entry.chunkBytes, "$.image.chunkBytes"),
    );
    const width = positiveNumber(entry.width, "$.image.width");
    const height = positiveNumber(entry.height, "$.image.height");
    const securityEpoch = positiveU64WireId(
      entry.securityEpoch,
      "$.image.securityEpoch",
    );
    if (
      state !== "ready" ||
      content !== "" ||
      truncated ||
      redacted ||
      !/^[a-f0-9]{48}$/.test(token) ||
      sizeBytes > 10 * 1024 * 1024 ||
      chunkBytes !== 262143 ||
      !Number.isInteger(width) ||
      !Number.isInteger(height) ||
      width > 8192 ||
      height > 8192 ||
      width * height > 16777216
    )
      fail("$.image", "invalid bounded original-image descriptor");
    image = {
      token,
      mediaType,
      sizeBytes,
      width,
      height,
      chunkBytes,
      securityEpoch,
    };
  }
  if (
    state !== "ready" &&
    (hasImage || content !== "" || truncated || redacted)
  )
    fail("$", "non-ready preview must not publish content or success facts");
  return {
    state,
    content,
    truncated,
    redacted,
    ...(image ? { image } : {}),
    ...(reason ? { reason } : {}),
  };
}
export function decodePreviewChunk(value: unknown) {
  const raw = record(value, "$");
  const state = enumValue(raw.state, "$.state", [
    "ready",
    "stale_security",
    "restricted",
    "expired",
    "error",
  ] as const);
  if (state !== "ready") {
    object(value, "$", ["state"]);
    return { state };
  }
  const item = object(value, "$", [
    "state",
    "token",
    "offset",
    "bytes",
    "dataBase64",
  ]);
  const token = stringValue(item.token, "$.token");
  const offset = Number(wireId(item.offset, "$.offset"));
  const bytes = Number(positiveU64WireId(item.bytes, "$.bytes"));
  const dataBase64 = stringValue(item.dataBase64, "$.dataBase64");
  if (
    !/^[a-f0-9]{48}$/.test(token) ||
    !Number.isSafeInteger(offset) ||
    bytes > 262143 ||
    dataBase64.length !== Math.ceil(bytes / 3) * 4 ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(dataBase64)
  )
    fail("$", "invalid preview image chunk");
  return { state, token, offset, bytes, dataBase64 };
}
export function decodePreviewRelease(
  value: unknown,
  generation: string,
  previewId: string,
) {
  const item = object(value, "$", ["generation", "previewId", "released"]);
  if (
    item.generation !== generation ||
    item.previewId !== previewId ||
    item.released !== true
  )
    fail("$", "invalid preview release confirmation");
}
export function decodeFileChangeDiff(value: unknown): FileChangeDiffResult {
  const recordValue = record(value, "$fileChangeDiff");
  const status = enumValue(recordValue.status, "$fileChangeDiff.status", [
    "ready",
    "unavailable",
  ] as const);
  if (status === "ready") {
    const item = object(value, "$fileChangeDiff", [
      "status",
      "content",
      "complete",
      "redacted",
    ]);
    return {
      status,
      content: stringValue(item.content, "$fileChangeDiff.content"),
      complete: booleanValue(item.complete, "$fileChangeDiff.complete"),
      redacted: booleanValue(item.redacted, "$fileChangeDiff.redacted"),
    };
  }
  const item = object(value, "$fileChangeDiff", [
    "status",
    "reason",
    "content",
  ]);
  const content = stringValue(item.content, "$fileChangeDiff.content");
  if (content !== "")
    fail("$fileChangeDiff.content", "must be empty when unavailable");
  return {
    status,
    reason: enumValue(item.reason, "$fileChangeDiff.reason", [
      "not_recorded",
      "capacity",
      "missing",
      "corrupt",
    ] as const),
    content: "",
  };
}
function decodeTool(value: unknown, path: string): ToolView {
  const item = object(value, path, [
    "bash",
    "presentation",
    "errorDetail",
    "id",
    "order",
    "name",
    "input",
    "progress",
    "content",
    "state",
    "isError",
    "elapsedMs",
    "inputTruncated",
    "progressTruncated",
    "contentTruncated",
    "redacted",
    "fileRefs",
  ]);
  const state = enumValue(item.state, `${path}.state`, [
    "running",
    "completed",
    "failed",
  ] as const);
  const isError = booleanValue(item.isError, `${path}.isError`);
  if ((state === "failed") !== isError)
    fail(path, "tool failure state and error flag must agree");
  const bash = decodeBashPresentation(item.bash, `${path}.bash`);
  const presentation = decodeToolPresentation(
    item.presentation,
    `${path}.presentation`,
  );
  const errorDetail =
    item.errorDetail === null
      ? null
      : stringValue(item.errorDetail, `${path}.errorDetail`);
  if (bash !== null && item.name !== "Bash")
    fail(path, "Bash presentation requires Bash identity");
  if (
    presentation !== null &&
    presentation.kind !== toolPresentationKind(item.name)
  )
    fail(path, "tool presentation does not match tool identity");
  if (presentation !== null && item.inputTruncated === true)
    fail(path, "truncated tool input cannot expose a typed presentation");
  if (errorDetail !== null && state !== "failed")
    fail(path, "tool error detail requires a failed tool");
  if (
    presentation !== null &&
    (presentation.kind === "bash_output" ||
      presentation.kind === "web_fetch") &&
    presentation.result !== null &&
    (state === "running" || item.contentTruncated === true)
  )
    fail(path, "unfinished or truncated tools cannot expose a typed result");
  if (bash?.result && (state === "running" || item.contentTruncated === true))
    fail(path, "unfinished or truncated tools cannot expose a Bash result");
  if (bash !== null && bash.command !== null && item.inputTruncated === true)
    fail(path, "truncated tool input cannot expose a Bash command");
  return {
    bash,
    presentation,
    errorDetail,
    id: stringValue(item.id, `${path}.id`),
    order: positiveWireId(item.order, `${path}.order`),
    name: stringValue(item.name, `${path}.name`),
    input: stringValue(item.input, `${path}.input`),
    progress: stringValue(item.progress, `${path}.progress`),
    content: stringValue(item.content, `${path}.content`),
    state,
    isError,
    elapsedMs: wireId(item.elapsedMs, `${path}.elapsedMs`),
    inputTruncated: booleanValue(item.inputTruncated, `${path}.inputTruncated`),
    progressTruncated: booleanValue(
      item.progressTruncated,
      `${path}.progressTruncated`,
    ),
    contentTruncated: booleanValue(
      item.contentTruncated,
      `${path}.contentTruncated`,
    ),
    redacted: booleanValue(item.redacted, `${path}.redacted`),
    fileRefs: arrayValue(
      item.fileRefs,
      `${path}.fileRefs`,
      decodeFileReference,
    ),
  };
}
function toolPresentationKind(name: unknown) {
  switch (name) {
    case "Read":
      return "read";
    case "Write":
      return "write";
    case "Edit":
      return "edit";
    case "Glob":
      return "glob";
    case "Grep":
      return "grep";
    case "BashOutput":
      return "bash_output";
    case "KillShell":
      return "kill_shell";
    case "WebSearch":
      return "web_search";
    case "WebFetch":
      return "web_fetch";
    default:
      return null;
  }
}
function decodeToolPresentation(
  value: unknown,
  path: string,
): ToolView["presentation"] {
  if (value === null) return null;
  const itemRecord = record(value, path);
  const kind = enumValue(itemRecord.kind, `${path}.kind`, [
    "read",
    "write",
    "edit",
    "glob",
    "grep",
    "bash_output",
    "kill_shell",
    "web_search",
    "web_fetch",
  ] as const);
  switch (kind) {
    case "read": {
      const item = object(value, path, ["kind", "target", "offset", "limit"]);
      return {
        kind,
        target: stringValue(item.target, `${path}.target`),
        offset:
          item.offset === null ? null : wireId(item.offset, `${path}.offset`),
        limit: item.limit === null ? null : wireId(item.limit, `${path}.limit`),
      };
    }
    case "write":
    case "edit": {
      const item = object(value, path, ["kind", "target"]);
      return { kind, target: stringValue(item.target, `${path}.target`) };
    }
    case "glob": {
      const item = object(value, path, ["kind", "pattern", "scope"]);
      return {
        kind,
        pattern: stringValue(item.pattern, `${path}.pattern`),
        scope:
          item.scope === null ? null : stringValue(item.scope, `${path}.scope`),
      };
    }
    case "grep": {
      const item = object(value, path, ["kind", "pattern", "scope", "include"]);
      return {
        kind,
        pattern: stringValue(item.pattern, `${path}.pattern`),
        scope:
          item.scope === null ? null : stringValue(item.scope, `${path}.scope`),
        include:
          item.include === null
            ? null
            : stringValue(item.include, `${path}.include`),
      };
    }
    case "bash_output": {
      const item = object(value, path, ["kind", "jobId", "result"]);
      if (item.result === null)
        return {
          kind,
          jobId: stringValue(item.jobId, `${path}.jobId`),
          result: null,
        };
      const result = object(item.result, `${path}.result`, [
        "status",
        "stdout",
        "stderr",
        "stdoutIncomplete",
        "stderrIncomplete",
      ]);
      return {
        kind,
        jobId: stringValue(item.jobId, `${path}.jobId`),
        result: {
          status: enumValue(result.status, `${path}.result.status`, [
            "running",
            "exited",
            "killed",
          ] as const),
          stdout: stringValue(result.stdout, `${path}.result.stdout`),
          stderr: stringValue(result.stderr, `${path}.result.stderr`),
          stdoutIncomplete: booleanValue(
            result.stdoutIncomplete,
            `${path}.result.stdoutIncomplete`,
          ),
          stderrIncomplete: booleanValue(
            result.stderrIncomplete,
            `${path}.result.stderrIncomplete`,
          ),
        },
      };
    }
    case "kill_shell": {
      const item = object(value, path, ["kind", "jobId"]);
      return { kind, jobId: stringValue(item.jobId, `${path}.jobId`) };
    }
    case "web_search": {
      const item = object(value, path, ["kind", "query"]);
      return { kind, query: stringValue(item.query, `${path}.query`) };
    }
    case "web_fetch": {
      const item = object(value, path, ["kind", "url", "prompt", "result"]);
      const prompt =
        item.prompt === null
          ? null
          : stringValue(item.prompt, `${path}.prompt`);
      if (item.result === null)
        return {
          kind,
          url: stringValue(item.url, `${path}.url`),
          prompt,
          result: null,
        };
      const result = object(item.result, `${path}.result`, [
        "url",
        "bytes",
        "content",
      ]);
      return {
        kind,
        url: stringValue(item.url, `${path}.url`),
        prompt,
        result: {
          url: stringValue(result.url, `${path}.result.url`),
          bytes:
            result.bytes === null
              ? null
              : wireId(result.bytes, `${path}.result.bytes`),
          content: stringValue(result.content, `${path}.result.content`),
        },
      };
    }
  }
}
function decodeBashPresentation(
  value: unknown,
  path: string,
): ToolView["bash"] {
  if (value === null) return null;
  const item = object(value, path, ["command", "description", "result"]);
  const command =
    item.command === null ? null : stringValue(item.command, `${path}.command`);
  const description =
    item.description === null
      ? null
      : stringValue(item.description, `${path}.description`);
  if (command === null && description !== null)
    fail(path, "description requires a parsed command");
  if (item.result === null) return { command, description, result: null };
  const result = object(item.result, `${path}.result`, [
    "exitCode",
    "stdout",
    "stderr",
    "stdoutIncomplete",
    "stderrIncomplete",
  ]);
  const exitCode = numberValue(result.exitCode, `${path}.result.exitCode`);
  if (
    !Number.isInteger(exitCode) ||
    exitCode < -2147483648 ||
    exitCode > 2147483647
  )
    fail(path, "expected i32 exit code");
  return {
    command,
    description,
    result: {
      exitCode,
      stdout: stringValue(result.stdout, `${path}.result.stdout`),
      stderr: stringValue(result.stderr, `${path}.result.stderr`),
      stdoutIncomplete: booleanValue(
        result.stdoutIncomplete,
        `${path}.result.stdoutIncomplete`,
      ),
      stderrIncomplete: booleanValue(
        result.stderrIncomplete,
        `${path}.result.stderrIncomplete`,
      ),
    },
  };
}
function decodeRunTerminal(value: unknown, path: string): RunView["terminal"] {
  return value === null
    ? null
    : (() => {
        const terminalItem = object(value, `${path}`, [
          "outcome",
          "cause",
          "diagnosticDisposition",
        ]);
        return {
          outcome: enumValue(
            terminalItem.outcome,
            `${path}.outcome`,
            runOutcomes,
          ),
          cause: nullableEnum(terminalItem.cause, `${path}.cause`, runCauses),
          diagnosticDisposition: enumValue(
            terminalItem.diagnosticDisposition,
            `${path}.diagnosticDisposition`,
            ["absent", "withheld"] as const,
          ),
        };
      })();
}
function decodeRunOutput(value: unknown, path: string): RunView["output"] {
  const outputItem = object(value, path, [
    "commentary",
    "response",
    "responseKind",
    "provisional",
    "redacted",
    "provisionalRedacted",
  ]);
  const commentary = arrayValue(
    outputItem.commentary,
    `${path}.commentary`,
    stringValue,
  );
  if (commentary.length > maxCommentarySegmentsPerRun)
    fail(`${path}.commentary`, "too many commentary segments");
  const output = {
    commentary,
    response: stringValue(outputItem.response, `${path}.response`),
    responseKind: nullableEnum(
      outputItem.responseKind,
      `${path}.responseKind`,
      ["final", "partial"] as const,
    ),
    provisional: stringValue(outputItem.provisional, `${path}.provisional`),
    redacted: booleanValue(outputItem.redacted, `${path}.redacted`),
    provisionalRedacted: booleanValue(
      outputItem.provisionalRedacted,
      `${path}.provisionalRedacted`,
    ),
  };
  return output;
}
function decodeRun(value: unknown, path: string): RunView {
  const item = object(value, path, [
    "elapsedMs",
    "submittedAtUnixMs",
    "finishedAtUnixMs",
    "id",
    "conversationCoverage",
    "phase",
    "permissionProfile",
    "permissionInteraction",
    "execution",
    "input",
    "submission",
    "additionalInputs",
    "output",
    "activity",
    "terminal",
    "usage",
    "tools",
    "fileChanges",
    "outputs",
  ]);
  const executionItem = object(item.execution, `${path}.execution`, [
    "generation",
    "protocol",
    "model",
  ]);
  const execution = {
    generation: positiveWireId(
      executionItem.generation,
      `${path}.execution.generation`,
    ),
    protocol: enumValue(
      executionItem.protocol,
      `${path}.execution.protocol`,
      protocols,
    ),
    model: stringValue(executionItem.model, `${path}.execution.model`),
  };
  const usage = object(item.usage, `${path}.usage`, [
    "input",
    "output",
    "cacheRead",
    "cacheCreation",
  ]);
  const phase = enumValue(item.phase, `${path}.phase`, runPhases);
  const terminal = decodeRunTerminal(item.terminal, `${path}.terminal`);
  validateRunTerminalState(phase, terminal, path);
  if (terminal?.cause === "provider_failure" && terminal.outcome !== "failed")
    fail(`${path}.terminal`, "provider failure must describe a failed Run");
  const output = decodeRunOutput(item.output, `${path}.output`);
  const activity = decodeRunActivity(item.activity, `${path}.activity`);
  const elapsedMs =
    item.elapsedMs === null
      ? null
      : wireId(item.elapsedMs, `${path}.elapsedMs`);
  if (
    elapsedMs !== null &&
    (elapsedMs.length > 20 ||
      (elapsedMs.length === 20 && elapsedMs > "18446744073709551615"))
  )
    fail(`${path}.elapsedMs`, "expected u64 elapsed milliseconds");
  const submittedAtUnixMs =
    item.submittedAtUnixMs === null
      ? null
      : wireId(item.submittedAtUnixMs, `${path}.submittedAtUnixMs`);
  if (
    submittedAtUnixMs !== null &&
    (submittedAtUnixMs === "0" ||
      submittedAtUnixMs.length > 16 ||
      (submittedAtUnixMs.length === 16 &&
        submittedAtUnixMs > "8640000000000000"))
  )
    fail(
      `${path}.submittedAtUnixMs`,
      "expected a displayable non-zero Unix millisecond timestamp",
    );
  const finishedAtUnixMs =
    item.finishedAtUnixMs === null
      ? null
      : wireId(item.finishedAtUnixMs, `${path}.finishedAtUnixMs`);
  if (
    finishedAtUnixMs !== null &&
    (finishedAtUnixMs === "0" ||
      finishedAtUnixMs.length > 16 ||
      (finishedAtUnixMs.length === 16 && finishedAtUnixMs > "8640000000000000"))
  )
    fail(
      `${path}.finishedAtUnixMs`,
      "expected a displayable non-zero Unix millisecond timestamp",
    );
  const isTerminal = terminal !== null;
  if (!isTerminal && finishedAtUnixMs !== null)
    fail(path, "active Run cannot expose a finished time");
  if (isTerminal !== (activity === null))
    fail(path, "Run phase and activity must describe the same terminal state");
  if (phase === "queued" && activity?.kind !== "queued")
    fail(path, "queued Run must expose queued activity");
  if (phase === "waiting_ui" && activity?.kind !== "waiting_user")
    fail(path, "waiting Run must expose waiting_user activity");
  if (phase === "stopping" && activity?.kind !== "stopping")
    fail(path, "stopping Run must expose stopping activity");
  if (
    phase === "running" &&
    (activity?.kind === "queued" || activity?.kind === "stopping")
  )
    fail(path, "running Run cannot expose a phase-owned activity");
  if (output.responseKind === null && output.response !== "")
    fail(path, "unclassified output cannot publish a response");
  if (output.responseKind !== null && output.provisional !== "")
    fail(path, "classified response cannot retain provisional output");
  if (isTerminal && output.provisional !== "")
    fail(path, "terminal Run cannot retain provisional output");
  return {
    id: positiveWireId(item.id, `${path}.id`),
    conversationCoverage: enumValue(
      item.conversationCoverage,
      `${path}.conversationCoverage`,
      ["included", "excluded"] as const,
    ),
    phase,
    permissionProfile: enumValue(
      item.permissionProfile,
      `${path}.permissionProfile`,
      permissionProfiles,
    ),
    permissionInteraction: enumValue(
      item.permissionInteraction,
      `${path}.permissionInteraction`,
      permissionInteractions,
    ),
    execution,
    submission:
      item.submission === null
        ? null
        : decodeInputSubmission(item.submission, `${path}.submission`),
    input: decodeRunInput(item.input, `${path}.input`),
    additionalInputs: decodeAdditionalInputs(
      item.additionalInputs,
      `${path}.additionalInputs`,
    ),
    output,
    activity,
    elapsedMs,
    submittedAtUnixMs,
    finishedAtUnixMs,
    terminal,
    usage: {
      input: wireId(usage.input, `${path}.usage.input`),
      output: wireId(usage.output, `${path}.usage.output`),
      cacheRead: wireId(usage.cacheRead, `${path}.usage.cacheRead`),
      cacheCreation: wireId(usage.cacheCreation, `${path}.usage.cacheCreation`),
    },
    tools: arrayValue(item.tools, `${path}.tools`, decodeTool),
    fileChanges: decodeRunFileChanges(item.fileChanges, `${path}.fileChanges`),
    outputs: decodeDeliveredOutputs(item.outputs, `${path}.outputs`),
  };
}
function decodeDeliveredOutputs(
  value: unknown,
  path: string,
): RunView["outputs"] {
  if (!Array.isArray(value) || value.length > 8)
    fail(path, "expected bounded delivered outputs");
  const ids = new Set<string>();
  return value.map((raw, index) => {
    const itemPath = `${path}[${index}]`;
    const item = object(raw, itemPath, [
      "id",
      "displayPath",
      "sizeBytes",
      "redacted",
    ]);
    const id = stringValue(item.id, `${itemPath}.id`);
    if (!/^[0-9a-f]{32}$/.test(id) || /^0+$/.test(id) || ids.has(id))
      fail(itemPath, "invalid or repeated output identity");
    ids.add(id);
    const displayPath = stringValue(
      item.displayPath,
      `${itemPath}.displayPath`,
    );
    const redacted = booleanValue(item.redacted, `${itemPath}.redacted`);
    if (
      redacted
        ? displayPath !== ""
        : displayPath.length === 0 ||
          new TextEncoder().encode(displayPath).length > 512 ||
          /[\u0000-\u001f\u007f\\:<>"|?*]/.test(displayPath) ||
          displayPath
            .split("/")
            .some(
              (part) =>
                !part || part === "." || part === ".." || /[. ]$/.test(part),
            )
    )
      fail(itemPath, "invalid output display path");
    return {
      id,
      displayPath,
      sizeBytes: u64WireInteger(item.sizeBytes, `${itemPath}.sizeBytes`),
      redacted,
    };
  });
}
function decodeRunFileChanges(
  value: unknown,
  path: string,
): RunView["fileChanges"] {
  if (value === null) return null;
  const item = object(value, path, ["observation", "changes"]);
  const observation = enumValue(item.observation, `${path}.observation`, [
    "collecting",
    "complete",
    "incomplete",
  ] as const);
  const changes = arrayValue(
    item.changes,
    `${path}.changes`,
    (value, itemPath) => {
      const change = object(value, itemPath, [
        "id",
        "order",
        "kind",
        "status",
        "displayPath",
        "fromDisplayPath",
        "beforeBytes",
        "afterBytes",
        "diffAvailable",
        "diffComplete",
        "redacted",
      ]);
      const kind = enumValue(change.kind, `${itemPath}.kind`, [
        "created",
        "modified",
        "deleted",
        "moved",
      ] as const);
      const fromDisplayPath =
        change.fromDisplayPath === null
          ? null
          : stringValue(change.fromDisplayPath, `${itemPath}.fromDisplayPath`);
      if ((kind === "moved") !== (fromDisplayPath !== null))
        fail(itemPath, "moved changes alone require a source path");
      return {
        id: stringValue(change.id, `${itemPath}.id`),
        order: positiveWireId(change.order, `${itemPath}.order`),
        kind,
        status: enumValue(change.status, `${itemPath}.status`, [
          "applied",
          "partial",
        ] as const),
        displayPath: stringValue(change.displayPath, `${itemPath}.displayPath`),
        fromDisplayPath,
        beforeBytes: wireId(change.beforeBytes, `${itemPath}.beforeBytes`),
        afterBytes: wireId(change.afterBytes, `${itemPath}.afterBytes`),
        diffAvailable: booleanValue(
          change.diffAvailable,
          `${itemPath}.diffAvailable`,
        ),
        diffComplete: booleanValue(
          change.diffComplete,
          `${itemPath}.diffComplete`,
        ),
        redacted: booleanValue(change.redacted, `${itemPath}.redacted`),
      };
    },
  );
  return { observation, changes };
}
function decodeRunActivity(value: unknown, path: string): RunActivity | null {
  if (value === null) return null;
  const kind = stringValue(record(value, path).kind, `${path}.kind`);
  if ((simpleRunActivities as readonly string[]).includes(kind)) {
    const item = object(value, path, ["kind"]);
    return {
      kind: enumValue(item.kind, `${path}.kind`, simpleRunActivities),
    };
  }
  if (kind === "executing_tools") {
    const item = object(value, path, ["kind", "inFlight"]);
    return {
      kind,
      inFlight:
        item.inFlight === null
          ? null
          : positiveWireId(item.inFlight, `${path}.inFlight`),
    };
  }
  if (kind === "retrying_provider") {
    const item = object(value, path, ["kind", "attempt", "max", "delayMs"]);
    const attempt =
      item.attempt === null
        ? null
        : positiveWireId(item.attempt, `${path}.attempt`);
    const max =
      item.max === null ? null : positiveWireId(item.max, `${path}.max`);
    const delayMs =
      item.delayMs === null ? null : wireId(item.delayMs, `${path}.delayMs`);
    if (
      (attempt === null || max === null || delayMs === null) &&
      (attempt !== null || max !== null || delayMs !== null)
    )
      fail(path, "retry details must be either complete or absent");
    if (attempt !== null && max !== null && BigInt(attempt) > BigInt(max))
      fail(path, "retry attempt cannot exceed max");
    return { kind, attempt, max, delayMs };
  }
  return fail(`${path}.kind`, "unexpected Run activity");
}
function decodeConversationContext(value: unknown, path: string) {
  const item = object(value, path, ["pressure", "lastAutoCompact"]);
  const pressure =
    item.pressure === null
      ? null
      : (() => {
          const pressureItem = object(item.pressure, `${path}.pressure`, [
            "sourceRunId",
            "currentTokens",
            "warningThreshold",
            "autoCompactThreshold",
            "blockingLimit",
            "severity",
          ]);
          const result = {
            sourceRunId: positiveWireId(
              pressureItem.sourceRunId,
              `${path}.pressure.sourceRunId`,
            ),
            currentTokens: wireId(
              pressureItem.currentTokens,
              `${path}.pressure.currentTokens`,
            ),
            warningThreshold: positiveWireId(
              pressureItem.warningThreshold,
              `${path}.pressure.warningThreshold`,
            ),
            autoCompactThreshold: positiveWireId(
              pressureItem.autoCompactThreshold,
              `${path}.pressure.autoCompactThreshold`,
            ),
            blockingLimit: positiveWireId(
              pressureItem.blockingLimit,
              `${path}.pressure.blockingLimit`,
            ),
            severity: enumValue(
              pressureItem.severity,
              `${path}.pressure.severity`,
              ["warning", "critical"] as const,
            ),
          };
          const current = BigInt(result.currentTokens);
          const warning = BigInt(result.warningThreshold);
          const compact = BigInt(result.autoCompactThreshold);
          const blocking = BigInt(result.blockingLimit);
          if (!(
            warning <= compact &&
            compact <= blocking &&
            current >= warning
          ))
            fail(`${path}.pressure`, "context thresholds are inconsistent");
          if (current >= compact !== (result.severity === "critical"))
            fail(
              `${path}.pressure`,
              "context severity disagrees with pressure",
            );
          return result;
        })();
  const lastAutoCompact =
    item.lastAutoCompact === null
      ? null
      : (() => {
          const compactItem = object(
            item.lastAutoCompact,
            `${path}.lastAutoCompact`,
            ["sourceRunId", "dropped", "kept", "beforeTokens", "afterTokens"],
          );
          const result = {
            sourceRunId: positiveWireId(
              compactItem.sourceRunId,
              `${path}.lastAutoCompact.sourceRunId`,
            ),
            dropped: wireId(
              compactItem.dropped,
              `${path}.lastAutoCompact.dropped`,
            ),
            kept: wireId(compactItem.kept, `${path}.lastAutoCompact.kept`),
            beforeTokens: wireId(
              compactItem.beforeTokens,
              `${path}.lastAutoCompact.beforeTokens`,
            ),
            afterTokens: wireId(
              compactItem.afterTokens,
              `${path}.lastAutoCompact.afterTokens`,
            ),
          };
          const before = BigInt(result.beforeTokens);
          const after = BigInt(result.afterTokens);
          if (!(
            (before === 0n && after === 0n) ||
            (before > 0n && after <= before)
          ))
            fail(
              `${path}.lastAutoCompact`,
              "compact token counts are inconsistent",
            );
          return result;
        })();
  return { pressure, lastAutoCompact };
}
function decodeCompact(value: unknown, path: string): CompactView {
  const item = object(value, path, [
    "operationId",
    "afterRunId",
    "conversationCoverage",
    "phase",
    "cause",
    "beforeContextTokens",
    "afterContextTokens",
    "usage",
  ]);
  const phase = enumValue(item.phase, `${path}.phase`, compactPhases);
  const cause = nullableEnum(item.cause, `${path}.cause`, compactCauses);
  const terminalFailure = phase === "aborted" || phase === "failed";
  if (terminalFailure !== (cause !== null))
    fail(path, "Compact phase and cause must describe the same terminal state");
  const usage = object(item.usage, `${path}.usage`, [
    "input",
    "output",
    "cacheRead",
    "cacheCreation",
  ]);
  return {
    operationId: positiveWireId(item.operationId, `${path}.operationId`),
    afterRunId: positiveWireId(item.afterRunId, `${path}.afterRunId`),
    conversationCoverage: enumValue(
      item.conversationCoverage,
      `${path}.conversationCoverage`,
      ["included", "excluded"] as const,
    ),
    phase,
    cause,
    beforeContextTokens: wireId(
      item.beforeContextTokens,
      `${path}.beforeContextTokens`,
    ),
    afterContextTokens: wireId(
      item.afterContextTokens,
      `${path}.afterContextTokens`,
    ),
    usage: {
      input: wireId(usage.input, `${path}.usage.input`),
      output: wireId(usage.output, `${path}.usage.output`),
      cacheRead: wireId(usage.cacheRead, `${path}.usage.cacheRead`),
      cacheCreation: wireId(usage.cacheCreation, `${path}.usage.cacheCreation`),
    },
  };
}
function validateRunTerminalState(
  phase: RunView["phase"],
  terminal: RunView["terminal"],
  path: string,
) {
  const outcome = terminal?.outcome ?? null;
  switch (phase) {
    case "queued":
    case "running":
    case "waiting_ui":
    case "stopping":
      if (outcome !== null)
        fail(path, "a non-terminal Run cannot have an outcome");
      return;
    case "completed":
      if (outcome !== "completed")
        fail(path, "completed Run phase and outcome must agree");
      return;
    case "stopped":
      if (outcome !== "stopped")
        fail(path, "stopped Run phase and outcome must agree");
      return;
    case "cancelled":
      if (outcome !== "cancelled")
        fail(path, "cancelled Run phase and outcome must agree");
      return;
    case "interrupted":
      if (outcome !== "interrupted")
        fail(path, "interrupted Run phase and outcome must agree");
      return;
    case "failed":
      if (outcome !== "failed" && outcome !== "dependency_contract_failure")
        fail(path, "failed Run phase and outcome must agree");
  }
}
function decodePermissionHistory(
  value: unknown,
  path: string,
): PermissionHistory {
  const item = object(value, path, [
    "requestId",
    "matchedRuleId",
    "toolNamespace",
    "toolName",
    "toolBinding",
    "canonicalArgumentsDigest",
    "decision",
    "source",
    "policyGeneration",
    "usedSessionRule",
    "callbackOutcome",
  ]);
  return {
    requestId: nonEmptyString(item.requestId, `${path}.requestId`),
    matchedRuleId: stringValue(item.matchedRuleId, `${path}.matchedRuleId`),
    toolNamespace: enumValue(item.toolNamespace, `${path}.toolNamespace`, [
      "builtin",
      "host",
      "mcp",
    ] as const),
    toolName: nonEmptyString(item.toolName, `${path}.toolName`),
    toolBinding: nonEmptyString(item.toolBinding, `${path}.toolBinding`),
    canonicalArgumentsDigest: stringValue(
      item.canonicalArgumentsDigest,
      `${path}.canonicalArgumentsDigest`,
    ),
    decision: enumValue(item.decision, `${path}.decision`, [
      "allow",
      "ask",
      "deny",
    ] as const),
    source: enumValue(item.source, `${path}.source`, permissionDecisionSources),
    policyGeneration: wireId(item.policyGeneration, `${path}.policyGeneration`),
    usedSessionRule: booleanValue(
      item.usedSessionRule,
      `${path}.usedSessionRule`,
    ),
    callbackOutcome: nullableEnum(
      item.callbackOutcome,
      `${path}.callbackOutcome`,
      permissionCallbackOutcomes,
    ),
  };
}
function decodeUiRecord(value: unknown, path: string): UiRecord {
  const item = object(value, path, [
    "requestId",
    "runId",
    "order",
    "kind",
    "state",
    "agentRequestId",
    "permission",
    "detail",
    "itemCount",
    "detailTruncated",
    "redacted",
    "answeredBy",
    "reviewReason",
  ]);
  const kind = enumValue(item.kind, `${path}.kind`, uiRecordKinds);
  const agentRequestId = stringValue(
    item.agentRequestId,
    `${path}.agentRequestId`,
  );
  const permission =
    item.permission === null
      ? null
      : decodePermissionHistory(item.permission, `${path}.permission`);
  if (permission !== null && permission.requestId !== agentRequestId)
    fail(`${path}.permission`, "permission request identity must match record");
  const state = enumValue(item.state, `${path}.state`, uiRecordStates);
  const answeredBy = nullableEnum(item.answeredBy, `${path}.answeredBy`, [
    "user",
    "reviewer",
  ] as const);
  const reviewReason =
    item.reviewReason === null
      ? null
      : nonEmptyString(item.reviewReason, `${path}.reviewReason`);
  if (
    (state === "cancelled") !== (answeredBy === null) ||
    (answeredBy === "reviewer") !== (reviewReason !== null) ||
    (answeredBy === "reviewer" &&
      state !== "allowed_once" &&
      state !== "denied") ||
    (reviewReason !== null &&
      (new TextEncoder().encode(reviewReason).length > 512 ||
        reviewReason.trim().length === 0 ||
        /[\u0000-\u001f\u007f]/u.test(reviewReason)))
  )
    fail(path, "invalid permission review audit");
  return {
    requestId: positiveWireId(item.requestId, `${path}.requestId`),
    runId: positiveWireId(item.runId, `${path}.runId`),
    order: positiveWireId(item.order, `${path}.order`),
    kind,
    state,
    answeredBy,
    reviewReason,
    agentRequestId,
    permission,
    detail: stringValue(item.detail, `${path}.detail`),
    itemCount: nonNegativeNumber(item.itemCount, `${path}.itemCount`),
    detailTruncated: booleanValue(
      item.detailTruncated,
      `${path}.detailTruncated`,
    ),
    redacted: booleanValue(item.redacted, `${path}.redacted`),
  };
}
function decodePermissionPresentation(
  value: unknown,
  path: string,
  namespace: unknown,
  tool: unknown,
): PendingUi["presentation"] {
  if (value === null) return null;
  const kind = enumValue((value as JsonObject)?.kind, `${path}.kind`, [
    "command",
    "read",
    "write",
    "edit",
    "web_fetch",
  ] as const);
  const tools = {
    command: "Bash",
    read: "Read",
    write: "Write",
    edit: "Edit",
    web_fetch: "WebFetch",
  };
  if (namespace !== "builtin" || tool !== tools[kind])
    fail(path, "presentation must match the built-in request identity");
  const item = object(
    value,
    path,
    kind === "command"
      ? ["kind", "command", "description"]
      : ["kind", "target"],
  );
  if (kind === "command")
    return {
      kind,
      command: stringValue(item.command, `${path}.command`),
      description:
        item.description === null
          ? null
          : stringValue(item.description, `${path}.description`),
    };
  return { kind, target: stringValue(item.target, `${path}.target`) };
}

function decodePendingUi(value: unknown, path: string): PendingUi | null {
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value))
    fail(path, "expected request object or null");
  const kind = stringValue((value as JsonObject).kind, `${path}.kind`);
  if (kind === "permission") {
    const item = object(value, path, [
      "requestId",
      "runId",
      "order",
      "redacted",
      "kind",
      "toolNamespace",
      "tool",
      "toolBinding",
      "args",
      "presentation",
      "availableChoices",
      "policyGeneration",
      "canonicalArgumentsDigest",
      "candidate",
    ]);
    const availableChoices = arrayValue(
      item.availableChoices,
      `${path}.availableChoices`,
      (choice, choicePath) => enumValue(choice, choicePath, permissionChoices),
    );
    if (availableChoices.length === 0)
      fail(
        `${path}.availableChoices`,
        "permission request must expose a choice",
      );
    if (new Set(availableChoices).size !== availableChoices.length)
      fail(`${path}.availableChoices`, "permission choices must be unique");
    const candidate =
      item.candidate === null
        ? null
        : (() => {
            const scope = enumValue(
              (item.candidate as JsonObject)?.scope,
              `${path}.candidate.scope`,
              ["exact_arguments", "file_target"] as const,
            );
            const candidateItem = object(
              item.candidate,
              `${path}.candidate`,
              scope === "file_target"
                ? ["ruleId", "scope", "target"]
                : ["ruleId", "scope"],
            );
            const ruleId = nonEmptyString(
              candidateItem.ruleId,
              `${path}.candidate.ruleId`,
            );
            if (scope === "file_target") {
              if (
                item.toolNamespace !== "builtin" ||
                (item.tool !== "Write" && item.tool !== "Edit")
              )
                fail(
                  `${path}.candidate.scope`,
                  "file_target requires built-in Write or Edit",
                );
              return {
                ruleId,
                scope,
                target: nonEmptyString(
                  candidateItem.target,
                  `${path}.candidate.target`,
                ),
              };
            }
            return { ruleId, scope };
          })();
    if (
      candidate === null &&
      availableChoices.some(
        (choice) => choice === "allow_session" || choice === "deny_session",
      )
    )
      fail(
        `${path}.availableChoices`,
        "Session choices require a permission candidate",
      );
    return {
      presentation: decodePermissionPresentation(
        item.presentation,
        `${path}.presentation`,
        item.toolNamespace,
        item.tool,
      ),
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      order: positiveWireId(item.order, `${path}.order`),
      redacted: booleanValue(item.redacted, `${path}.redacted`),
      kind,
      toolNamespace: enumValue(item.toolNamespace, `${path}.toolNamespace`, [
        "builtin",
        "host",
        "mcp",
      ] as const),
      tool: stringValue(item.tool, `${path}.tool`),
      toolBinding: nonEmptyString(item.toolBinding, `${path}.toolBinding`),
      args: stringValue(item.args, `${path}.args`),
      availableChoices,
      policyGeneration: positiveWireId(
        item.policyGeneration,
        `${path}.policyGeneration`,
      ),
      canonicalArgumentsDigest: nonEmptyString(
        item.canonicalArgumentsDigest,
        `${path}.canonicalArgumentsDigest`,
      ),
      candidate,
    };
  }
  return fail(`${path}.kind`, "unexpected request kind");
}
function decodeTaskMcpAuthority(
  value: unknown,
  path: string,
): TaskView["mcpAuthority"] {
  const item = object(value, path, ["kind", "selection"]);
  const kind = enumValue(item.kind, `${path}.kind`, [
    "ready",
    "unavailable",
  ] as const);
  if (kind === "ready") {
    return {
      kind,
      selection: enumValue(item.selection, `${path}.selection`, [
        "selected",
        "none",
      ] as const),
    };
  }
  if (item.selection !== null)
    fail(`${path}.selection`, "unavailable authority cannot have a selection");
  return { kind, selection: null };
}
function decodeTaskApprovalChange(
  value: unknown,
  path: string,
): TaskApprovalChange {
  const item = object(value, path, ["revision", "targetMode", "state"]);
  return {
    revision: positiveWireId(item.revision, `${path}.revision`),
    targetMode: enumValue(item.targetMode, `${path}.targetMode`, approvalModes),
    state: enumValue(item.state, `${path}.state`, [
      "pending",
      "recovering",
      "outcome_unknown",
    ] as const),
  };
}
function decodeTaskApprovalResult(
  value: unknown,
  path: string,
): TaskApprovalResult {
  const item = decodeTaskApprovalResultWire(value, path);
  const { revision, outcome, reason } = item;
  if (outcome === "completed") {
    if (reason !== null) fail(`${path}.reason`, "expected null");
    return { revision, outcome, reason: null };
  }
  if (reason === null) fail(`${path}.reason`, "expected failure reason");
  return { revision, outcome, reason };
}
function inputOperationId(value: unknown, path: string): string {
  const id = stringValue(value, path);
  if (!/^[!-~]{1,64}$/.test(id))
    fail(path, "expected bounded printable operation identity");
  return id;
}
function decodeTask(
  value: unknown,
  path: string,
  manifest: RunManifest[],
): TaskView {
  const item = object(value, path, [
    "inputReady",
    "inputAcceptance",
    "inputSubmissions",
    "id",
    "recentOrder",
    "title",
    "workspaceId",
    "permissionProfile",
    "approvalMode",
    "approvalRevision",
    "availableApprovalModes",
    "approvalChange",
    "approvalResult",
    "permissionReviewState",
    "permissionReviewExplanation",
    "binding",
    "modelIntent",
    "modelSelectionAvailability",
    "mcpAuthority",
    "skillCatalog",
    "lifecycle",
    "deletionStatus",
    "continuationAvailable",
    "continuationUnavailableReason",
    "continuationRecoveryAvailable",
    "archived",
    "unreadCompletionRunId",
    "restorePermission",
    "activeOperation",
    "currentRunId",
    "currentRunPhase",
    "context",
    "runs",
    "compacts",
    "pendingUi",
    "uiHistory",
  ]);
  const bindingItem = object(item.binding, `${path}.binding`, [
    "epoch",
    "availability",
    "protocol",
    "model",
    "executionGeneration",
    "unavailableReason",
  ]);
  const availability = enumValue(
    bindingItem.availability,
    `${path}.binding.availability`,
    bindingAvailabilities,
  );
  const unavailableReason = nullableEnum(
    bindingItem.unavailableReason,
    `${path}.binding.unavailableReason`,
    ["runtime_detached"] as const,
  );
  if ((availability === "available") !== (unavailableReason === null))
    fail(
      `${path}.binding`,
      "availability and unavailable reason must describe the same binding state",
    );
  const binding = {
    epoch: positiveWireId(bindingItem.epoch, `${path}.binding.epoch`),
    availability,
    protocol: enumValue(
      bindingItem.protocol,
      `${path}.binding.protocol`,
      protocols,
    ),
    model: stringValue(bindingItem.model, `${path}.binding.model`),
    executionGeneration: positiveWireId(
      bindingItem.executionGeneration,
      `${path}.binding.executionGeneration`,
    ),
    unavailableReason,
  };
  const modelIntent =
    item.modelIntent === null
      ? null
      : (() => {
          const intent = object(item.modelIntent, `${path}.modelIntent`, [
            "modelRef",
            "selectionRevision",
            "state",
          ]);
          const selectionRevision = positiveU64WireId(
            intent.selectionRevision,
            `${path}.modelIntent.selectionRevision`,
          );
          return {
            modelRef: decodeRequiredModelRef(
              intent.modelRef,
              `${path}.modelIntent.modelRef`,
            ),
            selectionRevision,
            state: enumValue(intent.state, `${path}.modelIntent.state`, [
              "committed",
              "outcome_unknown",
            ] as const),
          };
        })();
  const modelSelectionAvailability = enumValue(
    item.modelSelectionAvailability,
    `${path}.modelSelectionAvailability`,
    [
      "available",
      "catalog_loading",
      "catalog_unavailable",
      "task_unavailable",
    ] as const,
  );
  const mcpAuthority = decodeTaskMcpAuthority(
    item.mcpAuthority,
    `${path}.mcpAuthority`,
  );
  const runs = arrayValue(item.runs, `${path}.runs`, decodeRun);
  if (new Set(runs.map((run) => run.id)).size !== runs.length)
    fail(path, "duplicate loaded Run");
  for (const run of runs) {
    const fact = manifest.find((entry) => entry.id === run.id);
    if (
      !fact ||
      fact.phase !== run.phase ||
      fact.permissionProfile !== run.permissionProfile ||
      fact.permissionInteraction !== run.permissionInteraction ||
      JSON.stringify(fact.terminal) !== JSON.stringify(run.terminal)
    )
      fail(path, "Run page disagrees with its manifest");
  }
  for (const run of runs) {
    for (const input of run.additionalInputs) {
      if (
        input.transferredToRunId !== null &&
        (BigInt(input.transferredToRunId) <= BigInt(run.id) ||
          !manifest.some((target) => target.id === input.transferredToRunId))
      )
        fail(path, "input transfer must target a later Run in the same Task");
      if (
        (input.state === "continuing" || input.state === "transferred") &&
        run.terminal?.outcome !== "completed"
      )
        fail(
          path,
          "only a normally completed Run can await input continuation",
        );
    }
  }
  const permissionProfile = enumValue(
    item.permissionProfile,
    `${path}.permissionProfile`,
    permissionProfiles,
  );
  const approvalMode = enumValue(
    item.approvalMode,
    `${path}.approvalMode`,
    approvalModes,
  );
  const approvalRevision = positiveWireId(
    item.approvalRevision,
    `${path}.approvalRevision`,
  );
  const availableApprovalModes = arrayValue(
    item.availableApprovalModes,
    `${path}.availableApprovalModes`,
    (mode, modePath) => enumValue(mode, modePath, approvalModes),
  );
  if (new Set(availableApprovalModes).size !== availableApprovalModes.length)
    fail(`${path}.availableApprovalModes`, "duplicate approval mode");
  const approvalChange =
    item.approvalChange === null
      ? null
      : decodeTaskApprovalChange(item.approvalChange, `${path}.approvalChange`);
  const approvalResult =
    item.approvalResult === null
      ? null
      : decodeTaskApprovalResult(item.approvalResult, `${path}.approvalResult`);
  if (
    approvalChange &&
    (availableApprovalModes.length !== 0 || approvalResult !== null)
  )
    fail(
      path,
      "pending approval change cannot admit another intent or publish a result",
    );
  if (
    approvalChange &&
    BigInt(approvalChange.revision) !== BigInt(approvalRevision) &&
    BigInt(approvalChange.revision) !== BigInt(approvalRevision) + 1n
  )
    fail(path, "approval intent must reference the current or next revision");
  if (
    approvalResult?.outcome === "completed" &&
    approvalResult.revision !== approvalRevision
  )
    fail(path, "completed approval result must match the committed revision");
  const permissionReviewState = enumValue(
    item.permissionReviewState,
    `${path}.permissionReviewState`,
    ["idle", "reviewing", "needs_user"] as const,
  );
  let permissionReviewExplanation: TaskView["permissionReviewExplanation"] =
    null;
  if (item.permissionReviewExplanation !== null) {
    const explanationPath = `${path}.permissionReviewExplanation`;
    const explanation = object(
      item.permissionReviewExplanation,
      explanationPath,
      ["cause", "reason"],
    );
    const cause = enumValue(explanation.cause, `${explanationPath}.cause`, [
      "unavailable",
      "reviewer_concern",
      "context_incomplete",
      "timeout",
      "call_failed",
      "invalid_response",
      "capacity",
      "unsupported_tool",
      "input_changed",
      "state_changed",
    ] as const);
    const reason =
      explanation.reason === null
        ? null
        : nonEmptyString(explanation.reason, `${explanationPath}.reason`);
    if (
      permissionReviewState !== "needs_user" ||
      (reason !== null &&
        (cause !== "reviewer_concern" ||
          new TextEncoder().encode(reason).length > 512 ||
          reason.trim().length === 0 ||
          /[\u0000-\u001f\u007f]/u.test(reason)))
    )
      fail(
        explanationPath,
        "expected a bounded explanation for the current manual handoff",
      );
    permissionReviewExplanation = { cause, reason };
  }
  if (
    (approvalMode === "full_access") !==
      (permissionProfile === "full_access") ||
    (approvalMode !== "auto_review" && permissionReviewState !== "idle")
  )
    fail(path, "approval mode must match session execution facts");
  if (
    runs.some(
      (run) =>
        run.terminal === null && run.permissionProfile !== permissionProfile,
    )
  )
    fail(
      path,
      "active Run permission provenance must match the current Task profile",
    );
  const context = decodeConversationContext(item.context, `${path}.context`);
  const compacts = arrayValue(item.compacts, `${path}.compacts`, decodeCompact);
  const lifecycle = enumValue(
    item.lifecycle,
    `${path}.lifecycle`,
    taskLifecycles,
  );
  const deletionStatus = enumValue(
    item.deletionStatus,
    `${path}.deletionStatus`,
    ["idle", "deleting", "failed"] as const,
  );
  const continuationAvailable = booleanValue(
    item.continuationAvailable,
    `${path}.continuationAvailable`,
  );
  const continuationUnavailableReason = nullableEnum(
    item.continuationUnavailableReason,
    `${path}.continuationUnavailableReason`,
    [
      "session_poisoned",
      "closing",
      "task_archived",
      "session_recovery_required",
      "session_recovery_in_progress",
      "session_recovery_failed",
      "persistence_unavailable",
      "checkpoint_unavailable",
      "execution_rebind_required",
      "workspace_unavailable",
      "authority_unavailable",
      "runtime_unavailable",
      "history_read_only",
    ] as const,
  );
  if (continuationAvailable !== (continuationUnavailableReason === null))
    fail(path, "continuation availability and unavailable reason must agree");
  const archived = booleanValue(item.archived, `${path}.archived`);
  const unreadCompletionRunId =
    item.unreadCompletionRunId === null
      ? null
      : positiveWireId(
          item.unreadCompletionRunId,
          `${path}.unreadCompletionRunId`,
        );
  if (unreadCompletionRunId !== null) {
    let latestTerminal: RunManifest | null = null;
    for (const run of manifest) {
      if (
        run.terminal !== null &&
        (latestTerminal === null || BigInt(run.id) > BigInt(latestTerminal.id))
      )
        latestTerminal = run;
    }
    if (
      archived ||
      latestTerminal?.id !== unreadCompletionRunId ||
      latestTerminal.terminal?.outcome !== "completed"
    )
      fail(
        `${path}.unreadCompletionRunId`,
        "unread completion must reference the latest terminal completed Run",
      );
  }
  if (deletionStatus === "deleting" && lifecycle !== "closing")
    fail(path, "an in-progress deletion must have closing lifecycle");
  const restorePermission =
    item.restorePermission === null
      ? null
      : (() => {
          const summary = object(
            item.restorePermission,
            `${path}.restorePermission`,
            ["restoredRules", "invalidatedRules"],
          );
          return {
            restoredRules: wireId(
              summary.restoredRules,
              `${path}.restorePermission.restoredRules`,
            ),
            invalidatedRules: wireId(
              summary.invalidatedRules,
              `${path}.restorePermission.invalidatedRules`,
            ),
          };
        })();
  const continuationRecoveryAvailable = booleanValue(
    item.continuationRecoveryAvailable,
    `${path}.continuationRecoveryAvailable`,
  );
  const currentRunId = wireId(item.currentRunId, `${path}.currentRunId`);
  const currentRunPhase = nullableEnum(
    item.currentRunPhase,
    `${path}.currentRunPhase`,
    nonTerminalRunPhases,
  );
  const activeOperation =
    item.activeOperation === null
      ? null
      : (() => {
          const operation = object(
            item.activeOperation,
            `${path}.activeOperation`,
            ["kind", "id"],
          );
          return {
            kind: enumValue(operation.kind, `${path}.activeOperation.kind`, [
              "run",
              "compact",
              "restore",
            ] as const),
            id: positiveWireId(operation.id, `${path}.activeOperation.id`),
          };
        })();
  if ((currentRunId === "0") !== (currentRunPhase === null))
    fail(path, "current Run identity and phase must both be present or absent");
  if (currentRunPhase !== null) {
    const current = manifest.find((run) => run.id === currentRunId);
    if (!current || current.phase !== currentRunPhase)
      fail(path, "current Run must reference a matching projected Run");
    if (archived) fail(path, "an archived Task cannot have a current Run");
  }
  const activeRuns = manifest.filter((run) =>
    nonTerminalRunPhases.includes(run.phase as never),
  );
  if (
    (currentRunPhase === null && activeRuns.length !== 0) ||
    (currentRunPhase !== null &&
      (activeRuns.length !== 1 || activeRuns[0]!.id !== currentRunId))
  )
    fail(path, "current Run must be the only non-terminal projected Run");
  const pendingUi = decodePendingUi(item.pendingUi, `${path}.pendingUi`);
  if (
    pendingUi &&
    (currentRunPhase !== "waiting_ui" || pendingUi.runId !== currentRunId)
  )
    fail(path, "pending UI must belong to the current waiting Run");
  const uiHistory = arrayValue(
    item.uiHistory,
    `${path}.uiHistory`,
    decodeUiRecord,
  );
  const acceptance = object(item.inputAcceptance, `${path}.inputAcceptance`, [
    "available",
    "reason",
  ]);
  const inputAcceptance = {
    available: booleanValue(
      acceptance.available,
      `${path}.inputAcceptance.available`,
    ),
    reason:
      acceptance.reason === null
        ? null
        : enumValue(
            acceptance.reason,
            `${path}.inputAcceptance.reason`,
            sendInputReasons,
          ),
  };
  if (inputAcceptance.available !== (inputAcceptance.reason === null))
    fail(path, "inconsistent input acceptance");
  const inputSubmissions = arrayValue(
    item.inputSubmissions,
    `${path}.inputSubmissions`,
    (raw, p): WaitingInputView => {
      const entry = object(raw, p, ["submission", "input", "state", "reason"]);
      const state = enumValue(entry.state, `${p}.state`, [
        "waiting",
        "failed",
        "cancelled",
        "interrupted",
      ] as const);
      const reason =
        entry.reason === null
          ? null
          : enumValue(entry.reason, `${p}.reason`, sendInputReasons);
      if ((state === "waiting" || state === "interrupted") && reason !== null)
        fail(p, "waiting or restored input has no failure reason");
      return {
        submission: decodeInputSubmission(entry.submission, `${p}.submission`),
        input: decodeRunInput(entry.input, `${p}.input`),
        state,
        reason,
      };
    },
  );
  if (inputSubmissions.length > 64) fail(path, "too many input submissions");
  const runIds = new Set(manifest.map((run) => run.id));
  if (
    (context.pressure !== null && !runIds.has(context.pressure.sourceRunId)) ||
    (context.lastAutoCompact !== null &&
      !runIds.has(context.lastAutoCompact.sourceRunId))
  )
    fail(path, "Conversation context must reference projected Run history");
  if (
    binding.availability !== "available" &&
    (context.pressure !== null || context.lastAutoCompact !== null)
  )
    fail(path, "detached Task cannot expose Conversation context observations");
  const compactIds = new Set(compacts.map((compact) => compact.operationId));
  if (compactIds.size !== compacts.length)
    fail(path, "Compact operation identities must be unique");
  for (const compact of compacts) {
    const afterRun = manifest.find((run) => run.id === compact.afterRunId);
    if (!afterRun || nonTerminalRunPhases.includes(afterRun.phase as never))
      fail(path, "Compact history must follow a terminal projected Run");
  }
  const activeCompacts = compacts.filter((compact) =>
    nonTerminalCompactPhases.includes(compact.phase as never),
  );
  if (activeCompacts.length > 1)
    fail(path, "a Task cannot have multiple active Compact operations");
  if (activeOperation?.kind === "run") {
    if (activeOperation.id !== currentRunId || currentRunPhase === null)
      fail(path, "active Run operation must match the current Run");
    if (activeCompacts.length !== 0)
      fail(path, "Run and Compact cannot be active together");
  } else if (activeOperation?.kind === "compact") {
    if (archived) fail(path, "an archived Task cannot have an active Compact");
    if (
      activeCompacts.length !== 1 ||
      activeCompacts[0]!.operationId !== activeOperation.id ||
      currentRunPhase !== null
    )
      fail(path, "active Compact operation must be the only active Task work");
  } else if (activeOperation?.kind === "restore") {
    if (archived || lifecycle !== "open")
      fail(path, "only an open visible Task can restore its conversation");
    if (currentRunPhase !== null || activeCompacts.length !== 0)
      fail(path, "active recovery must be the only active Task work");
    if (continuationUnavailableReason !== "session_recovery_in_progress")
      fail(path, "active recovery must project recovery in progress");
  } else if (currentRunPhase !== null || activeCompacts.length !== 0) {
    fail(path, "active Task work must have an active operation identity");
  }
  const requestIds = new Set<string>();
  const activityOrders = new Map(
    manifest.map((run) => [run.id, new Set<string>()]),
  );
  for (const run of runs)
    activityOrders.set(run.id, new Set(run.tools.map((tool) => tool.order)));
  for (const run of runs) {
    if (new Set(run.tools.map((tool) => tool.id)).size !== run.tools.length)
      fail(path, "tool product identities must be unique within a Run");
    if (activityOrders.get(run.id)!.size !== run.tools.length)
      fail(path, "tool activity order must be unique within a Run");
  }
  for (const record of uiHistory) {
    if (!runIds.has(record.runId))
      fail(path, "UI history must reference a projected Run");
    if (
      record.answeredBy === "reviewer" &&
      (manifest.find((run) => run.id === record.runId)?.permissionProfile !==
        "approval_required" ||
        manifest.find((run) => run.id === record.runId)
          ?.permissionInteraction !== "interactive")
    )
      fail(path, "reviewer decisions require an interactive approval session");
    if (requestIds.has(record.requestId))
      fail(path, "UI history request identities must be unique");
    requestIds.add(record.requestId);
    const orders = activityOrders.get(record.runId)!;
    if (orders.has(record.order))
      fail(path, "activity order must be unique within a Run");
    orders.add(record.order);
  }
  if (pendingUi && requestIds.has(pendingUi.requestId))
    fail(path, "a pending UI request cannot already be resolved");
  if (pendingUi && lifecycle !== "open")
    fail(path, "a non-open Task cannot expose actionable UI");
  if (pendingUi) {
    const orders = activityOrders.get(pendingUi.runId)!;
    if (orders.has(pendingUi.order))
      fail(path, "activity order must be unique within a Run");
  }
  if (
    !continuationAvailable &&
    lifecycle === "open" &&
    (currentRunPhase !== null || pendingUi !== null)
  )
    fail(path, "an open non-continuable Task cannot have active work");
  if (lifecycle !== "open" && continuationAvailable)
    fail(path, "a non-open Task cannot accept future work");
  if (continuationAvailable && binding.availability !== "available")
    fail(path, "a Task without an available binding cannot accept future work");
  if (
    continuationUnavailableReason === "session_recovery_in_progress" &&
    activeOperation?.kind !== "restore"
  )
    fail(path, "recovery in progress requires an active recovery operation");
  if (continuationRecoveryAvailable) {
    if (
      lifecycle !== "open" ||
      archived ||
      activeOperation !== null ||
      continuationAvailable ||
      (continuationUnavailableReason !== "session_recovery_required" &&
        continuationUnavailableReason !== "session_recovery_failed")
    )
      fail(
        path,
        "recovery availability must describe an eligible detached Task",
      );
  }
  if (continuationAvailable && continuationRecoveryAvailable)
    fail(path, "continuation and recovery cannot both be available");
  return {
    inputReady: booleanValue(item.inputReady, `${path}.inputReady`),
    inputAcceptance,
    inputSubmissions,
    id: positiveWireId(item.id, `${path}.id`),
    recentOrder: positiveWireId(item.recentOrder, `${path}.recentOrder`),
    title: stringValue(item.title, `${path}.title`),
    workspaceId: positiveWireId(item.workspaceId, `${path}.workspaceId`),
    permissionProfile,
    approvalMode,
    approvalRevision,
    availableApprovalModes,
    approvalChange,
    approvalResult,
    permissionReviewState,
    permissionReviewExplanation,
    binding,
    modelIntent,
    modelSelectionAvailability,
    mcpAuthority,
    skillCatalog: decodeSkillCatalog(item.skillCatalog, `${path}.skillCatalog`),
    lifecycle,
    deletionStatus,
    continuationAvailable,
    continuationUnavailableReason,
    continuationRecoveryAvailable,
    archived,
    unreadCompletionRunId,
    restorePermission,
    activeOperation,
    currentRunId,
    currentRunPhase,
    context,
    runs,
    compacts,
    pendingUi,
    uiHistory,
  };
}
function decodeWorkspace(value: unknown, path: string): WorkspaceView {
  const item = object(value, path, [
    "id",
    "epoch",
    "kind",
    "displayName",
    "canonicalRoot",
    "redacted",
    "authorization",
    "lastRemovalFailure",
    "skillCatalog",
    "skillSourceDiscovery",
    "recentOrder",
    "signals",
  ]);
  const signals = object(item.signals, `${path}.signals`, [
    "running",
    "attention",
    "failedOrInterrupted",
  ]);
  const kind = enumValue(item.kind, `${path}.kind`, workspaceKinds);
  const authorization = enumValue(
    item.authorization,
    `${path}.authorization`,
    workspaceAuthorizations,
  );
  const lastRemovalFailure = nullableEnum(
    item.lastRemovalFailure,
    `${path}.lastRemovalFailure`,
    ["task_close_failed"] as const,
  );
  const recentOrder = wireId(item.recentOrder, `${path}.recentOrder`);
  const skillSourceDiscovery = decodeSkillSourceDiscovery(
    item.skillSourceDiscovery,
    `${path}.skillSourceDiscovery`,
    "project",
  );
  if (
    (kind !== "manual" || authorization !== "available") &&
    skillSourceDiscovery !== null
  )
    fail(
      `${path}.skillSourceDiscovery`,
      "source discovery requires an authorized Manual Workspace",
    );
  const skillCatalog = decodeSkillCatalog(
    item.skillCatalog,
    `${path}.skillCatalog`,
  );
  if (kind === "manual" && recentOrder === "0")
    fail(`${path}.recentOrder`, "manual Workspace requires recent order");
  if (
    kind === "automatic" &&
    (recentOrder !== "0" ||
      authorization !== "available" ||
      lastRemovalFailure !== null)
  )
    fail(
      path,
      "automatic Workspace must remain Task-owned without project source settings",
    );
  return {
    id: positiveWireId(item.id, `${path}.id`),
    epoch: positiveWireId(item.epoch, `${path}.epoch`),
    kind,
    displayName: stringValue(item.displayName, `${path}.displayName`),
    canonicalRoot: stringValue(item.canonicalRoot, `${path}.canonicalRoot`),
    redacted: booleanValue(item.redacted, `${path}.redacted`),
    authorization,
    lastRemovalFailure,
    skillCatalog,
    skillSourceDiscovery,
    recentOrder,
    signals: {
      running: nonNegativeNumber(signals.running, `${path}.signals.running`),
      attention: nonNegativeNumber(
        signals.attention,
        `${path}.signals.attention`,
      ),
      failedOrInterrupted: nonNegativeNumber(
        signals.failedOrInterrupted,
        `${path}.signals.failedOrInterrupted`,
      ),
    },
  };
}
function decodeScheduledTask(value: unknown, path: string): ScheduledTaskView {
  const item = object(value, path, [
    "id",
    "epoch",
    "title",
    "titleRedacted",
    "permissionProfile",
    "enabled",
    "health",
    "failureReason",
    "binding",
    "input",
    "recurrence",
    "nextRunAtUnixSeconds",
    "occurrences",
  ]);
  const bindingRoot = object(item.binding, `${path}.binding`, [
    "status",
    "modelRef",
    "sourceGeneration",
    "selectionRevision",
    "protocol",
  ]);
  const bindingStatus = enumValue(
    bindingRoot.status,
    `${path}.binding.status`,
    ["bound"] as const,
  );
  const binding = {
    status: bindingStatus,
    modelRef: decodeRequiredModelRef(
      bindingRoot.modelRef,
      `${path}.binding.modelRef`,
    ),
    sourceGeneration: positiveWireId(
      bindingRoot.sourceGeneration,
      `${path}.binding.sourceGeneration`,
    ),
    selectionRevision: positiveWireId(
      bindingRoot.selectionRevision,
      `${path}.binding.selectionRevision`,
    ),
    protocol: enumValue(
      bindingRoot.protocol,
      `${path}.binding.protocol`,
      protocols,
    ),
  };
  if (
    typeof item.input !== "object" ||
    item.input === null ||
    Array.isArray(item.input)
  )
    fail(`${path}.input`, "expected object");
  const inputObject = item.input as JsonObject;
  const inputKind = stringValue(inputObject.kind, `${path}.input.kind`);
  if (inputKind !== "text")
    fail(`${path}.input.kind`, "unexpected scheduled Task input kind");
  const text = object(item.input, `${path}.input`, [
    "kind",
    "text",
    "redacted",
  ]);
  const input = {
    kind: "text" as const,
    text: stringValue(text.text, `${path}.input.text`),
    redacted: booleanValue(text.redacted, `${path}.input.redacted`),
  };
  if (
    typeof item.recurrence !== "object" ||
    item.recurrence === null ||
    Array.isArray(item.recurrence)
  )
    fail(`${path}.recurrence`, "expected object");
  const recurrenceObject = item.recurrence as JsonObject;
  const recurrenceKind = stringValue(
    recurrenceObject.kind,
    `${path}.recurrence.kind`,
  );
  const recurrence =
    recurrenceKind === "once"
      ? (() => {
          const once = object(item.recurrence, `${path}.recurrence`, [
            "kind",
            "atUnixSeconds",
          ]);
          return {
            kind: "once" as const,
            atUnixSeconds: positiveWireId(
              once.atUnixSeconds,
              `${path}.recurrence.atUnixSeconds`,
            ),
          };
        })()
      : recurrenceKind === "interval"
        ? (() => {
            const interval = object(item.recurrence, `${path}.recurrence`, [
              "kind",
              "startAtUnixSeconds",
              "everySeconds",
            ]);
            return {
              kind: "interval" as const,
              startAtUnixSeconds: positiveWireId(
                interval.startAtUnixSeconds,
                `${path}.recurrence.startAtUnixSeconds`,
              ),
              everySeconds: positiveWireId(
                interval.everySeconds,
                `${path}.recurrence.everySeconds`,
              ),
            };
          })()
        : fail(`${path}.recurrence.kind`, "unexpected recurrence kind");
  const occurrences = arrayValue(
    item.occurrences,
    `${path}.occurrences`,
    (value, occurrencePath) => {
      const last = object(value, occurrencePath, [
        "plannedAtUnixSeconds",
        "triggeredAtUnixSeconds",
        "source",
        "result",
        "taskId",
        "reason",
        "taskOutcome",
      ]);
      const result = enumValue(last.result, `${occurrencePath}.result`, [
        "claimed",
        "submitted",
        "skipped",
        "rejected",
      ] as const);
      const taskId =
        last.taskId === null
          ? null
          : positiveWireId(last.taskId, `${occurrencePath}.taskId`);
      const reason = nullableEnum(
        last.reason,
        `${occurrencePath}.reason`,
        scheduledTaskFailureReasons,
      );
      const taskOutcome = nullableEnum(
        last.taskOutcome,
        `${occurrencePath}.taskOutcome`,
        [
          "completed",
          "stopped",
          "cancelled",
          "interrupted",
          "failed",
          "dependency_contract_failure",
          "unavailable",
        ] as const,
      );
      if (
        result === "claimed" &&
        (taskId !== null || reason !== null || taskOutcome !== null)
      )
        fail(occurrencePath, "claimed occurrence cannot expose terminal facts");
      if (
        result === "submitted" &&
        (taskId === null ||
          (reason !== null &&
            (reason !== "permission_required" || taskOutcome === null)))
      )
        fail(
          occurrencePath,
          "submitted occurrence requires a Task and only permits a terminal permission reason",
        );
      if (
        result === "skipped" &&
        (taskId !== null || reason === null || taskOutcome !== null)
      )
        fail(
          occurrencePath,
          "skipped occurrence requires only a rejection reason",
        );
      if (result === "rejected" && (reason === null || taskOutcome !== null))
        fail(
          occurrencePath,
          "rejected occurrence requires a reason and may reference a Task",
        );
      return {
        plannedAtUnixSeconds: positiveWireId(
          last.plannedAtUnixSeconds,
          `${occurrencePath}.plannedAtUnixSeconds`,
        ),
        triggeredAtUnixSeconds: positiveWireId(
          last.triggeredAtUnixSeconds,
          `${occurrencePath}.triggeredAtUnixSeconds`,
        ),
        source: enumValue(last.source, `${occurrencePath}.source`, [
          "timer",
          "manual",
        ] as const),
        result,
        taskId,
        reason,
        taskOutcome,
      };
    },
  );
  const health = enumValue(item.health, `${path}.health`, scheduledTaskHealth);
  const failureReason = nullableEnum(
    item.failureReason,
    `${path}.failureReason`,
    scheduledTaskFailureReasons,
  );
  const enabled = booleanValue(item.enabled, `${path}.enabled`);
  const nextRunAtUnixSeconds =
    item.nextRunAtUnixSeconds === null
      ? null
      : positiveWireId(
          item.nextRunAtUnixSeconds,
          `${path}.nextRunAtUnixSeconds`,
        );
  if (enabled !== (health === "ready" && nextRunAtUnixSeconds !== null))
    fail(path, "enabled schedule must be ready and expose its next run");
  if ((health === "needs_attention") !== (failureReason !== null))
    fail(path, "Schedule attention and failure reason must agree");
  return {
    id: positiveWireId(item.id, `${path}.id`),
    epoch: positiveWireId(item.epoch, `${path}.epoch`),
    title: stringValue(item.title, `${path}.title`),
    titleRedacted: booleanValue(item.titleRedacted, `${path}.titleRedacted`),
    permissionProfile: enumValue(
      item.permissionProfile,
      `${path}.permissionProfile`,
      permissionProfiles,
    ),
    enabled,
    health,
    failureReason,
    binding,
    input,
    recurrence,
    nextRunAtUnixSeconds,
    occurrences,
  };
}
function decodeMcpManagement(value: unknown, path: string): McpManagementView {
  const item = object(value, path, [
    "availability",
    "managementHealth",
    "operation",
    "configurationApply",
    "authorizationOperation",
    "desiredGeneration",
    "runtimeAlignment",
    "redacted",
    "servers",
  ]);
  const availability = enumValue(
    item.availability,
    `${path}.availability`,
    mcpAvailabilities,
  );
  const managementHealth = enumValue(
    item.managementHealth,
    `${path}.managementHealth`,
    mcpManagementHealthValues,
  );
  const operation = enumValue(item.operation, `${path}.operation`, [
    "idle",
    "saving",
    "refreshing",
  ] as const);
  const configurationApply = enumValue(
    item.configurationApply,
    `${path}.configurationApply`,
    mcpConfigurationApplyValues,
  );
  const authorizationItem = record(
    item.authorizationOperation,
    `${path}.authorizationOperation`,
  );
  const authorizationKind = enumValue(
    authorizationItem.kind,
    `${path}.authorizationOperation.kind`,
    ["idle", ...mcpAuthorizationPhaseValues] as const,
  );
  const authorizationOperation =
    authorizationKind === "idle"
      ? (() => {
          exactKeys(authorizationItem, `${path}.authorizationOperation`, [
            "kind",
          ]);
          return { kind: "idle" as const };
        })()
      : (() => {
          exactKeys(authorizationItem, `${path}.authorizationOperation`, [
            "kind",
            "serverId",
            "operationId",
          ]);
          return {
            kind: authorizationKind,
            serverId: nonEmptyString(
              authorizationItem.serverId,
              `${path}.authorizationOperation.serverId`,
            ),
            operationId: nonEmptyString(
              authorizationItem.operationId,
              `${path}.authorizationOperation.operationId`,
            ),
          };
        })();
  const desiredGeneration =
    item.desiredGeneration === null
      ? null
      : wireId(item.desiredGeneration, `${path}.desiredGeneration`);
  const runtimeAlignment = enumValue(
    item.runtimeAlignment,
    `${path}.runtimeAlignment`,
    mcpRuntimeAlignmentValues,
  );
  const servers = arrayValue(
    item.servers,
    `${path}.servers`,
    (value, serverPath) => {
      const server = object(value, serverPath, [
        "id",
        "displayName",
        "namespace",
        "transport",
        "authMode",
        "negotiation",
        "timeoutMs",
        "connection",
        "approvalStatus",
        "authorizationStatus",
        "desiredEnabled",
        "runtimeStatus",
        "newTaskAccess",
        "safeDiagnostic",
        "connectionTest",
        "tools",
      ]);
      const tools = arrayValue(
        server.tools,
        `${serverPath}.tools`,
        (value, toolPath) => {
          const tool = object(value, toolPath, [
            "name",
            "discovered",
            "desiredAllowed",
            "availableToNewTasks",
          ]);
          const decoded = {
            name: nonEmptyString(tool.name, `${toolPath}.name`),
            discovered: booleanValue(tool.discovered, `${toolPath}.discovered`),
            desiredAllowed: booleanValue(
              tool.desiredAllowed,
              `${toolPath}.desiredAllowed`,
            ),
            availableToNewTasks: booleanValue(
              tool.availableToNewTasks,
              `${toolPath}.availableToNewTasks`,
            ),
          };
          if (
            decoded.availableToNewTasks &&
            (!decoded.discovered || !decoded.desiredAllowed)
          )
            fail(
              toolPath,
              "new-task authority requires discovered allowed tool",
            );
          return decoded;
        },
      );
      if (new Set(tools.map((tool) => tool.name)).size !== tools.length)
        fail(
          `${serverPath}.tools`,
          "MCP tool names must be unique within a server",
        );
      const transport = enumValue(server.transport, `${serverPath}.transport`, [
        "stdio",
        "streamable_http",
      ] as const);
      const decodeSlots = (slotValue: unknown, slotPath: string) => {
        const slots = arrayValue(slotValue, slotPath, (value, itemPath) => {
          const slot = object(value, itemPath, ["name", "status"]);
          return {
            name: nonEmptyString(slot.name, `${itemPath}.name`),
            status: enumValue(slot.status, `${itemPath}.status`, [
              "missing",
              "set",
            ] as const),
          };
        });
        if (
          new Set(slots.map((slot) => slot.name.toLowerCase())).size !==
          slots.length
        )
          fail(slotPath, "MCP secret slot names must be unique");
        return slots;
      };
      const connection =
        server.connection === null
          ? null
          : (() => {
              const item = record(
                server.connection,
                `${serverPath}.connection`,
              );
              const kind = enumValue(
                item.kind,
                `${serverPath}.connection.kind`,
                ["stdio", "streamable_http"] as const,
              );
              if (kind !== transport)
                fail(serverPath, "MCP transport and connection disagree");
              if (kind === "stdio") {
                exactKeys(item, `${serverPath}.connection`, [
                  "kind",
                  "command",
                  "arguments",
                  "cwd",
                  "environment",
                ]);
                return {
                  kind: "stdio" as const,
                  command: nonEmptyString(
                    item.command,
                    `${serverPath}.connection.command`,
                  ),
                  arguments: arrayValue(
                    item.arguments,
                    `${serverPath}.connection.arguments`,
                    (value, path) => stringValue(value, path),
                  ),
                  cwd:
                    item.cwd === null
                      ? null
                      : nonEmptyString(
                          item.cwd,
                          `${serverPath}.connection.cwd`,
                        ),
                  environment: decodeSlots(
                    item.environment,
                    `${serverPath}.connection.environment`,
                  ),
                };
              }
              exactKeys(item, `${serverPath}.connection`, [
                "kind",
                "endpoint",
                "headers",
                "registrationKind",
                "clientId",
                "tokenEndpointAuthMethod",
                "clientSecretStatus",
              ]);
              return {
                kind: "streamable_http" as const,
                endpoint: nonEmptyString(
                  item.endpoint,
                  `${serverPath}.connection.endpoint`,
                ),
                headers: decodeSlots(
                  item.headers,
                  `${serverPath}.connection.headers`,
                ),
                registrationKind: enumValue(
                  item.registrationKind,
                  `${serverPath}.connection.registrationKind`,
                  ["none", "automatic", "pre_registered"] as const,
                ),
                clientId:
                  item.clientId === null
                    ? null
                    : nonEmptyString(
                        item.clientId,
                        `${serverPath}.connection.clientId`,
                      ),
                tokenEndpointAuthMethod:
                  item.tokenEndpointAuthMethod === null
                    ? null
                    : enumValue(
                        item.tokenEndpointAuthMethod,
                        `${serverPath}.connection.tokenEndpointAuthMethod`,
                        [
                          "none",
                          "client_secret_basic",
                          "client_secret_post",
                        ] as const,
                      ),
                clientSecretStatus: enumValue(
                  item.clientSecretStatus,
                  `${serverPath}.connection.clientSecretStatus`,
                  ["not_required", "missing", "set"] as const,
                ),
              };
            })();
      const connectionTestItem = object(
        server.connectionTest,
        `${serverPath}.connectionTest`,
        ["status", "toolCount", "issueCount"],
      );
      const connectionTest = {
        status: enumValue(
          connectionTestItem.status,
          `${serverPath}.connectionTest.status`,
          ["untested", "testing", "connected", "failed"] as const,
        ),
        toolCount: nonNegativeNumber(
          connectionTestItem.toolCount,
          `${serverPath}.connectionTest.toolCount`,
        ),
        issueCount: nonNegativeNumber(
          connectionTestItem.issueCount,
          `${serverPath}.connectionTest.issueCount`,
        ),
      };
      const authMode = enumValue(server.authMode, `${serverPath}.authMode`, [
        "none",
        "static",
        "oauth",
      ] as const);
      if (connection !== null && connection.kind === "streamable_http") {
        if ((authMode === "oauth") !== (connection.registrationKind !== "none"))
          fail(serverPath, "OAuth registration must match auth mode");
        if (
          connection.registrationKind === "pre_registered" &&
          (connection.clientId === null ||
            connection.tokenEndpointAuthMethod === null)
        )
          fail(
            serverPath,
            "pre-registered OAuth client must expose its public configuration",
          );
        if (
          authMode !== "oauth" &&
          (connection.registrationKind !== "none" ||
            connection.clientId !== null ||
            connection.tokenEndpointAuthMethod !== null ||
            connection.clientSecretStatus !== "not_required")
        )
          fail(serverPath, "non-OAuth server cannot expose OAuth client state");
        if (
          connection.tokenEndpointAuthMethod === "none" &&
          connection.clientSecretStatus !== "not_required"
        )
          fail(serverPath, "public OAuth client cannot expose a client secret");
        if (
          (connection.tokenEndpointAuthMethod === "client_secret_basic" ||
            connection.tokenEndpointAuthMethod === "client_secret_post") &&
          connection.clientSecretStatus === "not_required"
        )
          fail(serverPath, "confidential OAuth client requires a secret state");
      }
      if (
        connection !== null &&
        connection.kind === "stdio" &&
        authMode === "oauth"
      )
        fail(serverPath, "STDIO cannot use OAuth");
      return {
        id: nonEmptyString(server.id, `${serverPath}.id`),
        displayName: nonEmptyString(
          server.displayName,
          `${serverPath}.displayName`,
        ),
        namespace: nonEmptyString(server.namespace, `${serverPath}.namespace`),
        transport,
        authMode,
        negotiation: enumValue(
          server.negotiation,
          `${serverPath}.negotiation`,
          ["automatic", "modern_only", "compat_only"] as const,
        ),
        timeoutMs: positiveNumber(server.timeoutMs, `${serverPath}.timeoutMs`),
        connection,
        approvalStatus: enumValue(
          server.approvalStatus,
          `${serverPath}.approvalStatus`,
          ["unapproved", "approved"] as const,
        ),
        authorizationStatus: enumValue(
          server.authorizationStatus,
          `${serverPath}.authorizationStatus`,
          mcpAuthorizationStatusValues,
        ),
        desiredEnabled: booleanValue(
          server.desiredEnabled,
          `${serverPath}.desiredEnabled`,
        ),
        runtimeStatus: enumValue(
          server.runtimeStatus,
          `${serverPath}.runtimeStatus`,
          mcpRuntimeStatusValues,
        ),
        newTaskAccess: enumValue(
          server.newTaskAccess,
          `${serverPath}.newTaskAccess`,
          mcpNewTaskAccessValues,
        ),
        safeDiagnostic: stringValue(
          server.safeDiagnostic,
          `${serverPath}.safeDiagnostic`,
        ),
        connectionTest,
        tools,
      };
    },
  );
  if (new Set(servers.map((server) => server.id)).size !== servers.length)
    fail(`${path}.servers`, "MCP server identities must be unique");
  if (
    new Set(servers.map((server) => server.namespace)).size !== servers.length
  )
    fail(`${path}.servers`, "MCP server namespaces must be unique");
  if (
    desiredGeneration === null &&
    (runtimeAlignment !== "unknown" ||
      servers.length !== 0 ||
      configurationApply !== "idle" ||
      authorizationOperation.kind !== "idle")
  )
    fail(path, "unknown desired state must hide alignment and servers");
  if (
    managementHealth === "outcome_unknown" &&
    (desiredGeneration !== null ||
      runtimeAlignment !== "unknown" ||
      servers.length !== 0 ||
      configurationApply !== "idle" ||
      authorizationOperation.kind !== "idle")
  )
    fail(path, "outcome-unknown management cannot claim desired state");
  if (managementHealth === "ready" && desiredGeneration === null)
    fail(path, "ready management requires a canonical desired generation");
  if (
    authorizationOperation.kind !== "idle" &&
    !servers.some((server) => server.id === authorizationOperation.serverId)
  )
    fail(path, "MCP authorization operation must bind a published server");
  if (
    availability === "ready" &&
    servers.some((server) =>
      ["needs_authentication", "unreachable", "invalid_catalog"].includes(
        server.runtimeStatus,
      ),
    )
  )
    fail(path, "ready MCP Runtime cannot contain attention states");
  for (const [index, server] of servers.entries()) {
    const availableTools = server.tools.filter(
      (tool) => tool.availableToNewTasks,
    ).length;
    if ((server.newTaskAccess === "available") !== availableTools > 0)
      fail(
        `${path}.servers[${index}]`,
        "server access must match selected tools",
      );
    if (server.newTaskAccess === "available" && !server.desiredEnabled)
      fail(
        `${path}.servers[${index}]`,
        "disabled desired server cannot expose new-task authority",
      );
    if (
      server.newTaskAccess !== "available" &&
      server.tools.some((tool) => tool.availableToNewTasks)
    )
      fail(
        `${path}.servers[${index}]`,
        "blocked server cannot expose authority",
      );
  }
  return {
    availability,
    managementHealth,
    operation,
    configurationApply,
    authorizationOperation,
    desiredGeneration,
    runtimeAlignment,
    redacted: booleanValue(item.redacted, `${path}.redacted`),
    servers,
  };
}
export function decodeSearchCursor(
  value: unknown,
  path: string,
): SearchCursor | null {
  if (value === null) return null;
  const item = object(value, path, [
    "revision",
    "securityEpoch",
    "task",
    "run",
    "part",
    "offset",
  ]);
  const bounded = (value: unknown, p: string) => {
    const id = wireId(value, p);
    u64WireInteger(value, p);
    return id;
  };
  return {
    revision: positiveU64WireId(item.revision, `${path}.revision`),
    securityEpoch: positiveU64WireId(
      item.securityEpoch,
      `${path}.securityEpoch`,
    ),
    task: bounded(item.task, `${path}.task`),
    run: bounded(item.run, `${path}.run`),
    part: bounded(item.part, `${path}.part`),
    offset: bounded(item.offset, `${path}.offset`),
  };
}
export function decodeViewScope(value: unknown, path = "$scope"): ViewScope {
  const item = object(value, path, [
    "taskId",
    "beforeRunId",
    "runLimit",
    "management",
    "search",
    "searchQuery",
    "searchCursor",
    "receipts",
  ]);
  const taskId =
    item.taskId === null ? null : positiveWireId(item.taskId, `${path}.taskId`);
  const beforeRunId =
    item.beforeRunId === null
      ? null
      : positiveWireId(item.beforeRunId, `${path}.beforeRunId`);
  const runLimit = positiveNumber(item.runLimit, `${path}.runLimit`);
  if (
    !Number.isInteger(runLimit) ||
    runLimit > 4 ||
    (beforeRunId !== null && taskId === null)
  )
    fail(path, "invalid history scope");
  const receipts = arrayValue(item.receipts, `${path}.receipts`, (value, p) => {
    const query = object(value, p, ["taskId", "operationId"]);
    const operationId = stringValue(query.operationId, `${p}.operationId`);
    if (!/^[\x21-\x7e]{1,64}$/.test(operationId))
      fail(p, "invalid operation identity");
    return { taskId: positiveWireId(query.taskId, `${p}.taskId`), operationId };
  });
  if (
    receipts.length > 64 ||
    new Set(receipts.map((query) => `${query.taskId}:${query.operationId}`))
      .size !== receipts.length
  )
    fail(path, "invalid receipt query bounds");
  const search = booleanValue(item.search, `${path}.search`);
  const searchQuery = stringValue(item.searchQuery, `${path}.searchQuery`);
  const searchCursor = decodeSearchCursor(
    item.searchCursor,
    `${path}.searchCursor`,
  );
  if (
    new TextEncoder().encode(searchQuery).length > 256 ||
    (!search && (searchQuery !== "" || searchCursor !== null))
  )
    fail(path, "invalid search bounds");
  return {
    receipts,
    taskId,
    beforeRunId,
    runLimit,
    search,
    searchQuery,
    searchCursor,
    management: enumValue(item.management, `${path}.management`, [
      "none",
      "skills",
      "mcp",
      "schedules",
    ] as const),
  };
}
function decodeRunManifest(value: unknown, path: string): RunManifest {
  const item = object(value, path, [
    "id",
    "contentVersion",
    "phase",
    "permissionProfile",
    "permissionInteraction",
    "terminal",
  ]);
  const phase = enumValue(item.phase, `${path}.phase`, runPhases);
  const terminal = decodeRunTerminal(item.terminal, `${path}.terminal`);
  validateRunTerminalState(phase, terminal, path);
  return {
    contentVersion: positiveU64WireId(
      item.contentVersion,
      `${path}.contentVersion`,
    ),
    id: positiveWireId(item.id, `${path}.id`),
    phase,
    terminal,
    permissionProfile: enumValue(
      item.permissionProfile,
      `${path}.permissionProfile`,
      permissionProfiles,
    ),
    permissionInteraction: enumValue(
      item.permissionInteraction,
      `${path}.permissionInteraction`,
      ["interactive", "noninteractive"] as const,
    ),
  };
}
function decodeTaskSummary(value: unknown, path: string): TaskSummary {
  const item = object(value, path, [
    "id",
    "recentOrder",
    "title",
    "workspaceId",
    "archived",
    "lifecycle",
    "deletionStatus",
    "historyReadOnly",
    "permissionReviewState",
    "currentRunPhase",
    "activeOperation",
    "activeCompactPhase",
    "lastCompactPhase",
    "latestTerminal",
    "unreadCompletionRunId",
  ]);
  const operation =
    item.activeOperation === null
      ? null
      : object(item.activeOperation, `${path}.activeOperation`, ["kind", "id"]);
  const terminal =
    item.latestTerminal === null
      ? null
      : object(item.latestTerminal, `${path}.latestTerminal`, [
          "outcome",
          "cause",
        ]);
  const summary: TaskSummary = {
    id: positiveWireId(item.id, `${path}.id`),
    recentOrder: positiveWireId(item.recentOrder, `${path}.recentOrder`),
    title: stringValue(item.title, `${path}.title`),
    workspaceId: positiveWireId(item.workspaceId, `${path}.workspaceId`),
    archived: booleanValue(item.archived, `${path}.archived`),
    lifecycle: enumValue(item.lifecycle, `${path}.lifecycle`, taskLifecycles),
    deletionStatus: enumValue(item.deletionStatus, `${path}.deletionStatus`, [
      "idle",
      "deleting",
      "failed",
    ] as const),
    historyReadOnly: booleanValue(
      item.historyReadOnly,
      `${path}.historyReadOnly`,
    ),
    permissionReviewState: enumValue(
      item.permissionReviewState,
      `${path}.permissionReviewState`,
      ["idle", "reviewing", "needs_user"] as const,
    ),
    currentRunPhase: nullableEnum(
      item.currentRunPhase,
      `${path}.currentRunPhase`,
      nonTerminalRunPhases,
    ),
    activeOperation:
      operation === null
        ? null
        : {
            kind: enumValue(operation.kind, `${path}.activeOperation.kind`, [
              "run",
              "compact",
              "restore",
            ] as const),
            id: positiveWireId(operation.id, `${path}.activeOperation.id`),
          },
    activeCompactPhase: nullableEnum(
      item.activeCompactPhase,
      `${path}.activeCompactPhase`,
      compactPhases,
    ),
    lastCompactPhase: nullableEnum(
      item.lastCompactPhase,
      `${path}.lastCompactPhase`,
      compactPhases,
    ),
    latestTerminal:
      terminal === null
        ? null
        : {
            outcome: enumValue(
              terminal.outcome,
              `${path}.latestTerminal.outcome`,
              runOutcomes,
            ),
            cause: nullableEnum(
              terminal.cause,
              `${path}.latestTerminal.cause`,
              runCauses,
            ),
          },
    unreadCompletionRunId:
      item.unreadCompletionRunId === null
        ? null
        : positiveWireId(
            item.unreadCompletionRunId,
            `${path}.unreadCompletionRunId`,
          ),
  };
  if (summary.deletionStatus === "deleting" && summary.lifecycle !== "closing")
    fail(path, "invalid deletion facts");
  if (
    summary.unreadCompletionRunId !== null &&
    (summary.archived || summary.latestTerminal?.outcome !== "completed")
  )
    fail(path, "invalid completion receipt");
  if (
    (summary.activeOperation?.kind === "run") !==
    (summary.currentRunPhase !== null)
  )
    fail(path, "inconsistent active Run");
  if (
    (summary.activeOperation?.kind === "compact") !==
    (summary.activeCompactPhase !== null)
  )
    fail(path, "inconsistent active Compact");
  return summary;
}
export function decodeViewVersions(value: unknown): ViewVersions {
  const item = object(value, "$.blockVersions", viewBlockNames);
  return Object.fromEntries(
    viewBlockNames.map((name) => [
      name,
      positiveU64WireId(item[name], `$.blockVersions.${name}`),
    ]),
  ) as ViewVersions;
}
export function decodeWorkbenchSnapshot(value: unknown): WorkbenchSnapshot {
  const view = object(value, "$", [
    "revision",
    "securityEpoch",
    "historyEpoch",
    "blockVersions",
    "reusedBlocks",
    "scope",
    "context",
    "workspaces",
    "taskIndex",
    "taskPage",
    "historyPage",
    "management",
    "searchIndex",
    "receipts",
  ]);
  const blockVersions = decodeViewVersions(view.blockVersions);
  if (
    arrayValue(view.reusedBlocks, "$.reusedBlocks", (item) => item).length !== 0
  )
    fail("$.reusedBlocks", "blocks must be materialized before decode");
  const scope = decodeViewScope(view.scope, "$.scope");
  const revision = wireId(view.revision, "$.revision");
  const securityEpoch = positiveU64WireId(
    view.securityEpoch,
    "$.securityEpoch",
  );
  const historyEpoch = positiveU64WireId(view.historyEpoch, "$.historyEpoch");
  const root = object(view.context, "$.context", [
    "capabilities",
    "permissions",
    "account",
    "models",
    "newTaskAdmission",
    "automaticWorkspaceRoot",
    "skillCatalog",
  ]);
  const management = object(view.management, "$.management", ["kind", "value"]);
  if (
    management.kind !== scope.management ||
    (management.kind === "none" && management.value !== null)
  )
    fail("$.management", "unexpected management scope");
  const automaticRootItem = object(
    root.automaticWorkspaceRoot,
    "$.automaticWorkspaceRoot",
    [
      "generation",
      "mode",
      "canonicalRoot",
      "health",
      "redacted",
      "canChoose",
      "canReset",
      "canRetry",
    ],
  );
  const automaticWorkspaceRoot = {
    generation: positiveWireId(
      automaticRootItem.generation,
      "$.automaticWorkspaceRoot.generation",
    ),
    mode:
      automaticRootItem.mode === null
        ? null
        : enumValue(automaticRootItem.mode, "$.automaticWorkspaceRoot.mode", [
            "system_default",
            "custom",
          ] as const),
    canonicalRoot:
      automaticRootItem.canonicalRoot === null
        ? null
        : nonEmptyString(
            automaticRootItem.canonicalRoot,
            "$.automaticWorkspaceRoot.canonicalRoot",
          ),
    health: enumValue(
      automaticRootItem.health,
      "$.automaticWorkspaceRoot.health",
      [
        "ready",
        "path_unavailable",
        "persistence_unavailable",
        "read_failed",
        "corrupt",
        "write_failed",
        "outcome_unknown",
      ] as const,
    ),
    redacted: booleanValue(
      automaticRootItem.redacted,
      "$.automaticWorkspaceRoot.redacted",
    ),
    canChoose: booleanValue(
      automaticRootItem.canChoose,
      "$.automaticWorkspaceRoot.canChoose",
    ),
    canReset: booleanValue(
      automaticRootItem.canReset,
      "$.automaticWorkspaceRoot.canReset",
    ),
    canRetry: booleanValue(
      automaticRootItem.canRetry,
      "$.automaticWorkspaceRoot.canRetry",
    ),
  };
  if (
    automaticWorkspaceRoot.mode === null &&
    automaticWorkspaceRoot.canonicalRoot !== null
  )
    fail(
      "$.automaticWorkspaceRoot.canonicalRoot",
      "untrusted root cannot expose a canonical path",
    );
  if (
    automaticWorkspaceRoot.mode !== null &&
    automaticWorkspaceRoot.canonicalRoot === null
  )
    fail(
      "$.automaticWorkspaceRoot.canonicalRoot",
      "trusted root must expose its canonical path",
    );
  if (
    automaticWorkspaceRoot.health === "ready" &&
    automaticWorkspaceRoot.mode === null
  )
    fail(
      "$.automaticWorkspaceRoot.mode",
      "ready root must expose a trusted mode",
    );
  if (
    automaticWorkspaceRoot.canRetry &&
    automaticWorkspaceRoot.health !== "path_unavailable"
  )
    fail(
      "$.automaticWorkspaceRoot.canRetry",
      "retry authority requires unavailable-path health",
    );
  if (
    automaticWorkspaceRoot.redacted &&
    automaticWorkspaceRoot.canonicalRoot === null
  )
    fail(
      "$.automaticWorkspaceRoot.redacted",
      "redaction requires a projected path",
    );
  const capabilityItem = object(root.capabilities, "$.capabilities", [
    "taskHistoryPersistence",
    "taskHistoryPersistenceHealth",
    "taskHistoryRecoveryAvailable",
    "retainedTaskHistoryCount",
    "conversationRecovery",
    "executionRebind",
    "structuredPlan",
    "typedOutputs",
    "typedFileChanges",
    "persistentWorkspacePermissions",
    "permissionProfiles",
    "automaticWorkspaces",
    "scheduledTasks",
    "scheduledTaskPersistence",
    "scheduledTaskPersistenceHealth",
    "scheduledTaskRecoveryAvailable",
    "backgroundScheduleWake",
    "localSkillManagement",
    "skillManagementHealth",
    "customProviderManagement",
    "customProviderSecretCapture",
    "customModelTest",
    "mcpManagement",
    "mcpConnectionApproval",
    "mcpSecretCapture",
    "mcpSecretMaxBytes",
    "mcpOAuth",
    "attachments",
  ]);
  const attachmentCapability = object(
    capabilityItem.attachments,
    "$.capabilities.attachments",
    ["enabled", "imageFormats", "maxFiles", "maxFileBytes", "maxStagedBytes"],
  );
  const capabilities = {
    taskHistoryPersistence: booleanValue(
      capabilityItem.taskHistoryPersistence,
      "$.capabilities.taskHistoryPersistence",
    ),
    taskHistoryPersistenceHealth: enumValue(
      capabilityItem.taskHistoryPersistenceHealth,
      "$.capabilities.taskHistoryPersistenceHealth",
      [
        "unavailable",
        "ready",
        "degraded",
        "read_failed",
        "corrupt",
        "write_failed",
        "outcome_unknown",
      ] as const,
    ),
    taskHistoryRecoveryAvailable: booleanValue(
      capabilityItem.taskHistoryRecoveryAvailable,
      "$.capabilities.taskHistoryRecoveryAvailable",
    ),
    retainedTaskHistoryCount: wireId(
      capabilityItem.retainedTaskHistoryCount,
      "$.capabilities.retainedTaskHistoryCount",
    ),
    conversationRecovery: booleanValue(
      capabilityItem.conversationRecovery,
      "$.capabilities.conversationRecovery",
    ),
    executionRebind: booleanValue(
      capabilityItem.executionRebind,
      "$.capabilities.executionRebind",
    ),
    structuredPlan: booleanValue(
      capabilityItem.structuredPlan,
      "$.capabilities.structuredPlan",
    ),
    typedOutputs: booleanValue(
      capabilityItem.typedOutputs,
      "$.capabilities.typedOutputs",
    ),
    typedFileChanges: booleanValue(
      capabilityItem.typedFileChanges,
      "$.capabilities.typedFileChanges",
    ),
    persistentWorkspacePermissions: booleanValue(
      capabilityItem.persistentWorkspacePermissions,
      "$.capabilities.persistentWorkspacePermissions",
    ),
    permissionProfiles: booleanValue(
      capabilityItem.permissionProfiles,
      "$.capabilities.permissionProfiles",
    ),
    automaticWorkspaces: booleanValue(
      capabilityItem.automaticWorkspaces,
      "$.capabilities.automaticWorkspaces",
    ),
    scheduledTasks: booleanValue(
      capabilityItem.scheduledTasks,
      "$.capabilities.scheduledTasks",
    ),
    scheduledTaskPersistence: booleanValue(
      capabilityItem.scheduledTaskPersistence,
      "$.capabilities.scheduledTaskPersistence",
    ),
    scheduledTaskPersistenceHealth: enumValue(
      capabilityItem.scheduledTaskPersistenceHealth,
      "$.capabilities.scheduledTaskPersistenceHealth",
      [
        "unavailable",
        "ready",
        "read_failed",
        "corrupt",
        "write_failed",
        "outcome_unknown",
      ] as const,
    ),
    scheduledTaskRecoveryAvailable: booleanValue(
      capabilityItem.scheduledTaskRecoveryAvailable,
      "$.capabilities.scheduledTaskRecoveryAvailable",
    ),
    backgroundScheduleWake: booleanValue(
      capabilityItem.backgroundScheduleWake,
      "$.capabilities.backgroundScheduleWake",
    ),
    localSkillManagement: booleanValue(
      capabilityItem.localSkillManagement,
      "$.capabilities.localSkillManagement",
    ),
    skillManagementHealth: enumValue(
      capabilityItem.skillManagementHealth,
      "$.capabilities.skillManagementHealth",
      [
        "unavailable",
        "ready",
        "read_failed",
        "corrupt",
        "write_failed",
        "outcome_unknown",
      ] as const,
    ),
    customProviderManagement: booleanValue(
      capabilityItem.customProviderManagement,
      "$.capabilities.customProviderManagement",
    ),
    customProviderSecretCapture: booleanValue(
      capabilityItem.customProviderSecretCapture,
      "$.capabilities.customProviderSecretCapture",
    ),
    customModelTest: booleanValue(
      capabilityItem.customModelTest,
      "$.capabilities.customModelTest",
    ),
    mcpManagement: booleanValue(
      capabilityItem.mcpManagement,
      "$.capabilities.mcpManagement",
    ),
    mcpConnectionApproval: booleanValue(
      capabilityItem.mcpConnectionApproval,
      "$.capabilities.mcpConnectionApproval",
    ),
    mcpSecretCapture: booleanValue(
      capabilityItem.mcpSecretCapture,
      "$.capabilities.mcpSecretCapture",
    ),
    mcpSecretMaxBytes: nonNegativeNumber(
      capabilityItem.mcpSecretMaxBytes,
      "$.capabilities.mcpSecretMaxBytes",
    ),
    mcpOAuth: booleanValue(capabilityItem.mcpOAuth, "$.capabilities.mcpOAuth"),
    attachments: {
      enabled: booleanValue(
        attachmentCapability.enabled,
        "$.capabilities.attachments.enabled",
      ),
      imageFormats: arrayValue(
        attachmentCapability.imageFormats,
        "$.capabilities.attachments.imageFormats",
        (format, formatPath) =>
          enumValue(format, formatPath, ["png", "jpeg", "webp"] as const),
      ),
      maxFiles: positiveWireId(
        attachmentCapability.maxFiles,
        "$.capabilities.attachments.maxFiles",
      ),
      maxFileBytes: positiveWireId(
        attachmentCapability.maxFileBytes,
        "$.capabilities.attachments.maxFileBytes",
      ),
      maxStagedBytes: positiveWireId(
        attachmentCapability.maxStagedBytes,
        "$.capabilities.attachments.maxStagedBytes",
      ),
    },
  };
  if (
    capabilities.attachments.enabled !==
      (capabilities.attachments.imageFormats.length === 3) ||
    (capabilities.attachments.enabled &&
      capabilities.attachments.imageFormats.join(",") !== "png,jpeg,webp")
  )
    fail(
      "$.capabilities.attachments",
      "attachment formats must match the enabled policy",
    );
  if (
    capabilities.taskHistoryPersistence !==
    (capabilities.taskHistoryPersistenceHealth === "ready" ||
      capabilities.taskHistoryPersistenceHealth === "degraded")
  )
    fail(
      "$.capabilities.taskHistoryPersistence",
      "Task history persistence availability and health must agree",
    );
  if (
    capabilities.taskHistoryRecoveryAvailable &&
    !["read_failed", "corrupt", "write_failed", "outcome_unknown"].includes(
      capabilities.taskHistoryPersistenceHealth,
    )
  )
    fail(
      "$.capabilities.taskHistoryRecoveryAvailable",
      "Task history recovery requires recoverable persistence health",
    );
  if (
    capabilities.scheduledTaskRecoveryAvailable &&
    !["read_failed", "corrupt", "write_failed", "outcome_unknown"].includes(
      capabilities.scheduledTaskPersistenceHealth,
    )
  )
    fail(
      "$.capabilities.scheduledTaskRecoveryAvailable",
      "Scheduled Task recovery requires recoverable persistence health",
    );
  const permissionItem = object(root.permissions, "$.permissions", [
    "availableProfiles",
    "defaultProfile",
    "availableModes",
    "defaultMode",
  ]);
  const availableProfiles = arrayValue(
    permissionItem.availableProfiles,
    "$.permissions.availableProfiles",
    (profile, profilePath) =>
      enumValue(profile, profilePath, permissionProfiles),
  );
  if (new Set(availableProfiles).size !== availableProfiles.length)
    fail("$.permissions.availableProfiles", "profiles must be unique");
  if (
    (!capabilities.permissionProfiles && availableProfiles.length !== 0) ||
    (capabilities.permissionProfiles &&
      availableProfiles.length !== permissionProfiles.length)
  )
    fail(
      "$.permissions.availableProfiles",
      "profile capability and available profiles must agree",
    );
  if (
    capabilities.permissionProfiles &&
    permissionProfiles.some((profile) => !availableProfiles.includes(profile))
  )
    fail(
      "$.permissions.availableProfiles",
      "enabled profile capability must expose the complete admitted set",
    );
  const permissions = {
    availableModes: arrayValue(
      permissionItem.availableModes,
      "$.permissions.availableModes",
      (mode, modePath) => enumValue(mode, modePath, approvalModes),
    ),
    defaultMode: enumValue(
      permissionItem.defaultMode,
      "$.permissions.defaultMode",
      approvalModes,
    ),
    availableProfiles,
    defaultProfile: enumValue(
      permissionItem.defaultProfile,
      "$.permissions.defaultProfile",
      permissionProfiles,
    ),
  };
  if (
    new Set(permissions.availableModes).size !==
      permissions.availableModes.length ||
    (capabilities.permissionProfiles
      ? approvalModes.some((mode) => !permissions.availableModes.includes(mode))
      : permissions.availableModes.length !== 0) ||
    (permissions.defaultMode === "full_access") !==
      (permissions.defaultProfile === "full_access")
  )
    fail("$.permissions", "approval modes and execution profiles must agree");
  const workspaces = arrayValue(
    view.workspaces,
    "$.workspaces",
    decodeWorkspace,
  );
  const taskIndex = arrayValue(
    view.taskIndex,
    "$.taskIndex",
    decodeTaskSummary,
  );
  let taskPage: WorkbenchSnapshot["taskPage"] = null;
  if (view.taskPage !== null) {
    const page = object(view.taskPage, "$.taskPage", [
      "beforeRunId",
      "nextBeforeRunId",
      "runManifest",
      "task",
    ]);
    const beforeRunId =
      page.beforeRunId === null
        ? null
        : positiveWireId(page.beforeRunId, "$.taskPage.beforeRunId");
    const nextBeforeRunId =
      page.nextBeforeRunId === null
        ? null
        : positiveWireId(page.nextBeforeRunId, "$.taskPage.nextBeforeRunId");
    const runManifest = arrayValue(
      page.runManifest,
      "$.taskPage.runManifest",
      decodeRunManifest,
    );
    if (new Set(runManifest.map((run) => run.id)).size !== runManifest.length)
      fail("$.taskPage.runManifest", "duplicate Run identity");
    for (let i = 1; i < runManifest.length; i++)
      if (BigInt(runManifest[i - 1]!.id) >= BigInt(runManifest[i]!.id))
        fail("$.taskPage.runManifest", "invalid Run order");
    const task = decodeTask(page.task, "$.taskPage.task", runManifest);
    if (task.id !== scope.taskId || beforeRunId !== null)
      fail("$.taskPage", "page identity mismatch");
    const expectedRuns = runManifest.slice(-scope.runLimit);
    if (
      task.runs.length !== expectedRuns.length ||
      task.runs.some((run, index) => run.id !== expectedRuns[index]!.id) ||
      nextBeforeRunId !==
        (runManifest.length > scope.runLimit ? expectedRuns[0]!.id : null)
    )
      fail("$.taskPage", "missing or unexpected current Run page");
    if (
      task.runs.length > scope.runLimit ||
      task.runs.some(
        (run) => beforeRunId !== null && BigInt(run.id) >= BigInt(beforeRunId),
      )
    )
      fail("$.taskPage", "invalid page bounds");
    if (
      nextBeforeRunId !== null &&
      (task.runs[0]?.id !== nextBeforeRunId ||
        !runManifest.some((run) => BigInt(run.id) < BigInt(nextBeforeRunId)))
    )
      fail("$.taskPage", "invalid next cursor");
    taskPage = { beforeRunId, nextBeforeRunId, runManifest, task };
  }
  if (scope.taskId === null && taskPage !== null)
    fail("$.taskPage", "unsolicited Task page");
  let historyPage: WorkbenchSnapshot["historyPage"] = null;
  if (view.historyPage !== null) {
    if (!taskPage || scope.beforeRunId === null)
      fail("$.historyPage", "unsolicited history page");
    const page = object(view.historyPage, "$.historyPage", [
      "beforeRunId",
      "nextBeforeRunId",
      "runs",
    ]);
    const beforeRunId = positiveWireId(
      page.beforeRunId,
      "$.historyPage.beforeRunId",
    );
    const nextBeforeRunId =
      page.nextBeforeRunId === null
        ? null
        : positiveWireId(page.nextBeforeRunId, "$.historyPage.nextBeforeRunId");
    if (
      beforeRunId !== scope.beforeRunId ||
      !taskPage.runManifest.some((run) => run.id === beforeRunId)
    )
      fail("$.historyPage", "history cursor association mismatch");
    const runs = arrayValue(page.runs, "$.historyPage.runs", decodeRun);
    const eligible = taskPage.runManifest.filter(
      (run) => BigInt(run.id) < BigInt(beforeRunId),
    );
    const expected = eligible.slice(-scope.runLimit);
    if (
      runs.length !== expected.length ||
      runs.some(
        (run, index) =>
          run.id !== expected[index]!.id ||
          run.phase !== expected[index]!.phase ||
          run.permissionProfile !== expected[index]!.permissionProfile ||
          run.permissionInteraction !==
            expected[index]!.permissionInteraction ||
          JSON.stringify(run.terminal) !==
            JSON.stringify(expected[index]!.terminal),
      )
    )
      fail("$.historyPage", "history Run manifest mismatch");
    if (
      nextBeforeRunId !== (eligible.length > runs.length ? runs[0]!.id : null)
    )
      fail("$.historyPage", "invalid history continuation");
    historyPage = { beforeRunId, nextBeforeRunId, runs };
  }
  if (scope.beforeRunId !== null && taskPage !== null && historyPage === null)
    fail("$.historyPage", "missing requested history page");
  const tasks = taskPage === null ? [] : [taskPage.task];
  const receipts = arrayValue(view.receipts, "$.receipts", (value, path) => {
    const item = object(value, path, ["taskId", "operationId", "observed"]);
    return {
      taskId: positiveWireId(item.taskId, `${path}.taskId`),
      operationId: stringValue(item.operationId, `${path}.operationId`),
      observed: booleanValue(item.observed, `${path}.observed`),
    };
  });
  if (
    receipts.length !== scope.receipts.length ||
    receipts.some(
      (receipt, index) =>
        receipt.taskId !== scope.receipts[index]!.taskId ||
        receipt.operationId !== scope.receipts[index]!.operationId ||
        (receipt.observed &&
          !taskIndex.some((task) => task.id === receipt.taskId)),
    )
  )
    fail("$.receipts", "receipt identity mismatch");
  if ((view.searchIndex !== null) !== scope.search)
    fail("$.searchIndex", "search scope mismatch");
  const searchIndex =
    view.searchIndex === null
      ? null
      : (() => {
          const page = object(view.searchIndex, "$.searchIndex", [
            "stale",
            "results",
            "nextCursor",
          ]);
          const stale = booleanValue(page.stale, "$.searchIndex.stale");
          const results = arrayValue(
            page.results,
            "$.searchIndex.results",
            (value, path) => {
              const hit = object(value, path, [
                "taskId",
                "runId",
                "part",
                "kind",
                "detail",
              ]);
              const taskId = positiveU64WireId(hit.taskId, `${path}.taskId`);
              if (!taskIndex.some((task) => task.id === taskId))
                fail(path, "unknown search Task");
              const runId =
                hit.runId === null
                  ? null
                  : positiveU64WireId(hit.runId, `${path}.runId`);
              const kind = enumValue(hit.kind, `${path}.kind`, [
                "task",
                "instruction",
                "completion",
              ] as const);
              if ((kind === "task") !== (runId === null))
                fail(path, "search kind mismatch");
              const detail = stringValue(hit.detail, `${path}.detail`);
              if (new TextEncoder().encode(detail).length > 512)
                fail(path, "unbounded search snippet");
              return {
                taskId,
                runId,
                part: u64WireInteger(hit.part, `${path}.part`),
                kind,
                detail,
              };
            },
          );
          const nextCursor = decodeSearchCursor(
            page.nextCursor,
            "$.searchIndex.nextCursor",
          );
          if (
            nextCursor &&
            JSON.stringify(nextCursor) === JSON.stringify(scope.searchCursor)
          )
            fail("$.searchIndex", "non-progressing search cursor");
          if (
            results.length > 50 ||
            (stale && (results.length !== 0 || nextCursor !== null)) ||
            new Set(
              results.map((hit) => `${hit.taskId}:${hit.runId}:${hit.part}`),
            ).size !== results.length
          )
            fail("$.searchIndex", "invalid search page");
          return { stale, results, nextCursor };
        })();
  const summary = taskIndex.find((task) => task.id === scope.taskId);
  if ((summary !== undefined) !== (taskPage !== null))
    fail("$.taskPage", "Task presence disagrees with index");
  if (summary && taskPage) {
    for (const key of [
      "id",
      "recentOrder",
      "title",
      "workspaceId",
      "archived",
      "lifecycle",
      "deletionStatus",
      "currentRunPhase",
      "permissionReviewState",
      "unreadCompletionRunId",
      "activeOperation",
    ] as const)
      if (JSON.stringify(summary[key]) !== JSON.stringify(taskPage.task[key]))
        fail("$.taskPage", "Task header disagrees with index");
  }
  const skillManagement =
    scope.management === "skills"
      ? decodeSkillManagement(management.value, "$.management.value")
      : null;
  if (skillManagement) {
    assertSourceDiscoverySettings(
      skillManagement.personalSourceDiscovery,
      skillManagement.sourceSettings,
      "$.management.value.personalSourceDiscovery",
    );
    for (const workspace of workspaces)
      assertSourceDiscoverySettings(
        workspace.skillSourceDiscovery,
        skillManagement.sourceSettings,
        "$.workspaces.skillSourceDiscovery",
      );
  }
  const scheduledTasks =
    scope.management === "schedules"
      ? arrayValue(management.value, "$.management.value", decodeScheduledTask)
      : null;
  const mcp =
    scope.management === "mcp"
      ? decodeMcpManagement(management.value, "$.management.value")
      : null;
  if (mcp && !capabilities.mcpManagement) {
    if (
      mcp.availability !== "unavailable" ||
      mcp.managementHealth !== "unavailable" ||
      mcp.operation !== "idle" ||
      mcp.configurationApply !== "idle" ||
      mcp.authorizationOperation.kind !== "idle" ||
      mcp.desiredGeneration !== null ||
      mcp.runtimeAlignment !== "unknown" ||
      mcp.redacted ||
      mcp.servers.length !== 0
    )
      fail("$.mcp", "disabled MCP management must use the unavailable view");
    if (
      capabilities.mcpConnectionApproval ||
      capabilities.mcpSecretCapture ||
      capabilities.mcpOAuth
    )
      fail(
        "$.capabilities",
        "disabled MCP management cannot expose Host MCP effects",
      );
  } else if (mcp?.managementHealth === "unavailable") {
    fail("$.mcp.managementHealth", "enabled MCP management requires its owner");
  }
  if (capabilities.mcpManagement !== capabilities.mcpSecretMaxBytes > 0)
    fail(
      "$.capabilities.mcpSecretMaxBytes",
      "MCP secret byte limit must be positive when management is enabled and zero otherwise",
    );
  if (
    new Set(workspaces.map((workspace) => workspace.id)).size !==
    workspaces.length
  )
    fail("$.workspaces", "Workspace identities must be unique");
  const workspaceIds = new Set(workspaces.map((workspace) => workspace.id));
  if (new Set(taskIndex.map((task) => task.id)).size !== taskIndex.length)
    fail("$.tasks", "Task identities must be unique");
  if (
    scheduledTasks &&
    new Set(scheduledTasks.map((task) => task.id)).size !==
      scheduledTasks.length
  )
    fail("$.scheduledTasks", "scheduled Task identities must be unique");
  const tasksById = new Map(tasks.map((task) => [task.id, task]));
  if (scheduledTasks)
    for (const schedule of scheduledTasks) {
      for (const occurrence of schedule.occurrences) {
        if (occurrence.taskId === null) continue;
        const occurrenceTask = tasksById.get(occurrence.taskId);
        if (!occurrenceTask) continue;
        if (
          occurrenceTask.runs.some(
            (run) => run.permissionInteraction !== "noninteractive",
          )
        )
          fail(
            "$.scheduledTasks",
            "scheduled occurrence Runs must be noninteractive",
          );
      }
    }
  for (const workspace of workspaces) {
    const taskCount = taskIndex.filter(
      (task) => task.workspaceId === workspace.id,
    ).length;
    if (workspace.kind === "automatic" && taskCount !== 1)
      fail(
        "$.workspaces",
        "automatic Workspace must belong to exactly one Task",
      );
  }
  return {
    revision,
    blockVersions,
    securityEpoch,
    historyEpoch,
    scope,
    taskIndex,
    receipts,
    searchIndex,
    taskPage,
    historyPage,
    automaticWorkspaceRoot,
    capabilities,
    permissions,
    account: decodeAccount(root.account, "$.account"),
    models: decodeModels(root.models, "$.models"),
    newTaskAdmission: decodeNewTaskAdmission(
      root.newTaskAdmission,
      "$.newTaskAdmission",
    ),
    skillCatalog: decodeSkillCatalog(root.skillCatalog, "$.skillCatalog"),
    skillManagement,
    mcp,
    workspaces,
    scheduledTasks,
    tasks,
  };
}
export function decodeAccountCommandResult(
  value: unknown,
): AccountCommandResult {
  const item = object(value, "$", ["accepted", "errorCode", "attemptId"]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const errorCode = enumValue(item.errorCode, "$.errorCode", accountErrorCodes);
  const attemptId =
    item.attemptId === null
      ? null
      : positiveWireId(item.attemptId, "$.attemptId");
  if (accepted !== (errorCode === "none"))
    fail("$", "accepted and errorCode must agree");
  if (!accepted && attemptId !== null)
    fail("$", "a rejected command cannot expose an attempt");
  return { accepted, errorCode, attemptId };
}
export function decodeExecutionCommandResult(
  value: unknown,
): ExecutionCommandResult {
  const item = object(value, "$", ["accepted", "errorCode", "attemptId"]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const errorCode = enumValue(
    item.errorCode,
    "$.errorCode",
    executionCommandErrorCodes,
  );
  if (item.attemptId !== null) fail("$.attemptId", "expected null");
  if (accepted !== (errorCode === "none"))
    fail("$", "accepted and errorCode must agree");
  return { accepted, errorCode, attemptId: null };
}
export function decodeRendererBridgeConnect(value: unknown) {
  const acceptedValue = booleanValue(
    (value as JsonObject)?.accepted,
    "$.accepted",
  );
  const item = object(value, "$", [
    "accepted",
    "contractId",
    "contractRevision",
    "generation",
    "error",
    ...(acceptedValue ? ["attachmentInput"] : []),
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const contractId = stringValue(item.contractId, "$.contractId");
  const contractRevision = positiveNumber(
    item.contractRevision,
    "$.contractRevision",
  );
  if (accepted) {
    if (item.error !== null) fail("$.error", "expected null");
    const input = object(item.attachmentInput, "$.attachmentInput", [
      "mode",
      "maxChunkBytes",
    ]);
    const mode = enumValue(input.mode, "$.attachmentInput.mode", [
      "native_paths",
      "file_bytes",
    ] as const);
    const maxChunkBytes = positiveWireId(
      input.maxChunkBytes,
      "$.attachmentInput.maxChunkBytes",
    );
    if (BigInt(maxChunkBytes) > 128n * 1024n)
      fail(
        "$.attachmentInput.maxChunkBytes",
        "chunk exceeds Bridge frame budget",
      );
    return {
      accepted: true as const,
      contractId,
      contractRevision,
      generation: positiveWireId(item.generation, "$.generation"),
      attachmentInput: { mode, maxChunkBytes: Number(maxChunkBytes) },
      error: null,
    };
  }
  if (item.generation !== null) fail("$.generation", "expected null");
  return {
    accepted: false as const,
    contractId,
    contractRevision,
    generation: null,
    error: enumValue(item.error, "$.error", rendererBridgeConnectErrors),
  };
}
export function decodeRevisionNotification(value: unknown) {
  const item = object(value, "$", ["generation", "revision", "securityEpoch"]);
  return {
    generation: positiveU64WireId(item.generation, "$.generation"),
    revision: wireId(item.revision, "$.revision"),
    securityEpoch: positiveU64WireId(item.securityEpoch, "$.securityEpoch"),
  };
}
function decodeSignal(value: unknown, keys: readonly string[]): HostSignal {
  const item = object(value, "$", keys);
  const sequence = positiveNumber(item.sequence, "$.sequence");
  stringValue(item.transport, "$.transport");
  stringValue(item.origin, "$.origin");
  booleanValue(item.onMainThread, "$.onMainThread");
  return {
    sequence,
  };
}
export function decodeHostSignalEvent(value: unknown): HostSignal {
  const keys = [
    "sequence",
    "transport",
    "origin",
    "onMainThread",
    "requestBytes",
  ];
  const signal = decodeSignal(value, keys);
  const item = value as JsonObject;
  nonNegativeNumber(item.requestBytes, "$.requestBytes");
  return signal;
}
export function decodePingResponse(value: unknown): HostSignal {
  return decodeSignal(value, [
    "sequence",
    "transport",
    "origin",
    "onMainThread",
  ]);
}
export function assertSignalAcknowledged(value: unknown, sequence: number) {
  const item = object(value, "$", [
    "sequence",
    "transport",
    "origin",
    "onMainThread",
  ]);
  if (positiveNumber(item.sequence, "$.sequence") !== sequence)
    fail("$.sequence", "acknowledgement identity mismatch");
  stringValue(item.transport, "$.transport");
  stringValue(item.origin, "$.origin");
  booleanValue(item.onMainThread, "$.onMainThread");
}
export function assertDisconnected(value: unknown, generation: string) {
  const item = object(value, "$", ["generation", "detached"]);
  if (
    positiveWireId(item.generation, "$.generation") !== generation ||
    booleanValue(item.detached, "$.detached") !== true
  )
    fail("$", "disconnect response mismatch");
}
export function assertWindowChromeHandled(value: unknown, generation: string) {
  const item = object(value, "$", ["generation", "handled"]);
  if (
    positiveWireId(item.generation, "$.generation") !== generation ||
    booleanValue(item.handled, "$.handled") !== true
  )
    fail("$", "window chrome acknowledgement mismatch");
}
export type WindowChromeEnvironment = {
  generation: string;
  insets: {
    top: number;
    left: number;
    bottom: number;
    right: number;
  };
  buttons: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  rendererControls: boolean;
  maximized: boolean;
};
export function decodeWindowChromeEnvironment(
  value: unknown,
): WindowChromeEnvironment {
  const item = object(value, "$", [
    "generation",
    "insets",
    "buttons",
    "rendererControls",
    "maximized",
  ]);
  const insets = object(item.insets, "$.insets", [
    "top",
    "left",
    "bottom",
    "right",
  ]);
  const buttons = object(item.buttons, "$.buttons", [
    "x",
    "y",
    "width",
    "height",
  ]);
  return {
    generation: positiveWireId(item.generation, "$.generation"),
    insets: {
      top: nonNegativeFiniteNumber(insets.top, "$.insets.top"),
      left: nonNegativeFiniteNumber(insets.left, "$.insets.left"),
      bottom: nonNegativeFiniteNumber(insets.bottom, "$.insets.bottom"),
      right: nonNegativeFiniteNumber(insets.right, "$.insets.right"),
    },
    buttons: {
      x: nonNegativeFiniteNumber(buttons.x, "$.buttons.x"),
      y: nonNegativeFiniteNumber(buttons.y, "$.buttons.y"),
      width: nonNegativeFiniteNumber(buttons.width, "$.buttons.width"),
      height: nonNegativeFiniteNumber(buttons.height, "$.buttons.height"),
    },
    rendererControls: booleanValue(item.rendererControls, "$.rendererControls"),
    maximized: booleanValue(item.maximized, "$.maximized"),
  };
}
export function decodeWorkspaceChoice(value: unknown): WorkspaceChoice {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail("$", "expected workspace choice object");
  const selected = booleanValue((value as JsonObject).selected, "$.selected");
  if (!selected) {
    object(value, "$", ["selected"]);
    return { selected: false };
  }
  const item = object(value, "$", ["selected", "workspaceId"]);
  return {
    selected: true,
    workspaceId: positiveWireId(item.workspaceId, "$.workspaceId"),
  };
}
export function decodeSkillImportPreview(value: unknown): SkillImportPreview {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail("$", "expected Skill import preview object");
  const selected = booleanValue((value as JsonObject).selected, "$.selected");
  if (!selected) {
    object(value, "$", ["selected"]);
    return { selected: false };
  }
  const item = object(value, "$", [
    "selected",
    "previewId",
    "sourceKind",
    "invocationName",
    "displayName",
    "description",
    "fileCount",
    "totalBytes",
  ]);
  return {
    selected: true,
    previewId: positiveWireId(item.previewId, "$.previewId"),
    sourceKind: enumValue(item.sourceKind, "$.sourceKind", [
      "local_package",
      "local_directory",
    ] as const),
    invocationName: stringValue(item.invocationName, "$.invocationName"),
    displayName: stringValue(item.displayName, "$.displayName"),
    description: stringValue(item.description, "$.description"),
    fileCount: positiveNumber(item.fileCount, "$.fileCount"),
    totalBytes: positiveNumber(item.totalBytes, "$.totalBytes"),
  };
}
export function decodeMcpMutationResult(value: unknown): McpMutationResult {
  const item = object(value, "$", ["outcome", "desiredGeneration"]);
  const outcome = enumValue(item.outcome, "$.outcome", [
    "unchanged",
    "saved",
    "saved_recovery_required",
    "stale_generation",
    "rejected",
    "indeterminate",
    "busy",
    "cancelled",
    "capability_unavailable",
  ] as const);
  const desiredGeneration =
    item.desiredGeneration === null
      ? null
      : wireId(item.desiredGeneration, "$.desiredGeneration");
  if (outcome === "indeterminate" && desiredGeneration !== null)
    fail(
      "$.desiredGeneration",
      "indeterminate outcome cannot claim generation",
    );
  if (
    [
      "unchanged",
      "saved",
      "saved_recovery_required",
      "stale_generation",
    ].includes(outcome) &&
    desiredGeneration === null
  )
    fail("$.desiredGeneration", "known mutation outcome requires generation");
  return { outcome, desiredGeneration };
}
export function decodeMcpRefreshResult(value: unknown): McpRefreshResult {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", [
      "started",
      "busy",
      "unavailable",
      "shutting_down",
      "rejected",
    ] as const),
  };
}
export function decodeMcpConfigurationApplyResult(
  value: unknown,
): McpConfigurationApplyResult {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", [
      "started",
      "busy",
      "unavailable",
      "rejected",
    ] as const),
  };
}
export function decodeMcpConnectionTestResult(
  value: unknown,
): McpConnectionTestResult {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", [
      "started",
      "busy",
      "stale_generation",
      "needs_authentication",
      "rejected",
      "unavailable",
    ] as const),
  };
}
export function decodeMcpAuthorizationResult(
  value: unknown,
): McpAuthorizationResult {
  const item = object(value, "$", ["outcome", "operationId"]);
  const outcome = enumValue(item.outcome, "$.outcome", [
    "started",
    "busy",
    "rejected",
    "stale_generation",
    "capability_unavailable",
  ] as const);
  const operationId =
    item.operationId === null
      ? null
      : nonEmptyString(item.operationId, "$.operationId");
  if ((outcome === "started") !== (operationId !== null))
    fail("$.operationId", "only a started authorization has an operation id");
  return { outcome, operationId };
}
export function decodeMcpAuthorizationCancelResult(
  value: unknown,
): McpAuthorizationCancelResult {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", [
      "cancelled",
      "saved",
      "saved_recovery_required",
      "rejected",
      "indeterminate",
      "capability_unavailable",
    ] as const),
  };
}
export function decodeSkillMutationResult(value: unknown): SkillMutationResult {
  const item = object(value, "$", [
    "accepted",
    "installId",
    "verificationPending",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const pending = booleanValue(
    item.verificationPending,
    "$.verificationPending",
  );
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      installId: nonEmptyString(item.installId, "$.installId"),
      verificationPending: pending,
      reason: null,
    };
  }
  if (item.installId !== null) fail("$.installId", "expected null");
  if (pending) fail("$.verificationPending", "rejection cannot be pending");
  return {
    accepted: false,
    installId: null,
    verificationPending: false,
    reason: enumValue(item.reason, "$.reason", [
      "invalid_scope",
      "invalid_preview",
      "source_changed",
      "asset_unavailable",
      "state_changed",
      "target_exists",
      "busy",
      "catalog_loading",
      "workspace_changed",
      "workspace_unavailable",
      "capacity_reached",
      "shutting_down",
      "local_storage_failed",
    ] as const),
  };
}
export function decodeSkillEnablementResult(
  value: unknown,
): SkillEnablementResult {
  const item = object(value, "$", ["applied", "selectionRevision", "reason"]);
  const applied = booleanValue(item.applied, "$.applied");
  if (applied) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      applied: true,
      selectionRevision: positiveWireId(
        item.selectionRevision,
        "$.selectionRevision",
      ),
      reason: null,
    };
  }
  if (item.selectionRevision !== null)
    fail("$.selectionRevision", "expected null");
  return {
    applied: false,
    selectionRevision: null,
    reason: enumValue(item.reason, "$.reason", [
      "invalid_scope",
      "invalid_preview",
      "source_changed",
      "asset_unavailable",
      "state_changed",
      "target_exists",
      "busy",
      "catalog_loading",
      "workspace_changed",
      "workspace_unavailable",
      "capacity_reached",
      "shutting_down",
      "local_storage_failed",
    ] as const),
  };
}
export function decodeSkillSourceSettingsResult(
  value: unknown,
): SkillSourceSettingsResult {
  const item = object(value, "$", ["applied", "revision", "reason"]);
  const applied = booleanValue(item.applied, "$.applied");
  if (applied) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      applied: true,
      revision: positiveWireId(item.revision, "$.revision"),
      reason: null,
    };
  }
  if (item.revision !== null) fail("$.revision", "expected null");
  return {
    applied: false,
    revision: null,
    reason: enumValue(item.reason, "$.reason", skillSourceSettingsReasons),
  };
}
export function decodeSkillExportResult(value: unknown): SkillExportResult {
  const item = object(value, "$", ["exported", "fileName", "reason"]);
  const exported = booleanValue(item.exported, "$.exported");
  if (exported) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      exported: true,
      fileName: nonEmptyString(item.fileName, "$.fileName"),
      reason: null,
    };
  }
  if (item.fileName !== null) fail("$.fileName", "expected null");
  return {
    exported: false,
    fileName: null,
    reason: nonEmptyString(item.reason, "$.reason"),
  };
}
export function decodeSkillDetailResult(value: unknown): SkillDetailResult {
  const item = object(value, "$", [
    "available",
    "definition",
    "fileCount",
    "totalBytes",
    "reason",
  ]);
  const available = booleanValue(item.available, "$.available");
  if (available) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      available: true,
      definition: stringValue(item.definition, "$.definition"),
      fileCount: positiveNumber(item.fileCount, "$.fileCount"),
      totalBytes: positiveNumber(item.totalBytes, "$.totalBytes"),
      reason: null,
    };
  }
  if (item.definition !== null) fail("$.definition", "expected null");
  if (item.fileCount !== 0 || item.totalBytes !== 0)
    fail("$", "unavailable detail cannot expose file metadata");
  return {
    available: false,
    definition: null,
    fileCount: 0,
    totalBytes: 0,
    reason: nonEmptyString(item.reason, "$.reason"),
  };
}
export function decodeTaskCreateResult(value: unknown): TaskCreateResult {
  const item = object(value, "$", [
    "accepted",
    "taskId",
    "bindingEpoch",
    "mcpAuthority",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId: positiveWireId(item.taskId, "$.taskId"),
      bindingEpoch: positiveWireId(item.bindingEpoch, "$.bindingEpoch"),
      mcpAuthority: decodeTaskMcpAuthority(item.mcpAuthority, "$.mcpAuthority"),
      reason: null,
    };
  }
  if (
    item.taskId !== null ||
    item.bindingEpoch !== null ||
    item.mcpAuthority !== null
  )
    fail("$", "a rejected Task creation cannot expose identities");
  return {
    accepted: false,
    taskId: null,
    bindingEpoch: null,
    mcpAuthority: null,
    reason: enumValue(item.reason, "$.reason", taskCreateReasons),
  };
}
export function decodeTaskRunResult(
  value: unknown,
  expectedTaskId: string,
): TaskRunResult {
  const item = object(value, "$", ["accepted", "taskId", "runId", "reason"]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const taskId = positiveWireId(item.taskId, "$.taskId");
  if (taskId !== expectedTaskId) fail("$.taskId", "response identity mismatch");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId,
      runId: positiveWireId(item.runId, "$.runId"),
      reason: null,
    };
  }
  if (item.runId !== null) fail("$.runId", "expected null");
  return {
    accepted: false,
    taskId,
    runId: null,
    reason: enumValue(item.reason, "$.reason", taskRunReasons),
  };
}
export function decodeTaskCompletionSeenResult(
  value: unknown,
  expectedTaskId: string,
  expectedRunId: string,
) {
  const item = object(value, "$", ["taskId", "runId", "marked"]);
  const taskId = positiveWireId(item.taskId, "$.taskId");
  const runId = positiveWireId(item.runId, "$.runId");
  if (taskId !== expectedTaskId || runId !== expectedRunId)
    fail("$", "completion receipt response identity mismatch");
  return {
    taskId,
    runId,
    marked: booleanValue(item.marked, "$.marked"),
  };
}
export function decodeTaskApprovalModeResult(
  value: unknown,
  expectedTaskId: string,
): TaskApprovalModeResult {
  const item = object(value, "$", [
    "accepted",
    "taskId",
    "approvalRevision",
    "reason",
  ]);
  const taskId = positiveWireId(item.taskId, "$.taskId");
  if (taskId !== expectedTaskId) fail("$.taskId", "response identity mismatch");
  if (booleanValue(item.accepted, "$.accepted")) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId,
      approvalRevision: positiveWireId(
        item.approvalRevision,
        "$.approvalRevision",
      ),
      reason: null,
    };
  }
  if (item.approvalRevision !== null)
    fail("$.approvalRevision", "expected null");
  return {
    accepted: false,
    taskId,
    approvalRevision: null,
    reason: enumValue(item.reason, "$.reason", taskApprovalModeReasons),
  };
}
export function decodeTaskModelSelectionResult(
  value: unknown,
  expectedTaskId: string,
): TaskModelSelectionResult {
  const item = object(value, "$", [
    "accepted",
    "taskId",
    "selectionRevision",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const taskId = positiveWireId(item.taskId, "$.taskId");
  if (taskId !== expectedTaskId) fail("$.taskId", "response identity mismatch");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId,
      selectionRevision: positiveU64WireId(
        item.selectionRevision,
        "$.selectionRevision",
      ),
      reason: null,
    };
  }
  if (item.selectionRevision !== null)
    fail("$.selectionRevision", "expected null");
  return {
    accepted: false,
    taskId,
    selectionRevision: null,
    reason: enumValue(item.reason, "$.reason", taskModelSelectionReasons),
  };
}
export function decodeTaskCompactResult(
  value: unknown,
  expectedTaskId: string,
): TaskCompactResult {
  const item = object(value, "$", [
    "accepted",
    "taskId",
    "operationId",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const taskId = positiveWireId(item.taskId, "$.taskId");
  if (taskId !== expectedTaskId) fail("$.taskId", "response identity mismatch");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId,
      operationId: positiveWireId(item.operationId, "$.operationId"),
      reason: null,
    };
  }
  if (item.operationId !== null) fail("$.operationId", "expected null");
  return {
    accepted: false,
    taskId,
    operationId: null,
    reason: enumValue(item.reason, "$.reason", taskCompactReasons),
  };
}
export function decodeTaskRestoreResult(
  value: unknown,
  expectedTaskId: string,
): TaskRestoreResult {
  const item = object(value, "$", [
    "accepted",
    "taskId",
    "attemptId",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const taskId = positiveWireId(item.taskId, "$.taskId");
  if (taskId !== expectedTaskId) fail("$.taskId", "response identity mismatch");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId,
      attemptId: positiveWireId(item.attemptId, "$.attemptId"),
      reason: null,
    };
  }
  if (item.attemptId !== null) fail("$.attemptId", "expected null");
  return {
    accepted: false,
    taskId,
    attemptId: null,
    reason: enumValue(item.reason, "$.reason", taskRestoreReasons),
  };
}
export function assertCompactCancelAccepted(
  value: unknown,
  taskId: string,
  operationId: string,
) {
  const item = object(value, "$", ["taskId", "operationId", "cancelRequested"]);
  if (
    positiveWireId(item.taskId, "$.taskId") !== taskId ||
    positiveWireId(item.operationId, "$.operationId") !== operationId ||
    booleanValue(item.cancelRequested, "$.cancelRequested") !== true
  )
    fail("$", "Compact cancel response mismatch");
}
export function decodeScheduledTaskMutationResult(
  value: unknown,
  expectedId?: string,
) {
  const item = object(value, "$", ["scheduledTaskId", "epoch", "accepted"]);
  if (!booleanValue(item.accepted, "$.accepted"))
    fail("$.accepted", "scheduled Task mutation must be accepted");
  const scheduledTaskId = positiveWireId(
    item.scheduledTaskId,
    "$.scheduledTaskId",
  );
  if (expectedId !== undefined && scheduledTaskId !== expectedId)
    fail("$.scheduledTaskId", "response identity mismatch");
  return {
    accepted: true as const,
    scheduledTaskId,
    epoch: positiveWireId(item.epoch, "$.epoch"),
  };
}
export function decodeScheduledTaskEnabledResult(
  value: unknown,
  expectedId: string,
  expectedEnabled: boolean,
) {
  const item = object(value, "$", ["scheduledTaskId", "epoch", "enabled"]);
  const scheduledTaskId = positiveWireId(
    item.scheduledTaskId,
    "$.scheduledTaskId",
  );
  if (scheduledTaskId !== expectedId)
    fail("$.scheduledTaskId", "response identity mismatch");
  const enabled = booleanValue(item.enabled, "$.enabled");
  if (enabled !== expectedEnabled) fail("$.enabled", "response state mismatch");
  return {
    scheduledTaskId,
    epoch: positiveWireId(item.epoch, "$.epoch"),
    enabled,
  };
}
export function decodeScheduledTaskRunResult(
  value: unknown,
  expectedId: string,
) {
  const item = object(value, "$", ["scheduledTaskId", "taskId", "accepted"]);
  if (!booleanValue(item.accepted, "$.accepted"))
    fail("$.accepted", "scheduled Task run must be accepted");
  const scheduledTaskId = positiveWireId(
    item.scheduledTaskId,
    "$.scheduledTaskId",
  );
  if (scheduledTaskId !== expectedId)
    fail("$.scheduledTaskId", "response identity mismatch");
  return {
    accepted: true as const,
    scheduledTaskId,
    taskId: positiveWireId(item.taskId, "$.taskId"),
  };
}
export function assertScheduledTaskDeleted(value: unknown, expectedId: string) {
  const item = object(value, "$", ["scheduledTaskId", "deleted"]);
  if (positiveWireId(item.scheduledTaskId, "$.scheduledTaskId") !== expectedId)
    fail("$.scheduledTaskId", "response identity mismatch");
  if (!booleanValue(item.deleted, "$.deleted"))
    fail("$.deleted", "expected deletion confirmation");
}
const persistenceRecoveryOutcomes = [
  "recovered",
  "stale_revision",
  "not_required",
  "unavailable",
  "failed",
  "outcome_unknown",
  "shutting_down",
] as const satisfies readonly PersistenceRecoveryOutcome[];
export function decodePersistenceRecoveryResult(value: unknown) {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", persistenceRecoveryOutcomes),
  };
}
export function decodeCatalogRefreshResult<
  Identity extends "workspaceId" | "taskId",
>(
  value: unknown,
  identityName: Identity,
  expectedIdentity: string,
): CatalogRefreshResult<Identity> {
  const item = object(value, "$", ["accepted", identityName, "reason"]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const identity = positiveWireId(item[identityName], `$.${identityName}`);
  if (identity !== expectedIdentity)
    fail(`$.${identityName}`, "response identity mismatch");
  const reason =
    item.reason === null
      ? null
      : enumValue(item.reason, "$.reason", catalogRefreshReasons);
  if (accepted !== (reason === null))
    fail("$", "accepted and reason must agree");
  return {
    accepted,
    [identityName]: identity,
    reason,
  } as CatalogRefreshResult<Identity>;
}
export function decodeSkillCatalogRefreshResult(
  value: unknown,
): SkillCatalogRefreshResult {
  const item = object(value, "$", ["accepted", "reason"]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const reason =
    item.reason === null
      ? null
      : enumValue(item.reason, "$.reason", catalogRefreshReasons);
  if (accepted !== (reason === null))
    fail("$", "accepted and reason must agree");
  return { accepted, reason };
}
export function assertCancelAccepted(
  value: unknown,
  taskId: string,
  runId: string,
) {
  const item = object(value, "$", ["taskId", "runId", "cancelRequested"]);
  if (
    positiveWireId(item.taskId, "$.taskId") !== taskId ||
    positiveWireId(item.runId, "$.runId") !== runId ||
    booleanValue(item.cancelRequested, "$.cancelRequested") !== true
  )
    fail("$", "cancel response mismatch");
}
export function assertUiResponseAccepted(
  value: unknown,
  taskId: string,
  runId: string,
  requestId: string,
) {
  const item = object(value, "$", ["taskId", "runId", "requestId", "answered"]);
  if (
    positiveWireId(item.taskId, "$.taskId") !== taskId ||
    positiveWireId(item.runId, "$.runId") !== runId ||
    positiveWireId(item.requestId, "$.requestId") !== requestId ||
    booleanValue(item.answered, "$.answered") !== true
  )
    fail("$", "UI response identity mismatch");
}
export function assertTaskFlag(
  value: unknown,
  taskId: string,
  flag: "renamed" | "deleting",
) {
  const item = object(value, "$", ["taskId", flag]);
  if (
    positiveWireId(item.taskId, "$.taskId") !== taskId ||
    booleanValue(item[flag], `$.${flag}`) !== true
  )
    fail("$", `${flag} response mismatch`);
}
export function assertTaskArchived(
  value: unknown,
  taskId: string,
  archived: boolean,
) {
  const item = object(value, "$", ["taskId", "archived"]);
  if (
    positiveWireId(item.taskId, "$.taskId") !== taskId ||
    booleanValue(item.archived, "$.archived") !== archived
  )
    fail("$", "archive response mismatch");
}
export function decodeAttachmentChooseResult(
  value: unknown,
): AttachmentChooseResult {
  const root = value as JsonObject;
  const status = enumValue(root?.status, "$.status", [
    "cancelled",
    "ready",
    "rejected",
  ] as const);
  if (status === "cancelled") {
    object(value, "$", ["status"]);
    return { status };
  }
  if (status === "rejected") {
    const item = object(value, "$", ["status", "reason"]);
    return {
      status,
      reason: enumValue(item.reason, "$.reason", [
        "unsupported_type",
        "file_too_large",
        "text_file_too_large",
        "too_many_files",
        "staging_capacity",
        "read_failed",
        "file_changed",
        "shutting_down",
      ] as const),
    };
  }
  const item = object(value, "$", ["status", "attachments"]);
  const attachments = arrayValue(
    item.attachments,
    "$.attachments",
    (attachmentValue, path) => {
      const candidate = attachmentValue as JsonObject;
      const kind = enumValue(candidate?.kind, `${path}.kind`, [
        "file",
        "image",
      ] as const);
      const keys =
        kind === "image"
          ? ["token", "kind", "format", "displayName", "sizeBytes"]
          : ["token", "kind", "displayName", "sizeBytes"];
      const attachment = object(attachmentValue, path, keys);
      const token = stringValue(attachment.token, `${path}.token`);
      if (!/^[0-9a-f]{48}$/.test(token))
        fail(`${path}.token`, "invalid attachment token");
      const common = {
        token,
        displayName: nonEmptyString(
          attachment.displayName,
          `${path}.displayName`,
        ),
        sizeBytes: positiveWireId(attachment.sizeBytes, `${path}.sizeBytes`),
      };
      return kind === "image"
        ? {
            ...common,
            kind,
            format: enumValue(attachment.format, `${path}.format`, [
              "png",
              "jpeg",
              "webp",
            ] as const),
          }
        : { ...common, kind };
    },
  );
  if (attachments.length === 0)
    fail("$.attachments", "ready attachment result must not be empty");
  if (attachments.length > 8)
    fail("$.attachments", "ready attachment result exceeds the file limit");
  if (
    new Set(attachments.map((attachment) => attachment.token)).size !==
    attachments.length
  )
    fail("$.attachments", "attachment tokens must be unique");
  return { status, attachments };
}
export function decodeAttachmentReleaseResult(value: unknown) {
  const item = object(value, "$", ["released"]);
  return { released: booleanValue(item.released, "$.released") };
}
export function decodeAutomaticWorkspaceRootMutationResult(
  value: unknown,
): AutomaticWorkspaceRootMutationResult {
  const item = object(value, "$", ["outcome"]);
  return {
    outcome: enumValue(item.outcome, "$.outcome", [
      "applied",
      "cancelled",
    ] as const),
  };
}
export function decodeAttachmentReceiveResult(
  value: unknown,
): AttachmentReceiveResult {
  const root = value as JsonObject;
  if (
    root?.status === "rejected" &&
    (root.reason === "invalid_transfer" || root.reason === "stale_transfer")
  ) {
    object(value, "$", ["status", "reason"]);
    return { status: "rejected" as const, reason: root.reason };
  }
  const result = decodeAttachmentChooseResult(value);
  if (result.status === "cancelled")
    fail("$.status", "expected ready or rejected");
  return result;
}
export function decodeAttachmentReceiveAcceptance(value: unknown) {
  if ((value as JsonObject)?.status === "accepted") {
    object(value, "$", ["status"]);
    return { status: "accepted" as const };
  }
  const result = decodeAttachmentReceiveResult(value);
  if (result.status !== "rejected")
    fail("$.status", "expected accepted or rejected");
  return result;
}
export function decodeAttachmentAddResult(value: unknown): AttachmentAddResult {
  const root = value as JsonObject;
  if (
    root?.status === "rejected" &&
    [
      "invalid_transfer",
      "stale_transfer",
      "input_busy",
      "cleanup_failed",
    ].includes(root.reason as string)
  ) {
    const item = object(value, "$", ["status", "reason"]);
    return {
      status: "rejected",
      reason: enumValue(item.reason, "$.reason", [
        "invalid_transfer",
        "stale_transfer",
        "input_busy",
        "cleanup_failed",
      ] as const),
    };
  }
  return decodeAttachmentChooseResult(value);
}
export function decodeAttachmentAddBegin(
  value: unknown,
): AttachmentAddBeginResult {
  if ((value as JsonObject)?.status === "accepted") {
    object(value, "$", ["status"]);
    return { status: "accepted" };
  }
  return decodeAttachmentAddResult(value);
}
export function decodeAttachmentAddAcceptance(
  value: unknown,
): AttachmentAddAcceptance {
  const result = decodeAttachmentAddBegin(value);
  if (result.status === "ready")
    fail("$.status", "expected accepted, cancelled or rejected");
  return result;
}
export function decodeAttachmentCancelResult(
  value: unknown,
): AttachmentCancelResult {
  const status = enumValue((value as JsonObject)?.status, "$.status", [
    "cleaned",
    "cleanup_failed",
  ] as const);
  if (status === "cleanup_failed") {
    object(value, "$", ["status"]);
    return { status };
  }
  const item = object(value, "$", ["status", "released"]);
  return { status, released: booleanValue(item.released, "$.released") };
}
function inputSequence(value: unknown, path: string): number {
  const result = positiveNumber(value, path);
  if (result > 64) fail(path, "input sequence exceeds the Run limit");
  return result;
}
function decodeAdditionalInputs(
  value: unknown,
  path: string,
): AdditionalInputView[] {
  let previousId = 0n;
  let previousSequence = 0;
  const records = arrayValue(value, path, (raw, p) => {
    const item = object(raw, p, [
      "id",
      "submission",
      "afterOutputCount",
      "transferredToRunId",
      "continuationReason",
      "operationId",
      "text",
      "redacted",
      "sequence",
      "adoptedTurn",
      "order",
      "state",
    ]);
    const id = positiveU64WireId(item.id, `${p}.id`);
    if (BigInt(id) <= previousId) fail(p, "input identities must increase");
    previousId = BigInt(id);
    const sequence =
      item.sequence === null
        ? null
        : inputSequence(item.sequence, `${p}.sequence`);
    if (sequence !== null) {
      if (sequence <= previousSequence)
        fail(p, "input sequences must increase");
      previousSequence = sequence;
    }
    const state = enumValue(item.state, `${p}.state`, [
      "pending",
      "adopted",
      "unadopted",
      "unknown",
      "continuing",
      "transferred",
    ] as const);
    const adoptedTurn =
      item.adoptedTurn === null
        ? null
        : positiveNumber(item.adoptedTurn, `${p}.adoptedTurn`);
    const order =
      item.order === null ? null : positiveU64WireId(item.order, `${p}.order`);
    if (
      (state === "adopted" ||
        state === "unadopted" ||
        state === "continuing" ||
        state === "transferred") &&
      sequence === null
    )
      fail(p, "a confirmed input requires its receipt");
    const transferredToRunId =
      item.transferredToRunId === null
        ? null
        : positiveU64WireId(item.transferredToRunId, `${p}.transferredToRunId`);
    if ((state === "transferred") !== (transferredToRunId !== null))
      fail(p, "a transferred input requires its target Run");
    const continuationReason =
      item.continuationReason === null
        ? null
        : enumValue(
            item.continuationReason,
            `${p}.continuationReason`,
            sendInputReasons,
          );
    if (continuationReason !== null && state !== "unadopted")
      fail(p, "only an unadopted input can have a continuation failure");
    if (
      (adoptedTurn === null) !== (order === null) ||
      (adoptedTurn !== null &&
        (state !== "adopted" || adoptedTurn > 4294967295))
    )
      fail(p, "invalid adoption anchor");
    const afterOutputCount = nonNegativeNumber(
      item.afterOutputCount,
      `${p}.afterOutputCount`,
    );
    if (afterOutputCount > maxCommentarySegmentsPerRun + 1)
      fail(`${p}.afterOutputCount`, "input anchor exceeds the output capacity");
    return {
      submission:
        item.submission === null
          ? null
          : decodeInputSubmission(item.submission, `${p}.submission`),
      id,
      afterOutputCount,
      operationId: inputOperationId(item.operationId, `${p}.operationId`),
      text: stringValue(item.text, `${p}.text`),
      redacted: booleanValue(item.redacted, `${p}.redacted`),
      sequence,
      state,
      adoptedTurn,
      order,
      transferredToRunId,
      continuationReason,
    };
  });
  if (records.length > 64) fail(path, "too many additional inputs");
  return records;
}
function decodeInputSubmission(value: unknown, path: string): InputSubmission {
  const item = object(value, path, [
    "operationId",
    "receivedAtUnixMs",
    "anchorRunId",
    "afterOutputCount",
    "presentationOrder",
  ]);
  const afterOutputCount = nonNegativeNumber(
    item.afterOutputCount,
    `${path}.afterOutputCount`,
  );
  if (afterOutputCount > 257) fail(path, "input anchor exceeds output limit");
  const receivedAtUnixMs =
    item.receivedAtUnixMs === null
      ? null
      : positiveU64WireId(item.receivedAtUnixMs, `${path}.receivedAtUnixMs`);
  if (receivedAtUnixMs !== null && BigInt(receivedAtUnixMs) > 8640000000000000n)
    fail(path, "expected displayable reception timestamp");
  return {
    presentationOrder:
      item.presentationOrder === null
        ? null
        : positiveU64WireId(
            item.presentationOrder,
            `${path}.presentationOrder`,
          ),
    operationId: inputOperationId(item.operationId, `${path}.operationId`),
    receivedAtUnixMs,
    anchorRunId:
      item.anchorRunId === null
        ? null
        : positiveU64WireId(item.anchorRunId, `${path}.anchorRunId`),
    afterOutputCount,
  };
}
export function decodeSendInputResult(
  value: unknown,
  expectedTaskId: string,
  expectedOperationId?: string,
  path = "$",
): SendInputResult {
  const item = object(value, path, [
    "taskId",
    "operationId",
    "outcome",
    "reason",
  ]);
  const taskId = positiveU64WireId(item.taskId, `${path}.taskId`);
  const operationId = inputOperationId(item.operationId, `${path}.operationId`);
  if (
    taskId !== expectedTaskId ||
    (expectedOperationId !== undefined && operationId !== expectedOperationId)
  )
    fail(path, "input result identity mismatch");
  const outcome = enumValue(item.outcome, `${path}.outcome`, [
    "accepted",
    "rejected",
  ] as const);
  if (outcome === "rejected")
    return {
      taskId,
      operationId,
      outcome,
      reason: enumValue(item.reason, `${path}.reason`, sendInputReasons),
    };
  if (item.reason !== null)
    fail(path, "accepted input cannot have a refusal reason");
  return { taskId, operationId, outcome, reason: null };
}
