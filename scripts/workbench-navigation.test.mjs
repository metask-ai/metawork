import assert from "node:assert/strict";
import test from "node:test";

import {
  attentionStatus,
  publishStatus,
  quietStatus,
  selectAccountGateStatus,
  selectCommandBarStatus,
  statusVisibleInAccountGate,
  statusVisibleInCommandBar,
} from "../frontend/src/app/command-bar-status.ts";

import {
  clearNewTaskDraft,
  clearTaskDraft,
  newTaskDraftMoveDecision,
  newTaskDraftStorageId,
  unscopedNewTaskDraftId,
  prepareRetryDraft,
  pruneTaskDrafts,
  readNewTaskDraft,
  readTaskDraft,
  writeNewTaskDraft,
  writeTaskDraft,
} from "../frontend/src/features/composer/drafts.ts";
import { composerDraftWithinLimits } from "../frontend/src/features/composer/slash.ts";
import {
  isRunInFlight,
  searchWorkbench,
  taskDisplayState,
  taskGroups,
  taskSignals,
  workspaceDirectoryLabel,
} from "../frontend/src/workbench/selectors.ts";

function run(id, text, assistant, outcome, toolContent = "") {
  return {
    id,
    phase: outcome === null ? "running" : "completed",
    input: { kind: "text", text, redacted: false },
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
    workspaceId: "1",
    lifecycle: "open",
    continuationAvailable: true,
    archived: false,
    closeFailed: false,
    currentRunId: "0",
    currentRunPhase: null,
    recentOrder: "1",
    lastRunOutcome: null,
    cause: null,
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
    ...overrides,
  };
}

test("Task list groups action before recency and keeps Host order exact", () => {
  const groups = taskGroups(
    [
      task({ id: "recent-old", recentOrder: "9007199254740993" }),
      task({ id: "queued", currentRunPhase: "queued", recentOrder: "8" }),
      task({ id: "running", currentRunPhase: "running", recentOrder: "9" }),
      task({
        id: "attention-old",
        currentRunPhase: "waiting_ui",
        recentOrder: "10",
      }),
      task({
        id: "attention-new",
        currentRunPhase: "waiting_ui",
        recentOrder: "11",
      }),
      task({ id: "recent-new", recentOrder: "9007199254740994" }),
      task({ id: "archived", archived: true, recentOrder: "12" }),
    ],
    true,
  );

  assert.deepEqual(
    groups.map((group) => [group.kind, group.tasks.map((item) => item.id)]),
    [
      ["attention", ["attention-new", "attention-old"]],
      ["running", ["running"]],
      ["queued", ["queued"]],
      ["recent", ["recent-new", "recent-old"]],
      ["archived", ["archived"]],
    ],
  );
});

