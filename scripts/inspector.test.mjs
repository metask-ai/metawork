import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

import {
  inspectorFocusReturnTarget,
  shouldDismissInspectorForEscape,
} from "../frontend/src/features/inspector/inspector-interaction.ts";
import {
  inspectorOpenForTask,
  reduceInspectorSession,
  taskHasInspectorFacts,
} from "../frontend/src/features/inspector/inspector-state.ts";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
if (!HTMLElement.prototype.scrollIntoView)
  HTMLElement.prototype.scrollIntoView = () => undefined;
if (!HTMLElement.prototype.scrollTo)
  HTMLElement.prototype.scrollTo = () => undefined;

const { cleanup, fireEvent, render, screen } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { TaskOverview } = await vite.ssrLoadModule(
  "/src/features/inspector/TaskOverview.tsx",
);
const { TaskContent } = await vite.ssrLoadModule(
  "/src/features/tasks/TaskContent.tsx",
);
const { FileChangesDrawer } = await vite.ssrLoadModule(
  "/src/features/files/FileChangesDrawer.tsx",
);
const { RunProcess } = await vite.ssrLoadModule(
  "/src/features/tasks/RunProcess.tsx",
);
const { deriveRunPresentation } = await vite.ssrLoadModule(
  "/src/features/tasks/run-presentation.ts",
);
const { ApprovalPanel } = await vite.ssrLoadModule(
  "/src/features/approvals/ApprovalPanel.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function run(overrides = {}) {
  return {
    id: "9",
    phase: "completed",
    input: {
      kind: "text",
      text: "Inspect the release",
      redacted: false,
    },
    output: {
      commentary: [],
      response: "Release is ready",
      responseKind: "final",
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    activity: null,
    outcome: "completed",
    cause: null,
    usage: { input: "12", output: "5", cacheRead: "0", cacheCreation: "0" },
    tools: [],
    ...overrides,
  };
}

function technicalTool(overrides = {}) {
  return {
    id: "tool-1",
    order: "1",
    name: "Read",
    input: "",
    progress: "",
    content: "",
    state: "completed",
    isError: false,
    elapsedMs: "12",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
    ...overrides,
  };
}

function task(overrides = {}) {
  return {
    id: "3",
    recentOrder: "1",
    title: "Release review",
    workspaceId: "1",
    binding: {},
    mcpAuthority: { kind: "unavailable", selection: null },
    lifecycle: "open",
    deletionStatus: "idle",
    continuationAvailable: true,
    archived: false,
    currentRunId: "0",
    currentRunPhase: null,
    lastRunOutcome: null,
    cause: null,
    context: { pressure: null, lastAutoCompact: null },
    runs: [],
    pendingUi: null,
    uiHistory: [],
    ...overrides,
  };
}

function renderInspector(value, locale = "en-US") {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale,
          setLocale() {},
          t: (id, values) => translate(locale, id, values),
        },
      },
      createElement(TaskOverview, {
        task: value,
        focusRequest: null,
        onClose() {},
        onFocusPending() {},
      }),
    ),
  );
}

function renderTaskContent(value, locale = "en-US") {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale,
          setLocale() {},
          t: (id, values) => translate(locale, id, values),
        },
      },
      createElement(TaskContent, {
        task: value,
        revision: "1",
        composerHasDraft: false,
        retryAvailable: false,
        responseDisabled: false,
        fileChangesEnabled: false,
        onPrepareRetry() {},
        onOpenTool() {},
        onPreviewFile() {},
        onReviewFileChanges() {},
        onRespond() {},
        renderPendingUi() {
          return null;
        },
      }),
    ),
  );
}

function localizedView(component, locale = "en-US") {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale,
        setLocale() {},
        t: (id, values) => translate(locale, id, values),
      },
    },
    component,
  );
}

function taskContentElement(value, revision = "1", overrides = {}) {
  return localizedView(
    createElement(TaskContent, {
      task: value,
      revision,
      composerHasDraft: false,
      retryAvailable: false,
      responseDisabled: false,
      fileChangesEnabled: false,
      onPrepareRetry() {},
      onOpenTool() {},
      onPreviewFile() {},
      onReviewFileChanges() {},
      onRespond() {},
      renderPendingUi() {
        return null;
      },
      ...overrides,
    }),
  );
}

