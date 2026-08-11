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
const { AccountGate } = await vite.ssrLoadModule(
  "/src/features/account/AccountGate.tsx",
);
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { requiresAccountGate } = await vite.ssrLoadModule(
  "/src/features/account/gating.ts",
);
const { accountErrorMessageId } = await vite.ssrLoadModule(
  "/src/i18n/account-error.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.after(async () => vite.close());

const signedOut = {
  state: "signed_out",
  catalogState: "unavailable",
  canCancel: false,
  accountId: "",
  displayName: "",
  apiKeys: [],
  models: [],
  selectedApiKeySelectionId: "",
  selectedModelSelectionId: "",
  candidateApiKeySelectionId: "",
  candidateModelSelectionId: "",
  modelCatalogApiKeySelectionId: "",
  canCreateTask: false,
  errorCode: "none",
  safeDiagnostic: "",
  catalogGeneration: "0",
  executionGeneration: "0",
};

const ready = {
  ...signedOut,
  state: "authenticated",
  catalogState: "ready",
  accountId: "account-1",
  displayName: "Metask User",
  apiKeys: [
    {
      selectionId: "key-1",
      name: "Primary",
      suffix: "1234",
      provider: "anthropic",
    },
  ],
  models: [{ selectionId: "model-1", displayName: "Model One" }],
  selectedApiKeySelectionId: "key-1",
  selectedModelSelectionId: "model-1",
  modelCatalogApiKeySelectionId: "key-1",
  canCreateTask: true,
  catalogGeneration: "1",
  executionGeneration: "1",
};

const callbacks = {
  onReconnect() {},
  onBeginLogin() {},
  onCancel() {},
  onRefresh() {},
  onSelectApiKey() {},
  onSelectModel() {},
  onLogout() {},
  onBack() {},
};

const workspaceSettingsProps = {
  manualWorkspaces: [],
  tasks: [],
  workspaceDisabled: false,
  workspaceBusy: false,
  async onChooseWorkspace() {
    return { kind: "cancelled" };
  },
  async onRemoveWorkspace() {
    return { kind: "accepted" };
  },
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

function renderGate(account, props = {}) {
  return withI18n(
    createElement(AccountGate, {
      account,
      cancelDisabled: false,
      connectionFailed: false,
      connectionRetryable: true,
      connectionTitleId: "connection.failed",
      connectionHelpId: "connection.failed_help",
      reconnecting: false,
      notice: "",
      ...callbacks,
      ...props,
    }),
  );
}

function renderSettings(account) {
  return withI18n(
    createElement(SettingsPage, {
      account,
      focusTarget: "title",
      disabled: false,
      cancelDisabled: false,
      ...workspaceSettingsProps,
      ...callbacks,
    }),
  );
}

test("only checking and authorizing replace the Workbench surface", () => {
  assert.equal(requiresAccountGate({ state: "checking" }), true);
  assert.equal(requiresAccountGate({ state: "authorizing" }), true);
  assert.equal(requiresAccountGate({ state: "signed_out" }), false);
  assert.equal(requiresAccountGate({ state: "authenticated" }), false);
});

test("Account runtime blockers keep running tasks distinct from idle sessions", () => {
  assert.equal(
    accountErrorMessageId("execution_in_use"),
    "account.task_running",
  );
  assert.equal(
    accountErrorMessageId("session_in_use"),
    "account.session_in_use",
  );
});

test("authorization has one cancel path and no reopen or reauthenticate branch", () => {
  const markup = renderGate({
    ...signedOut,
    state: "authorizing",
    canCancel: true,
  });
  assert.match(markup, /Finishing Metask sign-in/);
  assert.match(markup, /Cancel current action/);
  assert.doesNotMatch(
    markup,
    /Open sign-in page again|Sign in again|saved account|previous account/,
  );
});

test("signed-out settings keep local history reachable and expose sign-in", () => {
  const markup = renderSettings(signedOut);
  assert.match(markup, /Sign in to MetaWork/);
  assert.match(markup, />Sign in with Metask</);
  assert.doesNotMatch(markup, /Sign out on this device/);
});

test("authenticated settings project current catalog defaults", () => {
  const markup = renderSettings(ready);
  assert.match(markup, /Metask User/);
  assert.match(markup, /Primary/);
  assert.match(markup, /Model One/);
  assert.match(markup, /Sign out on this device/);
});

test("catalog failure remains an authenticated retryable settings state", () => {
  const markup = renderSettings({
    ...ready,
    catalogState: "failed",
    canCreateTask: false,
    errorCode: "metask_service_unavailable",
  });
  assert.match(markup, /Account action needs attention/);
  assert.match(markup, /Sync again/);
  assert.doesNotMatch(markup, /Sign in again/);
});

test("cold connection failure exposes reconnect and bounded diagnostics", () => {
  const markup = renderGate(
    { ...signedOut, state: "checking" },
    {
      connectionFailed: true,
      connectionDiagnostic: "transport unavailable",
    },
  );
  assert.match(markup, /Reconnect/);
  assert.match(markup, /transport unavailable/);
});
