import {
  compactCauses,
  builtinProviderIds,
  permissionProfiles,
  runCauses,
  type AccountCommandResult,
  type BuiltinProviderId,
  type ExecutionCommandResult,
  type AccountView,
  type ModelsView,
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
  type PermissionProfileMutationResult,
  type CatalogRefreshResult,
  type CompactView,
  type RunInputView,
  type RunActivity,
  type RunView,
  type AttachmentChooseResult,
  type ScheduledTaskView,
  type PersistenceRecoveryOutcome,
  type SkillCatalogView,
  type SkillManagementView,
  type SkillEnablementResult,
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
  type FilePreview,
  type FileChangeDiffResult,
  type UiRecord,
  type WorkbenchSnapshot,
  type WorkspaceChoice,
  type WorkspaceView,
} from "./contracts.ts";

type JsonObject = Record<string, unknown>;

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
const compactPhases = [
  "queued",
  "compacting",
  "stopping",
  "compacted",
  "no_change",
  "degraded",
  "aborted",
  "failed",
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
  "no_api_keys",
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
  "catalog_unavailable",
  "stale_catalog",
  "skill_not_found",
  "skill_unavailable",
  "invalid_skill_arguments",
  "capacity_reached",
  "shutting_down",
] as const;
const taskModelSelectionReasons = [
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

function fail(path: string, message: string): never {
  throw new Error(`Invalid Host contract at ${path}: ${message}`);
}

function record(value: unknown, path: string): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail(path, "expected object");
  return value as JsonObject;
}

function exactKeys(result: JsonObject, path: string, keys: readonly string[]) {
  const actual = Object.keys(result).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  )
    fail(path, `expected keys ${expected.join(", ")}`);
}

function object(value: unknown, path: string, keys: readonly string[]) {
  const result = record(value, path);
  exactKeys(result, path, keys);
  return result;
}

function stringValue(value: unknown, path: string) {
  if (typeof value !== "string") fail(path, "expected string");
  return value;
}

function nonEmptyString(value: unknown, path: string) {
  const result = stringValue(value, path);
  if (result.length === 0) fail(path, "expected non-empty string");
  return result;
}

function wireId(value: unknown, path: string) {
  const result = stringValue(value, path);
  if (!/^(0|[1-9][0-9]*)$/.test(result)) fail(path, "expected wire integer");
  return result;
}

function positiveWireId(value: unknown, path: string) {
  const result = wireId(value, path);
  if (result === "0") fail(path, "expected positive wire integer");
  return result;
}

function booleanValue(value: unknown, path: string) {
  if (typeof value !== "boolean") fail(path, "expected boolean");
  return value;
}

function numberValue(value: unknown, path: string) {
  if (typeof value !== "number" || !Number.isSafeInteger(value))
    fail(path, "expected safe integer");
  return value;
}

function positiveNumber(value: unknown, path: string) {
  const result = numberValue(value, path);
  if (result <= 0) fail(path, "expected positive safe integer");
  return result;
}

function nonNegativeNumber(value: unknown, path: string) {
  const result = numberValue(value, path);
  if (result < 0) fail(path, "expected non-negative safe integer");
  return result;
}

function nonNegativeFiniteNumber(value: unknown, path: string) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
    fail(path, "expected non-negative finite number");
  return value;
}

function arrayValue<T>(
  value: unknown,
  path: string,
  decode: (item: unknown, path: string) => T,
) {
  if (!Array.isArray(value)) fail(path, "expected array");
  return value.map((item, index) => decode(item, `${path}[${index}]`));
}

function nullableObject<T>(
  value: unknown,
  path: string,
  decode: (item: unknown, path: string) => T,
): T | null {
  return value === null ? null : decode(value, path);
}

