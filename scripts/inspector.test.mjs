import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

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

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { TaskInspector } = await vite.ssrLoadModule(
  "/src/features/inspector/TaskInspector.tsx",
);
const { ApprovalPanel } = await vite.ssrLoadModule(
  "/src/features/approvals/ApprovalPanel.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => vite.close());

function run(overrides = {}) {
  return {
    id: "9",
    phase: "completed",
    input: {
      kind: "text",
      text: "Inspect the release",
      redacted: false,
    },
    assistant: "Release is ready",
    assistantRedacted: false,
    status: "Completed",
    outcome: "completed",
    cause: null,
    usage: { input: "12", output: "5", cacheRead: "0", cacheCreation: "0" },
    tools: [],
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

function renderInspector(value) {
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
      createElement(TaskInspector, {
        task: value,
        focusRequest: null,
        onClose() {},
        onFocusPending() {},
      }),
    ),
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

test("Inspector shows latest canonical run facts without copying raw output", () => {
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
          status: "INTERNAL_PROVIDER_RETRY",
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
    }),
  );
  assert.match(markup, />Inspector</);
  assert.match(markup, />Last run</);
  assert.match(markup, />17</);
  assert.match(markup, />Bash</);
  assert.doesNotMatch(
    markup,
    /1,000|private raw output|private input|INTERNAL_PROVIDER_RETRY/,
  );
  assert.doesNotMatch(markup, />Plan<|>Outputs<|>Files changed</);
});

test("approval cards never expose internal Run identity", () => {
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
  assert.match(markup, />Response required</);
  assert.match(markup, /class="ai-tool-field-label">Arguments<\/p>/);
  assert.match(markup, /class="code-block-preview"/);
  assert.doesNotMatch(markup, /8472|work item/i);
});

test("question controls keep their projected question as an accessible label", () => {
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
          requestId: "request-question",
          runId: "9",
          order: "1",
          redacted: false,
          kind: "ask_question",
          questions: [
            {
              header: "Continue",
              question: "Continue the run?",
              multi: false,
              options: [],
            },
          ],
        },
        busy: false,
        responsePhase: "idle",
        respond() {},
      }),
    ),
  );
  assert.match(markup, /id="ui-question-request-question-0"/);
  assert.match(markup, /aria-labelledby="ui-question-request-question-0"/);
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

test("Inspector has one controlled panel and the central narrative is not chat", async () => {
  const [app, shell, surface, css] = await Promise.all([
    readFile(join(process.cwd(), "frontend/src/app/App.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/app/AppShell.tsx"), "utf8"),
    readFile(
      join(
        process.cwd(),
        "frontend/src/features/agent-surface/AgentWorkSurface.tsx",
      ),
      "utf8",
    ),
    readFile(join(process.cwd(), "frontend/src/index.css"), "utf8"),
  ]);
  assert.match(app, /aria-controls="task-inspector"/);
  assert.match(app, /aria-expanded=\{inspector\.open\}/);
  assert.match(app, /inspectorOpener\.current = opener/);
  assert.match(app, /panel\?\.contains\(document\.activeElement\)/);
  assert.match(app, /inspectorFocusReturnTarget/);
  assert.match(shell, /id="task-inspector"/);
  assert.doesNotMatch(shell, /rightPreference|setRightOpen|aria-modal/);
  assert.doesNotMatch(surface, /run\.label|Work item/);
  const userMessageRule = css.match(
    /\.ai-message\.agent-user-message\s*\{([^}]*)\}/,
  )?.[1];
  assert.ok(userMessageRule);
  assert.match(userMessageRule, /width:\s*fit-content/);
  assert.match(userMessageRule, /max-width:\s*min\(78%, 660px\)/);
  assert.match(userMessageRule, /margin-left:\s*auto/);
  assert.match(userMessageRule, /border-radius:\s*14px 14px 4px 14px/);
  assert.doesNotMatch(surface, /message\.(?:you|agent)/);
  assert.doesNotMatch(surface, /message-role/);
  const runOutcomeRule = css.match(/\.agent-run-outcome\s*\{([^}]*)\}/)?.[1];
  assert.ok(runOutcomeRule);
  assert.match(runOutcomeRule, /border-top:\s*1px solid var\(--ui-border\)/);
  assert.doesNotMatch(runOutcomeRule, /border-radius|background:/);
  assert.match(
    css,
    /@media \(max-width: 560px\)[\s\S]*?\.ai-message\.agent-user-message\s*\{[^}]*max-width:\s*88%/,
  );
  assert.doesNotMatch(css, /\.ai-message\.agent-user-message::(?:before|after)/);
});

test("Inspector breakpoint changes presentation without creating a modal or second state owner", async () => {
  const [app, shell, css] = await Promise.all([
    readFile(join(process.cwd(), "frontend/src/app/App.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/app/AppShell.tsx"), "utf8"),
    readFile(join(process.cwd(), "frontend/src/index.css"), "utf8"),
  ]);
  assert.match(
    shell,
    /const effectiveInspectorOpen = inspectorAvailable && inspectorOpen/,
  );
  assert.match(shell, /aria-hidden=\{!effectiveInspectorOpen\}/);
  assert.match(shell, /inert=\{!effectiveInspectorOpen\}/);
  assert.match(shell, /onDismissInspector\(false\)/);
  assert.match(shell, /shouldDismissInspectorForEscape/);
  assert.match(shell, /role="dialog"/);
  assert.match(shell, /role="menu"/);
  assert.match(shell, /role="alertdialog"/);
  assert.doesNotMatch(shell, /setLeftOpen\(\(open\) =>/);
  assert.doesNotMatch(shell, /matchMedia\("\(max-width: 1100px\)"\)/);
  const inspectorAside = shell.match(
    /<aside\s+id="task-inspector"[\s\S]*?>/,
  )?.[0];
  assert.ok(inspectorAside);
  assert.doesNotMatch(inspectorAside, /aria-modal|role="dialog"/);
  assert.match(
    app,
    /if \(window\.innerWidth <= 1100\) dismissInspector\(false\)/,
  );
  assert.match(
    css,
    /@media \(max-width: 1100px\)[\s\S]*?--right-column: 0px;[\s\S]*?\.task-inspector \{[\s\S]*?position: fixed;/,
  );
  assert.doesNotMatch(css, /data-inspector-open="true"[^}]*panel-scrim/);
  assert.match(
    css,
    /@media \(prefers-reduced-motion: reduce\)[\s\S]*?transition-duration: 0\.01ms !important/,
  );
});
