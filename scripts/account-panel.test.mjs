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
const { AccountPanel } = await vite.ssrLoadModule(
  "/src/features/account/AccountPanel.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => vite.close());

const signedOut = {
  sessionState: "signed_out",
  executionState: "none",
  operation: "none",
  accountId: "",
  displayName: "",
  apiKeys: [],
  models: [],
  selectedApiKeyId: "",
  selectedModel: "",
  canCreateTask: false,
  errorCode: "none",
  safeDiagnostic: "",
  catalogGeneration: "0",
  executionGeneration: "0",
};

function render(account, compact = false) {
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
      createElement(AccountPanel, {
        account,
        compact,
        disabled: false,
        onBeginLogin() {},
        onReauthenticate() {},
        onCancel() {},
        onRefresh() {},
        onSelectApiKey() {},
        onSelectModel() {},
        onLogout() {},
      }),
    ),
  );
}

test("signed-out Account exposes one concrete Metask login action", () => {
  const markup = render(signedOut);
  assert.match(markup, />Sign in with Metask</);
  assert.doesNotMatch(markup, /<select/);
});

test("authorization progress is visible and cancellable", () => {
  const markup = render({
    ...signedOut,
    sessionState: "authorizing",
    operation: "oauth_callback",
  });
  assert.match(markup, />Waiting for Metask authorization</);
  assert.match(markup, />Cancel current action</);
});

test("authenticated Account exposes bounded Key and model choices", () => {
  const markup = render({
    ...signedOut,
    sessionState: "authenticated",
    accountId: "account-1",
    displayName: "Metask User",
    apiKeys: [{ id: "key-1", name: "Primary", suffix: "1234" }],
    models: [{ id: "model-1", displayName: "Model One" }],
  });
  assert.match(markup, />Primary · 1234</);
  assert.match(markup, />Model One</);
  assert.equal(
    (markup.match(/<select class="focus-ring" disabled="">/g) ?? []).length,
    2,
  );
  assert.match(markup, /<option value="" selected="">Choose an API Key</);
  assert.match(markup, /<option value="" selected="">Choose a model</);
  assert.match(markup, />Refresh account options</);
  assert.match(markup, />Sign out and clear this Mac</);
});

test("catalog selectors follow the exact Host selection phase", () => {
  const selectingKey = render({
    ...signedOut,
    sessionState: "authenticated",
    operation: "selecting_key",
    accountId: "account-1",
    apiKeys: [{ id: "key-1", name: "Primary", suffix: "1234" }],
    models: [{ id: "model-1", displayName: "Model One" }],
  });
  assert.match(selectingKey, /<select class="focus-ring">/);
  assert.equal(
    (selectingKey.match(/<select class="focus-ring" disabled="">/g) ?? [])
      .length,
    1,
  );
  assert.match(selectingKey, />Cancel current action</);
  assert.doesNotMatch(selectingKey, />Refresh account options</);
  assert.doesNotMatch(selectingKey, />Sign out and clear this Mac</);

  const selectingModel = render({
    ...signedOut,
    sessionState: "authenticated",
    operation: "selecting_model",
    accountId: "account-1",
    apiKeys: [{ id: "key-1", name: "Primary", suffix: "1234" }],
    models: [{ id: "model-1", displayName: "Model One" }],
    selectedApiKeyId: "key-1",
  });
  assert.equal(
    (selectingModel.match(/<select class="focus-ring" disabled="">/g) ?? [])
      .length,
    1,
  );
  assert.match(
    selectingModel,
    /<select class="focus-ring"><option value="" selected="">Choose a model</,
  );
  assert.match(selectingModel, />Cancel current action</);
});

test("restart keeps committed execution labels without persisting catalogs", () => {
  const markup = render({
    ...signedOut,
    sessionState: "authenticated",
    executionState: "ready",
    accountId: "account-1",
    displayName: "Metask User",
    selectedApiKeyId: "445",
    selectedModel: "gpt-5.5",
    canCreateTask: true,
    executionGeneration: "7",
  });
  assert.match(markup, />Saved API Key</);
  assert.match(markup, />gpt-5.5</);
  assert.match(markup, />Ready</);
});

test("logout progress and user cancellation are reported truthfully", () => {
  const loggingOut = render({
    ...signedOut,
    sessionState: "authenticated",
    operation: "logging_out",
    accountId: "account-1",
    displayName: "Metask User",
  });
  assert.match(loggingOut, /Signing out and clearing this Mac/);
  assert.doesNotMatch(loggingOut, />Cancel current action</);

  const cancelled = render({
    ...signedOut,
    errorCode: "user_cancelled",
  });
  assert.match(cancelled, /The account action was cancelled/);
  assert.doesNotMatch(cancelled, /Account action needs attention/);
});

test("reauth and restart states expose their actual recovery boundary", () => {
  const reauth = render({
    ...signedOut,
    sessionState: "reauth_required",
    accountId: "account-1",
    displayName: "Metask User",
    apiKeys: [{ id: "key-1", name: "Primary", suffix: "1234" }],
    models: [{ id: "model-1", displayName: "Model One" }],
  });
  assert.match(reauth, />Sign in again</);
  assert.match(reauth, /<select class="focus-ring" disabled="">/);
  assert.doesNotMatch(reauth, />Refresh account options</);

  const restart = render({
    ...signedOut,
    sessionState: "shutting_down",
    errorCode: "recovery_state_invalid",
  });
  assert.match(restart, /Close and reopen MetaWork/);
  assert.doesNotMatch(restart, />Sign in with Metask</);
});
