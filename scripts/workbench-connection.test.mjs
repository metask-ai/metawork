import assert from "node:assert/strict";
import test from "node:test";

import { WorkbenchConnection } from "../frontend/src/bridge/connection.ts";
import { RendererBridgeContractError } from "../frontend/src/bridge/client.ts";
import { initialViewScope } from "../frontend/src/bridge/contracts.ts";
import {
  connectionFailurePresentation,
  connectionStatus,
} from "../frontend/src/app/connection-status.ts";

globalThis.window ??= {
  setTimeout: (...args) => globalThis.setTimeout(...args),
  clearTimeout: (...args) => globalThis.clearTimeout(...args),
};

function snapshot(revision, tasks = []) {
  return {
    revision,
    securityEpoch: "1",
    account: {
      state: "signed_out",
      catalogState: "unavailable",
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
      errorCode: "none",
      safeDiagnostic: "",
      catalogGeneration: "0",
    },
    newTaskAdmission: {
      available: false,
      reason: "none",
      activeModelRef: null,
      activeGeneration: "0",
      activeSelectionRevision: "0",
      state: "unavailable",
    },
    capabilities: {
      taskHistoryPersistence: false,
      conversationRecovery: false,
      executionRebind: false,
      structuredPlan: false,
      typedOutputs: false,
      typedFileChanges: false,
      persistentWorkspacePermissions: false,
      automaticWorkspaces: false,
    },
    workspaces:
      tasks.length === 0
        ? []
        : [
            {
              id: "1",
              kind: "manual",
              displayName: "repo",
              canonicalRoot: "/repo",
              redacted: false,
              authorization: "available",
              recentOrder: "1",
              signals: { running: 1, attention: 0, failedOrInterrupted: 0 },
            },
          ],
    tasks,
  };
}

function runningTask() {
  return {
    id: "2",
    workspaceId: "1",
    lifecycle: "open",
    deletionStatus: "idle",
    currentRunId: "7",
    currentRunPhase: "running",
    activeOperation: { kind: "run", id: "7" },
  };
}

test("contract mismatch is terminal and never enters connection retry backoff", async () => {
  let connectCalls = 0;
  const statuses = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => {
      connectCalls += 1;
      throw new RendererBridgeContractError(
        "revision_mismatch",
        "Host requires metawork.renderer-bridge revision 1",
      );
    },
    disconnect: async () => assert.fail("no generation was established"),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: (status) => statuses.push(status),
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  await assert.rejects(connection.start(), RendererBridgeContractError);
  await assert.rejects(connection.retry(), RendererBridgeContractError);
  assert.equal(connectCalls, 2);
  assert.equal(statuses.at(-1)?.kind, "contract_failed");
  assert.equal(statuses.at(-1)?.source, "bootstrap");
  assert.equal(statuses.at(-1)?.code, "revision_mismatch");
  const shellStatus = connectionStatus(statuses.at(-1));
  assert.equal(shellStatus.id, "connection.component_mismatch");
  assert.deepEqual(connectionFailurePresentation(shellStatus), {
    titleId: "connection.component_mismatch",
    helpId: "connection.component_mismatch_help",
    retryable: false,
  });
});

test("bootstrap transport failure is classified separately from snapshot sync failure", async () => {
  const statuses = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => {
      throw new Error("Host is not running");
    },
    disconnect: async () => undefined,
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: (status) => statuses.push(status),
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  await assert.rejects(connection.start(), /Host is not running/);
  assert.equal(statuses.at(-1)?.kind, "connection_failed");
  assert.equal(statuses.at(-1)?.failure, "bootstrap_failed");
});

test("uncertain attachment cleanup replaces even a healthy snapshot connection", async () => {
  let generation = 0;
  const disconnected = [];
  const observed = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => {},
    onHostSignal: () => () => {},
    connect: async () => String(++generation),
    disconnect: async (value) => {
      disconnected.push(value);
    },
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => ({}),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => {},
    onStatus: () => {},
    onReady: () => {},
    onViewSyncFailed: () => {},
    onGeneration: (value) => observed.push(value),
  });
  await connection.start();
  await connection.retry({ replaceConnection: true });
  assert.deepEqual(disconnected, ["1"]);
  assert.deepEqual(observed, ["1", "0", "2"]);
  await connection.stop();
});

