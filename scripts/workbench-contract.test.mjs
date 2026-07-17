import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  assertDisconnected,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeWorkbenchSnapshot,
} from "../frontend/src/host/decode-contracts.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/host/__fixtures__/workbench-snapshot-v4.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

function clone(value) {
  return structuredClone(value);
}

test("the canonical v4 Workbench fixture decodes without normalization", () => {
  assert.deepEqual(decodeWorkbenchSnapshot(fixture), fixture);
});

test("Task metadata mutation acknowledgements are identity-checked and exact", () => {
  assert.doesNotThrow(() =>
    assertTaskFlag({ sessionId: "3", renamed: true }, "3", "renamed"),
  );
  assert.doesNotThrow(() =>
    assertTaskFlag({ sessionId: "3", deleted: true }, "3", "deleted"),
  );
  assert.doesNotThrow(() =>
    assertTaskArchived({ sessionId: "3", archived: false }, "3", false),
  );
  assert.throws(
    () => assertTaskFlag({ sessionId: "4", renamed: true }, "3", "renamed"),
    /response mismatch/,
  );
  assert.throws(
    () =>
      assertTaskArchived(
        { sessionId: "3", archived: true, compatibility: true },
        "3",
        true,
      ),
    /expected keys/,
  );
});

test("Workbench decoding rejects version drift, extra fields, and invalid wire values", () => {
  const oldVersion = clone(fixture);
  oldVersion.schemaVersion = 0;
  assert.throws(
    () => decodeWorkbenchSnapshot(oldVersion),
    /unsupported version/,
  );

  const extraField = clone(fixture);
  extraField.compatibility = true;
  assert.throws(() => decodeWorkbenchSnapshot(extraField), /expected keys/);

  const invalidId = clone(fixture);
  invalidId.sessions[0].currentRunId = "07";
  assert.throws(() => decodeWorkbenchSnapshot(invalidId), /wire integer/);

  const invalidState = clone(fixture);
  invalidState.sessions[0].lifecycle = "recovering";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidState),
    /unexpected value/,
  );

  const missingField = clone(fixture);
  delete missingField.sessions[0].runs[0].usage.cacheCreation;
  assert.throws(() => decodeWorkbenchSnapshot(missingField), /expected keys/);

  const missingPrivacyFlag = clone(fixture);
  delete missingPrivacyFlag.sessions[0].runs[0].assistantRedacted;
  assert.throws(
    () => decodeWorkbenchSnapshot(missingPrivacyFlag),
    /expected keys/,
  );

  const mismatchedCurrentRun = clone(fixture);
  mismatchedCurrentRun.sessions[0].currentRunPhase = "waiting_ui";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedCurrentRun),
    /matching projected Run/,
  );

  const terminalCurrentRun = clone(fixture);
  terminalCurrentRun.sessions[0].currentRunPhase = "completed";
  terminalCurrentRun.sessions[0].runs[0].phase = "completed";
  terminalCurrentRun.sessions[0].runs[0].outcome = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(terminalCurrentRun),
    /unexpected value/,
  );

  const nonTerminalOutcome = clone(fixture);
  nonTerminalOutcome.sessions[0].runs[0].outcome = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(nonTerminalOutcome),
    /non-terminal Run cannot have an outcome/,
  );

  const mismatchedTerminalOutcome = clone(fixture);
  mismatchedTerminalOutcome.sessions[0].runs[0].phase = "failed";
  mismatchedTerminalOutcome.sessions[0].runs[0].outcome = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedTerminalOutcome),
    /failed Run phase and outcome must agree/,
  );

  const mismatchedToolFailure = clone(fixture);
  mismatchedToolFailure.sessions[0].runs[0].tools.push({
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
  archivedRunning.sessions[0].archived = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(archivedRunning),
    /archived Task/,
  );

  const nonContinuableRunning = clone(fixture);
  nonContinuableRunning.sessions[0].continuationAvailable = false;
  assert.throws(
    () => decodeWorkbenchSnapshot(nonContinuableRunning),
    /open non-continuable Task cannot have active work/,
  );

  const closingRun = clone(fixture);
  closingRun.sessions[0].lifecycle = "closing";
  closingRun.sessions[0].continuationAvailable = false;
  closingRun.sessions[0].currentRunPhase = "stopping";
  closingRun.sessions[0].runs[0].phase = "stopping";
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(closingRun));

  const continuableClosing = clone(closingRun);
  continuableClosing.sessions[0].continuationAvailable = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(continuableClosing),
    /non-open Task cannot accept future work/,
  );

  const closingWithRequest = clone(closingRun);
  closingWithRequest.sessions[0].currentRunPhase = "waiting_ui";
  closingWithRequest.sessions[0].runs[0].phase = "waiting_ui";
  closingWithRequest.sessions[0].pendingUi = {
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
  foreignUiHistory.sessions[0].uiHistory.push({
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
  duplicateUiHistory.sessions[0].uiHistory.push(record, { ...record });
  assert.throws(
    () => decodeWorkbenchSnapshot(duplicateUiHistory),
    /identities must be unique/,
  );

  const pendingPermission = clone(fixture);
  pendingPermission.sessions[0].currentRunPhase = "waiting_ui";
  pendingPermission.sessions[0].runs[0].phase = "waiting_ui";
  pendingPermission.sessions[0].pendingUi = {
    requestId: "9",
    runId: "7",
    order: "1",
    redacted: true,
    kind: "permission",
    tool: "Bash",
    args: "***",
  };
  assert.doesNotThrow(() => decodeWorkbenchSnapshot(pendingPermission));
  delete pendingPermission.sessions[0].pendingUi.redacted;
  assert.throws(
    () => decodeWorkbenchSnapshot(pendingPermission),
    /expected keys/,
  );

  const duplicateActivityOrder = clone(fixture);
  duplicateActivityOrder.sessions[0].runs[0].tools.push({
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
  duplicateActivityOrder.sessions[0].uiHistory.push({
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
});

test("Host notifications and lifecycle responses require their exact payload shapes", () => {
  assert.deepEqual(
    decodePingResponse({
      sequence: 4,
      transport: "BridgeDispatcher.response",
      origin: "zero://app",
      onMainThread: true,
      automation: false,
      gate5Fixture: false,
    }),
    { sequence: 4, automation: false, gate5Fixture: false },
  );
  assert.deepEqual(
    decodeHostSignalEvent({
      sequence: 4,
      transport: "Runtime.emitWindowEvent",
      origin: "zero://app",
      onMainThread: true,
      requestBytes: 2,
      automation: false,
      gate5Fixture: false,
    }),
    { sequence: 4, automation: false, gate5Fixture: false },
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
        automation: false,
        gate5Fixture: false,
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
        automation: false,
        gate5Fixture: false,
      }),
    /positive safe integer/,
  );
  assert.throws(
    () => assertDisconnected({ generation: "0", detached: true }, "0"),
    /positive wire integer/,
  );
});
