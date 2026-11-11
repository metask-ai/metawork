import { decodeWorkbenchSnapshot as decodeScopedSnapshot } from "../frontend/src/bridge/decode-contracts.ts";
import { productViewFixture } from "./test-support/product-view-fixture.mjs";
import { initialViewScope } from "../frontend/src/bridge/contracts.ts";
import { decodeProductStateFixture as decodeWorkbenchSnapshot } from "./test-support/decode-product-state-fixture.mjs";
import { decodeSendInputResult } from "../frontend/src/bridge/decode-contracts.ts";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  assertDisconnected,
  decodeAccountCommandResult,
  decodeExecutionCommandResult,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeTaskCreateResult,
  decodeTaskCompactResult,
  decodeTaskRestoreResult,
  decodeTaskRunResult,
  decodeTaskCompletionSeenResult,
  decodeSkillDetailResult,
  decodeSkillExportResult,
  decodeSkillImportPreview,
  decodeSkillMutationResult,
  decodeMcpMutationResult,
  decodeMcpInstallation,
  decodeMcpCreateResult,
  decodeMcpRefreshResult,
  decodeFilePreview,
  decodeAttachmentChooseResult,
  decodeAttachmentReleaseResult,
  decodeAutomaticWorkspaceRootMutationResult,
} from "../frontend/src/bridge/decode-contracts.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

test("MCP installation operations are strict safe facts with terminal history", () => {
  const operation = {
    serverId: "mcp-01234567890123456789",
    taskId: "3",
    runId: "7",
    revision: "2",
    desiredGeneration: "9",
    displayName: "Installed MCP",
    phase: "ready",
    failure: null,
    sourceOrigin: "https://source.example",
    targetOrigin: "https://target.example",
    canCancel: false,
    missingCredentials: [],
  };
  assert.deepEqual(
    decodeMcpInstallation({ operations: [operation], notice: null })
      .operations[0],
    operation,
  );
  for (const patch of [
    { request: "private" },
    { credentialRef: "private" },
    { endpoint: "private" },
    { revision: "0" },
    { phase: "proposal_submitted" },
    { failure: "timeout" },
  ]) {
    assert.throws(
      () =>
        decodeMcpInstallation({
          operations: [{ ...operation, ...patch }],
          notice: null,
        }),
      /Invalid Host contract/,
    );
  }
});

const modelsUnavailableFixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/models-unavailable.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

function clone(value) {
  return structuredClone(value);
}

test("Task index and detail require their Host action blockers", () => {
  const view = productViewFixture(fixture);
  const decoded = decodeScopedSnapshot(view);
  assert.equal(decoded.taskIndex[0].archiveBlocker, "busy");
  assert.equal(decoded.taskIndex[0].deleteBlocker, null);
  assert.equal(decoded.taskPage.task.compactBlocker, "busy");

  const missing = clone(view);
  delete missing.taskPage.task.compactBlocker;
  assert.throws(() => decodeScopedSnapshot(missing), /compactBlocker/);
  const unknown = clone(view);
  unknown.taskIndex[0].deleteBlocker = "worker_busy";
  assert.throws(() => decodeScopedSnapshot(unknown), /deleteBlocker/);
  const misplaced = clone(view);
  misplaced.taskPage.task.archiveBlocker = null;
  assert.throws(() => decodeScopedSnapshot(misplaced), /unexpected fields: 1/);
});

test("project entry removal is a strict fact independent of Task directory and Workspace authorization", () => {
  const value = clone(fixture);
  value.workspaces[0].projectRemoved = true;
  const decoded = decodeWorkbenchSnapshot(value);
  assert.equal(decoded.workspaces[0].projectRemoved, true);
  assert.equal(
    decoded.workspaces[0].authorization,
    fixture.workspaces[0].authorization,
  );
  assert.equal(decoded.tasks[0].workspaceId, fixture.tasks[0].workspaceId);
  for (const invalid of [undefined, null, "true", 1]) {
    value.workspaces[0].projectRemoved = invalid;
    assert.throws(() => decodeWorkbenchSnapshot(value), /projectRemoved/);
  }
});

test("approval mode defaults and captured Task mode remain separate strict facts", () => {
  const value = clone(fixture);
  value.permissions.defaultMode = "auto_review";
  assert.equal(decodeWorkbenchSnapshot(value).tasks[0].approvalMode, "manual");
  value.tasks[0].approvalMode = "auto_review";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  for (const invalid of [0, "0", ["auto_review"], "auto"]) {
    const bad = clone(value);
    bad.tasks[0].approvalMode = invalid;
    assert.throws(() => decodeWorkbenchSnapshot(bad));
  }
  const wrongProfile = clone(value);
  wrongProfile.tasks[0].approvalMode = "full_access";
  assert.throws(() => decodeWorkbenchSnapshot(wrongProfile));
  const wrongDefault = clone(value);
  wrongDefault.permissions.defaultMode = "full_access";
  assert.throws(() => decodeWorkbenchSnapshot(wrongDefault));
});

