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
const { AccountGate } = await vite.ssrLoadModule(
  "/src/features/account/AccountGate.tsx",
);
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { requiresAccountGate } = await vite.ssrLoadModule(
  "/src/features/account/gating.ts",
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

const callbacks = {
  onReconnect() {},
  onBeginLogin() {},
  onReopenLogin() {},
  onReauthenticate() {},
  onCancel() {},
  onRetry() {},
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

function renderGate(account) {
  return withI18n(
    createElement(AccountGate, {
      account,
      disabled: false,
      cancelDisabled: false,
      connectionFailed: false,
      connectionRetryable: true,
      connectionTitleId: "connection.failed",
      connectionHelpId: "connection.failed_help",
      reconnecting: false,
      notice: "Workbench connected.",
      ...callbacks,
    }),
  );
}

function renderGateWith(account, props) {
  return withI18n(
    createElement(AccountGate, {
      account,
      disabled: false,
      cancelDisabled: false,
      connectionFailed: false,
      connectionRetryable: true,
      connectionTitleId: "connection.failed",
      connectionHelpId: "connection.failed_help",
      reconnecting: false,
      notice: "Workbench connected.",
      ...callbacks,
      ...props,
    }),
  );
}

test("signed-out readiness is an independent surface with one primary action", () => {
  const markup = renderGate(signedOut);
  assert.match(markup, /<main[^>]*account-gate/);
  assert.match(markup, /Sign in to MetaWork/);
  assert.match(markup, /load the APIs and models available to you/);
  assert.match(markup, />Sign in with Metask</);
  assert.doesNotMatch(markup, /Workspace|Task activity|composer-start/);
  assert.equal((markup.match(/primary-button/g) ?? []).length, 1);
});

test("Account gate is sticky only until the first successful Workbench entry", () => {
  const reconfiguring = {
    ...signedOut,
    sessionState: "authenticated",
    readiness: "preparing",
    executionState: "reconfiguring",
    executionGeneration: "4",
  };
  assert.equal(requiresAccountGate(false, reconfiguring), false);
  assert.equal(requiresAccountGate(true, reconfiguring), false);
  assert.equal(
    requiresAccountGate(false, {
      ...reconfiguring,
      executionGeneration: "0",
    }),
    true,
  );
  assert.equal(
    requiresAccountGate(true, {
      ...reconfiguring,
      sessionState: "signed_out",
    }),
    true,
  );
  assert.equal(
    requiresAccountGate(true, {
      ...reconfiguring,
      sessionState: "shutting_down",
      readiness: "restart_required",
    }),
    true,
  );
});

test("sign-out confirmation owns focus, Escape, and its description", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/features/settings/SettingsPage.tsx"),
    "utf8",
  );
  assert.match(source, /signOutCancel\.current\?\.focus\(\)/);
  assert.match(source, /event\.key !== "Escape"/);
  assert.match(source, /signOut\.current\?\.focus\(\)/);
  assert.match(source, /aria-describedby="settings-signout-confirmation-copy"/);
});

test("account disclosure implements complete menu keyboard movement", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/features/account/AccountIdentity.tsx"),
    "utf8",
  );
  for (const key of ["ArrowDown", "ArrowUp", "Home", "End", "Escape", "Tab"])
    assert.match(source, new RegExp(`event\\.key === "${key}"|"${key}"`));
  assert.match(source, /\[role="menuitem"\]:not\(:disabled\)/);
});

