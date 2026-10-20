import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  decodeViewScope,
  decodeWorkbenchSnapshot,
} from "../frontend/src/bridge/decode-contracts.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/product-view.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

test("Product view decodes the exact Host fixture without reconstructing missing histories", () => {
  const view = decodeWorkbenchSnapshot(fixture);
  assert.equal(view.taskIndex[0].id, "3");
  assert.equal("runs" in view.taskIndex[0], false);
  assert.equal(view.taskPage.task.runs[0].id, "7");
  assert.equal(view.skillManagement.availability, "unavailable");
  assert.equal(view.mcp, null);
  assert.equal(view.scheduledTasks, null);
});

test("Product view rejects mixed commits, wrong associations and malformed pages", () => {
  for (const mutate of [
    (view) => {
      view.context.revision = "1";
    },
    (view) => {
      view.scope.taskId = "4";
    },
    (view) => {
      view.taskPage.beforeRunId = "9";
    },
    (view) => {
      view.taskPage.runManifest = [];
    },
    (view) => {
      view.taskPage.runManifest.push(view.taskPage.runManifest[0]);
    },
    (view) => {
      view.taskPage.runManifest[0].phase = "queued";
    },
    (view) => {
      view.taskIndex[0].title = "different commit";
    },
    (view) => {
      view.taskIndex.push(view.taskIndex[0]);
    },
    (view) => {
      view.taskPage.nextBeforeRunId = "7";
    },
    (view) => {
      view.management.kind = "mcp";
    },
    (view) => {
      view.taskIndex[0].runs = [];
    },
  ]) {
    const candidate = structuredClone(fixture);
    mutate(candidate);
    assert.throws(() => decodeWorkbenchSnapshot(candidate));
  }
});

test("Product consumer scope is closed and bounded", () => {
  for (const scope of [
    {},
    { ...fixture.scope, taskId: "0" },
    { ...fixture.scope, taskId: null, beforeRunId: "7" },
    { ...fixture.scope, runLimit: 5 },
    { ...fixture.scope, runLimit: 1.5 },
    { ...fixture.scope, management: "all" },
    { ...fixture.scope, fields: ["tasks"] },
  ])
    assert.throws(() => decodeViewScope(scope));
});

test("Product view rejects invalid safety epochs and missing or misassociated history", () => {
  for (const mutate of [
    (view) => {
      view.securityEpoch = "0";
    },
    (view) => {
      view.securityEpoch = "01";
    },
    (view) => {
      view.securityEpoch = 1;
    },
    (view) => {
      view.scope.beforeRunId = "7";
    },
    (view) => {
      view.historyPage = { beforeRunId: "7", nextBeforeRunId: null, runs: [] };
    },
    (view) => {
      view.scope.beforeRunId = "7";
      view.historyPage = { beforeRunId: "8", nextBeforeRunId: null, runs: [] };
    },
  ]) {
    const view = structuredClone(fixture);
    mutate(view);
    assert.throws(() => decodeWorkbenchSnapshot(view));
  }
  const empty = structuredClone(fixture);
  empty.scope.beforeRunId = "7";
  empty.historyPage = { beforeRunId: "7", nextBeforeRunId: null, runs: [] };
  const decoded = decodeWorkbenchSnapshot(empty);
  assert.equal(decoded.taskPage.task.currentRunId, "7");
  assert.equal(decoded.taskPage.task.runs[0].id, "7");
  assert.deepEqual(decoded.historyPage.runs, []);
});
