import { productStateFixture } from "./test-support/product-view-fixture.mjs";
import assert from "node:assert/strict";
import test from "node:test";

import {
  attentionStatus,
  publishStatus,
  quietStatus,
  selectCommandBarStatus,
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
  pendingInputContinuation,
  orderedTasks,
  taskSignals,
  workspaceDirectoryLabel,
} from "../frontend/src/workbench/selectors.ts";

function run(id, text, assistant, outcome, toolContent = "", cause = null) {
  return {
    id,
    conversationCoverage: "included",
    phase:
      outcome === null
        ? "running"
        : outcome === "dependency_contract_failure"
          ? "failed"
          : outcome,
    execution: {
      generation: "1",
      protocol: "anthropic_messages",
      model: "fixture-model",
    },
    input: { kind: "text", text, redacted: false },
    additionalInputs: [],
    output: {
      commentary: [],
      response: assistant,
      responseKind: assistant ? "final" : null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    activity: outcome === null ? { kind: "waiting_model" } : null,
    terminal:
      outcome === null
        ? null
        : { outcome, cause, diagnosticDisposition: "absent" },
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
            fileRefs: [],
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
    deletionStatus: "idle",
    continuationAvailable: true,
    archived: false,
    currentRunId: "0",
    currentRunPhase: null,
    recentOrder: "1",
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
    ...overrides,
  };
}

test("continuation is a Task reservation without a fabricated active Run phase", () => {
  const source = run("9", "question", "answer", "completed");
  source.additionalInputs = [{ state: "continuing" }];
  const current = task({ currentRunId: source.id, runs: [source] });
  assert.equal(isRunInFlight(current), false);
  assert.equal(pendingInputContinuation(current), source);
  assert.deepEqual(taskDisplayState(current), {
    kind: "outcome",
    value: "completed",
  });
  source.additionalInputs[0].state = "transferred";
  assert.equal(pendingInputContinuation(current), null);
  assert.deepEqual(taskDisplayState(current), {
    kind: "outcome",
    value: "completed",
  });
});

test("Task list stays flat while ordering action before recency", () => {
  const tasks = [
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
  ];
  const ordered = orderedTasks(tasks);

  assert.deepEqual(
    ordered.map((item) => item.id),
    [
      "attention-new",
      "attention-old",
      "running",
      "queued",
      "recent-new",
      "recent-old",
    ],
  );
  assert.deepEqual(
    orderedTasks(tasks).map((item) => item.id),
    ordered.map((item) => item.id),
  );
});

test("automatic review is processing until the current request needs a user", () => {
  const reviewing = task({
    id: "reviewing",
    approvalMode: "auto_review",
    permissionReviewState: "reviewing",
    currentRunId: "9",
    currentRunPhase: "waiting_ui",
    recentOrder: "10",
  });
  const manual = task({ id: "manual", currentRunPhase: "waiting_ui" });
  const working = task({
    id: "working",
    currentRunPhase: "running",
    recentOrder: "11",
  });
  assert.deepEqual(taskSignals(reviewing), {
    running: true,
    attention: false,
    failed: false,
  });
  assert.deepEqual(taskDisplayState(reviewing), { kind: "permission_review" });
  assert.deepEqual(
    orderedTasks([reviewing, working, manual]).map((item) => item.id),
    ["manual", "working", "reviewing"],
  );
  reviewing.permissionReviewState = "needs_user";
  assert.deepEqual(taskSignals(reviewing), {
    running: false,
    attention: true,
    failed: false,
  });
  assert.deepEqual(taskDisplayState(reviewing), {
    kind: "phase",
    value: "waiting_ui",
  });
  assert.deepEqual(
    orderedTasks([working, reviewing]).map((item) => item.id),
    ["reviewing", "working"],
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
      runs: [run("3", "", "", "failed")],
    }),
    task({
      id: "4",
      workspaceId: "2",
      archived: true,
      runs: [run("4", "", "", "failed")],
    }),
  ];
  assert.deepEqual(taskSignals(tasks[2]), {
    running: false,
    attention: false,
    failed: true,
  });
  assert.deepEqual(
    taskSignals(
      task({
        runs: [run("5", "", "", "interrupted", "", "app_shutdown")],
      }),
    ),
    { running: false, attention: false, failed: true },
  );
  assert.deepEqual(
    taskSignals(task({ archived: true, deletionStatus: "failed" })),
    { running: false, attention: false, failed: true },
  );
  assert.equal(
    workspaceDirectoryLabel(
      { kind: "manual", canonicalRoot: "/repo/metawork" },
      "Default",
    ),
    "/repo/metawork",
  );
  assert.equal(
    workspaceDirectoryLabel(
      {
        kind: "automatic",
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
        runs: [run("9", "", "", "failed")],
      }),
    ),
    { kind: "phase", value: "running" },
  );
  assert.deepEqual(
    taskDisplayState(
      task({ lifecycle: "closing", runs: [run("9", "", "", "failed")] }),
    ),
    { kind: "lifecycle", value: "closing" },
  );
  assert.deepEqual(
    taskDisplayState(
      task({ archived: true, runs: [run("9", "", "", "failed")] }),
    ),
    { kind: "archived" },
  );
  assert.deepEqual(
    taskDisplayState(task({ runs: [run("9", "", "", "failed")] })),
    {
      kind: "outcome",
      value: "failed",
    },
  );
  assert.deepEqual(taskDisplayState(task({})), { kind: "ready" });
});