test("manual review explanations are bounded request-only facts with typed failure causes", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  task.approvalMode = "auto_review";
  task.permissionReviewState = "needs_user";
  task.permissionReviewExplanation = {
    cause: "reviewer_concern",
    reason: "请确认安装来源。",
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  for (const cause of [
    "timeout",
    "call_failed",
    "capacity",
    "context_incomplete",
    "invalid_response",
    "input_changed",
    "state_changed",
    "unavailable",
  ]) {
    task.permissionReviewExplanation = { cause, reason: null };
    assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
    task.permissionReviewExplanation.reason = "untrusted failure details";
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
  for (const reason of [" ", "bad\nreason", "字".repeat(171)]) {
    task.permissionReviewExplanation = { cause: "reviewer_concern", reason };
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
  task.permissionReviewExplanation = { cause: "timeout", reason: null };
  task.permissionReviewState = "reviewing";
  assert.throws(() => decodeWorkbenchSnapshot(value));
});

test("review audit only describes once-only reviewer decisions and keeps legal old reasons", () => {
  const value = clone(fixture);
  const record = {
    requestId: "8",
    runId: "7",
    order: "1",
    kind: "permission",
    state: "allowed_once",
    detail: "",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "reviewer",
    review: null,
    reviewReason: "Matches the user request",
    agentRequestId: "",
    permission: null,
  };
  value.tasks[0].uiHistory.push(record);
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  record.reviewReason = "a".repeat(512);
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  for (const reason of [null, " ", "a".repeat(513), "bad\nreason"]) {
    record.reviewReason = reason;
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
  record.reviewReason = "ok";
  for (const state of ["allowed_always", "denied_always", "cancelled"]) {
    record.state = state;
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
  record.state = "denied";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  record.answeredBy = "user";
  assert.throws(() => decodeWorkbenchSnapshot(value));
});

const emptyAccountSummary = {
  operation: "idle",
  usageEligibility: "unknown",
  wallet: {
    availability: "unavailable",
    balanceU: null,
    syncedAt: null,
    errorCode: "none",
    safeDiagnostic: "",
  },
  usage: {
    availability: "unavailable",
    today: null,
    total: null,
    syncedAt: null,
    errorCode: "none",
    safeDiagnostic: "",
  },
  history: {
    availability: "unavailable",
    startDate: null,
    endDate: null,
    days: [],
    syncedAt: null,
    errorCode: "none",
    safeDiagnostic: "",
  },
};

test("Automatic Workspace root projection and mutation results are strict", () => {
  const candidate = clone(fixture);
  candidate.automaticWorkspaceRoot = {
    generation: "18446744073709551615",
    mode: "custom",
    canonicalRoot: "/tmp/custom-root",
    health: "path_unavailable",
    redacted: false,
    canChoose: true,
    canReset: true,
    canRetry: true,
  };
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);

  const uncertain = clone(candidate);
  uncertain.automaticWorkspaceRoot = {
    ...uncertain.automaticWorkspaceRoot,
    mode: null,
    canonicalRoot: null,
    health: "outcome_unknown",
    canRetry: false,
  };
  assert.deepEqual(decodeWorkbenchSnapshot(uncertain), uncertain);

  const inactiveWriteFailure = clone(uncertain);
  inactiveWriteFailure.automaticWorkspaceRoot.health = "write_failed";
  assert.deepEqual(
    decodeWorkbenchSnapshot(inactiveWriteFailure),
    inactiveWriteFailure,
  );

  for (const mutate of [
    (value) => delete value.automaticWorkspaceRoot.canRetry,
    (value) => (value.automaticWorkspaceRoot.generation = "0"),
    (value) => (value.automaticWorkspaceRoot.health = "invented"),
    (value) => (value.automaticWorkspaceRoot.mode = "temporary"),
    (value) => (value.automaticWorkspaceRoot.path = "/tmp/leaked"),
    (value) => (value.automaticWorkspaceRoot.health = "ready"),
    (value) => (value.automaticWorkspaceRoot.mode = null),
    (value) => (value.automaticWorkspaceRoot.canonicalRoot = null),
  ]) {
    const invalid = clone(candidate);
    mutate(invalid);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }

  assert.deepEqual(
    decodeAutomaticWorkspaceRootMutationResult({ outcome: "applied" }),
    {
      outcome: "applied",
    },
  );
  assert.deepEqual(
    decodeAutomaticWorkspaceRootMutationResult({ outcome: "cancelled" }),
    {
      outcome: "cancelled",
    },
  );
  assert.throws(() =>
    decodeAutomaticWorkspaceRootMutationResult({
      outcome: "applied",
      path: "/tmp",
    }),
  );
  assert.throws(() =>
    decodeAutomaticWorkspaceRootMutationResult({ outcome: "unknown" }),
  );
});

test("Skill recovery state matches the Host fixture and enforces Retry authority", () => {
  const asset = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/skill-recovery-required.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const candidate = clone(fixture);
  candidate.skillManagement.assets = [asset];
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  candidate.skillManagement.availability = "ready";
  asset.canRetry = true;
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  for (const mutate of [
    (value) => (value.skillManagement.availability = "write_failed"),
    (value) => (value.skillManagement.assets[0].managementState = "ready"),
    (value) =>
      (value.skillManagement.assets[0].managementState = "invented_phase"),
    (value) => (value.skillManagement.assets[0].installId = null),
    (value) => (value.skillManagement.assets[0].canReimport = true),
  ]) {
    const invalid = clone(candidate);
    mutate(invalid);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
});

test("Built-in Skill provenance does not grant file management", () => {
  const candidate = clone(fixture);
  candidate.skillManagement.assets = [
    JSON.parse(
      readFileSync(
        new URL(
          "../frontend/src/bridge/__fixtures__/skill-builtin.fixture",
          import.meta.url,
        ),
        "utf8",
      ),
    ),
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  for (const forbidden of [
    "canExport",
    "canReimport",
    "canUninstall",
    "canRetry",
  ]) {
    const invalid = clone(candidate);
    invalid.skillManagement.assets[0][forbidden] = true;
    assert.throws(
      () => decodeWorkbenchSnapshot(invalid),
      /built-in skills cannot expose file management/,
    );
  }
});

test("Skill discovery is scoped root evidence, separate from shared Task catalog", () => {
  const candidate = clone(fixture);
  candidate.skillManagement.personalSourceDiscovery = [
    { sourceId: "agents.user.default", state: "missing", reason: null },
  ];
  candidate.workspaces[0].skillSourceDiscovery = [
    { sourceId: "agents.user.default", state: "checked", reason: null },
    {
      sourceId: "agents.workspace.default",
      state: "error",
      reason: "unsupported_entry",
    },
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  assert.equal(candidate.tasks[0].skillCatalog.sourceDiscovery, undefined);
  for (const workspaceState of [
    {
      kind: "manual",
      authorization: "reauthorization_required",
      recentOrder: "1",
    },
    { kind: "manual", authorization: "removing", recentOrder: "1" },
    { kind: "automatic", authorization: "available", recentOrder: "0" },
  ]) {
    const next = clone(candidate);
    Object.assign(next.workspaces[0], workspaceState, {
      skillSourceDiscovery: null,
    });
    // These Workspace facts are valid; only publishing discovery is forbidden.
    assert.deepEqual(decodeWorkbenchSnapshot(next), next);
    next.workspaces[0].skillSourceDiscovery =
      candidate.workspaces[0].skillSourceDiscovery;
    assert.throws(
      () => decodeWorkbenchSnapshot(next),
      /source discovery requires an authorized Manual Workspace/,
    );
  }
  for (const mutate of [
    (next) => {
      next.skillManagement.personalSourceDiscovery.push(
        next.workspaces[0].skillSourceDiscovery[1],
      );
    },
    (next) => {
      next.workspaces[0].skillSourceDiscovery[0].state = "disabled";
    },
    (next) => {
      next.workspaces[0].skillSourceDiscovery[1].reason = null;
    },
    (next) => {
      next.workspaces[0].authorization = "removing";
    },
    (next) => {
      next.tasks[0].skillCatalog.sourceDiscovery = [];
    },
  ]) {
    const next = clone(candidate);
    mutate(next);
    assert.throws(() => decodeWorkbenchSnapshot(next));
  }
});

test("Run elapsed time is nullable, bounded, and frozen for terminal history", () => {
  for (const value of [null, "0", "134000"]) {
    const candidate = clone(fixture);
    const run = candidate.tasks[0].runs[0];
    run.phase = "running";
    run.activity = { kind: "thinking" };
    run.terminal = null;
    run.elapsedMs = value;
    assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  }
  for (const value of [undefined, "-1", "01", "18446744073709551616", 1200]) {
    const candidate = clone(fixture);
    candidate.tasks[0].runs[0].elapsedMs = value;
    assert.throws(() => decodeWorkbenchSnapshot(candidate));
  }
  const candidate = clone(fixture);
  const task = candidate.tasks[0];
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.activeOperation = null;
  const run = candidate.tasks[0].runs[0];
  run.phase = "completed";
  run.activity = null;
  run.output.provisional = "";
  run.terminal = terminal("completed");
  run.elapsedMs = "1200";
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
});

test("Run finished time is terminal-only, bounded, and lossless", () => {
  const candidate = clone(fixture);
  const task = candidate.tasks[0];
  const run = task.runs[0];
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.activeOperation = null;
  run.phase = "failed";
  run.activity = null;
  run.output.provisional = "";
  run.terminal = terminal("failed", "timeout");
  run.elapsedMs = null;
  run.finishedAtUnixMs = "1789436313000";
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);

  for (const value of ["0", "01", "8640000000000001", -1, undefined]) {
    const invalid = clone(candidate);
    invalid.tasks[0].runs[0].finishedAtUnixMs = value;
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
  const active = clone(fixture);
  active.tasks[0].runs[0].finishedAtUnixMs = "1789436313000";
  assert.throws(
    () => decodeWorkbenchSnapshot(active),
    /active Run cannot expose a finished time/,
  );
});

test("Run submitted time is nullable, bounded, and valid before completion", () => {
  const candidate = clone(fixture);
  candidate.tasks[0].runs[0].submittedAtUnixMs = "1789436300000";
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);

  for (const value of ["0", "01", "8640000000000001", -1, undefined]) {
    const invalid = clone(candidate);
    invalid.tasks[0].runs[0].submittedAtUnixMs = value;
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
});

function terminal(outcome, cause = null, diagnosticDisposition = "absent") {
  return {
    outcome,
    cause,
    diagnosticDisposition,
    recordingIncomplete: false,
    feedback: { guidance: "none", offerInputPreparation: false },
    modelError: null,
  };
}

test("Task navigation requires a known signal consistent with the frozen page", () => {
  const value = productViewFixture(fixture);
  assert.equal(decodeScopedSnapshot(value).taskPage.task.signal, "running");
  const task = value.taskPage.task;
  delete task.signal;
  assert.throws(() => decodeScopedSnapshot(value), /expected keys/);
  task.signal = "future";
  assert.throws(() => decodeScopedSnapshot(value), /signal/);
  task.signal = null;
  assert.throws(
    () => decodeScopedSnapshot(value),
    /Task header disagrees with index/,
  );
});

test("Run feedback cannot disagree between a visible Run and its manifest", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  Object.assign(task, {
    signal: null,
    activeOperation: null,
    currentRunId: "0",
    currentRunPhase: null,
  });
  Object.assign(task.runs[0], {
    phase: "stopped",
    activity: null,
    terminal: {
      ...terminal("stopped", "tool_failure"),
      feedback: { guidance: "review_changes", offerInputPreparation: true },
    },
  });
  const view = productViewFixture(value);
  assert.doesNotThrow(() => decodeScopedSnapshot(view));
  const manifestRun = view.taskPage.runManifest[0];
  manifestRun.terminal = {
    ...manifestRun.terminal,
    feedback: { guidance: "review_changes", offerInputPreparation: false },
  };
  assert.throws(() => decodeScopedSnapshot(view), /manifest/);
});

test("model error details accept the Host fixture and reject malformed or authority-expanding shapes", () => {
  const detail = JSON.parse(
    readFileSync(
      new URL("../src/product/control/model_error.fixture", import.meta.url),
      "utf8",
    ),
  );
  const value = clone(fixture);
  const task = value.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  const run = task.runs[0];
  run.phase = "failed";
  run.activity = null;
  run.terminal = {
    ...terminal("failed", "provider_failure"),
    modelError: detail,
    feedback: { guidance: "account_settings", offerInputPreparation: true },
  };
  assert.deepEqual(
    decodeWorkbenchSnapshot(value).tasks[0].runs[0].terminal.modelError,
    detail,
  );
  for (const patch of [
    { agentRunId: "0" },
    { agentRunId: "01" },
    { category: "future" },
    { message: "é".repeat(513) },
    { code: "x".repeat(129) },
    { attempts: "0" },
    { attempts: "4294967296" },
    { retryAfterMs: "18446744073709551616" },
    { httpStatus: -1 },
    { retry: "yes" },
    { hostRedacted: "true" },
    { recovery: "account_settings" },
    { extra: true },
  ]) {
    run.terminal.modelError = { ...detail, ...patch };
    assert.throws(() => decodeWorkbenchSnapshot(value), /modelError/);
  }
  run.terminal.modelError = { ...detail, source: "custom_provider" };
  assert.throws(() => decodeWorkbenchSnapshot(value), /Metask/);
  run.terminal = {
    ...terminal("failed", "agent_failure"),
    modelError: detail,
    feedback: { guidance: "prepare_retry", offerInputPreparation: true },
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  run.terminal.feedback.guidance = "account_settings";
  assert.throws(() => decodeWorkbenchSnapshot(value), /primary model error/);
  for (const feedback of [
    { guidance: "unknown", offerInputPreparation: false },
    { guidance: "none", offerInputPreparation: 1 },
    { guidance: "none" },
  ]) {
    run.terminal.feedback = feedback;
    assert.throws(() => decodeWorkbenchSnapshot(value), /feedback/);
  }
  delete run.terminal.feedback;
  assert.throws(() => decodeWorkbenchSnapshot(value), /expected keys/);
  run.terminal = terminal("failed", "provider_failure");
  delete run.terminal.modelError;
  assert.throws(() => decodeWorkbenchSnapshot(value), /expected keys/);
});

test("typed Bash presentation rejects contradictory or malformed detail", () => {
  const candidate = clone(fixture);
  const tool = {
    id: "bash-detail",
    order: "1",
    name: "Bash",
    bash: {
      command: "pwd",
      description: "Inspect workspace",
      result: {
        exitCode: 0,
        stdout: "",
        stderr: "",
        stdoutIncomplete: false,
        stderrIncomplete: false,
      },
    },
    presentation: null,
    errorDetail: null,
    input: "{}",
    progress: "",
    content: "raw",
    state: "completed",
    isError: false,
    elapsedMs: "1",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
  };
  candidate.tasks[0].runs[0].tools = [tool];
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  for (const mutate of [
    (t) => delete t.bash,
    (t) => (t.name = "Read"),
    (t) => (t.inputTruncated = true),
    (t) => (t.contentTruncated = true),
    (t) => (t.state = "running"),
    (t) => (t.bash.command = null),
    (t) => (t.bash.result.exitCode = 2147483648),
    (t) => (t.bash.result.stdoutIncomplete = "false"),
    (t) => (t.bash.extra = true),
  ]) {
    const invalid = clone(candidate);
    mutate(invalid.tasks[0].runs[0].tools[0]);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
});

test("typed built-in Tool presentations remain identity-bound and terminal-safe", () => {
  const presentations = [
    [
      "Read",
      { kind: "read", target: "/workspace/main.ts", offset: "1", limit: "20" },
    ],
    ["Write", { kind: "write", target: "/workspace/main.ts" }],
    ["Edit", { kind: "edit", target: "/workspace/main.ts" }],
    ["Glob", { kind: "glob", pattern: "**/*.ts", scope: "/workspace" }],
    [
      "Grep",
      {
        kind: "grep",
        pattern: "TODO",
        scope: "/workspace",
        include: "*.ts",
      },
    ],
    [
      "BashOutput",
      {
        kind: "bash_output",
        jobId: "job-1",
        result: {
          status: "exited",
          stdout: "done",
          stderr: "",
          stdoutIncomplete: false,
          stderrIncomplete: false,
        },
      },
    ],
    ["KillShell", { kind: "kill_shell", jobId: "job-1" }],
    ["WebSearch", { kind: "web_search", query: "release notes" }],
    [
      "WebFetch",
      {
        kind: "web_fetch",
        url: "https://example.com",
        prompt: null,
        result: {
          url: "https://example.com",
          bytes: "12",
          content: "hello world",
        },
      },
    ],
  ];
  for (const [name, presentation] of presentations) {
    const candidate = clone(fixture);
    candidate.tasks[0].runs[0].tools = [
      {
        id: "tool-1",
        order: "1",
        name,
        bash: null,
        presentation,
        errorDetail: null,
        input: "{}",
        progress: "",
        content: "result",
        state: "completed",
        isError: false,
        elapsedMs: "1",
        inputTruncated: false,
        progressTruncated: false,
        contentTruncated: false,
        redacted: false,
        fileRefs: [],
      },
    ];
    assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  }

  const mismatch = clone(fixture);
  mismatch.tasks[0].runs[0].tools = [
    {
      id: "tool-1",
      order: "1",
      name: "Read",
      bash: null,
      presentation: { kind: "web_search", query: "wrong identity" },
      errorDetail: null,
      input: "{}",
      progress: "",
      content: "",
      state: "completed",
      isError: false,
      elapsedMs: "1",
      inputTruncated: false,
      progressTruncated: false,
      contentTruncated: false,
      redacted: false,
      fileRefs: [],
    },
  ];
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatch),
    /presentation does not match tool identity/,
  );

  const invalidError = clone(mismatch);
  invalidError.tasks[0].runs[0].tools[0].presentation = null;
  invalidError.tasks[0].runs[0].tools[0].errorDetail = "failed";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidError),
    /error detail requires a failed tool/,
  );
});

test("the canonical Workbench fixture decodes without normalization", () => {
  assert.deepEqual(decodeWorkbenchSnapshot(fixture), fixture);

  const inconsistentPersistence = clone(fixture);
  inconsistentPersistence.capabilities.taskHistoryPersistence = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(inconsistentPersistence),
    /availability and health must agree/,
  );

  const recoverableWithoutFileCapability = clone(fixture);
  recoverableWithoutFileCapability.capabilities.taskHistoryPersistenceHealth =
    "read_failed";
  assert.deepEqual(
    decodeWorkbenchSnapshot(recoverableWithoutFileCapability),
    recoverableWithoutFileCapability,
  );

  const impossibleRecovery = clone(fixture);
  impossibleRecovery.capabilities.taskHistoryRecoveryAvailable = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(impossibleRecovery),
    /recovery requires recoverable persistence health/,
  );
});

test("retained Task history count is a strict wire integer", () => {
  const retained = clone(fixture);
  retained.capabilities.retainedTaskHistoryCount = "3";
  assert.deepEqual(decodeWorkbenchSnapshot(retained), retained);

  const invalidCount = clone(fixture);
  invalidCount.capabilities.retainedTaskHistoryCount = 3;
  assert.throws(() => decodeWorkbenchSnapshot(invalidCount));
});

test("read-only Tasks expose one unavailable continuation state", () => {
  const readOnly = clone(fixture);
  const task = readOnly.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "interrupted";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("interrupted", "app_shutdown");
  task.binding.availability = "unavailable";
  task.binding.unavailableReason = "runtime_detached";
  task.continuationAvailable = false;
  task.continuationUnavailableReason = "history_read_only";
  task.continuationRecoveryAvailable = false;
  assert.deepEqual(decodeWorkbenchSnapshot(readOnly), readOnly);
});

test("completion receipt is a strict latest terminal completed Run identity", () => {
  const completed = clone(fixture);
  const task = completed.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "completed";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("completed");
  task.unreadCompletionRunId = task.runs[0].id;
  assert.deepEqual(decodeWorkbenchSnapshot(completed), completed);

  for (const mutate of [
    (candidate) => (candidate.tasks[0].unreadCompletionRunId = "99"),
    (candidate) => (candidate.tasks[0].runs[0].terminal = terminal("failed")),
    (candidate) => (candidate.tasks[0].archived = true),
    (candidate) => delete candidate.tasks[0].unreadCompletionRunId,
  ]) {
    const invalid = clone(completed);
    mutate(invalid);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }

  assert.deepEqual(
    decodeTaskCompletionSeenResult(
      { taskId: "3", runId: "7", marked: false },
      "3",
      "7",
    ),
    { taskId: "3", runId: "7", marked: false },
  );
  assert.throws(() =>
    decodeTaskCompletionSeenResult(
      { taskId: "3", runId: "8", marked: true },
      "3",
      "7",
    ),
  );
});

test("Task MCP authority is an exact immutable creation-time fact", () => {
  for (const authority of [
    { kind: "ready", selection: "selected" },
    { kind: "ready", selection: "none" },
    { kind: "unavailable", selection: null },
  ]) {
    const candidate = clone(fixture);
    candidate.tasks[0].mcpAuthority = authority;
    assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  }

  const mixed = clone(fixture);
  mixed.tasks[0].mcpAuthority = {
    kind: "unavailable",
    selection: "selected",
  };
  assert.throws(
    () => decodeWorkbenchSnapshot(mixed),
    /cannot have a selection/,
  );
});

test("durable Metask intent remains decodable when the current catalog is unavailable", () => {
  const catalogUnavailable = clone(fixture);
  catalogUnavailable.models = modelsUnavailableFixture;
  catalogUnavailable.account = {
    state: "signed_out",
    canCancel: false,
    accountId: "",
    displayName: "",
    emailHint: "",
    phoneHint: "",
    concurrencyLimit: null,
    errorCode: "none",
    safeDiagnostic: "",
    summary: emptyAccountSummary,
  };
  catalogUnavailable.newTaskAdmission = { available: true, reason: "none" };

  assert.deepEqual(
    decodeWorkbenchSnapshot(catalogUnavailable).models,
    modelsUnavailableFixture,
  );
});

test("Account concurrency accepts the backend unlimited sentinel", () => {
  const unlimited = clone(fixture);
  unlimited.account.concurrencyLimit = 0;
  assert.deepEqual(decodeWorkbenchSnapshot(unlimited), unlimited);

  const invalid = clone(fixture);
  invalid.account.concurrencyLimit = -1;
  assert.throws(() => decodeWorkbenchSnapshot(invalid));
});

test("Models recovery-required health crosses the strict snapshot decoder", () => {
  const recoveryRequired = clone(fixture);
  recoveryRequired.models.availability = "unavailable";
  recoveryRequired.models.persistenceHealth = "recovery_required";
  recoveryRequired.models.errorCode = "persistence_unavailable";
  recoveryRequired.newTaskAdmission = { available: true, reason: "none" };

  assert.deepEqual(decodeWorkbenchSnapshot(recoveryRequired), recoveryRequired);
});

test("attachment results enforce opaque grants and atomic typed outcomes", () => {
  const ready = {
    status: "ready",
    attachments: [
      {
        token: "a".repeat(48),
        kind: "image",
        format: "webp",
        displayName: "reference.webp",
        sizeBytes: "2048",
      },
      {
        token: "b".repeat(48),
        kind: "file",
        displayName: "spec.pdf",
        sizeBytes: "4096",
      },
    ],
  };
  assert.deepEqual(decodeAttachmentChooseResult(ready), ready);
  assert.deepEqual(decodeAttachmentChooseResult({ status: "cancelled" }), {
    status: "cancelled",
  });
  assert.deepEqual(
    decodeAttachmentChooseResult({
      status: "rejected",
      reason: "file_too_large",
    }),
    { status: "rejected", reason: "file_too_large" },
  );
  assert.throws(
    () =>
      decodeAttachmentChooseResult({
        ...ready,
        attachments: [{ ...ready.attachments[0], token: "physical/path.png" }],
      }),
    /invalid attachment token/,
  );
  assert.throws(
    () =>
      decodeAttachmentChooseResult({
        ...ready,
        attachments: [{ ...ready.attachments[1], kind: "pdf" }],
      }),
    /attachments\[0\].kind: unexpected value for enum/,
  );
  assert.throws(
    () =>
      decodeAttachmentChooseResult({
        ...ready,
        attachments: [{ ...ready.attachments[1], format: "pdf" }],
      }),
    /expected keys/,
  );
  assert.deepEqual(decodeAttachmentReleaseResult({ released: true }), {
    released: true,
  });
});

test("multimodal Run history keeps only ordered safe attachment metadata", () => {
  const snapshot = clone(fixture);
  snapshot.tasks[0].runs[0].input = {
    kind: "multimodal",
    text: "Compare these",
    attachments: [
      {
        kind: "image",
        format: "png",
        displayName: "diagram.png",
        sizeBytes: "128",
        redacted: false,
      },
      {
        kind: "image",
        format: "webp",
        displayName: "brief.webp",
        sizeBytes: "256",
        redacted: false,
      },
    ],
    redacted: false,
  };
  assert.deepEqual(decodeWorkbenchSnapshot(snapshot), snapshot);

  const leaked = clone(snapshot);
  leaked.tasks[0].runs[0].input.attachments[0].path = "/tmp/diagram.png";
  assert.throws(() => decodeWorkbenchSnapshot(leaked), /expected keys/);

  const retiredPdf = clone(snapshot);
  retiredPdf.tasks[0].runs[0].input.attachments[1].kind = "pdf";
  retiredPdf.tasks[0].runs[0].input.attachments[1].format = "pdf";
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredPdf),
    /attachments\[1\].kind: unexpected value for enum/,
  );
});

test("Workbench snapshot hard cut rejects retired provider fields", () => {
  const retiredApiKey = clone(fixture);
  retiredApiKey.models.providers[0].apiKeys = [];
  assert.throws(() => decodeWorkbenchSnapshot(retiredApiKey), /expected keys/);

  const retiredBinding = clone(fixture);
  retiredBinding.tasks[0].binding.provider = "anthropic";
  delete retiredBinding.tasks[0].binding.protocol;
  assert.throws(() => decodeWorkbenchSnapshot(retiredBinding), /expected keys/);

  const retiredExecutionRoot = clone(fixture);
  retiredExecutionRoot.execution = {
    state: "ready",
    defaultSource: "metask",
    activeSource: "metask",
    activeGeneration: "1",
    taskCreationAvailable: true,
    errorCode: "none",
  };
  delete retiredExecutionRoot.newTaskAdmission;
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredExecutionRoot),
    /expected keys/,
  );
});