test("a startup snapshot contract failure is a terminal bootstrap failure", async () => {
  let fetchCalls = 0;
  const statuses = [];
  const failed = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => "1",
    disconnect: async () => undefined,
    fetchSnapshot: async () => {
      fetchCalls += 1;
      throw new RendererBridgeContractError(
        "invalid_response",
        "snapshot shape is stale",
      );
    },
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => assert.fail("invalid snapshot must not publish"),
    onStatus: (status) => statuses.push(status),
    onReady: () => undefined,
    onViewSyncFailed: (value) => failed.push(value),
  });

  await assert.rejects(connection.start(), RendererBridgeContractError);
  assert.equal(fetchCalls, 1);
  assert.equal(statuses.at(-1)?.kind, "contract_failed");
  // No trusted view exists yet, so the root failure page owns this state.
  assert.equal(statuses.at(-1)?.failure, "bootstrap_failed");
  assert.equal(statuses.at(-1)?.source, "snapshot");
  assert.equal(statuses.at(-1)?.code, "invalid_response");
  const shellStatus = connectionStatus(statuses.at(-1));
  assert.equal(shellStatus.id, "connection.contract_failed");
  assert.deepEqual(connectionFailurePresentation(shellStatus), {
    titleId: "connection.contract_failed",
    helpId: "connection.contract_failed_help",
    retryable: true,
  });
  assert.equal(failed.at(-1), true);
});

test("snapshot publication carries the generation that produced it", async () => {
  const publications = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => "generation-2",
    disconnect: async () => undefined,
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => ({ sequence: 1 }),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (value, generation) => publications.push({ value, generation }),
    onStatus: () => undefined,
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  await connection.start();
  assert.equal(publications[0]?.generation, "generation-2");
  await connection.stop();
});

test("a bootstrap contract mismatch during recovery remains a root failure", async () => {
  let connectCalls = 0;
  const statuses = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => {
      connectCalls += 1;
      if (connectCalls === 1) return "1";
      throw new RendererBridgeContractError(
        "revision_mismatch",
        "Host requires metawork.renderer-bridge revision 2",
      );
    },
    disconnect: async () => undefined,
    fetchSnapshot: async () => {
      throw new RendererBridgeContractError(
        "invalid_response",
        "snapshot shape is stale",
      );
    },
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: (status) => statuses.push(status),
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  await assert.rejects(connection.start(), RendererBridgeContractError);
  await assert.rejects(connection.retry(), RendererBridgeContractError);
  assert.equal(statuses.at(-1)?.source, "bootstrap");
  assert.equal(statuses.at(-1)?.failure, "bootstrap_failed");
});

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
    ping: async () => ({ sequence: 1 }),
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

  signalHandler({ sequence: 3 });
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

test("Workbench connection publishes generation establishment and teardown", async () => {
  const generations = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: async () => "42",
    disconnect: async () => undefined,
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => ({ sequence: 1 }),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: () => undefined,
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
    onGeneration: (generation) => generations.push(generation),
  });

  await connection.start();
  await connection.stop();

  assert.deepEqual(generations, ["42", "0"]);
});

test("explicit recovery replaces a generation whose snapshots stay unavailable", async () => {
  const generations = ["1", "2"];
  const disconnected = [];
  let active = "0";
  const snapshots = [];
  const published = [];
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
      const next = snapshot(active, active === "2" ? [runningTask()] : []);
      snapshots.push(next);
      return next;
    },
    ping: async () => ({ sequence: 1 }),
    acknowledgeSignal: async () => undefined,
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (value) => published.push(value),
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
  assert.equal(published.at(-1)?.account.state, "signed_out");
  assert.equal(published.at(-1)?.tasks[0]?.currentRunPhase, "running");
  assert.deepEqual(published.at(-1)?.tasks[0]?.activeOperation, {
    kind: "run",
    id: "7",
  });
  await connection.stop();
  assert.deepEqual(disconnected, ["1", "2"]);
});