test("manual Compact participates in Task action ordering without becoming a Run", () => {
  const compacting = task({
    activeOperation: { kind: "compact", id: "11" },
    compacts: [
      {
        operationId: "11",
        afterRunId: "9",
        conversationCoverage: "included",
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
  assert.deepEqual(orderedTasks([compacting]), [compacting]);
  assert.equal(taskSignals(compacting).running, true);
});

test("Conversation recovery remains visible as Task work without becoming a Run", () => {
  const restoring = task({
    continuationAvailable: false,
    continuationUnavailableReason: "session_recovery_in_progress",
    continuationRecoveryAvailable: false,
    activeOperation: { kind: "restore", id: "12" },
  });
  assert.equal(isRunInFlight(restoring), false);
  assert.deepEqual(taskDisplayState(restoring), { kind: "recovery" });
  assert.deepEqual(orderedTasks([restoring]), [restoring]);
  assert.equal(taskSignals(restoring).running, true);
});

test("a new Task draft is not mistaken for an in-flight Run", () => {
  assert.equal(isRunInFlight(null), false);
  assert.equal(isRunInFlight(task({ currentRunPhase: null })), false);
  assert.equal(isRunInFlight(task({ currentRunPhase: "queued" })), true);
});

test("command bar attention is explicit and cannot leak across product identity", () => {
  const taskA = {
    route: "workbench",
    settingsOpen: false,
    workspaceId: "ws-1",
    taskId: "task-a",
  };
  const taskB = {
    route: "workbench",
    settingsOpen: false,
    workspaceId: "ws-1",
    taskId: "task-b",
  };
  const otherWorkspace = {
    route: "workbench",
    settingsOpen: false,
    workspaceId: "ws-2",
    taskId: null,
  };
  const settings = {
    route: "skills",
    settingsOpen: true,
    workspaceId: "ws-1",
    taskId: null,
  };

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
  const taskFailure = attentionStatus("task.rename_failed", {
    scope: "task",
    taskId: "task-a",
  });
  assert.equal(statusVisibleInCommandBar(taskFailure, taskA), true);
  assert.equal(statusVisibleInCommandBar(taskFailure, taskB), false);
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
        kind: "manual",
        displayName: "alpha",
        canonicalRoot: "/repo/alpha",
      },
      {
        id: "9",
        kind: "automatic",
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
      task({ id: "9", workspaceId: "9", title: "Automatic report" }),
    ],
  };
  Object.assign(
    snapshot,
    productStateFixture(snapshot, {
      taskId: null,
      beforeRunId: null,
      runLimit: 4,
      management: "none",
      search: true,
      receipts: [],
    }),
  );
  assert.deepEqual(searchWorkbench(snapshot, "alpha"), []);
  assert.equal(searchWorkbench(snapshot, "audit")[0].kind, "task");
  assert.equal(searchWorkbench(snapshot, "readiness")[0].kind, "instruction");
  assert.equal(searchWorkbench(snapshot, "checklist")[0].kind, "completion");
  assert.deepEqual(searchWorkbench(snapshot, "tool-only"), []);
  assert.deepEqual(searchWorkbench(snapshot, "deadbeef"), []);
  assert.equal(
    searchWorkbench(snapshot, "automatic report")[0].detail,
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
  const largeDraft = { kind: "text", text: "界\n".repeat(100 * 1024) };
  assert.equal(composerDraftWithinLimits(largeDraft), false);
  writeTaskDraft("7", largeDraft);
  assert.deepEqual(readTaskDraft("7"), largeDraft);
  writeNewTaskDraft("large", largeDraft);
  assert.deepEqual(readNewTaskDraft("large"), largeDraft);
  clearNewTaskDraft("large");
  writeTaskDraft("7", { kind: "text", text: "Follow up after this run" });
  writeTaskDraft("media", {
    kind: "multimodal",
    text: "Keep only this text",
    attachments: [
      {
        token: "a".repeat(48),
        kind: "image",
        format: "png",
        displayName: "secret-name.png",
        sizeBytes: "128",
      },
    ],
  });
  const persistedMedia = values.get("metawork.task-draft.v1.media");
  assert.doesNotMatch(persistedMedia, /secret-name|aaaaaaaa/);
  assert.deepEqual(readTaskDraft("media"), {
    kind: "text",
    text: "Keep only this text",
    attachmentsReloadRequired: true,
  });
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
    selectionRevision: "3",
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
      text: "x".repeat(8 * 1024 * 1024 + 1),
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
    prepareRetryDraft({ kind: "text", text: "" }, "x".repeat(256 * 1024 + 1)),
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
