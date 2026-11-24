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

test("Run manifest carries the Run's own submission time and a bounded folded excerpt", () => {
  const entry = decodeWorkbenchSnapshot(fixture).taskPage.runManifest[0];
  assert.equal(entry.excerpt, "inspect");
  assert.equal(entry.submittedAtUnixMs, null);
  const accept = (mutate) => {
    const view = structuredClone(fixture);
    mutate(view);
    return decodeWorkbenchSnapshot(view).taskPage.runManifest[0];
  };
  assert.equal(
    accept((view) => {
      view.taskPage.runManifest[0].excerpt = null;
    }).excerpt,
    null,
  );
  assert.equal(
    accept((view) => {
      view.taskPage.runManifest[0].excerpt = "汉".repeat(60);
    }).excerpt,
    "汉".repeat(60),
  );
  assert.equal(
    accept((view) => {
      view.taskPage.runManifest[0].submittedAtUnixMs = "1700000000000";
      view.taskPage.task.runs[0].submittedAtUnixMs = "1700000000000";
    }).submittedAtUnixMs,
    "1700000000000",
  );
  for (const [mutate, reason] of [
    [
      (view) => {
        view.taskPage.runManifest[0].excerpt = `${"汉".repeat(60)}a`;
      },
      /excerpt/,
    ],
    [
      (view) => {
        view.taskPage.runManifest[0].excerpt = "two\nlines";
      },
      /excerpt/,
    ],
    [
      (view) => {
        view.taskPage.runManifest[0].excerpt = 7;
      },
      /excerpt/,
    ],
    [
      (view) => {
        delete view.taskPage.runManifest[0].excerpt;
      },
      /runManifest/,
    ],
    [
      (view) => {
        view.taskPage.runManifest[0].preview = "inspect";
      },
      /runManifest/,
    ],
    [
      (view) => {
        delete view.taskPage.runManifest[0].submittedAtUnixMs;
      },
      /runManifest/,
    ],
    [
      (view) => {
        view.taskPage.runManifest[0].submittedAtUnixMs = "0";
        view.taskPage.task.runs[0].submittedAtUnixMs = "0";
      },
      /submittedAtUnixMs/,
    ],
    [
      (view) => {
        view.taskPage.runManifest[0].submittedAtUnixMs = "1700000000000";
      },
      /disagrees with its manifest/,
    ],
  ]) {
    const view = structuredClone(fixture);
    mutate(view);
    assert.throws(() => decodeWorkbenchSnapshot(view), reason);
  }
});

test("a history page Run must carry its manifest submission time", () => {
  const view = structuredClone(fixture);
  const older = {
    ...structuredClone(view.taskPage.task.runs[0]),
    id: "6",
    phase: "completed",
    activity: null,
    submittedAtUnixMs: "1700000000000",
    terminal: {
      outcome: "completed",
      cause: null,
      diagnosticDisposition: "absent",
      recordingIncomplete: false,
      feedback: {
        guidance: "none",
        reason: null,
        offerInputPreparation: false,
      },
      modelError: null,
    },
  };
  view.taskPage.runManifest.unshift({
    ...structuredClone(view.taskPage.runManifest[0]),
    id: "6",
    phase: "completed",
    submittedAtUnixMs: "1700000000000",
    excerpt: "earlier",
    terminal: structuredClone(older.terminal),
  });
  // One Run per page: the current page holds Run 7, the history page Run 6.
  view.scope.runLimit = 1;
  view.scope.beforeRunId = "7";
  view.taskPage.nextBeforeRunId = "7";
  view.historyPage = { beforeRunId: "7", nextBeforeRunId: null, runs: [older] };
  assert.equal(
    decodeWorkbenchSnapshot(view).historyPage.runs[0].submittedAtUnixMs,
    "1700000000000",
  );
  view.taskPage.runManifest[0].submittedAtUnixMs = "1700000000009";
  assert.throws(
    () => decodeWorkbenchSnapshot(view),
    /history Run manifest mismatch/,
  );
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
  delete hidden.taskPage.task.runs[0].outputs[0].open;
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

test("an output says where the Host opens it, for a Run and for the conversation alike", () => {
  const value = structuredClone(fixture);
  const task = value.taskPage.task;
  const runId = task.runs[0].id;
  const set = (open) => {
    const row = structuredClone(deliveredOutput);
    delete row.open;
    if (open !== undefined) row.open = open;
    task.runs[0].outputs = [row];
    task.conversationOutputs = [{ ...row, runId }];
  };
  for (const open of ["browser", "default_app", undefined]) {
    set(open);
    const decoded = decodeWorkbenchSnapshot(value).taskPage.task;
    for (const output of [
      decoded.runs[0].outputs[0],
      decoded.conversationOutputs[0],
    ]) {
      assert.equal(output.open, open);
      assert.equal(Object.hasOwn(output, "open"), open !== undefined);
    }
  }
  for (const open of ["office", "", true, null]) {
    set(open);
    assert.throws(() => decodeWorkbenchSnapshot(value));
    task.runs[0].outputs[0].open = "browser";
    assert.throws(() => decodeWorkbenchSnapshot(value));
  }
  // A hidden path has nothing to open.
  set("default_app");
  for (const row of [task.runs[0].outputs[0], task.conversationOutputs[0]])
    Object.assign(row, { displayPath: "", redacted: true });
  assert.throws(() => decodeWorkbenchSnapshot(value));
  for (const field of ["officeOutputsOpen", "browserOutputsOpen"]) {
    set("browser");
    const old = structuredClone(value);
    old.taskPage.task[field] = true;
    assert.throws(() => decodeWorkbenchSnapshot(old));
  }
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