test("model metadata preserves nullable declarations and exact positive u64 limits", () => {
  for (const declaration of [null, true, false]) {
    const candidate = clone(fixture);
    const metadata = candidate.models.providers[0].models[0].metadata;
    for (const [key, value] of Object.entries(metadata.capabilities)) {
      if (value !== null && typeof value === "object") {
        for (const child of Object.keys(value)) value[child] = declaration;
      } else {
        metadata.capabilities[key] = declaration;
      }
    }
    metadata.maxInputTokens =
      declaration === null ? null : "18446744073709551615";
    metadata.maxOutputTokens = declaration === null ? null : "1";
    assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  }
});

test("model metadata rejects missing fields, coercion and overflowing limits", () => {
  const changes = [
    (model) => {
      delete model.metadata;
    },
    (model) => {
      model.metadata = null;
    },
    (model) => {
      model.metadata.unexpected = true;
    },
    (model) => {
      model.metadata.capabilities.unexpected = true;
    },
  ];
  for (const field of ["maxInputTokens", "maxOutputTokens"]) {
    for (const value of [
      undefined,
      1024,
      "0",
      "-1",
      "01",
      "1.5",
      "1e3",
      "18446744073709551616",
    ]) {
      changes.push((model) => {
        model.metadata[field] = value;
      });
    }
  }
  const caps = fixture.models.providers[0].models[0].metadata.capabilities;
  for (const [key, value] of Object.entries(caps)) {
    for (const invalid of [undefined, null, true, []]) {
      if (value !== null && typeof value === "object") {
        changes.push((model) => {
          model.metadata.capabilities[key] = invalid;
        });
      }
    }
    const paths =
      value !== null && typeof value === "object"
        ? Object.keys(value).map((child) => [key, child])
        : [[key]];
    for (const path of paths) {
      for (const invalid of [undefined, "true", 0, {}]) {
        changes.push((model) => {
          let target = model.metadata.capabilities;
          for (const segment of path.slice(0, -1)) target = target[segment];
          target[path.at(-1)] = invalid;
        });
      }
    }
  }
  for (const change of changes) {
    const candidate = clone(fixture);
    change(candidate.models.providers[0].models[0]);
    assert.throws(() => decodeWorkbenchSnapshot(candidate), /metadata/);
  }
});

test("file references expose only preview identity and presentation", () => {
  const referenced = clone(fixture);
  referenced.tasks[0].runs[0].tools = [
    {
      id: "tool-1",
      order: "1",
      name: "Read",
      bash: null,
      presentation: null,
      errorDetail: null,
      input: "{}",
      progress: "",
      content: "ok",
      state: "completed",
      isError: false,
      elapsedMs: "1",
      inputTruncated: false,
      progressTruncated: false,
      contentTruncated: false,
      redacted: false,
      fileRefs: [
        {
          id: "file-3-1-1-1",
          title: "main.zig",
          displayPath: "src/main.zig",
        },
      ],
    },
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(referenced), referenced);

  const legacyShape = clone(referenced);
  legacyShape.tasks[0].runs[0].tools[0].fileRefs[0].kind = "read";
  assert.throws(() => decodeWorkbenchSnapshot(legacyShape), /expected keys/);
});

test("file preview response is exact and non-ready states cannot carry bytes", () => {
  assert.deepEqual(
    decodeFilePreview({
      state: "ready",
      content: "const answer = 42;",
      truncated: true,
      redacted: false,
    }),
    {
      state: "ready",
      content: "const answer = 42;",
      truncated: true,
      redacted: false,
    },
  );
  assert.deepEqual(
    decodeFilePreview({
      state: "changing",
      content: "",
      truncated: false,
      redacted: false,
    }),
    {
      state: "changing",
      content: "",
      truncated: false,
      redacted: false,
    },
  );
  assert.throws(
    () =>
      decodeFilePreview({
        state: "restricted",
        content: "leaked",
        truncated: false,
        redacted: false,
      }),
    /non-ready preview must not publish content/,
  );
  assert.throws(
    () =>
      decodeFilePreview({
        state: "ready",
        content: "ok",
        truncated: false,
        redacted: false,
        path: "src/main.zig",
      }),
    /expected keys/,
  );
});

test("resource-limited Run terminal crosses the Host to Renderer contract", () => {
  const resourceLimited = clone(fixture);
  const task = resourceLimited.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "stopped";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("stopped", "resource_limit");

  assert.deepEqual(decodeWorkbenchSnapshot(resourceLimited), resourceLimited);
});

test("typed Agent failures cross the Host to Renderer contract", () => {
  for (const cause of [
    "agent_failure",
    "provider_failure",
    "tool_failure",
    "image_input_unsupported",
    "event_payload_too_large",
    "queue_capacity_failure",
  ]) {
    const agentFailure = clone(fixture);
    const task = agentFailure.tasks[0];
    task.activeOperation = null;
    task.currentRunId = "0";
    task.currentRunPhase = null;
    task.runs[0].phase = "failed";
    task.runs[0].activity = null;
    task.runs[0].terminal = terminal("failed", cause);

    assert.deepEqual(decodeWorkbenchSnapshot(agentFailure), agentFailure);
  }
});

test("recording integrity is explicit and independent from successful completion", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  const run = task.runs[0];
  run.phase = "completed";
  run.activity = null;
  run.terminal = { ...terminal("completed"), recordingIncomplete: true };
  assert.equal(
    decodeWorkbenchSnapshot(value).tasks[0].runs[0].terminal.outcome,
    "completed",
  );
  for (const invalid of [null, "true", 1]) {
    run.terminal.recordingIncomplete = invalid;
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
  delete run.terminal.recordingIncomplete;
  assert.throws(() => decodeWorkbenchSnapshot(value));
});

test("event size and queue capacity retain distinct Host fixture causes", () => {
  const cases = JSON.parse(
    readFileSync(
      new URL("../src/product/control/event_failure.fixture", import.meta.url),
      "utf8",
    ),
  );
  for (const expected of cases) {
    const value = clone(fixture);
    const task = value.tasks[0];
    task.activeOperation = null;
    task.currentRunId = "0";
    task.currentRunPhase = null;
    task.runs[0].phase = "failed";
    task.runs[0].activity = null;
    task.runs[0].terminal = expected;
    assert.deepEqual(
      decodeWorkbenchSnapshot(value).tasks[0].runs[0].terminal,
      expected,
    );
  }
});

test("Task model intent is a source-qualified durable fact independent of installed and default models", () => {
  const snapshot = clone(fixture);
  snapshot.tasks[0].modelIntent = {
    modelRef: { sourceId: "another-provider", modelId: "next-model" },
    selectionRevision: "9",
    state: "committed",
  };
  assert.deepEqual(decodeWorkbenchSnapshot(snapshot), snapshot);
  assert.notEqual(
    snapshot.tasks[0].modelIntent.modelRef.modelId,
    snapshot.tasks[0].binding.model,
  );
  // A legacy record must not inherit a source from today's global catalog.
  snapshot.tasks[0].modelIntent = null;
  assert.equal(decodeWorkbenchSnapshot(snapshot).tasks[0].modelIntent, null);
});

test("Task model intent rejects missing or extended wire shapes and invalid revisions", () => {
  const valid = {
    modelRef: { sourceId: "provider", modelId: "model" },
    selectionRevision: "1",
    state: "committed",
  };
  const missing = clone(fixture);
  delete missing.tasks[0].modelIntent;
  assert.throws(() => decodeWorkbenchSnapshot(missing), /modelIntent/);
  for (const invalid of [
    {},
    { ...valid, modelRef: null },
    { ...valid, modelRef: { sourceId: "provider" } },
    { ...valid, modelRef: { sourceId: "", modelId: "model" } },
    { ...valid, modelRef: { ...valid.modelRef, apiKey: "forbidden" } },
    { ...valid, credential: "forbidden" },
    ...["0", "01", "-1", "18446744073709551616", 1, null].map(
      (selectionRevision) => ({ ...valid, selectionRevision }),
    ),
  ]) {
    const bad = clone(fixture);
    bad.tasks[0].modelIntent = invalid;
    assert.throws(() => decodeWorkbenchSnapshot(bad), /modelIntent/);
  }
});

test("Task model selection availability is a strict Host-owned projection", () => {
  for (const availability of [
    "available",
    "catalog_loading",
    "catalog_unavailable",
    "task_unavailable",
  ]) {
    const snapshot = clone(fixture);
    snapshot.tasks[0].modelSelectionAvailability = availability;
    assert.deepEqual(decodeWorkbenchSnapshot(snapshot), snapshot);
  }

  for (const retired of [
    "execution_replacing",
    "runtime_detached",
    "unsupported_source",
    "authority_changed",
  ]) {
    const snapshot = clone(fixture);
    snapshot.tasks[0].modelSelectionAvailability = retired;
    assert.throws(
      () => decodeWorkbenchSnapshot(snapshot),
      /modelSelectionAvailability/,
    );
  }

  const missing = clone(fixture);
  delete missing.tasks[0].modelSelectionAvailability;
  assert.throws(
    () => decodeWorkbenchSnapshot(missing),
    /modelSelectionAvailability/,
  );

  const unknown = clone(fixture);
  unknown.tasks[0].modelSelectionAvailability = "provider_failed";
  assert.throws(
    () => decodeWorkbenchSnapshot(unknown),
    /modelSelectionAvailability/,
  );
});

test("Automatic Workspace current catalog uses the Host authority without project controls", () => {
  const automatic = clone(fixture);
  automatic.workspaces[0].kind = "automatic";
  automatic.workspaces[0].recentOrder = "0";
  automatic.workspaces[0].skillCatalog.availability = "unavailable";
  assert.deepEqual(decodeWorkbenchSnapshot(automatic), automatic);
  automatic.workspaces[0].skillCatalog.availability = "loading";
  assert.deepEqual(decodeWorkbenchSnapshot(automatic), automatic);
  automatic.workspaces[0].recentOrder = "1";
  assert.throws(() => decodeWorkbenchSnapshot(automatic), /Task-owned/);
});

test("automatic Workspace projection is one-to-one and capability-gated", () => {
  const automatic = clone(fixture);
  automatic.capabilities.automaticWorkspaces = true;
  automatic.workspaces.push({
    ...clone(fixture.workspaces[0]),
    id: "9",
    kind: "automatic",
    displayName: "Automatic workspace",
    canonicalRoot: "/data/workspaces/0000000000000009",
    recentOrder: "0",
    signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
  });
  automatic.tasks.push({
    ...clone(fixture.tasks[0]),
    id: "4",
    recentOrder: "2",
    workspaceId: "9",
  });
  assert.deepEqual(decodeWorkbenchSnapshot(automatic), automatic);

  const missingOwner = clone(automatic);
  missingOwner.tasks.pop();
  assert.throws(
    () => decodeWorkbenchSnapshot(missingOwner),
    /exactly one Task/,
  );

  const unavailable = clone(automatic);
  unavailable.capabilities.automaticWorkspaces = false;
  assert.deepEqual(decodeWorkbenchSnapshot(unavailable), unavailable);
});

test("Skill catalogs and typed Skill history decode without exposing loader internals", () => {
  const withSkill = clone(fixture);
  const catalog = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/skill-catalog-ready.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  withSkill.workspaces[0].skillCatalog = catalog;
  withSkill.tasks[0].skillCatalog = clone(catalog);
  withSkill.tasks[0].runs[0].input = {
    kind: "skill",
    skillId: "builtin.review",
    catalogRevision: "catalog-revision",
    invocationName: "review",
    displayName: "Review",
    argumentValues: ["src/main.zig", "correctness"],
    redacted: false,
  };
  assert.deepEqual(decodeWorkbenchSnapshot(withSkill), withSkill);
  assert.equal(JSON.stringify(withSkill).includes("skillBody"), false);
  assert.equal(JSON.stringify(withSkill).includes("sourcePath"), false);

  const staleProjection = clone(withSkill);
  staleProjection.tasks[0].skillCatalog.availability = "unavailable";
  assert.throws(
    () => decodeWorkbenchSnapshot(staleProjection),
    /availability and revision must agree/,
  );

  const duplicateIdentity = clone(withSkill);
  duplicateIdentity.tasks[0].skillCatalog.skills.push(
    clone(duplicateIdentity.tasks[0].skillCatalog.skills[0]),
  );
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateIdentity),
    /identities must be unique/,
  );
});

