import {
  type AccountCommandResult,
  type AccountView,
  type AskOption,
  type AskQuestion,
  type HostSignal,
  type PendingUi,
  type CatalogRefreshResult,
  type RunInputView,
  type RunView,
  type ScheduledTaskView,
  type SkillCatalogView,
  type SkillCatalogRefreshResult,
  type TaskView,
  type TaskCreateResult,
  type TaskRunResult,
  type ToolView,
  type UiRecord,
  type WorkbenchSnapshot,
  type WorkspaceChoice,
  type WorkspaceMutationResult,
  type WorkspaceView,
} from "./contracts.ts";

type JsonObject = Record<string, unknown>;

const taskLifecycles = ["open", "closing", "closed"] as const;
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
const runOutcomes = [
  "completed",
  "stopped",
  "cancelled",
  "interrupted",
  "failed",
  "dependency_contract_failure",
] as const;
const hostCauses = [
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
] as const;
const uiRecordKinds = ["ask_question", "permission"] as const;
const uiRecordStates = [
  "answered",
  "allowed_once",
  "allowed_always",
  "denied",
  "denied_session",
  "cancelled",
] as const;
const accountSessionStates = [
  "restoring",
  "signed_out",
  "authorizing",
  "authenticated",
  "refreshing",
  "reauth_required",
  "shutting_down",
] as const;
const executionStates = [
  "none",
  "preparing",
  "ready",
  "reconfiguring",
  "invalid",
] as const;
const accountOperations = [
  "none",
  "oauth_callback",
  "token_exchange",
  "loading_keys",
  "selecting_key",
  "loading_models",
  "selecting_model",
  "persisting",
  "logging_out",
] as const;
const accountReadiness = [
  "checking",
  "sign_in_required",
  "preparing",
  "choice_required",
  "ready",
  "needs_attention",
  "restart_required",
] as const;
const accountPrimaryActions = [
  "none",
  "sign_in",
  "reopen_login",
  "choose_api_key",
  "choose_model",
  "retry_catalog",
  "reauthenticate",
  "restart",
] as const;
const accountErrorCodes = [
  "none",
  "invalid_command",
  "invalid_state",
  "operation_in_progress",
  "execution_in_use",
  "oauth_bind_failed",
  "oauth_browser_open_failed",
  "oauth_callback_rejected",
  "oauth_state_mismatch",
  "oauth_exchange_failed",
  "user_cancelled",
  "deadline_exceeded",
  "token_refresh_failed",
  "account_mismatch",
  "metask_unauthorized",
  "metask_rate_limited",
  "metask_service_unavailable",
  "metask_protocol_invalid",
  "catalog_too_large",
  "catalog_field_too_large",
  "no_api_keys",
  "no_models",
  "execution_target_invalid",
  "execution_config_invalid",
  "credential_store_read_failed",
  "credential_store_write_failed",
  "credential_store_delete_failed",
  "generation_mismatch",
  "recovery_state_invalid",
  "local_resource_exhausted",
  "dependency_contract_invalid",
  "shutting_down",
] as const;
const rendererBridgeConnectErrors = [
  "identity_mismatch",
  "revision_mismatch",
] as const;
const providers = ["anthropic", "openai"] as const;
const workspaceAuthorizations = [
  "available",
  "removing",
  "reauthorization_required",
] as const;
const workspaceOrigins = ["user", "managed"] as const;
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
  "workspace_changed",
  "workspace_unavailable",
  "catalog_changed",
  "capacity_reached",
  "shutting_down",
  "task_start_failed",
  "timer_unavailable",
  "persistence_failed",
  "host_interrupted",
] as const;
const workspaceMutationReasons = [
  "workspace_changed",
  "workspace_unavailable",
  "workspace_removing",
  "capacity_reached",
  "removal_failed",
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
  "invalid_skill_arguments",
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

function object(value: unknown, path: string, keys: readonly string[]) {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail(path, "expected object");
  const result = value as JsonObject;
  const actual = Object.keys(result).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  )
    fail(path, `expected keys ${expected.join(", ")}`);
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

function arrayValue<T>(
  value: unknown,
  path: string,
  decode: (item: unknown, path: string) => T,
) {
  if (!Array.isArray(value)) fail(path, "expected array");
  return value.map((item, index) => decode(item, `${path}[${index}]`));
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
  ] as const);
  if (kind === "text") {
    const item = object(value, path, ["kind", "text", "redacted"]);
    return {
      kind,
      text: stringValue(item.text, `${path}.text`),
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
    skills,
    issues,
  };
}

