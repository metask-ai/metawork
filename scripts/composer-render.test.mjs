import assert from "node:assert/strict";
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
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => {
  await vite.close();
});

const base = {
  textareaRef: { current: null },
  hasTask: false,
  draft: false,
  archived: false,
  closed: false,
  prompt: "",
  composeDisabled: false,
  canSubmit: false,
  runInFlight: false,
  accessRequired: false,
  actionDisabled: false,
  onStart() {},
  onPromptChange() {},
  onSubmit() {},
  onConfirmAccess() {},
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

function tag(markup, className) {
  return markup.match(
    new RegExp(`<(?:button|textarea)[^>]*class="[^"]*${className}[^"]*"[^>]*>`),
  )?.[0];
}

test("cold start presents a clear enabled action instead of a fake disabled Composer", () => {
  const markup = render();
  assert.match(markup, />Start a new task</);
  assert.doesNotMatch(markup, /<textarea/);
  assert.doesNotMatch(tag(markup, "composer-start") ?? "", /disabled/);
});

test("a new Task draft is editable before its first send", () => {
  const markup = render({
    draft: true,
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
    draft: true,
    prompt: "Keep this draft",
    accessRequired: true,
  });
  assert.match(markup, />Keep this draft</);
  assert.match(markup, />Confirm access</);
  assert.doesNotMatch(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
  assert.match(tag(markup, "composer-send") ?? "", /disabled/);
});

test("only non-composable Task states disable the Composer", () => {
  const markup = render({
    hasTask: true,
    archived: true,
    composeDisabled: true,
  });
  assert.match(markup.match(/<textarea[^>]*>/)?.[0] ?? "", /disabled/);
  assert.match(markup, /Restore this task to continue/);
});
