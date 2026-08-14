import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { ComposerFooter } = await vite.ssrLoadModule(
  "/src/features/composer/ComposerFooter.tsx",
);
const { AppShell } = await vite.ssrLoadModule("/src/app/AppShell.tsx");
const { AgentWorkSurface } = await vite.ssrLoadModule(
  "/src/features/agent-surface/AgentWorkSurface.tsx",
);
const { NewTaskView } = await vite.ssrLoadModule(
  "/src/features/tasks/NewTaskView.tsx",
);
const { TaskList } = await vite.ssrLoadModule(
  "/src/features/tasks/TaskList.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => {
  await vite.close();
});

const base = {
  textareaRef: { current: null },
  archived: false,
  closing: false,
  closed: false,
  unavailable: false,
  unavailableReason: null,
  recoveryAvailable: false,
  recoveryInProgress: false,
  recoveryDisabled: false,
  draft: { kind: "text", text: "" },
  skillCatalog: {
    availability: "ready",
    redacted: false,
    revision: "4",
    skills: [],
    issues: [],
  },
  slashCommands: [],
  composeDisabled: false,
  canSubmit: false,
  runInFlight: false,
  accessRequired: false,
  workspaceMissing: false,
  workspaceLabel: "Default",
  workspaceTitle: "Default",
  workspaceOptions: [
    {
      id: "automatic",
      label: "Default",
      authorization: "available",
    },
  ],
  selectedWorkspaceOptionId: "automatic",
  workspaceEditable: true,
  modelLabel: "Claude Sonnet 4",
  modelOptions: [
    { selectionId: "claude-sonnet-4", displayName: "Claude Sonnet 4" },
  ],
  selectedModelId: "claude-sonnet-4",
  modelEditable: true,
  modelSelectionDisabled: false,
  modelSelectionPending: false,
  modelContextTitle: "Default model",
  actionDisabled: false,
  onDraftChange() {},
  onSubmit() {},
  onRestore() {},
  onSlashCommand() {},
  onRefreshSkillCatalog() {},
  onConfirmAccess() {},
  onSelectWorkspace() {},
  onSelectModel() {},
};

test("Conversation recovery is an explicit accessible Composer action", () => {
  const required = render({
    unavailable: true,
    unavailableReason: "session_recovery_required",
    recoveryAvailable: true,
  });
  assert.match(required, /role="status"/);
  assert.match(required, /aria-live="polite"/);
  assert.match(required, />Continue this conversation</);
  assert.match(required, />Restore conversation</);

  const restoring = render({
    unavailable: true,
    unavailableReason: "session_recovery_in_progress",
    recoveryInProgress: true,
  });
  assert.match(restoring, /data-state="in-progress"/);
  assert.match(restoring, /disabled=""/);
  assert.match(restoring, />Restoring…</);
});

function relativeLuminance(hex) {
  const channels = hex
    .match(/[0-9a-f]{2}/gi)
    .map((channel) => Number.parseInt(channel, 16) / 255)
    .map((channel) =>
      channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
    );
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function contrastRatio(foreground, background) {
  const foregroundLuminance = relativeLuminance(foreground);
  const backgroundLuminance = relativeLuminance(background);
  return (
    (Math.max(foregroundLuminance, backgroundLuminance) + 0.05) /
    (Math.min(foregroundLuminance, backgroundLuminance) + 0.05)
  );
}

function hasBooleanAttribute(markup, name) {
  return new RegExp(`\\b${name}=""`).test(markup);
}

function render(props = {}) {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(ComposerFooter, { ...base, ...props }),
    ),
  );
}

function renderShell(
  inspector,
  inspectorOpen = false,
  left = undefined,
  contextVisible = true,
) {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(
        AppShell,
        {
          taskTitle: "New task",
          contextVisible,
          status: "Connected",
          onSearch() {},
          left:
            left === undefined ? createElement("p", null, "Navigation") : left,
          inspector,
          inspectorOpen,
          onDismissInspector() {},
        },
        createElement("p", null, "Composer stage"),
      ),
    ),
  );
}