test("Host Schedule projection fixture keeps the current Renderer contract", () => {
  const scheduled = clone(fixture);
  Object.assign(scheduled.capabilities, {
    scheduledTasks: true,
    scheduledTaskPersistence: true,
    scheduledTaskPersistenceHealth: "ready",
    backgroundScheduleWake: true,
  });
  scheduled.scheduledTasks = JSON.parse(
    readFileSync(
      new URL(
        "../src/product/schedule/renderer_projection.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const decoded = decodeWorkbenchSnapshot(scheduled);
  assert.deepEqual(decoded.scheduledTasks, scheduled.scheduledTasks);
  assert.deepEqual(
    decoded.scheduledTasks.map((task) => task.id),
    ["1", "2", "3", "4", "5"],
  );
  assert.deepEqual(
    decoded.scheduledTasks.map((task) => task.recurrence.kind),
    ["calendar", "once", "calendar", "interval", "calendar"],
  );
});

test("Scheduled Task projection decodes recurrence and occurrence without secrets", () => {
  const scheduled = clone(fixture);
  scheduled.capabilities.scheduledTasks = true;
  scheduled.capabilities.scheduledTaskPersistence = true;
  scheduled.capabilities.scheduledTaskPersistenceHealth = "ready";
  scheduled.capabilities.backgroundScheduleWake = true;
  scheduled.tasks[0].runs[0].permissionInteraction = "noninteractive";
  scheduled.scheduledTasks = [
    {
      id: "8",
      epoch: "2",
      title: "Daily summary",
      titleRedacted: false,
      permissionProfile: "approval_required",
      enabled: true,
      health: "ready",
      failureReason: null,
      binding: {
        status: "bound",
        modelRef: { sourceId: "metask", modelId: "fixture-model" },
        sourceGeneration: "1",
        protocol: "openai_chat_completions",
      },
      input: {
        kind: "text",
        text: "Summarize src",
        redacted: false,
      },
      recurrence: {
        kind: "interval",
        startAtUnixSeconds: "1800000000",
        everySeconds: "3600",
      },
      nextRunAtUnixSeconds: "1800003600",
      occurrences: [
        {
          plannedAtUnixSeconds: "1800000000",
          triggeredAtUnixSeconds: "1800000001",
          source: "timer",
          result: "submitted",
          taskId: "3",
          reason: null,
          taskOutcome: null,
        },
      ],
    },
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(scheduled), scheduled);

  const blockerHistory = clone(scheduled);
  blockerHistory.scheduledTasks[0].occurrences = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/scheduled-occurrences.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(decodeWorkbenchSnapshot(blockerHistory), blockerHistory);
  const invalidBlocker = clone(blockerHistory);
  invalidBlocker.scheduledTasks[0].occurrences[1].reason = "capacity_reached";
  assert.throws(() => decodeWorkbenchSnapshot(invalidBlocker), /blocker Task/);

  const retiredRevision = clone(scheduled);
  retiredRevision.scheduledTasks[0].binding.selectionRevision = "3";
  assert.throws(() => decodeWorkbenchSnapshot(retiredRevision));

  const retiredMigrationShape = clone(scheduled);
  retiredMigrationShape.scheduledTasks[0].enabled = false;
  retiredMigrationShape.scheduledTasks[0].health = "needs_attention";
  retiredMigrationShape.scheduledTasks[0].failureReason =
    "binding_migration_required";
  retiredMigrationShape.scheduledTasks[0].binding = {
    status: "migration_required",
    legacyExecution: {
      generation: "19",
      protocol: "anthropic_messages",
      model: "legacy-model",
    },
  };
  retiredMigrationShape.scheduledTasks[0].nextRunAtUnixSeconds = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredMigrationShape),
    /expected keys|unexpected enum value/,
  );

  const updatedDefinitionProfile = clone(scheduled);
  updatedDefinitionProfile.scheduledTasks[0].permissionProfile = "full_access";
  assert.deepEqual(
    decodeWorkbenchSnapshot(updatedDefinitionProfile),
    updatedDefinitionProfile,
  );

  const permissionRequired = clone(scheduled);
  permissionRequired.scheduledTasks[0].enabled = false;
  permissionRequired.scheduledTasks[0].health = "needs_attention";
  permissionRequired.scheduledTasks[0].failureReason = "permission_required";
  permissionRequired.scheduledTasks[0].nextRunAtUnixSeconds = null;
  permissionRequired.scheduledTasks[0].occurrences[0].reason =
    "permission_required";
  permissionRequired.scheduledTasks[0].occurrences[0].taskOutcome = "stopped";
  assert.deepEqual(
    decodeWorkbenchSnapshot(permissionRequired),
    permissionRequired,
  );

  const unavailableTask = clone(scheduled);
  unavailableTask.scheduledTasks[0].occurrences[0].taskOutcome = "unavailable";
  assert.deepEqual(decodeWorkbenchSnapshot(unavailableTask), unavailableTask);

  const rejectedAfterTaskCreation = clone(scheduled);
  rejectedAfterTaskCreation.scheduledTasks[0].occurrences[0] = {
    ...rejectedAfterTaskCreation.scheduledTasks[0].occurrences[0],
    result: "rejected",
    reason: "capacity_reached",
  };
  assert.deepEqual(
    decodeWorkbenchSnapshot(rejectedAfterTaskCreation),
    rejectedAfterTaskCreation,
  );

  const rejectedWithoutReason = clone(rejectedAfterTaskCreation);
  rejectedWithoutReason.scheduledTasks[0].occurrences[0].reason = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(rejectedWithoutReason),
    /rejected occurrence requires a reason/,
  );

  const configuredWorkspace = clone(scheduled);
  configuredWorkspace.scheduledTasks[0].target = { kind: "default" };
  assert.throws(
    () => decodeWorkbenchSnapshot(configuredWorkspace),
    /expected keys/,
  );

  const textTarget = clone(scheduled);
  textTarget.scheduledTasks[0].input = {
    kind: "text",
    text: "Summarize current work",
    redacted: false,
  };
  assert.deepEqual(decodeWorkbenchSnapshot(textTarget), textTarget);

  const configuredSkill = clone(scheduled);
  configuredSkill.scheduledTasks[0].input = {
    kind: "skill",
    skillId: "builtin.summary",
    catalogRevision: "catalog-4",
    argumentValues: ["src"],
    redacted: false,
  };
  assert.throws(
    () => decodeWorkbenchSnapshot(configuredSkill),
    /unexpected scheduled Task input kind/,
  );

  const invalid = clone(scheduled);
  invalid.scheduledTasks[0].recurrence.cron = "* * * * *";
  assert.throws(() => decodeWorkbenchSnapshot(invalid), /expected keys/);
});

test("MCP management is capability-gated and identity checked", () => {
  const withMcp = clone(fixture);
  withMcp.capabilities.mcpManagement = true;
  withMcp.capabilities.mcpConnectionApproval = true;
  withMcp.capabilities.mcpSecretCapture = true;
  withMcp.capabilities.mcpSecretMaxBytes = 4096;
  withMcp.capabilities.mcpOAuth = true;
  withMcp.mcp = {
    availability: "degraded",
    managementHealth: "ready",
    operation: "idle",
    configurationApply: "idle",
    retainedMemberCount: 0,
    applyFailureCount: 0,
    runtimeUncertain: false,
    runtimeTimeoutLimitMs: 120000,
    authorizationOperation: { kind: "idle" },
    desiredGeneration: "1",
    runtimeAlignment: "current",
    redacted: false,
    servers: [
      {
        id: "github-binding",
        displayName: "GitHub",
        namespace: "github",
        transport: "streamable_http",
        authMode: "oauth",
        negotiation: "automatic",
        timeoutMs: 30_000,
        taskReferenceCount: 0,
        applyStatus: "current",
        connection: {
          kind: "streamable_http",
          endpoint: "https://github.example/mcp",
          headers: [],
          registrationKind: "automatic",
          clientId: null,
          tokenEndpointAuthMethod: null,
          clientSecretStatus: "not_required",
        },
        approvalStatus: "approved",
        authorizationStatus: "ready",
        canAuthorize: false,
        desiredEnabled: true,
        runtimeStatus: "ready",
        newTaskAccess: "available",
        safeDiagnostic: "",
        connectionTest: { status: "untested", toolCount: 0, issueCount: 0 },
        tools: [
          {
            name: "search_repositories",
            discovered: true,
            desiredAllowed: true,
            availableToNewTasks: true,
          },
        ],
      },
      {
        id: "notion-binding",
        displayName: "Notion",
        namespace: "notion",
        transport: "streamable_http",
        authMode: "oauth",
        negotiation: "automatic",
        timeoutMs: 30_000,
        taskReferenceCount: 0,
        applyStatus: "current",
        connection: {
          kind: "streamable_http",
          endpoint: "https://notion.example/mcp",
          headers: [],
          registrationKind: "automatic",
          clientId: null,
          tokenEndpointAuthMethod: null,
          clientSecretStatus: "not_required",
        },
        approvalStatus: "approved",
        authorizationStatus: "reauth_required",
        canAuthorize: true,
        desiredEnabled: true,
        runtimeStatus: "needs_authentication",
        newTaskAccess: "unavailable",
        safeDiagnostic: "Sign in again.",
        connectionTest: { status: "untested", toolCount: 0, issueCount: 0 },
        tools: [],
      },
    ],
  };
  assert.deepEqual(decodeWorkbenchSnapshot(withMcp), withMcp);

  for (const limit of [
    undefined,
    null,
    "4096",
    -1,
    0,
    1.5,
    NaN,
    Infinity,
    Number.MAX_SAFE_INTEGER + 1,
  ]) {
    const invalidLimit = clone(withMcp);
    invalidLimit.capabilities.mcpSecretMaxBytes = limit;
    assert.throws(
      () => decodeWorkbenchSnapshot(invalidLimit),
      /mcpSecretMaxBytes/,
    );
  }
  const unavailableWithLimit = clone(fixture);
  unavailableWithLimit.capabilities.mcpSecretMaxBytes = 4096;
  assert.throws(
    () => decodeWorkbenchSnapshot(unavailableWithLimit),
    /mcpSecretMaxBytes/,
  );

  const hiddenCatalog = clone(withMcp);
  hiddenCatalog.capabilities.mcpManagement = false;
  assert.throws(
    () => decodeWorkbenchSnapshot(hiddenCatalog),
    /MCP secret byte limit must be positive when management is enabled and zero otherwise/,
  );

  const duplicateServer = clone(withMcp);
  duplicateServer.mcp.servers.push(clone(duplicateServer.mcp.servers[0]));
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateServer),
    /server identities must be unique/,
  );

  const duplicateTool = clone(withMcp);
  duplicateTool.mcp.servers[0].tools.push(
    clone(duplicateTool.mcp.servers[0].tools[0]),
  );
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateTool),
    /tool names must be unique/,
  );

  const falselyReady = clone(withMcp);
  falselyReady.mcp.availability = "ready";
  assert.throws(
    () => decodeWorkbenchSnapshot(falselyReady),
    /cannot contain attention states/,
  );

  const unavailableLeak = clone(withMcp);
  unavailableLeak.capabilities.mcpManagement = false;
  unavailableLeak.mcp.availability = "unavailable";
  assert.throws(
    () => decodeWorkbenchSnapshot(unavailableLeak),
    /MCP secret byte limit must be positive when management is enabled and zero otherwise/,
  );

  for (const key of ["retainedMemberCount", "applyFailureCount"]) {
    for (const value of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1]) {
      const invalid = clone(withMcp);
      invalid.mcp[key] = value;
      assert.throws(() => decodeWorkbenchSnapshot(invalid), new RegExp(key));
    }
  }
  const retained = clone(withMcp);
  const disabled = retained.mcp.servers[0];
  Object.assign(disabled, {
    desiredEnabled: false,
    runtimeStatus: "disabled",
    newTaskAccess: "not_allowed",
    taskReferenceCount: 2,
  });
  disabled.tools.forEach((tool) => {
    tool.availableToNewTasks = false;
  });
  assert.throws(() => decodeWorkbenchSnapshot(retained), /retained members/);
  retained.mcp.retainedMemberCount = 1;
  assert.deepEqual(decodeWorkbenchSnapshot(retained), retained);
  retained.mcp.retainedMemberCount = 2; // Deleted retained members have no Desired row.
  assert.deepEqual(decodeWorkbenchSnapshot(retained), retained);
  const failed = clone(withMcp);
  Object.assign(failed.mcp.servers[0], {
    applyStatus: "rejected",
    runtimeStatus: "not_loaded",
    newTaskAccess: "unavailable",
    tools: [],
  });
  assert.throws(() => decodeWorkbenchSnapshot(failed), /failure count/);
  failed.mcp.applyFailureCount = 1;
  assert.deepEqual(decodeWorkbenchSnapshot(failed), failed);
  failed.mcp.servers[0].applyStatus = "capacity";
  assert.deepEqual(decodeWorkbenchSnapshot(failed), failed);
  failed.mcp.applyFailureCount = 0;
  assert.throws(() => decodeWorkbenchSnapshot(failed), /failure count/);
  const recoveryProjections = JSON.parse(
    readFileSync(
      new URL(
        "../src/product/mcp/testdata/oauth-recovery-view.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  for (const projection of Object.values(recoveryProjections)) {
    const recovering = clone(withMcp);
    const server = recovering.mcp.servers[1];
    Object.assign(server, projection, {
      runtimeStatus: "not_loaded",
      newTaskAccess: "unavailable",
      tools: [],
    });
    recovering.mcp.applyFailureCount = ["rejected", "failed"].includes(
      projection.applyStatus,
    )
      ? 1
      : 0;
    assert.deepEqual(decodeWorkbenchSnapshot(recovering), recovering);
    delete server.canAuthorize;
    assert.throws(() => decodeWorkbenchSnapshot(recovering), /canAuthorize/);
    server.canAuthorize = "yes";
    assert.throws(() => decodeWorkbenchSnapshot(recovering), /canAuthorize/);
  }
  const applying = clone(withMcp);
  applying.mcp.configurationApply = "applying";
  for (const server of applying.mcp.servers) server.applyStatus = "applying";
  assert.throws(() => decodeWorkbenchSnapshot(applying), /single-member/);
  const unknownRuntime = clone(withMcp);
  unknownRuntime.mcp.runtimeUncertain = true;
  unknownRuntime.mcp.runtimeAlignment = "unknown";
  unknownRuntime.mcp.availability = "unavailable";
  assert.throws(
    () => decodeWorkbenchSnapshot(unknownRuntime),
    /unknown Runtime takeover/,
  );
  for (const server of unknownRuntime.mcp.servers)
    Object.assign(server, {
      applyStatus: "unknown",
      runtimeStatus: "not_loaded",
      newTaskAccess: "unavailable",
      tools: [],
    });
  assert.deepEqual(decodeWorkbenchSnapshot(unknownRuntime), unknownRuntime);

  const unknownDesired = clone(withMcp);
  unknownDesired.mcp.managementHealth = "outcome_unknown";
  unknownDesired.mcp.desiredGeneration = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(unknownDesired),
    /unknown desired state must hide alignment and servers/,
  );
});

