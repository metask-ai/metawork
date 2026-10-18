import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, createRef, useState } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  NodeFilter: dom.window.NodeFilter,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  HTMLInputElement: dom.window.HTMLInputElement,
  MutationObserver: dom.window.MutationObserver,
  CustomEvent: dom.window.CustomEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
});
const resizeObservers = [];
globalThis.ResizeObserver = class {
  constructor(callback) {
    this.callback = callback;
    this.target = null;
    resizeObservers.push(this);
  }

  observe(target) {
    this.target = target;
  }

  disconnect() {
    this.target = null;
  }

  notify(width = 320) {
    this.callback([
      {
        target: this.target,
        contentRect: { width },
      },
    ]);
  }
};
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

if (!HTMLElement.prototype.hasPointerCapture)
  HTMLElement.prototype.hasPointerCapture = () => false;
if (!HTMLElement.prototype.setPointerCapture)
  HTMLElement.prototype.setPointerCapture = () => undefined;
if (!HTMLElement.prototype.releasePointerCapture)
  HTMLElement.prototype.releasePointerCapture = () => undefined;
if (!HTMLElement.prototype.scrollIntoView)
  HTMLElement.prototype.scrollIntoView = () => undefined;
HTMLButtonElement.prototype.getBoundingClientRect = () => ({
  x: 16,
  y: 16,
  width: 320,
  height: 36,
  top: 16,
  right: 336,
  bottom: 52,
  left: 16,
  toJSON() {
    return this;
  },
});

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { ApprovalModeMenu } = await vite.ssrLoadModule(
  "/src/features/approvals/ApprovalModeMenu.tsx",
);
const { SelectionMenu } = await vite.ssrLoadModule(
  "/src/components/ui/SelectionMenu.tsx",
);
const { useNewTaskDrafts } = await vite.ssrLoadModule(
  "/src/features/composer/useTaskDrafts.ts",
);
const { ComposerFooter } = await vite.ssrLoadModule(
  "/src/features/composer/ComposerFooter.tsx",
);
const { SettingsPage, customProviderEndpointFromBaseUrl } =
  await vite.ssrLoadModule("/src/features/settings/SettingsPage.tsx");
const { GlobalSearch } = await vite.ssrLoadModule(
  "/src/features/search/GlobalSearch.tsx",
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

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function renderMenu(onValueChange, value = "alpha", overrides = {}) {
  return render(
    createElement(SelectionMenu, {
      value,
      options: [
        { value: "alpha", label: "Alpha", description: "/repo/alpha" },
        { value: "blocked", label: "Blocked", disabled: true },
        { value: "bravo", label: "Bravo", description: "/repo/bravo" },
      ],
      placeholder: "Choose workspace",
      ariaLabel: "Switch workspace",
      disabled: false,
      onValueChange,
      ...overrides,
    }),
  );
}

function searchElement(props) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(GlobalSearch, props),
  );
}

test("SelectionMenu portals above Settings and supports keyboard selection", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderMenu((value) => selected.push(value));

  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  await user.click(trigger);
  const listbox = await screen.findByRole("listbox");
  assert.equal(trigger.getAttribute("aria-expanded"), "true");
  assert.ok(listbox);
  const popup = listbox.parentElement;
  assert.equal(popup?.classList.contains("selection-menu-content"), true);
  const positioner = popup?.parentElement;
  assert.ok(positioner);
  assert.equal(positioner.classList.contains("z-[120]"), true);
  assert.equal(positioner.classList.contains("z-50"), false);

  await user.keyboard("{ArrowDown}{ArrowDown}{Enter}");
  assert.deepEqual(selected, ["bravo"]);
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  assert.equal(document.activeElement, trigger);
});

test("Global search keeps focus in its combobox and restores the opener", async () => {
  const selected = [];
  let closed = 0;
  const opener = document.createElement("button");
  document.body.append(opener);
  opener.focus();
  const props = {
    open: true,
    query: "task",
    results: [
      {
        key: "task:1",
        kind: "task",
        title: "First task",
        detail: "alpha",
        workspaceId: "1",
        taskId: "1",
      },
      {
        key: "task:2",
        kind: "task",
        title: "Second task",
        detail: "beta",
        workspaceId: "1",
        taskId: "2",
      },
    ],
    onQuery() {},
    onClose() {
      closed += 1;
    },
    onSelect(result) {
      selected.push(result.key);
    },
  };
  const view = render(searchElement(props));
  const combobox = screen.getByRole("combobox", { name: "Search MetaWork" });
  await waitFor(() => assert.ok(document.activeElement === combobox));
  const options = screen.getAllByRole("option");
  assert.deepEqual(
    options.map((option) => option.tabIndex),
    [-1, -1],
  );
  fireEvent.keyDown(combobox, { key: "ArrowDown" });
  assert.equal(
    combobox.getAttribute("aria-activedescendant"),
    "search-result-1",
  );
  fireEvent.keyDown(combobox, { key: "Enter" });
  assert.deepEqual(selected, ["task:2"]);
  fireEvent.keyDown(document, { key: "Escape" });
  assert.equal(closed, 1);
  view.rerender(searchElement({ ...props, open: false }));
  await waitFor(() => assert.ok(document.activeElement === opener));
  view.unmount();
  opener.remove();
});

test("SelectionMenu closes on Escape and restores trigger focus", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderMenu(() => undefined);

  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  trigger.focus();
  await user.keyboard("{Enter}");
  assert.equal(trigger.getAttribute("aria-expanded"), "true");

  await user.keyboard("{Escape}");
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  assert.equal(document.activeElement, trigger);
});

test("SelectionMenu exposes disabled options without admitting them", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderMenu((value) => selected.push(value));

  await user.click(screen.getByRole("combobox", { name: "Switch workspace" }));
  const blocked = await screen.findByRole("option", { name: "Blocked" });
  assert.equal(blocked.getAttribute("data-disabled"), "");

  await user.click(blocked);
  assert.deepEqual(selected, []);
});

test("SelectionMenu stays controlled while the Host selection is empty", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderMenu((value) => selected.push(value), "");

  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  await user.click(trigger);
  await user.click(await screen.findByRole("option", { name: /Bravo/ }));
  assert.deepEqual(selected, ["bravo"]);
  assert.match(trigger.textContent, /Choose workspace/);

  await user.click(trigger);
  await user.click(await screen.findByRole("option", { name: /Bravo/ }));
  assert.deepEqual(selected, ["bravo", "bravo"]);
  assert.match(trigger.textContent, /Choose workspace/);
});

test("SelectionMenu detailed values expose metadata without making it a field", () => {
  renderMenu(() => undefined, "alpha", {
    valueLayout: "detailed",
    options: [
      {
        value: "alpha",
        label: "Primary API",
        description: "OpenAI",
        descriptionKind: "text",
        trailing: "•••• 1234",
      },
    ],
  });

  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  assert.equal(trigger.dataset.layout, "detailed");
  assert.match(trigger.textContent, /Primary API/);
  assert.match(trigger.textContent, /OpenAI/);
  assert.match(trigger.textContent, /•••• 1234/);
  assert.equal(
    trigger.querySelector(".selection-trigger-detail")?.dataset.kind,
    "text",
  );
});

test("SelectionMenu exposes a visible busy state without a false chevron", () => {
  renderMenu(() => undefined, "alpha", { busy: true });

  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  assert.equal(trigger.getAttribute("aria-busy"), "true");
  assert.ok(trigger.querySelector(".selection-trigger-busy"));
  assert.equal(trigger.querySelector(".selection-trigger-chevron"), null);
});

const readySettingsAccount = {
  state: "authenticated",
  canCancel: false,
  accountId: "account-1",
  displayName: "Metask User",
  emailHint: "m***@example.com",
  phoneHint: "",
  concurrencyLimit: 5,
  errorCode: "none",
  safeDiagnostic: "",
  summary: {
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
  },
};

const readySettingsModels = {
  availability: "ready",
  persistenceHealth: "ready",
  providers: [
    {
      id: "metask",
      displayName: "Metask",
      recommended: true,
      catalogState: "ready",
      principalRef: "account-1",
      models: [
        { id: "model-1", displayName: "Model One" },
        { id: "model-2", displayName: "Model Two" },
      ],
      catalogGeneration: "1",
      sourceGeneration: "1",
      errorCode: "none",
      safeDiagnostic: "",
    },
  ],
  metaskSelection: { sourceId: "metask", modelId: "model-1" },
  metaskSelectionRevision: "1",
  defaultSelection: { sourceId: "metask", modelId: "model-1" },
  selectionRevision: "1",
  operation: "idle",
  errorCode: "none",
  builtinProviderPresets: [],
  customProviders: [],
};

function settingsModels(provider = {}, view = {}) {
  return {
    ...readySettingsModels,
    ...view,
    providers: [{ ...readySettingsModels.providers[0], ...provider }],
  };
}

function settingsElement(account, overrides = {}) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(SettingsPage, {
      account,
      models: readySettingsModels,
      automaticWorkspaceRoot: readyAutomaticWorkspaceRoot,
      customProviderCapabilities: {
        management: true,
        secretCapture: false,
        modelTest: true,
      },
      focusTarget: "title",
      initialSection: "models",
      disabled: false,
      accountDisabled: false,
      executionDisabled: false,
      cancelDisabled: false,
      onBack() {},
      onRefresh() {},
      onResetModels() {
        return Promise.resolve(false);
      },
      onChooseAutomaticWorkspaceRoot() {
        return Promise.resolve(false);
      },
      onResetAutomaticWorkspaceRoot() {
        return Promise.resolve(false);
      },
      onRetryAutomaticWorkspaceRoot() {
        return Promise.resolve(false);
      },
      onCancel() {},
      onSelectModel() {},
      onCreateCustomProvider() {
        return Promise.resolve(false);
      },
      onCreateBuiltinProvider() {
        return Promise.resolve(false);
      },
      onUpdateBuiltinProviderBaseUrl() {
        return Promise.resolve(false);
      },
      onUpdateCustomProvider() {
        return Promise.resolve(false);
      },
      onAddCustomModel() {
        return Promise.resolve(false);
      },
      onRemoveCustomModel() {
        return Promise.resolve(false);
      },
      onRemoveCustomProvider() {
        return Promise.resolve(false);
      },
      onTestCustomModel() {},
      onSelectCustomModel() {},
      onBeginLogin() {},
      onOpenRecharge() {},
      onLogout() {},
      ...overrides,
    }),
  );
}

test("Automatic Workspace location shows the canonical system default path", () => {
  render(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: readyAutomaticWorkspaceRoot,
    }),
  );

  assert.equal(
    screen.getByText("/tmp/MetaWork/Automatic Workspaces").textContent,
    "/tmp/MetaWork/Automatic Workspaces",
  );
  assert.equal(screen.getByText("Default").textContent, "Default");
  assert.equal(screen.queryByText("System default"), null);
});