test("stop during startup prevents a later handshake", async () => {
  let releaseConnect;
  const connectStarted = new Promise((resolve) => {
    releaseConnect = resolve;
  });
  const disconnected = [];
  let pingCount = 0;
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => undefined,
    onHostSignal: () => () => undefined,
    connect: () => connectStarted.then(() => "7"),
    disconnect: async (generation) => disconnected.push(generation),
    fetchSnapshot: async () => snapshot("1"),
    ping: async () => {
      pingCount += 1;
      return { sequence: 1 };
    },
    acknowledgeSignal: async () => undefined,
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: () => undefined,
    onStatus: () => undefined,
    onReady: () => undefined,
    onViewSyncFailed: () => undefined,
  });

  const starting = connection.start();
  await flush();
  const stopping = connection.stop();
  releaseConnect();
  await Promise.all([starting, stopping]);
  assert.equal(pingCount, 0);
  assert.deepEqual(disconnected, ["7"]);
});

test("a failed startup confirmation is disconnected and repeated during recovery", async () => {
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
      return { sequence: 2 };
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

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

function fixture(fetchSnapshot = async () => snapshot("1")) {
  const statuses = [],
    publications = [],
    ready = [],
    failures = [],
    generations = [],
    disconnected = [];
  let notify,
    rejectNotification,
    signal,
    generation = 0,
    reads = 0,
    pings = 0;
  const client = {
    available: () => true,
    onWorkbenchRevision: (consume, reject) => {
      notify = consume;
      rejectNotification = reject;
      return () => {};
    },
    onHostSignal: (consume) => {
      signal = consume;
      return () => {};
    },
    connect: async () => String(++generation),
    disconnect: async (value) => {
      disconnected.push(value);
    },
    fetchSnapshot: () => {
      reads++;
      return fetchSnapshot({
        reads,
        generation,
        notify: (value, epoch = "1") => notify(value, epoch),
      });
    },
    ping: async () => {
      pings++;
      return {};
    },
    acknowledgeSignal: async () => {},
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (value, generation) =>
      publications.push({ revision: value.revision, generation }),
    onStatus: (value) => statuses.push(value),
    onReady: (value) => ready.push(value),
    onViewSyncFailed: (value) => failures.push(value),
    onGeneration: (value) => generations.push(value),
  });
  return {
    client,
    connection,
    statuses,
    publications,
    ready,
    failures,
    generations,
    disconnected,
    notify: (value, epoch = "1") => notify(value, epoch),
    rejectNotification: (value) => rejectNotification(value),
    signal: (value) => signal(value),
    reads: () => reads,
    pings: () => pings,
  };
}

const flush = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

test("refresh before start and after stop rejects without reading, and cannot poison startup", async () => {
  const f = fixture();
  await assert.rejects(f.connection.refresh(), /connect/i);
  assert.equal(f.reads(), 0);
  await f.connection.start();
  assert.equal(f.reads(), 1);
  assert.equal(f.pings(), 1);
  await f.connection.stop();
  await assert.rejects(f.connection.refresh(), /stopped/i);
  assert.equal(f.reads(), 1);
});

test("moving notification targets do not fail successful reads or delay first confirmation", async () => {
  let remaining = 12;
  const gates = [];
  const f = fixture(({ reads, notify }) => {
    if (remaining-- > 0) notify(String(reads + 1), "1");
    const gate = deferred();
    gates.push(gate);
    return gate.promise.then(() => snapshot(String(reads)));
  });
  const starting = f.connection.start();
  await flush();
  gates[0].resolve();
  await starting;
  assert.equal(f.pings(), 1);
  assert.equal(f.ready.at(-1), true);
  const refreshing = f.connection.refresh();
  let settled = false;
  refreshing.then(() => {
    settled = true;
  });
  await flush();
  gates[1].resolve();
  await flush();
  if (!settled) {
    gates[2].resolve();
    await flush();
  }
  assert.equal(settled, true);
  assert.equal(f.failures.includes(true), false);
  assert.equal(
    f.statuses.some((x) => x.kind === "refresh_failed"),
    false,
  );
  await f.connection.stop();
  for (const gate of gates) gate.resolve();
});

test("refresh during a read requires a later read and resolves before further catch-up", async () => {
  const a = deferred(),
    b = deferred(),
    c = deferred();
  const f = fixture(({ reads }) =>
    reads === 1 ? Promise.resolve(snapshot("1")) : [a, b, c][reads - 2].promise,
  );
  await f.connection.start();
  const before = f.connection.refresh();
  await flush();
  const after = f.connection.refresh();
  let settled = false;
  after.then(() => {
    settled = true;
  });
  a.resolve(snapshot("2"));
  await before;
  assert.equal(settled, false);
  await flush();
  f.notify("4");
  b.resolve(snapshot("3"));
  await after;
  assert.equal(settled, true);
  await f.connection.stop();
  c.resolve(snapshot("4"));
});

test("a contract failure rejects waiters and cannot be cleared by a late snapshot", async () => {
  const gate = deferred();
  const f = fixture(({ reads }) =>
    reads === 1 ? Promise.resolve(snapshot("1")) : gate.promise,
  );
  await f.connection.start();
  const pending = f.connection.refresh();
  const rejected = assert.rejects(pending, /contract/i);
  await flush();
  f.rejectNotification(
    new RendererBridgeContractError("invalid_response", "malformed revision"),
  );
  await rejected;
  gate.resolve(snapshot("2"));
  await flush();
  assert.deepEqual(
    f.publications.map((x) => x.revision),
    ["1"],
  );
  assert.equal(f.ready.at(-1), false);
  assert.equal(f.failures.at(-1), true);
  await assert.rejects(f.connection.refresh(), /contract/i);
  await f.connection.stop();
});

test("notification bursts coalesce without starving the first read under continuous output", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let revision = 1;
  const f = fixture(async () => snapshot(String(revision)));
  await f.connection.start();
  for (let i = 0; i < 3; i++) {
    revision++;
    f.notify(String(revision));
  }
  assert.equal(f.reads(), 1);
  for (let i = 0; i < 7; i++) {
    t.mock.timers.tick(4);
    await flush();
    revision++;
    f.notify(String(revision));
  }
  assert.equal(f.reads(), 1);
  t.mock.timers.tick(4);
  await flush();
  assert.equal(f.reads(), 2);
  assert.equal(f.publications.at(-1).revision, String(revision));
  revision++;
  f.notify(String(revision));
  t.mock.timers.tick(32);
  await flush();
  assert.equal(f.reads(), 3);
  await f.connection.stop();
});