test("Host untrusted MCP projections pass the strict snapshot decoder", () => {
  const projections = JSON.parse(
    readFileSync(
      new URL(
        "../src/product/mcp/testdata/untrusted-view.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  for (const projection of Object.values(projections)) {
    const snapshot = clone(fixture);
    snapshot.capabilities.mcpManagement = true;
    snapshot.capabilities.mcpSecretMaxBytes = 4096;
    snapshot.mcp = projection;
    assert.deepEqual(decodeWorkbenchSnapshot(snapshot).mcp, projection);
  }
});

test("MCP create receipts require committed identity and reject invented identity", () => {
  const rejected = JSON.parse(
    readFileSync(
      new URL(
        "../src/bridge/testdata/mcp-create-rejected.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(decodeMcpCreateResult(rejected), {
    outcome: "rejected",
    desiredGeneration: null,
    serverId: null,
  });
  assert.deepEqual(
    decodeMcpCreateResult({
      outcome: "saved",
      desiredGeneration: "12",
      serverId: "created-1",
    }),
    { outcome: "saved", desiredGeneration: "12", serverId: "created-1" },
  );
  for (const value of [
    { outcome: "saved", desiredGeneration: "12", serverId: null },
    { outcome: "rejected", desiredGeneration: "12", serverId: "invented" },
    { outcome: "indeterminate", desiredGeneration: null, serverId: "invented" },
    { outcome: "saved", desiredGeneration: "12" },
  ])
    assert.throws(() => decodeMcpCreateResult(value));
});

test("MCP command results preserve persistence certainty and refresh admission", () => {
  assert.deepEqual(
    decodeMcpMutationResult({ outcome: "saved", desiredGeneration: "12" }),
    { outcome: "saved", desiredGeneration: "12" },
  );
  assert.deepEqual(
    decodeMcpMutationResult({
      outcome: "indeterminate",
      desiredGeneration: null,
    }),
    { outcome: "indeterminate", desiredGeneration: null },
  );
  assert.throws(
    () =>
      decodeMcpMutationResult({
        outcome: "indeterminate",
        desiredGeneration: "12",
      }),
    /cannot claim generation/,
  );
  assert.deepEqual(decodeMcpRefreshResult({ outcome: "started" }), {
    outcome: "started",
  });
  assert.throws(
    () => decodeMcpRefreshResult({ outcome: "started", generation: "1" }),
    /expected keys/,
  );
});

test("Account command acknowledgements preserve state-machine and attempt identity", () => {
  assert.deepEqual(
    decodeAccountCommandResult({
      accepted: false,
      errorCode: "refresh_schedule_failed",
      attemptId: null,
    }),
    {
      accepted: false,
      errorCode: "refresh_schedule_failed",
      attemptId: null,
    },
  );
  assert.deepEqual(
    decodeAccountCommandResult({
      accepted: true,
      errorCode: "none",
      attemptId: "41",
    }),
    { accepted: true, errorCode: "none", attemptId: "41" },
  );
  assert.deepEqual(
    decodeAccountCommandResult({
      accepted: false,
      errorCode: "invalid_state",
      attemptId: null,
    }),
    { accepted: false, errorCode: "invalid_state", attemptId: null },
  );
  assert.throws(
    () =>
      decodeAccountCommandResult({
        accepted: true,
        errorCode: "invalid_state",
        attemptId: null,
      }),
    /must agree/,
  );
  assert.throws(
    () =>
      decodeAccountCommandResult({
        accepted: false,
        errorCode: "invalid_state",
        attemptId: "41",
      }),
    /cannot expose an attempt/,
  );
});

test("Execution command acknowledgements stay outside the Account error domain", () => {
  assert.deepEqual(
    decodeExecutionCommandResult({
      accepted: false,
      errorCode: "custom_provider_persistence_unavailable",
      attemptId: null,
    }),
    {
      accepted: false,
      errorCode: "custom_provider_persistence_unavailable",
      attemptId: null,
    },
  );
  assert.throws(
    () =>
      decodeAccountCommandResult({
        accepted: false,
        errorCode: "custom_provider_persistence_unavailable",
        attemptId: null,
      }),
    /unexpected value/,
  );
  assert.throws(
    () =>
      decodeExecutionCommandResult({
        accepted: false,
        errorCode: "custom_provider_invalid",
        attemptId: "41",
      }),
    /expected null/,
  );
});

test("Task metadata mutation acknowledgements are identity-checked and exact", () => {
  assert.deepEqual(
    decodeTaskCreateResult({
      accepted: true,
      taskId: "3",
      bindingEpoch: "7",
      mcpAuthority: { kind: "ready", selection: "none" },
      reason: null,
    }),
    {
      accepted: true,
      taskId: "3",
      bindingEpoch: "7",
      mcpAuthority: { kind: "ready", selection: "none" },
      reason: null,
    },
  );
  assert.throws(
    () =>
      decodeTaskCreateResult({
        accepted: true,
        taskId: "3",
        bindingEpoch: "7",
        mcpAuthority: { kind: "unavailable", selection: "none" },
        reason: null,
      }),
    /cannot have a selection/,
  );
  assert.throws(
    () =>
      decodeTaskCreateResult({
        accepted: false,
        taskId: null,
        bindingEpoch: null,
        mcpAuthority: { kind: "unavailable", selection: null },
        reason: "catalog_loading",
      }),
    /cannot expose identities/,
  );
  assert.throws(() => decodeTaskCreateResult({ taskId: "3" }), /expected keys/);
  assert.deepEqual(
    decodeTaskRunResult(
      {
        accepted: false,
        taskId: "3",
        runId: null,
        reason: "binding_changed",
      },
      "3",
    ),
    {
      accepted: false,
      taskId: "3",
      runId: null,
      reason: "binding_changed",
    },
  );
  assert.deepEqual(
    decodeTaskCompactResult(
      {
        accepted: true,
        taskId: "3",
        operationId: "11",
        reason: null,
      },
      "3",
    ),
    {
      accepted: true,
      taskId: "3",
      operationId: "11",
      reason: null,
    },
  );
  assert.deepEqual(
    decodeTaskRestoreResult(
      {
        accepted: true,
        taskId: "3",
        attemptId: "12",
        reason: null,
      },
      "3",
    ),
    {
      accepted: true,
      taskId: "3",
      attemptId: "12",
      reason: null,
    },
  );
  assert.deepEqual(
    decodeTaskRestoreResult(
      {
        accepted: false,
        taskId: "3",
        attemptId: null,
        reason: "recovery_unavailable",
      },
      "3",
    ),
    {
      accepted: false,
      taskId: "3",
      attemptId: null,
      reason: "recovery_unavailable",
    },
  );
  assert.throws(
    () =>
      decodeTaskRestoreResult(
        {
          accepted: true,
          taskId: "3",
          attemptId: null,
          reason: null,
        },
        "3",
      ),
    /expected string/,
  );
  assert.doesNotThrow(() =>
    assertTaskFlag({ taskId: "3", renamed: true }, "3", "renamed"),
  );
  assert.doesNotThrow(() =>
    assertTaskFlag({ taskId: "3", deleting: true }, "3", "deleting"),
  );
  assert.doesNotThrow(() =>
    assertTaskArchived({ taskId: "3", archived: false }, "3", false),
  );
  assert.throws(
    () => assertTaskFlag({ taskId: "4", renamed: true }, "3", "renamed"),
    /response mismatch/,
  );
  assert.throws(
    () =>
      assertTaskArchived(
        { taskId: "3", archived: true, compatibility: true },
        "3",
        true,
      ),
    /expected keys/,
  );
});

test("new Task admission rejects retired execution fields and inconsistent generic gates", () => {
  for (const field of [
    "activeProtocol",
    "activeModelRef",
    "activeExecutionGeneration",
    "activeSelectionRevision",
    "state",
  ]) {
    const snapshot = clone(fixture);
    snapshot.newTaskAdmission[field] = null;
    assert.throws(() => decodeWorkbenchSnapshot(snapshot), /expected keys/);
  }
  for (const gate of [
    { available: true, reason: "workspace_unavailable" },
    { available: false, reason: "none" },
    { available: false, reason: "invalid_candidate" },
  ]) {
    const snapshot = clone(fixture);
    snapshot.newTaskAdmission = gate;
    assert.throws(() => decodeWorkbenchSnapshot(snapshot));
  }
  const snapshot = clone(fixture);
  snapshot.newTaskAdmission = { available: false, reason: "shutting_down" };
  assert.deepEqual(decodeWorkbenchSnapshot(snapshot), snapshot);
});

test("Custom Provider readiness survives an isolated failed retest", () => {
  const snapshot = clone(fixture);
  snapshot.account = {
    state: "signed_out",
    canCancel: false,
    accountId: "",
    displayName: "",
    emailHint: "",
    phoneHint: "",
    concurrencyLimit: null,
    errorCode: "none",
    safeDiagnostic: "",
    summary: emptyAccountSummary,
  };
  const customMetadata = clone(snapshot.models.providers[0].models[0].metadata);
  snapshot.models = {
    ...snapshot.models,
    availability: "ready",
    providers: [],
    defaultSelection: { sourceId: "provider-1", modelId: "gpt-5" },
    builtinProviderPresets: [],
    customProviders: [
      {
        id: "provider-1",
        builtinProviderId: null,
        displayName: "OpenAI",
        protocol: "openai_chat_completions",
        normalizedBaseUrl: "https://api.openai.com/v1/chat/completions",
        state: "ready",
        credentialStatus: "ready",
        enabled: true,
        providerRevision: "1",
        sourceGeneration: "2",
        catalogGeneration: "3",
        models: [
          {
            id: "gpt-5",
            displayName: "GPT-5",
            metadata: customMetadata,
            metadataProvenance: "user_declared",
            testStatus: "failed",
            ready: true,
          },
        ],
      },
    ],
  };
  snapshot.newTaskAdmission = { available: true, reason: "none" };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(snapshot));

  const neverVerified = clone(snapshot);
  neverVerified.models.customProviders[0].models[0].ready = false;
  assert.throws(
    () => decodeWorkbenchSnapshot(neverVerified),
    /ready provider must be verified/,
  );

  const impossibleConnected = clone(snapshot);
  impossibleConnected.models.customProviders[0].state = "configuring";
  assert.throws(
    () => decodeWorkbenchSnapshot(impossibleConnected),
    /only a ready provider can retain model readiness/,
  );
});

test("Conversation recovery projection is one coherent continuation state", () => {
  const recoverable = clone(fixture);
  const task = recoverable.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "interrupted";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("interrupted", "app_shutdown");
  task.binding.availability = "unavailable";
  task.binding.unavailableReason = "runtime_detached";
  task.continuationAvailable = false;
  task.continuationUnavailableReason = "session_recovery_required";
  task.continuationRecoveryAvailable = true;
  assert.deepEqual(decodeWorkbenchSnapshot(recoverable), recoverable);

  const restoring = clone(recoverable);
  restoring.tasks[0].activeOperation = { kind: "restore", id: "12" };
  restoring.tasks[0].continuationUnavailableReason =
    "session_recovery_in_progress";
  restoring.tasks[0].continuationRecoveryAvailable = false;
  assert.deepEqual(decodeWorkbenchSnapshot(restoring), restoring);

  const rebindRequired = clone(recoverable);
  rebindRequired.tasks[0].continuationUnavailableReason =
    "execution_rebind_required";
  rebindRequired.tasks[0].continuationRecoveryAvailable = false;
  assert.deepEqual(decodeWorkbenchSnapshot(rebindRequired), rebindRequired);

  const retiredReason = clone(rebindRequired);
  retiredReason.tasks[0].continuationUnavailableReason = "execution_mismatch";
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredReason),
    /continuationUnavailableReason: unexpected value for enum/,
  );

  const missingOperation = clone(restoring);
  missingOperation.tasks[0].activeOperation = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(missingOperation),
    /requires an active recovery operation/,
  );

  const contradictory = clone(recoverable);
  contradictory.tasks[0].continuationAvailable = true;
  contradictory.tasks[0].continuationUnavailableReason = null;
  contradictory.tasks[0].binding.availability = "available";
  contradictory.tasks[0].binding.unavailableReason = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(contradictory),
    /recovery availability must describe an eligible detached Task/,
  );
});

test("Task deletion exposes one product-level progress and retry fact", () => {
  const deleting = clone(fixture);
  deleting.tasks[0].archived = true;
  deleting.tasks[0].lifecycle = "closing";
  deleting.tasks[0].deletionStatus = "deleting";
  deleting.tasks[0].activeOperation = null;
  deleting.tasks[0].currentRunId = "0";
  deleting.tasks[0].currentRunPhase = null;
  deleting.tasks[0].runs[0].phase = "completed";
  deleting.tasks[0].runs[0].activity = null;
  deleting.tasks[0].runs[0].terminal = terminal("completed");
  deleting.tasks[0].continuationAvailable = false;
  deleting.tasks[0].continuationUnavailableReason = "closing";
  assert.deepEqual(decodeWorkbenchSnapshot(deleting), deleting);

  const retryable = clone(deleting);
  retryable.tasks[0].deletionStatus = "failed";
  assert.deepEqual(decodeWorkbenchSnapshot(retryable), retryable);

  const unarchived = clone(retryable);
  unarchived.tasks[0].archived = false;
  assert.deepEqual(decodeWorkbenchSnapshot(unarchived), unarchived);
  unarchived.tasks[0].deletionStatus = "deleting";
  assert.deepEqual(decodeWorkbenchSnapshot(unarchived), unarchived);
  unarchived.tasks[0].lifecycle = "open";
  assert.throws(
    () => decodeWorkbenchSnapshot(unarchived),
    /invalid deletion facts/,
  );
});

test("Compact projection is append-only and mutually exclusive with Run work", () => {
  const accepted = decodeTaskCompactResult(
    {
      accepted: true,
      taskId: "3",
      operationId: "11",
      reason: null,
    },
    "3",
  );
  assert.equal(accepted.operationId, "11");

  const compacted = clone(fixture);
  const task = compacted.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "completed";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("completed");
  task.compacts.push({
    operationId: "11",
    afterRunId: "7",
    conversationCoverage: "included",
    phase: "compacted",
    cause: null,
    beforeContextTokens: "100",
    afterContextTokens: "40",
    usage: { input: "5", output: "2", cacheRead: "0", cacheCreation: "0" },
  });
  assert.deepEqual(decodeWorkbenchSnapshot(compacted), compacted);

  const active = clone(compacted);
  active.tasks[0].compacts[0].phase = "compacting";
  active.tasks[0].compacts[0].beforeContextTokens = "0";
  active.tasks[0].compacts[0].afterContextTokens = "0";
  active.tasks[0].activeOperation = { kind: "compact", id: "11" };
  assert.deepEqual(decodeWorkbenchSnapshot(active), active);

  const queueFailure = clone(compacted);
  queueFailure.tasks[0].compacts[0].phase = "failed";
  queueFailure.tasks[0].compacts[0].cause = "resource_limit";
  queueFailure.tasks[0].compacts[0].beforeContextTokens = "0";
  queueFailure.tasks[0].compacts[0].afterContextTokens = "0";
  queueFailure.tasks[0].compacts[0].usage = {
    input: "0",
    output: "0",
    cacheRead: "0",
    cacheCreation: "0",
  };
  assert.deepEqual(decodeWorkbenchSnapshot(queueFailure), queueFailure);

  const archivedActive = clone(active);
  archivedActive.tasks[0].archived = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(archivedActive),
    /archived Task cannot have an active Compact/,
  );

  const closingActive = clone(active);
  closingActive.tasks[0].lifecycle = "closing";
  closingActive.tasks[0].continuationAvailable = false;
  closingActive.tasks[0].continuationUnavailableReason = "closing";
  closingActive.tasks[0].compacts[0].phase = "stopping";
  assert.deepEqual(decodeWorkbenchSnapshot(closingActive), closingActive);

  const simultaneous = clone(active);
  simultaneous.tasks[0].runs.push({
    ...clone(simultaneous.tasks[0].runs[0]),
    id: "8",
    phase: "running",
    activity: { kind: "waiting_model" },
    terminal: null,
  });
  simultaneous.tasks[0].currentRunId = "8";
  simultaneous.tasks[0].currentRunPhase = "running";
  assert.throws(
    () => decodeWorkbenchSnapshot(simultaneous),
    /inconsistent active Run/,
  );

  const invalidCause = clone(compacted);
  invalidCause.tasks[0].compacts[0].cause = "agent_failure";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidCause),
    /phase and cause must describe the same terminal state/,
  );
});

test("Agent output activity and Conversation context are strict typed facts", () => {
  const observed = clone(fixture);
  observed.tasks[0].runs[0].activity = {
    kind: "retrying_provider",
    attempt: "2",
    max: "3",
    delayMs: "250",
  };
  observed.tasks[0].context = {
    pressure: {
      sourceRunId: "7",
      currentTokens: "90",
      warningThreshold: "80",
      autoCompactThreshold: "100",
      blockingLimit: "120",
      severity: "warning",
    },
    lastAutoCompact: {
      sourceRunId: "7",
      dropped: "4",
      kept: "8",
      beforeTokens: "110",
      afterTokens: "70",
    },
  };
  assert.deepEqual(decodeWorkbenchSnapshot(observed), observed);

  const legacyOutput = clone(fixture);
  legacyOutput.tasks[0].runs[0].assistant = "legacy";
  assert.throws(() => decodeWorkbenchSnapshot(legacyOutput), /expected keys/);

  const flattenedCommentary = clone(fixture);
  flattenedCommentary.tasks[0].runs[0].output.commentary = "legacy";
  assert.throws(
    () => decodeWorkbenchSnapshot(flattenedCommentary),
    /expected array/,
  );

  const excessiveCommentary = clone(fixture);
  excessiveCommentary.tasks[0].runs[0].output.commentary = Array.from(
    { length: 257 },
    () => "update",
  );
  assert.throws(
    () => decodeWorkbenchSnapshot(excessiveCommentary),
    /too many commentary segments/,
  );

  const unclassifiedResponse = clone(fixture);
  unclassifiedResponse.tasks[0].runs[0].output.response = "answer";
  assert.throws(
    () => decodeWorkbenchSnapshot(unclassifiedResponse),
    /unclassified output cannot publish a response/,
  );

  const classifiedProvisional = clone(fixture);
  classifiedProvisional.tasks[0].runs[0].output.responseKind = "partial";
  classifiedProvisional.tasks[0].runs[0].output.provisional = "retry";
  assert.throws(
    () => decodeWorkbenchSnapshot(classifiedProvisional),
    /classified response cannot retain provisional output/,
  );

  const partialRetry = clone(observed);
  partialRetry.tasks[0].runs[0].activity.delayMs = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(partialRetry),
    /retry details must be either complete or absent/,
  );

  const impossiblePressure = clone(observed);
  impossiblePressure.tasks[0].context.pressure.severity = "critical";
  assert.throws(
    () => decodeWorkbenchSnapshot(impossiblePressure),
    /context severity disagrees with pressure/,
  );

  const foreignContext = clone(observed);
  foreignContext.tasks[0].context.lastAutoCompact.sourceRunId = "99";
  assert.throws(
    () => decodeWorkbenchSnapshot(foreignContext),
    /must reference projected Run history/,
  );
});

