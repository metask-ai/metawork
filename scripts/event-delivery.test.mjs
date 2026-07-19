import assert from "node:assert/strict";
import test from "node:test";

import { EventDelivery } from "../frontend/src/bridge/fixtures/event-delivery.ts";

test("a failed batch reconnects with a new generation and invalidates old batches", async () => {
  const generations = ["1", "2"];
  const disconnected = [];
  const connected = [];
  const consumed = [];
  let failFirst = true;
  const delivery = new EventDelivery({
    connect: async () =>
      generations.shift() ?? assert.fail("unexpected connect"),
    disconnect: async (generation) => {
      disconnected.push(generation);
    },
    consume: async (batch) => {
      consumed.push(batch.value);
      if (failFirst) {
        failFirst = false;
        throw new Error("injected ACK failure");
      }
    },
    onConnected: (generation, recovered) => {
      connected.push({ generation, recovered });
    },
    onDisconnected: () => undefined,
    onRecoveryFailure: assert.fail,
  });

  await delivery.start();
  delivery.enqueue({ generation: "1", value: "failed" });
  delivery.enqueue({ generation: "1", value: "stale" });
  await delivery.idle();
  delivery.enqueue({ generation: "2", value: "resent" });
  await delivery.idle();

  assert.deepEqual(disconnected, ["1"]);
  assert.deepEqual(connected, [
    { generation: "1", recovered: false },
    { generation: "2", recovered: true },
  ]);
  assert.deepEqual(consumed, ["failed", "resent"]);
  await delivery.stop();
});

test("stop disconnects exactly once and prevents later consumption", async () => {
  const disconnected = [];
  let consumed = 0;
  const delivery = new EventDelivery({
    connect: async () => "7",
    disconnect: async (generation) => {
      disconnected.push(generation);
    },
    consume: async () => {
      consumed += 1;
    },
    onConnected: () => undefined,
    onDisconnected: () => undefined,
    onRecoveryFailure: assert.fail,
  });

  await delivery.start();
  await delivery.stop();
  await delivery.stop();
  delivery.enqueue({ generation: "7" });
  await delivery.idle();

  assert.deepEqual(disconnected, ["7"]);
  assert.equal(consumed, 0);
});

test("recovery retries a transient Host reconnect failure", async () => {
  const attempts = [];
  const connected = [];
  const failures = [];
  let consumeFailed = false;
  const delivery = new EventDelivery({
    connect: async () => {
      attempts.push(attempts.length + 1);
      if (attempts.length === 2) throw new Error("injected reconnect failure");
      return attempts.length === 1 ? "1" : "3";
    },
    disconnect: async () => undefined,
    consume: async () => {
      if (!consumeFailed) {
        consumeFailed = true;
        throw new Error("injected batch failure");
      }
    },
    onConnected: (generation, recovered) => {
      connected.push({ generation, recovered });
    },
    onDisconnected: () => undefined,
    onRecoveryFailure: (error) => failures.push(error),
    retryDelaysMs: [0, 0],
  });

  await delivery.start();
  delivery.enqueue({ generation: "1" });
  await delivery.idle();

  assert.equal(attempts.length, 3);
  assert.deepEqual(connected, [
    { generation: "1", recovered: false },
    { generation: "3", recovered: true },
  ]);
  assert.deepEqual(failures, []);
  await delivery.stop();
});

test("an explicit restart reconnects an offline delivery generation", async () => {
  const generations = ["1", "2"];
  const disconnected = [];
  const connected = [];
  const delivery = new EventDelivery({
    connect: async () =>
      generations.shift() ?? assert.fail("unexpected connect"),
    disconnect: async (generation) => disconnected.push(generation),
    consume: async () => undefined,
    onConnected: (generation, recovered) =>
      connected.push({ generation, recovered }),
    onDisconnected: () => undefined,
    onRecoveryFailure: assert.fail,
    retryDelaysMs: [0],
  });

  await delivery.start();
  await delivery.restart();

  assert.deepEqual(disconnected, ["1"]);
  assert.deepEqual(connected, [
    { generation: "1", recovered: false },
    { generation: "2", recovered: true },
  ]);
  await delivery.stop();
});