test("Automatic Workspace write failures distinguish active and unavailable locations", () => {
  const active = render(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        mode: "custom",
        canonicalRoot: "/Volumes/Work/MetaWork",
        health: "write_failed",
      },
    }),
  );
  assert.match(
    screen.getByRole("status").textContent,
    /previously saved location remains active/u,
  );
  active.unmount();

  render(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        mode: null,
        canonicalRoot: null,
        health: "write_failed",
        canReset: true,
      },
    }),
  );
  assert.equal(
    screen.getByText("Location unavailable").textContent,
    "Location unavailable",
  );
  assert.match(
    screen.getByRole("status").textContent,
    /automatic workspaces are paused/u,
  );
});

test("Automatic Workspace command errors stay local and do not duplicate Host health", async () => {
  const ready = render(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      onChooseAutomaticWorkspaceRoot: async () => false,
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Choose folder…" }));
  await waitFor(() =>
    assert.match(
      screen.getByRole("alert").textContent,
      /could not be changed/u,
    ),
  );
  ready.unmount();

  render(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        mode: "custom",
        canonicalRoot: "/Volumes/Missing/MetaWork",
        health: "path_unavailable",
        canReset: true,
        canRetry: true,
      },
      onRetryAutomaticWorkspaceRoot: async () => false,
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() =>
    assert.equal(screen.getByRole("button", { name: "Retry" }).disabled, false),
  );
  assert.match(
    screen.getByRole("status").textContent,
    /folder is unavailable/u,
  );
  assert.equal(screen.queryByRole("alert"), null);
});

test("Automatic Workspace location waits for the canonical snapshot and restores focus", async () => {
  const calls = [];
  const choose = async (generation) => {
    calls.push(generation);
    return "applied";
  };
  const { rerender } = render(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        mode: "custom",
        canonicalRoot: "/Volumes/Work/MetaWork",
        canReset: true,
      },
      onChooseAutomaticWorkspaceRoot: choose,
    }),
  );

  assert.equal(
    screen.getByText("/Volumes/Work/MetaWork").textContent,
    "/Volumes/Work/MetaWork",
  );
  const chooseButton = screen.getByRole("button", { name: "Choose folder…" });
  fireEvent.click(chooseButton);
  await Promise.resolve();
  assert.deepEqual(calls, ["1"]);
  assert.equal(
    screen.getByRole("button", { name: "Choosing…" }).disabled,
    true,
  );
  assert.equal(
    screen.getByText("/Volumes/Work/MetaWork").textContent,
    "/Volumes/Work/MetaWork",
  );

  assert.equal(
    screen.getByRole("button", { name: "Choosing…" }).disabled,
    true,
  );

  rerender(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        generation: "2",
        mode: "custom",
        canonicalRoot: "/Volumes/New/MetaWork",
        canReset: true,
      },
      onChooseAutomaticWorkspaceRoot: choose,
    }),
  );
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(
    screen.getByRole("button", { name: "Choose folder…" }),
    document.activeElement,
  );
  assert.equal(
    screen.getByText("/Volumes/New/MetaWork").textContent,
    "/Volumes/New/MetaWork",
  );

  const cancelCalls = [];
  rerender(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        generation: "2",
        mode: "custom",
        canonicalRoot: "/Volumes/New/MetaWork",
        canReset: true,
      },
      onChooseAutomaticWorkspaceRoot: async (generation) => {
        cancelCalls.push(generation);
        return "cancelled";
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Choose folder…" }));
  await Promise.resolve();
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.deepEqual(cancelCalls, ["2"]);
  assert.equal(
    screen.getByRole("button", { name: "Choose folder…" }),
    document.activeElement,
  );

  const retryCalls = [];
  rerender(
    settingsElement(readySettingsAccount, {
      initialSection: "general",
      automaticWorkspaceRoot: {
        ...readyAutomaticWorkspaceRoot,
        generation: "2",
        mode: "custom",
        canonicalRoot: "/Volumes/New/MetaWork",
        health: "path_unavailable",
        canReset: true,
        canRetry: true,
      },
      onRetryAutomaticWorkspaceRoot: async (generation) => {
        retryCalls.push(generation);
        return "cancelled";
      },
    }),
  );
  assert.match(
    screen.getByRole("status").textContent,
    /folder is unavailable/u,
  );
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await Promise.resolve();
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.deepEqual(retryCalls, ["2"]);
  assert.equal(
    screen.getByRole("button", { name: "Retry" }),
    document.activeElement,
  );
});

function renderSettings(account, overrides = {}) {
  const selections = { model: [] };
  const callbacks = {
    onSelectModel(value) {
      selections.model.push(value);
    },
    ...overrides,
  };
  const view = render(settingsElement(account, callbacks));
  return {
    ...view,
    selections,
    rerenderAccount(nextAccount) {
      view.rerender(settingsElement(nextAccount, callbacks));
    },
    rerenderModels(nextModels) {
      view.rerender(
        settingsElement(account, {
          ...callbacks,
          models: nextModels,
        }),
      );
    },
  };
}

test("Settings exposes Providers only for the complete Host gate", () => {
  const incomplete = renderSettings(readySettingsAccount);
  assert.equal(screen.queryByRole("link", { name: "Providers" }), null);
  incomplete.unmount();

  render(
    settingsElement(readySettingsAccount, {
      customProviderCapabilities: {
        management: true,
        secretCapture: true,
        modelTest: true,
      },
    }),
  );
  fireEvent.click(screen.getByRole("link", { name: "Providers" }));
  assert.ok(screen.getByRole("heading", { name: "Providers" }));
  assert.equal(screen.queryByRole("combobox", { name: "Default model" }), null);
  fireEvent.click(screen.getByRole("button", { name: "Add custom API" }));
  assert.ok(screen.getByRole("heading", { name: "Connect a custom API" }));
  assert.ok(screen.getByRole("button", { name: "Back to providers" }));
});

test("Provider setup keeps Base URL user-owned and submits the protocol endpoint", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const submitted = [];
  render(
    settingsElement(readySettingsAccount, {
      customProviderCapabilities: {
        management: true,
        secretCapture: true,
        modelTest: true,
      },
      onCreateCustomProvider(input) {
        submitted.push(input);
        return Promise.resolve(false);
      },
    }),
  );

  await user.click(screen.getByRole("link", { name: "Providers" }));
  await user.click(screen.getByRole("button", { name: "Add custom API" }));
  assert.equal(screen.queryByRole("radio"), null);

  const baseUrl = screen.getByRole("textbox", { name: "Base URL" });
  assert.equal(baseUrl.value, "");
  assert.equal(baseUrl.placeholder, "https://api.openai.com/v1");
  assert.equal(screen.queryByRole("textbox", { name: /model id/i }), null);
  const apiKey = screen.getByLabelText("API key");
  assert.equal(apiKey.type, "password");

  await user.click(screen.getByRole("combobox", { name: "Protocol" }));
  for (const name of [
    "OpenAI Responses",
    "OpenAI Chat Completions",
    "Anthropic Messages",
    "Gemini Native",
  ]) {
    assert.ok(await screen.findByRole("option", { name }));
  }
  await user.click(screen.getByRole("option", { name: "Anthropic Messages" }));
  assert.equal(baseUrl.value, "");
  assert.equal(baseUrl.placeholder, "https://api.anthropic.com");

  const displayName = screen.getByRole("textbox", { name: "Display name" });
  await user.type(displayName, "My Anthropic");
  await user.type(baseUrl, "https://api.anthropic.com/");
  assert.ok(
    screen.getByText("Request endpoint: https://api.anthropic.com/v1/messages"),
  );
  await user.type(apiKey, "anthropic-secret");
  await user.click(screen.getByRole("button", { name: "Save provider" }));
  assert.deepEqual(submitted, [
    {
      displayName: "My Anthropic",
      protocol: "anthropic_messages",
      normalizedBaseUrl: "https://api.anthropic.com/v1/messages",
      apiKey: "anthropic-secret",
    },
  ]);
});

test("Official Provider setup starts from its official address", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const submitted = [];
  renderSettings(readySettingsAccount, {
    models: {
      ...readySettingsModels,
      builtinProviderPresets: [
        {
          id: "deepseek",
          displayName: "DeepSeek",
          protocol: "openai_chat_completions",
          defaultBaseUrl: "https://api.deepseek.com",
          apiKeyUrl: "https://platform.deepseek.com/api_keys",
          documentationUrl: "https://api-docs.deepseek.com/",
        },
      ],
    },
    customProviderCapabilities: {
      management: true,
      secretCapture: true,
      modelTest: true,
    },
    onCreateBuiltinProvider(input) {
      submitted.push(input);
      return Promise.resolve(false);
    },
  });

  await user.click(screen.getByRole("link", { name: "Providers" }));
  assert.ok(screen.getByText("Model providers"));
  await user.click(screen.getByRole("button", { name: "Configure" }));
  assert.ok(screen.getByRole("heading", { name: "DeepSeek" }));
  assert.equal(screen.queryByRole("combobox", { name: "Protocol" }), null);
  assert.equal(screen.queryByRole("textbox", { name: "Base URL" }), null);
  assert.equal(
    screen.getByRole("button", { name: "Save provider" }).disabled,
    true,
  );

  assert.ok(screen.getByText("https://api.deepseek.com"));
  await user.click(screen.getByRole("button", { name: "Use another address" }));
  assert.equal(
    screen.getByRole("textbox", { name: "Base URL" }).value,
    "https://api.deepseek.com",
  );
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  const apiKey = screen.getByLabelText("API key");
  await user.type(apiKey, "deepseek-secret");
  assert.equal(
    screen.getByRole("link", { name: "Get an API key" }).href,
    "https://platform.deepseek.com/api_keys",
  );
  await user.click(screen.getByRole("button", { name: "Save provider" }));
  assert.deepEqual(submitted, [
    {
      providerId: "deepseek",
      baseUrl: "https://api.deepseek.com",
      apiKey: "deepseek-secret",
    },
  ]);
});

test("Official Provider address override is explicit and separate from its credential", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const updates = [];
  renderSettings(readySettingsAccount, {
    models: {
      ...readySettingsModels,
      builtinProviderPresets: [
        {
          id: "deepseek",
          displayName: "DeepSeek",
          protocol: "openai_chat_completions",
          defaultBaseUrl: "https://api.deepseek.com",
          apiKeyUrl: "https://platform.deepseek.com/api_keys",
          documentationUrl: "https://api-docs.deepseek.com/",
        },
      ],
      customProviders: [
        {
          id: "provider-deepseek",
          builtinProviderId: "deepseek",
          displayName: "DeepSeek",
          protocol: "openai_chat_completions",
          normalizedBaseUrl: "https://api.deepseek.com/chat/completions",
          state: "configuring",
          credentialStatus: "ready",
          enabled: true,
          models: [],
          providerRevision: "7",
          sourceGeneration: "3",
          catalogGeneration: "5",
        },
      ],
    },
    customProviderCapabilities: {
      management: true,
      secretCapture: true,
      modelTest: true,
    },
    onUpdateBuiltinProviderBaseUrl(input) {
      updates.push(input);
      return Promise.resolve(false);
    },
  });

  await user.click(screen.getByRole("link", { name: "Providers" }));
  await user.click(screen.getByRole("button", { name: "Manage" }));
  assert.equal(screen.queryByRole("textbox", { name: "Base URL" }), null);
  await user.click(screen.getByRole("button", { name: "Use another address" }));
  const baseUrl = screen.getByRole("textbox", { name: "Base URL" });
  await user.clear(baseUrl);
  await user.type(baseUrl, "https://gateway.example.com/deepseek/v1");
  assert.ok(
    screen.getByText(
      "Future model requests will send this Provider's API key to gateway.example.com.",
    ),
  );
  await user.click(screen.getByRole("button", { name: "Save provider" }));
  assert.deepEqual(updates, [
    {
      providerId: "provider-deepseek",
      expectedProviderRevision: "7",
      baseUrl: "https://gateway.example.com/deepseek/v1",
    },
  ]);
});

