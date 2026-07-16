import {
  WORKBENCH_SCHEMA_VERSION,
  type AskOption,
  type AskQuestion,
  type HostSignal,
  type PendingUi,
  type RunView,
  type SessionView,
  type ToolView,
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
  "host_shutdown",
  "event_pipeline_failure",
  "queue_capacity_failure",
  "bridge_pipeline_failure",
  "ui_pipeline_failure",
  "dependency_contract_failure",
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

function decodeTool(value: unknown, path: string): ToolView {
  const item = object(value, path, [
    "id",
    "name",
    "input",
    "progress",
    "content",
    "state",
    "isError",
    "elapsedMs",
  ]);
  return {
    id: stringValue(item.id, `${path}.id`),
    name: stringValue(item.name, `${path}.name`),
    input: stringValue(item.input, `${path}.input`),
    progress: stringValue(item.progress, `${path}.progress`),
    content: stringValue(item.content, `${path}.content`),
    state: enumValue(item.state, `${path}.state`, [
      "running",
      "completed",
      "failed",
    ] as const),
    isError: booleanValue(item.isError, `${path}.isError`),
    elapsedMs: wireId(item.elapsedMs, `${path}.elapsedMs`),
  };
}

function decodeRun(value: unknown, path: string): RunView {
  const item = object(value, path, [
    "id",
    "phase",
    "user",
    "assistant",
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
  return {
    id: positiveWireId(item.id, `${path}.id`),
    phase: enumValue(item.phase, `${path}.phase`, runPhases),
    user: stringValue(item.user, `${path}.user`),
    assistant: stringValue(item.assistant, `${path}.assistant`),
    status: stringValue(item.status, `${path}.status`),
    outcome: nullableEnum(item.outcome, `${path}.outcome`, runOutcomes),
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
      "kind",
      "questions",
    ]);
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
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
      "kind",
      "tool",
      "args",
    ]);
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      kind,
      tool: stringValue(item.tool, `${path}.tool`),
      args: stringValue(item.args, `${path}.args`),
    };
  }
  if (kind === "plan_approval") {
    const item = object(value, path, ["requestId", "runId", "kind", "plan"]);
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      kind,
      plan: stringValue(item.plan, `${path}.plan`),
    };
  }
  if (kind === "custom") {
    const item = object(value, path, [
      "requestId",
      "runId",
      "kind",
      "customKind",
      "payload",
    ]);
    return {
      requestId: positiveWireId(item.requestId, `${path}.requestId`),
      runId: positiveWireId(item.runId, `${path}.runId`),
      kind,
      customKind: stringValue(item.customKind, `${path}.customKind`),
      payload: stringValue(item.payload, `${path}.payload`),
    };
  }
  return fail(`${path}.kind`, `unexpected request kind ${kind}`);
}

function decodeSession(value: unknown, path: string): SessionView {
  const item = object(value, path, [
    "id",
    "title",
    "workspaceRoot",
    "lifecycle",
    "archived",
    "closeFailed",
    "currentRunId",
    "currentRunPhase",
    "lastRunOutcome",
    "cause",
    "runs",
    "pendingUi",
  ]);
  const runs = arrayValue(item.runs, `${path}.runs`, decodeRun);
  const lifecycle = enumValue(
    item.lifecycle,
    `${path}.lifecycle`,
    taskLifecycles,
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
  return {
    id: positiveWireId(item.id, `${path}.id`),
    title: stringValue(item.title, `${path}.title`),
    workspaceRoot: stringValue(item.workspaceRoot, `${path}.workspaceRoot`),
    lifecycle,
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
  };
}

export function decodeWorkbenchSnapshot(value: unknown): WorkbenchSnapshot {
  const root = object(value, "$", ["schemaVersion", "revision", "sessions"]);
  const schemaVersion = numberValue(root.schemaVersion, "$.schemaVersion");
  if (schemaVersion !== WORKBENCH_SCHEMA_VERSION)
    fail("$.schemaVersion", `unsupported version ${schemaVersion}`);
  return {
    schemaVersion,
    revision: wireId(root.revision, "$.revision"),
    sessions: arrayValue(root.sessions, "$.sessions", decodeSession),
  };
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
    automation: booleanValue(item.automation, "$.automation"),
    gate5Fixture: booleanValue(item.gate5Fixture, "$.gate5Fixture"),
  };
}

export function decodeHostSignalEvent(value: unknown): HostSignal {
  const keys = [
    "sequence",
    "transport",
    "origin",
    "onMainThread",
    "requestBytes",
    "automation",
    "gate5Fixture",
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
    "automation",
    "gate5Fixture",
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

export function decodeSessionId(value: unknown) {
  const item = object(value, "$", ["sessionId"]);
  return positiveWireId(item.sessionId, "$.sessionId");
}

export function assertRunAccepted(value: unknown, sessionId: string) {
  const item = object(value, "$", ["sessionId", "runId"]);
  if (positiveWireId(item.sessionId, "$.sessionId") !== sessionId)
    fail("$.sessionId", "response identity mismatch");
  return positiveWireId(item.runId, "$.runId");
}

export function assertCancelAccepted(
  value: unknown,
  sessionId: string,
  runId: string,
) {
  const item = object(value, "$", ["sessionId", "runId", "cancelRequested"]);
  if (
    positiveWireId(item.sessionId, "$.sessionId") !== sessionId ||
    positiveWireId(item.runId, "$.runId") !== runId ||
    booleanValue(item.cancelRequested, "$.cancelRequested") !== true
  )
    fail("$", "cancel response mismatch");
}

export function assertUiResponseAccepted(
  value: unknown,
  sessionId: string,
  runId: string,
  requestId: string,
) {
  const item = object(value, "$", [
    "sessionId",
    "runId",
    "requestId",
    "answered",
  ]);
  if (
    positiveWireId(item.sessionId, "$.sessionId") !== sessionId ||
    positiveWireId(item.runId, "$.runId") !== runId ||
    positiveWireId(item.requestId, "$.requestId") !== requestId ||
    booleanValue(item.answered, "$.answered") !== true
  )
    fail("$", "UI response identity mismatch");
}

export function assertCloseAccepted(value: unknown, sessionId: string) {
  const item = object(value, "$", ["sessionId", "closing"]);
  if (
    positiveWireId(item.sessionId, "$.sessionId") !== sessionId ||
    booleanValue(item.closing, "$.closing") !== true
  )
    fail("$", "close response mismatch");
}

export function assertTaskFlag(
  value: unknown,
  sessionId: string,
  flag: "renamed" | "deleted",
) {
  const item = object(value, "$", ["sessionId", flag]);
  if (
    positiveWireId(item.sessionId, "$.sessionId") !== sessionId ||
    booleanValue(item[flag], `$.${flag}`) !== true
  )
    fail("$", `${flag} response mismatch`);
}

export function assertTaskArchived(
  value: unknown,
  sessionId: string,
  archived: boolean,
) {
  const item = object(value, "$", ["sessionId", "archived"]);
  if (
    positiveWireId(item.sessionId, "$.sessionId") !== sessionId ||
    booleanValue(item.archived, "$.archived") !== archived
  )
    fail("$", "archive response mismatch");
}
