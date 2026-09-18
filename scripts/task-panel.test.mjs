import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

import {
  sidePanelFocusReturnTarget,
  shouldDismissSidePanelForEscape,
} from "../frontend/src/app/side-panel-interaction.ts";
import {
  closeTaskPanelTab,
  createTaskPanelPreviewTab,
  createTaskPanelReviewTab,
  emptyTaskPanelSession,
  emptyTaskPanelTarget,
  openTaskPanelTab,
  reconcileTaskPanelSession,
  resolveTaskPanelTarget,
  selectTaskPanelTab,
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
  "/src/features/tasks/ToolDetailView.tsx",
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
const { useFilePreviewTabs } = await vite.ssrLoadModule(
  "/src/features/task-panel/useFilePreviewTabs.ts",
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
const {
  HighlightedSource,
  countSourceLines,
  isWithinHighlightBudget,
  resolvePreviewLanguage,
  validateHighlightTree,
} = await vite.ssrLoadModule("/src/features/task-panel/HighlightedSource.tsx");
const { TaskPanel, taskPanelTabLabels } = await vite.ssrLoadModule(
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
    submittedAtUnixMs: null,
    finishedAtUnixMs: null,
    elapsedMs: "12000",
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

test("Bash detail shows semantic evidence without duplicate protocol data or copy actions", () => {
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
  assert.ok(screen.getByText("Command completed · exit code 0"));
  assert.ok(screen.getByText("partial warning"));
  assert.equal(screen.queryByText("No standard output captured."), null);
  assert.equal(screen.queryByText("raw envelope"), null);
  assert.equal(view.container.querySelector("details"), null);
  assert.equal(screen.queryByRole("button", { name: "Copy code" }), null);
  assert.equal(
    view.container.querySelectorAll(".tool-evidence-surface").length,
    2,
  );
});

test("partially parsed Bash detail discloses only unparsed evidence", () => {
  const tool = technicalTool({
    name: "Bash",
    input: '{"command":"pwd"}',
    content: "raw envelope",
    bash: {
      command: "pwd",
      description: "Inspect workspace",
      result: null,
    },
  });
  const view = render(localizedView(createElement(ToolDetailView, { tool })));
  assert.ok(screen.getByText("pwd"));
  assert.ok(screen.getByText("Some Bash data could not be interpreted."));
  assert.equal(view.container.querySelector("details").open, false);
  assert.ok(
    view.container
      .querySelector("details")
      .textContent.includes("raw envelope"),
  );
  assert.equal(
    view.container.querySelector("details").textContent.includes("command"),
    false,
  );
});

test("unparsed Bash detail presents safe original evidence directly", () => {
  const tool = technicalTool({
    name: "Bash",
    input: '{"command":"pwd"}',
    content: "raw envelope",
    bash: { command: null, description: null, result: null },
  });
  const view = render(localizedView(createElement(ToolDetailView, { tool })));
  assert.ok(screen.getByText(/^This Bash call could not be interpreted\./));
  assert.ok(screen.getByText('{"command":"pwd"}'));
  assert.ok(screen.getByText("raw envelope"));
  assert.equal(view.container.querySelector("details"), null);
  assert.equal(screen.queryByRole("button", { name: "Copy code" }), null);
});

test("generic Tool detail uses selectable evidence without copy actions", () => {
  const tool = technicalTool({
    input: '{"file_path":"README.md"}',
    content: "raw result",
  });
  const view = render(localizedView(createElement(ToolDetailView, { tool })));
  assert.equal(view.container.querySelectorAll("button").length, 0);
  assert.equal(
    view.container.querySelectorAll(".tool-evidence-surface").length,
    2,
  );
  assert.ok(screen.getByText('{"file_path":"README.md"}'));
  assert.ok(screen.getByText("raw result"));
});

test("terminal Bash detail reports an unparsed empty result", () => {
  const tool = technicalTool({
    name: "Bash",
    input: '{"command":"pwd"}',
    content: "",
    bash: {
      command: "pwd",
      description: "Inspect workspace",
      result: null,
    },
  });
  const view = render(localizedView(createElement(ToolDetailView, { tool })));
  assert.ok(screen.getByText("Some Bash data could not be interpreted."));
  assert.equal(view.container.querySelector("details"), null);
});

test("Bash detail updates when readable projection becomes unavailable", () => {
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
        stderr: "",
        stdoutIncomplete: false,
        stderrIncomplete: false,
      },
    },
  });
  const view = render(localizedView(createElement(ToolDetailView, { tool })));
  view.rerender(
    localizedView(
      createElement(ToolDetailView, { tool: { ...tool, bash: null } }),
    ),
  );
  assert.equal(view.container.querySelector("details"), null);
  assert.ok(screen.getByText("raw envelope"));
});

