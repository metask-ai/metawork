import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  assertDisconnected,
  decodeAccountCommandResult,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeTaskCreateResult,
  decodeTaskCompactResult,
  decodeTaskRestoreResult,
  decodeTaskRunResult,
  decodeSkillDetailResult,
  decodeSkillExportResult,
  decodeSkillImportPreview,
  decodeSkillMutationResult,
  decodeMcpMutationResult,
  decodeMcpRefreshResult,
  decodeWorkspaceMutationResult,
  decodeWorkbenchSnapshot,
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

function clone(value) {
  return structuredClone(value);
}

test("the canonical Workbench fixture decodes without normalization", () => {
  assert.deepEqual(decodeWorkbenchSnapshot(fixture), fixture);

  const inconsistentPersistence = clone(fixture);
  inconsistentPersistence.capabilities.taskHistoryPersistence = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(inconsistentPersistence),
    /availability and health must agree/,
  );
});

test("ranged file references use canonical decimal wire strings", () => {
  const ranged = clone(fixture);
  ranged.tasks[0].runs[0].tools = [
    {
      id: "tool-1",
      order: "1",
      name: "Read",
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
          kind: "read",
          range: {
            start: { line: "1", column: "1" },
            end: { line: "2", column: "1" },
          },
        },
      ],
    },
  ];
  assert.deepEqual(decodeWorkbenchSnapshot(ranged), ranged);

  const numericRange = clone(ranged);
  numericRange.tasks[0].runs[0].tools[0].fileRefs[0].range.start.line = 1;
  assert.throws(() => decodeWorkbenchSnapshot(numericRange), /expected string/);
});

test("resource-limited Run terminal crosses the Host to Renderer contract", () => {
  const resourceLimited = clone(fixture);
  const task = resourceLimited.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.lastRunOutcome = "stopped";
  task.cause = "resource_limit";
  task.runs[0].phase = "stopped";
  task.runs[0].outcome = "stopped";
  task.runs[0].cause = "resource_limit";

  assert.deepEqual(decodeWorkbenchSnapshot(resourceLimited), resourceLimited);
});

