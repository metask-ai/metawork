import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
const { requiresAccountGate, requiresAccountSetup } = await vite.ssrLoadModule(
  "/src/features/account/gating.ts",
);
const { accountSurfacePolicy } = await vite.ssrLoadModule(
  "/src/app/account-surface-policy.ts",
);
const { accountErrorMessageId } = await vite.ssrLoadModule(
  "/src/i18n/account-error.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

const appSource = readFileSync(
  new URL("../frontend/src/app/App.tsx", import.meta.url),
  "utf8",
);

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
  errorCode: "none",
  safeDiagnostic: "",
  catalogGeneration: "0",
};

const unavailableExecution = {
  state: "unavailable",
  defaultSource: null,
  activeSource: null,
  activeGeneration: "0",
  taskCreationAvailable: false,
  selectedModelConnectionId: "",
  modelConnections: [],
  errorCode: "none",
};

const readyExecution = {
  ...unavailableExecution,
  state: "ready",
  defaultSource: "metask",
  activeSource: "metask",
  activeGeneration: "1",
  taskCreationAvailable: true,
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
      protocol: "anthropic_messages",
    },
  ],
  models: [{ selectionId: "model-1", displayName: "Model One" }],
  selectedApiKeySelectionId: "key-1",
  selectedModelSelectionId: "model-1",
  modelCatalogApiKeySelectionId: "key-1",
  catalogGeneration: "1",
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

function renderSettings(account, execution = readyExecution) {
  return withI18n(
    createElement(SettingsPage, {
      account,
      execution,
      modelConnectionCapabilities: {
        management: false,
        secretCapture: false,
        connectionTest: false,
      },
      permissionProfiles: {
        enabled: false,
        available: [],
        defaultProfile: "approval_required",
        busy: false,
      },
      focusTarget: "title",
      disabled: false,
      accountDisabled: false,
      executionDisabled: false,
      cancelDisabled: false,
      onCreateModelConnection: async () => false,
      onUpdateModelConnection: async () => false,
      onRemoveModelConnection: async () => false,
      onTestModelConnection() {},
      onSelectModelConnection() {},
      onActivateMetask() {},
      onSetDefaultPermissionProfile() {},
      ...callbacks,
    }),
  );
}

test("only checking and authorizing request the Account onboarding surface", () => {
  assert.equal(
    requiresAccountGate({ state: "checking" }, { defaultSource: "metask" }),
    true,
  );
  assert.equal(
    requiresAccountGate({ state: "authorizing" }, { defaultSource: "metask" }),
    true,
  );
  assert.equal(
    requiresAccountGate({ state: "signed_out" }, { defaultSource: "metask" }),
    false,
  );
  assert.equal(
    requiresAccountGate(
      { state: "authenticated" },
      { defaultSource: "metask" },
    ),
    false,
  );
  assert.equal(
    requiresAccountGate(
      { state: "checking" },
      { defaultSource: "model_connection" },
    ),
    false,
  );
});

test("unresolved authenticated catalog opens account setup", () => {
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated", catalogState: "choosing" },
      { defaultSource: "metask", taskCreationAvailable: false },
    ),
    true,
  );
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated", catalogState: "failed" },
      { defaultSource: "metask", taskCreationAvailable: false },
    ),
    true,
  );
  // Transient loading resolves through the automatic post-login
  // continuation; redirecting on it flashes settings on every startup.
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated", catalogState: "loading" },
      { defaultSource: "metask", taskCreationAvailable: false },
    ),
    false,
  );
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated", catalogState: "ready" },
      { defaultSource: "metask", taskCreationAvailable: true },
    ),
    false,
  );
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated", catalogState: "ready" },
      { defaultSource: "metask", taskCreationAvailable: false },
    ),
    false,
  );
});

test("Product execution failure never opens Account setup", () => {
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated", catalogState: "ready" },
      { defaultSource: "metask", taskCreationAvailable: false },
    ),
    false,
  );
  assert.equal(
    accountSurfacePolicy(
      { state: "authenticated", catalogState: "ready" },
      { defaultSource: "metask", taskCreationAvailable: false },
      false,
    ).setupRequired,
    false,
  );
});

test("Account onboarding never replaces a Workbench that already owns Tasks", () => {
  const checking = accountSurfacePolicy(
    { ...signedOut, state: "checking" },
    { defaultSource: "metask", taskCreationAvailable: false },
    true,
  );
  assert.deepEqual(checking, {
    gateRequired: false,
    setupRequired: false,
  });

  const unresolved = accountSurfacePolicy(
    { ...signedOut, state: "authenticated", catalogState: "failed" },
    { defaultSource: "metask", taskCreationAvailable: false },
    true,
  );
  assert.deepEqual(unresolved, {
    gateRequired: false,
    setupRequired: false,
  });

  const empty = accountSurfacePolicy(
    { ...signedOut, state: "checking" },
    { defaultSource: "metask", taskCreationAvailable: false },
    false,
  );
  assert.equal(empty.gateRequired, true);
});

test("Account errors stay inside the Account failure domain", () => {
  assert.equal(
    accountErrorMessageId("account_operation_failed"),
    "account.error.generic",
  );
});

test("Account preference recovery exposes the canonical login repair and freezes selectors", () => {
  const markup = renderSettings({
    ...ready,
    errorCode: "recovery_state_invalid",
  });
  assert.match(markup, /Sign in with Metask/);
  assert.match(markup, /id="settings-api"[^>]*disabled/);
  assert.match(markup, /id="settings-model"[^>]*disabled/);
});

test("Execution commands never enter the Account busy or error scope", () => {
  assert.doesNotMatch(
    appSource,
    /runAccountCommand\(\(\) =>\s*client\.(?:selectMetaskDefault|selectDefaultModelConnection|createModelConnection|updateModelConnection|removeModelConnection|testModelConnection)/,
  );
  assert.match(
    appSource,
    /runExecutionCommand\(\(\) =>\s*client\.selectDefaultModelConnection/,
  );
});

test("opening Account settings has no hidden catalog mutation", () => {
  assert.doesNotMatch(
    appSource,
    /function openSettings[\s\S]*?runAccountCommand\(\(\) => client\.refreshAccountCatalog\(\)\)[\s\S]*?function closeSettings/,
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
  assert.match(markup, /id="settings-model-connections"[^>]*hidden=""/);
});

test("catalog failure remains an authenticated retryable settings state", () => {
  const markup = renderSettings({
    ...ready,
    catalogState: "failed",
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