function runProcessElement(
  value,
  { expanded = true, onExpandedChange = () => {}, onOpenTool } = {},
) {
  return localizedView(
    createElement(RunProcess, {
      presentation: deriveRunPresentation(value),
      expanded,
      onExpandedChange,
      onOpenTool,
    }),
  );
}

test("Inspector availability comes only from real Task facts", () => {
  assert.equal(taskHasInspectorFacts(null), false);
  assert.equal(taskHasInspectorFacts(task()), false);
  assert.equal(taskHasInspectorFacts(task({ runs: [run()] })), true);
  assert.equal(
    taskHasInspectorFacts(
      task({
        pendingUi: {
          requestId: "request-1",
          runId: "9",
          order: "1",
          redacted: false,
          kind: "permission",
          tool: "Bash",
          args: "",
        },
      }),
    ),
    true,
  );
});

test("Inspector distinguishes immutable MCP authority captured at Task creation", () => {
  assert.match(
    renderInspector(
      task({ mcpAuthority: { kind: "ready", selection: "selected" } }),
    ),
    /Tools selected/,
  );
  assert.match(
    renderInspector(
      task({ mcpAuthority: { kind: "ready", selection: "none" } }),
    ),
    /Ready · no tools selected/,
  );
  assert.match(
    renderInspector(
      task({ mcpAuthority: { kind: "unavailable", selection: null } }),
    ),
    /Unavailable/,
  );
});

test("attention auto-opens once per Task and request identity", () => {
  let state = {};
  state = reduceInspectorSession(state, {
    type: "task.observed",
    taskId: "task-a",
    attentionId: "run-1:request-1",
  });
  assert.equal(inspectorOpenForTask(state, "task-a"), true);

  state = reduceInspectorSession(state, {
    type: "panel.closed",
    taskId: "task-a",
  });
  const closed = state;
  state = reduceInspectorSession(state, {
    type: "task.observed",
    taskId: "task-a",
    attentionId: "run-1:request-1",
  });
  assert.equal(state, closed);
  assert.equal(inspectorOpenForTask(state, "task-a"), false);

  state = reduceInspectorSession(state, {
    type: "task.observed",
    taskId: "task-a",
    attentionId: "run-2:request-2",
  });
  assert.equal(inspectorOpenForTask(state, "task-a"), true);

  state = reduceInspectorSession(state, {
    type: "panel.closed",
    taskId: "task-a",
  });
  const closedAfterSecondRequest = state;
  state = reduceInspectorSession(state, {
    type: "task.observed",
    taskId: "task-a",
    attentionId: "run-1:request-1",
  });
  assert.equal(state, closedAfterSecondRequest);
  assert.equal(inspectorOpenForTask(state, "task-a"), false);
});

test("Inspector visibility stays isolated per Task and ignores content churn", () => {
  let state = reduceInspectorSession(
    {},
    {
      type: "panel.opened",
      taskId: "task-a",
    },
  );
  state = reduceInspectorSession(state, {
    type: "panel.closed",
    taskId: "task-b",
  });
  assert.equal(inspectorOpenForTask(state, "task-a"), true);
  assert.equal(inspectorOpenForTask(state, "task-b"), false);
  assert.equal(inspectorOpenForTask(state, "task-a"), true);
});

test("Inspector shows Work process without eagerly mounting raw tool output", () => {
  const markup = renderInspector(
    task({
      runs: [
        run({
          id: "8",
          usage: {
            input: "900",
            output: "100",
            cacheRead: "0",
            cacheCreation: "0",
          },
        }),
        run({
          id: "9",
          tools: [
            {
              id: "tool-1",
              order: "1",
              name: "Bash",
              input: "private input",
              progress: "private progress",
              content: "private raw output",
              state: "completed",
              isError: false,
              elapsedMs: "25",
              inputTruncated: false,
              progressTruncated: false,
              contentTruncated: false,
              redacted: false,
              fileRefs: [],
            },
          ],
        }),
      ],
      lastRunOutcome: "completed",
      context: {
        pressure: {
          sourceRunId: "9",
          currentTokens: "90",
          warningThreshold: "80",
          autoCompactThreshold: "100",
          blockingLimit: "120",
          severity: "warning",
        },
        lastAutoCompact: {
          sourceRunId: "9",
          dropped: "4",
          kept: "8",
          beforeTokens: "110",
          afterTokens: "70",
        },
      },
    }),
  );
  assert.match(markup, />Task overview</);
  assert.match(markup, />Last run</);
  assert.match(markup, />Work process</);
  assert.match(markup, />Bash</);
  assert.match(markup, /aria-expanded="false"/);
  assert.match(markup, />17</);
  assert.match(markup, />Context is filling up</);
  assert.match(markup, /90 tokens now · auto-compact at 100 · limit 120/);
  assert.match(markup, />110 → 70 tokens</);
  assert.doesNotMatch(
    markup,
    /1,000|private raw output|private input|INTERNAL_PROVIDER_RETRY/,
  );
  assert.doesNotMatch(markup, />Plan<|>Outputs<|>Files changed</);
});