test("waiters before a transient failure and during backoff share the same successful retry", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const gate = deferred();
  const f = fixture(({ reads }) =>
    reads === 2 ? gate.promise : Promise.resolve(snapshot(String(reads))),
  );
  await f.connection.start();
  const first = f.connection.refresh();
  await flush();
  const before = f.connection.refresh();
  gate.reject(new Error("temporary read failure"));
  await flush();
  const during = f.connection.refresh();
  t.mock.timers.tick(99);
  await flush();
  assert.equal(f.reads(), 2);
  t.mock.timers.tick(1);
  await flush();
  await Promise.all([first, before, during]);
  assert.equal(f.reads(), 3);
  assert.equal(f.failures.includes(true), false);
  assert.equal(
    f.statuses.some((x) => x.kind.endsWith("failed")),
    false,
  );
  await f.connection.stop();
});

test("exhausted reads reject zero-read refresh and passive notifications until explicit same-generation recovery", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let healthy = true;
  let revision = "9";
  const f = fixture(async () => {
    if (!healthy) throw new Error("read unavailable");
    return snapshot(revision);
  });
  await f.connection.start();
  healthy = false;
  const pending = f.connection.refresh();
  const rejected = assert.rejects(pending, /unavailable/);
  await flush();
  for (const delay of [100, 250, 500, 1000]) {
    t.mock.timers.tick(delay);
    await flush();
  }
  await rejected;
  assert.equal(f.reads(), 6);
  await assert.rejects(f.connection.refresh(), /unavailable/);
  f.notify("10");
  t.mock.timers.tick(10000);
  await flush();
  assert.equal(f.reads(), 6);
  healthy = true;
  revision = "10";
  await f.connection.retry();
  assert.equal(f.reads(), 7);
  assert.deepEqual(f.generations, ["1"]);
  assert.equal(f.ready.at(-1), true);
  await f.connection.stop();
});

