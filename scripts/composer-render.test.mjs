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
  prompt: "",
  composeDisabled: false,
  canSubmit: false,
  runInFlight: false,
  accessRequired: false,
  workspaceMissing: true,
  workspaceLabel: "No workspace",
  workspaceTitle: "No workspace",
  modelLabel: "Claude Sonnet 4",
  modelOptions: [
    { selectionId: "claude-sonnet-4", displayName: "Claude Sonnet 4" },
  ],
  selectedModelId: "claude-sonnet-4",
  modelEditable: true,
  modelSelectionDisabled: false,
  modelContextTitle: "Default model",
  actionDisabled: false,
  onPromptChange() {},
  onSubmit() {},
  onConfirmAccess() {},
  onSelectModel() {},
  onOpenModelSettings() {},
};

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

function renderShell(activity) {
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
          left: createElement("p", null, "Navigation"),
          activity,
        },
        createElement("p", null, "Composer stage"),
      ),
    ),
  );
}

function renderNewTaskTimeline(composerHasDraft) {
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
        onUseExample() {},
        onPrepareRetry() {},
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
        disabled: false,
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
  assert.match(markup, />Choose on send</);
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
  });
  assert.match(markup, /<option value="" selected="">Choose a model<\/option>/);
  assert.match(markup, /<select[^>]*disabled=""/);
  assert.doesNotMatch(markup, /value="candidate-model" selected=""/);
});

test("desktop shortcut labels follow the host platform", () => {
  assert.equal(primaryShortcutModifier("Win32"), "Ctrl+");
  assert.equal(primaryShortcutModifier("MacIntel"), "⌘");
  assert.match(renderShell(null), /<kbd>Ctrl\+K<\/kbd>/);
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
});

test("New task does not render or reserve an empty activity panel", () => {
  const markup = renderShell(null);
  assert.doesNotMatch(markup, /id="task-activity"/);
  assert.doesNotMatch(markup, /aria-controls="task-activity"/);
  assert.match(markup, /data-right-open="false"/);
});

test("task examples disappear before they can overwrite an existing draft", () => {
  assert.match(renderNewTaskTimeline(false), /Review this project/);
  assert.doesNotMatch(renderNewTaskTimeline(true), /Review this project/);
});

test("a new Task draft is editable before its first send", () => {
  const markup = render({
    prompt: "Ship the release",
    canSubmit: true,
  });
  assert.match(markup, /<textarea/);
  assert.match(markup, />Ship the release</);
  assert.doesNotMatch(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
  assert.doesNotMatch(tag(markup, "composer-send") ?? "", /disabled/);
});

test("an expired workspace grant preserves editable text and exposes recovery", () => {
  const markup = render({
    prompt: "Keep this draft",
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
});