test("Context and usage remains visible for cache-only usage", () => {
  const markup = renderInspector(
    task({
      runs: [
        run({
          usage: {
            input: "0",
            output: "0",
            cacheRead: "9",
            cacheCreation: "0",
          },
        }),
      ],
    }),
  );
  assert.match(markup, />Context and usage</);
  assert.match(markup, />Cache read<\/dt><dd>9</);
});

test("Work process mounts and removes one Tool detail on demand", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const value = task({
    runs: [
      run({
        tools: [
          {
            id: "tool-1",
            order: "1",
            name: "Bash",
            input: "private input",
            progress: "private progress",
            content: "private raw output",
            state: "completed",
            isError: false,
            elapsedMs: "25",
            inputTruncated: false,
            progressTruncated: false,
            contentTruncated: false,
            redacted: false,
            fileRefs: [],
          },
          {
            id: "tool-2",
            order: "2",
            name: "Read",
            input: "",
            progress: "",
            content: "second private output",
            state: "completed",
            isError: false,
            elapsedMs: "10",
            inputTruncated: false,
            progressTruncated: false,
            contentTruncated: false,
            redacted: false,
            fileRefs: [],
          },
        ],
      }),
    ],
  });
  const view = render(
    localizedView(
      createElement(TaskOverview, {
        task: value,
        focusRequest: null,
        onFocusPending() {},
      }),
    ),
  );

  assert.equal(screen.queryByText("private raw output"), null);
  const disclosure = screen.getByRole("button", { name: /Bash/ });
  assert.equal(disclosure.getAttribute("aria-expanded"), "false");
  await user.click(disclosure);
  assert.equal(disclosure.getAttribute("aria-expanded"), "true");
  assert.ok(screen.getByText("private raw output"));
  const secondDisclosure = screen.getByRole("button", { name: /Read/ });
  await user.click(secondDisclosure);
  assert.equal(screen.queryByText("private raw output"), null);
  assert.ok(screen.getByText("second private output"));
  assert.equal(disclosure.getAttribute("aria-expanded"), "false");
  await user.click(secondDisclosure);
  assert.equal(screen.queryByText("second private output"), null);

  await user.click(disclosure);
  assert.ok(screen.getByText("private raw output"));
  view.rerender(
    localizedView(
      createElement(TaskOverview, {
        task: {
          ...value,
          id: "task-b",
          runs: [
            {
              ...value.runs[0],
              id: "run-b",
              tools: [
                {
                  ...value.runs[0].tools[0],
                  content: "another private output",
                },
              ],
            },
          ],
        },
        focusRequest: null,
        onFocusPending() {},
      }),
    ),
  );
  assert.equal(screen.queryByText("another private output"), null);
  assert.equal(
    screen.getByRole("button", { name: /Bash/ }).getAttribute("aria-expanded"),
    "false",
  );
});

test("conversation separates commentary, Markdown response, and plain provisional output", () => {
  const active = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        outcome: null,
        activity: { kind: "writing_response" },
        output: {
          commentary: ["Checked **two files**."],
          response: "",
          responseKind: null,
          provisional: "Draft **not Markdown**",
          redacted: false,
          provisionalRedacted: false,
        },
      }),
    ],
  });
  const activeMarkup = renderTaskContent(active);
  assert.match(activeMarkup, />Preparing a response</);
  assert.match(activeMarkup, /data-streaming="false"/);
  assert.doesNotMatch(activeMarkup, /aria-expanded=/);
  assert.match(activeMarkup, /Checked <strong>two files<\/strong>\./);
  assert.match(activeMarkup, /Draft \*\*not Markdown\*\*/);
  assert.doesNotMatch(activeMarkup, /Draft <strong>not Markdown<\/strong>/);

  const completed = task({
    runs: [
      run({
        output: {
          commentary: ["A historical update"],
          response: "**Ready**",
          responseKind: "final",
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
      }),
    ],
  });
  const completedMarkup = renderTaskContent(completed);
  assert.doesNotMatch(completedMarkup, /aria-expanded=/);
  assert.match(completedMarkup, /A historical update/);
  assert.match(completedMarkup, /<strong>Ready<\/strong>/);
});

