import assert from "node:assert/strict";
import test from "node:test";

import { SnapshotDemand } from "../frontend/src/snapshot-demand.ts";

test("a failed snapshot attempt preserves its target revision", () => {
  const demand = new SnapshotDemand();
  demand.beginGeneration("1");
  demand.request(7n);
  demand.beginAttempt();
  assert.equal(demand.failAttempt(), 100);
  assert.equal(demand.needsRefresh(), true);

  demand.beginAttempt();
  assert.equal(demand.accept(7n), true);
  assert.equal(demand.needsRefresh(), false);
});

test("snapshot demand coalesces concurrent notifications to the newest revision", () => {
  const demand = new SnapshotDemand();
  demand.request(4n);
  demand.beginAttempt();
  demand.request(9n);
  assert.equal(demand.accept(4n), true);
  assert.equal(demand.needsRefresh(), true);

  demand.beginAttempt();
  assert.equal(demand.accept(9n), true);
  assert.equal(demand.needsRefresh(), false);
  assert.equal(demand.accept(8n), false);
});

test("snapshot retry is exhausted once per generation and requires an explicit reset", () => {
  const demand = new SnapshotDemand();
  demand.beginGeneration("4");
  demand.request();
  for (const delay of [100, 250, 500, 1000]) {
    demand.beginAttempt();
    assert.equal(demand.failAttempt(), delay);
  }
  demand.beginAttempt();
  assert.equal(demand.failAttempt(), null);
  assert.equal(demand.hasPending(), true);
  assert.equal(demand.needsRefresh(), false);

  demand.resetRetry();
  assert.equal(demand.needsRefresh(), true);
  demand.beginGeneration("5");
  assert.equal(demand.needsRefresh(), true);
});
