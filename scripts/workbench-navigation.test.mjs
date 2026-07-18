import assert from "node:assert/strict";
import test from "node:test";

import {
  clearNewTaskDraft,
  clearTaskDraft,
  prepareRetryDraft,
  pruneTaskDrafts,
  readNewTaskDraft,
  readTaskDraft,
  writeNewTaskDraft,
  writeTaskDraft,
} from "../frontend/src/features/composer/drafts.ts";
import {
  isRunInFlight,
  searchWorkbench,
  taskActivity,
  taskDisplayState,
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

function task(overrides) {
  return {
    id: "1",
    title: "Release audit",
    workspaceRoot: "/repo/alpha",
    lifecycle: "open",
    continuationAvailable: true,
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
  const tasks = [
    task({ id: "1", currentRunId: "9", currentRunPhase: "running" }),
    task({
      id: "2",
      currentRunId: "10",
      currentRunPhase: "waiting_ui",
    }),
    task({
      id: "3",
      workspaceRoot: "/repo/beta",
      lastRunOutcome: "failed",
    }),
    task({
      id: "4",
      workspaceRoot: "/repo/beta",
      archived: true,
      lastRunOutcome: "failed",
    }),
  ];
  assert.deepEqual(workspaceSummaries({ tasks: tasks }), [
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
  assert.deepEqual(taskSignals(tasks[2]), {
    running: false,
    attention: false,
    failed: true,
  });
  assert.deepEqual(
    taskSignals(task({ lastRunOutcome: "interrupted", cause: "app_shutdown" })),
    { running: false, attention: false, failed: true },
  );
  assert.equal(workspaceLabel("C:\\work\\metawork\\"), "metawork");
});

test("Task display state preserves Run, lifecycle, archive, and outcome precedence", () => {
  assert.deepEqual(
    taskDisplayState(
      task({
        currentRunId: "9",
        currentRunPhase: "running",
        lifecycle: "closing",
        lastRunOutcome: "failed",
      }),
    ),
    { kind: "phase", value: "running" },
  );
  assert.deepEqual(
    taskDisplayState(task({ lifecycle: "closing", lastRunOutcome: "failed" })),
    { kind: "lifecycle", value: "closing" },
  );
  assert.deepEqual(
    taskDisplayState(task({ archived: true, lastRunOutcome: "failed" })),
    { kind: "archived" },
  );
  assert.deepEqual(taskDisplayState(task({ lastRunOutcome: "failed" })), {
    kind: "outcome",
    value: "failed",
  });
  assert.deepEqual(taskDisplayState(task({})), { kind: "ready" });
});

test("Task activity hides empty modules and derives only Host-projected content", () => {
  assert.deepEqual(taskActivity(null), {
    currentRun: null,
    tokenTotal: 0n,
  });

  const current = run("9", "Audit", "Working", null, "tool detail");
  current.usage.input = "12";
  current.usage.output = "5";
  const summary = taskActivity(
    task({
      currentRunId: "9",
      currentRunPhase: "running",
      runs: [current],
    }),
  );
  assert.equal(summary.currentRun, current);
  assert.equal(summary.tokenTotal, 17n);
});

test("a new Task draft is not mistaken for an in-flight Run", () => {
  assert.equal(isRunInFlight(null), false);
  assert.equal(isRunInFlight(task({ currentRunPhase: null })), false);
  assert.equal(isRunInFlight(task({ currentRunPhase: "queued" })), true);
});

test("global search finds product content and deliberately excludes raw tool output", () => {
  const snapshot = {
    tasks: [
      task({
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
  writeNewTaskDraft("/repo/alpha", "First instruction");
  assert.equal(readTaskDraft("7"), "Follow up after this run");
  pruneTaskDrafts(new Set(["7"]));
  assert.equal(readTaskDraft("7"), "Follow up after this run");
  assert.equal(readTaskDraft("8"), "");
  assert.equal(readNewTaskDraft("/repo/alpha"), "First instruction");
  clearTaskDraft("7");
  clearNewTaskDraft("/repo/alpha");
  assert.equal(readTaskDraft("7"), "");
  assert.equal(readNewTaskDraft("/repo/alpha"), "");

  Object.defineProperty(globalThis.window, "sessionStorage", {
    get() {
      throw new Error("storage disabled");
    },
  });
  assert.doesNotThrow(() => writeTaskDraft("7", "still typeable"));
  assert.doesNotThrow(() => writeNewTaskDraft("/repo/alpha", "still typeable"));
  assert.equal(readTaskDraft("7"), "");
  assert.equal(readNewTaskDraft("/repo/alpha"), "");
  delete globalThis.window;
});

test("preparing a retry never overwrites an existing Composer draft", () => {
  assert.deepEqual(prepareRetryDraft("", "Run the release checks"), {
    draft: "Run the release checks",
    kind: "prepared",
  });
  assert.deepEqual(prepareRetryDraft("Current draft", "Old instruction"), {
    draft: "Current draft",
    kind: "preserved",
  });
  assert.deepEqual(prepareRetryDraft("", "x".repeat(16 * 1024 + 1)), {
    draft: "",
    kind: "too_long",
  });
});