test("live revisions extend the narrative while replacing one bottom status in place", () => {
  const activeRun = run({
    phase: "running",
    outcome: null,
    activity: { kind: "thinking" },
    output: {
      commentary: ["I will inspect the structure."],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
  });
  const activeTask = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [activeRun],
  });
  const view = render(taskContentElement(activeTask));
  const statusSurface = document.querySelector(".run-process");
  assert.ok(statusSurface);
  assert.ok(screen.getByText("Analyzing"));

  view.rerender(
    taskContentElement(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            activity: { kind: "executing_tools", inFlight: "1" },
            output: {
              ...activeRun.output,
              commentary: [
                "I will inspect the structure.",
                "The structure is clear; now updating it.",
              ],
            },
            tools: [
              technicalTool({
                name: "Bash",
                state: "running",
                elapsedMs: "0",
              }),
            ],
          },
        ],
      },
      "2",
    ),
  );

  assert.equal(document.querySelectorAll(".run-process").length, 1);
  assert.equal(document.querySelector(".run-process"), statusSurface);
  assert.equal(document.querySelectorAll(".run-commentary-item").length, 2);
  assert.ok(screen.getByText("The structure is clear; now updating it."));
  assert.ok(screen.getByRole("button", { name: "Running an operation" }));
  assert.equal(screen.queryByText("Bash"), null);
});

test("discarded provisional output disappears on the next Snapshot revision", () => {
  const activeRun = run({
    phase: "running",
    outcome: null,
    activity: { kind: "writing_response" },
    output: {
      commentary: [],
      response: "",
      responseKind: null,
      provisional: "This segment may be discarded",
      redacted: false,
      provisionalRedacted: false,
    },
  });
  const activeTask = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [activeRun],
  });
  const view = render(taskContentElement(activeTask));
  assert.ok(screen.getByText("This segment may be discarded"));

  view.rerender(
    taskContentElement(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            activity: { kind: "waiting_model" },
            output: { ...activeRun.output, provisional: "" },
          },
        ],
      },
      "2",
    ),
  );
  assert.equal(screen.queryByText("This segment may be discarded"), null);
  assert.ok(screen.getByText("Waiting for the next step"));
});

test("Run status keeps technical Tool summaries behind explicit disclosure", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const opened = [];
  const expandedChanges = [];
  const value = run({
    phase: "running",
    outcome: null,
    activity: { kind: "executing_tools", inFlight: "1" },
    output: {
      commentary: ["Checked **two files**."],
      response: "",
      responseKind: null,
      provisional: "Live **plain text**",
      redacted: false,
      provisionalRedacted: false,
    },
    tools: [
      {
        id: "tool-1",
        order: "1",
        name: "Read",
        input: "private input",
        progress: "private progress",
        content: "private result",
        state: "running",
        isError: false,
        elapsedMs: "0",
        inputTruncated: false,
        progressTruncated: false,
        contentTruncated: false,
        redacted: false,
        fileRefs: [],
      },
    ],
  });
  render(
    runProcessElement(value, {
      onExpandedChange: (expanded) => expandedChanges.push(expanded),
      onOpenTool: (tool) => opened.push(tool.id),
    }),
  );

  const header = screen.getByRole("button", {
    name: /Inspecting the workspace/,
  });
  assert.equal(header.getAttribute("aria-expanded"), "true");
  assert.equal(screen.queryByText("two files", { selector: "strong" }), null);
  assert.equal(screen.queryByText("Live **plain text**"), null);
  assert.equal(screen.queryByText("private input"), null);
  assert.equal(screen.queryByText("private progress"), null);
  assert.equal(screen.queryByText("private result"), null);

  await user.click(
    screen.getByRole("button", { name: "View details for Read" }),
  );
  assert.deepEqual(opened, ["tool-1"]);
  await user.click(header);
  assert.deepEqual(expandedChanges, [false]);
});

