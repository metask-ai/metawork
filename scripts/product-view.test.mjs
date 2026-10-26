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

const deliveredOutput = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/delivered-output.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);

test("delivered Output wire consumes only bounded trusted metadata and rejects path authority", () => {
  const value = structuredClone(fixture);
  value.taskPage.task.runs[0].outputs = [structuredClone(deliveredOutput)];
  const decoded = decodeWorkbenchSnapshot(value).taskPage.task.runs[0].outputs;
  assert.deepEqual(decoded, [deliveredOutput]);
  for (const mutate of [
    (row) => {
      row.id = "0".repeat(32);
    },
    (row) => {
      row.id = "AB".repeat(16);
    },
    (row) => {
      row.id = "1";
    },
    (row) => {
      row.displayPath = "C:/secret.docx";
    },
    (row) => {
      row.displayPath = "../secret.docx";
    },
    (row) => {
      row.displayPath = "a//b";
    },
    (row) => {
      row.displayPath = "报告".repeat(100);
    },
    (row) => {
      row.displayPath = "line\nbreak";
    },
    (row) => {
      row.sizeBytes = 42;
    },
    (row) => {
      row.sizeBytes = "01";
    },
    (row) => {
      row.sizeBytes = "18446744073709551616";
    },
    (row) => {
      row.redacted = true;
    },
    (row) => {
      row.locator = "secret.docx";
    },
    (row) => {
      row.sha256 = "fake";
    },
  ]) {
    const bad = structuredClone(value);
    mutate(bad.taskPage.task.runs[0].outputs[0]);
    assert.throws(() => decodeWorkbenchSnapshot(bad));
  }
  const duplicate = structuredClone(value);
  duplicate.taskPage.task.runs[0].outputs.push(
    structuredClone(deliveredOutput),
  );
  assert.throws(() => decodeWorkbenchSnapshot(duplicate));
  const over = structuredClone(value);
  over.taskPage.task.runs[0].outputs = Array.from({ length: 9 }, (_, i) => ({
    ...deliveredOutput,
    id: (i + 1).toString(16).padStart(32, "0"),
  }));
  assert.throws(() => decodeWorkbenchSnapshot(over));
  const hidden = structuredClone(value);
  Object.assign(hidden.taskPage.task.runs[0].outputs[0], {
    displayPath: "",
    redacted: true,
    sizeBytes: "18446744073709551615",
  });
  assert.equal(
    decodeWorkbenchSnapshot(hidden).taskPage.task.runs[0].outputs[0].sizeBytes,
    "18446744073709551615",
  );
  const missing = structuredClone(value);
  delete missing.taskPage.task.runs[0].outputs;
  assert.throws(() => decodeWorkbenchSnapshot(missing));
});

test("Product bounded Host search shares Native wire and rejects oversized or stale pages", () => {
  const page = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/search-page.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const value = structuredClone(fixture);
  Object.assign(value.scope, {
    search: true,
    searchQuery: "inspect",
    searchCursor: null,
  });
  value.searchIndex = page;
  assert.equal(
    decodeWorkbenchSnapshot(value).searchIndex.results[0].detail,
    "inspect",
  );
  for (const mutate of [
    (v) => (v.searchIndex.results[0].detail = "界".repeat(171)),
    (v) =>
      (v.searchIndex.results = Array.from({ length: 51 }, (_, i) => ({
        ...page.results[0],
        part: String(i),
      }))),
    (v) => (v.searchIndex.stale = true),
    (v) => (v.searchIndex.results[0].kind = "raw_tool"),
    (v) => (v.searchIndex.results[0].part = "18446744073709551616"),
    (v) => (v.scope.searchQuery = "界".repeat(86)),
    (v) =>
      (v.scope.searchCursor = {
        revision: "0",
        securityEpoch: "1",
        task: "0",
        run: "0",
        part: "0",
        offset: "0",
      }),
  ]) {
    const bad = structuredClone(value);
    mutate(bad);
    assert.throws(() => decodeWorkbenchSnapshot(bad));
  }
  const cursor = {
    revision: "2",
    securityEpoch: "2",
    task: "0",
    run: "1",
    part: "0",
    offset: "65536",
  };
  const working = structuredClone(value);
  working.searchIndex = { stale: false, results: [], nextCursor: cursor };
  assert.equal(
    decodeWorkbenchSnapshot(working).searchIndex.nextCursor.offset,
    "65536",
  );
  working.scope.searchCursor = cursor;
  assert.throws(() => decodeWorkbenchSnapshot(working));
});