test("Host unilateral disconnect recovers once without publishing an intermediate terminal fault", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture(async ({ reads, generation }) => {
    if (generation === 1 && reads > 1) throw new Error("NoConnection");
    return snapshot(String(generation));
  });
  await f.connection.start();
  const recovering = f.connection.retry();
  await flush();
  for (const delay of [100, 250, 500, 1000]) {
    t.mock.timers.tick(delay);
    await flush();
  }
  await recovering;
  assert.equal(f.reads(), 7);
  assert.equal(f.pings(), 2);
  assert.deepEqual(f.generations, ["1", "0", "2"]);
  assert.equal(f.failures.includes(true), false);
  assert.equal(
    f.statuses.some((x) => x.kind.endsWith("failed")),
    false,
  );
  await f.connection.stop();
});

test("one recovery has at most two read budgets and one rebuild", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture(async ({ reads }) => {
    if (reads > 1) throw new Error("unavailable");
    return snapshot("1");
  });
  await f.connection.start();
  const rejected = assert.rejects(f.connection.retry(), /unavailable/);
  await flush();
  for (let cycle = 0; cycle < 2; cycle++) {
    for (const delay of [100, 250, 500, 1000]) {
      t.mock.timers.tick(delay);
      await flush();
    }
  }
  await rejected;
  assert.equal(f.reads(), 11);
  assert.deepEqual(f.generations, ["1", "0", "2", "0"]);
  assert.deepEqual(f.failures.filter(Boolean), [true]);
  await assert.rejects(f.connection.refresh(), /disconnect/);
  assert.equal(f.reads(), 11);
  await f.connection.stop();
});

test("generation replacement rejects old waiters, ignores old ACK failure and waits for physical read exit", async () => {
  const read = deferred(),
    ack = deferred();
  const f = fixture(({ reads }) =>
    reads === 2 ? read.promise : Promise.resolve(snapshot("1")),
  );
  f.client.acknowledgeSignal = () => ack.promise;
  await f.connection.start();
  f.signal({ sequence: 3 });
  const old = f.connection.refresh();
  const rejected = assert.rejects(old, /replaced/);
  await flush();
  const replacement = f.connection.retry({ replaceConnection: true });
  await flush();
  await rejected;
  assert.equal(f.reads(), 2);
  ack.reject(new Error("late old ACK"));
  read.resolve(snapshot("99"));
  await replacement;
  assert.equal(f.reads(), 3);
  assert.deepEqual(f.publications, [
    { revision: "1", generation: "1" },
    { revision: "1", generation: "2" },
  ]);
  assert.equal(f.failures.includes(true), false);
  await f.connection.stop();
});

test("stopping rejects active waiters immediately and discards late data", async () => {
  const gate = deferred();
  const f = fixture(({ reads }) =>
    reads === 1 ? Promise.resolve(snapshot("1")) : gate.promise,
  );
  await f.connection.start();
  const rejected = assert.rejects(f.connection.refresh(), /stopped/);
  await flush();
  await f.connection.stop();
  await rejected;
  const statuses = f.statuses.length;
  gate.resolve(snapshot("2"));
  await flush();
  assert.equal(f.publications.length, 1);
  assert.equal(f.statuses.length, statuses);
  assert.equal(f.ready.at(-1), false);
});