test("expanded process keeps each Tool summary to one bounded line", async () => {
  const value = run({
    phase: "running",
    activity: { kind: "executing_tools", inFlight: "1" },
    terminal: null,
    tools: [
      technicalTool({
        id: "bash-1",
        name: "Bash",
        progress: "<script>" + "x".repeat(500),
        bash: {
          command: "pwd",
          description: "Inspect " + "d".repeat(300),
          result: null,
        },
      }),
      technicalTool({
        id: "read-1",
        name: "Read",
        progress: "Reading " + "p".repeat(300),
      }),
      technicalTool({
        id: "write-1",
        name: "Write",
        fileRefs: [{ id: "file-1", displayPath: "src/report.html" }],
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
  const rows = [...view.container.querySelectorAll(".run-process-tool")];
  assert.equal(rows.length, 3);
  assert.ok(
    rows.every(
      (row) =>
        row.querySelectorAll(".run-process-tool-label > span").length <= 2,
    ),
  );
  assert.equal(
    rows[1].querySelector(".run-process-tool-description").textContent.length,
    161,
  );
  assert.equal(
    rows[2].querySelector(".run-process-tool-description").textContent,
    "src/report.html",
  );
  assert.equal(
    within(rows[2]).queryByRole("button", { name: "Preview src/report.html" }),
    null,
  );
  assert.equal(
    view.container.querySelector(".run-process-tool-progress"),
    null,
  );
  assert.equal(view.container.querySelector("script"), null);

  const stylesheet = await readFile("frontend/src/index.css", "utf8");
  assert.match(
    stylesheet,
    /\.run-process-tool-label\s*\{[^}]*display: flex;[^}]*white-space: nowrap;/s,
  );
  assert.match(
    stylesheet,
    /\.run-process-tool-description\s*\{[^}]*text-overflow: ellipsis;[^}]*white-space: nowrap;/s,
  );
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

test("Edit and Write replace raw protocol details with matching file audit links", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const opened = [];
  const value = run({
    tools: [
      technicalTool({
        name: "Edit",
        input: '{"file_path":"/workspace/index.html","old_string":"before"}',
        content: '{"success":true,"gitDiff":"-before\\n+after"}',
        fileRefs: [
          { id: "file-1", title: "index.html", displayPath: "index.html" },
        ],
      }),
      technicalTool({
        id: "tool-2",
        order: "2",
        name: "Write",
        input: '{"file_path":"/workspace/app.js","content":"saved"}',
        content: '{"success":true}',
        fileRefs: [{ id: "file-2", title: "app.js", displayPath: "app.js" }],
      }),
    ],
    fileChanges: {
      observation: "complete",
      changes: [
        fileChange({ displayPath: "index.html" }),
        fileChange({ id: "change-2", order: "2", displayPath: "app.js" }),
      ],
    },
  });
  render(
    runProcessElement(value, {
      onReviewFileChanges: (...args) => opened.push(args),
    }),
  );

  assert.equal(
    screen.queryByRole("button", { name: "Show or hide details for Edit" }),
    null,
  );
  assert.equal(
    screen.queryByRole("button", { name: "Show or hide details for Write" }),
    null,
  );
  assert.doesNotMatch(
    document.body.textContent,
    /old_string|gitDiff|file_path|success/,
  );
  const editAudit = screen.getByRole("button", {
    name: "Review changes to index.html",
  });
  const writeAudit = screen.getByRole("button", {
    name: "Review changes to app.js",
  });
  await user.click(editAudit);
  await user.click(writeAudit);
  assert.equal(opened.length, 2);
  assert.equal(opened[0][0], "index.html");
  assert.equal(opened[0][1], editAudit);
  assert.equal(opened[1][0], "app.js");
  assert.equal(opened[1][1], writeAudit);

  cleanup();
  render(
    runProcessElement(
      {
        ...value,
        fileChanges: {
          ...value.fileChanges,
          changes: [
            fileChange({ displayPath: "other.html" }),
            fileChange({ id: "change-2", order: "2", displayPath: "app.js" }),
          ],
        },
      },
      { onReviewFileChanges: (...args) => opened.push(args) },
    ),
  );
  assert.equal(
    screen.queryByRole("button", { name: "Review changes to index.html" }),
    null,
  );
  assert.ok(screen.getByText("index.html"));
  assert.ok(screen.getByRole("button", { name: "Review changes to app.js" }));
  assert.doesNotMatch(
    document.body.textContent,
    /old_string|gitDiff|file_path|success/,
  );
});

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
  { expanded = true, onExpandedChange = () => {}, onReviewFileChanges } = {},
) {
  function Harness() {
    const [expandedToolIds, setExpandedToolIds] = useState(new Set());
    return createElement(RunProcess, {
      presentation: deriveRunPresentation(value),
      fileChanges: value.fileChanges ?? null,
      elapsedMs: value.elapsedMs,
      expanded,
      onExpandedChange,
      onReviewFileChanges,
      expandedToolIds,
      onToolExpandedChange(toolId, nextExpanded) {
        setExpandedToolIds((current) => {
          const next = new Set(current);
          if (nextExpanded) next.add(toolId);
          else next.delete(toolId);
          return next;
        });
      },
    });
  }
  return localizedView(createElement(Harness));
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

test("conversation renders commentary, provisional, and response through one Markdown surface", () => {
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
  assert.doesNotMatch(activeMarkup, /aria-expanded=/);
  assert.match(activeMarkup, /Checked <strong>two files<\/strong>\./);
  assert.match(activeMarkup, /Draft <strong>not Markdown<\/strong>/);
  assert.equal(
    (activeMarkup.match(/class="ai-message run-assistant-output"/g) ?? [])
      .length,
    1,
  );

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

test("provisional Markdown is formatted from the first bytes but remains inert", () => {
  const active = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        terminal: null,
        activity: { kind: "writing_response" },
        output: {
          commentary: [],
          response: "",
          responseKind: null,
          provisional:
            "**Bold**\n\n- item\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n[web](https://example.com) [file](report.md) ![remote image](https://example.com/a.png) <b>raw html</b>\n\n```ts\nconst answer = 42",
          redacted: false,
          provisionalRedacted: false,
        },
      }),
    ],
  });
  const view = render(taskContentElement(active));
  const output = view.container.querySelector(
    '[data-output-disposition="provisional"]',
  );
  assert.ok(output);
  assert.ok(within(output).getByText("Bold", { selector: "strong" }));
  assert.ok(within(output).getByText("item", { selector: "li" }));
  assert.ok(within(output).getByRole("table"));
  assert.ok(within(output).getByText("const answer = 42", { selector: "pre" }));
  assert.ok(within(output).getByText("remote image"));
  assert.equal(output.querySelector("a"), null);
  assert.equal(output.querySelector("button"), null);
  assert.equal(output.querySelector("img"), null);
  assert.equal(output.querySelector("b"), null);
  assert.equal(output.querySelector("[aria-live]"), null);
});

test("growing provisional Markdown preserves follow state, text selection, and Composer focus", async () => {
  const activeRun = run({
    phase: "running",
    terminal: null,
    activity: { kind: "writing_response" },
    output: {
      commentary: [],
      response: "",
      responseKind: null,
      provisional: `Selectable prefix\n\n${"x".repeat(16 * 1024)}`,
      redacted: false,
      provisionalRedacted: false,
    },
  });
  const activeTask = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [activeRun],
  });
  const surface = (value, revision) =>
    createElement(
      "div",
      null,
      createElement("textarea", { "aria-label": "Composer" }),
      taskContentElement(value, revision),
    );
  const view = render(surface(activeTask, "1"));
  const viewport = view.container.querySelector(".ai-conversation-viewport");
  let scrollHeight = 1_000;
  Object.defineProperties(viewport, {
    scrollHeight: { configurable: true, get: () => scrollHeight },
    clientHeight: { configurable: true, value: 400 },
    scrollTop: { configurable: true, writable: true, value: 600 },
  });
  fireEvent.scroll(viewport);

  const composer = screen.getByRole("textbox", { name: "Composer" });
  composer.focus();
  const prefix = screen.getByText("Selectable prefix");
  const selection = window.getSelection();
  const range = document.createRange();
  range.setStart(prefix.firstChild, 0);
  range.setEnd(prefix.firstChild, "Selectable".length);
  selection.removeAllRanges();
  selection.addRange(range);

  scrollHeight = 1_200;
  view.rerender(
    surface(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            output: {
              ...activeRun.output,
              provisional: `Selectable prefix\n\n${"x".repeat(64 * 1024)}\n\nGrowing marker`,
            },
          },
        ],
      },
      "2",
    ),
  );
  await waitFor(() => assert.ok(screen.getByText("Growing marker")));
  assert.equal(viewport.scrollTop, 1_200);
  assert.equal(document.activeElement, composer);
  assert.equal(selection.toString(), "Selectable");

  viewport.scrollTop = 200;
  fireEvent.scroll(viewport);
  scrollHeight = 1_400;
  view.rerender(
    surface(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            output: {
              ...activeRun.output,
              provisional: `Selectable prefix\n\n${"x".repeat(96 * 1024)}\n\nPaused marker`,
            },
          },
        ],
      },
      "3",
    ),
  );
  await waitFor(() => assert.ok(screen.getByText("Paused marker")));
  assert.equal(viewport.scrollTop, 200);
  assert.ok(screen.getByRole("button", { name: "Jump to latest" }));
  assert.equal(document.activeElement, composer);
  assert.equal(selection.toString(), "Selectable");
});