test("Agent execution failure crosses the Host to Renderer contract", () => {
  const agentFailure = clone(fixture);
  const task = agentFailure.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.lastRunOutcome = "failed";
  task.cause = "agent_failure";
  task.runs[0].phase = "failed";
  task.runs[0].outcome = "failed";
  task.runs[0].cause = "agent_failure";

  assert.deepEqual(decodeWorkbenchSnapshot(agentFailure), agentFailure);
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
  const catalog = {
    availability: "degraded",
    redacted: false,
    revision: "catalog-revision",
    skills: [
      {
        skillId: "builtin.review",
        invocationName: "review",
        displayName: "Review",
        description: "Review a target",
        argumentNames: ["target", "focus"],
        maxValues: 2,
      },
    ],
    issues: [
      {
        code: "invalid_resource",
        invocationName: "broken-skill",
      },
    ],
  };
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

test("Scheduled Task projection decodes recurrence and occurrence without secrets", () => {
  const scheduled = clone(fixture);
  scheduled.capabilities.scheduledTasks = true;
  scheduled.capabilities.scheduledTaskPersistence = true;
  scheduled.capabilities.scheduledTaskPersistenceHealth = "ready";
  scheduled.capabilities.backgroundScheduleWake = true;
  scheduled.scheduledTasks = [
    {
      id: "8",
      epoch: "2",
      title: "Daily summary",
      titleRedacted: false,
      enabled: true,
      health: "ready",
      failureReason: null,
      execution: {
        generation: "1",
        provider: "anthropic",
        model: "fixture-model",
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
  withMcp.capabilities.mcpOAuth = true;
  withMcp.mcp = {
    availability: "degraded",
    managementHealth: "ready",
    operation: "idle",
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

  const hiddenCatalog = clone(withMcp);
  hiddenCatalog.capabilities.mcpManagement = false;
  assert.throws(
    () => decodeWorkbenchSnapshot(hiddenCatalog),
    /disabled MCP management must use the unavailable view/,
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
    /disabled MCP management must use the unavailable view/,
  );

  const unknownDesired = clone(withMcp);
  unknownDesired.mcp.managementHealth = "outcome_unknown";
  unknownDesired.mcp.desiredGeneration = null;
  assert.throws(
    () => decodeWorkbenchSnapshot(unknownDesired),
    /unknown desired state must hide alignment and servers/,
  );
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

test("Task metadata mutation acknowledgements are identity-checked and exact", () => {
  assert.deepEqual(
    decodeTaskCreateResult({
      accepted: true,
      taskId: "3",
      bindingEpoch: "7",
      reason: null,
    }),
    { accepted: true, taskId: "3", bindingEpoch: "7", reason: null },
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
  assert.deepEqual(
    decodeWorkspaceMutationResult(
      {
        accepted: false,
        workspaceId: "5",
        workspaceEpoch: null,
        reason: "workspace_changed",
      },
      "5",
    ),
    {
      accepted: false,
      workspaceId: "5",
      workspaceEpoch: null,
      reason: "workspace_changed",
    },
  );
  assert.doesNotThrow(() =>
    assertTaskFlag({ taskId: "3", renamed: true }, "3", "renamed"),
  );
  assert.doesNotThrow(() =>
    assertTaskFlag({ taskId: "3", deleted: true }, "3", "deleted"),
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

test("Conversation recovery projection is one coherent continuation state", () => {
  const recoverable = clone(fixture);
  const task = recoverable.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.runs[0].phase = "interrupted";
  task.runs[0].outcome = "interrupted";
  task.runs[0].cause = "app_shutdown";
  task.lastRunOutcome = "interrupted";
  task.cause = "app_shutdown";
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

test("Compact projection is append-only and mutually exclusive with Run work", () => {
  const compacted = clone(fixture);
  const task = compacted.tasks[0];
  task.activeOperation = null;
  task.currentRunId = "0";
  task.currentRunPhase = null;
  task.lastRunOutcome = "completed";
  task.runs[0].phase = "completed";
  task.runs[0].outcome = "completed";
  task.compacts.push({
    operationId: "11",
    afterRunId: "7",
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

  const archivedActive = clone(active);
  archivedActive.tasks[0].archived = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(archivedActive),
    /archived Task cannot have an active Compact/,
  );

  const closedActive = clone(active);
  closedActive.tasks[0].lifecycle = "closed";
  closedActive.tasks[0].continuationAvailable = false;
  closedActive.tasks[0].continuationUnavailableReason = "closed";
  assert.throws(
    () => decodeWorkbenchSnapshot(closedActive),
    /closed Task cannot have an active Compact/,
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
    outcome: null,
  });
  simultaneous.tasks[0].currentRunId = "8";
  simultaneous.tasks[0].currentRunPhase = "running";
  assert.throws(
    () => decodeWorkbenchSnapshot(simultaneous),
    /active Compact operation must be the only active Task work/,
  );

  const invalidCause = clone(compacted);
  invalidCause.tasks[0].compacts[0].cause = "agent_failure";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidCause),
    /phase and cause must describe the same terminal state/,
  );
});

test("Workbench decoding rejects extra fields and invalid wire values", () => {
  const extraField = clone(fixture);
  extraField.compatibility = true;
  assert.throws(() => decodeWorkbenchSnapshot(extraField), /expected keys/);

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

  const invalidReadyAccount = clone(fixture);
  invalidReadyAccount.account.executionGeneration = "0";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidReadyAccount),
    /ready catalog requires/,
  );

  const keyOutsideCatalog = clone(fixture);
  keyOutsideCatalog.account.selectedApiKeySelectionId = "missing-key";
  assert.throws(
    () => decodeWorkbenchSnapshot(keyOutsideCatalog),
    /selected catalog membership/,
  );

  const modelOutsideCatalog = clone(fixture);
  modelOutsideCatalog.account.selectedModelSelectionId = "missing-model";
  assert.throws(
    () => decodeWorkbenchSnapshot(modelOutsideCatalog),
    /selected catalog membership/,
  );

  const mismatchedCancellation = clone(fixture);
  mismatchedCancellation.account.canCancel = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedCancellation),
    /cancellation requires active authorization or catalog work/,
  );

  const persistenceCommitted = clone(fixture);
  persistenceCommitted.account.catalogState = "loading";
  persistenceCommitted.account.canCreateTask = false;
  persistenceCommitted.account.candidateApiKeySelectionId = "key-1";
  persistenceCommitted.account.candidateModelSelectionId = "fixture-model";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(persistenceCommitted));

  const cancellablePersistence = clone(persistenceCommitted);
  cancellablePersistence.account.canCancel = true;
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(cancellablePersistence));

  const candidateAtRest = clone(fixture);
  candidateAtRest.account.candidateApiKeySelectionId = "key-1";
  assert.throws(
    () => decodeWorkbenchSnapshot(candidateAtRest),
    /candidate execution identities require reconfiguration/,
  );

  const unresolvedCandidate = clone(fixture);
  unresolvedCandidate.account.catalogState = "loading";
  unresolvedCandidate.account.canCancel = true;
  unresolvedCandidate.account.canCreateTask = false;
  unresolvedCandidate.account.candidateApiKeySelectionId = "key-pending";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(unresolvedCandidate));

  const incompletePersistence = clone(persistenceCommitted);
  incompletePersistence.account.candidateModelSelectionId = "";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(incompletePersistence));

  const emptyKeyChoice = clone(fixture);
  emptyKeyChoice.account.catalogState = "choosing";
  emptyKeyChoice.account.canCancel = true;
  emptyKeyChoice.account.canCreateTask = false;
  emptyKeyChoice.account.apiKeys = [];
  emptyKeyChoice.account.models = [];
  emptyKeyChoice.account.modelCatalogApiKeySelectionId = "";
  assert.throws(
    () => decodeWorkbenchSnapshot(emptyKeyChoice),
    /catalog choice requires at least one API/,
  );

  const emptyModelChoice = clone(emptyKeyChoice);
  emptyModelChoice.account.apiKeys = fixture.account.apiKeys;
  emptyModelChoice.account.models = [];
  emptyModelChoice.account.candidateApiKeySelectionId = "key-1";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(emptyModelChoice));

  const loadingModelCandidate = clone(fixture);
  loadingModelCandidate.account.catalogState = "loading";
  loadingModelCandidate.account.canCreateTask = false;
  loadingModelCandidate.account.models = [];
  loadingModelCandidate.account.candidateApiKeySelectionId = "key-1";
  loadingModelCandidate.account.candidateModelSelectionId = "model-pending";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(loadingModelCandidate));

  const loadingIdentity = clone(fixture);
  loadingIdentity.account.state = "authorizing";
  loadingIdentity.account.catalogState = "unavailable";
  loadingIdentity.account.canCancel = false;
  loadingIdentity.account.accountId = "";
  loadingIdentity.account.displayName = "";
  loadingIdentity.account.apiKeys = [];
  loadingIdentity.account.models = [];
  loadingIdentity.account.selectedApiKeySelectionId = "";
  loadingIdentity.account.selectedModelSelectionId = "";
  loadingIdentity.account.modelCatalogApiKeySelectionId = "";
  loadingIdentity.account.canCreateTask = false;
  loadingIdentity.account.executionGeneration = "0";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(loadingIdentity));

  const loggingOut = clone(fixture);
  loggingOut.account.catalogState = "unavailable";
  loggingOut.account.models = [];
  loggingOut.account.modelCatalogApiKeySelectionId = "";
  loggingOut.account.canCreateTask = false;
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(loggingOut));

  const duplicateModel = clone(fixture);
  duplicateModel.account.models = [
    { selectionId: "model-1", displayName: "One" },
    { selectionId: "model-1", displayName: "Two" },
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
  delete missingPrivacyFlag.tasks[0].runs[0].assistantRedacted;
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
  terminalCurrentRun.tasks[0].runs[0].outcome = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(terminalCurrentRun),
    /unexpected value/,
  );

  const nonTerminalOutcome = clone(fixture);
  nonTerminalOutcome.tasks[0].runs[0].outcome = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(nonTerminalOutcome),
    /non-terminal Run cannot have an outcome/,
  );

  const mismatchedTerminalOutcome = clone(fixture);
  mismatchedTerminalOutcome.tasks[0].runs[0].phase = "failed";
  mismatchedTerminalOutcome.tasks[0].runs[0].outcome = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedTerminalOutcome),
    /failed Run phase and outcome must agree/,
  );

  const mismatchedToolFailure = clone(fixture);
  mismatchedToolFailure.tasks[0].runs[0].tools.push({
    id: "tool-mismatch",
    order: "1",
    name: "Bash",
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
  closingWithRequest.tasks[0].pendingUi = {
    requestId: "9",
    runId: "7",
    order: "1",
    redacted: true,
    kind: "permission",
    tool: "Bash",
    args: "***",
    availableChoices: ["deny_once", "allow_once"],
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
  pendingPermission.tasks[0].pendingUi = {
    requestId: "9",
    runId: "7",
    order: "1",
    redacted: true,
    kind: "permission",
    tool: "Bash",
    args: "***",
    availableChoices: ["deny_once", "allow_once"],
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(pendingPermission));
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
    agentRequestId: "agent-request-11",
    permission: {
      requestId: "agent-request-11",
      matchedRuleId: "rule-11",
      toolNamespace: "builtin",
      toolName: "Bash",
      toolBinding: "binding-11",
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

test("Skill import previews expose only bounded metadata and an opaque identity", () => {
  assert.deepEqual(decodeSkillImportPreview({ selected: false }), {
    selected: false,
  });
  const preview = {
    selected: true,
    previewId: "7",
    sourceKind: "local_package",
    invocationName: "release-check",
    displayName: "release-check",
    description: "Check a release.",
    fileCount: 2,
    totalBytes: 42,
  };
  assert.deepEqual(decodeSkillImportPreview(preview), preview);
  assert.throws(
    () =>
      decodeSkillImportPreview({ ...preview, sourcePath: "/private/skill" }),
    /expected keys/,
  );
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