test("Provider API key update lives inside Edit and submits the exact user input", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const replacements = [];
  renderSettings(readySettingsAccount, {
    customProviderCapabilities: {
      management: true,
      secretCapture: true,
      modelTest: true,
    },
    models: {
      ...readySettingsModels,
      customProviders: [
        {
          id: "provider-1",
          builtinProviderId: null,
          displayName: "Team OpenAI",
          protocol: "openai_responses",
          normalizedBaseUrl: "https://api.openai.com/v1/responses",
          state: "configuring",
          credentialStatus: "ready",
          enabled: true,
          models: [],
          providerRevision: "7",
          sourceGeneration: "3",
          catalogGeneration: "5",
        },
      ],
    },
    onReplaceCustomProviderCredential(...input) {
      replacements.push(input);
      return Promise.resolve(false);
    },
  });

  await user.click(screen.getByRole("link", { name: "Providers" }));
  assert.equal(screen.queryByRole("button", { name: "Update API key" }), null);
  await user.click(screen.getByRole("button", { name: "Edit" }));
  await user.click(screen.getByRole("button", { name: "Update API key" }));
  const apiKey = screen.getByLabelText("API key");
  assert.equal(apiKey.type, "password");
  assert.equal(apiKey.value, "");
  assert.equal(apiKey.autocomplete, "off");

  await user.type(apiKey, "  exact replacement secret  ");
  await user.click(screen.getByRole("button", { name: "Save API key" }));
  assert.deepEqual(replacements, [
    ["provider-1", "7", "  exact replacement secret  "],
  ]);
});

test("Provider Base URLs map to all four existing protocol endpoints", () => {
  assert.equal(
    customProviderEndpointFromBaseUrl(
      "openai_responses",
      "https://api.openai.com/v1/",
    ),
    "https://api.openai.com/v1/responses",
  );
  assert.equal(
    customProviderEndpointFromBaseUrl(
      "openai_chat_completions",
      "https://api.openai.com/v1",
    ),
    "https://api.openai.com/v1/chat/completions",
  );
  assert.equal(
    customProviderEndpointFromBaseUrl(
      "anthropic_messages",
      "https://api.anthropic.com",
    ),
    "https://api.anthropic.com/v1/messages",
  );
  assert.equal(
    customProviderEndpointFromBaseUrl(
      "gemini_native",
      "https://generativelanguage.googleapis.com",
    ),
    "https://generativelanguage.googleapis.com",
  );
});

test("Settings moves directly from Provider to model selection", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount);

  assert.equal(screen.queryByRole("combobox", { name: "API key" }), null);
  assert.match(screen.getByText("Models 2").textContent, /Models 2/);
  await user.click(screen.getByRole("combobox", { name: "Default model" }));
  await user.click(await screen.findByRole("option", { name: /Model Two/ }));
  assert.deepEqual(view.selections.model, ["model-2"]);

  view.rerenderModels(
    settingsModels(
      {
        catalogState: "loading",
        models: [{ id: "model-2", displayName: "Model Two" }],
      },
      { operation: "refreshing_catalog" },
    ),
  );
  assert.match(screen.getByRole("status").textContent, /Preparing Model Two/);
  assert.match(
    screen.getByRole("status").textContent,
    /current default model, model-1/i,
  );
  const model = screen.getByRole("combobox", { name: "Default model" });
  assert.equal(model.getAttribute("aria-busy"), "true");
  assert.equal(model.hasAttribute("disabled"), true);

  view.rerenderModels(
    settingsModels(
      { models: [{ id: "model-2", displayName: "Model Two" }] },
      {
        metaskSelection: { sourceId: "metask", modelId: "model-2" },
        defaultSelection: { sourceId: "metask", modelId: "model-2" },
      },
    ),
  );
  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model Two/,
  );
  assert.equal(screen.queryByText("Pending change"), null);
  assert.equal(screen.queryByRole("status"), null);
});

test("Settings keeps a model choice visibly pending without declaring it committed", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount);

  await user.click(screen.getByRole("combobox", { name: "Default model" }));
  await user.click(await screen.findByRole("option", { name: /Model Two/ }));

  assert.deepEqual(view.selections.model, ["model-2"]);
  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model Two/,
  );
  assert.equal(readySettingsModels.metaskSelection.modelId, "model-1");
});

test("Settings keeps Metask available while a custom provider is the default", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const customSelections = [];
  const view = renderSettings(readySettingsAccount, {
    models: {
      ...readySettingsModels,
      defaultSelection: { sourceId: "provider-1", modelId: "gpt-5" },
      customProviders: [
        {
          id: "provider-1",
          builtinProviderId: null,
          displayName: "Team OpenAI",
          protocol: "openai_chat_completions",
          normalizedBaseUrl: "https://api.openai.com/v1/chat/completions",
          state: "ready",
          credentialStatus: "ready",
          enabled: true,
          models: [
            {
              id: "gpt-5",
              displayName: "GPT-5",
              metadata: readySettingsModels.providers[0].models[0].metadata,
              metadataProvenance: "user_declared",
              testStatus: "connected",
              ready: true,
            },
            {
              id: "gpt-5-mini",
              displayName: "GPT-5 mini",
              metadata: readySettingsModels.providers[0].models[0].metadata,
              metadataProvenance: "user_declared",
              testStatus: "connected",
              ready: true,
            },
          ],
          providerRevision: "1",
          sourceGeneration: "1",
          catalogGeneration: "1",
        },
      ],
    },
    onSelectCustomModel(...selection) {
      customSelections.push(selection);
    },
  });

  const provider = screen.getByRole("combobox", { name: "Provider" });
  const defaultModel = screen.getByRole("combobox", {
    name: "Default model",
  });
  assert.match(provider.textContent, /Team OpenAI/);
  assert.match(defaultModel.textContent, /GPT-5/);
  await user.click(defaultModel);
  await user.click(await screen.findByRole("option", { name: /GPT-5 mini/ }));
  assert.deepEqual(customSelections, [["provider-1", "1", "gpt-5-mini"]]);

  await user.click(provider);
  await user.click(await screen.findByRole("option", { name: /Metask/ }));
  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Choose a model/,
  );
  await user.click(screen.getByRole("combobox", { name: "Default model" }));
  await user.click(await screen.findByRole("option", { name: /Model One/ }));
  assert.deepEqual(view.selections.model, ["model-1"]);
});

test("Models keeps adding and removing models after the first provider model", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const additions = [];
  const removals = [];
  renderSettings(readySettingsAccount, {
    models: {
      ...readySettingsModels,
      customProviders: [
        {
          id: "provider-multi",
          builtinProviderId: null,
          displayName: "Multi-model provider",
          protocol: "openai_responses",
          normalizedBaseUrl: "https://api.openai.com/v1/responses",
          state: "configuring",
          credentialStatus: "ready",
          enabled: true,
          models: [
            {
              id: "model-a",
              displayName: "Model A",
              metadata: {},
              metadataProvenance: "unknown",
              testStatus: "untested",
              ready: false,
            },
          ],
          providerRevision: "3",
          sourceGeneration: "5",
          catalogGeneration: "7",
        },
      ],
    },
    onAddCustomModel(...input) {
      additions.push(input);
      return Promise.resolve(false);
    },
    onRemoveCustomModel(...input) {
      removals.push(input);
      return Promise.resolve(false);
    },
  });

  await user.click(screen.getByRole("combobox", { name: "Provider" }));
  await user.click(
    await screen.findByRole("option", { name: /Multi-model provider/ }),
  );

  const modelId = screen.getByRole("textbox", { name: "Model ID" });
  await user.type(modelId, "gpt-5.6-sol");
  await user.click(screen.getByRole("button", { name: "Add model" }));
  assert.deepEqual(additions, [["provider-multi", "3", "7", "gpt-5.6-sol"]]);

  await user.click(screen.getByRole("button", { name: "Remove" }));
  const removeButtons = screen.getAllByRole("button", { name: "Remove" });
  await user.click(removeButtons[removeButtons.length - 1]);
  assert.deepEqual(removals, [["provider-multi", "3", "7", "model-a"]]);
});

test("Settings keeps Account cancellation independent from Models loading", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let cancellations = 0;
  renderSettings(
    { ...readySettingsAccount, state: "authorizing", canCancel: true },
    {
      models: settingsModels(
        { catalogState: "loading", models: [] },
        { operation: "refreshing_catalog" },
      ),
      onCancel() {
        cancellations += 1;
      },
    },
  );

  assert.equal(
    screen
      .getByRole("combobox", { name: "Default model" })
      .hasAttribute("disabled"),
    true,
  );

  await user.click(screen.getByRole("link", { name: "General" }));
  assert.equal(
    screen.getByRole("combobox", { name: "Language" }).hasAttribute("disabled"),
    false,
  );
  assert.equal(
    screen.getByRole("link", { name: "Account" }).hasAttribute("aria-disabled"),
    false,
  );

  await user.click(screen.getByRole("link", { name: "Account" }));
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(cancellations, 1);
});

test("Settings reports Models failure without changing Account identity", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount, {
    models: settingsModels({}, { errorCode: "catalog_unavailable" }),
    initialSection: "models",
  });

  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model One/,
  );
  assert.match(
    screen.getByRole("alert").textContent,
    /Model configuration needs attention/,
  );

  await user.click(screen.getByRole("link", { name: "Account" }));
  assert.match(screen.getByText("Metask User").textContent, /Metask User/);
  await user.click(screen.getByRole("link", { name: "Models" }));

  view.rerenderModels(readySettingsModels);
  assert.equal(screen.queryByRole("alert"), null);
});

test("Settings switches between one section page at a time", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderSettings(readySettingsAccount, { initialSection: "general" });
  assert.equal(
    screen.getByRole("link", { name: "General" }).getAttribute("aria-current"),
    "location",
  );

  assert.ok(screen.getByRole("heading", { name: "General" }));
  assert.equal(screen.queryByRole("heading", { name: "Account" }), null);

  await user.click(screen.getByRole("link", { name: "Account" }));
  assert.equal(
    screen.getByRole("link", { name: "Account" }).getAttribute("aria-current"),
    "location",
  );
  assert.ok(screen.getByRole("heading", { name: "Account" }));
  assert.equal(screen.queryByRole("heading", { name: "General" }), null);

  await user.click(screen.getByRole("link", { name: "Models" }));
  assert.equal(
    screen.getByRole("link", { name: "Models" }).getAttribute("aria-current"),
    "location",
  );
  assert.ok(screen.getByRole("heading", { name: "Models" }));
  assert.equal(screen.queryByRole("heading", { name: "Account" }), null);
});

