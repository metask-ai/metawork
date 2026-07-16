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
      "../frontend/src/host/__fixtures__/workbench-snapshot-v2.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

function clone(value) {
  return structuredClone(value);
}

test("the canonical v2 Workbench fixture decodes without normalization", () => {
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

  const mismatchedCurrentRun = clone(fixture);
  mismatchedCurrentRun.sessions[0].currentRunPhase = "waiting_ui";
  assert.throws(
    () => decodeWorkbenchSnapshot(mismatchedCurrentRun),
    /matching projected Run/,
  );

  const terminalCurrentRun = clone(fixture);
  terminalCurrentRun.sessions[0].currentRunPhase = "completed";
  terminalCurrentRun.sessions[0].runs[0].phase = "completed";
  assert.throws(
    () => decodeWorkbenchSnapshot(terminalCurrentRun),
    /unexpected value/,
  );

  const archivedRunning = clone(fixture);
  archivedRunning.sessions[0].archived = true;
  assert.throws(
    () => decodeWorkbenchSnapshot(archivedRunning),
    /archived Task/,
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
