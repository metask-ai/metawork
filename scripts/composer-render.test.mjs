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
const { AppShell, resolveWorkbenchColumns } = await vite.ssrLoadModule(
  "/src/app/AppShell.tsx",
);
const { TaskContent } = await vite.ssrLoadModule(
  "/src/features/tasks/TaskContent.tsx",
);
const { NewTaskView, NewTaskApprovalModeMenu } = await vite.ssrLoadModule(
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
  unavailable: false,
  unavailableReason: null,
  draft: { kind: "text", text: "" },
  attachmentsEnabled: false,
  attachmentMaxFileBytes: "3750000",
  attachmentBusy: false,
  attachmentError: null,
  attachmentModelWarning: null,
  skillCatalog: {
    availability: "ready",
    redacted: false,
    revision: "4",
    selectionRevision: "1",
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
  defaultSelectionMissing: false,
  defaultRecoveryDisabled: false,
  actionDisabled: false,
  stopAction: null,
  stopDisabled: false,
  onDraftChange() {},
  onChooseAttachments() {},
  onRemoveAttachment() {},
  onSubmit() {},
  onStop() {},
  onSlashCommand() {},
  onRefreshSkillCatalog() {},
  onConfirmAccess() {},
  onSelectWorkspace() {},
  onSelectModel() {},
  onOpenModels() {},
};

test("detached Conversation recovery stays invisible until normal send", () => {
  const required = render({
    unavailable: true,
    unavailableReason: "session_recovery_required",
    draft: { kind: "text", text: "Continue" },
    canSubmit: true,
  });
  assert.doesNotMatch(required, /conversation-recovery/);
  assert.doesNotMatch(required, /Restore conversation/);
  assert.match(required, /placeholder="Describe the outcome you need…"/);
  assert.match(required, /aria-label="Send"/);

  const restoring = render({
    unavailable: true,
    unavailableReason: "session_recovery_in_progress",
    composeDisabled: true,
  });
  assert.doesNotMatch(restoring, /Restoring conversation/);
  assert.match(restoring.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
  assert.match(restoring, /placeholder="Describe the outcome you need…"/);

  const failed = render({
    unavailable: true,
    unavailableReason: "session_recovery_failed",
    draft: { kind: "text", text: "Retry without a recovery control" },
    canSubmit: true,
  });
  assert.doesNotMatch(failed, /Try again|Restore conversation/);
  assert.match(failed, /placeholder="Describe the outcome you need…"/);
  assert.match(failed, /aria-label="Send"/);
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
  rightPanel,
  rightPanelOpen = false,
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
          rightPanel,
          rightPanelOpen,
          onToggleRightPanel() {},
          onDismissRightPanel() {},
        },
        createElement("p", null, "Composer stage"),
      ),
    ),
  );
}

function renderCompletedSurface(
  assistant = "Release is ready",
  input = {
    kind: "text",
    text: "Inspect the release",
    redacted: false,
  },
  compacts = [],
  { pendingUi = null, uiHistory = [], conversationCoverage = "included" } = {},
) {
  const task = {
    id: "3",
    runs: [
      {
        id: "9",
        conversationCoverage,
        phase: pendingUi ? "waiting_ui" : "completed",
        execution: {
          generation: "1",
          protocol: "anthropic_messages",
          model: "fixture-model",
        },
        input,
        output: {
          commentary: [],
          response: assistant,
          responseKind: assistant ? "final" : null,
          provisional: "",
          redacted: false,
          provisionalRedacted: false,
        },
        activity: pendingUi ? { kind: "waiting_user" } : null,
        submittedAtUnixMs: null,
        finishedAtUnixMs: null,
        terminal: pendingUi
          ? null
          : {
              outcome: "completed",
              cause: null,
              diagnosticDisposition: "absent",
            },
        usage: { input: "12", output: "5", cacheRead: "0", cacheCreation: "0" },
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
            fileRefs: [],
          },
        ],
      },
    ],
    compacts,
    pendingUi,
    uiHistory,
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
      createElement(TaskContent, {
        task,
        revision: "1",
        composerHasDraft: false,
        retryAvailable: true,
        responseDisabled: false,
        fileChangesEnabled: false,
        onPrepareRetry() {},
        onPreviewFile() {},
        onReviewFileChanges() {},
        onRespond() {},
        renderPendingUi() {
          return createElement("div", null, "Pending decision");
        },
      }),
    ),
  );
}