function renderCompletedTimeline(
  assistant = "Release is ready",
  input = {
    kind: "text",
    text: "Inspect the release",
    redacted: false,
  },
  compacts = [],
) {
  const task = {
    id: "3",
    runs: [
      {
        id: "9",
        phase: "completed",
        input,
        assistant,
        assistantRedacted: false,
        outcome: "completed",
        cause: null,
        usage: { input: "12", output: "5" },
        tools: [
          {
            id: "tool-1",
            order: "1",
            name: "Read",
            state: "completed",
            elapsedMs: "4",
            input: "fixture.txt",
            progress: "",
            content: "ready",
            isError: false,
            redacted: false,
            inputTruncated: false,
            progressTruncated: false,
            contentTruncated: false,
          },
        ],
      },
    ],
    compacts,
    pendingUi: null,
    uiHistory: [],
  };
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(AgentWorkSurface, {
        task,
        revision: "1",
        composerHasDraft: false,
        retryAvailable: true,
        responseDisabled: false,
        onPrepareRetry() {},
        onInspect() {},
        onRespond() {},
        renderPendingUi() {
          return null;
        },
        renderUiRecord() {
          return null;
        },
      }),
    ),
  );
}

function renderNewTaskView(composer = null) {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(NewTaskView, {
        hasWorkspace: true,
        composer,
      }),
    ),
  );
}

function renderTaskList(tasks, workspaces = []) {
  return renderToStaticMarkup(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(TaskList, {
        tasks,
        workspaces,
        activeTaskId: null,
        showArchived: false,
        onSelectTask() {},
        onToggleArchived() {},
      }),
    ),
  );
}

function tag(markup, className) {
  return markup.match(
    new RegExp(`<(?:button|textarea)[^>]*class="[^"]*${className}[^"]*"[^>]*>`),
  )?.[0];
}

test("New task opens as an editable Composer with its execution context", () => {
  const markup = render();
  assert.match(markup, /<textarea/);
  assert.match(markup, />Claude Sonnet 4</);
  assert.match(markup, />Default</);
  assert.doesNotMatch(markup, />Select a workspace</);
  assert.match(markup, /composer-workspace-context/);
  assert.equal(
    hasBooleanAttribute(markup.match(/<textarea[^>]*>/)?.[0] ?? "", "disabled"),
    false,
  );
  assert.doesNotMatch(markup, /composer-start/);
});

test("candidate model catalogs never imply a committed default", () => {
  const markup = render({
    modelLabel: "Choose a model",
    modelOptions: [
      { selectionId: "candidate-model", displayName: "Candidate model" },
    ],
    selectedModelId: "",
    modelSelectionDisabled: true,
    modelSelectionPending: true,
  });
  const trigger =
    markup.match(
      /<button[^>]*class="[^"]*composer-model-trigger[^"]*"[^>]*>/,
    )?.[0] ?? "";
  assert.match(trigger, /role="combobox"/);
  assert.match(trigger, /disabled=""/);
  assert.match(trigger, /data-placeholder=""/);
  assert.match(trigger, /aria-busy="true"/);
  assert.match(markup, />Choose a model</);
  assert.doesNotMatch(markup, />Candidate model</);
});

test("disabled model selection does not invent a pending state", () => {
  const markup = render({
    modelSelectionDisabled: true,
    modelSelectionPending: false,
  });
  const trigger =
    markup.match(
      /<button[^>]*class="[^"]*composer-model-trigger[^"]*"[^>]*>/,
    )?.[0] ?? "";
  assert.match(trigger, /disabled=""/);
  assert.doesNotMatch(trigger, /aria-busy/);
});

test("model selection keeps its exact identity when display metadata is absent", () => {
  const markup = render({
    modelLabel: "deepseek-v4",
    modelOptions: [{ selectionId: "deepseek-v4", displayName: "" }],
    selectedModelId: "deepseek-v4",
  });
  assert.match(markup, />deepseek-v4</);
  assert.doesNotMatch(markup, />Available model</);
});

