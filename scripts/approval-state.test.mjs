import assert from "node:assert/strict";
import test from "node:test";

import {
  optionAnswerSelected,
  selectedOptionIndex,
  serializeAnswerDrafts,
  updateOptionAnswer,
  updateTextAnswer,
} from "../frontend/src/features/approvals/answer-drafts.ts";
import {
  acceptUiResponse,
  beginUiResponse,
  failUiResponse,
  initialUiResponseStates,
  observeUiResponseSnapshot,
  uiResponsePhase,
} from "../frontend/src/features/approvals/response-state.ts";

const requestA = { taskId: "3", runId: "7", requestId: "11" };
const requestB = { taskId: "4", runId: "8", requestId: "12" };
const account = {
  sessionState: "signed_out",
  executionState: "none",
  operation: "none",
  readiness: "sign_in_required",
  primaryAction: "sign_in",
  canCancel: false,
  accountId: "",
  displayName: "",
  apiKeys: [],
  models: [],
  selectedApiKeySelectionId: "",
  selectedModelSelectionId: "",
  candidateApiKeySelectionId: "",
  candidateModelSelectionId: "",
  modelCatalogApiKeySelectionId: "",
  canCreateTask: false,
  errorCode: "none",
  safeDiagnostic: "",
  catalogGeneration: "0",
  executionGeneration: "0",
};

function pending(identity) {
  return {
    requestId: identity.requestId,
    runId: identity.runId,
    order: "1",
    redacted: false,
    kind: "permission",
    tool: "Read",
    args: "README.md",
  };
}

function task(identity, pendingUi = pending(identity)) {
  return {
    id: identity.taskId,
    title: "",
    workspaceId: "1",
    binding: {
      epoch: "1",
      availability: "available",
      accountId: "account-1",
      accountDisplayName: "Metask User",
      apiKeySelectionId: "key-1",
      apiKeyName: "Primary",
      apiKeySuffix: "1234",
      provider: "anthropic",
      modelSelectionId: "model-1",
      modelDisplayName: "Model One",
      executionGeneration: "1",
      unavailableReason: null,
    },
    lifecycle: "open",
    continuationAvailable: true,
    archived: false,
    closeFailed: false,
    currentRunId: identity.runId,
    currentRunPhase: "waiting_ui",
    lastRunOutcome: null,
    cause: null,
    runs: [],
    pendingUi,
    uiHistory: [],
  };
}

function snapshot(tasks) {
  return {
    revision: "1",
    capabilities: {
      taskHistoryPersistence: false,
      conversationRecovery: false,
      executionRebind: false,
      structuredPlan: false,
      typedOutputs: false,
      typedFileChanges: false,
      persistentWorkspacePermissions: false,
    },
    account,
    selectedWorkspaceId: "1",
    workspaces: [
      {
        id: "1",
        displayName: "repo",
        canonicalRoot: "/repo",
        redacted: false,
        authorization: "available",
        recentOrder: "1",
        signals: { running: 0, attention: 1, failedOrInterrupted: 0 },
      },
    ],
    tasks,
  };
}

test("UI response state waits for the authoritative snapshot and never reopens an accepted request", () => {
  let states = beginUiResponse(initialUiResponseStates, requestA);
  assert.equal(uiResponsePhase(states, requestA), "sending");
  assert.equal(beginUiResponse(states, requestA), states);

  states = acceptUiResponse(states, requestA);
  assert.equal(uiResponsePhase(states, requestA), "awaiting_snapshot");
  assert.equal(beginUiResponse(states, requestA), states);

  states = beginUiResponse(states, requestB);
  assert.equal(uiResponsePhase(states, requestB), "sending");
  states = observeUiResponseSnapshot(
    states,
    snapshot([task(requestA), task(requestB)]),
  );
  assert.equal(uiResponsePhase(states, requestA), "awaiting_snapshot");

  states = observeUiResponseSnapshot(states, snapshot([task(requestB)]));
  assert.equal(uiResponsePhase(states, requestA), "idle");
  assert.equal(uiResponsePhase(states, requestB), "sending");
});

test("a resolving snapshot wins races with late command completion", () => {
  const sending = beginUiResponse(initialUiResponseStates, requestA);
  const resolved = observeUiResponseSnapshot(sending, snapshot([]));
  assert.equal(uiResponsePhase(resolved, requestA), "idle");
  assert.equal(acceptUiResponse(resolved, requestA), resolved);
  assert.equal(failUiResponse(resolved, requestA), resolved);
});

test("snapshot observation requires the complete Task, Run, and request identity", () => {
  const awaiting = acceptUiResponse(
    beginUiResponse(initialUiResponseStates, requestA),
    requestA,
  );
  const wrongRun = {
    ...requestA,
    runId: "99",
  };
  const resolved = observeUiResponseSnapshot(
    awaiting,
    snapshot([task(wrongRun)]),
  );
  assert.equal(uiResponsePhase(resolved, requestA), "idle");
});

test("a rejected response is retryable without weakening accepted-response locking", () => {
  const sending = beginUiResponse(initialUiResponseStates, requestA);
  const failed = failUiResponse(sending, requestA);
  assert.equal(uiResponsePhase(failed, requestA), "failed");
  const retrying = beginUiResponse(failed, requestA);
  assert.equal(uiResponsePhase(retrying, requestA), "sending");
});

test("question drafts keep option identity instead of parsing display labels", () => {
  const questions = [
    {
      question: "Choose targets",
      header: "Targets",
      multi: true,
      options: [
        { label: "Alpha, Beta", description: "", preview: "" },
        { label: "Gamma", description: "", preview: "" },
      ],
    },
    {
      question: "Why?",
      header: "Reason",
      multi: false,
      options: [],
    },
  ];
  let drafts = updateOptionAnswer([], 0, 0, true, true);
  drafts = updateOptionAnswer(drafts, 0, 1, true, true);
  drafts = updateTextAnswer(drafts, 1, "Ship both");
  assert.equal(optionAnswerSelected(drafts, 0, 0), true);
  assert.equal(selectedOptionIndex(drafts, 0), 0);
  assert.deepEqual(serializeAnswerDrafts(questions, drafts), [
    "Alpha, Beta, Gamma",
    "Ship both",
  ]);

  drafts = updateOptionAnswer(drafts, 0, 0, true, false);
  assert.equal(optionAnswerSelected(drafts, 0, 0), false);
  assert.equal(optionAnswerSelected(drafts, 0, 1), true);
  assert.deepEqual(serializeAnswerDrafts(questions, drafts), [
    "Gamma",
    "Ship both",
  ]);
  assert.equal(
    serializeAnswerDrafts(questions, updateTextAnswer(drafts, 1, "   ")),
    null,
  );
});