function renderNewTaskView(composer = null, overrides = {}) {
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
        composer:
          composer ??
          createElement(ComposerFooter, {
            ...base,
            approvalModeControl: createElement(NewTaskApprovalModeMenu, {
              approvalModes: [],
              approvalMode: "manual",
              disabled: false,
              onApprovalModeChange() {},
              ...overrides,
            }),
          }),
      }),
    ),
  );
}

test("terminal responses expose response and code copy without copying process UI", () => {
  const markup = renderCompletedSurface(
    "Answer\n\n```ts\nconst answer = 42;\n```",
  );
  assert.match(markup, /data-latest="true"/);
  assert.match(markup, /aria-label="Copy input"/);
  assert.match(markup, /aria-label="Copy response"/);
  assert.match(markup, /aria-label="Copy code"/);
  assert.equal((markup.match(/class="sr-only"/g) ?? []).length, 3);
  assert.equal((markup.match(/data-copy-state="idle"/g) ?? []).length, 3);
});

function renderTaskList(tasks, props = {}) {
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
        workspaces: [],
        activeTaskId: null,
        showArchived: false,
        onSelectTask() {},
        onToggleArchived() {},
        ...props,
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

test("a closed empty side panel reserves no space but keeps its layout toggle", () => {
  const markup = renderShell(null);
  assert.match(markup, /id="task-panel"/);
  assert.match(markup, /aria-hidden="true"/);
  assert.match(markup, /aria-controls="task-panel"/);
  assert.match(markup, /aria-label="Open side panel"/);
  const openEmpty = renderShell(null, true);
  assert.match(openEmpty, /id="task-panel"/);
  assert.match(openEmpty, /data-right-panel-open="true"/);
  assert.match(openEmpty, /aria-label="Hide side panel"/);
  assert.match(markup, /data-right-panel-open="false"/);
});

test("a closed Task Panel keeps its shell but unmounts its content", () => {
  const closed = renderShell(createElement("p", null, "Private panel body"));
  assert.match(closed, /id="task-panel"/);
  assert.match(closed, /aria-hidden="true"/);
  assert.doesNotMatch(closed, /Private panel body/);

  const open = renderShell(
    createElement("p", null, "Private panel body"),
    true,
  );
  assert.match(open, /aria-hidden="false"/);
  assert.match(open, /Private panel body/);
  assert.match(open, /aria-label="Resize side panel"/);
});

test("bounded proportional columns preserve both docked minimums", () => {
  const resolve = (viewportWidth, leftOpen, leftWidth = 320) =>
    resolveWorkbenchColumns({
      containerWidth: viewportWidth,
      leftOpen,
      leftWidth,
      rightOpen: true,
      rightShare: 1 / 3,
    });

  assert.deepEqual(resolve(1440, true), {
    availableWidth: 1120,
    docked: true,
    middleWidth: 746,
    rightWidth: 374,
    rightMinimum: 360,
    rightMaximum: 760,
    rightShare: 1 / 3,
  });
  assert.deepEqual(resolve(1200, true), {
    availableWidth: 880,
    docked: true,
    middleWidth: 520,
    rightWidth: 360,
    rightMinimum: 360,
    rightMaximum: 520,
    rightShare: 1 / 3,
  });
  assert.deepEqual(
    {
      docked: resolve(1200, true, 480).docked,
      middleWidth: resolve(1200, true, 480).middleWidth,
      rightWidth: resolve(1200, true, 480).rightWidth,
    },
    { docked: true, middleWidth: 360, rightWidth: 360 },
  );
  assert.deepEqual(
    {
      docked: resolve(960, false).docked,
      middleWidth: resolve(960, false).middleWidth,
      rightWidth: resolve(960, false).rightWidth,
    },
    { docked: true, middleWidth: 600, rightWidth: 360 },
  );
  assert.equal(resolve(960, true).docked, false);

  const ultrawide = resolve(2560, true);
  assert.equal(ultrawide.docked, true);
  assert.equal(ultrawide.rightWidth, 747);
  assert.equal(ultrawide.middleWidth, 1493);
});

test("Settings uses the global stage without retaining the Task sidebar", () => {
  const markup = renderShell(null, false, null);
  assert.doesNotMatch(markup, /id="workspace-sidebar"/);
  assert.doesNotMatch(markup, /aria-controls="workspace-sidebar"/);
  assert.match(markup, /data-left-open="false"/);
});

test("Assistant reply is primary and completed does not add a redundant outcome", () => {
  const markup = renderCompletedSurface();
  assert.match(markup, /class="ai-conversation"/);
  assert.match(markup, /class="ai-message" data-role="user"/);
  assert.match(
    markup,
    /class="ai-message run-assistant-output" data-role="assistant"/,
  );
  assert.match(markup, /Release is ready/);
  assert.doesNotMatch(markup, /Read|Work completed/);
  assert.match(renderCompletedSurface(""), /Work completed/);
});

test("pending UI follows the unified Assistant output without technical history", () => {
  const markup = renderCompletedSurface(
    "Review this before continuing",
    undefined,
    [],
    {
      uiHistory: [
        {
          requestId: "request-resolved",
          runId: "9",
          order: "2",
          kind: "permission",
          state: "allowed_once",
          agentRequestId: "agent-request-resolved",
          permission: null,
          detail: "allowed",
          itemCount: 1,
          detailTruncated: false,
          redacted: false,
        },
      ],
      pendingUi: {
        requestId: "request-pending",
        runId: "9",
        order: "3",
        redacted: false,
        kind: "permission",
        tool: "Bash",
        args: "npm test",
        availableChoices: ["deny_once", "allow_once"],
      },
    },
  );
  const assistant = markup.indexOf("Review this before continuing");
  const pending = markup.indexOf("Pending decision");
  assert.ok(assistant < pending);
  assert.match(markup, />Needs attention</);
  assert.doesNotMatch(markup, />Read</);
  assert.doesNotMatch(markup, /fixture\.txt|>ready<|Resolved decision/);
});

test("Task content keeps Tool and Run metadata out of the reading flow", () => {
  const markup = renderCompletedSurface();
  assert.match(markup, /Inspect the release/);
  assert.match(markup, /Release is ready/);
  assert.doesNotMatch(markup, /Read|fixture\.txt|tokens|runId/);
});

test("excluded conversation history is explained beside its owning Run", () => {
  const markup = renderCompletedSurface(
    "The interrupted response remains visible",
    undefined,
    [],
    { conversationCoverage: "excluded" },
  );
  const exchange = markup.indexOf('class="ai-exchange"');
  const input = markup.indexOf("Inspect the release", exchange);
  const notice = markup.indexOf(
    "This message remains in the task history, but is not included in the restored model context",
    exchange,
  );
  assert.ok(exchange >= 0 && input > exchange && notice > input);
  assert.equal(
    (markup.match(/run-conversation-coverage-notice/g) ?? []).length,
    1,
  );
  assert.doesNotMatch(markup.slice(0, exchange), /restored model context/);
});

test("Task content preserves typed Skill identity and positional arguments", () => {
  const markup = renderCompletedSurface("Review complete", {
    kind: "skill",
    skillId: "builtin.review",
    catalogRevision: "17",
    invocationName: "review",
    displayName: "Review",
    argumentValues: ["src/main.zig"],
    redacted: false,
  });
  assert.match(markup, /task-skill-token/);
  assert.match(markup, />\/review/);
  assert.match(markup, />src\/main\.zig</);
});

test("Task content renders multimodal history as metadata-only attachment chips", () => {
  const markup = renderCompletedSurface("Analysis complete", {
    kind: "multimodal",
    text: "Inspect these files",
    attachments: [
      {
        kind: "image",
        format: "png",
        displayName: "diagram.png",
        mediaType: "image/png",
        sizeBytes: "2048",
        redacted: false,
      },
      {
        kind: "image",
        format: "webp",
        displayName: "brief.webp",
        mediaType: "image/webp",
        sizeBytes: "4096",
        redacted: false,
      },
    ],
    redacted: false,
  });

  assert.match(markup, /task-input-attachments/);
  assert.match(markup, /diagram\.png/);
  assert.match(markup, /brief\.webp/);
  assert.match(markup, /2 KB/);
  assert.doesNotMatch(markup, /attachmentToken|token|file:\/\/|\/Users\//);
});

test("Task content marks redacted Text and Skill inputs consistently", () => {
  const text = renderCompletedSurface("Review complete", {
    kind: "text",
    text: "Inspect [redacted]",
    redacted: true,
  });
  const skill = renderCompletedSurface("Review complete", {
    kind: "skill",
    skillId: "builtin.review",
    catalogRevision: "8",
    invocationName: "review",
    displayName: "Review",
    argumentValues: ["[redacted]"],
    redacted: true,
  });

  assert.match(text, /Sensitive values were hidden/);
  assert.match(skill, /Sensitive values were hidden/);
});

test("Task content does not project manual Compact history", () => {
  const markup = renderCompletedSurface("Release is ready", undefined, [
    {
      operationId: "11",
      afterRunId: "9",
      conversationCoverage: "included",
      phase: "compacted",
      cause: null,
      beforeContextTokens: "100",
      afterContextTokens: "40",
      usage: { input: "5", output: "2", cacheRead: "0", cacheCreation: "0" },
    },
  ]);
  assert.doesNotMatch(
    markup,
    /conversation-compaction|Context compacted|100|40/,
  );
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

test("new Task keeps its approval choice inside the Composer toolbar without details", () => {
  for (const [mode, label] of [
    ["manual", "Manual approval"],
    ["auto_review", "Automatic approval"],
    ["full_access", "Direct execution"],
  ]) {
    const markup = renderNewTaskView(null, {
      approvalModes: ["manual", "auto_review", "full_access"],
      approvalMode: mode,
    });
    assert.match(markup, /aria-label="Approval mode"/);
    assert.ok(markup.includes(label));
    assert.ok(
      markup.indexOf('id="new-task-permission-profile"') >
        markup.indexOf('class="ai-composer-toolbar"'),
    );
    assert.doesNotMatch(
      markup,
      /new-task-permission"|permission-policy-boundary|Remembered across restarts|additional usage charges|AgentCore protections/,
    );
  }
});

test("approval surfaces keep a usable narrow mode selector and dark parameter contrast", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  assert.match(css, /\.task-approval-trigger\s*\{[^}]*min-height:\s*44px/);
  assert.match(
    css,
    /\.dark \.ai-intervention \.code-block-preview\s*\{[^}]*color:\s*var\(--ui-content-primary\);[^}]*background:\s*var\(--ui-surface-panel-2\)/,
  );
  assert.match(
    css,
    /\.ai-intervention button:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--ui-focus-ring\)/,
  );
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

test("an active run replaces the send action with stop in the Composer", () => {
  const markup = render({
    draft: { kind: "text", text: "Keep working" },
    stopAction: "run",
  });
  assert.match(markup, /aria-label="Stop task"/);
  assert.match(markup, /class="[^\"]*composer-stop/);
  assert.doesNotMatch(markup, /class="[^\"]*composer-send/);
});

test("an unavailable workspace preserves editable text and offers folder reselection", () => {
  const markup = render({
    draft: { kind: "text", text: "Keep this draft" },
    accessRequired: true,
    workspaceMissing: false,
    workspaceLabel: "/repo/alpha",
    workspaceTitle: "/repo/alpha",
  });
  assert.match(markup, />Keep this draft</);
  assert.match(markup, />Select folder again</);
  assert.equal(
    hasBooleanAttribute(markup.match(/<textarea[^>]*>/)?.[0] ?? "", "disabled"),
    false,
  );
  assert.match(tag(markup, "composer-send") ?? "", /disabled/);
});

test("Composer keeps Workspace context after its input controls", () => {
  const markup = render();
  const composerStart = markup.indexOf('class="ai-composer"');
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
  assert.match(
    markup,
    /This conversation cannot continue right now\. Check recovery status and try again/,
  );
  assert.doesNotMatch(markup, /End this task and start a new one/);
});

test("execution target incompatibility does not mislabel the Conversation as lost", () => {
  const markup = render({
    unavailable: true,
    unavailableReason: "execution_rebind_required",
    composeDisabled: true,
  });
  assert.match(
    markup,
    /The current execution cannot run this conversation\. Switch to an account or connection that supports the task model/,
  );
  assert.doesNotMatch(markup, /End this task and start a new one/);
});

test("a restart-detached Task keeps the Composer ready for send-time recovery", () => {
  const markup = render({
    unavailable: true,
    unavailableReason: "session_recovery_required",
    composeDisabled: false,
  });
  assert.equal(
    hasBooleanAttribute(markup.match(/<textarea[^>]*>/)?.[0] ?? "", "disabled"),
    false,
  );
  assert.match(markup, /Describe the outcome you need/);
  assert.doesNotMatch(markup, />Restore conversation</);
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
});

test("Task list shows tasks from different workspaces without workspace controls", () => {
  const task = (id, title, workspaceId, recentOrder) => ({
    id,
    title,
    workspaceId,
    lifecycle: "open",
    deletionStatus: "idle",
    continuationAvailable: true,
    archived: false,
    unreadCompletionRunId: null,
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    recentOrder,
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
  });
  const archived = task("3", "Archived task", "workspace-b", "3");
  archived.archived = true;
  const markup = renderTaskList(
    [
      task("1", "Alpha task", "workspace-a", "2"),
      task("2", "Beta task", "workspace-b", "1"),
      archived,
    ],
    { showArchived: true },
  );

  assert.match(markup, /Alpha task/);
  assert.match(markup, /Beta task/);
  assert.match(markup, /Archived task/);
  assert.match(markup, /aria-label="Archived"/);
  assert.doesNotMatch(markup, /<section|<h3/);
  assert.doesNotMatch(markup, /workspace-card|workspace-picker|>Add</);
});

test("Task list keeps duplicate titles free of workspace metadata", () => {
  const task = (id, workspaceId) => ({
    id,
    title: "Review changes",
    workspaceId,
    lifecycle: "open",
    deletionStatus: "idle",
    continuationAvailable: true,
    archived: false,
    unreadCompletionRunId: null,
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    recentOrder: id,
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
  });
  const markup = renderTaskList([
    task("2", "workspace-a"),
    task("1", "workspace-b"),
  ]);

  assert.equal((markup.match(/Review changes/g) ?? []).length, 2);
  assert.doesNotMatch(
    markup,
    /task-list-meta|\/repo\/alpha|\/repo\/beta|Default/,
  );
});

test("Manual projects repeat their tasks while automatic tasks stay global", () => {
  const task = (id, workspaceId, overrides = {}) => ({
    id,
    title: `Task ${id}`,
    workspaceId,
    archived: false,
    unreadCompletionRunId: null,
    currentRunPhase: null,
    activeOperation: null,
    recentOrder: id,
    runs: [],
    compacts: [],
    ...overrides,
  });
  const workspaces = [
    {
      id: "automatic",
      kind: "automatic",
      displayName: "Default",
      canonicalRoot: "/custom-default/random-task-directory",
      recentOrder: "0",
    },
    {
      id: "alpha",
      kind: "manual",
      displayName: "Same directory name",
      canonicalRoot: "/repo/alpha",
      recentOrder: "9007199254740993",
    },
    {
      id: "beta",
      kind: "manual",
      displayName: "Same directory name",
      canonicalRoot: "/repo/beta",
      recentOrder: "9007199254740994",
    },
    {
      id: "empty",
      kind: "manual",
      displayName: "Empty project",
      canonicalRoot: "/repo/empty",
      recentOrder: "1",
    },
  ];
  const tasks = [
    task("1", "automatic"),
    task("2", "alpha", {
      currentRunPhase: "waiting_ui",
      permissionReviewState: "needs_user",
    }),
    task("3", "alpha", { currentRunPhase: "running" }),
    task("4", "alpha"),
    task("5", "beta", { archived: true }),
    task("6", "alpha", { unreadCompletionRunId: "9" }),
  ];
  const markup = renderTaskList(tasks, {
    workspaces,
    activeTaskId: "2",
  });
  const projectsStart = markup.indexOf('class="task-projects"');
  const tasksStart = markup.indexOf('class="task-list-heading"');
  assert.ok(projectsStart < tasksStart, "Projects appear above global tasks");
  const projects = markup.slice(projectsStart, tasksStart);
  const alpha = projects.slice(
    projects.indexOf('data-workspace-id="alpha"'),
    projects.indexOf('data-workspace-id="empty"'),
  );
  assert.match(markup, />5 tasks</);
  assert.equal((markup.match(/data-task-id="1"/g) ?? []).length, 1);
  for (const id of ["2", "3", "4", "6"])
    assert.equal(
      (markup.match(new RegExp(`data-task-id="${id}"`, "g")) ?? []).length,
      2,
    );
  assert.doesNotMatch(
    markup,
    /data-task-id="5"|data-workspace-id="automatic"|custom-default/,
  );
  assert.deepEqual(
    [...alpha.matchAll(/data-task-id="([^"]+)"/g)].map((match) => match[1]),
    ["2", "3", "6", "4"],
  );
  assert.ok(
    projects.indexOf('data-workspace-id="beta"') <
      projects.indexOf('data-workspace-id="alpha"'),
  );
  assert.match(projects, /title="\/repo\/alpha"/);
  assert.match(projects, /title="\/repo\/beta"/);
  assert.match(projects, /Archived tasks are hidden/);
  assert.match(projects, /No tasks in this project yet/);
  assert.equal((markup.match(/aria-current="page"/g) ?? []).length, 2);
  assert.equal((markup.match(/aria-label="Attention"/g) ?? []).length, 2);
  assert.equal((markup.match(/task-notification-dot/g) ?? []).length, 2);

  const archived = renderTaskList(tasks, { workspaces, showArchived: true });
  assert.equal((archived.match(/data-task-id="5"/g) ?? []).length, 2);
  assert.match(archived, />6 tasks</);
  const suppressed = renderTaskList(tasks, {
    workspaces,
    suppressedCompletionTaskId: "6",
    synchronized: false,
  });
  assert.doesNotMatch(
    suppressed,
    /task-notification-dot|aria-label="Attention"|aria-label="Running"/,
  );
});

test("Redacted project paths do not appear in directory titles", () => {
  const markup = renderTaskList([], {
    workspaces: [
      {
        id: "1",
        kind: "manual",
        displayName: "Project",
        canonicalRoot: "/private/path",
        recentOrder: "1",
        redacted: true,
      },
    ],
  });
  assert.match(markup, /title="Project"/);
  assert.doesNotMatch(markup, /\/private\/path/);
});

test("Task list states how many saved Tasks this version kept unopened", () => {
  assert.doesNotMatch(renderTaskList([]), /can't open/);
  const markup = renderTaskList([], { retainedTaskCount: 2 });
  assert.match(
    markup,
    /Tasks this version can&#x27;t open: 2\. They are kept unchanged\./,
  );
});

test("Sidebar typography reserves bold weight for the product identity", async () => {
  const stylesheet = await readFile(
    new URL("../frontend/src/index.css", import.meta.url),
    "utf8",
  );
  assert.match(stylesheet, /\.sidebar-capability\s*\{[^}]*font-weight: 500/s);
  assert.doesNotMatch(stylesheet, /\.task-group/);
  assert.match(stylesheet, /\.section-label\s*\{[^}]*font-weight: 500/s);
  assert.match(
    stylesheet,
    /\.task-list-row > span:first-child\s*\{[^}]*font-weight: 400/s,
  );
  assert.match(
    stylesheet,
    /\.task-list-item\[aria-current="page"\] \.task-list-row > span:first-child\s*\{[^}]*font-weight: 500/s,
  );
  assert.match(
    stylesheet,
    /\.account-identity-copy strong\s*\{[^}]*font-weight: 500/s,
  );
});

test("Account identity and its menu stay compact without shrinking the hit target", async () => {
  const stylesheet = await readFile(
    new URL("../frontend/src/index.css", import.meta.url),
    "utf8",
  );

  assert.match(
    stylesheet,
    /\.account-identity\s*\{[^}]*padding: 4px 8px calc\(4px \+ env\(safe-area-inset-bottom, 0px\)\);/s,
  );
  assert.match(
    stylesheet,
    /\.account-identity-trigger\s*\{[^}]*min-height: 44px;/s,
  );
  assert.match(
    stylesheet,
    /\.account-menu\s*\{[^}]*width: min\(224px, calc\(100vw - 24px\)\);/s,
  );
});

test("Task list keeps compact row density without group-owned spacing", async () => {
  const stylesheet = await readFile(
    new URL("../frontend/src/index.css", import.meta.url),
    "utf8",
  );

  assert.match(
    stylesheet,
    /\.task-list-item\s*\{[^}]*margin-top: 1px;[^}]*padding: 6px 10px;/s,
  );
  assert.match(
    stylesheet,
    /\.task-list-heading \+ \.task-list-item\s*\{[^}]*margin-top: 6px;/s,
  );
  assert.match(
    stylesheet,
    /\.task-list-row > span:first-child\s*\{[^}]*line-height: 18px;/s,
  );
  assert.doesNotMatch(stylesheet, /\.task-group/);
});

test("Task completion dot consumes only the canonical unread receipt", () => {
  const completed = {
    id: "1",
    title: "Completed task",
    workspaceId: "workspace-a",
    lifecycle: "open",
    deletionStatus: "idle",
    continuationAvailable: true,
    archived: false,
    unreadCompletionRunId: "9",
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    recentOrder: "1",
    runs: [
      {
        id: "9",
        terminal: { outcome: "completed", cause: null },
      },
    ],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
  };

  assert.match(renderTaskList([completed]), /task-notification-dot/);
  assert.doesNotMatch(
    renderTaskList([completed], { suppressedCompletionTaskId: "1" }),
    /task-notification-dot/,
  );
  assert.doesNotMatch(
    renderTaskList([{ ...completed, unreadCompletionRunId: null }]),
    /task-notification-dot/,
  );
});

test("an active Run keeps the normal Send icon and shows no queue drafting prompt", () => {
  const markup = render({
    draft: { kind: "text", text: "follow up" },
    stopAction: "run",
    runInFlight: true,
    onQueueInput() {},
    canQueue: true,
  });
  assert.doesNotMatch(markup, /aria-label="Stop task"/);
  assert.match(markup, /aria-label="Send"/);
  assert.doesNotMatch(
    markup,
    /Queue message|Draft your next message|composer-draft-note/,
  );
  const stopping = render({
    draft: { kind: "text", text: "follow up" },
    stopAction: "run",
    stopDisabled: true,
    runInFlight: true,
    onQueueInput() {},
  });
  assert.doesNotMatch(stopping, /aria-label="Send"/);
  assert.match(
    stopping,
    /<button(?=[^>]*aria-label="Stop task")(?=[^>]*disabled)[^>]*>/,
  );
  const attachments = render({
    draft: {
      kind: "multimodal",
      text: "",
      attachments: [
        {
          token: "file",
          kind: "file",
          displayName: "notes.txt",
          sizeBytes: "1",
          redacted: false,
        },
      ],
    },
    stopAction: "run",
    onQueueInput() {},
    canQueue: false,
    queueDisabledReason: "queue.attachments_unsupported",
  });
  assert.match(
    attachments,
    /<button(?=[^>]*aria-label="Send")(?=[^>]*disabled)[^>]*>/,
  );
  assert.match(attachments, /Send messages with attachments manually/);
});