test("terminal Run process summarizes Tool evidence without implying Run failure", () => {
  const value = run({
    output: {
      commentary: ["Finished checking"],
      response: "Done",
      responseKind: "final",
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    tools: [
      {
        id: "tool-1",
        order: "1",
        name: "Read",
        input: "",
        progress: "",
        content: "",
        state: "completed",
        isError: false,
        elapsedMs: "12",
        inputTruncated: false,
        progressTruncated: false,
        contentTruncated: false,
        redacted: false,
        fileRefs: [],
      },
      {
        id: "tool-2",
        order: "2",
        name: "Bash",
        input: "",
        progress: "",
        content: "",
        state: "failed",
        isError: true,
        elapsedMs: "4",
        inputTruncated: false,
        progressTruncated: false,
        contentTruncated: false,
        redacted: false,
        fileRefs: [],
      },
    ],
  });
  const markup = renderToStaticMarkup(
    runProcessElement(value, { expanded: false }),
  );
  assert.match(markup, />Work process</);
  assert.match(markup, /2 operations/);
  assert.doesNotMatch(markup, /1 failed/);
  assert.doesNotMatch(markup, /Finished checking/);
  assert.doesNotMatch(markup, />Work failed</);
});

test("technical process disclosure remains user-controlled across revisions and Task switches", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const active = task({
    id: "task-a",
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        outcome: null,
        activity: { kind: "writing_response" },
        output: {
          commentary: ["Checking the workspace"],
          response: "",
          responseKind: null,
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
        tools: [technicalTool({ state: "running", elapsedMs: "0" })],
      }),
    ],
  });
  const view = render(taskContentElement(active));
  let disclosure = screen.getByRole("button", {
    name: "Preparing a response",
  });
  assert.equal(disclosure.getAttribute("aria-expanded"), "false");
  await user.click(disclosure);
  disclosure = screen.getByRole("button", { name: "Preparing a response" });
  assert.equal(disclosure.getAttribute("aria-expanded"), "true");

  view.rerender(
    taskContentElement(
      {
        ...active,
        runs: [
          {
            ...active.runs[0],
            output: {
              ...active.runs[0].output,
              commentary: ["Checking the workspace", "Still working"],
            },
          },
        ],
      },
      "2",
    ),
  );
  disclosure = screen.getByRole("button", { name: "Preparing a response" });
  assert.equal(disclosure.getAttribute("aria-expanded"), "true");

  view.rerender(taskContentElement(task({ id: "task-b" }), "3"));
  assert.equal(
    screen.queryByRole("button", { name: "Preparing a response" }),
    null,
  );
  view.rerender(taskContentElement(active, "4"));
  disclosure = screen.getByRole("button", { name: "Preparing a response" });
  assert.equal(disclosure.getAttribute("aria-expanded"), "true");
});

test("successful terminal keeps commentary visible and technical process collapsed", () => {
  const activeRun = run({
    phase: "running",
    outcome: null,
    activity: { kind: "writing_response" },
    output: {
      commentary: ["Working through the task"],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    tools: [technicalTool({ state: "running", elapsedMs: "0" })],
  });
  const active = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [activeRun],
  });
  const view = render(taskContentElement(active));
  const completed = task({
    runs: [
      {
        ...activeRun,
        phase: "completed",
        activity: null,
        outcome: "completed",
        output: {
          ...activeRun.output,
          response: "Final response",
          responseKind: "final",
        },
        tools: [technicalTool()],
      },
    ],
  });
  view.rerender(taskContentElement(completed, "2"));
  const disclosure = screen.getByRole("button", { name: /^Work process/ });
  assert.equal(disclosure.getAttribute("aria-expanded"), "false");
  assert.ok(screen.getByText("Working through the task"));
  assert.ok(screen.getByText("Final response"));
});

test("terminal transition preserves reading position without expanding technical details", () => {
  const activeRun = run({
    phase: "running",
    outcome: null,
    activity: { kind: "thinking" },
    output: {
      commentary: ["Evidence the reader is reviewing"],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    tools: [technicalTool({ state: "running", elapsedMs: "0" })],
  });
  const active = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [activeRun],
  });
  const view = render(taskContentElement(active));
  const viewport = document.querySelector(".ai-conversation-viewport");
  Object.defineProperties(viewport, {
    scrollHeight: { configurable: true, value: 1200 },
    clientHeight: { configurable: true, value: 400 },
    scrollTop: { configurable: true, writable: true, value: 160 },
  });
  fireEvent.scroll(viewport);

  view.rerender(
    taskContentElement(
      task({
        runs: [
          {
            ...activeRun,
            phase: "completed",
            activity: null,
            outcome: "completed",
            output: {
              ...activeRun.output,
              response: "Final response",
              responseKind: "final",
            },
            tools: [technicalTool()],
          },
        ],
      }),
      "2",
    ),
  );
  const disclosure = screen.getByRole("button", { name: /^Work process/ });
  assert.equal(disclosure.getAttribute("aria-expanded"), "false");
  assert.ok(screen.getByText("Evidence the reader is reviewing"));
  assert.ok(screen.getByRole("button", { name: "Jump to latest" }));
});

