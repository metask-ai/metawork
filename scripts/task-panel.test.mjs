import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

import {
  sidePanelFocusReturnTarget,
  shouldDismissSidePanelForEscape,
} from "../frontend/src/app/side-panel-interaction.ts";
import {
  emptyTaskPanelTarget,
  resolveTaskPanelTarget,
} from "../frontend/src/features/task-panel/task-panel-state.ts";

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

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { ToolDetailView } = await vite.ssrLoadModule(
  "/src/features/task-panel/ToolDetailView.tsx",
);
const { TaskInformation } = await vite.ssrLoadModule(
  "/src/features/tasks/TaskInformation.tsx",
);
const { ConversationContext } = await vite.ssrLoadModule(
  "/src/features/composer/ConversationContext.tsx",
);
const { useTaskPanelTarget } = await vite.ssrLoadModule(
  "/src/features/task-panel/useTaskPanelTarget.ts",
);
const { TaskContent } = await vite.ssrLoadModule(
  "/src/features/tasks/TaskContent.tsx",
);
const { FileChangesView } = await vite.ssrLoadModule(
  "/src/features/task-panel/FileChangesView.tsx",
);
const { FilePreviewRefreshAction, FilePreviewView } = await vite.ssrLoadModule(
  "/src/features/task-panel/FilePreviewView.tsx",
);
const { TaskPanel } = await vite.ssrLoadModule(
  "/src/features/task-panel/TaskPanel.tsx",
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

function terminal(
  outcome = "completed",
  cause = null,
  diagnosticDisposition = "absent",
) {
  return { outcome, cause, diagnosticDisposition };
}

function run(overrides = {}) {
  return {
    id: "9",
    phase: "completed",
    execution: {
      generation: "7",
      protocol: "anthropic_messages",
      model: "fixture-model",
    },
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
    terminal: terminal(),
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
    bash: null,
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

test("Bash detail shows known fields with collapsed raw evidence and explicit empty streams", () => {
  const tool = technicalTool({
    name: "Bash",
    input: '{"command":"pwd"}',
    content: "raw envelope",
    bash: {
      command: "pwd",
      description: "Inspect workspace",
      result: {
        exitCode: 0,
        stdout: "",
        stderr: "partial warning",
        stdoutIncomplete: false,
        stderrIncomplete: true,
      },
    },
  });
  const view = render(localizedView(createElement(ToolDetailView, { tool })));
  assert.ok(screen.getByText("pwd"));
  assert.ok(screen.getByText("No standard output captured."));
  assert.ok(screen.getByText("partial warning"));
  assert.equal(view.container.querySelector("details").open, false);
  assert.ok(
    view.container
      .querySelector("details")
      .textContent.includes("raw envelope"),
  );
  view.rerender(
    localizedView(
      createElement(ToolDetailView, { tool: { ...tool, bash: null } }),
    ),
  );
  assert.equal(view.container.querySelector("details"), null);
  assert.ok(screen.getByText("raw envelope"));
});

test("expanded process shows bounded descriptions and progress without interpreting text", () => {
  const value = run({
    tools: [
      technicalTool({
        name: "Bash",
        progress: "<script>" + "x".repeat(500),
        bash: {
          command: "pwd",
          description: "Inspect " + "d".repeat(300),
          result: null,
        },
      }),
    ],
  });
  const view = render(
    localizedView(
      createElement(RunProcess, {
        presentation: deriveRunPresentation(value),
        expanded: true,
        onExpandedChange() {},
      }),
    ),
  );
  assert.equal(
    view.container.querySelector(".run-process-tool-description").textContent
      .length,
    161,
  );
  assert.equal(
    view.container.querySelector(".run-process-tool-progress").textContent
      .length,
    241,
  );
  assert.equal(view.container.querySelector("script"), null);
});

function fileChange(overrides = {}) {
  return {
    id: "change-1",
    order: "1",
    kind: "modified",
    status: "applied",
    displayPath: "src/main.ts",
    fromDisplayPath: null,
    beforeBytes: "1",
    afterBytes: "2",
    diffAvailable: true,
    diffComplete: true,
    redacted: false,
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
    context: { pressure: null, lastAutoCompact: null },
    runs: [],
    pendingUi: null,
    uiHistory: [],
    ...overrides,
  };
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
      snapshotReceivedAt: null,
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

test("elapsed display advances without snapshots, rebases on receipt and disappears at terminal", (context) => {
  let now = 1000;
  let tick;
  let cleared = 0;
  context.mock.method(performance, "now", () => now);
  context.mock.method(window, "setInterval", (callback) => {
    tick = callback;
    return 1;
  });
  context.mock.method(window, "clearInterval", () => {
    cleared++;
  });
  const element = (value, elapsedMs, snapshotReceivedAt) =>
    localizedView(
      createElement(RunProcess, {
        presentation: deriveRunPresentation(value),
        elapsedMs,
        snapshotReceivedAt,
        expanded: false,
        onExpandedChange() {},
      }),
    );
  const active = run({
    phase: "running",
    activity: { kind: "thinking" },
    terminal: null,
  });
  const view = render(element(active, "120000", 1000));
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 2:00",
  );
  assert.equal(
    view.container
      .querySelector(".run-process-elapsed")
      .closest('[aria-live="polite"]'),
    null,
  );
  now = 15000;
  act(() => tick());
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 2:14",
  );
  view.rerender(element(active, "134000", 15000));
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 2:14",
  );
  view.rerender(element(active, "6000", 15000));
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 0:06",
  );
  view.rerender(element(run(), null, 15000));
  assert.equal(view.container.querySelector(".run-process-elapsed"), null);
  assert.equal(cleared, 1);
  view.unmount();
});

test("unsynchronized status pauses elapsed and resumes only from the received Host sample", (ctx) => {
  let now = 1000,
    tick,
    cleared = 0;
  ctx.mock.method(performance, "now", () => now);
  ctx.mock.method(window, "setInterval", (callback) => {
    tick = callback;
    return 1;
  });
  ctx.mock.method(window, "clearInterval", () => {
    cleared++;
  });
  const active = run({
    phase: "running",
    activity: { kind: "waiting_model" },
    terminal: null,
  });
  const element = (
    synchronized,
    elapsedMs = "120000",
    snapshotReceivedAt = 1000,
    requestingStop = false,
  ) =>
    localizedView(
      createElement(RunProcess, {
        presentation: deriveRunPresentation(active),
        synchronized,
        elapsedMs,
        snapshotReceivedAt,
        requestingStop,
        expanded: false,
        onExpandedChange() {},
      }),
    );
  const view = render(element(true));
  now = 15000;
  act(() => tick());
  view.rerender(element(false));
  assert.ok(screen.getByText("Status not synchronized"));
  assert.equal(
    view.container.querySelector(".run-process").dataset.active,
    "false",
  );
  assert.equal(cleared, 1);
  now = 90000;
  view.rerender(element(false));
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 2:14",
  );
  view.rerender(element(true, "209000", 90000));
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 3:29",
  );
  now = 92000;
  act(() => tick());
  assert.equal(
    view.container.querySelector(".run-process-elapsed").textContent,
    "Turn elapsed 3:31",
  );
  view.rerender(element(true, "211000", 92000, true));
  assert.ok(screen.getByText("Requesting stop…"));
  assert.equal(
    view.container.querySelectorAll(".run-process-heading").length,
    1,
  );
});

test("queued and starting are distinct and missing Host timing is not invented", () => {
  const queued = run({
    phase: "queued",
    activity: { kind: "queued" },
    terminal: null,
  });
  const markup = renderToStaticMarkup(runProcessElement(queued));
  assert.match(markup, />Queued</);
  assert.doesNotMatch(markup, /run-process-elapsed/);
  const starting = run({
    phase: "running",
    activity: { kind: "starting" },
    terminal: null,
  });
  assert.match(
    renderToStaticMarkup(runProcessElement(starting)),
    />Getting started</,
  );
});