test("Settings keeps permission choices out of its navigation and pages", () => {
  renderSettings(readySettingsAccount, { initialSection: "general" });

  assert.equal(screen.queryByRole("link", { name: "Permissions" }), null);
  assert.equal(
    screen.queryByRole("combobox", { name: "Default for new Tasks" }),
    null,
  );
  assert.equal(document.querySelector(".permission-policy-boundary"), null);
  assert.ok(screen.getByRole("combobox", { name: "Language" }));
});

test("Settings closes on Escape at the surface boundary", () => {
  let closed = 0;
  renderSettings(readySettingsAccount, {
    onBack() {
      closed += 1;
    },
  });
  const page = screen.getByRole("dialog", { name: "Settings" });
  fireEvent.keyDown(page, { key: "Escape" });
  assert.equal(closed, 1);
});

function renderComposer(overrides = {}) {
  const textareaRef = createRef();
  let submissions = 0;
  let setDraftFromTest = null;
  const initialDraft = overrides.draft ?? {
    kind: "text",
    text: "请检查当前实现",
  };
  const externalOnDraftChange = overrides.onDraftChange;
  function ComposerHarness() {
    const [draft, setDraft] = useState(initialDraft);
    setDraftFromTest = setDraft;
    return createElement(ComposerFooter, {
      textareaRef,
      archived: false,
      closing: false,
      closed: false,
      unavailable: false,
      unavailableReason: null,
      draft,
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
      initialSection: "permissions",
      slashCommands: [],
      composeDisabled: false,
      canSubmit: true,
      runInFlight: false,
      accessRequired: false,
      workspaceMissing: false,
      workspaceLabel: "metawork",
      workspaceTitle: "/repo/metawork",
      workspaceOptions: [],
      selectedWorkspaceOptionId: "1",
      workspaceEditable: false,
      modelLabel: null,
      modelOptions: [],
      selectedModelId: "",
      modelEditable: false,
      modelSelectionDisabled: false,
      modelSelectionPending: false,
      modelContextTitle: "",
      defaultSelectionMissing: false,
      defaultRecoveryDisabled: false,
      actionDisabled: false,
      onSubmit() {
        submissions += 1;
      },
      onChooseAttachments() {},
      onRemoveAttachment() {},
      onSlashCommand() {},
      onRefreshSkillCatalog() {},
      onConfirmAccess() {},
      onSelectWorkspace() {},
      onSelectModel() {},
      onOpenModels() {},
      ...overrides,
      draft,
      onDraftChange(value) {
        setDraft(value);
        externalOnDraftChange?.(value);
      },
    });
  }
  render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(ComposerHarness),
    ),
  );
  return {
    textarea: textareaRef.current,
    submissions: () => submissions,
    setDraft(value) {
      assert.ok(setDraftFromTest);
      setDraftFromTest(value);
    },
  };
}

test("Task model trigger keeps the model name when the selection leaves the catalog", () => {
  for (const options of [
    [],
    [
      {
        selectionId: "selected",
        displayName: "Catalog label",
        triggerLabel: "Catalog trigger",
      },
    ],
  ]) {
    renderComposer({
      modelEditable: true,
      modelLabel: "Task model",
      selectedModelId: "selected",
      modelOptions: options,
    });
    assert.equal(
      document.querySelector(".composer-model-trigger .selection-trigger-value")
        .textContent,
      "Task model",
    );
    cleanup();
  }
});

test("detached Conversation uses the ordinary send action", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const composer = renderComposer({
    unavailable: true,
    unavailableReason: "session_recovery_required",
    composeDisabled: false,
  });
  assert.equal(
    screen.queryByRole("button", { name: "Restore conversation" }),
    null,
  );
  await user.click(screen.getByRole("button", { name: "Send" }));
  assert.equal(composer.submissions(), 1);
});

test("Composer explains a missing executable default and opens Models", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let opens = 0;
  renderComposer({
    canSubmit: false,
    defaultSelectionMissing: true,
    onOpenModels() {
      opens += 1;
    },
  });

  assert.match(
    screen.getByRole("status").textContent,
    /No executable default model is selected/,
  );
  const recovery = screen.getByRole("button", {
    name: "Open Models",
  });
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  await user.click(recovery);
  assert.equal(opens, 1);
});

test("Composer disables default recovery while an execution command is active", () => {
  renderComposer({
    defaultSelectionMissing: true,
    defaultRecoveryDisabled: true,
  });
  assert.equal(
    screen.getByRole("button", { name: "Open Models" }).disabled,
    true,
  );
});

test("Composer does not show Models recovery for a normal default", () => {
  renderComposer({ defaultSelectionMissing: false });
  assert.equal(screen.queryByRole("button", { name: "Open Models" }), null);
});

test("Composer Enter handling does not submit an active IME composition", () => {
  const composer = renderComposer();
  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: true,
  });
  assert.equal(composer.submissions(), 0);

  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: false,
  });
  assert.equal(composer.submissions(), 1);
});

test("Composer recalculates its height when its rendered width changes", () => {
  const observerCount = resizeObservers.length;
  const composer = renderComposer();
  const observer = resizeObservers.at(-1);
  assert.equal(resizeObservers.length, observerCount + 1);
  assert.equal(observer.target, composer.textarea);

  Object.defineProperty(composer.textarea, "scrollHeight", {
    configurable: true,
    value: 126,
  });
  observer.notify(420);
  assert.equal(composer.textarea.style.height, "126px");
  assert.equal(composer.textarea.style.overflowY, "hidden");
});

test("Slash menu is an IME-safe combobox and consumes Command Enter locally", () => {
  const commands = [{ name: "new", enabled: true, disabledReason: null }];
  const chosen = [];
  const composer = renderComposer({
    draft: { kind: "text", text: "/" },
    slashCommands: commands,
    canSubmit: true,
    onSlashCommand: (command) => chosen.push(command),
  });
  assert.equal(composer.textarea.getAttribute("role"), "combobox");
  assert.equal(composer.textarea.getAttribute("aria-expanded"), "true");
  assert.ok(screen.getByRole("listbox"));
  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: true,
  });
  assert.deepEqual(chosen, []);
  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: false,
  });
  assert.deepEqual(chosen, ["new"]);
  assert.equal(composer.submissions(), 0);
});

test("Slash menu translates command-specific disabled reasons without repeating its group label", () => {
  renderComposer({
    draft: { kind: "text", text: "/" },
    slashCommands: [
      {
        name: "new",
        enabled: false,
        disabledReason: "already_new_task",
      },
      { name: "compact", enabled: false, disabledReason: "no_history" },
    ],
  });
  assert.match(
    screen.getByRole("option", { name: /New task/ }).textContent,
    /A new task draft is already open/,
  );
  assert.match(
    screen.getByRole("option", { name: /Compact context/ }).textContent,
    /Run the task once before compacting context/,
  );
  assert.equal(screen.getAllByText("Commands").length, 1);
});

test("keyboard Skill selection moves focus into the structured draft", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "/review" },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      selectionRevision: "3",
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "Review a target",
          argumentNames: ["target"],
          maxValues: 1,
          enabled: true,
        },
      ],
      issues: [],
    },
  });
  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: false,
  });
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(
    document.activeElement,
    screen.getByRole("textbox", { name: "target" }),
  );
});

test("a no-argument Skill moves keyboard focus to the real Send action", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "/review" },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      selectionRevision: "3",
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "Review the current task",
          argumentNames: [],
          maxValues: 0,
          enabled: true,
        },
      ],
      issues: [],
    },
  });
  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: false,
  });
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(
    document.activeElement,
    screen.getByRole("button", { name: "Send" }),
  );
});

test("unknown leading Slash text cannot leak through ordinary submit", () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "/not-a-command" },
    slashCommands: [],
    canSubmit: true,
  });
  const send = screen.getByRole("button", { name: "Send" });
  assert.equal(send.disabled, true);
  fireEvent.keyDown(composer.textarea, {
    key: "Escape",
    isComposing: false,
  });
  fireEvent.keyDown(composer.textarea, {
    key: "Enter",
    shiftKey: false,
    isComposing: false,
  });
  assert.equal(composer.submissions(), 0);
});

test("a positional Skill tail remains visible even without a named label", () => {
  renderComposer({
    draft: {
      kind: "skill",
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentNames: [],
      argumentValues: ["src/main.zig"],
      maxValues: 1,
    },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      selectionRevision: "3",
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "",
          argumentNames: [],
          maxValues: 1,
          enabled: true,
        },
      ],
      issues: [],
    },
  });
  assert.equal(
    screen.getByRole("textbox", { name: "Argument 1" }).value,
    "src/main.zig",
  );
});

test("variadic Skills expose unnamed argument slots up to maxValues", () => {
  const changes = [];
  renderComposer({
    draft: {
      kind: "skill",
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentNames: [],
      argumentValues: [],
      maxValues: 3,
    },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      selectionRevision: "3",
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "",
          argumentNames: [],
          maxValues: 3,
          enabled: true,
        },
      ],
      issues: [],
    },
    onDraftChange: (draft) => changes.push(draft),
  });
  assert.equal(screen.getByRole("textbox", { name: "Argument 1" }).value, "");
  fireEvent.click(screen.getByRole("button", { name: "Add argument" }));
  assert.deepEqual(changes, [
    {
      kind: "skill",
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentNames: [],
      argumentValues: ["", ""],
      maxValues: 3,
    },
  ]);
});

test("multimodal drafts expose ordered removable chips and preserve keyboard focus", async () => {
  const removed = [];
  let composer;
  composer = renderComposer({
    attachmentsEnabled: true,
    attachmentModelWarning: "image",
    draft: {
      kind: "multimodal",
      text: "Compare these files",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "image",
          format: "png",
          displayName: "diagram.png",
          sizeBytes: "1536",
        },
        {
          token: "b".repeat(48),
          kind: "image",
          format: "webp",
          displayName: "brief.webp",
          sizeBytes: "2048",
        },
      ],
    },
    onRemoveAttachment(token) {
      removed.push(token);
    },
  });
  assert.equal(composer.textarea.value, "Compare these files");
  assert.equal(screen.getAllByRole("listitem").length, 2);
  assert.match(
    screen.getByText("diagram.png").parentElement.textContent,
    /2 KB/,
  );
  assert.match(
    screen.getByRole("status").textContent,
    /image input is unsupported/,
  );
  fireEvent.click(screen.getByRole("button", { name: "Remove diagram.png" }));
  assert.deepEqual(removed, ["a".repeat(48)]);
  act(() =>
    composer.setDraft({
      kind: "multimodal",
      text: "Compare these files",
      attachments: [
        {
          token: "b".repeat(48),
          kind: "image",
          format: "webp",
          displayName: "brief.webp",
          sizeBytes: "2048",
        },
      ],
    }),
  );
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(
    document.activeElement,
    screen.getByRole("button", { name: "Remove brief.webp" }),
  );
});