test("Task signals and Workspace path labels preserve their independent semantics", () => {
  const tasks = [
    task({ id: "1", currentRunId: "9", currentRunPhase: "running" }),
    task({
      id: "2",
      currentRunId: "10",
      currentRunPhase: "waiting_ui",
    }),
    task({
      id: "3",
      workspaceId: "2",
      lastRunOutcome: "failed",
    }),
    task({
      id: "4",
      workspaceId: "2",
      archived: true,
      lastRunOutcome: "failed",
    }),
  ];
  assert.deepEqual(taskSignals(tasks[2]), {
    running: false,
    attention: false,
    failed: true,
  });
  assert.deepEqual(
    taskSignals(task({ lastRunOutcome: "interrupted", cause: "app_shutdown" })),
    { running: false, attention: false, failed: true },
  );
  assert.equal(
    workspaceDirectoryLabel(
      { origin: "user", canonicalRoot: "/repo/metawork" },
      "Default",
    ),
    "/repo/metawork",
  );
  assert.equal(
    workspaceDirectoryLabel(
      {
        origin: "managed",
        canonicalRoot: "/data/workspaces/deadbeefdeadbeef",
      },
      "Default",
    ),
    "Default",
  );
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

test("manual Compact participates in Task action grouping without becoming a Run", () => {
  const compacting = task({
    activeOperation: { kind: "compact", id: "11" },
    compacts: [
      {
        operationId: "11",
        afterRunId: "9",
        phase: "compacting",
        cause: null,
        beforeContextTokens: "0",
        afterContextTokens: "0",
        usage: {
          input: "0",
          output: "0",
          cacheRead: "0",
          cacheCreation: "0",
        },
      },
    ],
  });
  assert.equal(isRunInFlight(compacting), false);
  assert.deepEqual(taskDisplayState(compacting), {
    kind: "compact_phase",
    value: "compacting",
  });
  assert.deepEqual(taskGroups([compacting], false), [
    { kind: "running", tasks: [compacting] },
  ]);
  assert.equal(taskSignals(compacting).running, true);
});

test("a new Task draft is not mistaken for an in-flight Run", () => {
  assert.equal(isRunInFlight(null), false);
  assert.equal(isRunInFlight(task({ currentRunPhase: null })), false);
  assert.equal(isRunInFlight(task({ currentRunPhase: "queued" })), true);
});

test("command bar attention is explicit and cannot leak across product identity", () => {
  const taskA = { route: "workbench", workspaceId: "ws-1", taskId: "task-a" };
  const taskB = { route: "workbench", workspaceId: "ws-1", taskId: "task-b" };
  const otherWorkspace = {
    route: "workbench",
    workspaceId: "ws-2",
    taskId: null,
  };
  const settings = { route: "settings", workspaceId: "ws-1", taskId: null };

  assert.equal(
    statusVisibleInCommandBar(
      quietStatus("connection.connected", { scope: "connection" }),
      taskA,
    ),
    false,
  );
  assert.equal(
    statusVisibleInCommandBar(
      attentionStatus("account.options_updated", { scope: "account" }),
      settings,
    ),
    true,
  );
  assert.equal(
    statusVisibleInAccountGate(
      attentionStatus("account.options_updated", { scope: "account" }),
    ),
    true,
  );
  assert.equal(
    statusVisibleInAccountGate(
      quietStatus("account.cancel_rejected", { scope: "account" }),
    ),
    false,
  );

  const workspaceFailure = attentionStatus("mutation.transport_failed", {
    scope: "workspace",
    workspaceId: "ws-1",
  });
  assert.equal(statusVisibleInCommandBar(workspaceFailure, taskA), true);
  assert.equal(
    statusVisibleInCommandBar(workspaceFailure, otherWorkspace),
    false,
  );
  assert.equal(statusVisibleInCommandBar(workspaceFailure, settings), false);
  assert.equal(statusVisibleInAccountGate(workspaceFailure), false);

  const taskFailure = attentionStatus("task.rename_failed", {
    scope: "task",
    taskId: "task-a",
  });
  assert.equal(statusVisibleInCommandBar(taskFailure, taskA), true);
  assert.equal(statusVisibleInCommandBar(taskFailure, taskB), false);
  assert.equal(statusVisibleInAccountGate(taskFailure), false);

  const concurrent = [
    attentionStatus("task.rename_failed", {
      scope: "task",
      taskId: "task-a",
    }),
    quietStatus("task.renamed", { scope: "task", taskId: "task-b" }),
  ].reduce(publishStatus, {});
  assert.equal(
    selectCommandBarStatus(concurrent, taskA)?.id,
    "task.rename_failed",
  );
  assert.equal(selectCommandBarStatus(concurrent, taskB), null);
  assert.equal(selectAccountGateStatus(concurrent), null);

  const recoveredWorkspace = publishStatus(
    publishStatus(
      {},
      attentionStatus("workspace.selection_failed", {
        scope: "workspace",
        workspaceId: null,
      }),
    ),
    quietStatus("workspace.grant_confirmed", {
      scope: "workspace",
      workspaceId: "ws-1",
    }),
  );
  assert.equal(selectCommandBarStatus(recoveredWorkspace, taskA), null);
  assert.equal(
    selectCommandBarStatus(recoveredWorkspace, otherWorkspace),
    null,
  );

  const mixedScope = [
    attentionStatus("account.command_failed", { scope: "account" }),
    attentionStatus("run.stop_failed", {
      scope: "task",
      taskId: "task-a",
    }),
  ].reduce(publishStatus, {});
  assert.equal(
    selectCommandBarStatus(mixedScope, taskA)?.id,
    "run.stop_failed",
  );
  assert.equal(
    selectCommandBarStatus(mixedScope, settings)?.id,
    "account.command_failed",
  );
});

test("global search finds product content and deliberately excludes raw tool output", () => {
  const snapshot = {
    workspaces: [
      {
        id: "1",
        origin: "user",
        displayName: "alpha",
        canonicalRoot: "/repo/alpha",
      },
      {
        id: "9",
        origin: "managed",
        displayName: "Independent workspace",
        canonicalRoot: "/data/workspaces/deadbeefdeadbeef",
      },
    ],
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
      task({ id: "9", workspaceId: "9", title: "Managed report" }),
    ],
  };
  assert.deepEqual(searchWorkbench(snapshot, "alpha"), []);
  assert.equal(searchWorkbench(snapshot, "audit")[0].kind, "task");
  assert.equal(searchWorkbench(snapshot, "readiness")[0].kind, "instruction");
  assert.equal(searchWorkbench(snapshot, "checklist")[0].kind, "completion");
  assert.deepEqual(searchWorkbench(snapshot, "tool-only"), []);
  assert.deepEqual(searchWorkbench(snapshot, "deadbeef"), []);
  assert.equal(
    searchWorkbench(snapshot, "managed report")[0].detail,
    "Independent workspace",
  );
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
  values.set("metawork.task-draft.legacy", "Preserve this existing draft");
  assert.deepEqual(readTaskDraft("legacy"), {
    kind: "text",
    text: "Preserve this existing draft",
  });
  writeTaskDraft("legacy", {
    kind: "text",
    text: "Preserve this existing draft",
  });
  assert.equal(values.has("metawork.task-draft.legacy"), false);
  assert.match(values.get("metawork.task-draft.v1.legacy"), /^\{/);
  writeTaskDraft("7", {
    kind: "text",
    text: "Follow up after this run",
  });
  writeTaskDraft("8", { kind: "text", text: "Stale draft" });
  writeNewTaskDraft(unscopedNewTaskDraftId, {
    kind: "text",
    text: "First instruction",
  });
  writeNewTaskDraft("/repo/alpha", { kind: "text", text: "Alpha draft" });
  writeNewTaskDraft("/repo/beta", { kind: "text", text: "Beta draft" });
  assert.deepEqual(readTaskDraft("7"), {
    kind: "text",
    text: "Follow up after this run",
  });
  pruneTaskDrafts(new Set(["7"]));
  assert.deepEqual(readTaskDraft("7"), {
    kind: "text",
    text: "Follow up after this run",
  });
  assert.deepEqual(readTaskDraft("8"), { kind: "text", text: "" });
  assert.deepEqual(readNewTaskDraft(unscopedNewTaskDraftId), {
    kind: "text",
    text: "First instruction",
  });
  assert.deepEqual(readNewTaskDraft("/repo/alpha"), {
    kind: "text",
    text: "Alpha draft",
  });
  assert.deepEqual(readNewTaskDraft("/repo/beta"), {
    kind: "text",
    text: "Beta draft",
  });
  clearTaskDraft("7");
  clearNewTaskDraft(unscopedNewTaskDraftId);
  clearNewTaskDraft("/repo/alpha");
  clearNewTaskDraft("/repo/beta");
  assert.deepEqual(readTaskDraft("7"), { kind: "text", text: "" });
  assert.deepEqual(readNewTaskDraft(unscopedNewTaskDraftId), {
    kind: "text",
    text: "",
  });

  Object.defineProperty(globalThis.window, "sessionStorage", {
    get() {
      throw new Error("storage disabled");
    },
  });
  assert.doesNotThrow(() =>
    writeTaskDraft("7", { kind: "text", text: "still typeable" }),
  );
  assert.doesNotThrow(() =>
    writeNewTaskDraft(unscopedNewTaskDraftId, {
      kind: "text",
      text: "still typeable",
    }),
  );
  assert.deepEqual(readTaskDraft("7"), { kind: "text", text: "" });
  assert.deepEqual(readNewTaskDraft(unscopedNewTaskDraftId), {
    kind: "text",
    text: "",
  });
  delete globalThis.window;
});

test("Skill drafts persist identity, revision, and positional values together", () => {
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
  const draft = {
    kind: "skill",
    skillId: "builtin.review",
    invocationName: "review",
    displayName: "Review",
    catalogRevision: "17",
    argumentNames: ["target"],
    argumentValues: ["src/main.zig"],
    maxValues: 1,
  };
  writeTaskDraft("7", draft);
  assert.deepEqual(readTaskDraft("7"), draft);

  values.set(
    "metawork.task-draft.v1.7",
    JSON.stringify({ ...draft, argumentValues: ["one", "two"] }),
  );
  assert.deepEqual(readTaskDraft("7"), { kind: "text", text: "" });
  values.set(
    "metawork.task-draft.v1.7",
    JSON.stringify({ ...draft, unexpected: true }),
  );
  assert.deepEqual(readTaskDraft("7"), { kind: "text", text: "" });
  const overRunBudget = {
    ...draft,
    argumentNames: [],
    argumentValues: Array.from({ length: 2 }, () => "界".repeat(12 * 1024)),
    maxValues: 2,
  };
  assert.equal(composerDraftWithinLimits(overRunBudget), false);
  writeTaskDraft("7", overRunBudget);
  assert.deepEqual(readTaskDraft("7"), overRunBudget);
  writeTaskDraft("7", {
    ...draft,
    argumentNames: [],
    argumentValues: Array.from({ length: 4 }, () => "界".repeat(16 * 1024)),
    maxValues: 4,
  });
  assert.deepEqual(readTaskDraft("7"), overRunBudget);
  values.set(
    "metawork.task-draft.v1.7",
    JSON.stringify({
      kind: "text",
      text: "x".repeat(16 * 1024 + 1),
    }),
  );
  assert.deepEqual(readTaskDraft("7"), { kind: "text", text: "" });
  delete globalThis.window;
});

test("preparing a retry never overwrites an existing Composer draft", () => {
  assert.deepEqual(
    prepareRetryDraft({ kind: "text", text: "" }, "Run the release checks"),
    {
      draft: { kind: "text", text: "Run the release checks" },
      kind: "prepared",
    },
  );
  assert.deepEqual(
    prepareRetryDraft(
      { kind: "text", text: "Current draft" },
      "Old instruction",
    ),
    {
      draft: { kind: "text", text: "Current draft" },
      kind: "preserved",
    },
  );
  assert.deepEqual(
    prepareRetryDraft({ kind: "text", text: "" }, "x".repeat(16 * 1024 + 1)),
    {
      draft: { kind: "text", text: "" },
      kind: "too_long",
    },
  );
});

test("New task draft identities are isolated by Workspace", () => {
  assert.equal(newTaskDraftStorageId(true, null), unscopedNewTaskDraftId);
  assert.equal(newTaskDraftStorageId(true, "/repo/alpha"), "/repo/alpha");
  assert.equal(newTaskDraftStorageId(true, "/repo/beta"), "/repo/beta");
  assert.equal(newTaskDraftStorageId(false, "/repo/alpha"), null);
});

test("New task draft migration never overwrites an existing Workspace draft", () => {
  assert.equal(
    newTaskDraftMoveDecision(
      { kind: "text", text: "" },
      { kind: "text", text: "Alpha draft" },
    ),
    "preserve_target",
  );
  assert.equal(
    newTaskDraftMoveDecision(
      { kind: "text", text: "Current draft" },
      { kind: "text", text: "" },
    ),
    "move",
  );
  assert.equal(
    newTaskDraftMoveDecision(
      { kind: "text", text: "Current draft" },
      { kind: "text", text: "Alpha draft" },
    ),
    "preserve_both",
  );
});