test("Workbench keeps Search as an icon beside the sidebar control", () => {
  const markup = renderShell(null);
  const leading = markup.indexOf('class="commandbar-leading-actions"');
  const search = markup.indexOf('aria-label="Search"');
  const context = markup.indexOf('class="commandbar-context"');
  assert.ok(leading >= 0 && search > leading && context > search);
  assert.doesNotMatch(markup, /<kbd>.*K<\/kbd>/);
  assert.doesNotMatch(markup, /<span>Search<\/span>/);
  assert.doesNotMatch(markup, /title="Search"/);
});

test("Account catalog work blocks New task admission but not bound Tasks", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  assert.match(
    source,
    /\(!newTaskDraftActive \|\| snapshot\.account\.canCreateTask\)/,
  );
  assert.match(source, /\(!newTaskDraftActive \|\| newTaskWorkspaceReady\)/);
});

test("Automatic Workspace creation is explicit in the first submit", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  const start = source.indexOf("async function submitRun()");
  const end = source.indexOf("\n  async function", start + 1);
  const submitRun = source.slice(start, end);
  assert.match(submitRun, /kind: "automatic" as const/);
  assert.match(submitRun, /kind: "manual" as const/);
  assert.doesNotMatch(submitRun, /chooseWorkspace|client\.chooseWorkspace/);
});

test("Slash V1 reuses the existing New task and Compact actions", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  const start = source.indexOf("function runSlashCommand(");
  const end = source.indexOf("\n  async function", start + 1);
  const controller = source.slice(start, end);
  assert.match(controller, /case "new":[\s\S]*beginNewTask\(\)/);
  assert.match(controller, /case "compact":[\s\S]*compactTask\(\)/);
  assert.doesNotMatch(controller, /client\.|invoke\(|tasks\./);
});

test("New task does not render or reserve an empty Inspector", () => {
  const markup = renderShell(null);
  assert.doesNotMatch(markup, /id="task-inspector"/);
  assert.doesNotMatch(markup, /aria-controls="task-inspector"/);
  assert.match(markup, /data-inspector-open="false"/);
});

test("Settings uses the global stage without retaining the Task sidebar", () => {
  const markup = renderShell(null, false, null);
  assert.doesNotMatch(markup, /id="workspace-sidebar"/);
  assert.doesNotMatch(markup, /aria-controls="workspace-sidebar"/);
  assert.match(markup, /data-left-open="false"/);
});

test("terminal delivery follows tool activity and precedes the outcome", () => {
  const markup = renderCompletedTimeline();
  assert.ok(markup.indexOf("Read") < markup.indexOf("Release is ready"));
  assert.ok(
    markup.indexOf("Release is ready") < markup.indexOf("Work completed"),
  );
  assert.match(renderCompletedTimeline(""), /did not return a final response/);
});