test("removing the last attachment returns keyboard focus to the picker", async () => {
  const removed = [];
  let composer;
  composer = renderComposer({
    attachmentsEnabled: true,
    draft: {
      kind: "multimodal",
      text: "",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "image",
          format: "png",
          displayName: "diagram.png",
          sizeBytes: "1536",
        },
      ],
    },
    onRemoveAttachment(token) {
      removed.push(token);
    },
  });

  fireEvent.click(screen.getByRole("button", { name: "Remove diagram.png" }));
  assert.deepEqual(removed, ["a".repeat(48)]);
  act(() => composer.setDraft({ kind: "text", text: "" }));
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(
    document.activeElement,
    screen.getByRole("button", { name: "Add files" }),
  );
});

test("Office file drafts are sendable with an explicit instruction", () => {
  renderComposer({
    attachmentsEnabled: true,
    canSubmit: true,
    draft: {
      kind: "multimodal",
      text: "Use this file",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "file",
          displayName: "report.docx",
          sizeBytes: "128",
        },
      ],
    },
  });
  assert.equal(screen.queryByRole("status"), null);
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false);
});

test("ZIP file drafts quietly require an explicit user instruction", () => {
  renderComposer({
    attachmentsEnabled: true,
    canSubmit: false,
    draft: {
      kind: "multimodal",
      text: " \n",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "file",
          displayName: "archive.zip",
          sizeBytes: "128",
        },
      ],
    },
  });
  assert.equal(screen.queryByRole("status"), null);
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
});

test("file size rejection displays the Host limit and preserves ready chips", () => {
  renderComposer({
    attachmentsEnabled: true,
    attachmentMaxFileBytes: "3750000",
    attachmentError: "file_too_large",
    draft: {
      kind: "multimodal",
      text: "keep draft",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "file",
          displayName: "ready.txt",
          sizeBytes: "25",
        },
      ],
    },
  });
  assert.match(screen.getByRole("alert").textContent, /3\.75 MB/);
  assert.ok(screen.getByText("ready.txt"));
});

test("text file size rejection remains actionable", () => {
  renderComposer({
    attachmentsEnabled: true,
    attachmentMaxFileBytes: "100000000",
    attachmentError: "text_file_too_large",
  });
  assert.match(screen.getByRole("alert").textContent, /100 MB/);
});

function pasteItems(target, items) {
  const event = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      items,
      get files() {
        throw new Error("Do not extract the same clipboard files twice");
      },
      getData: () => "companion clipboard text",
    },
  });
  fireEvent(target, event);
  return event;
}

function imageItem(file) {
  return { kind: "file", type: file.type, getAsFile: () => file };
}

test("image paste appends one ordered batch and leaves existing text and selection intact", () => {
  const received = [];
  const composer = renderComposer({
    attachmentsEnabled: true,
    onPasteImages: (files) => received.push(files),
  });
  composer.textarea.focus();
  composer.textarea.setSelectionRange(1, 3);
  const before = composer.textarea.value;
  const png = new File(["png bytes"], "screenshot.png", { type: "image/png" });
  const jpeg = new File(["jpeg bytes"], "capture.jpg", { type: "image/jpeg" });
  let reads = 0;
  const event = pasteItems(composer.textarea, [
    { kind: "string", type: "text/html" },
    {
      kind: "file",
      type: "application/pdf",
      getAsFile: () => assert.fail("Only image candidates are read"),
    },
    {
      kind: "file",
      type: png.type,
      getAsFile: () => {
        reads++;
        return png;
      },
    },
    imageItem(jpeg),
  ]);
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(received, [[png, jpeg]]);
  assert.equal(reads, 1);
  assert.equal(composer.textarea.value, before);
  assert.equal(composer.textarea.selectionStart, 1);
  assert.equal(composer.textarea.selectionEnd, 3);
  assert.equal(composer.submissions(), 0);
});

test("image paste preserves File bytes and MIME and supplies only a missing display name", async () => {
  const received = [];
  const composer = renderComposer({
    onPasteImages: (files) => received.push(files),
  });
  const file = new File([new Uint8Array([0, 255, 11])], "", {
    type: "image/webp",
    lastModified: 42,
  });
  pasteItems(composer.textarea, [imageItem(file)]);
  assert.equal(received.length, 1);
  const pasted = received[0][0];
  assert.ok(pasted.name.length > 0);
  assert.equal(pasted.type, file.type);
  assert.equal(pasted.lastModified, file.lastModified);
  assert.deepEqual(await pasted.arrayBuffer(), await file.arrayBuffer());
});

test("ordinary text paste, other fields and a disabled Composer are not intercepted", () => {
  const composer = renderComposer({
    onPasteImages: () => assert.fail("No image admission"),
  });
  const text = pasteItems(composer.textarea, [
    { kind: "string", type: "text/plain" },
  ]);
  assert.equal(text.defaultPrevented, false);
  const outside = document.createElement("textarea");
  document.body.append(outside);
  const file = new File(["png"], "a.png", { type: "image/png" });
  assert.equal(pasteItems(outside, [imageItem(file)]).defaultPrevented, false);
  outside.remove();
  cleanup();
  const disabled = renderComposer({
    composeDisabled: true,
    onPasteImages: () => assert.fail("Disabled Composer"),
  });
  assert.equal(
    pasteItems(disabled.textarea, [imageItem(file)]).defaultPrevented,
    false,
  );
});

test("file drag highlights the active Composer and hands the drop files to its input owner", () => {
  const received = [];
  renderComposer({
    attachmentsEnabled: true,
    onDropFiles: (files) => received.push(files),
  });
  const file = new File(["abc"], "notes.txt");
  const dataTransfer = { types: ["Files"], dropEffect: "none", files: [file] };
  const enter = new window.Event("dragenter", {
    bubbles: true,
    cancelable: true,
  });
  Object.defineProperty(enter, "dataTransfer", { value: dataTransfer });
  fireEvent(document, enter);
  assert.ok(screen.getByText("Drop files to add"));
  assert.equal(
    document.querySelector(".composer-shell").dataset.fileDragActive,
    "true",
  );

  const drop = new window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: dataTransfer });
  fireEvent(document, drop);
  assert.equal(screen.queryByText("Drop files to add"), null);
  assert.deepEqual(received, [[file]]);
});

test("receiving offers cancellation, keeps text editable and rejects another drop", () => {
  let cancelled = 0;
  const composer = renderComposer({
    attachmentsEnabled: true,
    attachmentBusy: true,
    canSubmit: false,
    onCancelAttachments: () => {
      cancelled++;
    },
    onDropFiles: () => assert.fail("busy composer must not admit files"),
  });
  assert.equal(composer.textarea.disabled, false);
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  fireEvent.click(screen.getByRole("button", { name: "Cancel adding files" }));
  assert.equal(cancelled, 1);
  const drop = new window.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", {
    value: { types: ["Files"], files: [new File(["abc"], "a.txt")] },
  });
  fireEvent(document, drop);
});

test("long ordinary text stays intact and oversized text disables both send paths", async () => {
  const changes = [];
  const composer = renderComposer({
    onDraftChange: (draft) => changes.push(draft),
  });
  assert.equal(composer.textarea.hasAttribute("maxlength"), false);
  const text = "error stack\n".repeat(24000);
  fireEvent.change(composer.textarea, { target: { value: text } });
  assert.equal(composer.textarea.value, text);
  assert.equal(changes.at(-1).text, text);
  assert.match(
    screen.getByRole("status").textContent,
    /256 KiB.*full draft.*100 MB/,
  );
  const send = screen.getByRole("button", { name: "Send" });
  assert.equal(send.disabled, true);
  fireEvent.keyDown(composer.textarea, { key: "Enter" });
  fireEvent.click(send);
  assert.equal(composer.submissions(), 0);
  fireEvent.change(composer.textarea, {
    target: { value: "x".repeat(256 * 1024) },
  });
  assert.equal(send.disabled, false);
  fireEvent.keyDown(composer.textarea, { key: "Enter" });
  assert.equal(composer.submissions(), 1);
});

test("cancelling keeps one disabled action and the existing text editable", () => {
  const composer = renderComposer({
    attachmentsEnabled: true,
    attachmentBusy: true,
    attachmentCancelling: true,
    canSubmit: false,
    onCancelAttachments: () => assert.fail("duplicate cancel"),
  });
  const cancel = screen.getByRole("button", {
    name: "Cancelling file addition…",
  });
  assert.equal(cancel.disabled, true);
  assert.equal(cancel.title, "Cancelling file addition…");
  assert.equal(composer.textarea.disabled, false);
  fireEvent.click(cancel);
});
test("attachment draft handoff is synchronous and rejects changed or missing targets", () => {
  let drafts;
  function Harness({ id }) {
    drafts = useNewTaskDrafts(id);
    return null;
  }
  const view = render(createElement(Harness, { id: "attachment-handoff-one" }));
  const oldCommit = drafts.commitDraft;
  const first = {
    kind: "multimodal",
    text: "instruction",
    attachments: [
      {
        token: "a".repeat(48),
        kind: "file",
        displayName: "a.txt",
        sizeBytes: "3",
      },
    ],
  };
  act(() => {
    assert.equal(drafts.commitDraft(null, first), false);
    assert.equal(drafts.commitDraft("attachment-handoff-one", first), true);
    const current = drafts.currentDraft("attachment-handoff-one");
    assert.deepEqual(current, first);
    const second = {
      ...current,
      attachments: [
        ...current.attachments,
        {
          token: "b".repeat(48),
          kind: "file",
          displayName: "b.txt",
          sizeBytes: "3",
        },
      ],
    };
    assert.equal(drafts.commitDraft("attachment-handoff-one", second), true);
    assert.equal(
      drafts.currentDraft("attachment-handoff-one").attachments.length,
      2,
    );
  });
  view.rerender(createElement(Harness, { id: "attachment-handoff-two" }));
  act(() => {
    assert.equal(oldCommit("attachment-handoff-one", first), false);
    assert.equal(drafts.currentDraft("attachment-handoff-one"), null);
  });
  view.rerender(createElement(Harness, { id: "attachment-handoff-one" }));
  act(() => {
    drafts.invalidateAttachments();
    assert.deepEqual(drafts.currentDraft("attachment-handoff-one"), {
      kind: "text",
      text: "instruction",
      attachmentsReloadRequired: true,
    });
  });
});

function approvalElement(task, overrides = {}) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(ApprovalModeMenu, {
      task,
      request: null,
      disabled: false,
      onSelect() {},
      onRefresh() {},
      ...overrides,
    }),
  );
}
const approvalTask = {
  id: "3",
  approvalMode: "manual",
  approvalRevision: "1",
  availableApprovalModes: ["manual", "auto_review", "full_access"],
  approvalChange: null,
  approvalResult: null,
  activeOperation: { kind: "run", id: "7" },
};

