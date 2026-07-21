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
const { AccountPrerequisite } = await vite.ssrLoadModule(
  "/src/features/account/AccountPrerequisite.tsx",
);
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
  readiness: "sign_in_required",
  primaryAction: "sign_in",
  canCancel: false,
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

const callbacks = {
  onBeginLogin() {},
  onReopenLogin() {},
  onReauthenticate() {},
  onCancel() {},
  onRetry() {},
  onRefresh() {},
  onSelectApiKey() {},
  onSelectModel() {},
  onLogout() {},
};

function withI18n(child) {
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
      child,
    ),
  );
}

function renderPrerequisite(account) {
  return withI18n(
    createElement(AccountPrerequisite, {
      account,
      disabled: false,
      ...callbacks,
    }),
  );
}

function renderPrerequisiteWith(account, props) {
  return withI18n(
    createElement(AccountPrerequisite, {
      account,
      disabled: false,
      ...callbacks,
      ...props,
    }),
  );
}

test("signed-out readiness stays beside the task draft with one primary action", () => {
  const markup = renderPrerequisite(signedOut);
  assert.match(markup, /Connect Metask to send/);
  assert.match(markup, /Keep writing your draft/);
  assert.match(markup, />Sign in with Metask</);
  assert.doesNotMatch(markup, /setup progress|Load API Keys|<select/);
});

test("authorization wait can reopen or cancel without exposing the OAuth URL", () => {
  const markup = renderPrerequisite({
    ...signedOut,
    sessionState: "authorizing",
    operation: "oauth_callback",
    readiness: "preparing",
    primaryAction: "reopen_login",
    canCancel: true,
  });
  assert.match(markup, /Waiting for Metask authorization/);
  assert.match(markup, />Open sign-in page again</);
  assert.match(markup, />Cancel current action</);
  assert.doesNotMatch(markup, /https?:\/\//);
});

test("background catalog preparation does not ask for a manual load step", () => {
  const markup = renderPrerequisite({
    ...signedOut,
    sessionState: "authenticated",
    operation: "loading_keys",
    readiness: "preparing",
    primaryAction: "none",
    canCancel: true,
    accountId: "account-1",
  });
  assert.match(markup, /Loading API Keys/);
  assert.match(markup, />Cancel current action</);
  assert.doesNotMatch(markup, /Load API Keys|Try again|<select/);
});

test("Account cancel stays available while an ordinary command is locally busy", () => {
  const markup = renderPrerequisiteWith(
    {
      ...signedOut,
      sessionState: "authorizing",
      operation: "oauth_callback",
      readiness: "preparing",
      primaryAction: "reopen_login",
      canCancel: true,
    },
    { disabled: true, cancelDisabled: false },
  );
  assert.match(markup, /<button[^>]*disabled=""[^>]*>Open sign-in page again</);
  assert.match(markup, /<button[^>]*>Cancel current action</);
});

test("only a real catalog ambiguity asks for the matching choice", () => {
  const keyChoice = renderPrerequisite({
    ...signedOut,
    sessionState: "authenticated",
    operation: "selecting_key",
    readiness: "choice_required",
    primaryAction: "choose_api_key",
    canCancel: true,
    accountId: "account-1",
    apiKeys: [
      { id: "key-1", name: "Primary", suffix: "1234" },
      { id: "key-2", name: "Backup", suffix: "5678" },
    ],
  });
  assert.match(keyChoice, />Primary · 1234</);
  assert.match(keyChoice, />Backup · 5678</);
  assert.doesNotMatch(keyChoice, />Choose a model</);

  const modelChoice = renderPrerequisite({
    ...signedOut,
    sessionState: "authenticated",
    operation: "selecting_model",
    readiness: "choice_required",
    primaryAction: "choose_model",
    canCancel: true,
    accountId: "account-1",
    models: [
      { id: "model-1", displayName: "Model One" },
      { id: "model-2", displayName: "Model Two" },
    ],
  });
  assert.match(modelChoice, />Model One</);
  assert.match(modelChoice, />Model Two</);
  assert.doesNotMatch(modelChoice, />Choose an API Key</);
});

test("retryable and restart-required failures never leave an actionless spinner", () => {
  const retry = renderPrerequisite({
    ...signedOut,
    sessionState: "authenticated",
    readiness: "needs_attention",
    primaryAction: "retry_catalog",
    accountId: "account-1",
    errorCode: "metask_service_unavailable",
    safeDiagnostic: "upstream service returned internal status E_METASK_503",
  });
  assert.match(retry, /Finish preparing this task/);
  assert.match(retry, />Try again</);
  assert.match(retry, /temporarily unavailable/);
  assert.doesNotMatch(retry, /metask_service_unavailable/);
  assert.doesNotMatch(retry, /E_METASK_503/);

  const noKeys = renderPrerequisite({
    ...signedOut,
    sessionState: "authenticated",
    readiness: "needs_attention",
    primaryAction: "retry_catalog",
    accountId: "account-1",
    errorCode: "no_api_keys",
  });
  assert.match(noKeys, /No API Keys are available/);
  assert.match(noKeys, />Try again</);

  const restart = renderPrerequisite({
    ...signedOut,
    sessionState: "shutting_down",
    readiness: "restart_required",
    primaryAction: "restart",
    errorCode: "recovery_state_invalid",
  });
  assert.match(restart, /Restart MetaWork to continue/);
  assert.match(restart, /Close and reopen MetaWork/);
  assert.doesNotMatch(restart, /Try again|Sign in with Metask/);
});

test("ready Account is a secondary status and settings surface", () => {
  const ready = {
    ...signedOut,
    sessionState: "authenticated",
    executionState: "ready",
    readiness: "ready",
    primaryAction: "none",
    accountId: "account-1",
    displayName: "Metask User",
    selectedApiKeyId: "key-1",
    selectedModel: "model-1",
    canCreateTask: true,
    executionGeneration: "1",
  };
  assert.equal(renderPrerequisite(ready), "");
  const panel = withI18n(
    createElement(AccountPanel, {
      account: ready,
      disabled: false,
      ...callbacks,
    }),
  );
  assert.match(panel, /Metask User/);
  assert.match(panel, /model-1/);
  assert.match(panel, />Refresh account options</);
  assert.match(panel, />Sign out and clear this device</);
  assert.doesNotMatch(panel, /setup progress/);
});