function enumValue<const T extends readonly string[]>(
  value: unknown,
  path: string,
  values: T,
): T[number] {
  const result = stringValue(value, path);
  if (!(values as readonly string[]).includes(result))
    fail(path, `unexpected value ${result}`);
  return result as T[number];
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
        const attachment = object(attachmentValue, attachmentPath, [
          "kind",
          "format",
          "displayName",
          "sizeBytes",
          "redacted",
        ]);
        const attachmentKind = enumValue(
          attachment.kind,
          `${attachmentPath}.kind`,
          ["image"] as const,
        );
        const format = enumValue(
          attachment.format,
          `${attachmentPath}.format`,
          ["png", "jpeg", "webp"] as const,
        );
        return {
          kind: attachmentKind,
          format,
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
        "workspaceEpoch",
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
              workspaceEpoch: positiveWireId(
                scopeValue.workspaceEpoch,
                `${itemPath}.scope.workspaceEpoch`,
              ),
            }
          : {
              kind: scopeKind,
              workspaceId: null,
              workspaceEpoch: null,
            };
      if (
        scopeKind !== "project" &&
        (scopeValue.workspaceId !== null || scopeValue.workspaceEpoch !== null)
      )
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
        scope,
        managementState: enumValue(
          asset.managementState,
          `${itemPath}.managementState`,
          ["ready", "pending_verification", "externally_managed"] as const,
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
    assets,
  } as SkillManagementView;
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
    "errorCode",
    "safeDiagnostic",
  ]);
  const state = enumValue(item.state, `${path}.state`, accountStates);
  const canCancel = booleanValue(item.canCancel, `${path}.canCancel`);
  const accountId = stringValue(item.accountId, `${path}.accountId`);
  const displayName = stringValue(item.displayName, `${path}.displayName`);
  const errorCode = enumValue(
    item.errorCode,
    `${path}.errorCode`,
    accountErrorCodes,
  );
  const safeDiagnostic = stringValue(
    item.safeDiagnostic,
    `${path}.safeDiagnostic`,
  );
  if (
    state !== "authenticated" &&
    (accountId.length !== 0 || displayName.length !== 0)
  )
    fail(path, "a non-authenticated Account must hide identity");
  if (
    state === "authenticated" &&
    (accountId.length === 0 || displayName.length === 0)
  )
    fail(path, "an authenticated Account requires identity");
  if (canCancel && state !== "authorizing")
    fail(path, "cancellation requires active authorization");
  if (errorCode === "none" && safeDiagnostic.length !== 0)
    fail(path, "safe diagnostic requires an Account error");
  return {
    state,
    canCancel,
    accountId,
    displayName,
    errorCode,
    safeDiagnostic,
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
        "apiKeys",
        "models",
        "selectedApiKeyId",
        "catalogGeneration",
        "sourceGeneration",
        "errorCode",
        "safeDiagnostic",
      ]);
      const apiKeys = arrayValue(
        provider.apiKeys,
        `${itemPath}.apiKeys`,
        (value, keyPath) => {
          const key = object(value, keyPath, [
            "id",
            "name",
            "suffix",
            "protocol",
          ]);
          return {
            id: stringValue(key.id, `${keyPath}.id`),
            name: stringValue(key.name, `${keyPath}.name`),
            suffix: stringValue(key.suffix, `${keyPath}.suffix`),
            protocol: enumValue(key.protocol, `${keyPath}.protocol`, protocols),
          };
        },
      );
      const models = arrayValue(
        provider.models,
        `${itemPath}.models`,
        (value, modelPath) => {
          const model = object(value, modelPath, [
            "id",
            "displayName",
            "metadata",
            "metadataProvenance",
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
          };
        },
      );
      if (new Set(apiKeys.map((key) => key.id)).size !== apiKeys.length)
        fail(`${itemPath}.apiKeys`, "API Key identities must be unique");
      if (new Set(models.map((model) => model.id)).size !== models.length)
        fail(`${itemPath}.models`, "model identities must be unique");
      const selectedApiKeyId = stringValue(
        provider.selectedApiKeyId,
        `${itemPath}.selectedApiKeyId`,
      );
      if (
        selectedApiKeyId.length > 0 &&
        !apiKeys.some((key) => key.id === selectedApiKeyId)
      )
        fail(itemPath, "the selected API Key must belong to its provider");
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
        apiKeys,
        models,
        selectedApiKeyId,
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
  for (const [name, selection] of [
    ["metaskSelection", metaskSelection],
    ["defaultSelection", defaultSelection],
  ] as const) {
    if (selection && selection.sourceId.startsWith("metask:")) {
      const provider = providers.find((candidate) => candidate.id === "metask");
      if (
        provider?.catalogState === "ready" &&
        !provider.models.some((model) => model.id === selection.modelId)
      )
        fail(
          `${path}.${name}`,
          "the selected Metask model must belong to its ready catalog",
        );
    }
  }
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

function decodeFileReference(value: unknown, path: string): FileReferenceView {
  const item = object(value, path, ["id", "title", "displayPath"]);
  return {
    id: stringValue(item.id, `${path}.id`),
    title: stringValue(item.title, `${path}.title`),
    displayPath: stringValue(item.displayPath, `${path}.displayPath`),
  };
}

export function decodeFilePreview(value: unknown): FilePreview {
  const item = object(value, "$", [
    "state",
    "content",
    "truncated",
    "redacted",
  ]);
  const state = enumValue(item.state, "$.state", [
    "ready",
    "missing",
    "restricted",
    "unsupported",
    "changing",
    "error",
  ] as const);
  const content = stringValue(item.content, "$.content");
  const truncated = booleanValue(item.truncated, "$.truncated");
  const redacted = booleanValue(item.redacted, "$.redacted");
  if (state !== "ready" && (content !== "" || truncated || redacted))
    fail("$", "non-ready preview must not publish content or success facts");
  return {
    state,
    content,
    truncated,
    redacted,
  };
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
  return {
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

function decodeRun(value: unknown, path: string): RunView {
  const item = object(value, path, [
    "id",
    "phase",
    "permissionProfile",
    "permissionInteraction",
    "input",
    "output",
    "activity",
    "outcome",
    "cause",
    "usage",
    "tools",
    "fileChanges",
  ]);
  const usage = object(item.usage, `${path}.usage`, [
    "input",
    "output",
    "cacheRead",
    "cacheCreation",
  ]);
  const phase = enumValue(item.phase, `${path}.phase`, runPhases);
  const outcome = nullableEnum(item.outcome, `${path}.outcome`, runOutcomes);
  validateRunTerminalState(phase, outcome, path);
  const outputItem = object(item.output, `${path}.output`, [
    "commentary",
    "response",
    "responseKind",
    "provisional",
    "redacted",
    "provisionalRedacted",
  ]);
  const commentary = arrayValue(
    outputItem.commentary,
    `${path}.output.commentary`,
    stringValue,
  );
  if (commentary.length > maxCommentarySegmentsPerRun)
    fail(`${path}.output.commentary`, "too many commentary segments");
  const output = {
    commentary,
    response: stringValue(outputItem.response, `${path}.output.response`),
    responseKind: nullableEnum(
      outputItem.responseKind,
      `${path}.output.responseKind`,
      ["final", "partial"] as const,
    ),
    provisional: stringValue(
      outputItem.provisional,
      `${path}.output.provisional`,
    ),
    redacted: booleanValue(outputItem.redacted, `${path}.output.redacted`),
    provisionalRedacted: booleanValue(
      outputItem.provisionalRedacted,
      `${path}.output.provisionalRedacted`,
    ),
  };
  const activity = decodeRunActivity(item.activity, `${path}.activity`);
  const terminal = !nonTerminalRunPhases.includes(phase as never);
  if (terminal !== (activity === null))
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
  if (terminal && output.provisional !== "")
    fail(path, "terminal Run cannot retain provisional output");
  return {
    id: positiveWireId(item.id, `${path}.id`),
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
    input: decodeRunInput(item.input, `${path}.input`),
    output,
    activity,
    outcome,
    cause: nullableEnum(item.cause, `${path}.cause`, runCauses),
    usage: {
      input: wireId(usage.input, `${path}.usage.input`),
      output: wireId(usage.output, `${path}.usage.output`),
      cacheRead: wireId(usage.cacheRead, `${path}.usage.cacheRead`),
      cacheCreation: wireId(usage.cacheCreation, `${path}.usage.cacheCreation`),
    },
    tools: arrayValue(item.tools, `${path}.tools`, decodeTool),
    fileChanges: decodeRunFileChanges(item.fileChanges, `${path}.fileChanges`),
  };
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
  return fail(`${path}.kind`, `unexpected Run activity ${kind}`);
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
  outcome: RunView["outcome"],
  path: string,
) {
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
  return {
    requestId: positiveWireId(item.requestId, `${path}.requestId`),
    runId: positiveWireId(item.runId, `${path}.runId`),
    order: positiveWireId(item.order, `${path}.order`),
    kind,
    state: enumValue(item.state, `${path}.state`, uiRecordStates),
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
      "tool",
      "args",
      "availableChoices",
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
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      order: positiveWireId(item.order, `${path}.order`),
      redacted: booleanValue(item.redacted, `${path}.redacted`),
      kind,
      tool: stringValue(item.tool, `${path}.tool`),
      args: stringValue(item.args, `${path}.args`),
      availableChoices,
    };
  }
  return fail(`${path}.kind`, `unexpected request kind ${kind}`);
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

function decodeTask(value: unknown, path: string): TaskView {
  const item = object(value, path, [
    "id",
    "recentOrder",
    "title",
    "workspaceId",
    "permissionProfile",
    "binding",
    "mcpAuthority",
    "skillCatalog",
    "lifecycle",
    "deletionStatus",
    "continuationAvailable",
    "continuationUnavailableReason",
    "continuationRecoveryAvailable",
    "archived",
    "restorePermission",
    "activeOperation",
    "currentRunId",
    "currentRunPhase",
    "lastRunOutcome",
    "cause",
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
  const mcpAuthority = decodeTaskMcpAuthority(
    item.mcpAuthority,
    `${path}.mcpAuthority`,
  );
  const runs = arrayValue(item.runs, `${path}.runs`, decodeRun);
  const permissionProfile = enumValue(
    item.permissionProfile,
    `${path}.permissionProfile`,
    permissionProfiles,
  );
  if (runs.some((run) => run.permissionProfile !== permissionProfile))
    fail(
      path,
      "Run permission provenance must match its immutable Task profile",
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
    ] as const,
  );
  if (continuationAvailable !== (continuationUnavailableReason === null))
    fail(path, "continuation availability and unavailable reason must agree");
  const archived = booleanValue(item.archived, `${path}.archived`);
  if (!archived && deletionStatus !== "idle")
    fail(path, "only an archived Task can have deletion state");
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
    const current = runs.find((run) => run.id === currentRunId);
    if (!current || current.phase !== currentRunPhase)
      fail(path, "current Run must reference a matching projected Run");
    if (archived) fail(path, "an archived Task cannot have a current Run");
  }
  const activeRuns = runs.filter((run) =>
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
  const runIds = new Set(runs.map((run) => run.id));
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
    const afterRun = runs.find((run) => run.id === compact.afterRunId);
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
    runs.map((run) => [run.id, new Set(run.tools.map((tool) => tool.order))]),
  );
  for (const run of runs) {
    if (new Set(run.tools.map((tool) => tool.id)).size !== run.tools.length)
      fail(path, "tool product identities must be unique within a Run");
    if (activityOrders.get(run.id)!.size !== run.tools.length)
      fail(path, "tool activity order must be unique within a Run");
  }
  for (const record of uiHistory) {
    if (!runIds.has(record.runId))
      fail(path, "UI history must reference a projected Run");
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
    id: positiveWireId(item.id, `${path}.id`),
    recentOrder: positiveWireId(item.recentOrder, `${path}.recentOrder`),
    title: stringValue(item.title, `${path}.title`),
    workspaceId: positiveWireId(item.workspaceId, `${path}.workspaceId`),
    permissionProfile,
    binding,
    mcpAuthority,
    skillCatalog: decodeSkillCatalog(item.skillCatalog, `${path}.skillCatalog`),
    lifecycle,
    deletionStatus,
    continuationAvailable,
    continuationUnavailableReason,
    continuationRecoveryAvailable,
    archived,
    restorePermission,
    activeOperation,
    currentRunId,
    currentRunPhase,
    lastRunOutcome: nullableEnum(
      item.lastRunOutcome,
      `${path}.lastRunOutcome`,
      runOutcomes,
    ),
    cause: nullableEnum(item.cause, `${path}.cause`, runCauses),
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
      lastRemovalFailure !== null ||
      skillCatalog.availability !== "uninitialized")
  )
    fail(path, "automatic Workspace must remain Task-owned and catalog-free");
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

export function decodeWorkbenchSnapshot(value: unknown): WorkbenchSnapshot {
  const root = object(value, "$", [
    "revision",
    "capabilities",
    "permissions",
    "account",
    "models",
    "newTaskAdmission",
    "skillCatalog",
    "skillManagement",
    "mcp",
    "workspaces",
    "scheduledTasks",
    "tasks",
  ]);
  const capabilityItem = object(root.capabilities, "$.capabilities", [
    "taskHistoryPersistence",
    "taskHistoryPersistenceHealth",
    "taskHistoryRecoveryAvailable",
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
    "mcpOAuth",
    "attachments",
  ]);
  const attachmentCapability = object(
    capabilityItem.attachments,
    "$.capabilities.attachments",
    ["enabled", "imageFormats", "maxFiles", "maxImageBytes", "maxStagedBytes"],
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
      maxImageBytes: positiveWireId(
        attachmentCapability.maxImageBytes,
        "$.capabilities.attachments.maxImageBytes",
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
    availableProfiles,
    defaultProfile: enumValue(
      permissionItem.defaultProfile,
      "$.permissions.defaultProfile",
      permissionProfiles,
    ),
  };
  const workspaces = arrayValue(
    root.workspaces,
    "$.workspaces",
    decodeWorkspace,
  );
  const tasks = arrayValue(root.tasks, "$.tasks", decodeTask);
  const scheduledTasks = arrayValue(
    root.scheduledTasks,
    "$.scheduledTasks",
    decodeScheduledTask,
  );
  const mcp = decodeMcpManagement(root.mcp, "$.mcp");
  if (!capabilities.mcpManagement) {
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
  } else if (mcp.managementHealth === "unavailable") {
    fail("$.mcp.managementHealth", "enabled MCP management requires its owner");
  }
  if (
    new Set(workspaces.map((workspace) => workspace.id)).size !==
    workspaces.length
  )
    fail("$.workspaces", "Workspace identities must be unique");
  const workspaceIds = new Set(workspaces.map((workspace) => workspace.id));
  if (new Set(tasks.map((task) => task.id)).size !== tasks.length)
    fail("$.tasks", "Task identities must be unique");
  if (
    new Set(scheduledTasks.map((task) => task.id)).size !==
    scheduledTasks.length
  )
    fail("$.scheduledTasks", "scheduled Task identities must be unique");
  const tasksById = new Map(tasks.map((task) => [task.id, task]));
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
    const taskCount = tasks.filter(
      (task) => task.workspaceId === workspace.id,
    ).length;
    if (workspace.kind === "automatic" && taskCount !== 1)
      fail(
        "$.workspaces",
        "automatic Workspace must belong to exactly one Task",
      );
  }
  return {
    revision: wireId(root.revision, "$.revision"),
    capabilities,
    permissions,
    account: decodeAccount(root.account, "$.account"),
    models: decodeModels(root.models, "$.models"),
    newTaskAdmission: decodeNewTaskAdmission(
      root.newTaskAdmission,
      "$.newTaskAdmission",
    ),
    skillCatalog: decodeSkillCatalog(root.skillCatalog, "$.skillCatalog"),
    skillManagement: decodeSkillManagement(
      root.skillManagement,
      "$.skillManagement",
    ),
    mcp,
    workspaces,
    scheduledTasks,
    tasks,
  };
}

export function decodePermissionProfileMutationResult(
  value: unknown,
): PermissionProfileMutationResult {
  const item = object(value, "$", ["changed", "defaultProfile"]);
  return {
    changed: booleanValue(item.changed, "$.changed"),
    defaultProfile: enumValue(
      item.defaultProfile,
      "$.defaultProfile",
      permissionProfiles,
    ),
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
  const item = object(value, "$", [
    "accepted",
    "contractId",
    "contractRevision",
    "generation",
    "error",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const contractId = stringValue(item.contractId, "$.contractId");
  const contractRevision = positiveNumber(
    item.contractRevision,
    "$.contractRevision",
  );
  if (accepted) {
    if (item.error !== null) fail("$.error", "expected null");
    return {
      accepted: true as const,
      contractId,
      contractRevision,
      generation: positiveWireId(item.generation, "$.generation"),
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
  const item = object(value, "$", ["revision"]);
  return wireId(item.revision, "$.revision");
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

export type WindowChromeEnvironment = {
  generation: string;
  insets: { top: number; left: number; bottom: number; right: number };
  buttons: { x: number; y: number; width: number; height: number };
  livePointerDrag: boolean;
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
    "livePointerDrag",
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
    livePointerDrag: booleanValue(item.livePointerDrag, "$.livePointerDrag"),
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

export function decodeTaskModelSelectionResult(
  value: unknown,
  expectedTaskId: string,
): TaskModelSelectionResult {
  const item = object(value, "$", ["accepted", "taskId", "model", "reason"]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const taskId = positiveWireId(item.taskId, "$.taskId");
  if (taskId !== expectedTaskId) fail("$.taskId", "response identity mismatch");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId,
      model: stringValue(item.model, "$.model"),
      reason: null,
    };
  }
  if (item.model !== null) fail("$.model", "expected null");
  return {
    accepted: false,
    taskId,
    model: null,
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
      const attachment = object(attachmentValue, path, [
        "token",
        "kind",
        "format",
        "displayName",
        "sizeBytes",
      ]);
      const kind = enumValue(attachment.kind, `${path}.kind`, [
        "image",
      ] as const);
      const format = enumValue(attachment.format, `${path}.format`, [
        "png",
        "jpeg",
        "webp",
      ] as const);
      const token = stringValue(attachment.token, `${path}.token`);
      if (!/^[0-9a-f]{48}$/.test(token))
        fail(`${path}.token`, "invalid attachment token");
      return {
        token,
        kind,
        format,
        displayName: nonEmptyString(
          attachment.displayName,
          `${path}.displayName`,
        ),
        sizeBytes: positiveWireId(attachment.sizeBytes, `${path}.sizeBytes`),
      };
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
