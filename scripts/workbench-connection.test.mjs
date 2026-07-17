import assert from "node:assert/strict";
import test from "node:test";

import { WorkbenchConnection } from "../frontend/src/host/connection.ts";

globalThis.window ??= {
  setTimeout: globalThis.setTimeout,
  clearTimeout: globalThis.clearTimeout,
};

function snapshot(revision) {
  return { schemaVersion: 4, revision, sessions: [] };
}

test("Workbench connection publishes only synchronized snapshots", async () => {
  let revisionHandler;
  let revisionReject;
  let signalHandler;
  let signalReject;
  const snapshots = [];
  const ready = [];
  const failed = [];
  const acknowledgements = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: (consume, reject) => {
      revisionHandler = consume;
      revisionReject = reject;
      return () => undefined;
    },
    onHostSignal: (consume, reject) => {
      signalHandler = consume;
      signalReject = reject;
      return () => undefined;
    },
    connect: async () => "1",
    disconnect: async () => undefined,
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => ({ sequence: 1, automation: false, gate5Fixture: false }),
    acknowledgeSignal: async (sequence) => acknowledgements.push(sequence),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (value) => snapshots.push(value),
    onStatus: () => undefined,
    onReady: (value) => ready.push(value),
    onViewSyncFailed: (value) => failed.push(value),
  });

  await connection.start();
  assert.deepEqual(
    snapshots.map((value) => value.revision),
    ["1"],
  );
  assert.equal(ready.at(-1), true);
  assert.equal(failed.at(-1), false);

  signalHandler({ sequence: 3, automation: false, gate5Fixture: false });
  await Promise.resolve();
  assert.deepEqual(acknowledgements, [3]);

  revisionReject(new Error("malformed revision"));
  assert.equal(ready.at(-1), false);
  assert.equal(failed.at(-1), true);
  signalReject(new Error("malformed signal"));
  assert.equal(failed.at(-1), true);

  revisionHandler("1");
  await connection.stop();
});

test("explicit recovery replaces a generation whose snapshots stay unavailable", async () => {
  const generations = ["1", "2"];
  const disconnected = [];
  let active = "0";
  const snapshots = [];
  const ready = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => {
      active = generations.shift() ?? assert.fail("unexpected connection");
      return active;
    },
    disconnect: async (generation) => {
      disconnected.push(generation);
      if (active === generation) active = "0";
    },
    fetchSnapshot: async () => {
      if (active === "1" && snapshots.length > 0) return snapshot("0");
      const next = snapshot(active);
      snapshots.push(next);
      return next;
    },
    ping: async () => ({ sequence: 1, automation: false, gate5Fixture: false }),
    acknowledgeSignal: async () => undefined,
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: () => undefined,
    onReady: (value) => ready.push(value),
    onViewSyncFailed: () => undefined,
  });

  await connection.start();
  await connection.retry();
  assert.deepEqual(disconnected, ["1"]);
  assert.deepEqual(
    snapshots.map((value) => value.revision),
    ["1", "2"],
  );
  assert.ok(ready.includes(false));
  assert.equal(ready.at(-1), true);
  await connection.stop();
  assert.deepEqual(disconnected, ["1", "2"]);
});

test("stop during startup prevents later ping and fixture work", async () => {
  let releaseConnect;
  const connectStarted = new Promise((resolve) => {
    releaseConnect = resolve;
  });
  const disconnected = [];
  let pingCount = 0;
  let fixtureBridgeCount = 0;
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: () => connectStarted.then(() => "7"),
    disconnect: async (generation) => disconnected.push(generation),
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => {
      pingCount += 1;
      return { sequence: 1, automation: true, gate5Fixture: true };
    },
    acknowledgeSignal: async () => undefined,
    nativeBridgeForAutomationFixture: () => {
      fixtureBridgeCount += 1;
      return {};
    },
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: () => undefined,
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  const starting = connection.start();
  const stopping = connection.stop();
  releaseConnect();
  await Promise.all([starting, stopping]);
  assert.equal(pingCount, 0);
  assert.equal(fixtureBridgeCount, 0);
  assert.deepEqual(disconnected, ["7"]);
});

test("a failed startup handshake is disconnected and repeated during recovery", async () => {
  const generations = ["1", "2"];
  const disconnected = [];
  let pingCount = 0;
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () =>
      generations.shift() ?? assert.fail("unexpected connection"),
    disconnect: async (generation) => disconnected.push(generation),
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => {
      pingCount += 1;
      if (pingCount === 1) throw new Error("injected ping failure");
      return { sequence: 2, automation: false, gate5Fixture: false };
    },
    acknowledgeSignal: async () => undefined,
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: () => undefined,
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  await assert.rejects(connection.start(), /injected ping failure/);
  assert.deepEqual(disconnected, ["1"]);
  await connection.retry();
  assert.equal(pingCount, 2);
  await connection.stop();
  assert.deepEqual(disconnected, ["1", "2"]);
});