test("stop before the registered bootstrap task runs emits no late status or handshake", async () => {
  const f = fixture();
  const starting = f.connection.start();
  await f.connection.stop();
  await starting;
  assert.deepEqual(f.statuses, []);
  assert.equal(f.reads(), 0);
  assert.equal(f.pings(), 0);
});

test("a target known before reading remains enforced and stale reads exhaust a bounded chain", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const f = fixture(async ({ reads }) => snapshot(String(reads)));
  await f.connection.start();
  f.notify("9");
  const rejected = assert.rejects(f.connection.refresh(), /stale/);
  await flush();
  for (const delay of [100, 250, 500, 1000]) {
    t.mock.timers.tick(delay);
    await flush();
  }
  await rejected;
  assert.equal(f.reads(), 6);
  assert.deepEqual(
    f.publications.map((x) => x.revision),
    ["1"],
  );
  assert.equal(f.failures.at(-1), true);
  await f.connection.stop();
});

test("a confirmation contract failure is published and cannot leave an unconfirmed view ready", async () => {
  const f = fixture();
  f.client.ping = async () => {
    throw new RendererBridgeContractError("invalid_response", "invalid ping");
  };
  await assert.rejects(f.connection.start(), RendererBridgeContractError);
  assert.equal(f.statuses.at(-1).kind, "contract_failed");
  assert.equal(f.statuses.at(-1).source, "bootstrap");
  assert.equal(f.ready.at(-1), false);
  assert.equal(f.failures.at(-1), true);
  await f.connection.stop();
});

test("an unavailable bridge publishes a bootstrap failure rather than leaving a quiet disabled view", async () => {
  const f = fixture();
  f.client.available = () => false;
  await assert.rejects(f.connection.start(), /unavailable/);
  assert.equal(f.reads(), 0);
  assert.equal(f.statuses.at(-1).failure, "bootstrap_failed");
  assert.equal(f.failures.at(-1), true);
  await f.connection.stop();
});

test("queued Host signals after stop do not issue late ACK commands", async () => {
  const f = fixture();
  let acknowledgements = 0;
  f.client.acknowledgeSignal = async () => {
    acknowledgements++;
  };
  await f.connection.start();
  await f.connection.stop();
  f.signal({ sequence: 4 });
  await flush();
  assert.equal(acknowledgements, 0);
});

test("startup connects without a recovery status while explicit recovery reports one", async () => {
  const f = fixture();
  await f.connection.start();
  assert.deepEqual(
    f.statuses.map((x) => x.kind),
    ["connected"],
  );
  await f.connection.retry();
  assert.deepEqual(
    f.statuses.map((x) => x.kind),
    ["connected", "recovering", "connected"],
  );
  assert.equal(f.statuses.at(-1).recovered, true);
  await f.connection.stop();
});

test("contract failures are bootstrap failures only until a view has been trusted", async () => {
  let malformed = true;
  const f = fixture(async ({ reads }) => {
    if (malformed)
      throw new RendererBridgeContractError(
        "invalid_response",
        "malformed snapshot",
      );
    return snapshot(String(reads));
  });
  await assert.rejects(f.connection.start(), RendererBridgeContractError);
  // Retrying from the root failure page still has no trusted view to keep.
  await assert.rejects(f.connection.retry(), RendererBridgeContractError);
  assert.equal(f.statuses.at(-1).failure, "bootstrap_failed");
  malformed = false;
  await f.connection.retry();
  assert.equal(f.statuses.at(-1).kind, "connected");
  malformed = true;
  await assert.rejects(f.connection.refresh(), RendererBridgeContractError);
  assert.equal(f.statuses.at(-1).failure, "snapshot_contract_failed");
  assert.equal(f.statuses.at(-1).source, "snapshot");
  await f.connection.stop();
});