test("output classification preserves the same parent and part DOM roots", () => {
  const activeRun = run({
    phase: "running",
    terminal: null,
    activity: { kind: "writing_response" },
    output: {
      commentary: ["Earlier"],
      response: "",
      responseKind: null,
      provisional: "**Stable tail**",
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
  const parent = view.container.querySelector(".run-assistant-output");
  const part = view.container.querySelector(
    '[data-output-identity="9:output:1"]',
  );
  assert.ok(parent);
  assert.ok(part);

  view.rerender(
    taskContentElement(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            output: {
              ...activeRun.output,
              commentary: ["Earlier", "**Stable tail**"],
              provisional: "",
            },
          },
        ],
      },
      "2",
    ),
  );
  assert.equal(view.container.querySelector(".run-assistant-output"), parent);
  assert.equal(
    view.container.querySelector('[data-output-identity="9:output:1"]'),
    part,
  );
  assert.equal(part.dataset.outputDisposition, "commentary");

  view.rerender(
    taskContentElement(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            output: {
              ...activeRun.output,
              response: "**Stable tail**",
              responseKind: "final",
              provisional: "",
            },
          },
        ],
      },
      "3",
    ),
  );
  assert.equal(view.container.querySelector(".run-assistant-output"), parent);
  assert.equal(
    view.container.querySelector('[data-output-identity="9:output:1"]'),
    part,
  );
  assert.equal(part.dataset.outputDisposition, "final");
});

test("closed output keeps its DOM root across status revisions and activates late references", () => {
  const activeRun = run({
    phase: "running",
    terminal: null,
    activity: { kind: "thinking" },
    output: {
      commentary: ["Inspect `report.md`."],
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
  const opened = [];
  const props = { onPreviewFile: (...args) => opened.push(args) };
  const view = render(taskContentElement(activeTask, "1", props));
  const part = view.container.querySelector(
    '[data-output-identity="9:output:0"]',
  );
  assert.ok(part);
  assert.equal(within(part).queryByRole("button"), null);

  view.rerender(
    taskContentElement(
      {
        ...activeTask,
        runs: [{ ...activeRun, activity: { kind: "waiting_model" } }],
      },
      "2",
      props,
    ),
  );
  assert.equal(
    view.container.querySelector('[data-output-identity="9:output:0"]'),
    part,
  );

  view.rerender(
    taskContentElement(
      {
        ...activeTask,
        runs: [
          {
            ...activeRun,
            activity: { kind: "executing_tools", inFlight: "1" },
            tools: [
              technicalTool({
                id: "write-1",
                name: "Write",
                fileRefs: [
                  {
                    id: "report-ref",
                    title: "report.md",
                    displayPath: "report.md",
                  },
                ],
              }),
            ],
          },
        ],
      },
      "3",
      props,
    ),
  );
  assert.equal(
    view.container.querySelector('[data-output-identity="9:output:0"]'),
    part,
  );
  const opener = within(part).getByRole("button", {
    name: "Preview report.md",
  });
  fireEvent.click(opener);
  assert.deepEqual(opened[0].slice(0, 2), ["3", "9"]);
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

test("Run status keeps technical Tool details behind nested disclosures", async () => {
  const user = userEvent.setup({ document: dom.window.document });
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
    screen.getByRole("button", { name: "Show or hide details for Read" }),
  );
  assert.ok(screen.getByRole("region", { name: "Details for Read" }));
  assert.ok(screen.getByText("private input"));
  assert.ok(screen.getByText("private result"));
  await user.click(header);
  assert.deepEqual(expandedChanges, [false]);
});

test("Tool disclosures expand independently and survive Work process collapse", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const value = run({
    phase: "running",
    terminal: null,
    activity: { kind: "executing_tools", inFlight: "1" },
    tools: [
      technicalTool({ id: "read-1", name: "Read", content: "read result" }),
      technicalTool({ id: "bash-1", name: "Bash", content: "bash result" }),
    ],
  });

  function Harness() {
    const [expanded, setExpanded] = useState(false);
    const [expandedToolIds, setExpandedToolIds] = useState(new Set());
    return createElement(RunProcess, {
      presentation: deriveRunPresentation(value),
      expanded,
      onExpandedChange: setExpanded,
      expandedToolIds,
      onToolExpandedChange(toolId, nextExpanded) {
        setExpandedToolIds((current) => {
          const next = new Set(current);
          if (nextExpanded) next.add(toolId);
          else next.delete(toolId);
          return next;
        });
      },
    });
  }

  render(localizedView(createElement(Harness)));
  const process = screen.getByRole("button", {
    name: /Working/,
  });
  await user.click(process);
  await user.click(
    screen.getByRole("button", { name: "Show or hide details for Read" }),
  );
  await user.click(
    screen.getByRole("button", { name: "Show or hide details for Bash" }),
  );
  assert.ok(screen.getByRole("region", { name: "Details for Read" }));
  assert.ok(screen.getByRole("region", { name: "Details for Bash" }));

  await user.click(process);
  assert.equal(
    screen.queryByRole("region", { name: "Details for Read" }),
    null,
  );
  await user.click(process);
  assert.ok(screen.getByRole("region", { name: "Details for Read" }));
  assert.ok(screen.getByRole("region", { name: "Details for Bash" }));
});

test("terminal Run keeps Tool process evidence behind a collapsed summary", () => {
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
  assert.match(markup, /Execution details/);
  assert.match(markup, /Turn time 0:12/);
  assert.doesNotMatch(markup, /run-process-tools/);

  const untimedMarkup = renderToStaticMarkup(
    runProcessElement({ ...value, elapsedMs: null }, { expanded: false }),
  );
  assert.match(untimedMarkup, /Execution details/);
  assert.doesNotMatch(untimedMarkup, /Turn time/);
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

test("successful terminal keeps commentary and collapsed technical process visible", () => {
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
  assert.equal(
    screen
      .getByRole("button", { name: /^Execution details/ })
      .getAttribute("aria-expanded"),
    "false",
  );
  assert.ok(screen.getByText("Working through the task"));
  assert.ok(screen.getByText("Final response"));
  assert.equal(
    document.querySelector(".ai-exchange").lastElementChild.className,
    "response-copy-actions",
  );
});

test("terminal transition preserves an explicitly expanded Tool detail", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const activeRun = run({
    phase: "running",
    terminal: null,
    activity: { kind: "executing_tools", inFlight: "1" },
    tools: [
      technicalTool({
        state: "running",
        elapsedMs: "0",
        content: "live evidence",
      }),
    ],
  });
  const view = render(
    taskContentElement(
      task({
        currentRunId: "9",
        currentRunPhase: "running",
        runs: [activeRun],
      }),
    ),
  );
  await user.click(
    screen.getByRole("button", { name: /Inspecting the workspace/ }),
  );
  await user.click(
    screen.getByRole("button", { name: "Show or hide details for Read" }),
  );
  assert.ok(screen.getByText("live evidence"));

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
              response: "Done",
              responseKind: "final",
            },
            tools: [
              technicalTool({ content: "recorded evidence", elapsedMs: "12" }),
            ],
          },
        ],
      }),
      "2",
    ),
  );
  assert.ok(screen.getByRole("region", { name: "Details for Read" }));
  assert.ok(screen.getByText("recorded evidence"));
});