test("existing conversation approval selection is Host-controlled and restores keyboard focus", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  const result = render(
    approvalElement(approvalTask, { onSelect: (mode) => selected.push(mode) }),
  );
  const trigger = screen.getByRole("combobox", { name: "Approval mode" });
  trigger.focus();
  await user.keyboard("{Enter}");
  assert.match(
    (await screen.findByRole("option", { name: /Direct execution/ }))
      .textContent,
    /Stops the current run/,
  );
  await user.keyboard("{ArrowDown}{Enter}");
  assert.deepEqual(selected, ["auto_review"]);
  assert.match(trigger.textContent, /Manual approval/);
  assert.equal(document.activeElement, trigger);
  result.rerender(
    approvalElement({
      ...approvalTask,
      approvalMode: "auto_review",
      approvalRevision: "2",
    }),
  );
  assert.match(trigger.textContent, /Automatic approval/);
  await user.keyboard("{Enter}{Escape}");
  assert.equal(document.activeElement, trigger);
});

test("approval pending, unavailable and unknown states admit no duplicate mode and refresh only", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let refreshed = 0;
  let selected = 0;
  const pending = {
    ...approvalTask,
    availableApprovalModes: [],
    approvalChange: {
      revision: "2",
      targetMode: "full_access",
      state: "outcome_unknown",
    },
  };
  const view = render(
    approvalElement(pending, {
      onRefresh: () => refreshed++,
      onSelect: () => selected++,
    }),
  );
  const trigger = screen.getByRole("combobox", { name: "Approval mode" });
  assert.equal(trigger.disabled, true);
  assert.equal(trigger.getAttribute("aria-busy"), "true");
  assert.match(screen.getByRole("status").textContent, /not yet confirmed/);
  const refresh = screen.getByRole("button", { name: "Refresh status" });
  refresh.focus();
  await user.keyboard("{Enter}");
  assert.equal(refreshed, 1);
  assert.equal(selected, 0);
  view.rerender(
    approvalElement({ ...approvalTask, availableApprovalModes: [] }),
  );
  assert.equal(trigger.disabled, true);
  view.rerender(
    approvalElement({
      ...approvalTask,
      availableApprovalModes: ["manual", "auto_review"],
    }),
  );
  await user.click(trigger);
  const full = await screen.findByRole("option", { name: /Direct execution/ });
  assert.equal(full.getAttribute("aria-disabled"), "true");
  await user.click(full);
  assert.equal(selected, 0);
});

test("Models lets an unavailable default be replaced from the current Host catalog", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount, {
    models: settingsModels({
      models: [{ id: "model-2", displayName: "Model Two" }],
    }),
  });
  assert.match(
    screen.getByRole("alert").textContent,
    /Choose another default model/,
  );
  assert.deepEqual(view.selections.model, []);
  const selector = screen.getByRole("combobox", { name: "Default model" });
  assert.equal(selector.disabled, false);
  await user.click(selector);
  assert.equal(screen.queryByRole("option", { name: /Model One/ }), null);
  await user.click(await screen.findByRole("option", { name: /Model Two/ }));
  assert.deepEqual(view.selections.model, ["model-2"]);
});

test("Models reports an authoritative empty conversation catalog without signing out", () => {
  const view = renderSettings(readySettingsAccount, {
    models: settingsModels(
      { models: [], errorCode: "no_models" },
      { errorCode: "no_models" },
    ),
  });
  assert.match(screen.getByRole("alert").textContent, /No conversation models/);
  assert.equal(
    screen.getByRole("combobox", { name: "Default model" }).disabled,
    true,
  );
  assert.ok(screen.getByRole("button", { name: "Sync again" }));
  assert.deepEqual(view.selections.model, []);
});

test("current Run switches from Send to Stop only when the draft is empty and preserves IME", () => {
  let stops = 0;
  const composer = renderComposer({
    stopAction: "run",
    stopDisabled: false,
    runInFlight: true,
    onStop() {
      stops++;
    },
  });
  fireEvent.keyDown(composer.textarea, { key: "Enter", shiftKey: true });
  fireEvent.keyDown(composer.textarea, { key: "Enter", isComposing: true });
  assert.equal(composer.submissions(), 0);
  fireEvent.keyDown(composer.textarea, { key: "Enter" });
  assert.equal(composer.submissions(), 1);
  fireEvent.click(screen.getByRole("button", { name: "Send" }));
  assert.equal(composer.submissions(), 2);
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  fireEvent.change(composer.textarea, { target: { value: "" } });
  assert.equal(screen.queryByRole("button", { name: "Send" }), null);
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  assert.equal(stops, 1);
});

test("unavailable interjection preserves the draft and shows only disabled Send", () => {
  let stops = 0;
  const composer = renderComposer({
    stopAction: "run",
    stopDisabled: false,
    runInFlight: true,
    canSubmit: false,
    sendDisabledReason: "input.not_ready",
    onStop() {
      stops++;
    },
  });
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  fireEvent.keyDown(composer.textarea, { key: "Enter" });
  assert.equal(composer.submissions(), 0);
  assert.ok(composer.textarea.value.length > 0);
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  assert.equal(stops, 0);
});

test("unadopted and uncertain history can only be put back in the editor", async () => {
  const { AdditionalInputs } = await vite.ssrLoadModule(
    "/src/features/tasks/AdditionalInputs.tsx",
  );
  const restored = [];
  const inputs = [
    {
      id: "1",
      operationId: "old",
      text: "safe preview",
      redacted: false,
      sequence: null,
      adoptedTurn: null,
      order: null,
      state: "unknown",
    },
  ];
  const view = render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(AdditionalInputs, {
        inputs,
        onRestore: (input) => restored.push(input),
      }),
    ),
  );
  assert.match(view.container.textContent, /Sending it again may repeat work/);
  assert.deepEqual(restored, []);
  fireEvent.click(
    screen.getByRole("button", { name: "Put back in the editor" }),
  );
  assert.deepEqual(restored, [
    { kind: "text", text: "safe preview", redacted: false },
  ]);
});

test("a saved Workspace can be selected directly without opening the folder picker", async () => {
  const selected = [];
  let pickers = 0;
  renderComposer({
    workspaceEditable: true,
    workspaceOptions: [
      { id: "automatic", label: "Default", authorization: "available" },
      { id: "saved", label: "/repo/saved", authorization: "available" },
    ],
    selectedWorkspaceOptionId: "automatic",
    onSelectWorkspace(id) {
      selected.push(id);
    },
    onConfirmAccess() {
      pickers++;
    },
  });
  const user = userEvent.setup();
  await user.click(screen.getByRole("combobox", { name: "Switch workspace" }));
  await user.click(await screen.findByRole("option", { name: "/repo/saved" }));
  assert.deepEqual(selected, ["saved"]);
  assert.equal(pickers, 0);
  assert.equal(screen.queryByText("Directory unavailable"), null);
});

test("new Task approval menu explains each mode only when opened and changes the draft choice", async () => {
  const { NewTaskApprovalModeMenu } = await vite.ssrLoadModule(
    "/src/features/tasks/NewTaskView.tsx",
  );
  const choices = [];
  renderComposer({
    approvalModeControl: createElement(NewTaskApprovalModeMenu, {
      approvalModes: ["manual", "auto_review", "full_access"],
      approvalMode: "auto_review",
      disabled: false,
      onApprovalModeChange(mode) {
        choices.push(mode);
      },
    }),
  });
  const user = userEvent.setup();
  await user.click(screen.getByRole("combobox", { name: "Approval mode" }));
  const options = await screen.findAllByRole("option");
  assert.deepEqual(
    options.map((option) =>
      option
        .querySelector(".selection-menu-item-copy > :first-child")
        .textContent.trim(),
    ),
    ["Manual approval", "Automatic approval", "Direct execution"],
  );
  assert.ok(
    options.every((option) =>
      option.querySelector("small")?.textContent.trim(),
    ),
  );
  assert.match(options[1].textContent, /extra cost/);
  assert.equal(document.querySelector(".permission-policy-boundary"), null);
  await user.click(screen.getByRole("option", { name: /^Manual approval/ }));
  assert.deepEqual(choices, ["manual"]);
});

// Exercise the actual App so state, draft handoff and DOM focus are verified together.
async function renderSubmissionApp(
  ctx,
  {
    newTask = false,
    draft = null,
    attachmentsEnabled,
    active = false,
    inputReady = true,
  } = {},
) {
  window.sessionStorage.clear();
  window.matchMedia = (query) => ({
    matches: false,
    media: query,
    addEventListener() {},
    removeEventListener() {},
  });
  globalThis.CSS ??= { escape: (value) => value.replace(/["\\]/g, "\\$&") };
  const { readFile } = await import("node:fs/promises");
  const { default: App } = await vite.ssrLoadModule("/src/app/App.tsx");
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  const snapshot = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  snapshot.capabilities.automaticWorkspaces = true;
  if (attachmentsEnabled !== undefined)
    snapshot.capabilities.attachments.enabled = attachmentsEnabled;
  const task = structuredClone(snapshot.tasks[0]);
  Object.assign(task, {
    title: "Submission task",
    activeOperation: null,
    currentRunId: null,
    currentRunPhase: null,
    runs: [],
  });
  if (active) {
    const live = structuredClone(snapshot.tasks[0].runs[0]);
    Object.assign(live, {
      phase: "running",
      terminal: null,
      activity: { kind: "waiting_model" },
      additionalInputs: [],
    });
    Object.assign(task, {
      activeOperation: { kind: "run", id: live.id },
      currentRunId: live.id,
      currentRunPhase: "running",
      runs: [live],
      pendingUi: null,
      inputReady,
    });
  }
  task.skillCatalog.availability = "unavailable";
  snapshot.tasks = newTask ? [] : [task];
  let revision;
  let resolveCreate, resolveRun;
  const creating = new Promise((resolve) => {
    resolveCreate = resolve;
  });
  const running = new Promise((resolve) => {
    resolveRun = resolve;
  });
  const inputs = [],
    targets = [],
    operationIds = [],
    cancellations = [];
  let creations = 0;
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onWorkbenchRevision: (callback) => {
      revision = callback;
      return () => {};
    },
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async () => structuredClone(snapshot),
    createTask: () => {
      creations += 1;
      return creating;
    },
    cancel: async (taskId, runId) => {
      cancellations.push([taskId, runId]);
      return { taskId, runId, cancelRequested: true };
    },
    sendInput: (
      operationId,
      taskId,
      expectedBindingEpoch,
      expectedExecution,
      input,
    ) => {
      assert.deepEqual(
        expectedExecution,
        active
          ? { kind: "run", runId: task.currentRunId }
          : { kind: "idle", lastRunId: null },
      );
      inputs.push([taskId, expectedBindingEpoch, input]);
      targets.push(expectedExecution);
      operationIds.push(operationId);
      return running.then((result) => {
        if (result instanceof Error) throw result;
        if (result.outcome) return result;
        return {
          taskId,
          operationId,
          outcome: result.accepted
            ? active
              ? "submitted"
              : "started"
            : "rejected",
          runId: result.accepted
            ? active
              ? expectedExecution.runId
              : "1"
            : null,
          inputId: result.accepted && active ? "1" : null,
          sequence: result.accepted && active ? 1 : null,
          reason: result.accepted ? null : result.reason,
        };
      });
    },
  }))
    ctx.mock.method(BridgeClient.prototype, name, fn);
  render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(App),
    ),
  );
  await waitFor(() => assert.ok(revision));
  await waitFor(() =>
    assert.ok(
      document.querySelector(".composer-bar textarea") &&
        !document.querySelector(".composer-bar textarea").disabled,
    ),
  );
  if (!newTask) {
    const button = (
      await screen.findAllByRole("button", { name: /Submission task/ })
    )[0];
    fireEvent.click(button);
  }
  const textarea = document.querySelector(".composer-bar textarea");
  return {
    textarea,
    snapshot,
    task,
    inputs,
    targets,
    operationIds,
    cancellations,
    creations: () => creations,
    publish: async () => {
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      await act(async () => revision(snapshot.revision));
    },
    created: async () =>
      act(async () =>
        resolveCreate({
          accepted: true,
          taskId: task.id,
          bindingEpoch: task.binding.epoch,
        }),
      ),
    settle: async (result = { accepted: true }) =>
      act(async () => resolveRun(result)),
  };
}