test("scope changes discard old reads and serialize a single merged follow-up", async () => {
  const reads = [];
  const published = [];
  let active = 0;
  let maximum = 0;
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => {},
    onHostSignal: () => () => {},
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => {
      maximum = Math.max(maximum, ++active);
      if (reads.length === 0) {
        reads.push({ scope });
        active--;
        return { ...snapshot("1"), scope };
      }
      return new Promise((resolve) =>
        reads.push({
          scope,
          release: (revision) => {
            active--;
            resolve({ ...snapshot(revision), scope });
          },
        }),
      );
    },
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (view) => published.push(view.scope),
    onStatus: () => {},
    onReady: () => {},
    onViewSyncFailed: () => {},
  });
  await connection.start();
  const a = connection.setScope({ ...initialViewScope, taskId: "3" });
  const rejectedA = assert.rejects(a, /scope changed/);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(reads.length, 2);
  const b = connection.setScope({ ...initialViewScope, taskId: "4" });
  await rejectedA;
  assert.equal(reads.length, 2);
  reads[1].release("2");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(reads.length, 3);
  reads[2].release("2");
  await b;
  assert.deepEqual(
    published.map((scope) => scope.taskId),
    [null, "4"],
  );
  assert.equal(maximum, 1);
  await connection.stop();
});

test("security notifications clear published state immediately and discard an old in-flight candidate", async () => {
  const old = deferred();
  let notify;
  let reads = 0;
  const observed = [],
    invalidated = [],
    ready = [];
  const client = {
    available: () => true,
    onWorkbenchRevision: (consume) => {
      notify = consume;
      return () => {};
    },
    onHostSignal: () => () => {},
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: () =>
      ++reads === 1
        ? Promise.resolve(snapshot("1"))
        : reads === 2
          ? old.promise
          : Promise.resolve({ ...snapshot("2"), securityEpoch: "2" }),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (view) => observed.push([view.revision, view.securityEpoch]),
    onSecurityInvalidated: (epoch) => invalidated.push(epoch),
    onReady: (value) => ready.push(value),
    onStatus: () => {},
    onViewSyncFailed: () => {},
  });
  await connection.start();
  const refreshing = connection.refresh();
  await flush();
  assert.equal(reads, 2);
  notify("2", "2");
  assert.equal(invalidated.at(-1), "2");
  assert.equal(ready.at(-1), false);
  old.resolve(snapshot("2"));
  await refreshing;
  assert.deepEqual(observed, [
    ["1", "1"],
    ["2", "2"],
  ]);
  assert.equal(reads, 3);
  assert.equal(ready.at(-1), true);
  await connection.stop();
});

test("navigation during bootstrap follows the current scope without converting cancellation into connection failure", async () => {
  const reads = [],
    published = [],
    statuses = [],
    ready = [];
  let active = 0,
    maximum = 0,
    pings = 0;
  const client = {
    available: () => true,
    onWorkbenchRevision: () => () => {},
    onHostSignal: () => () => {},
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {
      pings++;
    },
    fetchSnapshot: (scope) =>
      new Promise((resolve) => {
        maximum = Math.max(maximum, ++active);
        reads.push({
          scope,
          release: () => {
            active--;
            resolve({ ...snapshot("1"), scope });
          },
        });
      }),
  };
  const connection = new WorkbenchConnection(client, {
    onSnapshot: (view) => published.push(view.scope.management),
    onStatus: (status) => statuses.push(status),
    onReady: (value) => ready.push(value),
    onViewSyncFailed: () => {},
  });
  const startup = connection.start();
  await flush();
  assert.equal(reads.length, 1);
  const oldRefresh = connection.refresh();
  const rejected = assert.rejects(oldRefresh, /scope changed/);
  const navigation = connection.setScope({
    ...initialViewScope,
    management: "skills",
  });
  await rejected;
  reads[0].release();
  await flush();
  assert.equal(reads.length, 2);
  assert.equal(pings, 0);
  assert.equal(reads[1].scope.management, "skills");
  reads[1].release();
  await Promise.all([startup, navigation]);
  assert.deepEqual(published, ["skills"]);
  assert.equal(statuses.at(-1).kind, "connected");
  assert.equal(ready.at(-1), true);
  assert.equal(pings, 1);
  assert.equal(maximum, 1);
  await connection.stop();
});