test("Task switches restore each Task reading position without cross-contamination", () => {
  const taskA = task({ id: "task-a", runs: [run({ id: "run-a" })] });
  const taskB = task({ id: "task-b", runs: [run({ id: "run-b" })] });
  const view = render(taskContentElement(taskA));
  const viewport = document.querySelector(".ai-conversation-viewport");
  Object.defineProperties(viewport, {
    scrollHeight: { configurable: true, value: 1400 },
    clientHeight: { configurable: true, value: 400 },
    scrollTop: { configurable: true, writable: true, value: 180 },
  });
  fireEvent.scroll(viewport);

  view.rerender(taskContentElement(taskB, "2"));
  viewport.scrollTop = 520;
  fireEvent.scroll(viewport);
  view.rerender(taskContentElement(taskA, "3"));
  assert.equal(viewport.scrollTop, 180);
  assert.ok(screen.getByRole("button", { name: "Jump to latest" }));
});

test("Tool summary forwards exact Run, Tool, and opener identity", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const calls = [];
  const value = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        outcome: null,
        activity: { kind: "executing_tools", inFlight: "1" },
        tools: [
          {
            id: "tool-7",
            order: "1",
            name: "Bash",
            input: "private input",
            progress: "",
            content: "",
            state: "running",
            isError: false,
            elapsedMs: "0",
            inputTruncated: false,
            progressTruncated: false,
            contentTruncated: false,
            redacted: false,
            fileRefs: [],
          },
        ],
      }),
    ],
  });
  render(
    taskContentElement(value, "1", {
      onOpenTool: (runId, toolId, opener) =>
        calls.push({ runId, toolId, opener }),
    }),
  );
  await user.click(
    screen.getByRole("button", { name: "Running an operation" }),
  );
  await user.click(
    screen.getByRole("button", { name: "View details for Bash" }),
  );
  assert.equal(calls.length, 1);
  assert.equal(calls[0].runId, "9");
  assert.equal(calls[0].toolId, "tool-7");
  assert.ok(calls[0].opener instanceof HTMLButtonElement);
  assert.equal(screen.queryByText("private input"), null);
});

test("Inspector focus request opens the exact historical Tool detail once", async () => {
  const historical = run({
    id: "8",
    tools: [
      {
        id: "tool-8",
        order: "1",
        name: "Bash",
        input: "historical input",
        progress: "",
        content: "historical result",
        state: "completed",
        isError: false,
        elapsedMs: "8",
        inputTruncated: false,
        progressTruncated: false,
        contentTruncated: false,
        redacted: false,
        fileRefs: [],
      },
    ],
  });
  const current = run({ id: "9", tools: [] });
  render(
    localizedView(
      createElement(TaskOverview, {
        task: task({
          currentRunId: "9",
          runs: [historical, current],
        }),
        focusRequest: {
          taskId: "3",
          section: "work_process",
          runId: "8",
          toolId: "tool-8",
          nonce: 1,
        },
        onFocusPending() {},
      }),
    ),
  );
  await new Promise((resolve) => requestAnimationFrame(resolve));
  assert.ok(screen.getByText("historical input"));
  assert.ok(screen.getByText("historical result"));
  const toolButton = screen.getByRole("button", { name: /Bash/ });
  assert.equal(toolButton.getAttribute("aria-expanded"), "true");
  assert.equal(document.activeElement, toolButton);
});

