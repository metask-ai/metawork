import assert from "node:assert/strict";
import test from "node:test";

import {
  clearTaskDraft,
  pruneTaskDrafts,
  readTaskDraft,
  writeTaskDraft,
} from "../frontend/src/features/composer/drafts.ts";
import {
  searchWorkbench,
  taskActivity,
  taskSignals,
  workspaceLabel,
  workspaceSummaries,
} from "../frontend/src/workbench/selectors.ts";

function run(id, user, assistant, outcome, toolContent = "") {
  return {
    id,
    phase: outcome === null ? "running" : "completed",
    user,
    assistant,
    assistantRedacted: false,
    status: "",
    outcome,
    cause: null,
    usage: { input: "0", output: "0", cacheRead: "0", cacheCreation: "0" },
    tools: toolContent
      ? [
          {
            id: "tool",
            order: "1",
            name: "Read",
            input: "",
            progress: "",
            content: toolContent,
            state: "completed",
            isError: false,
            elapsedMs: "1",
            inputTruncated: false,
            progressTruncated: false,
            contentTruncated: false,
            redacted: false,
          },
        ]
      : [],
  };
}

function session(overrides) {
  return {
    id: "1",
    title: "Release audit",
    workspaceRoot: "/repo/alpha",
    lifecycle: "open",
    archived: false,
    closeFailed: false,
    currentRunId: "0",
    currentRunPhase: null,
    lastRunOutcome: null,
    cause: null,
    runs: [],
    pendingUi: null,
    uiHistory: [],
    ...overrides,
  };
}

test("workspace navigation aggregates actionable cross-workspace signals without conflating axes", () => {
  const sessions = [
    session({ id: "1", currentRunId: "9", currentRunPhase: "running" }),
    session({
      id: "2",
      currentRunId: "10",
      currentRunPhase: "waiting_ui",
    }),
    session({
      id: "3",
      workspaceRoot: "/repo/beta",
      lastRunOutcome: "failed",
    }),
    session({
      id: "4",
      workspaceRoot: "/repo/beta",
      archived: true,
      lastRunOutcome: "failed",
    }),
  ];
  assert.deepEqual(workspaceSummaries({ sessions }), [
    {
      root: "/repo/alpha",
      label: "alpha",
      taskCount: 2,
      running: 1,
      attention: 1,
      failed: 0,
    },
    {
      root: "/repo/beta",
      label: "beta",
      taskCount: 1,
      running: 0,
      attention: 0,
      failed: 1,
    },
  ]);
  assert.deepEqual(taskSignals(sessions[2]), {
    running: false,
    attention: false,
    failed: true,
  });
  assert.deepEqual(
    taskSignals(
      session({ lastRunOutcome: "interrupted", cause: "host_shutdown" }),
    ),
    { running: false, attention: false, failed: true },
  );
  assert.equal(workspaceLabel("C:\\work\\metawork\\"), "metawork");
});

test("Task activity hides empty modules and derives only Host-projected content", () => {
  assert.deepEqual(taskActivity(null), {
    currentRun: null,
    latestPlan: null,
    tokenTotal: 0n,
  });

  const current = run("9", "Audit", "Working", null, "tool detail");
  current.usage.input = "12";
  current.usage.output = "5";
  const resolvedPlan = {
    requestId: "4",
    runId: "9",
    order: "2",
    kind: "plan_approval",
    state: "approved",
    detail: "Inspect, validate, report",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
  };
  const summary = taskActivity(
    session({
      currentRunId: "9",
      currentRunPhase: "running",
      runs: [current],
      uiHistory: [resolvedPlan],
    }),
  );
  assert.equal(summary.currentRun, current);
  assert.equal(summary.latestPlan, resolvedPlan);
  assert.equal(summary.tokenTotal, 17n);
});

test("global search finds product content and deliberately excludes raw tool output", () => {
  const snapshot = {
    sessions: [
      session({
        runs: [
          run(
            "9",
            "Check release readiness",
            "Release checklist completed",
            "completed",
            "secret tool-only needle",
          ),
        ],
      }),
    ],
  };
  assert.equal(searchWorkbench(snapshot, "alpha")[0].kind, "workspace");
  assert.equal(searchWorkbench(snapshot, "audit")[0].kind, "task");
  assert.equal(searchWorkbench(snapshot, "readiness")[0].kind, "instruction");
  assert.equal(searchWorkbench(snapshot, "checklist")[0].kind, "completion");
  assert.deepEqual(searchWorkbench(snapshot, "tool-only"), []);
});

test("Composer drafts survive a WebView reload scope and fail safely when storage is unavailable", () => {
  const values = new Map();
  globalThis.window = {
    sessionStorage: {
      get length() {
        return values.size;
      },
      key: (index) => [...values.keys()][index] ?? null,
      getItem: (key) => values.get(key) ?? null,
      setItem: (key, value) => values.set(key, value),
      removeItem: (key) => values.delete(key),
    },
  };
  writeTaskDraft("7", "Follow up after this run");
  writeTaskDraft("8", "Stale draft");
  assert.equal(readTaskDraft("7"), "Follow up after this run");
  pruneTaskDrafts(new Set(["7"]));
  assert.equal(readTaskDraft("7"), "Follow up after this run");
  assert.equal(readTaskDraft("8"), "");
  clearTaskDraft("7");
  assert.equal(readTaskDraft("7"), "");

  Object.defineProperty(globalThis.window, "sessionStorage", {
    get() {
      throw new Error("storage disabled");
    },
  });
  assert.doesNotThrow(() => writeTaskDraft("7", "still typeable"));
  assert.equal(readTaskDraft("7"), "");
  delete globalThis.window;
});