test("reply footer uses the product tooltip for the finished time", async (context) => {
  const user = userEvent.setup({ document: dom.window.document });
  const finishedAt = new Date(2026, 8, 11, 10, 25).getTime();
  context.mock.method(Date, "now", () => finishedAt + 4 * 24 * 60 * 60 * 1000);
  const view = render(
    taskContentElement(
      task({ runs: [run({ finishedAtUnixMs: String(finishedAt) })] }),
    ),
  );
  const footer = view.container.querySelector(".response-copy-actions");
  assert.equal(footer.children[0].tagName, "BUTTON");
  assert.equal(footer.children[1].tagName, "TIME");
  assert.equal(footer.querySelector("time").textContent, "4 days ago");
  const time = footer.querySelector("time");
  assert.equal(time.hasAttribute("title"), false);
  assert.equal(time.tabIndex, 0);
  assert.ok(time.getAttribute("aria-label").includes("2026"));

  await user.hover(time);
  await waitFor(() =>
    assert.equal(
      document.querySelector("[data-base-ui-portal]")?.textContent,
      time.getAttribute("aria-label"),
    ),
  );
});

test("input metadata places the nullable submitted time before copy", async (context) => {
  const user = userEvent.setup({ document: dom.window.document });
  const submittedAt = new Date(2026, 8, 11, 10, 25).getTime();
  context.mock.method(Date, "now", () => submittedAt + 4 * 24 * 60 * 60 * 1000);
  const view = render(
    taskContentElement(
      task({ runs: [run({ submittedAtUnixMs: String(submittedAt) })] }),
    ),
  );
  const metadata = view.container.querySelector(".input-copy-actions");
  assert.equal(metadata.children[0].tagName, "TIME");
  assert.equal(metadata.children[1].tagName, "BUTTON");
  assert.equal(metadata.querySelector("time").textContent, "4 days ago");
  assert.ok(screen.getByRole("button", { name: "Copy input" }));

  const time = metadata.querySelector("time");
  await user.hover(time);
  await waitFor(() =>
    assert.equal(
      document.querySelector("[data-base-ui-portal]")?.textContent,
      time.getAttribute("aria-label"),
    ),
  );
});