test("each typed Tool stays an independent bounded detail card", async () => {
  const [markup, css, timeline, approval] = await Promise.all([
    Promise.resolve(renderCompletedTimeline()),
    readFile(join(process.cwd(), "frontend/src/index.css"), "utf8"),
    readFile(
      join(process.cwd(), "frontend/src/features/agent-surface/AgentWorkSurface.tsx"),
      "utf8",
    ),
    readFile(
      join(process.cwd(), "frontend/src/features/approvals/ApprovalPanel.tsx"),
      "utf8",
    ),
  ]);
  assert.equal(markup.match(/class="ai-tool tool-card"/g)?.length, 1);
  assert.match(markup, /class="ai-tool tool-card" data-state="completed"/);
  assert.match(css, /\.code-block-preview\s*\{[\s\S]*?max-height:\s*240px/);
  assert.match(timeline, /key=\{`tool:\$\{activity\.id\}`\}/);
  assert.doesNotMatch(timeline, /bg-cobalt/);
  assert.doesNotMatch(approval, /accent-cobalt/);
});

test("Timeline preserves typed Skill identity and positional arguments", () => {
  const markup = renderCompletedTimeline("Review complete", {
    kind: "skill",
    skillId: "builtin.review",
    catalogRevision: "17",
    invocationName: "review",
    displayName: "Review",
    argumentValues: ["src/main.zig"],
    redacted: false,
  });
  assert.match(markup, /timeline-skill-token/);
  assert.match(markup, />\/review/);
  assert.match(markup, />src\/main\.zig</);
});

test("Timeline projects manual Compact as a lightweight system event", () => {
  const markup = renderCompletedTimeline("Release is ready", undefined, [
    {
      operationId: "11",
      afterRunId: "9",
      phase: "compacted",
      cause: null,
      beforeContextTokens: "100",
      afterContextTokens: "40",
      usage: { input: "5", output: "2", cacheRead: "0", cacheCreation: "0" },
    },
  ]);
  assert.match(markup, /timeline-system-event/);
  assert.match(markup, /Context compacted/);
  assert.match(markup, /100/);
  assert.match(markup, /40/);
});

test("new Task places the Composer after the outcome prompt", () => {
  const markup = renderNewTaskView(
    createElement("footer", { "data-test": "draft-composer" }, "Composer"),
  );
  const prompt = markup.indexOf("Start with the outcome");
  const composer = markup.indexOf('data-test="draft-composer"');
  assert.ok(prompt >= 0 && composer > prompt);
  assert.doesNotMatch(markup, /task-examples|task-example/);
});

test("Workbench foundation uses a stable 760px new Task Composer stage", async () => {
  const [app, shell, css, tokens] = await Promise.all([
    readFile(join(process.cwd(), "frontend/src/app/App.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/app/AppShell.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/index.css"), "utf8"),
    readFile(
      join(process.cwd(), "frontend/src/styles/metask-tokens.css"),
      "utf8",
    ),
  ]);
  assert.match(css, /@import "\.\/styles\/metask-tokens\.css"/);
  assert.match(tokens, /--metask-primary:\s*#8a4ed1/);
  assert.match(tokens, /--ui-action-primary:\s*var\(--metask-primary\)/);
  assert.match(css, /--left-column:\s*248px/);
  assert.match(
    css,
    /\.app-window\[data-left-open="true"\] \.workbench-commandbar::before\s*\{[\s\S]*?width:\s*var\(--left-column\);[\s\S]*?border-right:\s*1px solid var\(--ui-border\);[\s\S]*?background:\s*var\(--ui-surface-panel-2\)/,
  );
  assert.match(
    css,
    /\.workbench-commandbar\s*\{[\s\S]*?background:\s*var\(--ui-surface-canvas\)/,
  );
  assert.doesNotMatch(
    css.match(/\.workbench-commandbar\s*\{[\s\S]*?\n\}/)?.[0] ?? "",
    /border-bottom|backdrop-filter/,
  );
  assert.doesNotMatch(app, /className="brand-mark"|app\.window_label/);
  assert.match(app, /<p className="brand-name">\{t\("app\.name"\)\}<\/p>/);
  assert.match(css, /\.sidebar-primary\s*\{[\s\S]*?padding:\s*10px 14px 0/);
  assert.match(css, /\.new-task-button\s*\{[\s\S]*?margin-top:\s*8px/);
  assert.match(css, /\.brand-name\s*\{[\s\S]*?min-height:\s*26px/);
  assert.match(css, /--content-measure:\s*760px/);
  assert.match(
    css,
    /\.new-task-content\s*\{[\s\S]*?width:\s*min\(100%, var\(--content-measure\)\)/,
  );
  assert.match(
    css,
    /\.new-task-view\s*\{[\s\S]*?display:\s*grid[\s\S]*?padding:\s*clamp\(24px, 4vh, 40px\) 24px clamp\(104px, 16vh, 144px\)[\s\S]*?align-items:\s*center/,
  );
  assert.match(
    css,
    /\.new-task-content \.composer\s*\{[\s\S]*?min-height:\s*140px/,
  );
  assert.doesNotMatch(css, /\.task-examples|\.task-example/);
  assert.doesNotMatch(css, /color-cobalt|settings-teal|35,\s*109,\s*100/);
  assert.match(app, /<NewTaskView[\s\S]*?composer=\{composerFooter\}/);
  assert.doesNotMatch(app, /draftComposer=/);
  assert.match(
    app,
    /!newTaskDraftActive && \(\s*<header className="task-header">/,
  );
  assert.match(
    app,
    /contextVisible=\{route === "workbench" && activeTask !== null\}/,
  );
  assert.doesNotMatch(shell, /commandbar-workspace|commandbar-separator/);
  assert.match(shell, /commandbar-task/);
});

test("New task keeps the titlebar quiet while a real Task retains context", () => {
  const quiet = renderShell(null, false, undefined, false);
  assert.doesNotMatch(quiet, /No workspace|New task/);

  const contextual = renderShell(null, false, undefined, true);
  assert.doesNotMatch(contextual, /No workspace/);
  assert.match(contextual, /New task/);
});

test("Workbench semantic text colors meet WCAG AA contrast", async () => {
  const tokens = await readFile(
    join(process.cwd(), "frontend/src/styles/metask-tokens.css"),
    "utf8",
  );
  const canvas = "#f7f8fa";
  const pairs = [
    ["#191b21", canvas],
    ["#626775", canvas],
    ["#4b2db5", canvas],
    ["#7d4308", "#ffffff"],
  ];
  assert.match(tokens, /--metask-light-canvas:\s*#f7f8fa/);
  assert.match(tokens, /--metask-light-text:\s*#191b21/);
  for (const [foreground, background] of pairs) {
    assert.ok(
      contrastRatio(foreground, background) >= 4.5,
      `${foreground} on ${background} falls below WCAG AA`,
    );
  }
});

test("a new Task draft is editable before its first send", () => {
  const markup = render({
    draft: { kind: "text", text: "Ship the release" },
    canSubmit: true,
    workspaceMissing: false,
    workspaceLabel: "alpha",
    workspaceTitle: "/repo/alpha",
    workspaceOptions: [
      {
        id: "1",
        label: "/repo/alpha",
        description: "alpha",
        authorization: "available",
      },
    ],
    selectedWorkspaceOptionId: "1",
  });
  assert.match(markup, /<textarea/);
  assert.match(markup, />Ship the release</);
  assert.equal(
    hasBooleanAttribute(markup.match(/<textarea[^>]*>/)?.[0] ?? "", "disabled"),
    false,
  );
  assert.doesNotMatch(tag(markup, "composer-send") ?? "", /disabled/);
});

test("an expired workspace grant preserves editable text and exposes recovery", () => {
  const markup = render({
    draft: { kind: "text", text: "Keep this draft" },
    accessRequired: true,
    workspaceMissing: false,
    workspaceLabel: "/repo/alpha",
    workspaceTitle: "/repo/alpha",
  });
  assert.match(markup, />Keep this draft</);
  assert.match(markup, />Confirm access</);
  assert.equal(
    hasBooleanAttribute(markup.match(/<textarea[^>]*>/)?.[0] ?? "", "disabled"),
    false,
  );
  assert.match(tag(markup, "composer-send") ?? "", /disabled/);
});

test("Composer is one input shell with lightweight Workspace context below", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  assert.match(css, /\.composer textarea \{[\s\S]*?resize: none;/);
  assert.match(css, /max-height: min\(180px, 28vh\)/);
  assert.match(css, /\.composer \{[\s\S]*?border-radius: 18px;/);
  assert.match(css, /\.composer-send \{[\s\S]*?border-radius: 50%;/);
  const composerBarRule = css.slice(
    css.indexOf(".composer-bar {"),
    css.indexOf("\n}", css.indexOf(".composer-bar {")),
  );
  assert.doesNotMatch(composerBarRule, /border(?:-top)?:/);
  const workspaceContextRule = css.slice(
    css.indexOf(".composer-workspace-context {"),
    css.indexOf("\n}", css.indexOf(".composer-workspace-context {")),
  );
  assert.doesNotMatch(workspaceContextRule, /border:/);
  assert.doesNotMatch(workspaceContextRule, /background:/);
  const markup = render();
  const composerStart = markup.indexOf('class="composer"');
  const workspaceContext = markup.indexOf('class="composer-workspace-context"');
  assert.ok(composerStart >= 0 && workspaceContext > composerStart);
  assert.ok(
    markup.indexOf(
      'class="selection-trigger focus-ring composer-model-trigger',
      composerStart,
    ) < workspaceContext,
  );
});

test("only non-composable Task states disable the Composer", () => {
  const markup = render({
    archived: true,
    composeDisabled: true,
    modelLabel: null,
  });
  assert.match(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
  assert.match(markup, /Restore this task to continue/);
  assert.doesNotMatch(markup, />Claude Sonnet 4</);
});

test("a poisoned Task explains why continuation is unavailable", () => {
  const markup = render({
    unavailable: true,
    composeDisabled: true,
  });
  assert.match(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
  assert.match(markup, /End this task and start a new one to continue/);
});

test("a restart-detached Task keeps the Composer ready for send-time recovery", () => {
  const markup = render({
    unavailable: true,
    unavailableReason: "session_recovery_required",
    recoveryAvailable: true,
    composeDisabled: false,
  });
  assert.equal(
    hasBooleanAttribute(markup.match(/<textarea[^>]*>/)?.[0] ?? "", "disabled"),
    false,
  );
  assert.match(
    markup,
    /Type a message; the conversation will restore when you send/,
  );
  assert.match(markup, />Restore conversation</);
  assert.doesNotMatch(markup, /start a new one to continue/);
});

test("terminal state takes precedence over archive state in Composer guidance", () => {
  assert.match(
    render({
      archived: true,
      closing: true,
      composeDisabled: true,
    }),
    /This task is ending/,
  );
  assert.match(
    render({
      archived: true,
      closed: true,
      composeDisabled: true,
    }),
    /This task has ended/,
  );
});

test("Task list shows tasks from different workspaces without workspace controls", () => {
  const task = (id, title, workspaceId, recentOrder) => ({
    id,
    title,
    workspaceId,
    lifecycle: "open",
    continuationAvailable: true,
    archived: false,
    closeFailed: false,
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    recentOrder,
    lastRunOutcome: null,
    cause: null,
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
  });
  const markup = renderTaskList([
    task("1", "Alpha task", "workspace-a", "2"),
    task("2", "Beta task", "workspace-b", "1"),
  ]);

  assert.match(markup, /Alpha task/);
  assert.match(markup, /Beta task/);
  assert.doesNotMatch(markup, /workspace-card|workspace-picker|>Add</);
});

test("Task list disambiguates duplicate titles with their own paths", () => {
  const task = (id, workspaceId) => ({
    id,
    title: "Review changes",
    workspaceId,
    lifecycle: "open",
    continuationAvailable: true,
    archived: false,
    closeFailed: false,
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    recentOrder: id,
    lastRunOutcome: null,
    cause: null,
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
  });
  const markup = renderTaskList(
    [task("2", "workspace-a"), task("1", "workspace-b")],
    [
      {
        id: "workspace-a",
        kind: "manual",
        canonicalRoot: "/repo/alpha",
      },
      {
        id: "workspace-b",
        kind: "manual",
        canonicalRoot: "/repo/beta",
      },
    ],
  );

  assert.match(markup, /\/repo\/alpha/);
  assert.match(markup, /\/repo\/beta/);
});

test("global shortcuts obey Account and Bridge gates", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  assert.match(
    source,
    /if \(accountGateRequired \|\| bridgeUnavailable\) return;[\s\S]*setSearchOpen\(true\)[\s\S]*beginNewTask\(\)/,
  );
});

test("Task deletion confirmation handles Escape and restores its opener", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  const confirmation = source.slice(
    source.indexOf("<AlertDialog.Root"),
    source.indexOf("{viewSyncFailed &&"),
  );
  assert.match(confirmation, /open=\{confirmDelete\}/);
  assert.match(confirmation, /<AlertDialog\.Popup>/);
  assert.match(
    confirmation,
    /onOpenChange=\{\(open\) => !open && closeDeleteConfirmation\(\)\}/,
  );
});

test("draft moves read authoritative storage instead of a render-time closure", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/features/composer/useTaskDrafts.ts"),
    "utf8",
  );
  assert.match(source, /const source = readDraft\(from\)/);
  assert.match(source, /const target = readDraft\(to\)/);
  assert.doesNotMatch(source, /drafts\[from\]|drafts\[to\]/);
});
