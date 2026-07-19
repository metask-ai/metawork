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
} from "../frontend/src/bridge/decode-contracts.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot-v5.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

function clone(value) {
  return structuredClone(value);
}

test("the canonical v5 Workbench fixture decodes without normalization", () => {
  assert.deepEqual(decodeWorkbenchSnapshot(fixture), fixture);
});

test("Task metadata mutation acknowledgements are identity-checked and exact", () => {
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
  invalidId.tasks[0].currentRunId = "07";
  assert.throws(() => decodeWorkbenchSnapshot(invalidId), /wire integer/);

  const invalidState = clone(fixture);
  invalidState.tasks[0].lifecycle = "recovering";
  assert.throws(
    () => decodeWorkbenchSnapshot(invalidState),
    /unexpected value/,
  );

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
