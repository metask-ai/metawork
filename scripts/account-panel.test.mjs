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
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { ConnectionFailureScreen } = await vite.ssrLoadModule(
  "/src/features/connection/ConnectionFailureScreen.tsx",
);
const { formatAccountDecimal, formatAccountSyncedAt } =
  await vite.ssrLoadModule("/src/features/settings/account-summary-format.ts");
const { buildUsageCalendar } = await vite.ssrLoadModule(
  "/src/features/settings/AccountUsageHeatmap.tsx",
);
const { accountErrorMessageId } = await vite.ssrLoadModule(
  "/src/i18n/account-error.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

const readyAutomaticWorkspaceRoot = {
  generation: "1",
  mode: "system_default",
  canonicalRoot: "/tmp/MetaWork/Automatic Workspaces",
  health: "ready",
  redacted: false,
  canChoose: true,
  canReset: false,
  canRetry: false,
};

const appSource = readFileSync(
  new URL("../frontend/src/app/App.tsx", import.meta.url),
  "utf8",
);

test.after(async () => vite.close());

const emptyAccountSummary = {
  operation: "idle",
  usageEligibility: "unknown",
  wallet: {
    availability: "unavailable",
    balanceU: null,
    syncedAt: null,
    errorCode: "none",
    safeDiagnostic: "",
  },
  usage: {
    availability: "unavailable",
    today: null,
    total: null,
    syncedAt: null,
    errorCode: "none",
    safeDiagnostic: "",
  },
  history: {
    availability: "unavailable",
    startDate: null,
    endDate: null,
    days: [],
    syncedAt: null,
    errorCode: "none",
    safeDiagnostic: "",
  },
};

const signedOut = {
  state: "signed_out",
  canCancel: false,
  accountId: "",
  displayName: "",
  emailHint: "",
  phoneHint: "",
  concurrencyLimit: null,
  errorCode: "none",
  safeDiagnostic: "",
  summary: emptyAccountSummary,
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
  builtinProviderPresets: [],
  customProviders: [],
};

const readyAccount = {
  ...signedOut,
  state: "authenticated",
  accountId: "account-1",
  displayName: "Metask User",
  emailHint: "m***@example.com",
  phoneHint: "",
  concurrencyLimit: 5,
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
  onRefreshAccountSummary() {},
  onOpenRecharge() {},
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

function renderSettings(account, models = readyModels, options = {}) {
  return withI18n(
    createElement(SettingsPage, {
      account,
      models,
      automaticWorkspaceRoot: readyAutomaticWorkspaceRoot,
      initialSection: options.initialSection ?? "general",
      customProviderCapabilities: {
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
      onCreateCustomProvider: async () => false,
      onUpdateCustomProvider: async () => false,
      onAddCustomModel: async () => false,
      onRemoveCustomProvider: async () => false,
      onTestCustomModel() {},
      onSelectCustomProvider() {},
      onResetModels: async () => false,
      onChooseAutomaticWorkspaceRoot: async () => false,
      onResetAutomaticWorkspaceRoot: async () => false,
      onRetryAutomaticWorkspaceRoot: async () => false,
      onSetDefaultPermissionProfile() {},
      ...callbacks,
      ...options,
    }),
  );
}

function renderConnectionFailure() {
  return withI18n(
    createElement(ConnectionFailureScreen, {
      titleId: "connection.failed",
      helpId: "connection.failed_help",
      diagnostic: "transport unavailable",
      retryable: true,
      retrying: false,
      onRetry() {},
    }),
  );
}

test("Account settings render each public session state with only its valid action", () => {
  const checkingMarkup = renderSettings(
    { ...signedOut, state: "checking" },
    unavailableModels,
    { initialSection: "account" },
  );
  assert.match(checkingMarkup, /Checking sign-in/);
  assert.doesNotMatch(checkingMarkup, />Sign in</);

  const callbackMarkup = renderSettings(
    { ...signedOut, state: "authorizing", canCancel: true },
    unavailableModels,
    { initialSection: "account" },
  );
  assert.match(callbackMarkup, /Complete authorization in your browser/);
  assert.match(callbackMarkup, />Cancel</);
  assert.doesNotMatch(callbackMarkup, />Sign in</);

  const exchangeMarkup = renderSettings(
    { ...signedOut, state: "authorizing", canCancel: false },
    unavailableModels,
    { initialSection: "account" },
  );
  assert.match(exchangeMarkup, /Finishing Metask sign-in/);
  assert.doesNotMatch(exchangeMarkup, />Cancel</);
  assert.doesNotMatch(exchangeMarkup, />Sign in</);

  const signedOutMarkup = renderSettings(signedOut, unavailableModels, {
    initialSection: "account",
  });
  assert.match(signedOutMarkup, /Sign in to MetaWork/);
  assert.match(signedOutMarkup, />Sign in with Metask</);
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
  const markup = renderSettings(
    {
      ...readyAccount,
      errorCode: "refresh_schedule_failed",
    },
    readyModels,
    { initialSection: "account" },
  );
  assert.match(markup, /Automatic sign-in refresh could not be scheduled/);
  assert.match(markup, />Retry sign-in refresh</);
});

test("Account settings render the whole-account balance and exact usage ledger", () => {
  const markup = renderSettings(
    {
      ...readyAccount,
      summary: {
        operation: "idle",
        usageEligibility: "enabled",
        wallet: {
          availability: "ready",
          balanceU: "100.25",
          syncedAt: "1789344000000",
          errorCode: "none",
          safeDiagnostic: "",
        },
        usage: {
          availability: "ready",
          today: {
            inputTokens: "344800",
            outputTokens: "496100",
            cacheCreationTokens: "0",
            cacheReadTokens: "1490000",
            totalTokens: "2330900",
            actualCostU: "149.739",
          },
          total: { totalTokens: "1204200000", actualCostU: "23420.1178" },
          syncedAt: "1789344000000",
          errorCode: "none",
          safeDiagnostic: "",
        },
        history: {
          availability: "ready",
          startDate: "2025-09-15",
          endDate: "2026-09-15",
          days: [
            {
              date: "2026-09-15",
              inputTokens: "344800",
              outputTokens: "496100",
              cacheCreationTokens: "0",
              cacheReadTokens: "1490000",
              totalTokens: "2330900",
              actualCostU: "149.739",
            },
          ],
          syncedAt: "1789344000000",
          errorCode: "none",
          safeDiagnostic: "",
        },
      },
    },
    readyModels,
    { initialSection: "account" },
  );
  assert.match(markup, /Account usage/);
  assert.doesNotMatch(markup, /Metask connected/);
  assert.match(markup, /whole Metask account, not only activity in MetaWork/);
  assert.match(markup, /100\.25 U/);
  assert.match(markup, /m\*\*\*@example\.com/);
  assert.match(markup, /Concurrency allowance 5/);
  assert.match(markup, /title="Open the Metask recharge page in your browser"/);
  assert.match(markup, />Recharge</);
  assert.match(
    markup,
    /Account information[\s\S]*settings-identity-balance[\s\S]*100\.25 U[\s\S]*Account usage/,
  );
  assert.match(markup, /2,330,900 Token/);
  assert.match(markup, /1,204,200,000 Token/);
  assert.match(markup, /Input 344,800 · Output 496,100/);
  assert.match(markup, /Token usage history/);
  assert.match(markup, /Daily Token usage calendar/);
  assert.equal(markup.match(/settings-account-calendar-day/g)?.length, 366);
  assert.match(markup, /September 15, 2026, 2,330,900 Token/);
  assert.doesNotMatch(markup, />Today</);
  assert.match(markup, />Refresh account usage</);
  assert.doesNotMatch(markup, /RPM|TPM|response time|API keys|standard cost/i);
});

test("Account summary failure stays local, stale values remain, and simple mode hides usage", () => {
  const partial = {
    ...readyAccount,
    summary: {
      operation: "idle",
      usageEligibility: "enabled",
      wallet: {
        availability: "ready",
        balanceU: "12",
        syncedAt: "1789344000000",
        errorCode: "none",
        safeDiagnostic: "",
      },
      usage: {
        availability: "unavailable",
        today: null,
        total: null,
        syncedAt: null,
        errorCode: "metask_service_unavailable",
        safeDiagnostic: "",
      },
      history: {
        availability: "unavailable",
        startDate: null,
        endDate: null,
        days: [],
        syncedAt: null,
        errorCode: "metask_service_unavailable",
        safeDiagnostic: "",
      },
    },
  };
  const partialMarkup = renderSettings(partial, readyModels, {
    initialSection: "account",
  });
  assert.match(partialMarkup, /12 U/);
  assert.match(partialMarkup, /Metask is temporarily unavailable/);
  assert.match(partialMarkup, /Metask User/);

  const usageOnlyFailure = structuredClone(partial);
  usageOnlyFailure.summary.history = {
    availability: "ready",
    startDate: "2025-09-15",
    endDate: "2026-09-15",
    days: [],
    syncedAt: "1789344000000",
    errorCode: "none",
    safeDiagnostic: "",
  };
  assert.match(
    renderSettings(usageOnlyFailure, readyModels, {
      initialSection: "account",
    }),
    /Metask is temporarily unavailable/,
  );

  const stale = structuredClone(partial);
  stale.summary.usage = {
    availability: "stale",
    today: {
      inputTokens: "1",
      outputTokens: "2",
      cacheCreationTokens: "3",
      cacheReadTokens: "4",
      totalTokens: "10",
      actualCostU: "0.5",
    },
    total: { totalTokens: "20", actualCostU: "1" },
    syncedAt: "1789343000000",
    errorCode: "metask_service_unavailable",
    safeDiagnostic: "",
  };
  stale.summary.history = {
    availability: "stale",
    startDate: "2025-09-15",
    endDate: "2026-09-15",
    days: [
      {
        date: "2026-09-14",
        inputTokens: "1",
        outputTokens: "2",
        cacheCreationTokens: "3",
        cacheReadTokens: "4",
        totalTokens: "10",
        actualCostU: "0.5",
      },
    ],
    syncedAt: "1789343000000",
    errorCode: "metask_service_unavailable",
    safeDiagnostic: "",
  };
  assert.match(
    renderSettings(stale, readyModels, { initialSection: "account" }),
    /May be out of date/,
  );

  const simple = structuredClone(readyAccount);
  simple.summary.usageEligibility = "disabled";
  assert.doesNotMatch(
    renderSettings(simple, readyModels, { initialSection: "account" }),
    /Account usage|Refresh account usage|>Balance</,
  );
});

test("Account history calendar fills sparse days and keeps complete week columns", () => {
  const history = {
    availability: "ready",
    startDate: "2025-09-15",
    endDate: "2026-09-15",
    days: [
      {
        date: "2026-09-15",
        inputTokens: "1",
        outputTokens: "2",
        cacheCreationTokens: "3",
        cacheReadTokens: "4",
        totalTokens: "10",
        actualCostU: "0.5",
      },
    ],
    syncedAt: "1789343000000",
    errorCode: "none",
    safeDiagnostic: "",
  };
  const desktop = buildUsageCalendar(history, 53);
  assert.equal(desktop.length, 366);
  assert.equal(desktop[0].date, "2025-09-15");
  assert.equal(desktop[0].totalTokens, "0");
  assert.equal(desktop.at(-1).totalTokens, "10");

  const compact = buildUsageCalendar(history, 13);
  assert.equal(compact.length, 86);
  assert.equal(compact[0].date, "2026-06-22");
  assert.equal(compact.at(-1).date, "2026-09-15");
});

test("unknown Account usage remains actionable without guessing a mode", () => {
  const markup = renderSettings(readyAccount, readyModels, {
    initialSection: "account",
  });
  assert.match(markup, /cannot confirm this account&#x27;s usage mode yet/);
  assert.match(markup, />Refresh account usage</);
  assert.match(markup, />Balance</);
});

test("an unlimited Account concurrency value stays visible", () => {
  const unlimited = { ...readyAccount, concurrencyLimit: 0 };
  const markup = renderSettings(unlimited, readyModels, {
    initialSection: "account",
  });
  assert.match(markup, /Concurrency allowance Unlimited/);
});

test("Account usage formatting preserves decimal precision without number coercion", () => {
  assert.equal(
    formatAccountDecimal("12042000000000001.125"),
    "12,042,000,000,000,001.125",
  );
  assert.equal(formatAccountDecimal("-1.25"), "−1.25");
  assert.equal(formatAccountSyncedAt("18446744073709551615", "en-US"), null);
});

test("Models canonical recovery preserves Account identity and freezes selectors", () => {
  const accountMarkup = renderSettings(readyAccount, readyModels, {
    initialSection: "account",
  });
  const modelsMarkup = renderSettings(
    readyAccount,
    {
      ...readyModels,
      persistenceHealth: "recovery_required",
      errorCode: "persistence_unavailable",
    },
    { initialSection: "models" },
  );
  assert.match(accountMarkup, /Metask User/);
  assert.match(modelsMarkup, /Model configuration needs attention/);
  assert.doesNotMatch(modelsMarkup, />Sign in with Metask</);
  assert.match(modelsMarkup, /id="settings-api"[^>]*disabled/);
  assert.match(modelsMarkup, /id="settings-model"[^>]*disabled/);
  assert.match(modelsMarkup, />Recover model configuration</);
});

test("Models without a persistence capability do not offer destructive reset", () => {
  const markup = renderSettings(
    readyAccount,
    {
      ...readyModels,
      availability: "unavailable",
      persistenceHealth: "unavailable",
      errorCode: "persistence_unavailable",
    },
    { initialSection: "models" },
  );
  assert.doesNotMatch(markup, />Recover model configuration</);
  assert.match(markup, /id="settings-api"[^>]*disabled/);
  assert.match(markup, /id="settings-model"[^>]*disabled/);
});

test("Execution commands never enter the Account busy or error scope", () => {
  assert.doesNotMatch(
    appSource,
    /runAccountCommand\(\(\) =>\s*client\.(?:refreshModelsCatalog|selectMetaskApiKey|configureMetaskSelection|selectModelsDefault|createCustomProvider|updateCustomProvider|replaceCustomProviderCredential|removeCustomProvider|testCustomModel)/,
  );
  assert.match(
    appSource,
    /runExecutionCommand\(\(\) =>\s*client\.selectModelsDefault/,
  );
});

test("Metask model selection refreshes canonical CAS inputs before selecting global default", () => {
  const start = appSource.indexOf("async function selectMetaskModel");
  const end = appSource.indexOf("async function cancelAccountOperation", start);
  assert.ok(start >= 0 && end > start);
  const selectionFlow = appSource.slice(start, end);
  const configure = selectionFlow.indexOf("client.configureMetaskSelection");
  const refresh = selectionFlow.indexOf("client.fetchSnapshot()");
  const selectDefault = selectionFlow.indexOf("client.selectModelsDefault");
  assert.ok(configure >= 0 && refresh > configure && selectDefault > refresh);
  assert.match(
    selectionFlow,
    /expectedSelectionRevision:\s*current\.models\.selectionRevision/,
  );
  assert.match(
    selectionFlow,
    /expectedSourceGeneration:\s*currentProvider\.sourceGeneration/,
  );
  assert.match(
    selectionFlow,
    /expectedCatalogGeneration:\s*currentProvider\.catalogGeneration/,
  );
});

test("opening Account settings has no hidden catalog mutation", () => {
  assert.doesNotMatch(
    appSource,
    /function openSettings[\s\S]*?runAccountCommand\(\(\) => client\.refreshAccountCatalog\(\)\)[\s\S]*?function closeSettings/,
  );
});

test("authorization has one cancel path and no reopen or reauthenticate branch", () => {
  const markup = renderSettings(
    { ...signedOut, state: "authorizing", canCancel: true },
    unavailableModels,
    { initialSection: "account" },
  );
  assert.match(markup, /Finishing Metask sign-in/);
  assert.match(markup, />Cancel</);
  assert.doesNotMatch(
    markup,
    /Open sign-in page again|Sign in again|saved account|previous account/,
  );
});

test("signed-out settings keep local history reachable and expose sign-in", () => {
  const markup = renderSettings(signedOut, unavailableModels, {
    initialSection: "account",
  });
  assert.match(markup, /Sign in to MetaWork/);
  assert.match(markup, />Sign in with Metask</);
  assert.doesNotMatch(markup, /Sign out on this device/);
});

test("authenticated settings project current catalog defaults", () => {
  const accountMarkup = renderSettings(readyAccount, readyModels, {
    initialSection: "account",
  });
  const modelsMarkup = renderSettings(readyAccount, readyModels, {
    initialSection: "models",
  });
  assert.match(accountMarkup, /Metask User/);
  assert.match(accountMarkup, /Sign out on this device/);
  assert.match(modelsMarkup, /Primary/);
  assert.match(modelsMarkup, /Model One/);
  assert.doesNotMatch(modelsMarkup, /<section[^>]*settings-custom-providers/);
});

test("catalog failure remains an authenticated retryable settings state", () => {
  const markup = renderSettings(
    readyAccount,
    {
      ...readyModels,
      providers: [
        {
          ...readyModels.providers[0],
          catalogState: "failed",
          errorCode: "catalog_unavailable",
        },
      ],
      errorCode: "catalog_unavailable",
    },
    { initialSection: "models" },
  );
  assert.match(markup, /Model configuration needs attention/);
  assert.match(markup, /Sync again/);
  assert.doesNotMatch(markup, /Sign in again/);
});

test("cold connection failure exposes reconnect and bounded diagnostics", () => {
  const markup = renderConnectionFailure();
  assert.match(markup, /Reconnect/);
  assert.match(markup, /transport unavailable/);
});