test("App image paste shares staging, rejects overlapping paste and sends the latest draft with existing images", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  fixture.snapshot.capabilities.attachments.enabled = true;
  await fixture.publish();
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  const { AttachmentAddOperation } = await vite.ssrLoadModule(
    "/src/bridge/attachment-receive.ts",
  );
  const file = new File(["image bytes"], "capture.png", { type: "image/png" });
  const descriptor = (token, name) => ({
    token: token.repeat(48),
    kind: "image",
    format: "png",
    displayName: name,
    sizeBytes: String(file.size),
  });
  const operations = [];
  const sources = [];
  const chunks = [];
  let finishSecond;
  const second = new Promise((resolve) => {
    finishSecond = resolve;
  });
  ctx.mock.method(BridgeClient.prototype, "createAttachmentAdd", () => {
    const index = operations.length;
    const op = new AttachmentAddOperation(
      {
        begin: async (source) => {
          sources.push(source);
          return { status: "accepted" };
        },
        append: async (...chunk) => {
          chunks.push(chunk);
          return { status: "accepted" };
        },
        finish: async () =>
          index === 0
            ? { status: "ready", attachments: [descriptor("a", "first.png")] }
            : second,
        cancel: async () => ({ status: "cleaned", released: true }),
        recover: async () => assert.fail("No recovery expected"),
      },
      3,
    );
    operations.push(op);
    return op;
  });
  fireEvent.change(fixture.textarea, { target: { value: "old instruction" } });
  pasteItems(fixture.textarea, [imageItem(file)]);
  await screen.findByText("first.png");
  pasteItems(fixture.textarea, [imageItem(file)]);
  await waitFor(() => assert.equal(sources.length, 2));
  fireEvent.change(fixture.textarea, {
    target: { value: "new instruction while adding" },
  });
  pasteItems(fixture.textarea, [imageItem(file)]);
  assert.match(screen.getByRole("alert").textContent, /still being processed/);
  assert.equal(operations.length, 2);
  await act(async () =>
    finishSecond({
      status: "ready",
      attachments: [descriptor("b", "second.png")],
    }),
  );
  await screen.findByText("second.png");
  assert.equal(screen.queryByRole("alert"), null);
  assert.equal(fixture.textarea.value, "new instruction while adding");
  assert.ok(screen.getByText("first.png"));
  assert.ok(sources.every((source) => source.kind === "file_bytes"));
  assert.equal(chunks.length, 2 * Math.ceil(file.size / 3));
  assert.equal(
    screen.getByRole("button", { name: "Send", exact: true }).disabled,
    false,
  );
  fireEvent.click(screen.getByRole("button", { name: "Send", exact: true }));
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.deepEqual(fixture.inputs[0][2], {
    kind: "multimodal",
    text: "new instruction while adding",
    attachmentTokens: ["a".repeat(48), "b".repeat(48)],
  });
  await fixture.settle();
});

async function renderPendingPasteApp(ctx) {
  const fixture = await renderSubmissionApp(ctx);
  fixture.snapshot.capabilities.attachments.enabled = true;
  await fixture.publish();
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  const { AttachmentAddOperation } = await vite.ssrLoadModule(
    "/src/bridge/attachment-receive.ts",
  );
  let resolveFinish,
    finishing = false,
    cancellations = 0,
    additions = 0;
  const finished = new Promise((resolve) => {
    resolveFinish = resolve;
  });
  ctx.mock.method(BridgeClient.prototype, "createAttachmentAdd", () => {
    additions++;
    return new AttachmentAddOperation(
      {
        begin: async () => ({ status: "accepted" }),
        append: async () => ({ status: "accepted" }),
        finish: () => {
          finishing = true;
          return finished;
        },
        cancel: async () => {
          cancellations++;
          return { status: "cleaned", released: true };
        },
        recover: async () => assert.fail("No connection recovery expected"),
      },
      3,
    );
  });
  const file = new File(["image"], "pending.png", { type: "image/png" });
  const attachment = {
    token: "c".repeat(48),
    kind: "image",
    format: "png",
    displayName: file.name,
    sizeBytes: String(file.size),
  };
  return {
    ...fixture,
    begin: async () => {
      pasteItems(fixture.textarea, [imageItem(file)]);
      await waitFor(() => assert.ok(finishing));
    },
    finish: async () =>
      act(async () =>
        resolveFinish({ status: "ready", attachments: [attachment] }),
      ),
    cancellations: () => cancellations,
    additions: () => additions,
    attachment,
  };
}

test("App image paste reports unavailable attachments without starting a writer", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { attachmentsEnabled: false });
  assert.ok(screen.queryByRole("button", { name: "Add files" }) === null);
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  ctx.mock.method(BridgeClient.prototype, "createAttachmentAdd", () =>
    assert.fail("Unavailable attachments must not reserve resources"),
  );
  const file = new File(["png"], "a.png", { type: "image/png" });
  const event = pasteItems(fixture.textarea, [imageItem(file)]);
  assert.equal(event.defaultPrevented, true);
  assert.match(screen.getByRole("alert").textContent, /cannot be added/);
  assert.equal(BridgeClient.prototype.createAttachmentAdd.mock.callCount(), 0);
  assert.equal(fixture.inputs.length, 0);
});

test("App cancelled image paste preserves edits and ignores a late ready result", async (ctx) => {
  const f = await renderPendingPasteApp(ctx);
  fireEvent.change(f.textarea, { target: { value: "keep original draft" } });
  await f.begin();
  fireEvent.change(f.textarea, { target: { value: "edited during staging" } });
  fireEvent.click(screen.getByRole("button", { name: "Cancel adding files" }));
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Add files" }).disabled,
      false,
    ),
  );
  await f.finish();
  assert.equal(f.cancellations(), 1);
  assert.equal(f.textarea.value, "edited during staging");
  assert.equal(screen.queryByText("pending.png"), null);
  assert.equal(f.inputs.length, 0);
});

test("App image paste cannot hand off to a Task after leaving and returning", async (ctx) => {
  const f = await renderPendingPasteApp(ctx);
  const other = structuredClone(f.task);
  other.id = String(BigInt(f.task.id) + 1n);
  other.title = "Other paste task";
  f.snapshot.tasks.push(other);
  await f.publish();
  fireEvent.change(f.textarea, { target: { value: "source Task draft" } });
  await f.begin();
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Other paste task/ }))[0],
  );
  await waitFor(() =>
    assert.equal(document.querySelector(".composer-bar textarea").value, ""),
  );
  fireEvent.change(document.querySelector(".composer-bar textarea"), {
    target: { value: "other Task draft" },
  });
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Submission task/ }))[0],
  );
  await waitFor(() =>
    assert.equal(
      document.querySelector(".composer-bar textarea").value,
      "source Task draft",
    ),
  );
  await f.finish();
  assert.equal(f.cancellations(), 1);
  assert.equal(screen.queryByText("pending.png"), null);
  assert.equal(f.inputs.length, 0);
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Other paste task/ }))[0],
  );
  assert.equal(
    document.querySelector(".composer-bar textarea").value,
    "other Task draft",
  );
  assert.equal(screen.queryByText("pending.png"), null);
});

test("App image-only paste sends through the existing multimodal Run input", async (ctx) => {
  const f = await renderPendingPasteApp(ctx);
  assert.equal(f.textarea.value, "");
  await f.begin();
  await f.finish();
  await screen.findByText("pending.png");
  const send = screen.getByRole("button", { name: "Send", exact: true });
  assert.equal(send.disabled, false);
  fireEvent.click(send);
  await waitFor(() => assert.equal(f.inputs.length, 1));
  assert.deepEqual(f.inputs[0][2], {
    kind: "multimodal",
    text: "",
    attachmentTokens: [f.attachment.token],
  });
  await f.settle();
});

for (const method of ["Enter", "click"]) {
  test(`App ${method} send keeps the editor focused and preserves edits before acknowledgement`, async (ctx) => {
    const fixture = await renderSubmissionApp(ctx);
    const user = userEvent.setup({ document });
    await user.type(fixture.textarea, "first instruction");
    if (method === "Enter") await user.keyboard("{Enter}");
    else
      await user.click(
        screen.getByRole("button", { name: "Send", exact: true }),
      );
    assert.equal(fixture.inputs.length, 1);
    assert.equal(fixture.textarea.disabled, false);
    assert.equal(document.activeElement, fixture.textarea);
    await user.clear(fixture.textarea);
    await user.type(fixture.textarea, "next instruction{Enter}");
    assert.equal(fixture.inputs.length, 1, "pending send must not be repeated");
    await fixture.settle();
    await waitFor(() =>
      assert.equal(
        screen.getByRole("button", { name: "Send", exact: true }).disabled,
        false,
      ),
    );
    assert.equal(fixture.textarea.value, "next instruction\n");
    assert.equal(document.activeElement, fixture.textarea);
  });
}

test("App first send preserves the textarea, caret and IME composition across Task creation", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  assert.equal(fixture.creations(), 1);
  assert.equal(fixture.textarea.disabled, false);
  await user.clear(fixture.textarea);
  await user.type(fixture.textarea, "next draft");
  await fixture.created();
  await user.keyboard("{Enter}");
  assert.equal(fixture.creations(), 1);
  fireEvent.compositionStart(fixture.textarea);
  fixture.textarea.setSelectionRange(3, 3);
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() =>
    assert.equal(
      document.querySelector(".workbench-view").dataset.view,
      "task",
    ),
  );
  assert.equal(
    document.querySelector(".composer-bar textarea"),
    fixture.textarea,
  );
  assert.equal(fixture.textarea.value, "next draft\n");
  assert.equal(fixture.textarea.selectionStart, 3);
  assert.equal(document.activeElement, fixture.textarea);
  await fixture.settle();
  assert.equal(fixture.textarea.value, "next draft\n");
  // Retaining the Composer instance also retains its in-progress IME latch.
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 1);
  fireEvent.compositionEnd(fixture.textarea);
});