test("partial output and terminal failure render one composite notice", () => {
  const value = task({
    runs: [
      run({
        phase: "failed",
        outcome: "failed",
        cause: "timeout",
        output: {
          commentary: [],
          response: "An incomplete answer",
          responseKind: "partial",
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
      }),
    ],
  });
  const markup = renderTaskContent(value);
  assert.match(markup, />Work failed before the response was complete</);
  assert.equal((markup.match(/class="ai-activity"/g) ?? []).length, 1);
  assert.doesNotMatch(markup, />Work failed</);
});

test("typed Run activity uses safe localized labels", () => {
  const thinkingRun = run({
    phase: "running",
    activity: { kind: "thinking" },
    outcome: null,
    output: {
      commentary: [],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
  });
  const thinkingTask = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [thinkingRun],
  });
  const thinkingContent = renderTaskContent(thinkingTask, "zh-CN");
  const thinkingInspector = renderInspector(thinkingTask, "zh-CN");
  assert.match(thinkingContent, />正在分析</);
  assert.match(thinkingInspector, />正在分析</);

  const writingTask = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        activity: { kind: "writing_response" },
        outcome: null,
      }),
    ],
  });
  assert.match(renderTaskContent(writingTask, "zh-CN"), />正在组织回复</);

  for (const [activity, expected] of [
    [{ kind: "starting" }, "正在准备"],
    [{ kind: "executing_tools", inFlight: "2" }, "正在处理"],
    [
      { kind: "retrying_provider", attempt: "1", max: "2", delayMs: "50" },
      "正在重试连接",
    ],
    [{ kind: "compacting_context" }, "正在整理上下文"],
    [{ kind: "finalizing" }, "正在整理结果"],
  ]) {
    const activityTask = task({
      currentRunId: "9",
      currentRunPhase: "running",
      runs: [run({ phase: "running", activity, outcome: null })],
    });
    assert.match(
      renderTaskContent(activityTask, "zh-CN"),
      new RegExp(`>${expected}<`),
    );
    assert.match(
      renderInspector(activityTask, "zh-CN"),
      new RegExp(`>${expected}<`),
    );
    if (activity.kind === "retrying_provider") {
      assert.match(
        renderTaskContent(activityTask, "zh-CN"),
        /第 1\/2 次尝试 · 50 毫秒后重试/,
      );
    }
  }

  const waitingModel = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        activity: { kind: "waiting_model" },
        outcome: null,
      }),
    ],
  });
  assert.match(renderTaskContent(waitingModel, "zh-CN"), />正在等待下一步</);
  assert.match(renderInspector(waitingModel, "zh-CN"), />正在等待下一步</);

  const stoppingTask = task({
    currentRunId: "9",
    currentRunPhase: "stopping",
    runs: [
      run({
        phase: "stopping",
        activity: { kind: "stopping" },
        outcome: null,
      }),
    ],
  });
  const stoppingContent = renderTaskContent(stoppingTask, "zh-CN");
  assert.match(stoppingContent, />正在停止</);
  assert.doesNotMatch(stoppingContent, />正在分析</);
});

