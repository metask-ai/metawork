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
  decodeTaskRunResult,
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
});

test("managed Workspace projection is one-to-one non-selecting and capability-gated", () => {
  const managed = clone(fixture);
  managed.capabilities.managedWorkspaces = true;
  managed.workspaces.push({
    ...clone(fixture.workspaces[0]),
    id: "9",
    origin: "managed",
    displayName: "Managed workspace",
    canonicalRoot: "/data/workspaces/0000000000000009",
    recentOrder: "0",
    signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
  });
  managed.tasks.push({
    ...clone(fixture.tasks[0]),
    id: "4",
    recentOrder: "2",
    workspaceId: "9",
  });
  assert.deepEqual(decodeWorkbenchSnapshot(managed), managed);

  const missingOwner = clone(managed);
  missingOwner.tasks.pop();
  assert.throws(
    () => decodeWorkbenchSnapshot(missingOwner),
    /exactly one Task/,
  );

  const selectedManaged = clone(managed);
  selectedManaged.selectedWorkspaceId = "9";
  assert.throws(
    () => decodeWorkbenchSnapshot(selectedManaged),
    /selected Workspace must be a projected user Workspace/,
  );

  const unavailable = clone(managed);
  unavailable.capabilities.managedWorkspaces = false;
  assert.throws(
    () => decodeWorkbenchSnapshot(unavailable),
    /managed Workspace capability is unavailable/,
  );
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
      target: {
        kind: "explicit",
        workspaceId: "1",
        workspaceEpoch: "1",
      },
      execution: {
        generation: "1",
        provider: "anthropic",
        model: "fixture-model",
      },
      input: {
        kind: "skill",
        skillId: "builtin.summary",
        catalogRevision: "catalog-4",
        argumentValues: ["src"],
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

  const managedTarget = clone(scheduled);
  managedTarget.capabilities.managedWorkspaces = true;
  managedTarget.workspaces.push({
    ...clone(fixture.workspaces[0]),
    id: "9",
    origin: "managed",
    displayName: "Managed workspace",
    canonicalRoot: "/data/workspaces/0000000000000009",
    recentOrder: "0",
  });
  managedTarget.tasks.push({
    ...clone(fixture.tasks[0]),
    id: "4",
    workspaceId: "9",
  });
  managedTarget.scheduledTasks[0].target.workspaceId = "9";
  assert.throws(
    () => decodeWorkbenchSnapshot(managedTarget),
    /explicit scheduled Task cannot target a managed Workspace/,
  );

  const unavailableExplicitTarget = clone(scheduled);
  unavailableExplicitTarget.scheduledTasks[0].target.workspaceId = "99";
  assert.deepEqual(
    decodeWorkbenchSnapshot(unavailableExplicitTarget),
    unavailableExplicitTarget,
  );

  const defaultTarget = clone(scheduled);
  defaultTarget.scheduledTasks[0].target = { kind: "default" };
  defaultTarget.scheduledTasks[0].input = {
    kind: "text",
    text: "Summarize current work",
    redacted: false,
  };
  assert.deepEqual(decodeWorkbenchSnapshot(defaultTarget), defaultTarget);

  const defaultSkill = clone(scheduled);
  defaultSkill.scheduledTasks[0].target = { kind: "default" };
  assert.throws(
    () => decodeWorkbenchSnapshot(defaultSkill),
    /default scheduled Task target requires text input/,
  );

  const invalid = clone(scheduled);
  invalid.scheduledTasks[0].recurrence.cron = "* * * * *";
  assert.throws(() => decodeWorkbenchSnapshot(invalid), /expected keys/);
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
    /ready execution requires/,
  );

  const missingReadyProfile = clone(fixture);
  missingReadyProfile.account.profileId = "";
  assert.throws(
    () => decodeWorkbenchSnapshot(missingReadyProfile),
    /ready execution requires/,
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

  const missingBindingProfile = clone(fixture);
  delete missingBindingProfile.tasks[0].binding.profileId;
  assert.throws(
    () => decodeWorkbenchSnapshot(missingBindingProfile),
    /expected keys/,
  );

  const refreshingReadyAccount = clone(fixture);
  refreshingReadyAccount.account.sessionState = "refreshing";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(refreshingReadyAccount));

  const mismatchedPrimaryAction = clone(fixture);
  mismatchedPrimaryAction.account.primaryAction = "sign_in";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedPrimaryAction),
    /readiness and primary action disagree/,
  );

  const mismatchedCancellation = clone(fixture);
  mismatchedCancellation.account.canCancel = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedCancellation),
    /cancellation availability disagrees/,
  );

  const persistenceCommitted = clone(fixture);
  persistenceCommitted.account.executionState = "reconfiguring";
  persistenceCommitted.account.operation = "persisting";
  persistenceCommitted.account.readiness = "preparing";
  persistenceCommitted.account.canCreateTask = false;
  persistenceCommitted.account.candidateApiKeySelectionId = "key-1";
  persistenceCommitted.account.candidateModelSelectionId = "fixture-model";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(persistenceCommitted));

  const cancellablePersistence = clone(persistenceCommitted);
  cancellablePersistence.account.canCancel = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(cancellablePersistence),
    /cancellation availability disagrees/,
  );

  const candidateAtRest = clone(fixture);
  candidateAtRest.account.candidateApiKeySelectionId = "key-1";
  assert.throws(
    () => decodeWorkbenchSnapshot(candidateAtRest),
    /candidate execution identities require reconfiguration/,
  );

  const unresolvedCandidate = clone(fixture);
  unresolvedCandidate.account.operation = "loading_keys";
  unresolvedCandidate.account.readiness = "preparing";
  unresolvedCandidate.account.canCancel = true;
  unresolvedCandidate.account.canCreateTask = false;
  unresolvedCandidate.account.candidateApiKeySelectionId = "key-pending";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(unresolvedCandidate));

  const incompletePersistence = clone(persistenceCommitted);
  incompletePersistence.account.candidateModelSelectionId = "";
  assert.throws(
    () => decodeWorkbenchSnapshot(incompletePersistence),
    /persistence requires a complete candidate execution target/,
  );

  const emptyKeyChoice = clone(fixture);
  emptyKeyChoice.account.executionState = "reconfiguring";
  emptyKeyChoice.account.operation = "selecting_key";
  emptyKeyChoice.account.readiness = "choice_required";
  emptyKeyChoice.account.primaryAction = "choose_api_key";
  emptyKeyChoice.account.canCancel = true;
  emptyKeyChoice.account.canCreateTask = false;
  emptyKeyChoice.account.apiKeys = [];
  emptyKeyChoice.account.models = [];
  emptyKeyChoice.account.modelCatalogApiKeySelectionId = "";
  assert.throws(
    () => decodeWorkbenchSnapshot(emptyKeyChoice),
    /choice requires at least one candidate/,
  );

  const emptyModelChoice = clone(emptyKeyChoice);
  emptyModelChoice.account.operation = "selecting_model";
  emptyModelChoice.account.primaryAction = "choose_model";
  emptyModelChoice.account.apiKeys = fixture.account.apiKeys;
  emptyModelChoice.account.models = [];
  emptyModelChoice.account.candidateApiKeySelectionId = "key-1";
  assert.throws(
    () => decodeWorkbenchSnapshot(emptyModelChoice),
    /choice requires at least one candidate/,
  );

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
    "credential_released";
  assert.throws(
    () => decodeWorkbenchSnapshot(unavailableContinuable),
    /cannot accept future work/,
  );

  const orphanHistory = clone(fixture);
  orphanHistory.selectedWorkspaceId = null;
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
  assert.throws(
    () => decodeWorkbenchSnapshot(nonContinuableRunning),
    /open non-continuable Task cannot have active work/,
  );

  const closingRun = clone(fixture);
  closingRun.tasks[0].lifecycle = "closing";
  closingRun.tasks[0].continuationAvailable = false;
  closingRun.tasks[0].currentRunPhase = "stopping";
  closingRun.tasks[0].runs[0].phase = "stopping";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(closingRun));

  const continuableClosing = clone(closingRun);
  continuableClosing.tasks[0].continuationAvailable = true;
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
  });
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateActivityOrder),
    /activity order must be unique/,
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
