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
  canCancel: false,
  accountId: "",
  displayName: "",
  errorCode: "none",
  safeDiagnostic: "",
};

const unavailableModels = {
  availability: "needs_authentication",
  persistenceHealth: "ready",
  providers: [
    {
      id: "metask",
      displayName: "Metask",
      recommended: true,
      catalogState: "needs_authentication",
      principalRef: "",
      apiKeys: [],
      models: [],
      selectedApiKeyId: "",
      catalogGeneration: "0",
      sourceGeneration: "0",
      errorCode: "authorization_unavailable",
      safeDiagnostic: "",
    },
  ],
  metaskSelection: null,
  metaskSelectionRevision: "0",
  defaultSelection: null,
  selectionRevision: "0",
  operation: "idle",
  errorCode: "authorization_unavailable",
  connections: [],
};

const readyAccount = {
  ...signedOut,
  state: "authenticated",
  accountId: "account-1",
  displayName: "Metask User",
};

const readyModels = {
  ...unavailableModels,
  availability: "ready",
  providers: [
    {
      ...unavailableModels.providers[0],
      catalogState: "ready",
      principalRef: "account-1",
      apiKeys: [
        {
          id: "key-1",
          name: "Primary",
          suffix: "1234",
          protocol: "anthropic_messages",
        },
      ],
      models: [{ id: "model-1", displayName: "Model One" }],
      selectedApiKeyId: "key-1",
      catalogGeneration: "1",
      sourceGeneration: "1",
      errorCode: "none",
    },
  ],
  metaskSelection: { sourceId: "metask:key-1", modelId: "model-1" },
  metaskSelectionRevision: "1",
  defaultSelection: { sourceId: "metask:key-1", modelId: "model-1" },
  selectionRevision: "1",
  errorCode: "none",
};

const callbacks = {
  onReconnect() {},
  onBeginLogin() {},
  onRetryRefresh() {},
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

function renderSettings(account, models = readyModels) {
  return withI18n(
    createElement(SettingsPage, {
      account,
      models,
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
    requiresAccountGate({ state: "checking" }, unavailableModels),
    true,
  );
  assert.equal(
    requiresAccountGate({ state: "authorizing" }, unavailableModels),
    true,
  );
  assert.equal(
    requiresAccountGate({ state: "signed_out" }, unavailableModels),
    false,
  );
  assert.equal(
    requiresAccountGate({ state: "authenticated" }, readyModels),
    false,
  );
  assert.equal(
    requiresAccountGate(
      { state: "checking" },
      {
        defaultSelection: { sourceId: "connection-1", modelId: "model-1" },
      },
    ),
    false,
  );
});

test("unresolved authenticated catalog opens account setup", () => {
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated" },
      {
        providers: [{ ...readyModels.providers[0], catalogState: "choosing" }],
        defaultSelection: readyModels.defaultSelection,
      },
    ),
    true,
  );
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated" },
      {
        providers: [{ ...readyModels.providers[0], catalogState: "failed" }],
        defaultSelection: readyModels.defaultSelection,
      },
    ),
    true,
  );
  // Transient loading resolves through the automatic post-login
  // continuation; redirecting on it flashes settings on every startup.
  assert.equal(
    requiresAccountSetup(
      { state: "authenticated" },
      {
        providers: [{ ...readyModels.providers[0], catalogState: "loading" }],
        defaultSelection: readyModels.defaultSelection,
      },
    ),
    false,
  );
  assert.equal(
    requiresAccountSetup({ state: "authenticated" }, readyModels),
    false,
  );
  assert.equal(
    requiresAccountSetup({ state: "authenticated" }, readyModels),
    false,
  );
});

test("Product execution failure never opens Account setup", () => {
  assert.equal(
    requiresAccountSetup({ state: "authenticated" }, readyModels),
    false,
  );
  assert.equal(
    accountSurfacePolicy({ state: "authenticated" }, readyModels, false)
      .setupRequired,
    false,
  );
});

test("Account onboarding never replaces a Workbench that already owns Tasks", () => {
  const checking = accountSurfacePolicy(
    { ...signedOut, state: "checking" },
    unavailableModels,
    true,
  );
  assert.deepEqual(checking, {
    gateRequired: false,
    setupRequired: false,
  });

  const unresolved = accountSurfacePolicy(
    { ...readyAccount },
    {
      ...readyModels,
      providers: [{ ...readyModels.providers[0], catalogState: "failed" }],
    },
    true,
  );
  assert.deepEqual(unresolved, {
    gateRequired: false,
    setupRequired: false,
  });

  const empty = accountSurfacePolicy(
    { ...signedOut, state: "checking" },
    unavailableModels,
    false,
  );
  assert.equal(empty.gateRequired, true);
});

test("Account errors stay inside the Account failure domain", () => {
  assert.equal(
    accountErrorMessageId("account_operation_failed"),
    "account.error.generic",
  );
  assert.equal(
    accountErrorMessageId("refresh_schedule_failed"),
    "account.error.refresh_schedule",
  );
});

test("refresh scheduling failure exposes the explicit Account retry", () => {
  const markup = renderSettings({
    ...readyAccount,
    errorCode: "refresh_schedule_failed",
  });
  assert.match(markup, /Automatic sign-in refresh could not be scheduled/);
  assert.match(markup, />Retry sign-in refresh</);
});

test("Models preference recovery preserves Account identity and freezes selectors", () => {
  const markup = renderSettings(readyAccount, {
    ...readyModels,
    persistenceHealth: "recovery_required",
    errorCode: "migration_required",
  });
  assert.match(markup, /Metask User/);
  assert.match(markup, /Model configuration needs attention/);
  assert.doesNotMatch(markup, />Sign in with Metask</);
  assert.match(markup, /id="settings-api"[^>]*disabled/);
  assert.match(markup, /id="settings-model"[^>]*disabled/);
});

test("Execution commands never enter the Account busy or error scope", () => {
  assert.doesNotMatch(
    appSource,
    /runAccountCommand\(\(\) =>\s*client\.(?:refreshModelsCatalog|selectMetaskApiKey|configureMetaskSelection|selectModelsDefault|createModelConnection|updateModelConnection|replaceModelConnectionCredential|removeModelConnection|testModelConnection)/,
  );
  assert.match(
    appSource,
    /runExecutionCommand\(\(\) =>\s*client\.selectModelsDefault/,
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
  const markup = renderSettings(signedOut, unavailableModels);
  assert.match(markup, /Sign in to MetaWork/);
  assert.match(markup, />Sign in with Metask</);
  assert.doesNotMatch(markup, /Sign out on this device/);
});

test("authenticated settings project current catalog defaults", () => {
  const markup = renderSettings(readyAccount, readyModels);
  assert.match(markup, /Metask User/);
  assert.match(markup, /Primary/);
  assert.match(markup, /Model One/);
  assert.match(markup, /Sign out on this device/);
  assert.match(markup, /id="settings-model-connections"[^>]*hidden=""/);
});

test("catalog failure remains an authenticated retryable settings state", () => {
  const markup = renderSettings(readyAccount, {
    ...readyModels,
    providers: [
      {
        ...readyModels.providers[0],
        catalogState: "failed",
        errorCode: "catalog_unavailable",
      },
    ],
    errorCode: "catalog_unavailable",
  });
  assert.match(markup, /Model configuration needs attention/);
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