test("App acknowledgement clears only the submitted draft and never steals outside focus", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  const outside = screen.getByRole("button", { name: "New task", exact: true });
  outside.focus();
  await fixture.settle();
  await waitFor(() => assert.equal(fixture.textarea.value, ""));
  assert.equal(document.activeElement, outside);
});

test("App rejected send preserves the latest edit and allows a deliberate retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await user.clear(fixture.textarea);
  await user.type(fixture.textarea, "revised instruction");
  await fixture.settle({ accepted: false, reason: "catalog_loading" });
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Send", exact: true }).disabled,
      false,
    ),
  );
  assert.equal(fixture.textarea.value, "revised instruction");
  assert.equal(document.activeElement, fixture.textarea);
});

test("App first accepted send clears its original version after Task handoff without losing focus", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle();
  await waitFor(() => assert.equal(fixture.textarea.value, ""));
  assert.equal(
    document.querySelector(".composer-bar textarea"),
    fixture.textarea,
  );
  assert.equal(document.activeElement, fixture.textarea);
  assert.equal(fixture.textarea.disabled, false);
  await user.type(fixture.textarea, "follow-up");
  assert.equal(fixture.textarea.value, "follow-up");
});

test("App Composer scopes model choices to its Provider and preserves the actual Run model", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const provider = fixture.snapshot.models.providers[0];
  const model = provider.models[0];
  provider.models = [
    { ...model, id: "minimax-m3", displayName: "minimax-m3" },
    { ...model, id: "glm-5.3-flash", displayName: "glm-5.3-flash" },
  ];
  fixture.snapshot.models.customProviders = [
    {
      id: "cc",
      builtinProviderId: null,
      displayName: "cc",
      protocol: "anthropic_messages",
      normalizedBaseUrl: "https://custom.example.com/v1",
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      providerRevision: "1",
      sourceGeneration: "23",
      catalogGeneration: "29",
      models: [
        {
          ...model,
          id: "gpt-5.6-sol",
          displayName: "gpt-5.6-sol",
          ready: true,
          testStatus: "connected",
        },
      ],
    },
  ];
  const defaultModel = { sourceId: "metask", modelId: "minimax-m3" };
  fixture.snapshot.models.defaultSelection = defaultModel;
  fixture.snapshot.newTaskAdmission.activeModelRef = defaultModel;
  await fixture.publish();
  const selector = screen.getByRole("combobox", { name: "Default model" });
  await waitFor(() => assert.match(selector.textContent, /minimax-m3/));
  const user = userEvent.setup({ document });
  await user.click(selector);
  assert.equal(screen.queryByRole("option", { name: /gpt-5.6-sol/ }), null);
  await user.click(
    await screen.findByRole("option", { name: /glm-5.3-flash/ }),
  );
  await user.type(fixture.textarea, "How can we forecast the weather?{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  assert.deepEqual(
    BridgeClient.prototype.createTask.mock.calls[0].arguments[3],
    {
      targetModelRef: { sourceId: "metask", modelId: "glm-5.3-flash" },
      expectedSourceGeneration: provider.sourceGeneration,
      expectedCatalogGeneration: provider.catalogGeneration,
    },
  );
  fixture.task.binding.model = "glm-5.3-flash";
  fixture.task.modelIntent = {
    modelRef: { sourceId: "metask", modelId: "glm-5.3-flash" },
    selectionRevision: "1",
    state: "committed",
  };
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  const { readFile } = await import("node:fs/promises");
  const run = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  ).tasks[0].runs[0];
  run.execution.model = "glm-5.3-flash";
  fixture.task.activeOperation = { kind: "run", id: run.id };
  fixture.task.currentRunId = run.id;
  fixture.task.currentRunPhase = run.phase;
  fixture.task.runs = [run];
  await fixture.settle();
  await fixture.publish();
  await waitFor(() => {
    const label = document.querySelector(".composer-model-trigger").textContent;
    assert.equal(label, "glm-5.3-flash");
    assert.doesNotMatch(label, /Next run/);
  });
  ctx.mock.method(
    BridgeClient.prototype,
    "selectTaskModel",
    async (_taskId, _revision, modelRef) => {
      fixture.task.modelIntent = {
        modelRef,
        selectionRevision: "2",
        state: "committed",
      };
      return {
        accepted: true,
        taskId: fixture.task.id,
        selectionRevision: "2",
        reason: null,
      };
    },
  );
  fixture.snapshot.models.defaultSelection = {
    sourceId: "cc",
    modelId: "gpt-5.6-sol",
  };
  fixture.snapshot.newTaskAdmission.activeModelRef =
    fixture.snapshot.models.defaultSelection;
  await fixture.publish();
  await user.click(screen.getByRole("combobox", { name: "Default model" }));
  assert.equal(screen.queryByRole("option", { name: /gpt-5.6-sol/ }), null);
  await user.click(await screen.findByRole("option", { name: /minimax-m3/ }));
  await waitFor(() => {
    const label = document.querySelector(".composer-model-trigger").textContent;
    assert.equal(label, "minimax-m3");
    assert.doesNotMatch(label, /Next run/);
  });
  await user.click(screen.getByRole("button", { name: "Task information" }));
  const fact = screen.getByText("Current run model").parentElement;
  assert.equal(fact.querySelector("dd").textContent, "glm-5.3-flash");
  assert.equal(
    screen.getByText("Selected provider").parentElement.querySelector("dd")
      .textContent,
    "Metask",
  );
  assert.equal(
    screen.getByText("Current run protocol").parentElement.querySelector("dd")
      .textContent,
    "Anthropic Messages",
  );
  await user.keyboard("{Escape}");
  assert.deepEqual(fixture.snapshot.models.defaultSelection, {
    sourceId: "cc",
    modelId: "gpt-5.6-sol",
  });
  await user.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  await user.click(screen.getByRole("combobox", { name: "Default model" }));
  assert.ok(await screen.findByRole("option", { name: "gpt-5.6-sol" }));
  assert.equal(
    screen.queryByRole("option", { name: /minimax-m3|glm-5.3-flash/ }),
    null,
  );
});

test("App late send result preserves another Task's draft and focus", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await user.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  const next = document.querySelector(".composer-bar textarea");
  await user.type(next, "different task draft");
  await fixture.settle();
  assert.equal(next.value, "different task draft");
  assert.equal(document.activeElement, next);
});

test("Composer draft kind changes do not reclaim focus from another control", async () => {
  const composer = renderComposer();
  const outside = document.createElement("button");
  document.body.append(outside);
  outside.focus();
  try {
    act(() =>
      composer.setDraft({
        kind: "skill",
        skillId: "review",
        invocationName: "review",
        displayName: "Review",
        catalogRevision: "4",
        selectionRevision: "1",
        argumentNames: ["path"],
        argumentValues: ["src"],
        maxValues: 1,
      }),
    );
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    assert.equal(document.activeElement, outside);
  } finally {
    outside.remove();
  }
});

test("send acknowledgement preserves newer text and unsubmitted attachments", () => {
  let drafts;
  function Harness() {
    drafts = useNewTaskDrafts("send-acknowledgement");
    return null;
  }
  render(createElement(Harness));
  const sent = {
    token: "a".repeat(48),
    kind: "file",
    displayName: "sent.txt",
    sizeBytes: "3",
  };
  const unsent = { ...sent, token: "b".repeat(48), displayName: "unsent.txt" };
  const submitted = {
    kind: "multimodal",
    text: "read notes",
    attachments: [sent],
  };
  act(() => {
    drafts.setDraft("send-acknowledgement", submitted);
    drafts.updateDraft({
      ...submitted,
      text: "new text",
      attachments: [sent, unsent],
    });
    drafts.acknowledgeDraft("send-acknowledgement", submitted);
  });
  assert.deepEqual(drafts.draft, {
    kind: "multimodal",
    text: "new text",
    attachments: [unsent],
  });
  act(() => {
    drafts.updateDraft({ ...submitted, text: "newer text" });
    drafts.acknowledgeDraft("send-acknowledgement", submitted);
  });
  assert.deepEqual(drafts.draft, { kind: "text", text: "newer text" });
});

test("App leaving Task creation preserves drafts and current input when preparation cancels", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await fixture.created();
  const other = {
    ...structuredClone(fixture.task),
    id: "4",
    title: "Other task",
  };
  fixture.snapshot.tasks = [other];
  await fixture.publish();
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Other task/ }))[0],
  );
  await user.type(
    document.querySelector(".composer-bar textarea"),
    "other task draft",
  );
  fixture.snapshot.tasks.push(fixture.task);
  await fixture.publish();
  assert.equal(fixture.inputs.length, 0);
  assert.equal(
    document.querySelector(".composer-bar textarea").value,
    "other task draft",
  );
  const { readNewTaskDraft, unscopedNewTaskDraftId } = await vite.ssrLoadModule(
    "/src/features/composer/drafts.ts",
  );
  assert.equal(
    readNewTaskDraft(unscopedNewTaskDraftId).text,
    "first instruction",
  );
});

test("App sends to the current Run without preparation and shows Stop when its busy draft is cleared", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  const editor = fixture.textarea;
  fireEvent.change(editor, { target: { value: "new constraint" } });
  fireEvent.keyDown(editor, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.deepEqual(fixture.targets, [
    { kind: "run", runId: fixture.task.currentRunId },
  ]);
  assert.equal(fixture.creations(), 0);
  fireEvent.change(editor, { target: { value: "newer unsent intent" } });
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  fireEvent.change(editor, { target: { value: "" } });
  const stop = screen.getByRole("button", { name: "Stop task" });
  assert.equal(stop.disabled, false);
  fireEvent.click(stop);
  await waitFor(() => assert.equal(fixture.cancellations.length, 1));
  fireEvent.change(editor, { target: { value: "newer unsent intent" } });
  await fixture.settle();
  assert.equal(editor.value, "newer unsent intent");
  assert.equal(fixture.inputs.length, 1);
});

test("App never waits for a current Run to become ready and never sends its retained draft later", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, {
    active: true,
    inputReady: false,
  });
  fireEvent.change(fixture.textarea, {
    target: { value: "retain until I explicitly send" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 0);
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  fixture.task.inputReady = true;
  await fixture.publish();
  assert.equal(fixture.inputs.length, 0);
  assert.equal(fixture.textarea.value, "retain until I explicitly send");
  await waitFor(() =>
    assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false),
  );
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle();
});

test("App uncertain current-Run submission keeps the draft, unlocks Send and never replays on completion", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "possibly submitted" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle(new Error("response lost"));
  assert.equal(fixture.textarea.value, "possibly submitted");
  await waitFor(() =>
    assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false),
  );
  fixture.task.activeOperation = null;
  fixture.task.currentRunPhase = "completed";
  fixture.task.inputReady = false;
  Object.assign(fixture.task.runs[0], {
    phase: "completed",
    activity: null,
    terminal: {
      outcome: "completed",
      cause: null,
      diagnosticDisposition: "absent",
    },
  });
  await fixture.publish();
  assert.equal(fixture.inputs.length, 1);
  assert.equal(fixture.textarea.value, "possibly submitted");
});