function decodeAccount(value: unknown, path: string): AccountView {
  const item = object(value, path, [
    "sessionState",
    "executionState",
    "operation",
    "readiness",
    "primaryAction",
    "canCancel",
    "accountId",
    "profileId",
    "displayName",
    "apiKeys",
    "models",
    "selectedApiKeySelectionId",
    "selectedModelSelectionId",
    "candidateApiKeySelectionId",
    "candidateModelSelectionId",
    "modelCatalogApiKeySelectionId",
    "canCreateTask",
    "errorCode",
    "safeDiagnostic",
    "catalogGeneration",
    "executionGeneration",
  ]);
  const apiKeys = arrayValue(
    item.apiKeys,
    `${path}.apiKeys`,
    (value, itemPath) => {
      const key = object(value, itemPath, [
        "selectionId",
        "name",
        "suffix",
        "provider",
      ]);
      return {
        selectionId: stringValue(key.selectionId, `${itemPath}.selectionId`),
        name: stringValue(key.name, `${itemPath}.name`),
        suffix: stringValue(key.suffix, `${itemPath}.suffix`),
        provider: enumValue(key.provider, `${itemPath}.provider`, providers),
      };
    },
  );
  const models = arrayValue(
    item.models,
    `${path}.models`,
    (value, itemPath) => {
      const model = object(value, itemPath, ["selectionId", "displayName"]);
      return {
        selectionId: stringValue(model.selectionId, `${itemPath}.selectionId`),
        displayName: stringValue(model.displayName, `${itemPath}.displayName`),
      };
    },
  );
  if (new Set(apiKeys.map((key) => key.selectionId)).size !== apiKeys.length)
    fail(`${path}.apiKeys`, "API Key identities must be unique");
  if (new Set(models.map((model) => model.selectionId)).size !== models.length)
    fail(`${path}.models`, "model identities must be unique");
  const sessionState = enumValue(
    item.sessionState,
    `${path}.sessionState`,
    accountSessionStates,
  );
  const executionState = enumValue(
    item.executionState,
    `${path}.executionState`,
    executionStates,
  );
  const operation = enumValue(
    item.operation,
    `${path}.operation`,
    accountOperations,
  );
  const readiness = enumValue(
    item.readiness,
    `${path}.readiness`,
    accountReadiness,
  );
  const primaryAction = enumValue(
    item.primaryAction,
    `${path}.primaryAction`,
    accountPrimaryActions,
  );
  const canCancel = booleanValue(item.canCancel, `${path}.canCancel`);
  const accountId = stringValue(item.accountId, `${path}.accountId`);
  const profileId = stringValue(item.profileId, `${path}.profileId`);
  const displayName = stringValue(item.displayName, `${path}.displayName`);
  const selectedApiKeySelectionId = stringValue(
    item.selectedApiKeySelectionId,
    `${path}.selectedApiKeySelectionId`,
  );
  const selectedModelSelectionId = stringValue(
    item.selectedModelSelectionId,
    `${path}.selectedModelSelectionId`,
  );
  const candidateApiKeySelectionId = stringValue(
    item.candidateApiKeySelectionId,
    `${path}.candidateApiKeySelectionId`,
  );
  const candidateModelSelectionId = stringValue(
    item.candidateModelSelectionId,
    `${path}.candidateModelSelectionId`,
  );
  const modelCatalogApiKeySelectionId = stringValue(
    item.modelCatalogApiKeySelectionId,
    `${path}.modelCatalogApiKeySelectionId`,
  );
  const canCreateTask = booleanValue(
    item.canCreateTask,
    `${path}.canCreateTask`,
  );
  const catalogGeneration = wireId(
    item.catalogGeneration,
    `${path}.catalogGeneration`,
  );
  const executionGeneration = wireId(
    item.executionGeneration,
    `${path}.executionGeneration`,
  );
  if (executionState !== "ready" && canCreateTask)
    fail(path, "a non-ready execution cannot admit Tasks");
  if (
    canCancel !==
    (operation !== "none" &&
      operation !== "logging_out" &&
      operation !== "persisting")
  )
    fail(path, "cancellation availability disagrees with the active operation");
  if (
    executionState === "ready" &&
    (accountId.length === 0 ||
      profileId.length === 0 ||
      selectedApiKeySelectionId.length === 0 ||
      selectedModelSelectionId.length === 0 ||
      executionGeneration === "0")
  )
    fail(path, "a ready execution requires selected identities and generation");
  const candidateAllowed = [
    "loading_keys",
    "loading_models",
    "selecting_model",
    "persisting",
  ].includes(operation);
  if (
    !candidateAllowed &&
    (candidateApiKeySelectionId.length > 0 ||
      candidateModelSelectionId.length > 0)
  )
    fail(path, "candidate execution identities require reconfiguration");
  if (
    candidateModelSelectionId.length > 0 &&
    candidateApiKeySelectionId.length === 0
  )
    fail(path, "a candidate model requires its candidate API");
  if (
    ["loading_models", "selecting_model", "persisting"].includes(operation) &&
    candidateApiKeySelectionId.length === 0
  )
    fail(path, "the active model flow requires a candidate API");
  if (operation === "persisting" && candidateModelSelectionId.length === 0)
    fail(path, "persistence requires a complete candidate execution target");
  if (
    candidateApiKeySelectionId.length > 0 &&
    operation !== "loading_keys" &&
    !apiKeys.some((key) => key.selectionId === candidateApiKeySelectionId)
  )
    fail(path, "candidate API must belong to the API catalog");
  if (
    candidateModelSelectionId.length > 0 &&
    operation === "persisting" &&
    !models.some((model) => model.selectionId === candidateModelSelectionId)
  )
    fail(path, "candidate model must belong to the model catalog");
  const catalogReconfiguration = [
    "loading_keys",
    "selecting_key",
    "loading_models",
    "selecting_model",
    "persisting",
  ].includes(operation);
  if (catalogReconfiguration && canCreateTask)
    fail(path, "catalog reconfiguration cannot admit a new Task");
  if (
    executionState === "ready" &&
    !catalogReconfiguration &&
    (!apiKeys.some((key) => key.selectionId === selectedApiKeySelectionId) ||
      !models.some((model) => model.selectionId === selectedModelSelectionId))
  )
    fail(path, "a ready execution requires selected catalog membership");
  if (
    models.length === 0 &&
    modelCatalogApiKeySelectionId.length > 0 &&
    operation !== "loading_models"
  )
    fail(path, "an empty model catalog can only name its owner while loading");
  if (models.length > 0 && modelCatalogApiKeySelectionId.length === 0)
    fail(path, "an available model catalog requires its API owner");
  if (
    modelCatalogApiKeySelectionId.length > 0 &&
    !apiKeys.some((key) => key.selectionId === modelCatalogApiKeySelectionId)
  )
    fail(path, "model catalog owner must belong to the API catalog");
  if (primaryAction === "choose_api_key" && apiKeys.length === 0)
    fail(path, "API Key choice requires at least one candidate");
  if (primaryAction === "choose_model" && models.length === 0)
    fail(path, "model choice requires at least one candidate");
  if (
    sessionState === "signed_out" &&
    (executionState !== "none" ||
      operation !== "none" ||
      accountId.length !== 0 ||
      profileId.length !== 0 ||
      displayName.length !== 0 ||
      apiKeys.length !== 0 ||
      models.length !== 0 ||
      selectedApiKeySelectionId.length !== 0 ||
      selectedModelSelectionId.length !== 0 ||
      candidateApiKeySelectionId.length !== 0 ||
      candidateModelSelectionId.length !== 0 ||
      modelCatalogApiKeySelectionId.length !== 0 ||
      executionGeneration !== "0" ||
      canCreateTask)
  )
    fail(path, "signed-out Account state must be empty and fail closed");
  const actionMatchesReadiness =
    (readiness === "checking" &&
      primaryAction === "none" &&
      sessionState === "restoring") ||
    (readiness === "sign_in_required" &&
      primaryAction === "sign_in" &&
      sessionState === "signed_out") ||
    (readiness === "preparing" &&
      operation !== "none" &&
      operation !== "selecting_key" &&
      operation !== "selecting_model" &&
      (primaryAction === "none" ||
        (primaryAction === "reopen_login" &&
          sessionState === "authorizing" &&
          operation === "oauth_callback"))) ||
    (readiness === "choice_required" &&
      ((primaryAction === "choose_api_key" && operation === "selecting_key") ||
        (primaryAction === "choose_model" &&
          operation === "selecting_model"))) ||
    (readiness === "ready" &&
      primaryAction === "none" &&
      executionState === "ready") ||
    (readiness === "needs_attention" &&
      operation === "none" &&
      ((primaryAction === "retry_catalog" &&
        sessionState === "authenticated") ||
        (primaryAction === "reauthenticate" &&
          sessionState === "reauth_required"))) ||
    (readiness === "restart_required" &&
      primaryAction === "restart" &&
      sessionState === "shutting_down");
  if (!actionMatchesReadiness)
    fail(path, "Account readiness and primary action disagree");
  return {
    sessionState,
    executionState,
    operation,
    readiness,
    primaryAction,
    canCancel,
    accountId,
    profileId,
    displayName,
    apiKeys,
    models,
    selectedApiKeySelectionId,
    selectedModelSelectionId,
    candidateApiKeySelectionId,
    candidateModelSelectionId,
    modelCatalogApiKeySelectionId,
    canCreateTask,
    errorCode: enumValue(
      item.errorCode,
      `${path}.errorCode`,
      accountErrorCodes,
    ),
    safeDiagnostic: stringValue(item.safeDiagnostic, `${path}.safeDiagnostic`),
    catalogGeneration,
    executionGeneration,
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
  };
}