test("Workbench decoding rejects extra fields and invalid wire values", () => {
  const extraField = clone(fixture);
  extraField.compatibility = true;
  assert.throws(() => decodeWorkbenchSnapshot(extraField), /expected keys/);

  const enabledPermissionProfiles = clone(fixture);
  enabledPermissionProfiles.capabilities.permissionProfiles = true;
  enabledPermissionProfiles.permissions.availableProfiles = [
    "approval_required",
    "full_access",
  ];
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(enabledPermissionProfiles));

  const hiddenPermissionLeak = clone(fixture);
  hiddenPermissionLeak.permissions.availableProfiles = ["approval_required"];
  assert.throws(
    () => decodeWorkbenchSnapshot(hiddenPermissionLeak),
    /profile capability and available profiles must agree/,
  );

  const mismatchedPermissionProvenance = clone(fixture);
  mismatchedPermissionProvenance.tasks[0].runs[0].permissionProfile =
    "full_access";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedPermissionProvenance),
    /permission provenance must match/,
  );

  const invalidPermissionInteraction = clone(fixture);
  invalidPermissionInteraction.tasks[0].runs[0].permissionInteraction =
    "background";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidPermissionInteraction),
    /unexpected value/,
  );

  const invalidId = clone(fixture);
  invalidId.tasks[0].currentRunId = "07";
  assert.throws(() => decodeWorkbenchSnapshot(invalidId), /wire integer/);

  const invalidState = clone(fixture);
  invalidState.tasks[0].lifecycle = "recovering";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidState),
    /unexpected value/,
  );

  const secretField = clone(fixture);
  secretField.account.apiKey = "must-never-cross-Bridge";
  assert.throws(() => decodeWorkbenchSnapshot(secretField), /expected keys/);

  const legacyRunInput = clone(fixture);
  legacyRunInput.tasks[0].runs[0].user = "inspect";
  delete legacyRunInput.tasks[0].runs[0].input;
  assert.throws(() => decodeWorkbenchSnapshot(legacyRunInput), /expected keys/);

  const retiredRunTerminalFields = clone(fixture);
  retiredRunTerminalFields.tasks[0].runs[0].outcome = null;
  retiredRunTerminalFields.tasks[0].runs[0].cause = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredRunTerminalFields),
    /expected keys/,
  );

  const retiredTaskTerminalSummary = clone(fixture);
  retiredTaskTerminalSummary.tasks[0].lastRunOutcome = null;
  retiredTaskTerminalSummary.tasks[0].cause = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredTaskTerminalSummary),
    /expected keys/,
  );

  const missingRunExecution = clone(fixture);
  delete missingRunExecution.tasks[0].runs[0].execution;
  assert.throws(
    () => decodeWorkbenchSnapshot(missingRunExecution),
    /expected keys/,
  );

  const invalidExecutionGeneration = clone(fixture);
  invalidExecutionGeneration.tasks[0].runs[0].execution.generation = "0";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidExecutionGeneration),
    /positive wire integer/,
  );

  const invalidDiagnosticDisposition = clone(fixture);
  invalidDiagnosticDisposition.tasks[0].runs[0].phase = "failed";
  invalidDiagnosticDisposition.tasks[0].runs[0].activity = null;
  invalidDiagnosticDisposition.tasks[0].runs[0].terminal = terminal(
    "failed",
    "provider_failure",
    "raw",
  );
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidDiagnosticDisposition),
    /unexpected value/,
  );

  const missingTerminal = clone(fixture);
  missingTerminal.tasks[0].runs[0].phase = "failed";
  missingTerminal.tasks[0].runs[0].activity = null;
  missingTerminal.tasks[0].runs[0].terminal = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(missingTerminal),
    /failed Run phase and outcome must agree/,
  );

  const legacyAccountGeneration = clone(fixture);
  legacyAccountGeneration.account.metaskExecutionGeneration = "0";
  assert.throws(
    () => decodeWorkbenchSnapshot(legacyAccountGeneration),
    /expected keys/,
  );

  const readyAccountWithoutInstalledExecution = clone(fixture);
  readyAccountWithoutInstalledExecution.newTaskAdmission = {
    available: true,
    reason: "none",
  };
  assert.doesNotThrow(() =>
    decodeWorkbenchSnapshot(readyAccountWithoutInstalledExecution),
  );

  const retiredKeySelection = clone(fixture);
  retiredKeySelection.models.providers[0].selectedApiKeyId = "missing-key";
  assert.throws(
    () => decodeWorkbenchSnapshot(retiredKeySelection),
    /expected keys/,
  );

  const modelOutsideCatalog = clone(fixture);
  modelOutsideCatalog.models.defaultSelection.modelId = "missing-model";
  assert.equal(
    decodeWorkbenchSnapshot(modelOutsideCatalog).models.defaultSelection
      .modelId,
    "missing-model",
  );

  const mismatchedCancellation = clone(fixture);
  mismatchedCancellation.account.canCancel = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedCancellation),
    /cancellation requires active authorization/,
  );

  const authenticatedWithoutDisplayName = clone(fixture);
  authenticatedWithoutDisplayName.account.displayName = "";
  authenticatedWithoutDisplayName.account.emailHint = "";
  authenticatedWithoutDisplayName.account.phoneHint = "138****8000";
  authenticatedWithoutDisplayName.account.concurrencyLimit = null;
  assert.doesNotThrow(() =>
    decodeWorkbenchSnapshot(authenticatedWithoutDisplayName),
  );

  const diagnosticWithoutError = clone(fixture);
  diagnosticWithoutError.account.safeDiagnostic = "must have an error code";
  assert.throws(
    () => decodeWorkbenchSnapshot(diagnosticWithoutError),
    /safe diagnostic requires an Account error/,
  );

  const readySummary = clone(fixture);
  readySummary.account.summary = {
    operation: "idle",
    usageEligibility: "enabled",
    wallet: {
      availability: "ready",
      balanceU: "-1.25",
      syncedAt: "1720000000000",
      errorCode: "none",
      safeDiagnostic: "",
    },
    usage: {
      availability: "ready",
      today: {
        inputTokens: "10",
        outputTokens: "20",
        cacheCreationTokens: "3",
        cacheReadTokens: "4",
        totalTokens: "37",
        actualCostU: "0.125",
      },
      total: { totalTokens: "300", actualCostU: "2.5" },
      syncedAt: "1720000000000",
      errorCode: "none",
      safeDiagnostic: "",
    },
    history: {
      availability: "ready",
      startDate: "2025-09-15",
      endDate: "2026-09-15",
      days: [
        {
          date: "2026-09-14",
          inputTokens: "1",
          outputTokens: "2",
          cacheCreationTokens: "3",
          cacheReadTokens: "4",
          totalTokens: "10",
          actualCostU: "0.25",
        },
        {
          date: "2026-09-15",
          inputTokens: "10",
          outputTokens: "20",
          cacheCreationTokens: "30",
          cacheReadTokens: "40",
          totalTokens: "100",
          actualCostU: "2.5",
        },
      ],
      syncedAt: "1720000000000",
      errorCode: "none",
      safeDiagnostic: "",
    },
  };
  assert.deepEqual(decodeWorkbenchSnapshot(readySummary), readySummary);
  for (const mutate of [
    (value) => (value.account.summary.wallet.balanceU = 1.25),
    (value) => (value.account.summary.wallet.balanceU = "01.25"),
    (value) => (value.account.summary.usage.today = null),
    (value) => (value.account.summary.usage.total.actualCostU = "2.50"),
    (value) => (value.account.summary.usage.extra = true),
    (value) => (value.account.summary.history.days[0].date = "2026-02-30"),
    (value) => (value.account.summary.history.days[1].date = "2026-09-14"),
    (value) => (value.account.summary.history.days[0].totalTokens = "010"),
    (value) => (value.account.summary.history.startDate = null),
    (value) => (value.account.summary.history.startDate = "2025-09-17"),
  ]) {
    const invalid = clone(readySummary);
    mutate(invalid);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }

  const refreshingCatalog = clone(fixture);
  refreshingCatalog.models.operation = "refreshing_catalog";
  refreshingCatalog.models.availability = "loading";
  refreshingCatalog.models.providers[0].catalogState = "loading";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(refreshingCatalog));

  const signedOut = clone(fixture);
  signedOut.account = {
    state: "signed_out",
    canCancel: false,
    accountId: "",
    displayName: "",
    emailHint: "",
    phoneHint: "",
    concurrencyLimit: null,
    errorCode: "none",
    safeDiagnostic: "",
    summary: emptyAccountSummary,
  };
  signedOut.models.availability = "needs_authentication";
  signedOut.models.providers[0].catalogState = "needs_authentication";
  signedOut.models.providers[0].principalRef = "";
  signedOut.models.providers[0].models = [];
  signedOut.models.providers[0].catalogGeneration = "0";
  signedOut.models.providers[0].sourceGeneration = "0";
  signedOut.models.providers[0].errorCode = "authorization_unavailable";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(signedOut));

  const leakedSignedOutPhone = clone(signedOut);
  leakedSignedOutPhone.account.phoneHint = "138****8000";
  assert.throws(
    () => decodeWorkbenchSnapshot(leakedSignedOutPhone),
    /must hide identity/,
  );

  const leakedSignedOutSummary = clone(signedOut);
  leakedSignedOutSummary.account.summary = readySummary.account.summary;
  assert.throws(
    () => decodeWorkbenchSnapshot(leakedSignedOutSummary),
    /must hide its summary/,
  );

  const duplicateModel = clone(fixture);
  duplicateModel.models.providers[0].models = [
    {
      ...fixture.models.providers[0].models[0],
      id: "model-1",
      displayName: "One",
    },
    {
      ...fixture.models.providers[0].models[0],
      id: "model-1",
      displayName: "Two",
    },
  ];
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateModel),
    /identities must be unique/,
  );

  const revisionOneTask = clone(fixture);
  revisionOneTask.tasks[0].workspaceRoot = "/repo/legacy";
  delete revisionOneTask.tasks[0].workspaceId;
  assert.throws(
    () => decodeWorkbenchSnapshot(revisionOneTask),
    /expected keys/,
  );

  const unavailableContinuable = clone(fixture);
  unavailableContinuable.tasks[0].binding.availability = "unavailable";
  unavailableContinuable.tasks[0].binding.unavailableReason =
    "runtime_detached";
  assert.throws(
    () => decodeWorkbenchSnapshot(unavailableContinuable),
    /cannot accept future work/,
  );

  const leakedTaskIdentity = clone(fixture);
  leakedTaskIdentity.tasks[0].binding.accountId = "retired-account";
  assert.throws(
    () => decodeWorkbenchSnapshot(leakedTaskIdentity),
    /expected keys/,
  );

  const orphanHistory = clone(fixture);
  orphanHistory.workspaces = [];
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(orphanHistory));

  const missingField = clone(fixture);
  delete missingField.tasks[0].runs[0].usage.cacheCreation;
  assert.throws(() => decodeWorkbenchSnapshot(missingField), /expected keys/);

  const missingPrivacyFlag = clone(fixture);
  delete missingPrivacyFlag.tasks[0].runs[0].output.provisionalRedacted;
  assert.throws(
    () => decodeWorkbenchSnapshot(missingPrivacyFlag),
    /expected keys/,
  );

  const mismatchedCurrentRun = clone(fixture);
  mismatchedCurrentRun.tasks[0].currentRunPhase = "waiting_ui";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedCurrentRun),
    /matching projected Run/,
  );

  const terminalCurrentRun = clone(fixture);
  terminalCurrentRun.tasks[0].currentRunPhase = "completed";
  terminalCurrentRun.tasks[0].runs[0].phase = "completed";
  terminalCurrentRun.tasks[0].runs[0].terminal = terminal("completed");
  terminalCurrentRun.tasks[0].runs[0].activity = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(terminalCurrentRun),
    /unexpected value/,
  );

  const nonTerminalOutcome = clone(fixture);
  nonTerminalOutcome.tasks[0].runs[0].terminal = terminal("completed");
  assert.throws(
    () => decodeWorkbenchSnapshot(nonTerminalOutcome),
    /non-terminal Run cannot have an outcome/,
  );

  const mismatchedTerminalOutcome = clone(fixture);
  mismatchedTerminalOutcome.tasks[0].runs[0].phase = "failed";
  mismatchedTerminalOutcome.tasks[0].runs[0].terminal = terminal("completed");
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedTerminalOutcome),
    /failed Run phase and outcome must agree/,
  );

  const mismatchedToolFailure = clone(fixture);
  mismatchedToolFailure.tasks[0].runs[0].tools.push({
    id: "tool-mismatch",
    order: "1",
    name: "Bash",
    bash: null,
    presentation: null,
    errorDetail: null,
    input: "false",
    progress: "",
    content: "exit 1",
    state: "completed",
    isError: true,
    elapsedMs: "5",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
  });
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedToolFailure),
    /tool failure state and error flag must agree/,
  );

  const archivedRunning = clone(fixture);
  archivedRunning.tasks[0].archived = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(archivedRunning),
    /archived Task/,
  );

  const nonContinuableRunning = clone(fixture);
  nonContinuableRunning.tasks[0].continuationAvailable = false;
  nonContinuableRunning.tasks[0].continuationUnavailableReason =
    "session_poisoned";
  assert.throws(
    () => decodeWorkbenchSnapshot(nonContinuableRunning),
    /open non-continuable Task cannot have active work/,
  );

  const closingRun = clone(fixture);
  closingRun.tasks[0].lifecycle = "closing";
  closingRun.tasks[0].continuationAvailable = false;
  closingRun.tasks[0].continuationUnavailableReason = "closing";
  closingRun.tasks[0].currentRunPhase = "stopping";
  closingRun.tasks[0].runs[0].phase = "stopping";
  closingRun.tasks[0].runs[0].activity = { kind: "stopping" };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(closingRun));

  const continuableClosing = clone(closingRun);
  continuableClosing.tasks[0].continuationAvailable = true;
  continuableClosing.tasks[0].continuationUnavailableReason = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(continuableClosing),
    /non-open Task cannot accept future work/,
  );

  const closingWithRequest = clone(closingRun);
  closingWithRequest.tasks[0].currentRunPhase = "waiting_ui";
  closingWithRequest.tasks[0].runs[0].phase = "waiting_ui";
  closingWithRequest.tasks[0].runs[0].activity = { kind: "waiting_user" };
  closingWithRequest.tasks[0].pendingUi = {
    requestId: "9",
    runId: "7",
    order: "1",
    redacted: true,
    kind: "permission",
    toolNamespace: "builtin",
    tool: "Bash",
    toolBinding: "binding-9",
    presentation: null,
    args: "***",
    availableChoices: ["deny_once", "allow_once"],
    policyGeneration: "1",
    canonicalArgumentsDigest: "digest-9",
    candidate: null,
  };
  assert.throws(
    () => decodeWorkbenchSnapshot(closingWithRequest),
    /non-open Task cannot expose actionable UI/,
  );

  const foreignUiHistory = clone(fixture);
  foreignUiHistory.tasks[0].uiHistory.push({
    requestId: "8",
    runId: "99",
    order: "1",
    kind: "permission",
    state: "allowed_once",
    detail: "{}",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "user",
    review: null,
    reviewReason: null,
    agentRequestId: "",
    permission: null,
  });
  assert.throws(
    () => decodeWorkbenchSnapshot(foreignUiHistory),
    /reference a projected Run/,
  );

  const duplicateUiHistory = clone(fixture);
  const record = {
    requestId: "8",
    runId: "7",
    order: "1",
    kind: "permission",
    state: "denied",
    detail: "{}",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "user",
    review: null,
    reviewReason: null,
    agentRequestId: "",
    permission: null,
  };
  duplicateUiHistory.tasks[0].uiHistory.push(record, { ...record });
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateUiHistory),
    /identities must be unique/,
  );

  const pendingPermission = clone(fixture);
  pendingPermission.tasks[0].currentRunPhase = "waiting_ui";
  pendingPermission.tasks[0].runs[0].phase = "waiting_ui";
  pendingPermission.tasks[0].runs[0].activity = { kind: "waiting_user" };
  pendingPermission.tasks[0].pendingUi = {
    requestId: "9",
    runId: "7",
    order: "1",
    redacted: true,
    kind: "permission",
    toolNamespace: "builtin",
    tool: "Bash",
    toolBinding: "binding-9",
    presentation: null,
    args: "***",
    availableChoices: ["deny_once", "allow_once"],
    policyGeneration: "1",
    canonicalArgumentsDigest: "digest-9",
    candidate: null,
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(pendingPermission));

  const sessionPermission = clone(pendingPermission);
  sessionPermission.tasks[0].pendingUi.availableChoices.push("allow_session");
  assert.throws(
    () => decodeWorkbenchSnapshot(sessionPermission),
    /Session choices require a permission candidate/,
  );
  sessionPermission.tasks[0].pendingUi.candidate = {
    ruleId: "rule-9",
    scope: "exact_arguments",
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(sessionPermission));

  const filePermission = clone(sessionPermission);
  Object.assign(filePermission.tasks[0].pendingUi, {
    tool: "Write",
    candidate: {
      ruleId: "file-rule",
      scope: "file_target",
      target: "C:/work/output.txt",
    },
  });
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(filePermission));
  for (const mutate of [
    (p) => {
      p.tool = "Bash";
    },
    (p) => {
      p.toolNamespace = "mcp";
    },
    (p) => {
      delete p.candidate.target;
    },
    (p) => {
      p.candidate.target = "";
    },
    (p) => {
      p.candidate.extra = true;
    },
  ]) {
    const invalid = clone(filePermission);
    mutate(invalid.tasks[0].pendingUi);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
  const unexpectedTarget = clone(sessionPermission);
  unexpectedTarget.tasks[0].pendingUi.candidate.target = "C:/work/output.txt";
  assert.throws(() => decodeWorkbenchSnapshot(unexpectedTarget));

  const unsupportedScope = clone(sessionPermission);
  unsupportedScope.tasks[0].pendingUi.candidate.scope = "workspace";
  assert.throws(
    () => decodeWorkbenchSnapshot(unsupportedScope),
    /candidate.scope: unexpected value for enum/,
  );

  const resolvedAndPending = clone(pendingPermission);
  resolvedAndPending.tasks[0].uiHistory.push({
    requestId: "9",
    runId: "7",
    order: "2",
    kind: "permission",
    state: "allowed_once",
    detail: "{}",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "user",
    review: null,
    reviewReason: null,
    agentRequestId: "",
    permission: null,
  });
  assert.throws(
    () => decodeWorkbenchSnapshot(resolvedAndPending),
    /a pending UI request cannot already be resolved/,
  );

  delete pendingPermission.tasks[0].pendingUi.redacted;
  assert.throws(
    () => decodeWorkbenchSnapshot(pendingPermission),
    /expected keys/,
  );

  const duplicateActivityOrder = clone(fixture);
  duplicateActivityOrder.tasks[0].runs[0].tools.push({
    id: "tool-1",
    order: "1",
    name: "Read",
    bash: null,
    presentation: null,
    errorDetail: null,
    input: "",
    progress: "",
    content: "done",
    state: "completed",
    isError: false,
    elapsedMs: "1",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
  });
  duplicateActivityOrder.tasks[0].uiHistory.push({
    requestId: "10",
    runId: "7",
    order: "1",
    kind: "permission",
    state: "allowed_once",
    detail: "{}",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "user",
    review: null,
    reviewReason: null,
    agentRequestId: "",
    permission: null,
  });
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateActivityOrder),
    /activity order must be unique/,
  );

  const permissionHistory = clone(fixture);
  permissionHistory.tasks[0].uiHistory.push({
    requestId: "11",
    runId: "7",
    order: "2",
    kind: "permission",
    state: "allowed_always",
    detail: "{}",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "user",
    review: null,
    reviewReason: null,
    agentRequestId: "agent-request-11",
    permission: {
      requestId: "agent-request-11",
      matchedRuleId: "rule-11",
      toolNamespace: "builtin",
      toolName: "Bash",
      toolBinding: "binding-11",
      canonicalArgumentsDigest: "digest-11",
      decision: "allow",
      source: "session_allow",
      policyGeneration: "7",
      usedSessionRule: true,
      callbackOutcome: "answered",
    },
  });
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(permissionHistory));
  permissionHistory.tasks[0].uiHistory[0].permission.requestId =
    "other-request";
  assert.throws(
    () => decodeWorkbenchSnapshot(permissionHistory),
    /permission request identity must match record/,
  );

  const duplicateToolIdentity = clone(fixture);
  const firstDuplicateTool = {
    id: "tool-1",
    order: "1",
    name: "Read",
    bash: null,
    presentation: null,
    errorDetail: null,
    input: "",
    progress: "",
    content: "done",
    state: "completed",
    isError: false,
    elapsedMs: "1",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
  };
  duplicateToolIdentity.tasks[0].runs[0].tools.push(firstDuplicateTool, {
    ...firstDuplicateTool,
    order: "2",
  });
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateToolIdentity),
    /tool product identities must be unique/,
  );
});

