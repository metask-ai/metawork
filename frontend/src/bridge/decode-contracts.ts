import {
  WORKBENCH_SCHEMA_VERSION,
  type AccountCommandResult,
  type AccountView,
  type AskOption,
  type AskQuestion,
  type HostSignal,
  type PendingUi,
  type RunView,
  type TaskView,
  type ToolView,
  type UiRecord,
  type WorkbenchSnapshot,
  type WorkspaceChoice,
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

function decodeAccount(value: unknown, path: string): AccountView {
  const item = object(value, path, [
    "sessionState",
    "executionState",
    "operation",
    "readiness",
    "primaryAction",
    "canCancel",
    "accountId",
    "displayName",
    "apiKeys",
    "models",
    "selectedApiKeyId",
    "selectedModel",
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
      const key = object(value, itemPath, ["id", "name", "suffix"]);
      return {
        id: stringValue(key.id, `${itemPath}.id`),
        name: stringValue(key.name, `${itemPath}.name`),
        suffix: stringValue(key.suffix, `${itemPath}.suffix`),
      };
    },
  );
  const models = arrayValue(
    item.models,
    `${path}.models`,
    (value, itemPath) => {
      const model = object(value, itemPath, ["id", "displayName"]);
      return {
        id: stringValue(model.id, `${itemPath}.id`),
        displayName: stringValue(model.displayName, `${itemPath}.displayName`),
      };
    },
  );
  if (new Set(apiKeys.map((key) => key.id)).size !== apiKeys.length)
    fail(`${path}.apiKeys`, "API Key identities must be unique");
  if (new Set(models.map((model) => model.id)).size !== models.length)
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
  const displayName = stringValue(item.displayName, `${path}.displayName`);
  const selectedApiKeyId = stringValue(
    item.selectedApiKeyId,
    `${path}.selectedApiKeyId`,
  );
  const selectedModel = stringValue(
    item.selectedModel,
    `${path}.selectedModel`,
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
  if (canCancel !== (operation !== "none" && operation !== "logging_out"))
    fail(path, "cancellation availability disagrees with the active operation");
  if (
    executionState === "ready" &&
    (selectedApiKeyId.length === 0 ||
      selectedModel.length === 0 ||
      executionGeneration === "0")
  )
    fail(path, "a ready execution requires selected identities and generation");
  if (primaryAction === "choose_api_key" && apiKeys.length === 0)
    fail(path, "API Key choice requires at least one candidate");
  if (primaryAction === "choose_model" && models.length === 0)
    fail(path, "model choice requires at least one candidate");
  if (
    sessionState === "signed_out" &&
    (executionState !== "none" ||
      operation !== "none" ||
      accountId.length !== 0 ||
      displayName.length !== 0 ||
      apiKeys.length !== 0 ||
      models.length !== 0 ||
      selectedApiKeyId.length !== 0 ||
      selectedModel.length !== 0 ||
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
    displayName,
    apiKeys,
    models,
    selectedApiKeyId,
    selectedModel,
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
    "user",
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
    user: stringValue(item.user, `${path}.user`),
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
    "title",
    "workspaceRoot",
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
  return {
    id: positiveWireId(item.id, `${path}.id`),
    title: stringValue(item.title, `${path}.title`),
    workspaceRoot: stringValue(item.workspaceRoot, `${path}.workspaceRoot`),
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

export function decodeWorkbenchSnapshot(value: unknown): WorkbenchSnapshot {
  const root = object(value, "$", [
    "schemaVersion",
    "revision",
    "account",
    "tasks",
  ]);
  const schemaVersion = numberValue(root.schemaVersion, "$.schemaVersion");
  if (schemaVersion !== WORKBENCH_SCHEMA_VERSION)
    fail("$.schemaVersion", `unsupported version ${schemaVersion}`);
  return {
    schemaVersion,
    revision: wireId(root.revision, "$.revision"),
    account: decodeAccount(root.account, "$.account"),
    tasks: arrayValue(root.tasks, "$.tasks", decodeTask),
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

export function decodeGeneration(value: unknown) {
  const item = object(value, "$", ["generation"]);
  return positiveWireId(item.generation, "$.generation");
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

export function decodeWorkspaceChoice(value: unknown): WorkspaceChoice {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    fail("$", "expected workspace choice object");
  const selected = booleanValue((value as JsonObject).selected, "$.selected");
  if (!selected) {
    object(value, "$", ["selected"]);
    return { selected: false };
  }
  const item = object(value, "$", ["selected", "workspaceRoot", "grant"]);
  return {
    selected: true,
    workspaceRoot: stringValue(item.workspaceRoot, "$.workspaceRoot"),
    grant: positiveWireId(item.grant, "$.grant"),
  };
}

export function decodeTaskId(value: unknown) {
  const item = object(value, "$", ["taskId"]);
  return positiveWireId(item.taskId, "$.taskId");
}

export function assertRunAccepted(value: unknown, taskId: string) {
  const item = object(value, "$", ["taskId", "runId"]);
  if (positiveWireId(item.taskId, "$.taskId") !== taskId)
    fail("$.taskId", "response identity mismatch");
  return positiveWireId(item.runId, "$.runId");
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