test("authorization wait can reopen or cancel without exposing the OAuth URL", () => {
  const markup = renderGate({
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
  const markup = renderGate({
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
  assert.doesNotMatch(markup, /Load API Keys|Try again|account-gate-choice/);
});

test("Account cancel stays available while an ordinary command is locally busy", () => {
  const markup = renderGateWith(
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
  const keyChoice = renderGate({
    ...signedOut,
    sessionState: "authenticated",
    operation: "selecting_key",
    readiness: "choice_required",
    primaryAction: "choose_api_key",
    canCancel: true,
    accountId: "account-1",
    apiKeys: [
      {
        selectionId: "key-1",
        name: "Primary",
        suffix: "1234",
        provider: "anthropic",
      },
      {
        selectionId: "key-2",
        name: "Backup",
        suffix: "5678",
        provider: "anthropic",
      },
    ],
  });
  assert.match(keyChoice, />Primary · 1234</);
  assert.match(keyChoice, />Backup · 5678</);
  assert.doesNotMatch(keyChoice, />Choose a model</);

  const modelChoice = renderGate({
    ...signedOut,
    sessionState: "authenticated",
    operation: "selecting_model",
    readiness: "choice_required",
    primaryAction: "choose_model",
    canCancel: true,
    accountId: "account-1",
    models: [
      { selectionId: "model-1", displayName: "Model One" },
      { selectionId: "model-2", displayName: "Model Two" },
    ],
  });
  assert.match(modelChoice, />Model One</);
  assert.match(modelChoice, />Model Two</);
  assert.doesNotMatch(modelChoice, />Choose an API Key</);
});

test("retryable and restart-required failures never leave an actionless spinner", () => {
  const retry = renderGate({
    ...signedOut,
    sessionState: "authenticated",
    readiness: "needs_attention",
    primaryAction: "retry_catalog",
    accountId: "account-1",
    displayName: "Metask User",
    errorCode: "metask_service_unavailable",
    safeDiagnostic: "upstream service returned internal status E_METASK_503",
  });
  assert.match(retry, /Account setup needs attention/);
  assert.match(retry, />Signed in<[\s\S]*?>Metask User</);
  assert.match(retry, />Try again</);
  assert.match(retry, /temporarily unavailable/);
  assert.doesNotMatch(retry, /metask_service_unavailable/);
  assert.match(retry, /Technical details/);
  assert.match(retry, /E_METASK_503/);

  const noKeys = renderGate({
    ...signedOut,
    sessionState: "authenticated",
    readiness: "needs_attention",
    primaryAction: "retry_catalog",
    accountId: "account-1",
    errorCode: "no_api_keys",
  });
  assert.match(noKeys, /No API Keys are available/);
  assert.match(noKeys, />Try again</);

  const restart = renderGate({
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

test("reauth-required gate presents a saved identity instead of a signed-in account", () => {
  const markup = renderGate({
    ...signedOut,
    sessionState: "reauth_required",
    readiness: "needs_attention",
    primaryAction: "reauthenticate",
    accountId: "account-1",
    displayName: "Metask User",
    errorCode: "token_refresh_failed",
  });
  assert.match(markup, /Sign-in expired/);
  assert.match(markup, /Saved account/);
  assert.match(markup, /Metask User/);
  assert.match(markup, />Sign in again</);
  assert.match(markup, />Sign out…</);
  assert.doesNotMatch(
    markup,
    /Account setup needs attention|Signed in|finish preparing this account/,
  );
});

test("reauth-required gate replaces stale saved identity with the next explicit sign-in", () => {
  const markup = renderGate({
    ...signedOut,
    sessionState: "reauth_required",
    readiness: "needs_attention",
    primaryAction: "reauthenticate",
    accountId: "account-1",
    profileId: "profile-1",
    displayName: "Metask User",
    errorCode: "account_mismatch",
  });
  assert.match(markup, />Sign in again</);
  assert.match(markup, /use the account from the new sign-in/);
  assert.match(markup, /Saved account/);
  assert.match(markup, />Sign out…/);
  assert.doesNotMatch(markup, /Sign-in expired|credential is no longer valid/);
});

test("reauth-required sign-out requires confirmation and restores focus", async () => {
  const source = await readFile(
    join(process.cwd(), "frontend/src/features/account/AccountGate.tsx"),
    "utf8",
  );
  assert.match(source, /signOutCancel\.current\?\.focus\(\)/);
  assert.match(source, /event\.key !== "Escape"/);
  assert.match(source, /signOut\.current\?\.focus\(\)/);
  assert.match(
    source,
    /aria-describedby="account-gate-signout-confirmation-copy"/,
  );
  assert.match(source, /onClick=\{onLogout\}/);
});

test("ready Account uses a formal settings route with truthful defaults", () => {
  const ready = {
    ...signedOut,
    sessionState: "authenticated",
    executionState: "ready",
    readiness: "ready",
    primaryAction: "none",
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
    executionGeneration: "1",
  };
  assert.equal(renderGate(ready), "");
  const panel = withI18n(
    createElement(SettingsPage, {
      account: ready,
      focusTarget: "title",
      disabled: false,
      cancelDisabled: false,
      ...callbacks,
    }),
  );
  assert.match(panel, /<h1[^>]*tabindex="-1">Settings</);
  assert.match(panel, /Metask User/);
  assert.match(panel, />Model One</);
  assert.equal((panel.match(/role="combobox"/g) ?? []).length, 3);
  assert.match(panel, /selection-trigger-value">Primary</);
  assert.match(
    panel,
    /selection-trigger-detail" data-kind="text" title="Anthropic">Anthropic</,
  );
  assert.match(panel, /selection-trigger-trailing">•••• 1234</);
  assert.equal((panel.match(/selection-trigger-action/g) ?? []).length, 2);
  assert.equal((panel.match(/>View options</g) ?? []).length, 2);
  assert.match(panel, />APIs 1 · Models 1</);
  assert.match(panel, /Metask currently returns only this API/);
  assert.match(panel, /This API currently provides only one available model/);
  assert.doesNotMatch(panel, /<button[^>]*disabled=""[^>]*id="settings-api"/);
  assert.doesNotMatch(panel, /<button[^>]*disabled=""[^>]*id="settings-model"/);
  assert.doesNotMatch(panel, /<select(?![^>]*aria-hidden="true")/);
  assert.match(panel, /aria-current="location">General</);
  assert.match(
    panel,
    /class="settings-execution-group" role="group" aria-labelledby="settings-execution-title"/,
  );
  assert.match(panel, />Sync again</);
  assert.match(panel, />Sign out…</);
  assert.match(panel, /Existing task bindings and history remain unchanged/);
  assert.doesNotMatch(panel, /Appearance|Notifications|Permissions|Plugins/);
});

test("settings keep APIs and models identifiable when display names are absent", () => {
  const account = {
    ...signedOut,
    sessionState: "authenticated",
    executionState: "ready",
    readiness: "ready",
    primaryAction: "none",
    accountId: "account-1",
    profileId: "profile-1",
    displayName: "Metask User",
    apiKeys: [
      {
        selectionId: "42",
        name: "",
        suffix: "1234",
        provider: "openai",
      },
    ],
    models: [{ selectionId: "minimax-m2.5", displayName: "" }],
    selectedApiKeySelectionId: "42",
    selectedModelSelectionId: "minimax-m2.5",
    modelCatalogApiKeySelectionId: "42",
    canCreateTask: true,
    catalogGeneration: "1",
    executionGeneration: "1",
  };
  const panel = withI18n(
    createElement(SettingsPage, {
      account,
      focusTarget: "title",
      disabled: false,
      cancelDisabled: false,
      ...callbacks,
    }),
  );

  assert.match(panel, /selection-trigger-value">Metask API 42</);
  assert.match(panel, /selection-trigger-value">minimax-m2\.5</);
  assert.doesNotMatch(panel, /selection-trigger-value">Available models</);
});

test("desktop settings shortcut opens the formal route through the native event", async () => {
  const [app, manifest] = await Promise.all([
    readFile(join(process.cwd(), "frontend/src/app/App.tsx"), "utf8"),
    readFile(join(process.cwd(), "app.zon"), "utf8"),
  ]);

  assert.match(
    manifest,
    /\.id = "settings\.open", \.key = ",", \.modifiers = \.\{"primary"\}/,
  );
  assert.match(app, /client\.onShortcut\(\(detail\) => \{/);
  assert.match(app, /detail\.id !== "settings\.open"/);
  assert.match(app, /accountGateRequired \|\| bridgeUnavailable/);
  assert.match(app, /openSettings\(\)/);
  assert.match(
    app,
    /function openSettings[\s\S]*?snapshot\.account\.sessionState !==\s*"authenticated"[\s\S]*?snapshot\.account\.operation !== "none"[\s\S]*?client\.refreshAccountCatalog\(\)/,
  );
});

test("reauth-required settings disable stale catalog mutations", () => {
  const account = {
    ...signedOut,
    sessionState: "reauth_required",
    executionState: "ready",
    readiness: "needs_attention",
    primaryAction: "reauthenticate",
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
    executionGeneration: "1",
  };
  const panel = withI18n(
    createElement(SettingsPage, {
      account,
      focusTarget: "title",
      disabled: false,
      cancelDisabled: false,
      ...callbacks,
    }),
  );
  assert.match(panel, />Sign in again</);
  assert.match(
    panel,
    /class="settings-identity-row" data-session-state="reauth_required"/,
  );
  assert.match(panel, /<button[^>]*disabled=""[^>]*id="settings-api"/);
  assert.match(panel, /<button[^>]*disabled=""[^>]*id="settings-model"/);
  assert.match(
    panel,
    /<button[^>]*disabled=""[^>]*>[\s\S]*?Sync again<\/button>/,
  );
  assert.match(panel, />Sign out…</);
});

test("settings project the full API transaction without replacing committed truth", () => {
  const base = {
    ...signedOut,
    sessionState: "authenticated",
    executionState: "ready",
    readiness: "ready",
    primaryAction: "none",
    accountId: "account-1",
    displayName: "Metask User",
    apiKeys: [
      {
        selectionId: "key-1",
        name: "Primary",
        suffix: "1234",
        provider: "anthropic",
      },
      {
        selectionId: "key-2",
        name: "Backup",
        suffix: "5678",
        provider: "openai",
      },
    ],
    models: [{ selectionId: "model-1", displayName: "Model One" }],
    selectedApiKeySelectionId: "key-1",
    selectedModelSelectionId: "model-1",
    modelCatalogApiKeySelectionId: "key-1",
    canCreateTask: true,
    executionGeneration: "1",
  };
  const renderSettings = (account) =>
    withI18n(
      createElement(SettingsPage, {
        account,
        focusTarget: "title",
        disabled: false,
        cancelDisabled: false,
        ...callbacks,
      }),
    );

  const preparing = renderSettings({
    ...base,
    operation: "loading_keys",
    candidateApiKeySelectionId: "key-2",
    canCreateTask: false,
    canCancel: true,
  });
  assert.match(preparing, /selection-trigger-value">Backup</);
  assert.match(preparing, /Pending change/);
  assert.match(preparing, /Preparing Backup/);
  assert.match(preparing, /current default.*stays active/i);
  assert.match(preparing, /selection-trigger-value">Model One</);

  const loading = renderSettings({
    ...base,
    operation: "loading_models",
    candidateApiKeySelectionId: "key-2",
    modelCatalogApiKeySelectionId: "key-2",
    models: [],
    canCreateTask: false,
    canCancel: true,
  });
  assert.match(
    loading,
    /id="settings-api"[^>]*aria-busy="true"[^>]*data-busy="true"/,
  );
  assert.match(loading, /selection-trigger-value">Backup</);
  assert.match(loading, /Loading models available to Backup/);
  assert.match(loading, />Loading models…</);
  assert.match(loading, />Cancel</);

  const choosing = renderSettings({
    ...base,
    operation: "selecting_model",
    candidateApiKeySelectionId: "key-2",
    modelCatalogApiKeySelectionId: "key-2",
    primaryAction: "choose_model",
    readiness: "choice_required",
    models: [{ selectionId: "model-2", displayName: "Model Two" }],
    canCreateTask: false,
    canCancel: true,
  });
  assert.match(choosing, /<button[^>]*disabled=""[^>]*id="settings-api"/);
  assert.doesNotMatch(
    choosing,
    /<button[^>]*disabled=""[^>]*id="settings-model"/,
  );
  assert.match(choosing, />Choose a model</);

  const persisting = renderSettings({
    ...base,
    executionState: "reconfiguring",
    operation: "persisting",
    candidateApiKeySelectionId: "key-2",
    candidateModelSelectionId: "model-2",
    modelCatalogApiKeySelectionId: "key-2",
    models: [{ selectionId: "model-2", displayName: "Model Two" }],
    canCreateTask: false,
    canCancel: false,
  });
  assert.match(
    persisting,
    /id="settings-model"[^>]*aria-busy="true"[^>]*data-busy="true"/,
  );
  assert.match(persisting, /Saving the new default/);
  assert.match(persisting, /Backup · Model Two/);
  assert.match(persisting, /Saving/);
  assert.doesNotMatch(persisting, />Cancel</);

  const failed = renderSettings({
    ...base,
    errorCode: "metask_service_unavailable",
  });
  assert.match(failed, /role="alert"/);
  assert.match(failed, /Account action needs attention/);
  assert.match(failed, /No default was changed/);
  assert.match(failed, />Sync again</);

  const cancelled = renderSettings({
    ...base,
    errorCode: "user_cancelled",
  });
  assert.match(cancelled, /Change cancelled/);
  assert.match(cancelled, /Primary · Model One remains your default/);
});

test("cold connection failure exposes only reconnect and technical details", () => {
  const markup = renderGateWith(
    {
      ...signedOut,
      sessionState: "restoring",
      readiness: "checking",
      primaryAction: "none",
    },
    {
      connectionFailed: true,
      connectionDiagnostic: "revision mismatch",
    },
  );
  assert.match(markup, /The Workbench view is unavailable/);
  assert.match(markup, />Reconnect</);
  assert.match(markup, /revision mismatch/);
  assert.doesNotMatch(markup, />Sign in with Metask|Workspace|Task activity/);
});

test("stale application components expose terminal recovery instead of reconnect", () => {
  const markup = renderGateWith(
    {
      ...signedOut,
      sessionState: "restoring",
      readiness: "checking",
      primaryAction: "none",
    },
    {
      connectionFailed: true,
      connectionRetryable: false,
      connectionTitleId: "connection.component_mismatch",
      connectionHelpId: "connection.component_mismatch_help",
      connectionSourceId: "connection.source.bootstrap",
      connectionDiagnostic: "Host requires Renderer Bridge revision 1",
    },
  );
  assert.match(markup, /MetaWork components do not match/);
  assert.match(
    markup,
    /rebuild or reinstall the matching application components/,
  );
  assert.match(markup, />Close MetaWork</);
  assert.match(
    markup,
    /Renderer contract: Host requires Renderer Bridge revision 1/,
  );
  assert.doesNotMatch(markup, />Reconnect</);
});