test("Host notifications and lifecycle responses require their exact payload shapes", () => {
  assert.deepEqual(
    decodePingResponse({
      sequence: 4,
      transport: "BridgeDispatcher.response",
      origin: "zero://app",
      onMainThread: true,
    }),
    { sequence: 4 },
  );
  assert.deepEqual(
    decodeHostSignalEvent({
      sequence: 4,
      transport: "Runtime.emitWindowEvent",
      origin: "zero://app",
      onMainThread: true,
      requestBytes: 2,
    }),
    { sequence: 4 },
  );
  assert.doesNotThrow(() =>
    assertSignalAcknowledged(
      {
        sequence: 4,
        transport: "React.eventAck",
        origin: "zero://app",
        onMainThread: true,
      },
      4,
    ),
  );
  assert.doesNotThrow(() =>
    assertDisconnected({ generation: "9", detached: true }, "9"),
  );
  assert.throws(
    () =>
      decodePingResponse({
        sequence: 4,
        transport: "BridgeDispatcher.response",
        origin: "zero://app",
        onMainThread: true,
        requestBytes: 2,
      }),
    /expected keys/,
  );
  assert.throws(
    () => assertDisconnected({ generation: "8", detached: true }, "9"),
    /mismatch/,
  );
  assert.throws(
    () =>
      decodePingResponse({
        sequence: -1,
        transport: "BridgeDispatcher.response",
        origin: "zero://app",
        onMainThread: true,
      }),
    /positive safe integer/,
  );
  assert.throws(
    () => assertDisconnected({ generation: "0", detached: true }, "0"),
    /positive wire integer/,
  );
});

test("Skill preparation distinguishes cancellation, diagnostics and bound confirmation", () => {
  assert.deepEqual(decodeSkillImportPreview({ status: "cancelled" }), {
    status: "cancelled",
  });
  assert.deepEqual(
    decodeSkillImportPreview({
      status: "rejected",
      reason: "multiple_definitions",
    }),
    { status: "rejected", reason: "multiple_definitions" },
  );
  const preview = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/skill-import-preview.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(decodeSkillImportPreview(preview), preview);
  for (const invalid of [
    { ...preview, sourcePath: "/private/skill" },
    { ...preview, allowReplace: true },
    { ...preview, preparationRevision: "0" },
    { ...preview, effect: "create" },
    {
      ...preview,
      scope: { kind: "personal", workspaceId: "1", workspaceEpoch: "3" },
    },
    { ...preview, blocker: "guessed_reason" },
    { selected: false },
    { status: "cancelled", reason: null },
  ])
    assert.throws(() => decodeSkillImportPreview(invalid));
});

test("Skill management responses keep mutations and file access explicit", () => {
  assert.deepEqual(
    decodeSkillMutationResult({
      accepted: true,
      installId: "aabbccdd",
      verificationPending: true,
      reason: null,
    }),
    {
      accepted: true,
      installId: "aabbccdd",
      verificationPending: true,
      reason: null,
    },
  );
  assert.deepEqual(
    decodeSkillMutationResult({
      accepted: false,
      installId: null,
      verificationPending: false,
      reason: "source_changed",
    }),
    {
      accepted: false,
      installId: null,
      verificationPending: false,
      reason: "source_changed",
    },
  );
  assert.throws(
    () =>
      decodeSkillMutationResult({
        accepted: false,
        installId: null,
        verificationPending: true,
        reason: "busy",
      }),
    /rejection cannot be pending/,
  );

  assert.deepEqual(
    decodeSkillExportResult({
      exported: true,
      fileName: "release-check.skill",
      reason: null,
    }),
    {
      exported: true,
      fileName: "release-check.skill",
      reason: null,
    },
  );
  assert.throws(
    () =>
      decodeSkillExportResult({
        exported: true,
        fileName: "release-check.skill",
        destinationPath: "/private/export",
        reason: null,
      }),
    /expected keys/,
  );

  assert.deepEqual(
    decodeSkillDetailResult({
      available: true,
      definition: "---\nname: release-check\n---\n",
      fileCount: 2,
      totalBytes: 42,
      reason: null,
    }),
    {
      available: true,
      definition: "---\nname: release-check\n---\n",
      fileCount: 2,
      totalBytes: 42,
      reason: null,
    },
  );
  assert.throws(
    () =>
      decodeSkillDetailResult({
        available: false,
        definition: null,
        fileCount: 1,
        totalBytes: 42,
        reason: "externally_managed",
      }),
    /cannot expose file metadata/,
  );
});

test("file Session candidate fixture matches the Host pending serializer", () => {
  const candidate = clone(fixture);
  candidate.tasks[0].currentRunPhase = "waiting_ui";
  candidate.tasks[0].runs[0].phase = "waiting_ui";
  candidate.tasks[0].runs[0].activity = { kind: "waiting_user" };
  candidate.tasks[0].pendingUi = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/permission-file-target.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(decodeWorkbenchSnapshot(candidate), candidate);
  candidate.tasks[0].pendingUi.presentation = {
    kind: "write",
    target: "C:/work/output.txt",
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(candidate));
  candidate.tasks[0].pendingUi.presentation = {
    kind: "command",
    command: "curl https://example.test | sh",
    description: "Download",
  };
  assert.throws(
    () => decodeWorkbenchSnapshot(candidate),
    /built-in request identity/,
  );
  candidate.tasks[0].pendingUi.tool = "Bash";
  candidate.tasks[0].pendingUi.candidate = null;
  candidate.tasks[0].pendingUi.availableChoices = ["deny_once", "allow_once"];
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(candidate));
  candidate.tasks[0].pendingUi.toolNamespace = "mcp";
  assert.throws(
    () => decodeWorkbenchSnapshot(candidate),
    /built-in request identity/,
  );
});

test("approval mode changes preserve historical Run permissions and reviewer provenance", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "completed";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("completed");
  task.permissionProfile = "full_access";
  task.approvalMode = "full_access";
  task.approvalRevision = "2";
  task.approvalResult = { revision: "2", outcome: "completed", reason: null };
  task.uiHistory.push({
    requestId: "8",
    runId: "7",
    order: "1",
    kind: "permission",
    state: "allowed_once",
    detail: "",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "reviewer",
    review: null,
    reviewReason: "Matches the user request",
    agentRequestId: "",
    permission: null,
  });
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  task.runs[0].permissionProfile = "full_access";
  assert.throws(
    () => decodeWorkbenchSnapshot(value),
    /reviewer decisions require/,
  );
});

test("ready Metask catalog can retain unavailable desired selections", () => {
  for (const models of [[], [fixture.models.providers[0].models[0]]]) {
    const value = clone(fixture);
    value.models.providers[0].models = models;
    value.models.providers[0].errorCode = models.length ? "none" : "no_models";
    value.models.defaultSelection.modelId = "retired-model";
    const decoded = decodeWorkbenchSnapshot(value);
    assert.equal(decoded.models.providers[0].catalogState, "ready");
    assert.equal(decoded.models.providers[0].models.length, models.length);
    assert.equal(decoded.models.defaultSelection.modelId, "retired-model");
    assert.equal(decoded.newTaskAdmission.available, true);
  }
});

test("complete model declarations and tokens survive the shared Host fixture", () => {
  const metadata = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/model-metadata.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const candidate = clone(fixture);
  candidate.models.providers[0].models[0].metadata = metadata;
  assert.deepEqual(
    decodeWorkbenchSnapshot(candidate).models.providers[0].models[0].metadata,
    metadata,
  );
});

test("model metadata excludes the deferred limits field", () => {
  const candidate = clone(fixture);
  candidate.models.providers[0].models[0].metadata.limits = {};
  assert.throws(() => decodeWorkbenchSnapshot(candidate), /expected keys/);
});

test("active input shared fixture preserves exact receipts and adoption history", () => {
  const wire = JSON.parse(
    readFileSync(
      new URL("../src/bridge/active_input.fixture", import.meta.url),
      "utf8",
    ),
  );
  assert.deepEqual(
    decodeSendInputResult(wire.accepted, "1", "input-1"),
    wire.accepted,
  );
  assert.deepEqual(
    decodeSendInputResult(wire.rejected, "1", "input-late"),
    wire.rejected,
  );
  const snapshot = clone(fixture);
  const task = snapshot.tasks[0];
  task.id = "1";
  task.currentRunId = "1";
  task.activeOperation.id = "1";
  task.runs[0].id = "1";
  task.inputReady = true;
  task.runs[0].additionalInputs = [wire.history];
  assert.deepEqual(
    decodeWorkbenchSnapshot(snapshot).tasks[0].runs[0].additionalInputs,
    [wire.history],
  );
  for (const change of [
    (input) => (input.state = "held"),
    (input) => delete input.afterOutputCount,
    (input) => delete input.transferredToRunId,
    (input) => delete input.continuationReason,
    (input) => (input.transferredToRunId = "2"),
    (input) => (input.state = "transferred"),
    (input) => (input.continuationReason = "schedule_failed"),
    (input) => (input.afterOutputCount = -1),
    (input) => (input.afterOutputCount = 0.5),
    (input) => (input.afterOutputCount = 258),
    (input) => (input.afterOutputCount = null),
    (input) => (input.sequence = 0),
    (input) => (input.order = null),
    (input) => (input.adoptedTurn = 0),
    (input) => (input.operationId = ""),
  ]) {
    const bad = clone(snapshot);
    change(bad.tasks[0].runs[0].additionalInputs[0]);
    assert.throws(() => decodeWorkbenchSnapshot(bad));
  }
  const unknown = clone(snapshot);
  // A discarded provisional slot may leave the anchor past current output.
  unknown.tasks[0].runs[0].additionalInputs[0].afterOutputCount = 257;
  Object.assign(unknown.tasks[0].runs[0].additionalInputs[0], {
    state: "unknown",
    sequence: null,
    adoptedTurn: null,
    order: null,
  });
  assert.deepEqual(decodeWorkbenchSnapshot(unknown), unknown);
  const transferred = clone(snapshot);
  const sourceRun = transferred.tasks[0].runs[0];
  const targetRun = clone(sourceRun);
  targetRun.id = "2";
  targetRun.additionalInputs = [];
  sourceRun.phase = "completed";
  sourceRun.activity = null;
  sourceRun.terminal = terminal("completed");
  Object.assign(sourceRun.additionalInputs[0], {
    state: "transferred",
    adoptedTurn: null,
    order: null,
    transferredToRunId: "2",
  });
  transferred.tasks[0].runs.push(targetRun);
  transferred.tasks[0].currentRunId = "2";
  transferred.tasks[0].activeOperation.id = "2";
  assert.deepEqual(decodeWorkbenchSnapshot(transferred), transferred);
  const failedSource = clone(transferred);
  Object.assign(failedSource.tasks[0].runs[0], {
    phase: "failed",
    terminal: terminal("failed"),
  });
  assert.throws(() => decodeWorkbenchSnapshot(failedSource));
  transferred.tasks[0].runs.pop();
  assert.throws(() => decodeWorkbenchSnapshot(transferred));
  assert.throws(() => decodeSendInputResult(wire.accepted, "1", "other"));
  assert.throws(() =>
    decodeSendInputResult(
      { ...wire.accepted, reason: "too_late" },
      "1",
      "input-1",
    ),
  );
  assert.throws(() =>
    decodeSendInputResult({ ...wire.rejected, runId: "1" }, "1", "input-late"),
  );
});