test("terminal transition preserves reading position and collapses technical details", () => {
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
  assert.equal(
    screen
      .getByRole("button", { name: /^Execution details/ })
      .getAttribute("aria-expanded"),
    "false",
  );
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

test("Tool summary expands its exact inline details", async () => {
  const user = userEvent.setup({ document: dom.window.document });
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
  render(taskContentElement(value));
  await user.click(
    screen.getByRole("button", { name: "Running an operation" }),
  );
  await user.click(
    screen.getByRole("button", { name: "Show or hide details for Bash" }),
  );
  assert.ok(screen.getByRole("region", { name: "Details for Bash" }));
  assert.ok(screen.getByText("private input"));
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
  assert.ok(
    markup.indexOf('class="ai-activity"') <
      markup.indexOf('class="response-copy-actions"'),
  );
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

test("Work process does not duplicate Tool file references", () => {
  const referenced = task({
    currentRunId: "9",
    currentRunPhase: "running",
    runs: [
      run({
        phase: "running",
        activity: { kind: "executing_tools", inFlight: "1" },
        terminal: null,
        output: {
          commentary: [],
          response: "",
          responseKind: null,
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
  render(taskContentElement(referenced));
  assert.equal(document.querySelector(".ai-exchange footer"), null);
  assert.equal(
    screen.queryByRole("button", { name: "Preview index.html" }),
    null,
  );
  fireEvent.click(document.querySelector(".run-process-header"));
  const rows = [...document.querySelectorAll(".run-process-tools > li")];
  assert.equal(rows.length, 8);
  for (const row of rows) {
    assert.ok(within(row).getByText("index.html"));
    assert.equal(
      within(row).queryByRole("button", { name: "Preview index.html" }),
      null,
    );
    assert.equal(
      within(row).queryByRole("button", {
        name: "Show or hide details for Read",
      }),
      null,
    );
  }
  fireEvent.click(document.querySelector(".run-process-header"));
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
    visible.indexOf(">File changes<") <
      visible.indexOf('class="response-copy-actions"'),
  );
  assert.match(visible, />Execution details</);
  assert.match(visible, />Turn time 0:12</);
  assert.ok(
    visible.indexOf(">File changes<") <
      visible.indexOf(">Execution details<") &&
      visible.indexOf(">Execution details<") <
        visible.indexOf('class="response-copy-actions"'),
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

function StatefulFileChangesView(props) {
  const [expandedFiles, setExpandedFiles] = useState({});
  const [scrollTop, setScrollTop] = useState(0);
  return createElement(FileChangesView, {
    ...props,
    expandedFiles,
    focus: props.focus ?? null,
    scrollTop,
    onFileExpandedChange(displayPath, expanded) {
      setExpandedFiles((current) => ({ ...current, [displayPath]: expanded }));
    },
    onFocusHandled: props.onFocusHandled ?? (() => {}),
    onScrollTopChange: setScrollTop,
  });
}

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
      createElement(StatefulFileChangesView, {
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
      createElement(StatefulFileChangesView, {
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
      createElement(StatefulFileChangesView, {
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

test("Task Panel review focuses the file requested by an Edit audit link", () => {
  const changes = [
    fileChange({ id: "change-a", displayPath: "src/a.ts" }),
    fileChange({ id: "change-b", order: "2", displayPath: "src/b.ts" }),
  ];
  const props = {
    observation: "complete",
    changes,
    diffs: {
      "change-a": { phase: "idle", diff: null },
      "change-b": { phase: "idle", diff: null },
    },
    onLoad() {},
  };
  const view = render(
    localizedView(
      createElement(StatefulFileChangesView, {
        ...props,
        focus: { displayPath: "src/b.ts", requestId: 1 },
      }),
    ),
  );
  assert.equal(
    document.activeElement,
    document
      .querySelector('[data-file-path="src/b.ts"]')
      .querySelector(".task-panel-change-toggle"),
  );

  view.rerender(
    localizedView(
      createElement(StatefulFileChangesView, {
        ...props,
        focus: { displayPath: "src/a.ts", requestId: 2 },
      }),
    ),
  );
  assert.equal(
    document.activeElement,
    document
      .querySelector('[data-file-path="src/a.ts"]')
      .querySelector(".task-panel-change-toggle"),
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
        createElement(StatefulFileChangesView, {
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
        createElement(StatefulFileChangesView, {
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
      createElement(StatefulFilePreviewView, { state, onRetry: onRefresh }),
    ),
  );
}

function StatefulFilePreviewView({ state, onRetry }) {
  const [mode, setMode] = useState("preview");
  const [scrollTop, setScrollTop] = useState(0);
  return createElement(FilePreviewView, {
    state,
    mode,
    scrollTop,
    onModeChange: setMode,
    onScrollTopChange: setScrollTop,
    onRetry,
  });
}

test("source preview language resolution is explicit and bounded", () => {
  for (const [path, content, expected] of [
    ["src/main.MTS", "", "typescript"],
    ["src/component.tsx", "", "tsx"],
    ["C:\\workspace\\Makefile", "", "makefile"],
    ["containers/Dockerfile", "", "docker"],
    ["native/CMakeLists.txt", "", "cmake"],
    ["crates/Cargo.lock", "", "toml"],
    ["ruby/Gemfile", "", "ruby"],
    ["native/build.zon", "", "zig"],
    ["config/settings.JSON", "", "json"],
    ["docs/readme.Markdown", "", "markdown"],
    ["web/page.HTML", "", "markup"],
    ["scripts/release", "#!/usr/bin/env -S node --no-warnings\n", "javascript"],
    ["scripts/check.command", "#!/usr/bin/env bash\n", "bash"],
    ["scripts/check", "#!/opt/tools/python3\n", "python"],
    ["notes.txt", "const misleading = true;", null],
  ]) {
    assert.equal(resolvePreviewLanguage(path, content), expected);
  }

  assert.equal(isWithinHighlightBudget("x".repeat(65_536)), true);
  assert.equal(isWithinHighlightBudget("x".repeat(65_537)), false);
  assert.equal(isWithinHighlightBudget("x\n".repeat(1_499)), true);
  assert.equal(isWithinHighlightBudget("x\n".repeat(1_500)), false);
  assert.equal(isWithinHighlightBudget("x\r".repeat(1_500)), false);
});

test("source preview line numbers preserve every displayed line boundary", () => {
  for (const [content, expected] of [
    ["", 1],
    ["plain", 1],
    ["plain\n", 2],
    ["one\ntwo\nthree", 3],
    ["one\r\ntwo", 2],
    ["one\rtwo", 2],
    ["\n\n", 3],
  ]) {
    assert.equal(countSourceLines(content), expected);
  }

  const content = "first\r\n\r\nthird\n";
  render(
    createElement(HighlightedSource, {
      displayPath: "notes.txt",
      content,
    }),
  );
  assert.equal(
    document.querySelector(".task-panel-code-gutter").textContent,
    "1\n2\n3\n4",
  );
  assert.equal(
    document
      .querySelector(".task-panel-code-gutter")
      .getAttribute("aria-hidden"),
    "true",
  );
  assert.equal(
    document.querySelector(".task-panel-code-source code").textContent,
    content,
  );
});

test("source preview does not load grammars for unknown or oversized content", async () => {
  let loadCount = 0;
  const loadHighlighter = async () => {
    loadCount += 1;
    throw new Error("must not load");
  };
  const view = render(
    createElement(HighlightedSource, {
      displayPath: "notes.txt",
      content: "plain text",
      loadHighlighter,
    }),
  );
  view.rerender(
    createElement(HighlightedSource, {
      displayPath: "large.js",
      content: "x".repeat(65_537),
      loadHighlighter,
    }),
  );
  view.rerender(
    createElement(HighlightedSource, {
      displayPath: "many-lines.js",
      content: "x\n".repeat(1_500),
      loadHighlighter,
    }),
  );
  await act(async () => Promise.resolve());
  assert.equal(loadCount, 0);
});

test("source preview keeps plain text after one failed highlight attempt", async () => {
  let loadCount = 0;
  const content = "const ready = true;";
  const props = {
    displayPath: "main.js",
    content,
    loadHighlighter: async () => {
      loadCount += 1;
      throw new Error("fixture load failure");
    },
  };
  const view = render(createElement(HighlightedSource, props));
  await waitFor(() => assert.equal(loadCount, 1));
  view.rerender(createElement(HighlightedSource, props));
  await act(async () => Promise.resolve());
  assert.equal(loadCount, 1);
  assert.equal(
    document.querySelector(".task-panel-code-source code").textContent,
    content,
  );
  assert.equal(document.querySelector(".token"), null);
});

test("source preview accepts only text-preserving span ASTs", () => {
  const valid = {
    type: "root",
    children: [
      {
        type: "element",
        tagName: "span",
        properties: { className: ["token", "keyword"] },
        children: [{ type: "text", value: "const" }],
      },
      { type: "text", value: " ready = true;" },
    ],
  };
  assert.notEqual(validateHighlightTree(valid, "const ready = true;"), null);
  assert.equal(validateHighlightTree(valid, "changed"), null);
  assert.equal(
    validateHighlightTree(
      {
        type: "root",
        children: [
          {
            type: "element",
            tagName: "img",
            properties: { src: "https://example.com/track.png" },
            children: [],
          },
        ],
      },
      "",
    ),
    null,
  );

  for (const properties of [
    { className: ["token", "keyword"], style: "display:none" },
    { className: ["token", 'keyword" onclick="attack'] },
  ]) {
    assert.equal(
      validateHighlightTree(
        {
          type: "root",
          children: [
            {
              type: "element",
              tagName: "span",
              properties,
              children: [{ type: "text", value: "const" }],
            },
          ],
        },
        "const",
      ),
      null,
    );
  }

  let tooDeep = { type: "text", value: "" };
  for (let depth = 0; depth < 9; depth += 1) {
    tooDeep = {
      type: "element",
      tagName: "span",
      properties: { className: ["token"] },
      children: [tooDeep],
    };
  }
  assert.equal(
    validateHighlightTree({ type: "root", children: [tooDeep] }, ""),
    null,
  );
  assert.equal(
    validateHighlightTree(
      {
        type: "root",
        children: Array.from({ length: 20_000 }, () => ({
          type: "text",
          value: "",
        })),
      },
      "",
    ),
    null,
  );
});

test("source preview progressively applies the registered grammar", async () => {
  const content = 'const 名称 = "🙂";\r\n\t// 保持原文\r\n';
  render(
    createElement(HighlightedSource, {
      displayPath: "src/main.zig",
      content,
    }),
  );
  assert.equal(
    document.querySelector(".task-panel-code-source code").textContent,
    content,
  );
  await waitFor(() => assert.ok(document.querySelector(".token.keyword")));
  assert.equal(
    document.querySelector(".task-panel-code-source code").textContent,
    content,
  );
});

test("source preview rejects a late highlight result after the file changes", async () => {
  let resolveLoader;
  let loadCount = 0;
  const loadHighlighter = () => {
    loadCount += 1;
    return new Promise((resolve) => {
      resolveLoader = resolve;
    });
  };
  const view = render(
    createElement(HighlightedSource, {
      displayPath: "old.js",
      content: "const oldValue = true;",
      loadHighlighter,
    }),
  );
  await waitFor(() => assert.equal(loadCount, 1));

  view.rerender(
    createElement(HighlightedSource, {
      displayPath: "notes.txt",
      content: "current plain text",
      loadHighlighter,
    }),
  );
  await act(async () => {
    resolveLoader({
      highlightSource() {
        return {
          type: "root",
          children: [
            {
              type: "element",
              tagName: "span",
              properties: { className: ["token", "keyword"] },
              children: [{ type: "text", value: "const" }],
            },
            { type: "text", value: " oldValue = true;" },
          ],
        };
      },
    });
    await Promise.resolve();
  });

  assert.equal(
    document.querySelector(".task-panel-code-source code").textContent,
    "current plain text",
  );
  assert.equal(document.querySelector("span.token"), null);
});

test("Task Panel renders file content without explanatory chrome", async () => {
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
  await waitFor(() => assert.ok(document.querySelector(".token.keyword")));
  assert.equal(document.querySelector(".task-panel-code").tabIndex, 0);
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
        mode: "preview",
        scrollTop: 0,
        onModeChange() {},
        onScrollTopChange() {},
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

test("Markdown preview renders documents, switches to source, and preserves mode while refreshing", async () => {
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
    document.querySelector(".task-panel-code-source code").textContent,
    content,
  );
  await waitFor(() => assert.ok(document.querySelector(".token")));
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
    document.querySelector(".task-panel-code-source code").textContent,
    "# Updated",
  );
  fireEvent.click(screen.getByRole("tab", { name: "Preview" }));
  assert.ok(screen.getByRole("heading", { name: "Updated" }));
});

test("text and HTML stay inert source without extra preview chrome", async () => {
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
    if (path === "notes.txt") {
      await act(async () => Promise.resolve());
      assert.equal(document.querySelector(".token"), null);
    } else {
      await waitFor(() => assert.ok(document.querySelector(".token")));
    }
    assert.equal(
      document.querySelector(".task-panel-code-source code").textContent,
      content,
    );
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

test("right-panel targets resolve exact document identities", () => {
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
});

test("Task Panel sessions preserve creation order and exact preview identity", () => {
  const firstReference = {
    id: "ref-a",
    title: "report.md",
    displayPath: "one/report.md",
  };
  const secondReference = {
    id: "ref-b",
    title: "report.md",
    displayPath: "two/report.md",
  };
  const value = task({
    runs: [
      run({
        tools: [technicalTool({ fileRefs: [firstReference, secondReference] })],
        fileChanges: {
          observation: "complete",
          changes: [{ id: "change-a" }],
        },
      }),
    ],
  });
  const first = createTaskPanelPreviewTab("3", "9", firstReference);
  const second = createTaskPanelPreviewTab("3", "9", secondReference);
  const review = createTaskPanelReviewTab("3", "9");
  let session = openTaskPanelTab(emptyTaskPanelSession, first, value, true);
  session = openTaskPanelTab(session, second, value, true);
  session = openTaskPanelTab(session, review, value, true);
  assert.deepEqual(
    session.tabs.map((tab) => tab.tabId),
    [first.tabId, second.tabId, review.tabId],
  );
  assert.equal(session.activeTabId, review.tabId);

  session = openTaskPanelTab(session, first, value, true);
  assert.deepEqual(
    session.tabs.map((tab) => tab.tabId),
    [first.tabId, second.tabId, review.tabId],
  );
  assert.equal(session.activeTabId, first.tabId);
  assert.notEqual(first.tabId, second.tabId);
});

test("Task Panel labels disambiguate duplicate file names without changing identity", () => {
  const tabs = [
    createTaskPanelPreviewTab("3", "9", {
      id: "one",
      title: "report.md",
      displayPath: "alpha/report.md",
    }),
    createTaskPanelPreviewTab("3", "9", {
      id: "two",
      title: "report.md",
      displayPath: "beta/report.md",
    }),
    createTaskPanelPreviewTab("3", "10", {
      id: "three",
      title: "report.md",
      displayPath: "beta/report.md",
    }),
  ];
  const labels = taskPanelTabLabels(tabs);
  assert.equal(labels.get(tabs[0].tabId), "alpha/report.md");
  assert.equal(labels.get(tabs[1].tabId), "beta/report.md · 1");
  assert.equal(labels.get(tabs[2].tabId), "beta/report.md · 2");
});

test("Task Panel tabs use manual keyboard activation and one tab stop", async () => {
  const tabs = ["a", "b", "c"].map((id) =>
    createTaskPanelPreviewTab("3", "9", {
      id,
      title: `${id}.txt`,
      displayPath: `${id}.txt`,
    }),
  );
  function Fixture() {
    const [activeTabId, setActiveTabId] = useState(tabs[0].tabId);
    return localizedView(
      createElement(
        TaskPanel,
        {
          title: "Side panel",
          tabs,
          activeTabId,
          attention: null,
          onSelectTab: setActiveTabId,
          onCloseTab() {},
          onClose() {},
        },
        tabs.find((tab) => tab.tabId === activeTabId)?.title,
      ),
    );
  }
  const user = userEvent.setup();
  render(createElement(Fixture));
  const first = screen.getByRole("tab", { name: "a.txt" });
  const second = screen.getByRole("tab", { name: "b.txt" });
  const third = screen.getByRole("tab", { name: "c.txt" });
  first.focus();

  await user.keyboard("{ArrowRight}");
  assert.equal(document.activeElement, second);
  assert.equal(first.getAttribute("aria-selected"), "true");
  assert.equal(second.getAttribute("aria-selected"), "false");
  assert.equal(screen.getByRole("tabpanel").textContent, "a.txt");

  await user.keyboard("{Enter}");
  assert.equal(second.getAttribute("aria-selected"), "true");
  assert.equal(screen.getByRole("tabpanel").textContent, "b.txt");
  assert.deepEqual(
    [first, second, third].map((tab) => tab.tabIndex),
    [-1, 0, -1],
  );

  await user.keyboard("{End}");
  assert.equal(document.activeElement, third);
  assert.equal(second.getAttribute("aria-selected"), "true");
  await user.keyboard("{Home}");
  assert.equal(document.activeElement, first);
});

test("Task Panel sessions replace the singleton review in place", () => {
  const reference = {
    id: "ref-a",
    title: "a.txt",
    displayPath: "a.txt",
  };
  const value = task({
    runs: [
      run({
        id: "9",
        tools: [technicalTool({ fileRefs: [reference] })],
        fileChanges: {
          observation: "complete",
          changes: [{ id: "change-a" }],
        },
      }),
      run({
        id: "10",
        fileChanges: {
          observation: "complete",
          changes: [{ id: "change-b" }],
        },
      }),
    ],
  });
  const preview = createTaskPanelPreviewTab("3", "9", reference);
  let session = openTaskPanelTab(emptyTaskPanelSession, preview, value, true);
  session = openTaskPanelTab(
    session,
    createTaskPanelReviewTab("3", "9"),
    value,
    true,
  );
  const reviewId = session.activeTabId;
  session = openTaskPanelTab(
    session,
    createTaskPanelReviewTab("3", "10"),
    value,
    true,
  );
  assert.deepEqual(
    session.tabs.map((tab) => tab.tabId),
    [preview.tabId, reviewId],
  );
  assert.equal(session.tabs[1].runId, "10");
  assert.equal(session.activeTabId, reviewId);

  const invalid = openTaskPanelTab(
    session,
    createTaskPanelReviewTab("3", "missing"),
    value,
    true,
  );
  assert.deepEqual(invalid, session);
});

test("Task Panel sessions choose a stable neighbor and reconcile only invalid tabs", () => {
  const references = ["a", "b", "c"].map((id) => ({
    id,
    title: `${id}.txt`,
    displayPath: `${id}.txt`,
  }));
  const value = task({
    runs: [run({ tools: [technicalTool({ fileRefs: references })] })],
  });
  let session = emptyTaskPanelSession;
  for (const reference of references)
    session = openTaskPanelTab(
      session,
      createTaskPanelPreviewTab("3", "9", reference),
      value,
      true,
    );
  session = selectTaskPanelTab(session, session.tabs[1].tabId);
  session = closeTaskPanelTab(session, session.tabs[1].tabId);
  assert.equal(session.activeTabId, session.tabs[1].tabId);

  const withoutLast = task({
    runs: [
      run({ tools: [technicalTool({ fileRefs: references.slice(0, 1) })] }),
    ],
  });
  session = reconcileTaskPanelSession(session, withoutLast, true);
  assert.deepEqual(
    session.tabs.map((tab) => tab.referenceId),
    ["a"],
  );
  assert.equal(session.activeTabId, session.tabs[0].tabId);
  assert.deepEqual(
    reconcileTaskPanelSession(session, task({ id: "4" }), true),
    emptyTaskPanelSession,
  );
});

test("file preview resources load independently and reject closed or switched Task responses", async () => {
  const references = ["a", "b"].map((id) => ({
    id,
    title: `${id}.txt`,
    displayPath: `${id}.txt`,
  }));
  const tabs = references.map((reference) =>
    createTaskPanelPreviewTab("3", "9", reference),
  );
  const requests = [];
  const load = (taskId, runId, referenceId) =>
    new Promise((resolve, reject) =>
      requests.push({ taskId, runId, referenceId, resolve, reject }),
    );
  let previewTabs;
  function Harness({ activeTaskId }) {
    previewTabs = useFilePreviewTabs(
      activeTaskId,
      new Set(tabs.map((tab) => tab.tabId)),
      load,
    );
    return null;
  }
  const view = render(createElement(Harness, { activeTaskId: "3" }));
  await act(async () => {
    previewTabs.open("3", "9", references[0]);
    previewTabs.open("3", "9", references[1]);
  });
  assert.deepEqual(
    requests.map(({ referenceId }) => referenceId),
    ["a", "b"],
  );
  await act(async () => {
    requests[1].resolve({
      state: "ready",
      content: "second",
      truncated: false,
      redacted: false,
    });
    requests[0].resolve({
      state: "ready",
      content: "first",
      truncated: false,
      redacted: false,
    });
    await Promise.resolve();
  });
  assert.equal(previewTabs.resources[tabs[0].tabId].preview.content, "first");
  assert.equal(previewTabs.resources[tabs[1].tabId].preview.content, "second");

  await act(async () => previewTabs.open("3", "9", references[0]));
  assert.equal(requests.length, 2);
  await act(async () => previewTabs.refresh("3", "9", references[0]));
  assert.equal(requests.length, 3);
  await act(async () => previewTabs.close(tabs[0].tabId));
  await act(async () => {
    requests[2].resolve({
      state: "ready",
      content: "stale",
      truncated: false,
      redacted: false,
    });
    await Promise.resolve();
  });
  assert.equal(previewTabs.resources[tabs[0].tabId], undefined);
  assert.equal(previewTabs.resources[tabs[1].tabId].preview.content, "second");

  view.rerender(createElement(Harness, { activeTaskId: "4" }));
  await waitFor(() => assert.deepEqual(previewTabs.resources, {}));
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
  const value = task({
    runs: [run({ tools: [technicalTool({ fileRefs: [{ id: "ref-a" }] })] })],
  });
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
      target: {
        kind: "preview",
        taskId: "3",
        runId: "9",
        referenceId: "ref-a",
      },
    }),
  );
  fireEvent.click(screen.getByRole("button"));
  assert.equal(session.target.kind, "preview");
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
  assert.equal(session.target.kind, "preview");
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

test("inline Tool detail follows live props without unsafe markup", () => {
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
      /Fixed when this Task was created.*Choices for later Tasks do not affect it/,
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

test("empty detail pane has one hide action and no review navigation layer", async () => {
  let close = 0;
  const view = render(
    localizedView(
      createElement(
        TaskPanel,
        {
          title: "Review",
          tabs: [],
          activeTabId: null,
          attention: createElement("button", null, "Needs your attention"),
          onSelectTab() {},
          onCloseTab() {},
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
        {
          title: "Tool details",
          tabs: [],
          activeTabId: null,
          attention: null,
          onSelectTab() {},
          onCloseTab() {},
          onClose: () => close++,
        },
        createElement("p", null, "tool body"),
      ),
    ),
  );
  assert.equal(screen.queryByText("diff body"), null);
  assert.equal(screen.queryByRole("button", { name: "Back to changes" }), null);
  fireEvent.click(screen.getByRole("button", { name: "Hide side panel" }));
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
  first.runs[0].output.commentary = ["Working with `a.txt` and `b.txt`."];
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

function filePreviewOpener(path) {
  return screen.getByRole("button", { name: `Preview ${path}` });
}

function fileChangesOpener() {
  return screen
    .getAllByRole("button")
    .find(
      (button) =>
        button.textContent.includes("File changes") &&
        button.textContent.includes("Review changes"),
    );
}

function assertTaskPanelShellHidden() {
  const panel = document.querySelector("#task-panel");
  assert.ok(panel !== null);
  assert.equal(panel.getAttribute("aria-hidden"), "true");
  assert.equal(panel.childElementCount, 0);
}

test("permanent panel toggle hides and restores the active Task Panel session", async (ctx) => {
  const { snapshot, previews, diffs, publish } = await renderAppFixture(ctx);
  await screen.findByRole("button", { name: /First task/ });
  const toggle = screen.getByRole("button", { name: "Open side panel" });
  assert.equal(toggle.disabled, false);
  fireEvent.click(toggle);
  assert.ok(
    screen.getByText("Open a file or review changes from the conversation."),
  );
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
  assert.ok(panel().getByText("stale body"));
  assert.equal(previews.length, 1);
  const shell = document.querySelector(".app-window");
  const previewWidth = shell.style.getPropertyValue("--right-panel-width");
  const permanentToggle = document.querySelector(
    'button[aria-controls="task-panel"]',
  );
  assert.equal(permanentToggle, toggle);
  assert.equal(
    document.querySelectorAll('button[aria-controls="task-panel"]').length,
    1,
  );
  const reviewOpener = fileChangesOpener();
  fireEvent.click(reviewOpener);
  assert.equal(diffs.length, 1);
  assert.deepEqual(diffs[0].ids, ["3", "7", "change-a"]);
  assert.ok(panel().getByRole("heading", { name: "Review changes" }));
  assert.equal(
    shell.style.getPropertyValue("--right-panel-width"),
    previewWidth,
  );
  assert.equal(
    document.querySelector('button[aria-controls="task-panel"]'),
    permanentToggle,
  );
  assert.equal(permanentToggle.getAttribute("aria-expanded"), "true");
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
  const closeReview = panel().getByRole("button", { name: "Hide side panel" });
  closeReview.focus();
  fireEvent.click(closeReview);
  await act(
    async () => new Promise((resolve) => window.requestAnimationFrame(resolve)),
  );
  assert.equal(document.activeElement === reviewOpener, true);
  assertTaskPanelShellHidden();
  fireEvent.click(toggle);
  assert.ok(panel().getByText("+first a"));
  assert.equal(diffs.length, 3);
  snapshot.tasks[0].runs = [];
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  await waitFor(() =>
    assert.ok(
      panel().getByText("Open a file or review changes from the conversation."),
    ),
  );
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

test("layout visibility and share survive Task changes, invalidation, and non-Task pages", async (ctx) => {
  const { snapshot, previews, publish } = await renderAppFixture(ctx);
  fireEvent.click(await screen.findByRole("button", { name: /First task/ }));
  fireEvent.click(screen.getByRole("button", { name: "Open side panel" }));
  const shell = document.querySelector(".app-window");
  const resize = screen.getByRole("separator", { name: "Resize side panel" });
  fireEvent.keyDown(resize, { key: "ArrowLeft" });
  const rightWidth = shell.style.getPropertyValue("--right-panel-width");
  const share = dom.window.localStorage.getItem("metawork.panel.task.share");
  assert.notEqual(share, null);
  assert.notEqual(Number(share), 1 / 3);
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
  assert.equal(shell.style.getPropertyValue("--right-panel-width"), rightWidth);
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.share"),
    share,
  );
  fireEvent.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  assert.ok(
    screen.getByText("Open a file or review changes from the conversation."),
  );
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  fireEvent.click(screen.getByRole("button", { name: "Skills", exact: true }));
  assert.ok(
    screen.getByText("Open a file or review changes from the conversation."),
  );
  assert.ok(
    !screen.getAllByRole("button", { name: "Hide side panel" })[0].disabled,
  );
  fireEvent.click(screen.getByRole("button", { name: /Second task/ }));
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  snapshot.tasks.splice(1, 1);
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  await screen.findByText(
    "Open a file or review changes from the conversation.",
  );
  assert.equal(shell.getAttribute("data-right-panel-open"), "true");
  assert.equal(shell.style.getPropertyValue("--right-panel-width"), rightWidth);
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.share"),
    share,
  );
  fireEvent.click(
    within(document.querySelector("#task-panel")).getByRole("button", {
      name: "Hide side panel",
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: /First task/ }));
  assert.equal(shell.getAttribute("data-right-panel-open"), "false");
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.share"),
    share,
  );
  cleanup();
});

test("App keeps preview and Review resources independent and rejects stale responses", async (ctx) => {
  const { snapshot, previews, diffs, publish } = await renderAppFixture(ctx);
  const firstButton = await screen.findByRole("button", { name: /First task/ });
  fireEvent.click(firstButton);
  await screen.findByRole("button", { name: "Task information" });
  assert.ok(
    screen.getByRole("button", { name: "Open side panel" }).disabled === false,
  );
  const openPreview = () =>
    fireEvent.click(
      screen.getAllByRole("button", { name: "Preview a.txt" })[0],
    );
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
      name: "Hide side panel",
    }),
  );
  await act(async () => previews[0].resolve(ready("loaded while hidden")));
  assert.equal(screen.queryByText("loaded while hidden"), null);
  assertTaskPanelShellHidden();
  openPreview();
  assert.equal(previews.length, 1);
  assert.ok(screen.getByText("loaded while hidden"));
  fireEvent.click(fileChangesOpener());
  assert.equal(document.querySelector(".task-panel-code"), null);
  assert.equal(diffs.length, 1);
  assert.deepEqual(diffs[0].ids, ["3", "7", "change-a"]);
  assert.equal(screen.queryByText("loaded while hidden"), null);
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
  const retainedFileToggle = document.querySelector(
    '[data-file-path="a.txt"] .task-panel-change-toggle',
  );
  fireEvent.click(retainedFileToggle);
  assert.equal(retainedFileToggle.getAttribute("aria-expanded"), "false");
  openPreview();
  assert.ok(screen.getByText("loaded while hidden"));
  assert.equal(previews.length, 1);
  fireEvent.click(fileChangesOpener());
  assert.ok(screen.getByText("+late a"));
  assert.equal(
    document
      .querySelector('[data-file-path="a.txt"] .task-panel-change-toggle')
      .getAttribute("aria-expanded"),
    "false",
  );
  assert.equal(diffs.length, 2);

  const replacementRun = structuredClone(snapshot.tasks[0].runs[0]);
  replacementRun.id = "8";
  replacementRun.fileChanges = {
    observation: "complete",
    changes: [
      {
        ...replacementRun.fileChanges.changes[0],
        id: "replacement-a",
        order: "1",
        displayPath: "a.txt",
      },
    ],
  };
  snapshot.tasks[0].runs.push(replacementRun);
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () => publish());
  let reviewOpeners = [];
  await waitFor(() => {
    reviewOpeners = screen
      .getAllByRole("button")
      .filter(
        (button) =>
          button.textContent.includes("File changes") &&
          button.textContent.includes("Review changes"),
      );
    assert.equal(reviewOpeners.length, 2);
  });
  fireEvent.click(reviewOpeners.at(-1));
  await waitFor(() => assert.equal(diffs.length, 3));
  assert.deepEqual(diffs[2].ids, ["3", "8", "replacement-a"]);
  assert.equal(
    document
      .querySelector('[data-file-path="a.txt"] .task-panel-change-toggle')
      .getAttribute("aria-expanded"),
    "true",
  );

  openPreview();
  fireEvent.click(
    within(document.querySelector("#task-panel")).getByRole("button", {
      name: "Refresh",
    }),
  );
  assert.equal(previews.length, 2);
  fireEvent.click(screen.getByRole("button", { name: /Second task/ }));
  await act(async () => previews[1].resolve(ready("late after switch")));
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
  assertTaskPanelShellHidden();
  assert.equal(document.querySelector(".run-process-files"), null);
});

test("Markdown preview mode is isolated per tab and inactive content is unmounted", async (ctx) => {
  const { previews } = await renderAppFixture(ctx, 1440, {
    output: {
      commentary: ["Working with `a.md` and `b.markdown`."],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
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
  const firstSource = document.querySelector(".task-panel-code");
  firstSource.scrollTop = 84;
  fireEvent.scroll(firstSource);
  fireEvent.click(filePreviewOpener("b.markdown"));
  assert.equal(document.querySelector(".task-panel-code"), null);
  await act(async () => previews[1].resolve(ready("# Second document")));
  assert.ok(screen.getByRole("heading", { name: "Second document" }));
  assert.equal(
    screen.getByRole("tab", { name: "Preview" }).getAttribute("aria-selected"),
    "true",
  );
  assert.equal(screen.queryByText("# First document"), null);
  fireEvent.click(screen.getByRole("tab", { name: "a.md" }));
  assert.equal(
    screen.getByRole("tab", { name: "Source" }).getAttribute("aria-selected"),
    "true",
  );
  assert.equal(
    document.querySelector(".task-panel-code-source code").textContent,
    "# First document",
  );
  assert.equal(document.querySelector(".task-panel-code").scrollTop, 84);
  assert.equal(
    screen.queryByRole("heading", { name: "Second document" }),
    null,
  );
  fireEvent.click(screen.getByRole("button", { name: "Close a.md" }));
  assert.ok(screen.getByRole("heading", { name: "Second document" }));
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  assert.equal(
    document.activeElement,
    screen.getByRole("tab", { name: "b.markdown" }),
  );
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
  fireEvent.click(panel.getByRole("button", { name: "Hide side panel" }));
  fireEvent.click(openers[1]);
  assert.equal(previews.length, 3);
  assert.ok(screen.getByText("refreshed reference"));
  fireEvent.click(
    within(document.querySelector("#task-panel")).getByRole("button", {
      name: "Close b.txt",
    }),
  );
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
    assertTaskPanelShellHidden();
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
      document.querySelector("#task-panel").getAttribute("aria-hidden"),
      String(width !== 1440),
    );
    if (width === 1440)
      fireEvent.click(
        within(document.querySelector("#task-panel")).getByRole("button", {
          name: "Hide side panel",
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
  const tab = screen.getByRole("tab", { name: "a.txt" });
  assert.ok(document.activeElement === tab);
  // Nested controls can consume Escape without closing the pane.
  const stopEscape = (event) => event.preventDefault();
  tab.addEventListener("keydown", stopEscape);
  fireEvent.keyDown(tab, { key: "Escape" });
  assert.ok(document.querySelector("#task-panel") !== null);
  tab.removeEventListener("keydown", stopEscape);
  fireEvent.keyDown(tab, { key: "Escape" });
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  assertTaskPanelShellHidden();
  assert.ok(document.activeElement === opener);
  fireEvent.click(opener);
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  opener.remove();
  assert.equal(opener.isConnected, false);
  fireEvent.keyDown(screen.getByRole("tab", { name: "a.txt" }), {
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
