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
const { primaryShortcutModifier } = await vite.ssrLoadModule(
  "/src/platform/keyboard.ts",
);
const { TaskTimeline } = await vite.ssrLoadModule(
  "/src/features/timeline/TaskTimeline.tsx",
);
const { WorkspaceNavigation } = await vite.ssrLoadModule(
  "/src/features/workspaces/WorkspaceNavigation.tsx",
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
  workspaceMissing: true,
  workspaceLabel: "No workspace",
  workspaceTitle: "No workspace",
  workspaceOptions: [],
  selectedWorkspaceId: "",
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
  onSlashCommand() {},
  onRefreshSkillCatalog() {},
  onConfirmAccess() {},
  onSelectWorkspace() {},
  onSelectModel() {},
};

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

function colorToken(css, name) {
  const match = css.match(
    new RegExp(`--color-${name}:\\s*(#[0-9a-f]{6})`, "i"),
  );
  assert.ok(match, `missing --color-${name}`);
  return match[1];
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

function renderShell(inspector, inspectorOpen = false, left = undefined) {
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
          workspaceLabel: "No workspace",
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
      createElement(TaskTimeline, {
        task,
        draft: false,
        draftHasWorkspace: true,
        revision: "1",
        composerHasDraft: false,
        retryAvailable: true,
        responseDisabled: false,
        onUseExample() {},
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

function renderNewTaskTimeline(composerHasDraft, draftComposer = null) {
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
      createElement(TaskTimeline, {
        task: null,
        draft: true,
        draftHasWorkspace: true,
        revision: "1",
        composerHasDraft,
        retryAvailable: true,
        responseDisabled: false,
        draftComposer,
        onUseExample() {},
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

function renderWorkspaceNavigation(
  lastRemovalFailure,
  authorization = "available",
  includeWorkspace = true,
  disabled = false,
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
      createElement(WorkspaceNavigation, {
        summaries: includeWorkspace
          ? [
              {
                id: "1",
                canonicalRoot: "/repo/alpha",
                label: "alpha",
                authorization,
                lastRemovalFailure,
                taskCount: 0,
                running: 0,
                attention: 0,
                failed: 0,
              },
            ]
          : [],
        currentWorkspaceId: includeWorkspace ? "1" : null,
        tasks: [],
        activeTaskId: null,
        showArchived: false,
        disabled,
        onChooseWorkspace() {},
        onRemoveWorkspace() {},
        onRetryRemoval() {},
        onSelectWorkspace() {},
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
  assert.match(markup, />Select a workspace</);
  assert.match(markup, /composer-workspace-context/);
  assert.doesNotMatch(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
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
  assert.match(
    markup,
    /role="combobox"[^>]*disabled=""[^>]*data-placeholder=""[^>]*aria-busy="true"/,
  );
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

test("desktop shortcut labels follow the host platform", () => {
  assert.equal(primaryShortcutModifier("Win32"), "Ctrl+");
  assert.equal(primaryShortcutModifier("MacIntel"), "⌘");
  assert.ok(
    renderShell(null).includes(`<kbd>${primaryShortcutModifier()}K</kbd>`),
  );
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
  assert.match(source, /\(!newTaskDraftActive \|\| composerWorkspaceReady\)/);
});

test("Workspace selection is not hidden inside submit", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/app/App.tsx"),
    "utf8",
  );
  const start = source.indexOf("async function submitRun()");
  const end = source.indexOf("\n  async function", start + 1);
  const submitRun = source.slice(start, end);
  assert.match(
    submitRun,
    /if \(!composerWorkspace \|\| !composerWorkspaceId\) return/,
  );
  assert.doesNotMatch(submitRun, /chooseWorkspace|client\.chooseWorkspace/);
});

test("New task does not render or reserve an empty Inspector", () => {
  const markup = renderShell(null);
  assert.doesNotMatch(markup, /id="task-inspector"/);
  assert.doesNotMatch(markup, /aria-controls="task-inspector"/);
  assert.match(markup, /data-inspector-open="false"/);
});

test("Settings uses the global stage without retaining Task navigation", () => {
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
      join(process.cwd(), "frontend/src/features/timeline/TaskTimeline.tsx"),
      "utf8",
    ),
    readFile(
      join(process.cwd(), "frontend/src/features/approvals/ApprovalPanel.tsx"),
      "utf8",
    ),
  ]);
  assert.equal(markup.match(/class="tool-card"/g)?.length, 1);
  assert.match(markup, /class="tool-card" data-state="completed"/);
  assert.match(css, /\.code-block-preview\s*\{[\s\S]*?max-height:\s*240px/);
  assert.match(timeline, /key=\{`tool:\$\{activity\.value\.id\}`\}/);
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

test("task examples disappear before they can overwrite an existing draft", () => {
  assert.match(renderNewTaskTimeline(false), /Review this project/);
  assert.doesNotMatch(renderNewTaskTimeline(true), /Review this project/);
});

test("new Task places the Composer between the outcome prompt and examples", () => {
  const markup = renderNewTaskTimeline(
    false,
    createElement("footer", { "data-test": "draft-composer" }, "Composer"),
  );
  const prompt = markup.indexOf("Start with the outcome");
  const composer = markup.indexOf('data-test="draft-composer"');
  const example = markup.indexOf("Review this project");
  assert.ok(prompt >= 0 && composer > prompt && example > composer);
});

test("Workbench foundation uses the purple system and centered new Task stage", async () => {
  const [app, shell, css] = await Promise.all([
    readFile(join(process.cwd(), "frontend/src/app/App.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/app/AppShell.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/index.css"), "utf8"),
  ]);
  assert.match(css, /--color-brand-600:\s*#5b46d8/);
  assert.match(css, /--left-column:\s*248px/);
  assert.match(
    css,
    /\.task-empty-state\.is-new-task\s*\{[\s\S]*?align-content:\s*center/,
  );
  assert.doesNotMatch(css, /color-cobalt|settings-teal|35,\s*109,\s*100/);
  assert.match(
    app,
    /draftComposer=\{newTaskDraftActive \? composerFooter : null\}/,
  );
  assert.match(
    app,
    /!newTaskDraftActive && \(\s*<header className="task-header">/,
  );
  assert.ok(
    shell.indexOf("commandbar-workspace") < shell.indexOf("commandbar-task"),
  );
});

test("Workbench semantic text colors meet WCAG AA contrast", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const canvas = colorToken(css, "canvas");
  const pairs = [
    [colorToken(css, "graphite"), canvas],
    [colorToken(css, "muted"), canvas],
    [colorToken(css, "brand-700"), canvas],
    [canvas, colorToken(css, "brand-600")],
    [colorToken(css, "amber-ink"), "#fff5e7"],
    [colorToken(css, "danger"), canvas],
    [colorToken(css, "live"), canvas],
    [colorToken(css, "amber"), canvas],
  ];
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
        label: "alpha",
        canonicalRoot: "/repo/alpha",
        authorization: "available",
      },
    ],
    selectedWorkspaceId: "1",
  });
  assert.match(markup, /<textarea/);
  assert.match(markup, />Ship the release</);
  assert.doesNotMatch(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
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
  assert.doesNotMatch(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
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

test("Workspace removal failure survives refresh with an honest retry surface", () => {
  const failed = renderWorkspaceNavigation("task_close_failed");
  assert.match(failed, /Some tasks may have stopped/);
  assert.match(failed, />Retry removal</);
  assert.doesNotMatch(renderWorkspaceNavigation(null), /Retry removal/);
});

test("Workspace removal state remains explicit without owning the global New task action", () => {
  const available = renderWorkspaceNavigation(null);
  assert.match(available, />Remove</);
  assert.doesNotMatch(available, /Removal in progress/);

  const removing = renderWorkspaceNavigation(null, "removing");
  assert.match(removing, /Removing this workspace/);
  assert.match(removing, /can’t start or continue tasks/);
  assert.doesNotMatch(removing, />New task</);
});

test("Workspace busy state disables real Workspace actions instead of swallowing clicks", async () => {
  const busy = renderWorkspaceNavigation(null, "available", true, true);
  assert.match(tag(busy, "workspace-picker") ?? "", /disabled/);

  const source = await readFile(
    join(
      process.cwd(),
      "frontend/src/features/workspaces/WorkspaceNavigation.tsx",
    ),
    "utf8",
  );
  assert.match(source, /disabled: workspace\.authorization === "removing"/);
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
    source.indexOf('className="delete-confirmation"'),
    source.indexOf("{viewSyncFailed &&"),
  );
  assert.match(confirmation, /role="alertdialog"/);
  assert.match(confirmation, /event\.key !== "Escape"/);
  assert.match(confirmation, /closeDeleteConfirmation\(\)/);
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

test("removing the final empty Workspace leaves a stable focus destination", () => {
  const empty = renderWorkspaceNavigation(null, "available", false);
  assert.match(
    empty,
    /class="workspace-section-heading focus-ring" tabindex="-1" aria-label="Workspace"/,
  );
  const picker = empty.match(
    /<button[^>]*class="[^"]*workspace-picker[^"]*"[^>]*>/,
  )?.[0];
  assert.match(picker ?? "", /disabled/);
  const add = empty.match(
    /<button[^>]*class="text-button focus-ring"[^>]*>Add/,
  );
  assert.ok(add);
  assert.doesNotMatch(empty, />Remove</);
});