test("unavailable Host attachment fixture stays decodable without advertising image formats", () => {
  const value = clone(fixture);
  value.capabilities.attachments = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/attachments-unavailable.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  assert.deepEqual(decodeWorkbenchSnapshot(value), value);
  value.capabilities.attachments.imageFormats = ["png", "jpeg", "webp"];
  assert.throws(
    () => decodeWorkbenchSnapshot(value),
    /attachment formats must match/,
  );
});

test("field mismatch locates missing schema fields without exposing input keys or values", () => {
  const value = clone(fixture);
  delete value.tasks[0].inputReady;
  delete value.tasks[0].inputSubmissions;
  const privateKey = "private-input-key-".repeat(1000);
  value.tasks[0][privateKey] = "private-input-value";
  assert.throws(
    () => decodeWorkbenchSnapshot(value),
    (error) => {
      assert.match(error.message, /\$\.taskPage\.task/);
      assert.match(
        error.message,
        /missing \(2\): inputReady, inputSubmissions/,
      );
      assert.match(error.message, /unexpected fields: 1/);
      assert.doesNotMatch(error.message, /private-input/);
      assert.ok(error.message.length < 512);
      return true;
    },
  );
  assert.throws(
    () => decodeWorkbenchSnapshot({}),
    (error) => {
      assert.ok(error.message.length < 512);
      assert.match(error.message, /unexpected fields: 0/);
      return true;
    },
  );
});

test("unknown enum and tagged values are rejected without echoing their content", () => {
  const privateValue = "private-input-value-".repeat(1000);
  for (const [field, mutate] of [
    [
      "permissionProfile",
      (value) => {
        value.tasks[0].permissionProfile = privateValue;
      },
    ],
    [
      "activity.kind",
      (value) => {
        value.tasks[0].runs[0].activity = { kind: privateValue };
      },
    ],
    [
      "pendingUi.kind",
      (value) => {
        value.tasks[0].pendingUi = { kind: privateValue };
      },
    ],
  ]) {
    const value = clone(fixture);
    mutate(value);
    assert.throws(
      () => decodeWorkbenchSnapshot(value),
      (error) => {
        assert.ok(error.message.includes(field));
        assert.doesNotMatch(error.message, /private-input/);
        assert.ok(error.message.length < 512);
        return true;
      },
    );
  }
});

test("actual interrupted Compact fixture is accepted by the existing snapshot decoder", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "completed";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("completed");
  value.tasks[0].compacts = [
    JSON.parse(
      readFileSync(
        new URL(
          "../frontend/src/bridge/__fixtures__/compact-interrupted.fixture",
          import.meta.url,
        ),
        "utf8",
      ),
    ),
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(value), value);
});

test("Task waiting input and reception metadata are strict safe projections", () => {
  const value = clone(fixture),
    task = value.tasks[0];
  const metadata = {
    operationId: "queued",
    receivedAtUnixMs: "1792390000000",
    presentationOrder: null,
    anchorRunId: task.runs[0].id,
    afterOutputCount: 0,
  };
  task.inputSubmissions = [
    {
      submission: metadata,
      input: { kind: "text", text: "waiting", redacted: false },
      state: "waiting",
      reason: null,
    },
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(value), value);
  for (const change of [
    (t) => (t.inputAcceptance.reason = "task_busy"),
    (t) => (t.inputSubmissions[0].state = "submitting"),
    (t) => (t.inputSubmissions[0].reason = "capacity_reached"),
    (t) => (t.inputSubmissions[0].submission.receivedAtUnixMs = "0"),
    (t) =>
      (t.inputSubmissions[0].submission.receivedAtUnixMs = "8640000000000001"),
    (t) => (t.inputSubmissions[0].submission.afterOutputCount = 0.5),
    (t) => (t.inputSubmissions[0].submission.anchorRunId = "0"),
    (t) => (t.inputSubmissions[0].payload = "private executable input"),
    (t) => delete t.inputSubmissions[0].submission.operationId,
  ]) {
    const invalid = clone(value);
    change(invalid.tasks[0]);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
  task.inputSubmissions[0].state = "interrupted";
  assert.deepEqual(decodeWorkbenchSnapshot(value), value);
});

test("Models rejects retired image selection projection and execution authority", () => {
  for (const key of [
    "imageGeneration",
    "imageModel",
    "imageCredential",
    "imageEndpoint",
  ]) {
    const value = clone(fixture);
    value.models[key] = {};
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
});

test("file preview preserves explicit refusal reasons", () => {
  const response = {
    state: "unsupported",
    content: "",
    truncated: false,
    redacted: false,
  };
  for (const reason of ["image_limit", "animated_image"]) {
    assert.deepEqual(decodeFilePreview({ ...response, reason }), {
      ...response,
      reason,
    });
    assert.throws(
      () => decodeFilePreview({ ...response, state: "ready", reason }),
      /Invalid Host contract/,
    );
  }
  assert.throws(
    () => decodeFilePreview({ ...response, reason: "unknown" }),
    /Invalid Host contract/,
  );
});

test("file preview admits only bounded ready original image descriptors", () => {
  const value = JSON.parse(
    readFileSync(
      new URL("../src/bridge/file_preview_image.fixture", import.meta.url),
      "utf8",
    ),
  );
  const decoded = decodeFilePreview(value);
  assert.equal(decoded.image.sizeBytes, 10485760);
  assert.equal(decoded.image.chunkBytes, 262143);
  for (const invalid of [
    { ...value, state: "missing" },
    { ...value, state: "busy" },
    { ...value, content: "binary must not become text" },
    { ...value, truncated: true },
    ...[
      { mediaType: "image/svg+xml" },
      { token: "file:///image.png" },
      { sizeBytes: "10485761" },
      { sizeBytes: "01" },
      { width: 0 },
      { height: 8193 },
      { width: 4097, height: 4097 },
      { width: 1.5 },
      { chunkBytes: "262144" },
      { securityEpoch: "0" },
      { dataBase64: "iVBORw0KGgo=" },
    ].map((change) => ({ ...value, image: { ...value.image, ...change } })),
  ])
    assert.throws(() => decodeFilePreview(invalid), /Invalid Host contract/);
  for (const state of ["busy", "stale_security"])
    assert.equal(
      decodeFilePreview({
        state,
        content: "",
        truncated: false,
        redacted: false,
      }).state,
      state,
    );
});

test("file image preview matches the Host shared fixture", () => {
  const value = JSON.parse(
    readFileSync(
      new URL("../src/bridge/file_preview_image.fixture", import.meta.url),
      "utf8",
    ),
  );
  const decoded = decodeFilePreview(value);
  assert.deepEqual(decoded, {
    ...value,
    image: {
      ...value.image,
      sizeBytes: Number(value.image.sizeBytes),
      chunkBytes: Number(value.image.chunkBytes),
    },
  });
});

test("visible Tasks allow failed deletion without archiving and reject deleting while open", () => {
  const value = clone(fixture);
  const scoped = productViewFixture(value, {
    ...initialViewScope,
    taskId: value.tasks[0].id,
  });
  scoped.taskPage.task.deletionStatus = "failed";
  scoped.taskIndex[0].deletionStatus = "failed";
  assert.equal(
    decodeScopedSnapshot(scoped).taskPage.task.deletionStatus,
    "failed",
  );
  scoped.taskPage.task.deletionStatus = "deleting";
  assert.throws(
    () => decodeScopedSnapshot(scoped),
    /in-progress deletion must have closing lifecycle/,
  );
});

test("active Compact identity must match the sole active compact", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "completed";
  task.runs[0].activity = null;
  task.runs[0].terminal = terminal("completed");
  const compact = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/compact-interrupted.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  compact.phase = "compacting";
  task.compacts = [compact];
  task.activeOperation = { kind: "compact", id: compact.operationId };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  const scoped = productViewFixture(value, {
    ...initialViewScope,
    taskId: task.id,
  });
  scoped.taskPage.task.activeOperation.id = "8";
  assert.throws(
    () => decodeScopedSnapshot(scoped),
    /active Compact operation must be the only active Task work/,
  );
});

test("disabled MCP management rejects a nonbaseline redaction state", () => {
  const value = clone(fixture);
  value.mcp.redacted = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(value),
    /disabled MCP management must use the unavailable view/,
  );
});

test("presentation anchors are strict and lossless for both messages and generated images", () => {
  const value = clone(fixture);
  const run = value.tasks[0].runs[0];
  run.submission = {
    operationId: "presentation",
    receivedAtUnixMs: null,
    anchorRunId: null,
    afterOutputCount: 1,
    presentationOrder: "18446744073709551614",
  };
  const tool = {
    id: "tool-1",
    order: "1",
    name: "Read",
    bash: null,
    presentation: null,
    errorDetail: null,
    input: "{}",
    progress: "",
    content: "ok",
    state: "completed",
    isError: false,
    elapsedMs: "1",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
  };
  tool.fileRefs = [
    {
      id: "image",
      title: "",
      displayPath: "image.png",
      generatedImage: true,
      presentationAnchor: {
        afterOutputCount: 1,
        presentationOrder: "18446744073709551613",
      },
    },
  ];
  run.tools = [tool];
  assert.deepEqual(decodeWorkbenchSnapshot(value), value);
  for (const order of ["0", "18446744073709551616", 1, "01"]) {
    const candidate = clone(value);
    candidate.tasks[0].runs[0].tools[0].fileRefs[0].presentationAnchor.presentationOrder =
      order;
    assert.throws(() => decodeWorkbenchSnapshot(candidate));
  }
  const missing = clone(value);
  delete missing.tasks[0].runs[0].submission.presentationOrder;
  assert.throws(() => decodeWorkbenchSnapshot(missing), /presentationOrder/);
  delete value.tasks[0].runs[0].tools[0].fileRefs[0].presentationAnchor;
  assert.throws(() => decodeWorkbenchSnapshot(value), /presentationAnchor/);
});

test("handoff history keeps model advice separate from user and cancellation attribution", () => {
  const value = clone(fixture);
  const record = {
    requestId: "18",
    runId: "7",
    order: "1",
    kind: "permission",
    state: "allowed_once",
    detail: "",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
    answeredBy: "user",
    reviewReason: null,
    agentRequestId: "",
    permission: null,
    review: {
      outcome: "needs_user",
      cause: "reviewer_concern",
      reason: "Confirm this publication.",
    },
  };
  value.tasks[0].uiHistory.push(record);
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  record.state = "cancelled";
  record.answeredBy = null;
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  record.reviewReason = "Wrong attribution";
  assert.throws(() => decodeWorkbenchSnapshot(value));
  record.reviewReason = null;
  record.review.reason = "bad\nreason";
  assert.throws(() => decodeWorkbenchSnapshot(value));
  record.review = { outcome: "failed", cause: "timeout", reason: null };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
});

test("rejection-limit handoff keeps the model reason and no new approval mode", () => {
  const value = clone(fixture);
  const task = value.tasks[0];
  task.approvalMode = "auto_review";
  task.permissionReviewState = "needs_user";
  task.permissionReviewExplanation = {
    cause: "rejection_limit",
    reason: "Confirm this operation.",
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(value));
  task.permissionReviewExplanation.reason = "bad\nreason";
  assert.throws(() => decodeWorkbenchSnapshot(value));
  task.permissionReviewExplanation = {
    cause: "timeout",
    reason: "Not a model reason",
  };
  assert.throws(() => decodeWorkbenchSnapshot(value));
});

test("calendar Schedule projection strictly validates frequency, zone and timestamp", () => {
  const snapshot = clone(fixture);
  Object.assign(snapshot.capabilities, {
    scheduledTasks: true,
    scheduledTaskPersistence: true,
    scheduledTaskPersistenceHealth: "ready",
    backgroundScheduleWake: true,
  });
  const entries = JSON.parse(
    readFileSync(
      new URL(
        "../src/product/schedule/renderer_projection.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  snapshot.scheduledTasks = [entries[0]];
  for (const frequency of ["hourly", "daily", "weekly", "monthly", "yearly"]) {
    snapshot.scheduledTasks[0].recurrence.frequency = frequency;
    if (frequency !== "weekly" && frequency !== "monthly")
      delete snapshot.scheduledTasks[0].recurrence.days;
    assert.equal(
      decodeWorkbenchSnapshot(snapshot).scheduledTasks[0].recurrence.frequency,
      frequency,
    );
  }
  for (const patch of [
    { frequency: "unknown" },
    { timezone: "Invalid Zone" },
    { timezone: "" },
    { startAtUnixSeconds: "253402300800" },
    { startAtUnixSeconds: "01" },
    { everySeconds: "86400" },
    { localTime: "24:00" },
    { localTime: null },
  ]) {
    const invalid = clone(snapshot);
    Object.assign(invalid.scheduledTasks[0].recurrence, patch);
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
  snapshot.scheduledTasks[0].recurrence.timezone = "Factory";
  assert.equal(
    decodeWorkbenchSnapshot(snapshot).scheduledTasks[0].recurrence.localTime,
    "08:33",
  );
});

test("calendar day sets decode strictly and preserve all selected dates", () => {
  const snapshot = clone(fixture);
  Object.assign(snapshot.capabilities, {
    scheduledTasks: true,
    scheduledTaskPersistence: true,
    scheduledTaskPersistenceHealth: "ready",
    backgroundScheduleWake: true,
  });
  const entries = JSON.parse(
    readFileSync(
      new URL(
        "../src/product/schedule/renderer_projection.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  snapshot.scheduledTasks = [entries[0]];
  Object.assign(snapshot.scheduledTasks[0].recurrence, {
    frequency: "weekly",
    days: [1, 3, 7],
  });
  assert.deepEqual(
    decodeWorkbenchSnapshot(snapshot).scheduledTasks[0].recurrence.days,
    [1, 3, 7],
  );
  for (const days of [[], [0], [8], [1, 1], [3, 1], [1.5], ["1"], null]) {
    const invalid = clone(snapshot);
    invalid.scheduledTasks[0].recurrence.days = days;
    assert.throws(() => decodeWorkbenchSnapshot(invalid));
  }
  snapshot.scheduledTasks[0].recurrence.frequency = "daily";
  assert.throws(() => decodeWorkbenchSnapshot(snapshot));
});