test("conversation separates commentary, Markdown response, and plain provisional output", () => {
  const active = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        terminal: null,
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
    terminal: null,
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
    terminal: null,
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
    terminal: null,
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
  assert.ok(screen.getByText("private progress"));
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
        terminal: null,
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
    terminal: null,
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
        terminal: terminal(),
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
    terminal: null,
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
            terminal: terminal(),
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
        terminal: null,
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

test("partial output and terminal failure render one composite notice", () => {
  const value = task({
    runs: [
      run({
        phase: "failed",
        terminal: terminal("failed", "timeout"),
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

test("typed Agent failures render accurate recovery guidance", () => {
  const cases = [
    [
      "tool_failure",
      "Tool execution failed and could not recover.",
      "工具执行失败且未能恢复",
    ],
    [
      "image_input_unsupported",
      "The current model does not support image input.",
      "当前模型不支持图片输入",
    ],
  ];

  for (const [cause, expectedEnglish, expectedChinese] of cases) {
    const value = task({
      runs: [run({ phase: "failed", terminal: terminal("failed", cause) })],
    });
    assert.match(
      renderTaskContent(value),
      new RegExp(expectedEnglish.replaceAll(".", "\\.")),
    );
    assert.match(
      renderTaskContent(value, "zh-CN"),
      new RegExp(expectedChinese),
    );
  }
});

test("provider failure notices explain impact without duplicating diagnostics", () => {
  const failedWithoutResponse = task({
    runs: [
      run({
        phase: "failed",
        output: {
          commentary: [],
          response: "",
          responseKind: null,
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
        terminal: terminal("failed", "provider_failure"),
      }),
    ],
  });
  const absent = renderTaskContent(failedWithoutResponse);
  assert.match(absent, />Model service request failed</);
  assert.match(absent, /This run did not produce a usable response\./);
  assert.doesNotMatch(
    absent,
    /MetaWork did not receive additional diagnostics for this run\./,
  );
  render(
    taskContentElement(failedWithoutResponse, "1", {
      retryAvailable: true,
    }),
  );
  assert.ok(
    screen.getByRole("button", { name: "Copy instruction to Composer" }),
  );
  assert.equal(
    screen.queryByRole("button", { name: "Use instruction again" }),
    null,
  );
  cleanup();

  const partialWithWithheldDiagnostic = task({
    runs: [
      run({
        phase: "failed",
        output: {
          commentary: [],
          response: "Partial result",
          responseKind: "partial",
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
        terminal: terminal("failed", "provider_failure", "withheld"),
      }),
    ],
  });
  const withheld = renderTaskContent(partialWithWithheldDiagnostic);
  assert.match(withheld, /produced only a partial response/);
  assert.doesNotMatch(withheld, /current security boundary/);

  for (const unsupportedGuess of [
    /401/i,
    /rate limit/i,
    /network/i,
    /api key/i,
  ]) {
    assert.doesNotMatch(absent, unsupportedGuess);
    assert.doesNotMatch(withheld, unsupportedGuess);
  }
});

test("provider failure details open for the exact historical Run", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const historical = run({
    id: "8",
    phase: "failed",
    execution: {
      generation: "4",
      protocol: "openai_responses",
      model: "historical-model",
    },
    output: {
      commentary: [],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    terminal: terminal("failed", "provider_failure", "withheld"),
  });
  const current = run({ id: "9" });
  const value = task({ runs: [historical, current] });

  render(taskContentElement(value));
  const summary = screen.getByText("View run details");
  const diagnostics = summary.closest("details");
  assert.equal(diagnostics.open, false);
  assert.equal(screen.queryByText("historical-model"), null);
  await user.click(summary);
  assert.equal(diagnostics.open, true);
  assert.match(diagnostics.textContent, /current security boundary/);
  assert.match(diagnostics.textContent, /historical-model/);
  assert.match(diagnostics.textContent, /OpenAI Responses/);
  assert.match(diagnostics.textContent, /provider_failure/);
  assert.doesNotMatch(diagnostics.textContent, /fixture-model/);
  await user.click(summary);
  assert.equal(screen.queryByText("historical-model"), null);
  assert.equal(translate("zh-CN", "inspector.diagnostic_run"), "运行 ID");
});

test("inline diagnostics stay absent for other failures and preserve safe exact Run facts", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const value = task({
    runs: [
      run({
        phase: "failed",
        execution: {
          generation: "99",
          protocol: "openai_responses",
          model: "<img src=x onerror=alert(1)>",
        },
        terminal: terminal("failed", "provider_failure", "absent"),
      }),
    ],
  });
  render(taskContentElement(value));
  const summary = screen.getByText("View run details");
  assert.ok(screen.queryByText("<img src=x onerror=alert(1)>") === null);
  summary.focus();
  await user.click(summary);
  assert.ok(summary.closest("details").open);
  assert.ok(
    screen.getByText(
      "MetaWork did not receive additional diagnostics for this run.",
    ),
  );
  assert.ok(screen.getByText("<img src=x onerror=alert(1)>"));
  assert.ok(summary.closest("details").querySelector("img") === null);
  await user.click(summary);
  assert.ok(!summary.closest("details").open);
  assert.ok(screen.queryByText("<img src=x onerror=alert(1)>") === null);
  cleanup();
  for (const cause of [null, "tool_failure"]) {
    render(
      taskContentElement(
        task({
          runs: [run({ phase: "failed", terminal: terminal("failed", cause) })],
        }),
      ),
    );
    assert.ok(screen.queryByText("View run details") === null);
    cleanup();
  }
});

test("typed Run activity uses safe localized labels", () => {
  const thinkingRun = run({
    phase: "running",
    activity: { kind: "thinking" },
    terminal: null,
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
  assert.match(thinkingContent, />正在分析</);

  const writingTask = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        activity: { kind: "writing_response" },
        terminal: null,
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
      runs: [run({ phase: "running", activity, terminal: null })],
    });
    assert.match(
      renderTaskContent(activityTask, "zh-CN"),
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
        terminal: null,
      }),
    ],
  });
  assert.match(renderTaskContent(waitingModel, "zh-CN"), />正在等待下一步</);

  const stoppingTask = task({
    currentRunId: "9",
    currentRunPhase: "stopping",
    runs: [
      run({
        phase: "stopping",
        activity: { kind: "stopping" },
        terminal: null,
      }),
    ],
  });
  const stoppingContent = renderTaskContent(stoppingTask, "zh-CN");
  assert.match(stoppingContent, />正在停止</);
  assert.doesNotMatch(stoppingContent, />正在分析</);
});

test("Run file previews belong to expanded tool operations, never a reply footer", () => {
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
        tools: Array.from({ length: 8 }, (_, index) =>
          technicalTool({
            id: `tool-${index}`,
            order: String(index + 1),
            fileRefs: [
              {
                id: `file-${index}`,
                title: "index.html",
                displayPath: "index.html",
              },
            ],
          }),
        ),
      }),
    ],
  });
  const previews = [],
    details = [];
  render(
    taskContentElement(referenced, "1", {
      onPreviewFile: (...args) => previews.push(args),
      onOpenTool: (...args) => details.push(args),
    }),
  );
  assert.equal(document.querySelector(".ai-exchange footer"), null);
  assert.equal(
    screen.queryByRole("button", { name: "Preview index.html" }),
    null,
  );
  fireEvent.click(screen.getByRole("button", { name: /Work process/ }));
  const rows = [...document.querySelectorAll(".run-process-tools > li")];
  assert.equal(rows.length, 8);
  for (const [index, row] of rows.entries()) {
    const preview = within(row).getByRole("button", {
      name: "Preview index.html",
    });
    const detail = within(row).getByRole("button", {
      name: "View details for Read",
    });
    assert.equal(preview.parentElement.closest("button"), null);
    fireEvent.click(preview);
    assert.equal(details.length, index);
    assert.deepEqual(previews[index].slice(0, 3), [
      "3",
      "9",
      referenced.runs[0].tools[index].fileRefs[0],
    ]);
    assert.equal(previews[index][3], preview);
    fireEvent.click(detail);
    assert.deepEqual(details[index], ["9", `tool-${index}`, detail]);
  }
  fireEvent.click(screen.getByRole("button", { name: /Work process/ }));
  assert.equal(
    screen.queryByRole("button", { name: "Preview index.html" }),
    null,
  );
  assert.equal(document.querySelector(".ai-exchange footer"), null);
});

test("conversation references stay in their owning Run and become plain text when invalidated", () => {
  const referenced = task({
    currentRunId: "0",
    currentRunPhase: null,
    runs: ["9", "10"].map((id) =>
      run({
        id,
        output: {
          commentary: [],
          response: "已生成 `report.txt`。",
          responseKind: "final",
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
        tools: [
          technicalTool({
            fileRefs: [
              {
                id: `ref-${id}`,
                title: "report.txt",
                displayPath: "report.txt",
              },
            ],
          }),
        ],
      }),
    ),
  });
  const opened = [];
  const props = { onPreviewFile: (...args) => opened.push(args) };
  const view = render(taskContentElement(referenced, "1", props));
  const openers = screen.getAllByRole("button", { name: "Preview report.txt" });
  fireEvent.click(openers[0]);
  fireEvent.click(openers[1]);
  assert.deepEqual(
    opened.map(([taskId, runId, reference]) => [taskId, runId, reference.id]),
    [
      ["3", "9", "ref-9"],
      ["3", "10", "ref-10"],
    ],
  );
  const next = structuredClone(referenced);
  next.runs[0].tools = [];
  view.rerender(taskContentElement(next, "2", props));
  assert.equal(
    screen.getAllByRole("button", { name: "Preview report.txt" }).length,
    1,
  );
  assert.equal(document.querySelectorAll(".agent-response code").length, 2);
  assert.equal(
    document.querySelector(".agent-response").querySelector("button"),
    null,
  );
  assert.equal(document.querySelector(".run-process-files"), null);
});

test("Run File Changes summary is capability-gated and preserves incomplete zero-record truth", () => {
  const recorded = task({
    runs: [
      run({
        tools: [technicalTool()],
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
  assert.match(visible, />1 file</);
  assert.doesNotMatch(visible, /1 changes/);
  assert.match(visible, />Review changes</);
  assert.match(
    visible,
    /<button[^>]*>.*File changes.*Review changes.*<\/button>/,
  );
  assert.ok(
    visible.indexOf(">File changes<") < visible.indexOf(">Work process<"),
  );

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

test("Task Panel review groups repeated records into one continuous file diff", async () => {
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
  let loaded = null;
  const view = render(
    localizedView(
      createElement(FileChangesView, {
        observation: "incomplete",
        changes,
        diffs: {
          "change-1": {
            phase: "settled",
            diff: {
              status: "ready",
              content: "@@ -1 +1 @@\n-secret\n+safe",
              complete: false,
              redacted: true,
            },
          },
          "change-2": { phase: "idle", diff: null },
        },
        onLoad(change) {
          loaded = change;
        },
      }),
    ),
  );

  assert.equal(screen.queryByRole("navigation"), null);
  assert.equal(screen.queryByRole("heading", { name: "Review changes" }), null);
  assert.equal(screen.queryByText("Recorded changes"), null);
  assert.ok(screen.getByRole("status"));
  assert.match(
    document.body.textContent,
    /Some file change records may be missing/,
  );
  assert.doesNotMatch(document.body.textContent, /Change 1|Change 2/);
  assert.equal(
    document.querySelectorAll(".task-panel-change-section").length,
    1,
  );
  assert.equal(
    document.querySelector(".task-panel-change-kind").dataset.kind,
    "moved",
  );
  assert.equal(
    document.querySelector(".task-panel-change-kind > [aria-hidden=true]")
      .textContent,
    "R",
  );
  assert.equal(
    document.querySelector(".task-panel-change-partial").title,
    "The change may not have been fully applied",
  );
  assert.match(document.body.textContent, /Recorded diff is incomplete/);
  assert.match(document.body.textContent, /Known sensitive content was hidden/);
  assert.match(document.body.textContent, /-secret/);
  assert.match(document.body.textContent, /\+safe/);
  assert.equal(screen.queryByText("@@ -1 +1 @@"), null);
  assert.match(document.body.textContent, /\+1−1/);
  assert.ok(screen.getByRole("table", { name: "Recorded unified diff" }));
  assert.ok(screen.getByLabelText("Old line 1"));
  assert.ok(screen.getByLabelText("New line 1"));
  assert.ok(document.querySelector('[data-kind="deletion"]'));
  assert.ok(document.querySelector('[data-kind="addition"]'));

  const user = userEvent.setup({ document: dom.window.document });
  await user.click(
    within(document.querySelector('[data-file-path="src/main.zig"]')).getByRole(
      "button",
      { name: "Load recorded diff" },
    ),
  );
  assert.equal(loaded, changes[1]);
  view.rerender(
    localizedView(
      createElement(FileChangesView, {
        observation: "incomplete",
        changes,
        diffs: {
          "change-1": {
            phase: "settled",
            diff: {
              status: "ready",
              content: "@@ -1 +1 @@\n-secret\n+safe",
              complete: false,
              redacted: true,
            },
          },
          "change-2": {
            phase: "settled",
            diff: {
              status: "ready",
              content: "@@ -8 +8 @@\n-old name\n+new name",
              complete: true,
              redacted: false,
            },
          },
        },
        onLoad(change) {
          loaded = change;
        },
      }),
    ),
  );
  assert.equal(
    document.querySelectorAll(".task-panel-change-section").length,
    1,
  );
  assert.equal(
    screen.getAllByRole("table", { name: "Recorded unified diff" }).length,
    1,
  );
  assert.match(document.body.textContent, /\+new name/);
  assert.match(document.body.textContent, /\+2−2/);
  assert.equal(screen.queryByText("Back to changes"), null);
  assert.doesNotMatch(document.body.textContent, /Accept|Reject|Revert|Stage/);
  view.unmount();
});

test("file headers independently collapse their diff with pointer and keyboard", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const changes = [
    fileChange({ id: "change-a", displayPath: "src/a.ts" }),
    fileChange({
      id: "change-b",
      order: "2",
      kind: "created",
      displayPath: "src/b.ts",
    }),
    fileChange({
      id: "change-c",
      order: "3",
      kind: "deleted",
      displayPath: "src/c.ts",
    }),
  ];
  render(
    localizedView(
      createElement(FileChangesView, {
        observation: "complete",
        changes,
        diffs: {
          "change-a": {
            phase: "settled",
            diff: {
              status: "ready",
              content: "@@ -1 +1 @@\n-old a\n+new a",
              complete: true,
              redacted: false,
            },
          },
          "change-b": {
            phase: "settled",
            diff: {
              status: "ready",
              content: "@@ -1 +1 @@\n-old b\n+new b",
              complete: true,
              redacted: false,
            },
          },
          "change-c": {
            phase: "settled",
            diff: {
              status: "ready",
              content: "@@ -1 +0,0 @@\n-old c",
              complete: true,
              redacted: false,
            },
          },
        },
        onLoad() {},
      }),
    ),
  );

  const first = screen.getByRole("button", { name: "src/a.ts" });
  const second = screen.getByRole("button", { name: "src/b.ts" });
  const third = screen.getByRole("button", { name: "src/c.ts" });
  assert.equal(first.getAttribute("aria-expanded"), "true");
  assert.equal(second.getAttribute("aria-expanded"), "true");
  assert.equal(third.getAttribute("aria-expanded"), "true");
  assert.deepEqual(
    [...document.querySelectorAll(".task-panel-change-kind")].map(
      (element) => element.firstElementChild.textContent,
    ),
    ["M", "A", "D"],
  );
  assert.equal(
    screen.getAllByRole("table", { name: "Recorded unified diff" }).length,
    3,
  );

  await user.click(first);
  assert.equal(first.getAttribute("aria-expanded"), "false");
  assert.equal(second.getAttribute("aria-expanded"), "true");
  assert.equal(
    screen.getAllByRole("table", { name: "Recorded unified diff" }).length,
    2,
  );
  assert.ok(screen.getByText("+new b"));

  first.focus();
  await user.keyboard("{Enter}");
  assert.equal(first.getAttribute("aria-expanded"), "true");
  assert.equal(
    screen.getAllByRole("table", { name: "Recorded unified diff" }).length,
    3,
  );
});

test("continuous Review requests an idle record when its section nears the viewport", async () => {
  const previousGlobal = globalThis.IntersectionObserver;
  const previousWindow = window.IntersectionObserver;
  const observers = [];
  class TestIntersectionObserver {
    constructor(callback, options) {
      this.callback = callback;
      this.options = options;
      observers.push(this);
    }
    observe(element) {
      this.element = element;
    }
    disconnect() {}
  }
  globalThis.IntersectionObserver = TestIntersectionObserver;
  window.IntersectionObserver = TestIntersectionObserver;
  let loaded = null;
  try {
    render(
      localizedView(
        createElement(FileChangesView, {
          observation: "complete",
          changes: [
            {
              id: "lazy-change",
              order: "1",
              kind: "created",
              status: "applied",
              displayPath: "src/lazy.ts",
              fromDisplayPath: null,
              beforeBytes: "0",
              afterBytes: "1",
              diffAvailable: true,
              diffComplete: true,
              redacted: false,
            },
          ],
          diffs: { "lazy-change": { phase: "idle", diff: null } },
          onLoad(change) {
            loaded = change.id;
          },
        }),
      ),
    );
    assert.equal(observers.length, 1);
    assert.equal(observers[0].element.dataset.changeId, "lazy-change");
    assert.ok(
      observers[0].options.root.classList.contains("task-panel-review"),
    );
    await act(async () => observers[0].callback([{ isIntersecting: true }]));
    assert.equal(loaded, "lazy-change");
  } finally {
    cleanup();
    if (previousGlobal === undefined) delete globalThis.IntersectionObserver;
    else globalThis.IntersectionObserver = previousGlobal;
    if (previousWindow === undefined) delete window.IntersectionObserver;
    else window.IntersectionObserver = previousWindow;
  }
});

test("recorded diff failures expose only valid retry actions", () => {
  const change = {
    id: "change-1",
    order: "1",
    kind: "modified",
    status: "applied",
    displayPath: "src/main.ts",
    fromDisplayPath: null,
    beforeBytes: "1",
    afterBytes: "2",
    diffAvailable: true,
    diffComplete: true,
    redacted: false,
  };
  const diffView = (phase, diff) =>
    renderToStaticMarkup(
      localizedView(
        createElement(FileChangesView, {
          observation: "complete",
          changes: [change],
          diffs: { [change.id]: { phase, diff } },
          onLoad() {},
        }),
      ),
    );

  assert.match(diffView("loading", null), /Loading recorded diff/);
  assert.match(diffView("failed", null), /could not be loaded/);
  assert.match(diffView("failed", null), />Retry</);
  assert.match(
    diffView("settled", {
      status: "unavailable",
      reason: "capacity",
      content: "",
    }),
    /temporarily unavailable[\s\S]*>Retry</,
  );
  for (const [reason, message] of [
    ["not_recorded", "No recorded diff is available"],
    ["missing", "The recorded diff is no longer available"],
    ["corrupt", "did not pass integrity checks"],
  ]) {
    const markup = diffView("settled", {
      status: "unavailable",
      reason,
      content: "",
    });
    assert.match(markup, new RegExp(message));
    assert.doesNotMatch(markup, />Retry</);
  }
});

function filePreviewElement(state, onRefresh = () => {}) {
  return localizedView(
    createElement(
      "div",
      null,
      createElement(FilePreviewRefreshAction, { state, onRefresh }),
      createElement(FilePreviewView, { state, onRetry: onRefresh }),
    ),
  );
}

test("Task Panel renders file content without explanatory chrome", () => {
  const state = {
    selected: {
      id: "file-1",
      title: "main.zig",
      displayPath: "src/main.zig",
    },
    phase: "settled",
    preview: {
      state: "ready",
      content: "const ready = true;",
      truncated: false,
      redacted: false,
    },
  };
  render(filePreviewElement(state));
  assert.ok(screen.getByRole("button", { name: "Refresh" }));
  assert.equal(screen.queryByRole("button", { name: "Preview details" }), null);
  assert.equal(screen.queryByText("Recorded diff"), null);
  assert.ok(screen.getByText("const ready = true;"));
  assert.equal(screen.queryByRole("combobox"), null);
});

test("file preview actions and content remain independently composable", () => {
  const markup = renderToStaticMarkup(
    localizedView(
      createElement(FilePreviewView, {
        state: {
          selected: { id: "file-1", displayPath: "main.zig" },
          phase: "settled",
          preview: {
            state: "ready",
            content: "const ready = true;",
            truncated: false,
            redacted: false,
          },
        },
        onRetry() {},
      }),
    ),
  );
  assert.match(markup, /const ready = true;/);
  assert.doesNotMatch(
    markup,
    /Preview details|Refresh|task-panel-resource-header/,
  );
});

test("Markdown preview renders documents, switches to source, and preserves mode while refreshing", () => {
  const content =
    "# API guide\n\n**Strong**\n\n| key | value |\n| --- | --- |\n| page | 1 |\n\n- [x] done\n\n> note\n\n```\nGET /users\n```\n\n![Remote image](https://example.com/track.png)\n\n[local](relative.md)\n\n<script>alert(1)</script>";
  const state = {
    selected: { id: "doc", displayPath: "doc.MD", title: "doc.MD" },
    phase: "settled",
    preview: { state: "ready", content, truncated: true, redacted: true },
  };
  let refreshes = 0;
  const element = (next) => filePreviewElement(next, () => refreshes++);
  const view = render(element(state));
  assert.ok(screen.getByRole("heading", { name: "API guide" }));
  assert.ok(screen.getByRole("table"));
  assert.ok(document.querySelector("blockquote"));
  assert.equal(document.querySelector("input[type=checkbox]").disabled, true);
  assert.equal(
    document.querySelector("pre.code-block-preview").textContent,
    "GET /users",
  );
  assert.equal(document.querySelector("img, script, iframe"), null);
  assert.equal(document.querySelector('a[href="relative.md"]'), null);
  assert.ok(screen.getByText("Remote image"));
  assert.ok(screen.getByText("Preview truncated"));
  assert.ok(screen.getByText("Known sensitive content was hidden"));
  fireEvent.click(screen.getByRole("tab", { name: "Source" }));
  assert.equal(
    document.querySelector("pre.task-panel-code").textContent,
    content,
  );
  assert.equal(screen.queryByRole("heading", { name: "API guide" }), null);
  assert.equal(document.querySelector("table"), null);
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  assert.equal(refreshes, 1);
  view.rerender(element({ ...state, phase: "loading", preview: null }));
  assert.equal(document.querySelector("pre"), null);
  view.rerender(
    element({ ...state, preview: { ...state.preview, content: "# Updated" } }),
  );
  assert.equal(
    screen.getByRole("tab", { name: "Source" }).getAttribute("aria-selected"),
    "true",
  );
  assert.equal(
    document.querySelector("pre.task-panel-code").textContent,
    "# Updated",
  );
  fireEvent.click(screen.getByRole("tab", { name: "Preview" }));
  assert.ok(screen.getByRole("heading", { name: "Updated" }));
});

test("text and HTML stay inert source without extra preview chrome", () => {
  for (const path of ["notes.txt", "script.js", "page.html", "page.HTM"]) {
    const content =
      '<h1>Page</h1><script>window.zero.invoke("attack")</script><img src="https://example.com/track.png">';
    const state = {
      selected: { id: path, displayPath: path, title: path },
      phase: "settled",
      preview: {
        state: "ready",
        content,
        redacted: false,
        truncated: false,
      },
    };
    render(filePreviewElement(state));
    assert.equal(document.querySelector("pre").textContent, content);
    assert.equal(document.querySelector("h1, script, img, iframe"), null);
    assert.equal(screen.queryByRole("tablist"), null);
    assert.equal(
      screen.queryByRole("button", { name: "Preview details" }),
      null,
    );
    cleanup();
  }
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

test("Escape dismissal and focus return preserve the real Task Panel opener", () => {
  assert.equal(shouldDismissSidePanelForEscape(true, "Escape", false), true);
  assert.equal(shouldDismissSidePanelForEscape(false, "Escape", false), false);
  assert.equal(shouldDismissSidePanelForEscape(true, "Escape", true), false);
  assert.equal(shouldDismissSidePanelForEscape(true, "Enter", false), false);

  const opener = { isConnected: true, focus() {} };
  const fallback = { isConnected: true, focus() {} };
  assert.equal(sidePanelFocusReturnTarget(opener, fallback), opener);
  assert.equal(
    sidePanelFocusReturnTarget({ ...opener, isConnected: false }, fallback),
    fallback,
  );
  assert.equal(
    sidePanelFocusReturnTarget(
      { ...opener, hasAttribute: (name) => name === "disabled" },
      fallback,
    ),
    fallback,
  );
});

test("detail targets resolve exact identities for one continuous review", () => {
  const value = task({
    runs: [
      run({
        tools: [technicalTool({ fileRefs: [{ id: "ref-a" }] })],
        fileChanges: { observation: "complete", changes: [{ id: "change-a" }] },
      }),
    ],
  });
  const base = { taskId: "3", runId: "9" };
  for (const target of [
    { ...base, kind: "tool", toolId: "tool-1" },
    { ...base, kind: "preview", referenceId: "ref-a" },
    { ...base, kind: "review" },
  ]) {
    assert.equal(resolveTaskPanelTarget(target, value, true), target);
    assert.equal(
      resolveTaskPanelTarget(target, task({ ...value, id: "other" }), true)
        .kind,
      "empty",
    );
    assert.equal(
      resolveTaskPanelTarget({ ...target, runId: "missing" }, value, true).kind,
      "empty",
    );
  }
  assert.equal(
    resolveTaskPanelTarget({ ...base, kind: "review" }, value, false).kind,
    "empty",
  );
  assert.equal(
    resolveTaskPanelTarget(
      { ...base, kind: "preview", referenceId: "gone" },
      value,
      true,
    ).kind,
    "empty",
  );
  assert.equal(
    resolveTaskPanelTarget(
      { ...base, kind: "tool", toolId: "gone" },
      value,
      true,
    ).kind,
    "empty",
  );
});

test("content targets clear on Task switch and never own layout visibility", () => {
  let session;
  function Harness({ value }) {
    session = useTaskPanelTarget(value, true);
    return createElement(
      "button",
      { onClick: () => session.clearTarget() },
      session.target.kind,
    );
  }
  const value = task({ runs: [run({ tools: [technicalTool()] })] });
  const view = render(createElement(Harness, { value }));
  assert.equal(session.target.kind, "empty");
  assert.equal("open" in session, false);
  fireEvent.click(screen.getByRole("button"));
  view.rerender(
    createElement(Harness, {
      value: { ...value, pendingUi: { runId: "9", requestId: "p" } },
    }),
  );
  assert.equal(session.target.kind, "empty");
  assert.equal("open" in session, false);
  // Drive the same hook used by App, including its render-time identity gate.
  function Opener({ value, target }) {
    const current = useTaskPanelTarget(value, true);
    session = current;
    return createElement(
      "button",
      { onClick: () => current.selectTarget(target) },
      current.target.kind,
    );
  }
  view.rerender(
    createElement(Opener, {
      value,
      target: { kind: "tool", taskId: "3", runId: "9", toolId: "tool-1" },
    }),
  );
  fireEvent.click(screen.getByRole("button"));
  assert.equal(session.target.kind, "tool");
  view.rerender(
    createElement(Opener, {
      value: {
        ...value,
        currentRunId: "10",
        pendingUi: { requestId: "p2", runId: "10" },
      },
      target: emptyTaskPanelTarget,
    }),
  );
  assert.equal(session.target.kind, "tool");
  view.rerender(
    createElement(Opener, {
      value: task({ id: "4" }),
      target: emptyTaskPanelTarget,
    }),
  );
  assert.equal(session.target.kind, "empty");
  assert.equal("open" in session, false);
  view.rerender(createElement(Opener, { value, target: emptyTaskPanelTarget }));
  assert.equal(session.target.kind, "empty");
  assert.equal("open" in session, false);
});

test("single Tool detail follows live props without mounting another tool or unsafe markup", () => {
  const value = technicalTool({
    input: "<script>input</script>",
    progress: "progress one",
    content: "result one",
    redacted: true,
    contentTruncated: true,
  });
  const view = render(
    localizedView(createElement(ToolDetailView, { tool: value })),
  );
  assert.equal(document.querySelector("script"), null);
  assert.ok(screen.getByText("<script>input</script>"));
  assert.match(document.body.textContent, /shortened|hidden/);
  view.rerender(
    localizedView(
      createElement(ToolDetailView, {
        tool: { ...value, progress: "progress two", state: "running" },
      }),
    ),
  );
  assert.equal(screen.queryByText("progress one"), null);
  assert.ok(screen.getByText("progress two"));
  view.unmount();
  assert.equal(screen.queryByText("result one"), null);
});

test("Run statistics remain data, not conversation content or empty disclosures", () => {
  const zero = { input: "0", output: "0", cacheRead: "0", cacheCreation: "0" };
  const value = task({
    runs: [
      run({ id: "6", usage: zero }),
      run({
        id: "7",
        phase: "running",
        terminal: null,
        usage: { ...zero, input: "1234567" },
      }),
      run({ id: "8", usage: { ...zero, cacheRead: "7654321" } }),
      run({
        id: "9",
        usage: { ...zero, output: "3456789", cacheCreation: "9876543" },
      }),
    ],
  });
  const original = structuredClone(value);
  render(taskContentElement(value));
  assert.equal(document.querySelector(".run-usage"), null);
  assert.doesNotMatch(
    document.body.textContent,
    /Usage|Cache read|Cache creation|1234567|7654321|3456789|9876543/,
  );
  assert.match(document.body.textContent, /Release is ready/);
  assert.deepEqual(value, original);
});

test("task information uses a keyboard-accessible icon and retains creation MCP and readonly permission", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  for (const [mcpAuthority, expected] of [
    [{ kind: "unavailable", selection: null }, "Unavailable"],
    [{ kind: "ready", selection: "none" }, "Ready · no tools selected"],
    [{ kind: "ready", selection: "selected" }, "Tools selected"],
  ]) {
    render(
      localizedView(
        createElement(TaskInformation, {
          task: task({ mcpAuthority, permissionProfile: "approval_required" }),
          permissionProfilesEnabled: true,
        }),
      ),
    );
    const trigger = screen.getByRole("button", { name: "Task information" });
    assert.equal(trigger.textContent, "");
    assert.ok(trigger.querySelector("svg"));
    assert.ok(trigger.classList.contains("icon-button"));
    assert.equal(trigger.title, "Task information");
    assert.equal(screen.queryByText(expected), null);
    trigger.focus();
    await user.keyboard("{Enter}");
    assert.ok(screen.getByText(expected));
    assert.equal(screen.queryByRole("combobox"), null);
    assert.match(
      document.body.textContent,
      /Fixed when this Task was created.*default does not affect it/,
    );
    assert.match(document.body.textContent, /not current connection status/);
    await user.keyboard("{Escape}");
    assert.equal(screen.queryByText(expected), null);
    assert.equal(document.activeElement, trigger);
    cleanup();
  }
});

test("task information keeps the full-access boundary visible without a mutation control", async () => {
  const user = userEvent.setup({ document: dom.window.document });

  render(
    localizedView(
      createElement(TaskInformation, {
        task: task({ permissionProfile: "full_access" }),
        permissionProfilesEnabled: true,
      }),
    ),
  );
  await user.click(screen.getByRole("button", { name: "Task information" }));
  assert.ok(screen.getByText("Full access"));
  assert.match(
    document.body.textContent,
    /Routine approval is skipped.*AgentCore and system protections still apply/,
  );
  assert.equal(screen.queryByRole("combobox"), null);
  assert.ok(
    document.querySelector(
      '.task-permission-fact > span[data-profile="full_access"] svg',
    ),
  );
});

test("Conversation context only shows pressure; successful compaction removes the surface", async () => {
  const compact = {
    sourceRunId: "9",
    beforeTokens: "54321",
    afterTokens: "12345",
    dropped: "17",
    kept: "23",
  };
  for (const lastAutoCompact of [null, compact]) {
    assert.equal(
      renderToStaticMarkup(
        localizedView(
          createElement(ConversationContext, {
            context: { pressure: null, lastAutoCompact },
          }),
        ),
      ),
      "",
    );
  }
  const pressure = {
    sourceRunId: "7",
    severity: "warning",
    currentTokens: "100",
    warningThreshold: "90",
    autoCompactThreshold: "200",
    blockingLimit: "300",
  };
  const context = { pressure, lastAutoCompact: compact };
  const view = render(
    localizedView(createElement(ConversationContext, { context })),
  );
  const user = userEvent.setup({ document: dom.window.document });
  const trigger = screen.getByRole("button", { name: "Context is filling up" });
  assert.doesNotMatch(document.body.textContent, /100|54321|12345/);
  await user.click(trigger);
  assert.match(document.body.textContent, /Latest observation/);
  assert.match(document.body.textContent, /100/);
  assert.doesNotMatch(
    document.body.textContent,
    /%|Cache read|54321|12345|Last automatic compaction/,
  );
  await user.keyboard("{Escape}");
  assert.equal(document.activeElement, trigger);
  view.rerender(
    localizedView(
      createElement(ConversationContext, {
        context: {
          ...context,
          pressure: { ...pressure, severity: "critical" },
        },
      }),
    ),
  );
  await user.click(
    screen.getByRole("button", { name: "Context compaction is approaching" }),
  );
  view.rerender(
    localizedView(
      createElement(ConversationContext, {
        context: { pressure: null, lastAutoCompact: compact },
      }),
    ),
  );
  assert.equal(screen.queryByRole("button"), null);
  assert.equal(screen.queryByRole("dialog"), null);
  assert.equal(document.querySelector(".composer-context"), null);
});

test("detail pane has one close action and no review navigation layer", async () => {
  let close = 0;
  const view = render(
    localizedView(
      createElement(
        TaskPanel,
        {
          title: "Review",
          attention: createElement("button", null, "Needs your attention"),
          onClose: () => close++,
        },
        createElement("p", null, "diff body"),
      ),
    ),
  );
  assert.equal(screen.queryByRole("tablist"), null);
  assert.equal(screen.queryByText("Overview"), null);
  assert.equal(screen.queryByText("Back to changes"), null);
  view.rerender(
    localizedView(
      createElement(
        TaskPanel,
        { title: "Tool details", attention: null, onClose: () => close++ },
        createElement("p", null, "tool body"),
      ),
    ),
  );
  assert.equal(screen.queryByText("diff body"), null);
  assert.equal(screen.queryByRole("button", { name: "Back to changes" }), null);
  fireEvent.click(screen.getByRole("button", { name: "Close side panel" }));
  assert.equal(close, 1);
});

async function renderAppFixture(ctx, width = 1440, runOverrides = {}) {
  Object.defineProperty(window, "innerWidth", {
    configurable: true,
    value: width,
    writable: true,
  });
  window.matchMedia = (query) => ({
    matches: query.includes("819") && window.innerWidth < 820,
    media: query,
    addEventListener() {},
    removeEventListener() {},
  });
  globalThis.CSS ??= { escape: (value) => value.replace(/["\\]/g, "\\$&") };
  const { default: App } = await vite.ssrLoadModule("/src/app/App.tsx");
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  let snapshot = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  const first = snapshot.tasks[0];
  first.title = "First task";
  first.runs[0].tools = [
    technicalTool({
      fileRefs: [
        { id: "ref-a", displayPath: "a.txt" },
        { id: "ref-b", displayPath: "b.txt" },
      ],
    }),
  ];
  first.runs[0].fileChanges = {
    observation: "complete",
    changes: [
      {
        id: "change-b",
        order: "2",
        kind: "modified",
        status: "applied",
        displayPath: "b.txt",
        fromDisplayPath: null,
        beforeBytes: "1",
        afterBytes: "2",
        diffAvailable: true,
        diffComplete: true,
        redacted: false,
      },
      {
        id: "change-a",
        order: "1",
        kind: "modified",
        status: "applied",
        displayPath: "a.txt",
        fromDisplayPath: null,
        beforeBytes: "1",
        afterBytes: "2",
        diffAvailable: true,
        diffComplete: true,
        redacted: false,
      },
    ],
  };
  Object.assign(first.runs[0], runOverrides);
  snapshot.capabilities.typedFileChanges = true;
  snapshot.tasks.push({
    ...structuredClone(first),
    id: "4",
    title: "Second task",
  });
  let onRevision;
  let snapshotFailure = false;
  const previews = [],
    diffs = [];
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onWorkbenchRevision: (callback) => {
      onRevision = callback;
      return () => {};
    },
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async () => {
      if (snapshotFailure) throw new Error("fixture synchronization failure");
      return structuredClone(snapshot);
    },
    previewFile: (...ids) =>
      new Promise((resolve, reject) => previews.push({ ids, resolve, reject })),
    fileChangeDiff: (...ids) =>
      new Promise((resolve, reject) => diffs.push({ ids, resolve, reject })),
  }))
    ctx.mock.method(BridgeClient.prototype, name, fn);
  render(localizedView(createElement(App)));
  return {
    snapshot,
    previews,
    diffs,
    publish: () => onRevision(snapshot.revision),
    setSnapshotFailure: (value) => {
      snapshotFailure = value;
    },
  };
}

test("App marks retained Run state unsynchronized and disables stop until refresh succeeds", async (ctx) => {
  const { snapshot, publish, setSnapshotFailure } = await renderAppFixture(
    ctx,
    1440,
    {
      elapsedMs: "10000",
      phase: "running",
      terminal: null,
      activity: { kind: "waiting_model" },
    },
  );
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  setSnapshotFailure(true);
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  assert.ok(await screen.findByText("Status not synchronized"));
  assert.equal(
    screen.getByRole("button", { name: "Stop task" }).disabled,
    true,
  );
  assert.equal(document.querySelector(".run-process").dataset.active, "false");
  assert.equal(
    document.querySelectorAll('.task-signal[data-signal="running"]').length,
    0,
  );
  setSnapshotFailure(false);
  snapshot.tasks[0].runs[0].elapsedMs = "90000";
  await act(async () => publish());
  await waitFor(() =>
    assert.ok(screen.queryByText("Status not synchronized") === null),
  );
  assert.equal(
    screen.getByRole("button", { name: "Stop task" }).disabled,
    false,
  );
});

test("App stop request remains bound to its Task and never fabricates a terminal", async (ctx) => {
  const { snapshot, publish } = await renderAppFixture(ctx, 1440, {
    elapsedMs: "10000",
    phase: "running",
    terminal: null,
    activity: { kind: "waiting_model" },
  });
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  let resolveStop, rejectStop;
  const calls = [];
  ctx.mock.method(BridgeClient.prototype, "cancel", (...ids) => {
    calls.push(ids);
    return new Promise((resolve, reject) => {
      resolveStop = resolve;
      rejectStop = reject;
    });
  });
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  assert.deepEqual(calls, [["3", "7"]]);
  assert.ok(screen.getByText("Requesting stop…"));
  assert.equal(
    screen.getByRole("button", { name: "Stop task" }).disabled,
    true,
  );
  fireEvent.click(screen.getByRole("button", { name: /Second task/ }));
  assert.ok(screen.queryByText("Requesting stop…") === null);
  assert.equal(
    screen.getByRole("button", { name: "Stop task" }).disabled,
    false,
  );
  await act(async () => rejectStop(new Error("fixture stop failure")));
  assert.ok(screen.queryByText(/stop request could not be confirmed/) === null);
  fireEvent.click(screen.getByRole("button", { name: /First task/ }));
  assert.ok(
    screen.getAllByText(/stop request could not be confirmed/).length > 0,
  );
  assert.ok(screen.queryByText("Work stopped") === null);
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  await act(async () => resolveStop());
  assert.ok(screen.queryByText("Work stopped") === null);
  Object.assign(snapshot.tasks[0].runs[0], {
    phase: "stopping",
    activity: { kind: "stopping" },
  });
  snapshot.tasks[0].currentRunPhase = "stopping";
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  assert.ok(await screen.findByText("Stopping"));
  assert.equal(
    screen.getByRole("button", { name: "Stop task" }).disabled,
    true,
  );
});

// Preview entry points are available only after explicitly expanding the process.
function filePreviewOpener(path) {
  const name = `Preview ${path}`;
  if (!screen.queryByRole("button", { name })) {
    const header = document.querySelector(
      '.run-process-header[aria-expanded="false"]',
    );
    assert.ok(header);
    fireEvent.click(header);
  }
  return screen.getByRole("button", { name });
}

test("permanent panel toggle opens a continuous Review and clears it on close", async (ctx) => {
  const { snapshot, previews, diffs, publish } = await renderAppFixture(ctx);
  await screen.findByRole("button", { name: /First task/ });
  const toggle = screen.getByRole("button", { name: "Open side panel" });
  assert.equal(toggle.disabled, false);
  fireEvent.click(toggle);
  assert.ok(screen.getByText("No content to display here."));
  fireEvent.click(screen.getByRole("button", { name: /First task/ }));
  const panel = () => within(document.querySelector("#task-panel"));
  assert.equal(toggle.getAttribute("aria-expanded"), "true");
  assert.ok(panel().getByRole("heading", { name: "Side panel" }));
  assert.equal(panel().queryByRole("navigation"), null);
  assert.equal(panel().queryByText("Overview"), null);
  assert.equal(previews.length, 0);
  assert.equal(diffs.length, 0);
  fireEvent.click(filePreviewOpener("a.txt"));
  assert.deepEqual(previews[0].ids, ["3", "7", "ref-a"]);
  fireEvent.click(toggle);
  await act(async () =>
    previews[0].resolve({
      state: "ready",
      content: "stale body",
      truncated: false,
      redacted: false,
    }),
  );
  assert.equal(screen.queryByText("stale body"), null);
  fireEvent.click(toggle);
  assert.ok(panel().getByText("No content to display here."));
  assert.equal(previews.length, 1);
  const reviewOpener = screen.getByRole("button", { name: /Review changes/ });
  fireEvent.click(reviewOpener);
  assert.equal(diffs.length, 1);
  assert.deepEqual(diffs[0].ids, ["3", "7", "change-a"]);
  assert.ok(panel().getByRole("heading", { name: "Review changes" }));
  assert.equal(panel().queryByText("Recorded changes"), null);
  assert.equal(panel().queryByRole("navigation"), null);
  assert.equal(panel().queryByText("Back to changes"), null);
  assert.deepEqual(
    [...document.querySelectorAll(".task-panel-change-section")].map(
      (element) => element.dataset.changeId,
    ),
    ["change-a", "change-b"],
  );
  await act(async () =>
    diffs[0].resolve({
      status: "unavailable",
      reason: "capacity",
      content: "",
    }),
  );
  fireEvent.click(
    within(document.querySelector('[data-change-id="change-a"]')).getByRole(
      "button",
      { name: "Retry" },
    ),
  );
  assert.deepEqual(diffs[1].ids, ["3", "7", "change-a"]);
  await act(async () =>
    diffs[1].resolve({
      status: "ready",
      content: "@@ -1 +1 @@\n-old a\n+first a",
      complete: true,
      redacted: false,
    }),
  );
  assert.ok(panel().getByText("+first a"));
  fireEvent.click(
    within(document.querySelector('[data-change-id="change-b"]')).getByRole(
      "button",
      { name: "Load recorded diff" },
    ),
  );
  assert.deepEqual(diffs[2].ids, ["3", "7", "change-b"]);
  const closeReview = panel().getByRole("button", { name: "Close side panel" });
  closeReview.focus();
  fireEvent.click(closeReview);
  await act(
    async () => new Promise((resolve) => window.requestAnimationFrame(resolve)),
  );
  assert.equal(document.activeElement === reviewOpener, true);
  assert.equal(document.querySelector("#task-panel"), null);
  fireEvent.click(toggle);
  assert.ok(panel().getByText("No content to display here."));
  snapshot.tasks[0].runs = [];
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  assert.ok(panel().getByText("No content to display here."));
  assert.equal(toggle.disabled, false);
  assert.equal(toggle.getAttribute("aria-expanded"), "true");
  await act(async () =>
    diffs[2].resolve({
      status: "ready",
      content: "+late b",
      complete: true,
      redacted: false,
    }),
  );
  cleanup();
});

test("layout visibility and width survive Task changes, invalidation, and non-Task pages", async (ctx) => {
  const { snapshot, previews, publish } = await renderAppFixture(ctx);
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  fireEvent.click(screen.getByRole("button", { name: "Open side panel" }));
  const shell = document.querySelector(".app-window");
  const resize = screen.getByRole("separator", { name: "Resize side panel" });
  fireEvent.keyDown(resize, { key: "ArrowLeft" });
  const width = shell.style.getPropertyValue("--right-column-width");
  assert.equal(width, "416px");
  fireEvent.click(filePreviewOpener("a.txt"));
  snapshot.tasks[0].runs[0].tools = [];
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  await waitFor(() =>
    assert.ok(screen.queryByRole("heading", { name: "a.txt" }) === null),
  );
  await act(async () =>
    previews[0].resolve({
      state: "ready",
      content: "invalidated file",
      truncated: false,
      redacted: false,
    }),
  );
  assert.ok(screen.queryByText("invalidated file") === null);
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  fireEvent.click(screen.getByRole("button", { name: /Second task/ }));
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  assert.equal(shell.style.getPropertyValue("--right-column-width"), width);
  fireEvent.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  assert.ok(screen.getByText("No content to display here."));
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  fireEvent.click(screen.getByRole("button", { name: "Skills", exact: true }));
  assert.ok(screen.getByText("No content to display here."));
  assert.ok(
    !screen.getAllByRole("button", { name: "Close side panel" })[0].disabled,
  );
  fireEvent.click(screen.getByRole("button", { name: /Second task/ }));
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  snapshot.tasks.splice(1, 1);
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  await screen.findByText("No content to display here.");
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  assert.equal(shell.style.getPropertyValue("--right-column-width"), width);
  fireEvent.click(
    within(document.querySelector("#task-panel")).getByRole("button", {
      name: "Close side panel",
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: /First task/ }));
  assert.equal(shell.getAttribute("data-right-panel-open"), "false");
  assert.equal(shell.style.getPropertyValue("--right-column-width"), width);
  cleanup();
});

test("App keeps per-record diffs independent and rejects stale review responses", async (ctx) => {
  const { snapshot, previews, diffs, publish } = await renderAppFixture(ctx);
  const firstButton = await screen.findByRole("button", { name: /First task/ });
  fireEvent.click(firstButton);
  await screen.findByRole("button", { name: "Task information" });
  assert.ok(
    screen.getByRole("button", { name: "Open side panel" }).disabled === false,
  );
  const openPreview = () => fireEvent.click(filePreviewOpener("a.txt"));
  const ready = (content) => ({
    state: "ready",
    content,
    truncated: false,
    redacted: false,
  });
  openPreview();
  assert.deepEqual(previews[0].ids, ["3", "7", "ref-a"]);
  fireEvent.click(
    within(document.querySelector("#task-panel")).getByRole("button", {
      name: "Close side panel",
    }),
  );
  await act(async () => previews[0].resolve(ready("late after close")));
  assert.equal(screen.queryByText("late after close"), null);
  assert.equal(document.querySelector("#task-panel"), null);
  openPreview();
  // Reopening starts a new read; even a failure from it must not reopen a closed pane.
  fireEvent.click(
    within(document.querySelector("#task-panel")).getByRole("button", {
      name: "Close side panel",
    }),
  );
  await act(async () => previews[1].reject(new Error("late failure")));
  assert.equal(document.querySelector("#task-panel"), null);
  openPreview();
  fireEvent.click(screen.getByRole("button", { name: /Review changes/ }));
  assert.equal(document.querySelector(".task-panel-code"), null);
  assert.equal(diffs.length, 1);
  assert.deepEqual(diffs[0].ids, ["3", "7", "change-a"]);
  await act(async () => previews[2].resolve(ready("late after review")));
  assert.equal(screen.queryByText("late after review"), null);
  fireEvent.click(
    within(document.querySelector('[data-change-id="change-b"]')).getByRole(
      "button",
      { name: "Load recorded diff" },
    ),
  );
  assert.deepEqual(diffs[1].ids, ["3", "7", "change-b"]);
  await act(async () =>
    diffs[1].resolve({
      status: "ready",
      content: "+chosen b",
      complete: true,
      redacted: false,
    }),
  );
  assert.ok(screen.getByText("+chosen b"));
  await act(async () =>
    diffs[0].resolve({
      status: "ready",
      content: "+late a",
      complete: true,
      redacted: false,
    }),
  );
  assert.ok(screen.getByText("+late a"));
  assert.ok(screen.getByText("+chosen b"));
  // Snapshot invalidation prunes one record without closing the remaining Review.
  snapshot.tasks[0].runs[0].fileChanges.changes =
    snapshot.tasks[0].runs[0].fileChanges.changes.filter(
      (change) => change.id !== "change-b",
    );
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  await waitFor(() => assert.ok(screen.queryByText("+chosen b") === null));
  assert.ok(screen.getByText("+late a"));
  assert.equal(
    document.querySelectorAll(".task-panel-change-section").length,
    1,
  );
  openPreview();
  fireEvent.click(screen.getByRole("button", { name: /Second task/ }));
  await act(async () => previews[3].resolve(ready("late after switch")));
  assert.equal(screen.queryByText("late after switch"), null);
  assert.ok(document.querySelector("#task-panel") !== null);
  assert.ok(
    within(document.querySelector("#task-panel")).getByRole("heading", {
      name: "Side panel",
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: /First task/ }));
  assert.ok(document.querySelector("#task-panel") !== null);
  assert.ok(screen.queryByText("late after switch") === null);
  cleanup();
});

test("conversation file links preview directly without expanding tools and return focus on Escape", async (ctx) => {
  const { previews } = await renderAppFixture(ctx, 1440, {
    output: {
      commentary: ["正在处理 `a.txt`。"],
      response: "已生成：`a.txt`、[查看 B](b.txt)。",
      responseKind: "final",
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
  });
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  assert.equal(
    document.querySelector(".run-process-header").getAttribute("aria-expanded"),
    "false",
  );
  assert.equal(document.querySelector(".run-process-files"), null);
  const narrative = document.querySelector(".run-commentary-item");
  const response = document.querySelector(".agent-response");
  const first = within(narrative).getByRole("button", {
    name: "Preview a.txt",
  });
  const second = within(response).getByRole("button", {
    name: "Preview b.txt",
  });
  assert.ok(within(response).getByRole("button", { name: "Preview a.txt" }));
  fireEvent.click(first);
  fireEvent.click(second);
  assert.deepEqual(
    previews.map((request) => request.ids),
    [
      ["3", "7", "ref-a"],
      ["3", "7", "ref-b"],
    ],
  );
  const ready = (content) => ({
    state: "ready",
    content,
    redacted: false,
    truncated: false,
  });
  await act(async () => previews[1].resolve(ready("B content")));
  await act(async () => previews[0].resolve(ready("stale A")));
  assert.ok(screen.getByText("B content"));
  assert.equal(screen.queryByText("stale A"), null);
  fireEvent.keyDown(screen.getByRole("heading", { name: "b.txt" }), {
    key: "Escape",
  });
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  assert.equal(document.activeElement, second);
  assert.equal(document.querySelector("#task-panel"), null);
  assert.equal(document.querySelector(".run-process-files"), null);
});

test("selecting another Markdown reference resets the display mode without retaining old content", async (ctx) => {
  const { previews } = await renderAppFixture(ctx, 1440, {
    tools: [
      technicalTool({
        fileRefs: [
          { id: "ref-a", displayPath: "a.md", title: "a.md" },
          { id: "ref-b", displayPath: "b.markdown", title: "b.markdown" },
        ],
      }),
    ],
  });
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  const ready = (content) => ({
    state: "ready",
    content,
    truncated: false,
    redacted: false,
  });
  fireEvent.click(filePreviewOpener("a.md"));
  await act(async () => previews[0].resolve(ready("# First document")));
  assert.ok(screen.getByRole("heading", { name: "First document" }));
  fireEvent.click(screen.getByRole("tab", { name: "Source" }));
  fireEvent.click(filePreviewOpener("b.markdown"));
  assert.equal(document.querySelector(".task-panel-code"), null);
  await act(async () => previews[1].resolve(ready("# Second document")));
  assert.ok(screen.getByRole("heading", { name: "Second document" }));
  assert.equal(
    screen.getByRole("tab", { name: "Preview" }).getAttribute("aria-selected"),
    "true",
  );
  assert.equal(screen.queryByText("# First document"), null);
});

test("App previews exact operation references, rejects superseded reads, and refreshes only the current file", async (ctx) => {
  const { previews } = await renderAppFixture(ctx);
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  const openers = [filePreviewOpener("a.txt"), filePreviewOpener("b.txt")];
  fireEvent.click(openers[0]);
  fireEvent.click(openers[1]);
  assert.deepEqual(
    previews.map((request) => request.ids),
    [
      ["3", "7", "ref-a"],
      ["3", "7", "ref-b"],
    ],
  );
  const ready = (content) => ({
    state: "ready",
    content,
    redacted: false,
    truncated: false,
  });
  await act(async () => previews[1].resolve(ready("selected reference")));
  await act(async () => previews[0].resolve(ready("superseded reference")));
  assert.ok(screen.getByText("selected reference"));
  assert.equal(screen.queryByText("superseded reference"), null);
  const panel = within(document.querySelector("#task-panel"));
  assert.equal(panel.queryByRole("combobox"), null);
  fireEvent.click(panel.getByRole("button", { name: "Refresh" }));
  assert.deepEqual(previews[2].ids, ["3", "7", "ref-b"]);
  assert.equal(screen.queryByText("selected reference"), null);
  await act(async () => previews[2].resolve(ready("refreshed reference")));
  assert.ok(screen.getByText("refreshed reference"));
  fireEvent.click(panel.getByRole("button", { name: "Close side panel" }));
  fireEvent.click(openers[1]);
  assert.deepEqual(previews[3].ids, ["3", "7", "ref-b"]);
  assert.equal(screen.queryByText("refreshed reference"), null);
  await act(async () => previews[3].resolve(ready("explicit reread")));
  assert.ok(screen.getByText("explicit reread"));
});

test("App attention only locates the original approval in docked and overlay layouts", async (ctx) => {
  for (const width of [1440, 600]) {
    const { snapshot, previews, publish } = await renderAppFixture(ctx, width);
    // A small-window sidebar is explicitly opened only to select the Task.
    if (width < 820)
      fireEvent.click(
        screen.getByRole("button", { name: "Toggle task sidebar" }),
      );
    fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
    const info = await screen.findByRole("button", {
      name: "Task information",
    });
    info.focus();
    snapshot.tasks[0].pendingUi = {
      requestId: "request-1",
      runId: "7",
      order: "1",
      redacted: false,
      kind: "permission",
      tool: "Bash",
      args: "inspect",
      availableChoices: ["deny_once", "allow_once"],
    };
    snapshot.tasks[0].currentRunPhase = "waiting_ui";
    snapshot.tasks[0].runs[0].phase = "waiting_ui";
    snapshot.revision = String(BigInt(snapshot.revision) + 1n);
    await act(async () => publish());
    await screen.findByRole("button", { name: "Needs your attention" });
    assert.ok(document.querySelector("#task-panel") === null);
    assert.ok(document.activeElement === info);
    fireEvent.click(filePreviewOpener("a.txt"));
    const panel = document.querySelector("#task-panel");
    assert.equal(
      document.querySelector(".app-window").dataset.rightPanelDocked,
      String(width === 1440),
    );
    // JSDOM has no layout. Bind only the computed layout branch; browser acceptance
    // separately checks that the real stylesheet actually chooses fixed overlay.
    const style = window.getComputedStyle.bind(window);
    const styleMock = ctx.mock.method(
      window,
      "getComputedStyle",
      (element, ...args) =>
        element === panel
          ? { position: width === 1440 ? "relative" : "fixed" }
          : style(element, ...args),
    );
    const locator = within(panel).getByRole("button", {
      name: "Needs your attention",
    });
    assert.equal(
      within(panel).queryByRole("button", { name: "Allow once" }),
      null,
    );
    fireEvent.click(locator);
    await act(
      async () =>
        new Promise((resolve) =>
          requestAnimationFrame(() => requestAnimationFrame(resolve)),
        ),
    );
    const pending = document.querySelector("#ui-request-request-1");
    assert.ok(document.activeElement === pending);
    assert.equal(
      document.querySelector("#task-panel") !== null,
      width === 1440,
    );
    if (width === 1440)
      fireEvent.click(
        within(document.querySelector("#task-panel")).getByRole("button", {
          name: "Close side panel",
        }),
      );
    await act(async () =>
      previews[0].resolve({
        state: "ready",
        content: "late approval read",
        redacted: false,
        truncated: false,
      }),
    );
    assert.ok(screen.queryByText("late approval read") === null);
    styleMock.mock.restore();
    cleanup();
    ctx.mock.restoreAll();
  }
});

test("App Escape returns to the opener, or the permanent toggle when that opener disappears", async (ctx) => {
  const { previews } = await renderAppFixture(ctx);
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  const opener = filePreviewOpener("a.txt");
  fireEvent.click(opener);
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  const heading = screen.getByRole("heading", { name: "a.txt" });
  assert.ok(document.activeElement === heading);
  // Nested controls can consume Escape without closing the pane.
  const stopEscape = (event) => event.preventDefault();
  heading.addEventListener("keydown", stopEscape);
  fireEvent.keyDown(heading, { key: "Escape" });
  assert.ok(document.querySelector("#task-panel") !== null);
  heading.removeEventListener("keydown", stopEscape);
  fireEvent.keyDown(heading, { key: "Escape" });
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  assert.ok(document.querySelector("#task-panel") === null);
  assert.ok(document.activeElement === opener);
  fireEvent.click(opener);
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  fireEvent.click(
    document.querySelector('.run-process-header[aria-expanded="true"]'),
  );
  assert.equal(opener.isConnected, false);
  fireEvent.keyDown(screen.getByRole("heading", { name: "a.txt" }), {
    key: "Escape",
  });
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  assert.ok(
    document.activeElement ===
      screen.getByRole("button", { name: "Open side panel" }),
  );
  await act(async () => {
    for (const request of previews)
      request.resolve({
        state: "missing",
        content: "",
        truncated: false,
        redacted: false,
      });
  });
  cleanup();
});