function decodeRun(value: unknown, path: string): RunView {
  const item = object(value, path, [
    "id",
    "phase",
    "input",
    "assistant",
    "assistantRedacted",
    "status",
    "outcome",
    "cause",
    "usage",
    "tools",
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
  return {
    id: positiveWireId(item.id, `${path}.id`),
    phase,
    input: decodeRunInput(item.input, `${path}.input`),
    assistant: stringValue(item.assistant, `${path}.assistant`),
    assistantRedacted: booleanValue(
      item.assistantRedacted,
      `${path}.assistantRedacted`,
    ),
    status: stringValue(item.status, `${path}.status`),
    outcome,
    cause: nullableEnum(item.cause, `${path}.cause`, hostCauses),
    usage: {
      input: wireId(usage.input, `${path}.usage.input`),
      output: wireId(usage.output, `${path}.usage.output`),
      cacheRead: wireId(usage.cacheRead, `${path}.usage.cacheRead`),
      cacheCreation: wireId(usage.cacheCreation, `${path}.usage.cacheCreation`),
    },
    tools: arrayValue(item.tools, `${path}.tools`, decodeTool),
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

function decodeUiRecord(value: unknown, path: string): UiRecord {
  const item = object(value, path, [
    "requestId",
    "runId",
    "order",
    "kind",
    "state",
    "detail",
    "itemCount",
    "detailTruncated",
    "redacted",
  ]);
  return {
    requestId: positiveWireId(item.requestId, `${path}.requestId`),
    runId: positiveWireId(item.runId, `${path}.runId`),
    order: positiveWireId(item.order, `${path}.order`),
    kind: enumValue(item.kind, `${path}.kind`, uiRecordKinds),
    state: enumValue(item.state, `${path}.state`, uiRecordStates),
    detail: stringValue(item.detail, `${path}.detail`),
    itemCount: nonNegativeNumber(item.itemCount, `${path}.itemCount`),
    detailTruncated: booleanValue(
      item.detailTruncated,
      `${path}.detailTruncated`,
    ),
    redacted: booleanValue(item.redacted, `${path}.redacted`),
  };
}

function decodeAskOption(value: unknown, path: string): AskOption {
  const item = object(value, path, ["label", "description", "preview"]);
  return {
    label: stringValue(item.label, `${path}.label`),
    description: stringValue(item.description, `${path}.description`),
    preview: stringValue(item.preview, `${path}.preview`),
  };
}

function decodeAskQuestion(value: unknown, path: string): AskQuestion {
  const item = object(value, path, ["question", "header", "multi", "options"]);
  return {
    question: stringValue(item.question, `${path}.question`),
    header: stringValue(item.header, `${path}.header`),
    multi: booleanValue(item.multi, `${path}.multi`),
    options: arrayValue(item.options, `${path}.options`, decodeAskOption),
  };
}

function decodePendingUi(value: unknown, path: string): PendingUi | null {
  if (value === null) return null;
  if (typeof value !== "object" || Array.isArray(value))
    fail(path, "expected request object or null");
  const kind = stringValue((value as JsonObject).kind, `${path}.kind`);
  if (kind === "ask_question") {
    const item = object(value, path, [
      "requestId",
      "runId",
      "order",
      "redacted",
      "kind",
      "questions",
    ]);
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      order: positiveWireId(item.order, `${path}.order`),
      redacted: booleanValue(item.redacted, `${path}.redacted`),
      kind,
      questions: arrayValue(
        item.questions,
        `${path}.questions`,
        decodeAskQuestion,
      ),
    };
  }
  if (kind === "permission") {
    const item = object(value, path, [
      "requestId",
      "runId",
      "order",
      "redacted",
      "kind",
      "tool",
      "args",
    ]);
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      order: positiveWireId(item.order, `${path}.order`),
      redacted: booleanValue(item.redacted, `${path}.redacted`),
      kind,
      tool: stringValue(item.tool, `${path}.tool`),
      args: stringValue(item.args, `${path}.args`),
    };
  }
  return fail(`${path}.kind`, `unexpected request kind ${kind}`);
}

function decodeTask(value: unknown, path: string): TaskView {
  const item = object(value, path, [
    "id",
    "recentOrder",
    "title",
    "workspaceId",
    "binding",
    "skillCatalog",
    "lifecycle",
    "continuationAvailable",
    "archived",
    "closeFailed",
    "currentRunId",
    "currentRunPhase",
    "lastRunOutcome",
    "cause",
    "runs",
    "pendingUi",
    "uiHistory",
  ]);
  const bindingItem = object(item.binding, `${path}.binding`, [
    "epoch",
    "availability",
    "accountId",
    "profileId",
    "accountDisplayName",
    "apiKeySelectionId",
    "apiKeyName",
    "apiKeySuffix",
    "provider",
    "modelSelectionId",
    "modelDisplayName",
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
    ["credential_released"] as const,
  );
  if ((availability === "available") !== (unavailableReason === null))
    fail(
      `${path}.binding`,
      "availability and unavailable reason must describe the same binding state",
    );
  const binding = {
    epoch: positiveWireId(bindingItem.epoch, `${path}.binding.epoch`),
    availability,
    accountId: stringValue(bindingItem.accountId, `${path}.binding.accountId`),
    profileId: stringValue(bindingItem.profileId, `${path}.binding.profileId`),
    accountDisplayName: stringValue(
      bindingItem.accountDisplayName,
      `${path}.binding.accountDisplayName`,
    ),
    apiKeySelectionId: stringValue(
      bindingItem.apiKeySelectionId,
      `${path}.binding.apiKeySelectionId`,
    ),
    apiKeyName: stringValue(
      bindingItem.apiKeyName,
      `${path}.binding.apiKeyName`,
    ),
    apiKeySuffix: stringValue(
      bindingItem.apiKeySuffix,
      `${path}.binding.apiKeySuffix`,
    ),
    provider: enumValue(
      bindingItem.provider,
      `${path}.binding.provider`,
      providers,
    ),
    modelSelectionId: stringValue(
      bindingItem.modelSelectionId,
      `${path}.binding.modelSelectionId`,
    ),
    modelDisplayName: stringValue(
      bindingItem.modelDisplayName,
      `${path}.binding.modelDisplayName`,
    ),
    executionGeneration: positiveWireId(
      bindingItem.executionGeneration,
      `${path}.binding.executionGeneration`,
    ),
    unavailableReason,
  };
  const runs = arrayValue(item.runs, `${path}.runs`, decodeRun);
  const lifecycle = enumValue(
    item.lifecycle,
    `${path}.lifecycle`,
    taskLifecycles,
  );
  const continuationAvailable = booleanValue(
    item.continuationAvailable,
    `${path}.continuationAvailable`,
  );
  const archived = booleanValue(item.archived, `${path}.archived`);
  const currentRunId = wireId(item.currentRunId, `${path}.currentRunId`);
  const currentRunPhase = nullableEnum(
    item.currentRunPhase,
    `${path}.currentRunPhase`,
    nonTerminalRunPhases,
  );
  if ((currentRunId === "0") !== (currentRunPhase === null))
    fail(path, "current Run identity and phase must both be present or absent");
  if (currentRunPhase !== null) {
    const current = runs.find((run) => run.id === currentRunId);
    if (!current || current.phase !== currentRunPhase)
      fail(path, "current Run must reference a matching projected Run");
    if (archived) fail(path, "an archived Task cannot have a current Run");
    if (lifecycle === "closed")
      fail(path, "a closed Task cannot have a current Run");
  }
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
  return {
    id: positiveWireId(item.id, `${path}.id`),
    recentOrder: positiveWireId(item.recentOrder, `${path}.recentOrder`),
    title: stringValue(item.title, `${path}.title`),
    workspaceId: positiveWireId(item.workspaceId, `${path}.workspaceId`),
    binding,
    skillCatalog: decodeSkillCatalog(item.skillCatalog, `${path}.skillCatalog`),
    lifecycle,
    continuationAvailable,
    archived,
    closeFailed: booleanValue(item.closeFailed, `${path}.closeFailed`),
    currentRunId,
    currentRunPhase,
    lastRunOutcome: nullableEnum(
      item.lastRunOutcome,
      `${path}.lastRunOutcome`,
      runOutcomes,
    ),
    cause: nullableEnum(item.cause, `${path}.cause`, hostCauses),
    runs,
    pendingUi,
    uiHistory,
  };
}

function decodeWorkspace(value: unknown, path: string): WorkspaceView {
  const item = object(value, path, [
    "id",
    "epoch",
    "origin",
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
  const origin = enumValue(item.origin, `${path}.origin`, workspaceOrigins);
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
  if (origin === "user" && recentOrder === "0")
    fail(`${path}.recentOrder`, "user Workspace requires recent order");
  if (
    origin === "managed" &&
    (recentOrder !== "0" ||
      authorization !== "available" ||
      lastRemovalFailure !== null ||
      skillCatalog.availability !== "uninitialized")
  )
    fail(path, "managed Workspace must remain non-selecting and catalog-free");
  return {
    id: positiveWireId(item.id, `${path}.id`),
    epoch: positiveWireId(item.epoch, `${path}.epoch`),
    origin,
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
    "enabled",
    "health",
    "failureReason",
    "target",
    "execution",
    "input",
    "recurrence",
    "nextRunAtUnixSeconds",
    "occurrences",
  ]);
  const execution = object(item.execution, `${path}.execution`, [
    "generation",
    "provider",
    "model",
  ]);
  if (
    typeof item.target !== "object" ||
    item.target === null ||
    Array.isArray(item.target)
  )
    fail(`${path}.target`, "expected object");
  const targetObject = item.target as JsonObject;
  const targetKind = stringValue(targetObject.kind, `${path}.target.kind`);
  const target =
    targetKind === "default"
      ? (() => {
          object(item.target, `${path}.target`, ["kind"]);
          return { kind: "default" as const };
        })()
      : targetKind === "explicit"
        ? (() => {
            const explicit = object(item.target, `${path}.target`, [
              "kind",
              "workspaceId",
              "workspaceEpoch",
            ]);
            return {
              kind: "explicit" as const,
              workspaceId: positiveWireId(
                explicit.workspaceId,
                `${path}.target.workspaceId`,
              ),
              workspaceEpoch: positiveWireId(
                explicit.workspaceEpoch,
                `${path}.target.workspaceEpoch`,
              ),
            };
          })()
        : fail(`${path}.target.kind`, "unexpected scheduled Task target kind");
  if (
    typeof item.input !== "object" ||
    item.input === null ||
    Array.isArray(item.input)
  )
    fail(`${path}.input`, "expected object");
  const inputObject = item.input as JsonObject;
  const inputKind = stringValue(inputObject.kind, `${path}.input.kind`);
  const input =
    inputKind === "text"
      ? (() => {
          const text = object(item.input, `${path}.input`, [
            "kind",
            "text",
            "redacted",
          ]);
          return {
            kind: "text" as const,
            text: stringValue(text.text, `${path}.input.text`),
            redacted: booleanValue(text.redacted, `${path}.input.redacted`),
          };
        })()
      : inputKind === "skill"
        ? (() => {
            const skill = object(item.input, `${path}.input`, [
              "kind",
              "skillId",
              "catalogRevision",
              "argumentValues",
              "redacted",
            ]);
            return {
              kind: "skill" as const,
              skillId: stringValue(skill.skillId, `${path}.input.skillId`),
              catalogRevision: stringValue(
                skill.catalogRevision,
                `${path}.input.catalogRevision`,
              ),
              argumentValues: arrayValue(
                skill.argumentValues,
                `${path}.input.argumentValues`,
                stringValue,
              ),
              redacted: booleanValue(skill.redacted, `${path}.input.redacted`),
            };
          })()
        : fail(`${path}.input.kind`, "unexpected scheduled Task input kind");
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
        ] as const,
      );
      if (result === "submitted" && taskId === null)
        fail(occurrencePath, "submitted occurrence must reference a Task");
      if (result !== "submitted" && taskOutcome !== null)
        fail(
          occurrencePath,
          "only submitted occurrence can expose Task outcome",
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
        reason: nullableEnum(
          last.reason,
          `${occurrencePath}.reason`,
          scheduledTaskFailureReasons,
        ),
        taskOutcome,
      };
    },
  );
  const health = enumValue(item.health, `${path}.health`, scheduledTaskHealth);
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
  if (target.kind === "default" && input.kind !== "text")
    fail(path, "default scheduled Task target requires text input");
  return {
    id: positiveWireId(item.id, `${path}.id`),
    epoch: positiveWireId(item.epoch, `${path}.epoch`),
    title: stringValue(item.title, `${path}.title`),
    titleRedacted: booleanValue(item.titleRedacted, `${path}.titleRedacted`),
    enabled,
    health,
    failureReason: nullableEnum(
      item.failureReason,
      `${path}.failureReason`,
      scheduledTaskFailureReasons,
    ),
    target,
    execution: {
      generation: positiveWireId(
        execution.generation,
        `${path}.execution.generation`,
      ),
      provider: enumValue(
        execution.provider,
        `${path}.execution.provider`,
        providers,
      ),
      model: stringValue(execution.model, `${path}.execution.model`),
    },
    input,
    recurrence,
    nextRunAtUnixSeconds,
    occurrences,
  };
}