test("Run file references render as preview entry without change semantics", () => {
  const referenced = task({
    currentRunId: "0",
    currentRunPhase: null,
    runs: [
      run({
        output: {
          commentary: [],
          response: "Done",
          responseKind: "final",
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
        tools: [
          {
            id: "tool-1",
            order: "1",
            name: "Read",
            input: "{}",
            progress: "",
            content: "ok",
            state: "completed",
            isError: false,
            elapsedMs: "1",
            inputTruncated: false,
            progressTruncated: false,
            contentTruncated: false,
            redacted: false,
            fileRefs: [
              {
                id: "file-1",
                title: "main.zig",
                displayPath: "src/main.zig",
              },
            ],
          },
        ],
      }),
    ],
  });
  const markup = renderTaskContent(referenced);
  assert.match(markup, />Referenced files</);
  assert.match(markup, /src\/main\.zig/);
  assert.doesNotMatch(markup, /Files changed|modified|Output/);
});

test("Run File Changes summary is capability-gated and preserves incomplete zero-record truth", () => {
  const recorded = task({
    runs: [
      run({
        fileChanges: {
          observation: "complete",
          changes: [
            {
              id: "change-1",
              order: "1",
              kind: "modified",
              status: "applied",
              displayPath: "src/main.zig",
              fromDisplayPath: null,
              beforeBytes: "12",
              afterBytes: "14",
              diffAvailable: true,
              diffComplete: true,
              redacted: false,
            },
          ],
        },
      }),
    ],
  });
  const hidden = renderToStaticMarkup(taskContentElement(recorded));
  assert.doesNotMatch(hidden, /File changes|Review changes/);

  const visible = renderToStaticMarkup(
    taskContentElement(recorded, "1", { fileChangesEnabled: true }),
  );
  assert.match(visible, />File changes</);
  assert.match(visible, />1 files · 1 changes</);
  assert.match(visible, />Review changes</);

  const incomplete = task({
    runs: [
      run({
        fileChanges: { observation: "incomplete", changes: [] },
      }),
    ],
  });
  const incompleteMarkup = renderToStaticMarkup(
    taskContentElement(incomplete, "1", { fileChangesEnabled: true }),
  );
  assert.match(incompleteMarkup, /The file change record may be incomplete/);
  assert.doesNotMatch(incompleteMarkup, />Review changes</);
});

test("File Changes Drawer keeps repeated records, typed warnings, and narrow-screen structure", async () => {
  const changes = [
    {
      id: "change-1",
      order: "1",
      kind: "modified",
      status: "applied",
      displayPath: "src/main.zig",
      fromDisplayPath: null,
      beforeBytes: "12",
      afterBytes: "14",
      diffAvailable: true,
      diffComplete: false,
      redacted: true,
    },
    {
      id: "change-2",
      order: "2",
      kind: "moved",
      status: "partial",
      displayPath: "src/main.zig",
      fromDisplayPath: "src/old-main.zig",
      beforeBytes: "14",
      afterBytes: "14",
      diffAvailable: false,
      diffComplete: false,
      redacted: false,
    },
  ];
  let selected = null;
  render(
    localizedView(
      createElement(FileChangesDrawer, {
        state: {
          observation: "incomplete",
          changes,
          selected: changes[0],
          phase: "settled",
          diff: {
            status: "ready",
            content: "@@ -1 +1 @@\n-secret\n+safe",
            complete: false,
            redacted: true,
          },
        },
        onSelect(change) {
          selected = change;
        },
        onRefresh() {},
        onClose() {},
      }),
    ),
  );

  const dialog = screen.getByRole("dialog", { name: "Review changes" });
  assert.match(dialog.className, /max-\[620px\]:w-full/);
  assert.ok(
    dialog.querySelector('[class*="max-[620px]:grid-cols-1"]'),
    "Drawer did not retain its narrow-screen single-column layout",
  );
  assert.ok(screen.getByRole("navigation", { name: "Changed files" }));
  assert.ok(screen.getByRole("status"));
  assert.match(dialog.textContent, /Some file change records may be missing/);
  assert.match(dialog.textContent, /Change 1/);
  assert.match(dialog.textContent, /Change 2/);
  assert.match(dialog.textContent, /Modified/);
  assert.match(dialog.textContent, /Moved/);
  assert.match(dialog.textContent, /Recorded diff is incomplete/);
  assert.match(dialog.textContent, /Known sensitive content was hidden/);
  assert.match(dialog.textContent, /-secret/);
  assert.match(dialog.textContent, /\+safe/);
  assert.doesNotMatch(dialog.textContent, /Accept|Reject|Revert|Stage/);

  const user = userEvent.setup({ document: dom.window.document });
  await user.click(screen.getByRole("button", { name: /Change 2 Moved/ }));
  assert.equal(selected, changes[1]);
});

test("permission intervention never exposes internal Run identity", () => {
  const markup = renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(ApprovalPanel, {
        pending: {
          requestId: "request-1",
          runId: "8472",
          order: "1",
          redacted: false,
          kind: "permission",
          tool: "Bash",
          args: "npm test",
          availableChoices: ["deny_once", "allow_once"],
        },
        busy: false,
        responsePhase: "idle",
        respond() {},
      }),
    ),
  );
  assert.match(markup, /class="ai-intervention"/);
  assert.match(markup, /data-kind="permission"/);
  assert.match(markup, />Response required</);
  assert.match(markup, /class="detail-field-label">Arguments<\/p>/);
  assert.match(markup, /class="code-block-preview"/);
  assert.doesNotMatch(markup, /8472|work item/i);
});

test("Escape dismissal and focus return preserve the real Inspector opener", () => {
  assert.equal(shouldDismissInspectorForEscape(true, "Escape", false), true);
  assert.equal(shouldDismissInspectorForEscape(false, "Escape", false), false);
  assert.equal(shouldDismissInspectorForEscape(true, "Escape", true), false);
  assert.equal(shouldDismissInspectorForEscape(true, "Enter", false), false);

  const opener = { isConnected: true, focus() {} };
  const fallback = { isConnected: true, focus() {} };
  assert.equal(inspectorFocusReturnTarget(opener, fallback), opener);
  assert.equal(
    inspectorFocusReturnTarget({ ...opener, isConnected: false }, fallback),
    fallback,
  );
  assert.equal(
    inspectorFocusReturnTarget(
      { ...opener, hasAttribute: (name) => name === "disabled" },
      fallback,
    ),
    fallback,
  );
});