export function decodeWorkbenchSnapshot(value: unknown): WorkbenchSnapshot {
  const root = object(value, "$", [
    "revision",
    "capabilities",
    "account",
    "skillCatalog",
    "selectedWorkspaceId",
    "workspaces",
    "scheduledTasks",
    "tasks",
  ]);
  const capabilityItem = object(root.capabilities, "$.capabilities", [
    "taskHistoryPersistence",
    "conversationRecovery",
    "executionRebind",
    "structuredPlan",
    "typedOutputs",
    "typedFileChanges",
    "persistentWorkspacePermissions",
    "managedWorkspaces",
    "scheduledTasks",
    "scheduledTaskPersistence",
    "scheduledTaskPersistenceHealth",
    "backgroundScheduleWake",
  ]);
  const capabilities = {
    taskHistoryPersistence: booleanValue(
      capabilityItem.taskHistoryPersistence,
      "$.capabilities.taskHistoryPersistence",
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
    managedWorkspaces: booleanValue(
      capabilityItem.managedWorkspaces,
      "$.capabilities.managedWorkspaces",
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
    backgroundScheduleWake: booleanValue(
      capabilityItem.backgroundScheduleWake,
      "$.capabilities.backgroundScheduleWake",
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
  const selectedWorkspaceId =
    root.selectedWorkspaceId === null
      ? null
      : positiveWireId(root.selectedWorkspaceId, "$.selectedWorkspaceId");
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
  if (
    scheduledTasks.some((task) => {
      const target = task.target;
      if (target.kind !== "explicit") return false;
      return (
        workspaces.find((workspace) => workspace.id === target.workspaceId)
          ?.origin === "managed"
      );
    })
  )
    fail(
      "$.scheduledTasks",
      "explicit scheduled Task cannot target a managed Workspace",
    );
  const selectedWorkspace = workspaces.find(
    (workspace) => workspace.id === selectedWorkspaceId,
  );
  if (selectedWorkspaceId !== null && selectedWorkspace?.origin !== "user")
    fail(
      "$.selectedWorkspaceId",
      "selected Workspace must be a projected user Workspace",
    );
  for (const workspace of workspaces) {
    const taskCount = tasks.filter(
      (task) => task.workspaceId === workspace.id,
    ).length;
    if (workspace.origin === "managed" && taskCount !== 1)
      fail("$.workspaces", "managed Workspace must belong to exactly one Task");
  }
  if (
    !capabilities.managedWorkspaces &&
    workspaces.some((workspace) => workspace.origin === "managed")
  )
    fail(
      "$.capabilities.managedWorkspaces",
      "managed Workspace capability is unavailable",
    );
  return {
    revision: wireId(root.revision, "$.revision"),
    capabilities,
    account: decodeAccount(root.account, "$.account"),
    skillCatalog: decodeSkillCatalog(root.skillCatalog, "$.skillCatalog"),
    selectedWorkspaceId,
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

export function assertWindowDragStarted(value: unknown) {
  const item = object(value, "$", ["started"]);
  if (booleanValue(item.started, "$.started") !== true)
    fail("$.started", "window drag did not start");
}

export function assertWindowControlCompleted(value: unknown) {
  const item = object(value, "$", ["completed"]);
  if (booleanValue(item.completed, "$.completed") !== true)
    fail("$.completed", "window control did not complete");
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

export function decodeWorkspaceMutationResult(
  value: unknown,
  expectedWorkspaceId: string,
): WorkspaceMutationResult {
  const item = object(value, "$", [
    "accepted",
    "workspaceId",
    "workspaceEpoch",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  const workspaceId = positiveWireId(item.workspaceId, "$.workspaceId");
  if (workspaceId !== expectedWorkspaceId)
    fail("$.workspaceId", "response identity mismatch");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      workspaceId,
      workspaceEpoch: positiveWireId(item.workspaceEpoch, "$.workspaceEpoch"),
      reason: null,
    };
  }
  if (item.workspaceEpoch !== null) fail("$.workspaceEpoch", "expected null");
  return {
    accepted: false,
    workspaceId,
    workspaceEpoch: null,
    reason: enumValue(item.reason, "$.reason", workspaceMutationReasons),
  };
}

export function decodeTaskCreateResult(value: unknown): TaskCreateResult {
  const item = object(value, "$", [
    "accepted",
    "taskId",
    "bindingEpoch",
    "reason",
  ]);
  const accepted = booleanValue(item.accepted, "$.accepted");
  if (accepted) {
    if (item.reason !== null) fail("$.reason", "expected null");
    return {
      accepted: true,
      taskId: positiveWireId(item.taskId, "$.taskId"),
      bindingEpoch: positiveWireId(item.bindingEpoch, "$.bindingEpoch"),
      reason: null,
    };
  }
  if (item.taskId !== null || item.bindingEpoch !== null)
    fail("$", "a rejected Task creation cannot expose identities");
  return {
    accepted: false,
    taskId: null,
    bindingEpoch: null,
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

export function assertCloseAccepted(value: unknown, taskId: string) {
  const item = object(value, "$", ["taskId", "closing"]);
  if (
    positiveWireId(item.taskId, "$.taskId") !== taskId ||
    booleanValue(item.closing, "$.closing") !== true
  )
    fail("$", "close response mismatch");
}

export function assertTaskFlag(
  value: unknown,
  taskId: string,
  flag: "renamed" | "deleted",
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
