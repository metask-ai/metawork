import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, createRef, useLayoutEffect, useState } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;
dom.window.matchMedia = (media) => ({
  media,
  matches: false,
  addEventListener() {},
  removeEventListener() {},
});

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
const { useNewTaskDrafts, useTaskDrafts } = await vite.ssrLoadModule(
  "/src/features/composer/useTaskDrafts.ts",
);
const { ComposerFooter } = await vite.ssrLoadModule(
  "/src/features/composer/ComposerFooter.tsx",
);
const { AppShell } = await vite.ssrLoadModule("/src/app/AppShell.tsx");
const { ModelSetupNotice } = await vite.ssrLoadModule(
  "/src/features/models/ModelSetup.tsx",
);
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { suggestChatCompletionsEndpoint } = await vite.ssrLoadModule(
  "/src/features/settings/model-connection.ts",
);

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
  assert.equal(screen.getByRole("listbox").tabIndex, -1);
  const close = screen.getByRole("button", { name: "Close" });
  assert.ok(close.closest('[role="dialog"]'));
  fireEvent.keyDown(combobox, { key: "ArrowDown", isComposing: true });
  assert.equal(combobox.getAttribute("aria-activedescendant"), options[0].id);
  fireEvent.compositionStart(combobox);
  fireEvent.keyDown(combobox, { key: "Enter" });
  fireEvent.keyDown(combobox, { key: "Escape" });
  assert.equal(closed, 0);
  fireEvent.compositionEnd(combobox);
  fireEvent.keyDown(combobox, { key: "Enter", keyCode: 229 });
  assert.deepEqual(selected, []);
  fireEvent.keyDown(combobox, { key: "ArrowDown" });
  assert.equal(
    combobox.getAttribute("aria-activedescendant"),
    "search-result-1",
  );
  fireEvent.keyDown(combobox, { key: "Enter" });
  assert.deepEqual(selected, ["task:2"]);
  fireEvent.click(close);
  assert.equal(closed, 1);
  view.rerender(searchElement({ ...props, open: false }));
  await waitFor(() => assert.ok(document.activeElement === opener));
  view.unmount();
  opener.remove();
});

test("Global search scrolls the active result into view and preserves its identity", () => {
  const results = Array.from({ length: 50 }, (_, index) => ({
    key: `task:${index}`,
    kind: "task",
    title: `Task ${index}`,
    detail: "",
    taskId: String(index),
  }));
  const selected = [];
  const props = {
    open: true,
    query: "task",
    results,
    onQuery() {},
    onClose() {},
    onSelect(result) {
      selected.push(result.key);
    },
  };
  const view = render(searchElement(props));
  const input = screen.getByRole("combobox");
  const list = screen.getByRole("listbox");
  const last = screen.getByRole("option", { name: "Task Task 49" });
  Object.defineProperty(list, "clientHeight", { value: 100 });
  Object.defineProperties(last, {
    offsetTop: { value: 150 },
    offsetHeight: { value: 30 },
  });
  fireEvent.keyDown(input, { key: "ArrowUp" });
  assert.equal(list.scrollTop, 81);
  assert.equal(input.getAttribute("aria-activedescendant"), last.id);
  fireEvent.mouseEnter(screen.getAllByRole("option")[0]);
  fireEvent.keyDown(input, { key: "Enter" });

  const reordered = [results[49], ...results.slice(0, 49)];
  view.rerender(searchElement({ ...props, results: reordered }));
  fireEvent.keyDown(input, { key: "Enter" });
  view.rerender(searchElement({ ...props, results: results.slice(0, 49) }));
  fireEvent.keyDown(input, { key: "Enter" });
  assert.deepEqual(selected, ["task:49", "task:49", "task:0"]);
  view.unmount();
});

test("SelectionMenu labels the custom group without adding a selectable item or interrupting keyboard navigation", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderMenu((value) => selected.push(value), "alpha", {
    options: [
      { value: "alpha", label: "Official model" },
      { value: "custom-one", label: "Custom one", groupLabel: "Custom models" },
      { value: "custom-two", label: "Custom two" },
    ],
  });
  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  trigger.focus();
  await user.keyboard("{Enter}");
  const customGroup = screen.getByRole("group", { name: "Custom models" });
  assert.equal(customGroup.querySelectorAll('[role="option"]').length, 2);
  assert.equal(screen.getAllByRole("option").length, 3);
  await user.keyboard("{ArrowDown}{Enter}");
  assert.deepEqual(selected, ["custom-one"]);
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

  defaultSelection: { sourceId: "metask", modelId: "model-1" },
  defaultSelectionDisplayName: null,
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
      modelContext: "fixture:1",
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
      onCreateCustomProvider() {
        return Promise.resolve(false);
      },
      onCreateBuiltinProvider() {
        return Promise.resolve(false);
      },
      onSaveCustomModel() {
        return Promise.resolve({
          accepted: false,
          applied: [],
          source: null,
          modelId: "",
          reviewRequired: true,
        });
      },
      onRemoveCustomModel() {
        return Promise.resolve(false);
      },
      onTestCustomModel() {
        return Promise.resolve(false);
      },
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

const completeModelCapabilities = {
  management: true,
  secretCapture: true,
  modelTest: true,
};
const presetModels = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
).models.builtinProviderPresets;
function renderModelSettings(overrides = {}) {
  return renderSettings(readySettingsAccount, {
    customProviderCapabilities: completeModelCapabilities,
    models: { ...readySettingsModels, builtinProviderPresets: presetModels },
    ...overrides,
  });
}
async function chooseModelSource(user, label) {
  const dialog = screen.getByRole("dialog", { name: "Add model" });
  await user.click(
    within(dialog).getByRole("combobox", { name: "Model vendor" }),
  );
  await user.click(
    await screen.findByRole("option", { name: label, exact: true }),
  );
  return dialog;
}
function accessibleDescription(element) {
  return (element.getAttribute("aria-describedby") ?? "")
    .split(/\s+/u)
    .filter(Boolean)
    .map((id) => document.getElementById(id)?.textContent ?? "")
    .join(" ")
    .trim();
}

test("Models exposes a model list and Add model action instead of a Provider directory", () => {
  const incomplete = renderSettings(readySettingsAccount);
  assert.equal(screen.queryByRole("heading", { name: "Custom models" }), null);
  incomplete.unmount();
  renderModelSettings();
  assert.equal(screen.queryByRole("link", { name: "Providers" }), null);
  assert.equal(screen.queryByRole("button", { name: "Configure" }), null);
  assert.ok(screen.getByRole("heading", { name: "Custom models" }));
  assert.ok(screen.getByRole("button", { name: "Add model" }));
});

test("Add model uses the Host recipe and saves the first model with its official connection", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateBuiltinProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = screen.getByRole("dialog", { name: "Add model" });
  await user.click(
    within(dialog).getByRole("combobox", { name: "Model vendor" }),
  );
  await screen.findByRole("option", { name: "DeepSeek", exact: true });
  const expectedOptions = [
    ["DeepSeek", "deepseek"],
    ["Kimi", "kimi"],
    ["MiniMax", "minimax"],
    ["腾讯混元", "hunyuan"],
    ["智谱 GLM", "glm"],
    ["Custom / other service", "custom"],
  ];
  const options = screen.getAllByRole("option");
  assert.equal(options.length, expectedOptions.length);
  for (const [index, [label, vendor]] of expectedOptions.entries()) {
    const option = options[index];
    assert.equal(option.textContent, label);
    assert.equal(
      option.querySelector(".model-vendor-icon")?.dataset.vendor,
      vendor,
    );
    assert.equal(
      option.querySelector(".model-vendor-icon")?.getAttribute("aria-hidden"),
      "true",
    );
  }
  await user.click(
    screen.getByRole("option", { name: "腾讯混元", exact: true }),
  );
  assert.equal(
    within(dialog)
      .getByRole("combobox", { name: "Model vendor" })
      .querySelector(".model-vendor-icon")?.dataset.vendor,
    "hunyuan",
  );
  assert.equal(within(dialog).queryByText("Connection settings"), null);
  assert.equal(
    within(dialog).queryByRole("textbox", { name: "Request URL (Endpoint)" }),
    null,
  );
  assert.equal(
    within(dialog).queryByRole("combobox", { name: "Protocol" }),
    null,
  );
  assert.equal(
    within(dialog).getByRole("link", { name: "Get an API key" }).href,
    "https://console.cloud.tencent.com/tokenhub/apikey",
  );

  await user.type(within(dialog).getByLabelText("API key"), "official-secret");
  await user.click(within(dialog).getByRole("combobox", { name: "Model ID" }));
  await screen.findByRole("option", { name: "hy4", exact: true });
  assert.deepEqual(
    screen.getAllByRole("option").map((option) => option.textContent),
    ["hy4", "hy4-preview", "hy3"],
  );
  await user.click(screen.getByRole("option", { name: "hy4", exact: true }));
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.deepEqual(submitted, [
    {
      providerId: "hunyuan",
      baseUrl: "https://tokenhub.tencentmaas.com/v1",
      apiKey: "official-secret",
      model: { id: "hy4" },
    },
  ]);
  assert.equal(within(dialog).getByLabelText("API key").value, "");
  assert.ok(within(dialog).getByRole("alert"));
});

test("Custom model form detects its protocol from the complete endpoint without a protocol selector", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  assert.equal(dialog.querySelector("details, summary"), null);
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.type(address, "https://custom.example.com/v1/messages");
  assert.equal(
    within(dialog).queryByRole("combobox", { name: "Protocol" }),
    null,
  );
  assert.match(
    within(dialog).getByRole("status").textContent,
    /Detected API: Anthropic Messages/,
  );
  assert.equal(address.value, "https://custom.example.com/v1/messages");
  assert.doesNotMatch(dialog.textContent, /Request endpoint:/);
  assert.match(
    dialog.textContent,
    /Model requests will send the API key to custom.example.com/,
  );
  assert.doesNotMatch(dialog.textContent, /\bprovider\b|\bdefault\b/i);

  await user.type(within(dialog).getByLabelText("API key"), "custom-secret");
  await user.type(
    within(dialog).getByRole("textbox", { name: "Model ID" }),
    "custom-model",
  );
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.deepEqual(submitted, [
    {
      displayName: "custom.example.com",
      protocol: "anthropic_messages",
      normalizedBaseUrl: "https://custom.example.com/v1/messages",
      apiKey: "custom-secret",
      model: { id: "custom-model" },
    },
  ]);
  assert.equal(within(dialog).getByLabelText("API key").value, "");
  assert.equal(
    within(dialog).getByRole("textbox", { name: "Model ID" }).value,
    "custom-model",
  );
});

test("closing or losing the model configuration gate clears an unfinished credential", async () => {
  const user = userEvent.setup({ document });
  const view = render(
    settingsElement(readySettingsAccount, {
      customProviderCapabilities: completeModelCapabilities,
      models: { ...readySettingsModels, builtinProviderPresets: presetModels },
    }),
  );
  await user.click(screen.getByRole("button", { name: "Add model" }));
  let dialog = await chooseModelSource(user, "Custom / other service");
  await user.type(
    within(dialog).getByLabelText("API key"),
    "unfinished-secret",
  );
  await user.keyboard("{Escape}");
  assert.equal(screen.queryByRole("dialog", { name: "Add model" }), null);
  await user.click(screen.getByRole("button", { name: "Add model" }));
  dialog = await chooseModelSource(user, "Custom / other service");
  assert.equal(within(dialog).getByLabelText("API key").value, "");
  await user.type(within(dialog).getByLabelText("API key"), "another-secret");
  view.rerender(
    settingsElement(readySettingsAccount, {
      customProviderCapabilities: {
        ...completeModelCapabilities,
        secretCapture: false,
      },
    }),
  );
  assert.equal(screen.queryByRole("dialog", { name: "Add model" }), null);
  assert.ok(screen.getByRole("heading", { name: "Models" }));
});

test("model editing saves all changes once and clears credentials after a partial failure", async () => {
  const user = userEvent.setup({ document });
  const changes = [];
  const source = {
    id: "source-edit",
    builtinProviderId: null,
    displayName: "Team",
    protocol: "openai_responses",
    normalizedBaseUrl: "https://example.com/v1/responses",
    state: "ready",
    credentialStatus: "ready",
    enabled: true,
    providerRevision: "7",
    sourceGeneration: "11",
    catalogGeneration: "13",
    models: [
      {
        id: "model-a",
        displayName: "Model A",
        metadata: {},
        metadataProvenance: "unknown",
        testStatus: "connected",
        ready: true,
      },
    ],
  };
  const view = renderModelSettings({
    models: { ...readySettingsModels, customProviders: [source] },
    onSaveCustomModel: async (input) => {
      changes.push(input);
      const updatedSource = {
        ...source,
        normalizedBaseUrl: input.endpoint,
        protocol: input.protocol,
        providerRevision: "8",
      };
      view.rerenderModels({
        ...readySettingsModels,
        customProviders: [updatedSource],
      });
      return {
        accepted: false,
        applied: ["address"],
        source: updatedSource,
        modelId: "model-a",
        reviewRequired: false,
      };
    },
  });
  assert.ok(screen.getByText("Model A"));
  assert.ok(screen.getByText("Test passed"));
  assert.equal(screen.queryByText("Team", { exact: true }), null);
  assert.equal(
    view.container.querySelector(".settings-model-identity .model-vendor-icon")
      ?.dataset.vendor,
    "custom",
  );
  await user.click(screen.getByRole("button", { name: "Edit", exact: true }));
  const dialog = screen.getByRole("dialog", { name: "Edit model" });
  assert.equal(
    within(dialog).queryByRole("combobox", { name: "Model vendor" }),
    null,
  );
  assert.match(dialog.textContent, /Save changes to the model/);
  assert.doesNotMatch(
    dialog.textContent,
    /choose a preset|\bprovider\b|\bdefault\b/i,
  );

  assert.equal(
    within(dialog).getByRole("textbox", { name: "Request URL (Endpoint)" })
      .value,
    source.normalizedBaseUrl,
  );
  const model = within(dialog).getByRole("textbox", { name: "Model ID" });
  await user.clear(model);
  await user.type(model, "model-b");
  const key = within(dialog).getByLabelText("API key");
  assert.equal(key.type, "password");
  assert.equal(key.value, "");
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  assert.ok(
    address.compareDocumentPosition(key) & Node.DOCUMENT_POSITION_FOLLOWING,
  );
  assert.ok(
    key.compareDocumentPosition(model) & Node.DOCUMENT_POSITION_FOLLOWING,
  );
  await user.clear(address);
  await user.type(address, "https://other.example/v1/messages");
  assert.doesNotMatch(dialog.textContent, /shared by/);
  await user.type(key, "  replacement secret  ");
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.deepEqual(changes, [
    {
      providerId: "source-edit",
      expectedProviderRevision: "7",
      expectedCatalogGeneration: "13",
      modelId: "model-a",
      nextModelId: "model-b",
      protocol: "anthropic_messages",
      endpoint: "https://other.example/v1/messages",
      apiKey: "  replacement secret  ",
    },
  ]);
  assert.equal(key.value, "");
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /Some changes were saved/,
  );
  assert.equal(
    within(dialog).queryByRole("button", { name: "Save API key" }),
    null,
  );
  await user.click(
    within(dialog).getByRole("button", { name: "Cancel", exact: true }),
  );
  view.rerenderModels({
    ...readySettingsModels,
    customProviders: [{ ...source, state: "configuring", models: [] }],
  });
  assert.equal(screen.queryByText("Team", { exact: true }), null);
  assert.ok(screen.getByText("No custom models yet."));
  await user.click(
    screen.getByRole("button", { name: "Add model", exact: true }),
  );
  const addDialog = await chooseModelSource(user, "Custom / other service");
  assert.equal(
    within(addDialog).queryByRole("combobox", {
      name: "Connection",
      exact: true,
    }),
    null,
  );
  assert.equal(
    within(addDialog).getByRole("textbox", { name: "Request URL (Endpoint)" })
      .value,
    "",
  );
  assert.equal(screen.queryByText("Team", { exact: true }), null);
  assert.ok(within(addDialog).getByRole("textbox", { name: "Model ID" }));
});

test("Editing an official model permits credential replacement without exposing connection settings", async () => {
  const user = userEvent.setup({ document });
  const credentials = [];
  const creations = [];
  const recipe = presetModels.find((preset) => preset.id === "deepseek");
  renderModelSettings({
    models: {
      ...readySettingsModels,
      builtinProviderPresets: presetModels,
      customProviders: [
        {
          id: "official-source",
          builtinProviderId: "deepseek",
          displayName: "DeepSeek",
          protocol: recipe.protocol,
          normalizedBaseUrl: "https://api.deepseek.com/chat/completions",
          state: "ready",
          credentialStatus: "ready",
          enabled: true,
          providerRevision: "7",
          sourceGeneration: "11",
          catalogGeneration: "13",
          models: [
            {
              ...readySettingsModels.providers[0].models[0],
              id: "deepseek-flash",
              displayName: "deepseek-flash",
              ready: true,
              metadataProvenance: "user_declared",
              testStatus: "connected",
            },
          ],
        },
      ],
    },
    onCreateBuiltinProvider: async (input) => {
      creations.push(input);
      return false;
    },
    onSaveCustomModel: async (input) => {
      credentials.push(input);
      return {
        accepted: false,
        applied: [],
        source: {
          id: "official-source",
          providerRevision: "7",
          catalogGeneration: "13",
        },
        modelId: "deepseek-flash",
        reviewRequired: false,
      };
    },
  });
  await user.click(screen.getByRole("button", { name: "Edit", exact: true }));
  const dialog = screen.getByRole("dialog", { name: "Edit model" });
  assert.equal(within(dialog).queryByText("Connection settings"), null);
  assert.equal(
    within(dialog).queryByRole("textbox", { name: "Request URL (Endpoint)" }),
    null,
  );
  assert.equal(
    within(dialog).queryByRole("combobox", { name: "Protocol" }),
    null,
  );
  const key = within(dialog).getByLabelText("API key");
  assert.equal(key.value, "");
  await user.type(key, "replacement-secret");
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.equal(credentials.length, 1);
  assert.equal(credentials[0].providerId, "official-source");
  assert.equal(credentials[0].apiKey, "replacement-secret");
  assert.equal(credentials[0].nextModelId, "deepseek-flash");
  assert.equal(key.value, "");
  await user.click(
    within(dialog).getByRole("button", { name: "Cancel", exact: true }),
  );
  await user.click(
    screen.getByRole("button", { name: "Add model", exact: true }),
  );
  const add = await chooseModelSource(user, "DeepSeek");
  assert.equal(within(add).getByLabelText("API key").value, "");
  await user.type(within(add).getByLabelText("API key"), "independent-key");
  await user.click(within(add).getByRole("combobox", { name: "Model ID" }));
  await user.click(
    await screen.findByRole("option", { name: "deepseek-flash", exact: true }),
  );
  await user.click(
    within(add).getByRole("button", { name: "Save", exact: true }),
  );
  assert.deepEqual(creations, [
    {
      providerId: "deepseek",
      baseUrl: recipe.defaultBaseUrl,
      apiKey: "independent-key",
      model: { id: "deepseek-flash" },
    },
  ]);
});

test("custom model addresses are submitted directly for every protocol", async () => {
  const user = userEvent.setup({ document });
  for (const [protocol, label, endpoint] of [
    [
      "openai_responses",
      "OpenAI Responses",
      "https://example.com/api/responses",
    ],
    [
      "openai_chat_completions",
      "OpenAI Chat Completions",
      "https://example.com/api/chat/completions",
    ],
    [
      "anthropic_messages",
      "Anthropic Messages",
      "https://example.com/api/v1/messages",
    ],
    ["gemini_native", "Gemini Native", "https://example.com"],
  ]) {
    const submissions = [];
    const view = renderModelSettings({
      onCreateCustomProvider: async (input) => {
        submissions.push(input);
        return false;
      },
    });
    await user.click(
      screen.getByRole("button", { name: "Add model", exact: true }),
    );
    const dialog = await chooseModelSource(user, "Custom / other service");
    assert.equal(
      within(dialog).queryByRole("combobox", { name: "Protocol" }),
      null,
    );
    const address = within(dialog).getByRole("textbox", {
      name: "Request URL (Endpoint)",
    });
    await user.type(address, endpoint);
    if (protocol === "gemini_native") {
      await user.click(
        within(dialog).getByRole("checkbox", {
          name: "This is a Gemini Native service root",
        }),
      );
      assert.equal(
        within(dialog)
          .getByRole("checkbox", {
            name: "This is a Gemini Native service root",
            exact: true,
          })
          .getAttribute("aria-checked"),
        "true",
      );
    } else {
      assert.equal(
        within(dialog).queryByRole("combobox", { name: "Protocol" }),
        null,
      );
      assert.match(
        within(dialog).getByRole("status").textContent,
        new RegExp(label),
      );
    }
    assert.equal(address.value, endpoint);
    assert.doesNotMatch(dialog.textContent, /Request endpoint:/);
    if (protocol === "gemini_native")
      assert.match(
        dialog.textContent,
        /Gemini model paths are generated automatically/,
      );
    await user.type(within(dialog).getByLabelText("API key"), "example-key");
    await user.type(
      within(dialog).getByRole("textbox", { name: "Model ID" }),
      "example-model",
    );
    await user.click(
      within(dialog).getByRole("button", { name: "Save", exact: true }),
    );
    assert.deepEqual(submissions, [
      {
        displayName: "example.com",
        protocol,
        normalizedBaseUrl: endpoint,
        apiKey: "example-key",
        model: { id: "example-model" },
      },
    ]);
    view.unmount();
  }
});

test("a service root needs explicit Gemini confirmation and an endpoint replaces that choice", async () => {
  const user = userEvent.setup({ document });
  const submissions = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submissions.push(input);
      return false;
    },
  });
  await user.click(
    screen.getByRole("button", { name: "Add model", exact: true }),
  );
  const dialog = await chooseModelSource(user, "Custom / other service");
  await user.type(within(dialog).getByLabelText("API key"), "example-key");
  await user.type(
    within(dialog).getByRole("textbox", { name: "Model ID" }),
    "example-model",
  );
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.type(address, "https://api.openai.com");
  assert.equal(within(dialog).queryByRole("alert"), null);
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.equal(submissions.length, 0);
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /If this is a Gemini Native service root, confirm below/,
  );
  assert.equal(address.getAttribute("aria-invalid"), "true");
  assert.equal(document.activeElement, address);
  await user.click(
    within(dialog).getByRole("checkbox", {
      name: "This is a Gemini Native service root",
    }),
  );
  assert.equal(within(dialog).queryByRole("alert"), null);
  assert.equal(address.getAttribute("aria-invalid"), null);
  await user.clear(address);
  await user.type(address, "https://example.com/v1/responses");
  assert.equal(
    within(dialog).queryByRole("combobox", { name: "Protocol" }),
    null,
  );
  assert.match(
    within(dialog).getByRole("status").textContent,
    /OpenAI Responses/,
  );
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.equal(submissions[0].protocol, "openai_responses");
  assert.equal(
    submissions[0].normalizedBaseUrl,
    "https://example.com/v1/responses",
  );
});

test("invalid endpoints explain the problem before submission and keep the other fields", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.type(address, "https://example.com/v1");
  await user.type(within(dialog).getByLabelText("API key"), "fake-test-key");
  await user.type(
    within(dialog).getByRole("textbox", { name: "Model ID" }),
    "my-model",
  );
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /endpoint ending/,
  );
  assert.equal(address.getAttribute("aria-invalid"), "true");
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.equal(submitted.length, 0);
  assert.equal(document.activeElement, address);
  assert.equal(within(dialog).getByLabelText("API key").value, "fake-test-key");
  await user.clear(address);
  await user.type(address, "https://example.com/v1/responses");
  assert.equal(within(dialog).queryByRole("alert"), null);
  assert.equal(
    within(dialog).getByRole("button", { name: "Save", exact: true }).disabled,
    false,
  );
  assert.equal(submitted.length, 0);
});

test("Save explains each missing custom model field instead of silently doing nothing", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  const save = within(dialog).getByRole("button", {
    name: "Save",
    exact: true,
  });
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  const key = within(dialog).getByLabelText("API key");
  const modelId = within(dialog).getByRole("textbox", { name: "Model ID" });
  assert.equal(save.disabled, false);
  assert.equal(within(dialog).queryByRole("alert"), null);
  assert.equal(address.getAttribute("aria-invalid"), null);

  await user.click(save);
  assert.equal(submitted.length, 0);
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /Enter the request URL\./,
  );
  assert.equal(address.getAttribute("aria-invalid"), "true");
  assert.equal(key.getAttribute("aria-invalid"), "true");
  assert.equal(accessibleDescription(key), "Enter an API key.");
  assert.equal(modelId.getAttribute("aria-invalid"), "true");
  assert.equal(accessibleDescription(modelId), "Enter a model ID.");
  assert.equal(document.activeElement, address);

  await user.type(address, "https://example.com/v1/chat/completions");
  assert.equal(within(dialog).queryByRole("alert"), null);
  assert.equal(address.getAttribute("aria-invalid"), null);
  await user.click(save);
  assert.equal(submitted.length, 0);
  assert.equal(document.activeElement, key);

  await user.type(key, "example-key");
  assert.equal(key.getAttribute("aria-invalid"), null);
  assert.doesNotMatch(dialog.textContent, /Enter an API key/);
  await user.type(modelId, "example-model");
  assert.doesNotMatch(dialog.textContent, /Enter a model ID/);
  await user.click(save);
  assert.deepEqual(submitted, [
    {
      displayName: "example.com",
      protocol: "openai_chat_completions",
      normalizedBaseUrl: "https://example.com/v1/chat/completions",
      apiKey: "example-key",
      model: { id: "example-model" },
    },
  ]);
});

test("a pasted address is checked at once without waiting for blur", async () => {
  const user = userEvent.setup({ document });
  renderModelSettings();
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.click(address);
  await user.paste("https://api.example.com/v1/");
  assert.equal(document.activeElement, address);
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /endpoint ending in \/chat\/completions/,
  );
  assert.equal(address.getAttribute("aria-invalid"), "true");
});

test("a version-suffixed Base URL can be completed to a chat completions endpoint", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.click(address);
  await user.paste("https://api.example.com/v1/");
  await user.click(
    within(dialog).getByRole("button", {
      name: "Use https://api.example.com/v1/chat/completions",
    }),
  );
  assert.equal(address.value, "https://api.example.com/v1/chat/completions");
  assert.equal(document.activeElement, address);
  assert.equal(within(dialog).queryByRole("alert"), null);
  assert.equal(address.getAttribute("aria-invalid"), null);
  assert.match(
    within(dialog).getByRole("status").textContent,
    /Detected API: OpenAI Chat Completions/,
  );
  await user.type(within(dialog).getByLabelText("API key"), "example-key");
  await user.type(
    within(dialog).getByRole("textbox", { name: "Model ID" }),
    "example-model",
  );
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.deepEqual(submitted, [
    {
      displayName: "api.example.com",
      protocol: "openai_chat_completions",
      normalizedBaseUrl: "https://api.example.com/v1/chat/completions",
      apiKey: "example-key",
      model: { id: "example-model" },
    },
  ]);
});

test("typed endpoint problems wait for blur or submission, and LAN HTTP explains the plaintext risk", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.type(address, "https://example.com/api");
  assert.equal(within(dialog).queryByRole("alert"), null);
  await user.keyboard("{Enter}");
  assert.equal(submitted.length, 0);
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /endpoint ending in \/chat\/completions/,
  );
  assert.equal(within(dialog).queryByRole("button", { name: /^Use / }), null);
  assert.equal(document.activeElement, address);

  await user.clear(address);
  await user.type(address, "http://192.168.1.5:1234/v1");
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /API key would be sent unencrypted.*localhost, 127\.0\.0\.1, \[::1\].*HTTPS/,
  );
  assert.equal(within(dialog).queryByRole("button", { name: /^Use / }), null);
  assert.equal(submitted.length, 0);
});

test("a scheme-less address reaches the form's own explanation instead of native URL validation", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateCustomProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = await chooseModelSource(user, "Custom / other service");
  const address = within(dialog).getByRole("textbox", {
    name: "Request URL (Endpoint)",
  });
  await user.type(address, "api.example.com/v1");
  await user.click(
    within(dialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.equal(submitted.length, 0);
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /Enter a valid URL/,
  );
  assert.equal(
    accessibleDescription(within(dialog).getByLabelText("API key")),
    "Enter an API key.",
  );
  assert.equal(document.activeElement, address);
});

test("Save names the missing vendor and the missing preset fields", async () => {
  const user = userEvent.setup({ document });
  const submitted = [];
  renderModelSettings({
    onCreateBuiltinProvider: async (input) => {
      submitted.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Add model" }));
  const dialog = screen.getByRole("dialog", { name: "Add model" });
  const save = within(dialog).getByRole("button", {
    name: "Save",
    exact: true,
  });
  const vendor = within(dialog).getByRole("combobox", { name: "Model vendor" });
  assert.equal(save.disabled, false);
  await user.click(save);
  assert.equal(vendor.getAttribute("aria-invalid"), "true");
  assert.equal(accessibleDescription(vendor), "Select a model vendor first.");
  assert.equal(document.activeElement, vendor);

  await user.click(vendor);
  await user.click(
    await screen.findByRole("option", { name: "DeepSeek", exact: true }),
  );
  assert.equal(vendor.getAttribute("aria-invalid"), null);
  assert.doesNotMatch(dialog.textContent, /Select a model vendor first/);
  await user.click(save);
  const key = within(dialog).getByLabelText("API key");
  const model = within(dialog).getByRole("combobox", { name: "Model ID" });
  assert.equal(key.getAttribute("aria-invalid"), "true");
  assert.equal(accessibleDescription(key), "Enter an API key.");
  assert.equal(model.getAttribute("aria-invalid"), "true");
  assert.equal(accessibleDescription(model), "Choose a model ID.");
  assert.equal(document.activeElement, key);
  assert.equal(submitted.length, 0);

  await user.type(key, "official-secret");
  await user.click(model);
  await user.click(
    await screen.findByRole("option", { name: "deepseek-flash", exact: true }),
  );
  assert.equal(model.getAttribute("aria-invalid"), null);
  await user.click(save);
  assert.deepEqual(submitted, [
    {
      providerId: "deepseek",
      baseUrl: "https://api.deepseek.com",
      apiKey: "official-secret",
      model: { id: "deepseek-flash" },
    },
  ]);
});

test("editing keeps Save disabled without changes and explains an emptied model ID", async () => {
  const user = userEvent.setup({ document });
  const changes = [];
  const source = {
    id: "source-empty-model",
    builtinProviderId: null,
    displayName: "Team",
    protocol: "openai_chat_completions",
    normalizedBaseUrl: "https://example.com/v1/chat/completions",
    state: "ready",
    credentialStatus: "ready",
    enabled: true,
    providerRevision: "7",
    sourceGeneration: "11",
    catalogGeneration: "13",
    models: [
      {
        id: "model-a",
        displayName: "Model A",
        metadata: {},
        metadataProvenance: "unknown",
        testStatus: "connected",
        ready: true,
      },
    ],
  };
  renderModelSettings({
    models: { ...readySettingsModels, customProviders: [source] },
    onSaveCustomModel: async (input) => {
      changes.push(input);
      return {
        accepted: true,
        applied: [],
        source,
        modelId: input.nextModelId,
        reviewRequired: false,
      };
    },
  });
  await user.click(screen.getByRole("button", { name: "Edit" }));
  const dialog = screen.getByRole("dialog", { name: "Edit model" });
  const save = within(dialog).getByRole("button", {
    name: "Save",
    exact: true,
  });
  assert.equal(save.disabled, true);
  const modelId = within(dialog).getByRole("textbox", { name: "Model ID" });
  await user.clear(modelId);
  assert.equal(save.disabled, false);
  await user.click(save);
  assert.equal(changes.length, 0);
  assert.equal(modelId.getAttribute("aria-invalid"), "true");
  assert.equal(accessibleDescription(modelId), "Enter a model ID.");
  assert.equal(document.activeElement, modelId);
});

test("model dialog feedback is visible: defined error color, invalid borders and dimmed disabled actions", () => {
  const read = (file) =>
    readFileSync(new URL(`../frontend/src/${file}`, import.meta.url), "utf8");
  const stylesheet = read("index.css");
  const definitions = `${read("styles/metask-tokens.css")}\n${stylesheet}`;
  const form = read("features/settings/CustomModelsSettings.tsx");
  const tokens = new Set(form.match(/--ui-[a-z0-9-]+/gu));
  assert.ok(tokens.has("--ui-content-error"));
  for (const token of tokens)
    assert.match(definitions, new RegExp(`${token}\\s*:`, "u"), token);
  assert.match(
    stylesheet,
    /\.settings-model-form \.settings-custom-provider-input\[aria-invalid="true"\],\s*\.settings-model-form \.selection-trigger\.settings-control\[aria-invalid="true"\]\s*\{[^}]*border-color:/su,
  );
  assert.match(
    stylesheet,
    /\.settings-model-form-actions button:disabled\s*\{[^}]*opacity: 0\.5;/su,
  );
});

test("only version-suffixed Base URLs get a chat completions suggestion", () => {
  const long = `https://example.com/${"a".repeat(2020)}/v1`;
  for (const [input, expected] of [
    [
      "https://api.example.com/v1",
      "https://api.example.com/v1/chat/completions",
    ],
    [
      "https://api.example.com/v1//",
      "https://api.example.com/v1/chat/completions",
    ],
    [
      " https://open.bigmodel.cn/api/paas/v4 ",
      "https://open.bigmodel.cn/api/paas/v4/chat/completions",
    ],
    [
      "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
    ],
    ["http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/chat/completions"],
    ["https://api.example.com", null],
    ["https://api.example.com/anthropic", null],
    ["https://generativelanguage.googleapis.com/v1beta", null],
    ["https://api.example.com/v1/chat/completions", null],
    ["https://api.example.com/v1/responses", null],
    ["http://192.168.1.5:1234/v1", null],
    ["https://api.example.com/v1?key=1", null],
    ["https://user@api.example.com/v1", null],
    ["not a url", null],
    [long, null],
  ])
    assert.equal(suggestChatCompletionsEndpoint(input), expected, input);
});

test("model test rejection and exceptions produce an actionable local message", async () => {
  const user = userEvent.setup({ document });
  let attempts = 0;
  const source = {
    id: "test-source",
    displayName: "Hidden provider",
    builtinProviderId: null,
    enabled: true,
    credentialStatus: "ready",
    providerRevision: "7",
    sourceGeneration: "11",
    catalogGeneration: "13",
    models: [{ id: "model-a", displayName: "Model A", testStatus: "untested" }],
  };
  renderModelSettings({
    models: { ...readySettingsModels, customProviders: [source] },
    onTestCustomModel: async () => {
      attempts++;
      if (attempts === 1) return false;
      throw Error("disconnected");
    },
  });
  for (let i = 0; i < 2; i++) {
    await user.click(
      screen.getByRole("button", { name: "Test model", exact: true }),
    );
    assert.match(
      screen.getByRole("alert").textContent,
      /Test start for Model A not yet confirmed/,
    );
  }
  assert.equal(attempts, 2);
});

test("delete confirmation uses current revisions and recovers focus when the row disappears", async () => {
  const user = userEvent.setup({ document });
  const calls = [];
  const source = {
    id: "delete-source",
    displayName: "Hidden provider",
    builtinProviderId: null,
    enabled: true,
    credentialStatus: "ready",
    providerRevision: "7",
    sourceGeneration: "11",
    catalogGeneration: "13",
    models: [{ id: "model-a", displayName: "Model A", testStatus: "untested" }],
  };
  const view = renderModelSettings({
    models: { ...readySettingsModels, customProviders: [source] },
    onRemoveCustomModel: async (...input) => {
      calls.push(input);
      return false;
    },
  });
  await user.click(screen.getByRole("button", { name: "Remove", exact: true }));
  const dialog = screen.getByRole("alertdialog");
  view.rerenderModels({
    ...readySettingsModels,
    customProviders: [
      { ...source, providerRevision: "8", catalogGeneration: "14" },
    ],
  });
  await user.click(
    within(dialog).getByRole("button", { name: "Remove", exact: true }),
  );
  assert.deepEqual(calls, [["delete-source", "8", "14", "model-a"]]);
  assert.match(
    within(dialog).getByRole("alert").textContent,
    /Model removal result not yet confirmed/,
  );
  view.rerenderModels({ ...readySettingsModels, customProviders: [] });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(screen.queryByRole("alertdialog"), null);
  assert.equal(
    document.activeElement,
    screen.getByRole("button", { name: "Add model" }),
  );
  assert.equal(calls.length, 1);
});

test("Models manages user-added models without an official catalog or default selection", () => {
  const view = renderModelSettings();
  assert.ok(screen.getByRole("heading", { name: "Models", exact: true }));
  assert.ok(screen.getByRole("heading", { name: "Custom models" }));
  assert.ok(screen.getByRole("button", { name: "Add model" }));
  assert.equal(screen.queryByText("Model One"), null);
  assert.equal(screen.queryByText("Model Two"), null);
  assert.equal(screen.queryByRole("button", { name: "Sync again" }), null);
  assert.equal(screen.queryByRole("combobox", { name: "Default model" }), null);
  assert.equal(screen.queryByText("Current default"), null);
  assert.deepEqual(view.selections.model, []);
});

test("Models adds a model independently without listing or reusing legacy providers", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const creations = [];
  const additions = [];
  const removals = [];
  renderSettings(readySettingsAccount, {
    customProviderCapabilities: completeModelCapabilities,
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
    onCreateCustomProvider(input) {
      creations.push(input);
      return Promise.resolve(false);
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

  await user.click(screen.getByRole("button", { name: "Add model" }));
  const addDialog = screen.getByRole("dialog", { name: "Add model" });
  await user.click(
    within(addDialog).getByRole("combobox", { name: "Model vendor" }),
  );
  await screen.findByRole("option", {
    name: "Custom / other service",
    exact: true,
  });
  assert.deepEqual(
    screen.getAllByRole("option").map((option) => option.textContent),
    ["Custom / other service"],
  );
  assert.equal(
    screen.queryByText("Multi-model provider", { exact: true }),
    null,
  );
  await user.click(
    screen.getByRole("option", { name: "Custom / other service", exact: true }),
  );
  assert.equal(
    within(addDialog).queryByRole("combobox", {
      name: "Connection",
      exact: true,
    }),
    null,
  );
  assert.equal(
    within(addDialog).queryByRole("option", { name: /api.openai.com/ }),
    null,
  );
  await user.type(within(addDialog).getByLabelText("API key"), "new-model-key");
  await user.type(
    within(addDialog).getByRole("textbox", { name: "Request URL (Endpoint)" }),
    "https://api.openai.com/v1/chat/completions",
  );
  await user.type(
    within(addDialog).getByRole("textbox", { name: "Model ID" }),
    "gpt-5.6-sol",
  );
  await user.click(
    within(addDialog).getByRole("button", { name: "Save", exact: true }),
  );
  assert.deepEqual(additions, []);
  assert.deepEqual(creations, [
    {
      displayName: "api.openai.com",
      protocol: "openai_chat_completions",
      normalizedBaseUrl: "https://api.openai.com/v1/chat/completions",
      apiKey: "new-model-key",
      model: { id: "gpt-5.6-sol" },
    },
  ]);
  const dialog = addDialog;
  await user.click(within(dialog).getByRole("button", { name: "Cancel" }));
  await user.click(screen.getByRole("button", { name: "Remove" }));
  const confirmation = screen.getByRole("alertdialog");
  assert.ok(
    within(confirmation).getByRole("heading", {
      name: "Remove model?",
      exact: true,
    }),
  );
  assert.match(confirmation.textContent, /Model A/);
  assert.doesNotMatch(confirmation.textContent, /provider/i);
  await user.click(
    within(confirmation).getByRole("button", { name: "Remove", exact: true }),
  );
  assert.deepEqual(removals, [["provider-multi", "3", "7", "model-a"]]);
});

test("Settings signs out only after confirming in a modal", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let logoutCalls = 0;
  let backCalls = 0;
  renderSettings(readySettingsAccount, {
    initialSection: "account",
    onLogout() {
      logoutCalls += 1;
    },
    onBack() {
      backCalls += 1;
    },
  });

  const heading = screen.getByRole("heading", { name: "Account", exact: true });
  await waitFor(() => assert.ok(document.activeElement === heading));
  const trigger = screen.getByRole("button", { name: "Sign out" });
  assert.equal(screen.queryByRole("heading", { name: "Security" }), null);
  assert.equal(screen.queryByText(/Sign in again to create new tasks/), null);
  await user.click(trigger);

  const dialog = await screen.findByRole("alertdialog", { name: "Sign out" });
  const cancel = within(dialog).getByRole("button", { name: "Cancel" });
  await waitFor(() => assert.ok(document.activeElement === cancel));
  assert.match(dialog.textContent, /Sign in again to create new tasks/);
  assert.equal(logoutCalls, 0);

  await user.keyboard("{Escape}");
  assert.equal(screen.queryByRole("alertdialog"), null);
  await waitFor(() => assert.ok(document.activeElement === trigger));
  assert.equal(backCalls, 0);
  assert.equal(logoutCalls, 0);

  await user.click(trigger);
  const confirmation = await screen.findByRole("alertdialog", {
    name: "Sign out",
  });
  await user.click(
    within(confirmation).getByRole("button", { name: "Sign out" }),
  );
  assert.equal(screen.queryByRole("alertdialog"), null);
  assert.equal(logoutCalls, 1);
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

  assert.equal(screen.queryByRole("button", { name: "Sync again" }), null);

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

test("Official catalog failures do not affect model management or Account identity", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount, {
    models: settingsModels({}, { errorCode: "catalog_unavailable" }),
    initialSection: "models",
  });

  assert.equal(screen.queryByText("Model One"), null);
  assert.equal(screen.queryByRole("alert"), null);

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

function renderComposer(overrides = {}, afterDraftCommit) {
  const textareaRef = createRef();
  let submissions = 0;
  let setDraftFromTest = null;
  const initialDraft = overrides.draft ?? {
    kind: "text",
    text: "请检查当前实现",
  };
  const externalOnDraftChange = overrides.onDraftChange;
  let latestDraft = initialDraft;
  let setScopeFromTest;
  let setHistoryAvailableFromTest;
  let setSlashCommandsFromTest;
  let setStopStateFromTest;
  function ComposerHarness() {
    const [localDraft, setDraft] = useState(initialDraft);
    const owner = overrides.taskDraftId
      ? useTaskDrafts(overrides.taskDraftId)
      : null;
    const draft = owner?.draft ?? localDraft;
    useLayoutEffect(() => {
      afterDraftCommit?.(draft, textareaRef.current);
    }, [afterDraftCommit, draft]);
    const [scope, setScope] = useState(overrides.draftScope ?? "task:3");
    const [historyAvailable, setHistoryAvailable] = useState(true);
    const [commands, setCommands] = useState(overrides.slashCommands ?? []);
    setSlashCommandsFromTest = setCommands;
    const [stopState, setStopState] = useState({
      action: overrides.stopAction ?? null,
      disabled: overrides.stopDisabled ?? false,
    });
    setStopStateFromTest = setStopState;
    setHistoryAvailableFromTest = setHistoryAvailable;
    setScopeFromTest = setScope;
    setDraftFromTest = setDraft;
    function commitDraft(value) {
      latestDraft = value;
      if (owner) owner.commitDraft(overrides.taskDraftId, value);
      else setDraft(value);
      externalOnDraftChange?.(value);
      return true;
    }
    const footer = createElement(ComposerFooter, {
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
      ...overrides,
      slashCommands: commands,
      stopAction: stopState.action,
      stopDisabled: stopState.disabled,
      draft,
      draftScope: scope,
      inputHistory:
        overrides.inputHistory && historyAvailable
          ? {
              load: overrides.inputHistory.load,
              currentDraft: () =>
                owner ? owner.currentDraft(overrides.taskDraftId) : latestDraft,
              commitDraft,
            }
          : undefined,
      onDraftChange: commitDraft,
    });
    return overrides.shell
      ? createElement(AppShell, overrides.shell, footer)
      : footer;
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
      latestDraft = value;
      setDraftFromTest(value);
    },
    setScope(value) {
      setScopeFromTest(value);
    },
    setHistoryAvailable(value) {
      setHistoryAvailableFromTest(value);
    },
    setSlashCommands(value) {
      setSlashCommandsFromTest(value);
    },
    setStopState(value) {
      setStopStateFromTest(value);
    },
    currentDraft: () => latestDraft,
  };
}

test("Composer browses a frozen multiline input history and restores the empty draft", async () => {
  const entries = ["A", "B\nsecond line", "C"];
  const empty = { kind: "text", text: "" };
  const composer = renderComposer({
    draft: empty,
    inputHistory: { load: async () => entries },
  });
  const key = (value) => fireEvent.keyDown(composer.textarea, { key: value });
  key("ArrowUp");
  await waitFor(() => assert.equal(composer.textarea.value, "C"));
  entries.unshift("older");
  entries.push("newer");
  key("ArrowUp");
  assert.equal(composer.textarea.value, "B\nsecond line");
  key("ArrowUp");
  key("ArrowUp");
  assert.equal(composer.textarea.value, "A");
  key("ArrowDown");
  key("ArrowDown");
  key("ArrowDown");
  assert.equal(composer.textarea.value, "");
  assert.equal(composer.currentDraft(), empty);
  assert.equal(key("ArrowDown"), true);
  assert.equal(composer.submissions(), 0);
});

test("Composer keeps browsing when another arrow arrives before draft effects run", async () => {
  const composer = renderComposer(
    {
      draft: { kind: "text", text: "" },
      inputHistory: { load: async () => ["first", "second", "third"] },
    },
    (draft, editor) => {
      if (draft.text !== "third") return;
      const arrow = new window.KeyboardEvent("keydown", {
        key: "ArrowUp",
        bubbles: true,
        cancelable: true,
      });
      assert.equal(editor.dispatchEvent(arrow), false);
    },
  );
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "second"));
  assert.equal(fireEvent.keyDown(composer.textarea, { key: "ArrowUp" }), false);
  assert.equal(composer.textarea.value, "first");
});

test("Composer history requires a completely empty text draft", async () => {
  for (const draft of [
    { kind: "text", text: "edited" },
    { kind: "text", text: " " },
    { kind: "text", text: "\n" },
    { kind: "text", text: "", attachmentsReloadRequired: true },
    { kind: "multimodal", text: "", attachments: [] },
    {
      kind: "multimodal",
      text: "",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "image",
          format: "png",
          displayName: "preserve.png",
          sizeBytes: "1536",
        },
      ],
    },
  ]) {
    let reads = 0;
    const composer = renderComposer({
      draft,
      inputHistory: {
        load: async () => {
          reads++;
          return ["old"];
        },
      },
    });
    fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
    await act(async () => {});
    assert.equal(reads, 0);
    assert.equal(composer.currentDraft(), draft);
    cleanup();
  }
});

test("Composer history exits on editing and external draft commits before React renders", async () => {
  for (const external of [
    { kind: "text", text: "Reference\nB" },
    { kind: "multimodal", text: "B", attachments: [] },
    {
      kind: "multimodal",
      text: "B",
      attachments: [
        {
          token: "a".repeat(48),
          kind: "image",
          format: "png",
          displayName: "preserve.png",
          sizeBytes: "1536",
        },
      ],
    },
    { kind: "text", text: "B", attachmentsReloadRequired: true },
    { kind: "text", text: "B" },
  ]) {
    const composer = renderComposer({
      draft: { kind: "text", text: "" },
      inputHistory: { load: async () => ["A", "B"] },
    });
    fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
    await waitFor(() => assert.equal(composer.textarea.value, "B"));
    act(() => {
      composer.setDraft(external);
      fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
    });
    fireEvent.keyDown(composer.textarea, { key: "ArrowDown" });
    fireEvent.keyDown(composer.textarea, { key: "ArrowDown" });
    assert.equal(composer.currentDraft(), external);
    cleanup();
  }
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    inputHistory: { load: async () => ["A", "B"] },
  });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "B"));
  fireEvent.change(composer.textarea, { target: { value: "B edited" } });
  assert.equal(fireEvent.keyDown(composer.textarea, { key: "ArrowUp" }), true);
  assert.equal(composer.textarea.value, "B edited");
});

test("Composer keeps Slash navigation ahead of history and resumes after dismissing its menu", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    slashCommands: [{ name: "new", enabled: true, disabledReason: null }],
    inputHistory: { load: async () => ["A", "/new"] },
  });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "/new"));
  assert.equal(composer.textarea.getAttribute("aria-expanded"), "true");
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  fireEvent.keyDown(composer.textarea, { key: "ArrowDown" });
  assert.equal(composer.textarea.value, "/new");
  assert.equal(composer.submissions(), 0);
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  assert.equal(composer.textarea.value, "A");
});

test("Composer retains history while moving the caret, selecting or copying text", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    inputHistory: { load: async () => ["A", "B"] },
  });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "B"));
  composer.textarea.setSelectionRange(0, 1);
  fireEvent.select(composer.textarea);
  fireEvent.copy(composer.textarea);
  fireEvent.keyDown(composer.textarea, { key: "ArrowLeft" });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  assert.equal(composer.textarea.value, "A");
});

test("Composer ignores a history response after unmount", async () => {
  let resolve;
  let writes = 0;
  renderComposer({
    draft: { kind: "text", text: "" },
    inputHistory: {
      load: () =>
        new Promise((done) => {
          resolve = done;
        }),
    },
    onDraftChange() {
      writes++;
    },
  });
  fireEvent.keyDown(screen.getByRole("combobox", { name: "" }), {
    key: "ArrowUp",
  });
  const writesBeforeUnmount = writes;
  cleanup();
  await act(async () => resolve(["stale"]));
  assert.equal(writes, writesBeforeUnmount);
});

test("Composer can start history from an uncached empty Task draft", async () => {
  let resolve;
  const composer = renderComposer({
    taskDraftId: "uncached-history-draft",
    inputHistory: {
      load: () =>
        new Promise((done) => {
          resolve = done;
        }),
    },
  });
  assert.equal(composer.textarea.value, "");
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  assert.ok(screen.getByText("Loading input history…"));
  await act(async () => resolve(["previous input"]));
  await waitFor(() => assert.equal(composer.textarea.value, "previous input"));
});

test("Composer leaves history when its source becomes unavailable", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    inputHistory: { load: async () => ["A", "B"] },
  });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "B"));
  act(() => composer.setHistoryAvailable(false));
  act(() => composer.setHistoryAvailable(true));
  fireEvent.keyDown(composer.textarea, { key: "ArrowDown" });
  assert.equal(composer.textarea.value, "B");
});

test("Composer recall and clearing preserve the ordinary Send and Stop rules", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
    inputHistory: { load: async () => ["previous"] },
  });
  assert.ok(screen.getByRole("button", { name: "Stop task" }));
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "previous"));
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  assert.ok(screen.getByRole("button", { name: "Send" }));
  fireEvent.keyDown(composer.textarea, { key: "ArrowDown" });
  assert.ok(screen.getByRole("button", { name: "Stop task" }));
  assert.equal(composer.submissions(), 0);
});

test("Composer protects modified arrows, IME, scope changes and pending history reads", async () => {
  let resolve;
  let reads = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    inputHistory: {
      load: () => {
        reads++;
        return new Promise((done) => {
          resolve = done;
        });
      },
    },
  });
  for (const modifier of [
    "shiftKey",
    "ctrlKey",
    "metaKey",
    "altKey",
    "isComposing",
  ]) {
    assert.equal(
      fireEvent.keyDown(composer.textarea, {
        key: "ArrowUp",
        [modifier]: true,
      }),
      true,
    );
  }
  assert.equal(reads, 0);
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  assert.equal(reads, 1);
  act(() => composer.setScope("task:4"));
  await act(async () => resolve(["stale"]));
  assert.equal(composer.textarea.value, "");
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  fireEvent.change(composer.textarea, { target: { value: "new draft" } });
  await act(async () => resolve(["stale"]));
  assert.equal(composer.textarea.value, "new draft");
});

test("Composer reports failed history reads and permits an explicit retry", async () => {
  let reads = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    inputHistory: {
      load: async () => {
        if (++reads === 1) throw new Error("read failed");
        return ["recovered"];
      },
    },
  });
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await screen.findByText("Couldn't load input history. Press ↑ to retry.");
  assert.equal(composer.textarea.value, "");
  fireEvent.keyDown(composer.textarea, { key: "ArrowUp" });
  await waitFor(() => assert.equal(composer.textarea.value, "recovered"));
});

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

test("Composer model notice explains the blocker and opens its recovery action", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let opens = 0;
  renderComposer({
    canSubmit: false,
    modelNotice: createElement(ModelSetupNotice, {
      notice: { reason: "choose", action: "choose_model" },
      disabled: false,
      onAction(action) {
        assert.equal(action, "choose_model");
        opens += 1;
      },
    }),
  });
  assert.match(
    screen.getByRole("status").textContent,
    /Choose an available model/,
  );
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  await user.click(screen.getByRole("button", { name: "Choose a model" }));
  assert.equal(opens, 1);
});

test("Composer does not show model recovery for a ready selection", () => {
  renderComposer();
  assert.equal(screen.queryByRole("button", { name: "Choose a model" }), null);
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

function renderSkillComposer(overrides = {}) {
  const skill = {
    skillId: "builtin.review",
    skillPolicyKey: "review",
    invocationName: "review",
    displayName: "Review",
    description: "Review a target",
    argumentNames: ["target"],
    maxValues: 1,
    enabled: true,
  };
  const composer = renderComposer({
    draft: {
      kind: "skill",
      ...skill,
      catalogRevision: "4",
      selectionRevision: "1",
      argumentValues: ["就是这个情况"],
    },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "4",
      selectionRevision: "1",
      skills: [skill],
      issues: [],
    },
    ...overrides,
  });
  return {
    ...composer,
    input: composer.textarea,
  };
}

for (const kind of ["text", "skill"]) {
  test(`Composer ${kind} keeps IME confirmation native before and after composition events`, () => {
    const composer =
      kind === "skill" ? renderSkillComposer() : renderComposer();
    const input = composer.input ?? composer.textarea;
    const original = input.value;
    const confirmingEnter = () => {
      assert.equal(
        fireEvent.keyDown(input, {
          key: "Enter",
          keyCode: 229,
          isComposing: false,
        }),
        true,
      );
      assert.equal(composer.submissions(), 0);
    };
    confirmingEnter();
    fireEvent.compositionStart(input);
    assert.equal(
      fireEvent.keyDown(input, { key: "Enter", isComposing: false }),
      true,
    );
    assert.equal(composer.submissions(), 0);
    fireEvent.compositionEnd(input, { data: original });
    confirmingEnter();
    assert.equal(input.value, original);
    fireEvent.keyUp(input, { key: "Enter", keyCode: 13 });
    fireEvent.keyDown(input, { key: "Enter", keyCode: 13 });
    assert.equal(composer.submissions(), 1);
  });

  test(`Composer ${kind} submits only bare or platform-primary Enter`, () => {
    const saved = Object.getOwnPropertyDescriptor(navigator, "platform");
    try {
      for (const [platform, primary, other] of [
        ["MacIntel", "metaKey", "ctrlKey"],
        ["Win32", "ctrlKey", "metaKey"],
      ]) {
        Object.defineProperty(navigator, "platform", {
          configurable: true,
          value: platform,
        });
        const composer =
          kind === "skill" ? renderSkillComposer() : renderComposer();
        const input = composer.input ?? composer.textarea;
        for (const keys of [
          { shiftKey: true },
          { altKey: true },
          { [other]: true },
          { [primary]: true, shiftKey: true },
          { [primary]: true, altKey: true },
          { metaKey: true, ctrlKey: true },
        ])
          fireEvent.keyDown(input, { key: "Enter", ...keys });
        assert.equal(composer.submissions(), 0);
        fireEvent.keyDown(input, { key: "Enter", [primary]: true });
        fireEvent.keyDown(input, { key: "Enter" });
        assert.equal(composer.submissions(), 2);
        cleanup();
      }
    } finally {
      if (saved) Object.defineProperty(navigator, "platform", saved);
      else delete navigator.platform;
    }
  });
}

test("Slash preserves multiline editing, modified arrows and reverse focus navigation", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "/" },
    slashCommands: [{ name: "new", enabled: true, disabledReason: null }],
    onSlashCommand: () => assert.fail("editing must not select a command"),
  });
  const before = document.createElement("button");
  before.textContent = "Before composer";
  document.body.prepend(before);
  const user = userEvent.setup({ document });
  try {
    composer.textarea.focus();
    for (const modifier of ["shiftKey", "metaKey", "ctrlKey", "altKey"])
      assert.equal(
        fireEvent.keyDown(composer.textarea, {
          key: "ArrowUp",
          [modifier]: true,
        }),
        true,
      );
    await user.keyboard("{Shift>}{Enter}{/Shift}");
    assert.equal(composer.textarea.value, "\n/");
    await user.tab({ shift: true });
    assert.equal(document.activeElement, before);
    assert.equal(composer.textarea.getAttribute("aria-expanded"), "false");
  } finally {
    before.remove();
  }
});

test("Slash Tab leaves an unknown or disabled candidate instead of trapping focus", async () => {
  const user = userEvent.setup({ document });
  for (const slashCommands of [
    [],
    [{ name: "new", enabled: false, disabledReason: "already_new_task" }],
  ]) {
    const composer = renderComposer({
      draft: { kind: "text", text: "/" },
      slashCommands,
    });
    const after = document.createElement("button");
    after.textContent = "After composer";
    document.body.append(after);
    try {
      composer.textarea.focus();
      fireEvent.keyDown(composer.textarea, { key: "Enter" });
      assert.equal(composer.submissions(), 0);
      await user.tab();
      assert.equal(
        document.activeElement?.getAttribute("aria-label"),
        "Add to message",
      );
      await user.tab();
      assert.ok(document.activeElement === after);
    } finally {
      after.remove();
      cleanup();
    }
  }
});

test("Slash Tab releases focus when its highlighted command becomes disabled", async () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "/" },
    slashCommands: [{ name: "new", enabled: true, disabledReason: null }],
    onSlashCommand: () => assert.fail("disabled command must not run"),
  });
  assert.match(composer.textarea.getAttribute("aria-activedescendant"), /new/);
  act(() =>
    composer.setSlashCommands([
      { name: "new", enabled: false, disabledReason: "already_new_task" },
    ]),
  );
  const after = document.createElement("button");
  after.textContent = "After composer";
  document.body.append(after);
  try {
    composer.textarea.focus();
    const user = userEvent.setup({ document });
    await user.tab();
    assert.equal(
      document.activeElement?.getAttribute("aria-label"),
      "Add to message",
    );
    await user.tab();
    assert.ok(document.activeElement === after);
    assert.equal(composer.submissions(), 0);
  } finally {
    after.remove();
  }
});

test("Slash ignores the confirming IME key after compositionend", () => {
  const chosen = [];
  const composer = renderComposer({
    draft: { kind: "text", text: "/" },
    slashCommands: [{ name: "new", enabled: true, disabledReason: null }],
    onSlashCommand: (name) => chosen.push(name),
  });
  fireEvent.compositionStart(composer.textarea);
  fireEvent.compositionEnd(composer.textarea);
  for (const key of ["ArrowUp", "ArrowDown", "Escape", "Tab", "Enter"])
    assert.equal(
      fireEvent.keyDown(composer.textarea, { key, keyCode: 229 }),
      true,
    );
  assert.deepEqual(chosen, []);
  assert.equal(composer.textarea.getAttribute("aria-expanded"), "true");
  fireEvent.keyDown(composer.textarea, { key: "Enter", keyCode: 13 });
  assert.deepEqual(chosen, ["new"]);
});

for (const kind of ["empty", "text", "skill"]) {
  test(`Composer double Escape stops with ${kind} draft without submitting or replacing it`, () => {
    let stops = 0;
    const overrides = { stopAction: "run", onStop: () => stops++ };
    const composer =
      kind === "skill"
        ? renderSkillComposer(overrides)
        : renderComposer({
            ...overrides,
            draft: { kind: "text", text: kind === "empty" ? "" : "keep draft" },
          });
    const input = composer.input ?? composer.textarea;
    const original = input.value;
    input.focus();
    fireEvent.keyDown(input, { key: "Escape" });
    assert.equal(stops, 0);
    if (kind === "empty")
      assert.equal(
        screen.getByRole("button", { name: "Press Esc again to stop" })
          .textContent,
        "Esc",
      );
    else {
      assert.ok(screen.getByRole("button", { name: "Send" }));
      assert.equal(
        screen.queryByRole("button", { name: "Press Esc again to stop" }),
        null,
      );
      assert.equal(screen.queryByText("Esc"), null);
    }
    fireEvent.keyDown(input, { key: "Escape", repeat: true });
    assert.equal(stops, 0);
    fireEvent.keyUp(input, { key: "Escape" });
    fireEvent.keyDown(input, { key: "Escape" });
    assert.equal(stops, 1);
    assert.equal(input.value, original);
    assert.equal(composer.submissions(), 0);
  });
}

test("Composer Escape cannot arm without stop eligibility or from an auto-repeat", () => {
  for (const [action, disabled] of [
    [null, false],
    ["run", true],
  ]) {
    const composer = renderComposer({
      draft: { kind: "text", text: "" },
      stopAction: action,
      stopDisabled: disabled,
      onStop: () => assert.fail("unavailable stop must not run"),
    });
    for (let i = 0; i < 2; i++)
      assert.equal(
        fireEvent.keyDown(composer.textarea, { key: "Escape" }),
        true,
      );
    assert.equal(screen.queryByText("Esc"), null);
    cleanup();
  }
  let stops = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
    onStop: () => stops++,
  });
  fireEvent.keyDown(composer.textarea, { key: "Escape", repeat: true });
  assert.ok(screen.getByRole("button", { name: "Stop task" }));
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 0);
  assert.ok(screen.getByRole("button", { name: "Press Esc again to stop" }));
});

test("Composer Escape uses its deadline even before the timeout callback can run", (ctx) => {
  let now = 100;
  ctx.mock.method(performance, "now", () => now);
  let stops = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
    onStop: () => stops++,
  });
  composer.textarea.focus();
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  now += 1001;
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 0);
  now += 999;
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 1);
});

test("Composer restores the Stop icon when confirmation times out", (ctx) => {
  ctx.mock.timers.enable({ apis: ["setTimeout"] });
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
  });
  composer.textarea.focus();
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(
    screen.getByRole("button", { name: "Press Esc again to stop" }).textContent,
    "Esc",
  );
  act(() => ctx.mock.timers.tick(1000));
  assert.ok(
    screen.getByRole("button", { name: "Stop task" }).querySelector("svg"),
  );
});

test("Composer Escape confirmation resets on edits, other actions, scope and stop availability", () => {
  for (const reset of [
    (c) => fireEvent.change(c.textarea, { target: { value: "changed" } }),
    (c) => fireEvent.keyDown(c.textarea, { key: "ArrowLeft" }),
    (c) => fireEvent.pointerDown(c.textarea),
    (c) => {
      fireEvent.compositionStart(c.textarea);
      fireEvent.compositionEnd(c.textarea);
    },
    () => fireEvent.blur(window),
    (c) => act(() => c.setScope("task:another")),
    (c) => {
      act(() => c.setStopState({ action: "run", disabled: true }));
      act(() => c.setStopState({ action: "run", disabled: false }));
    },
    (c) => {
      act(() => c.setStopState({ action: null, disabled: false }));
      act(() => c.setStopState({ action: "run", disabled: false }));
    },
  ]) {
    let stops = 0;
    const composer = renderComposer({
      stopAction: "run",
      onStop: () => stops++,
    });
    composer.textarea.focus();
    fireEvent.keyDown(composer.textarea, { key: "Escape" });
    reset(composer);
    fireEvent.keyDown(composer.textarea, { key: "Escape" });
    assert.equal(stops, 0);
    fireEvent.keyDown(composer.textarea, { key: "Escape" });
    assert.equal(stops, 1);
    cleanup();
  }
});

test("Composer Escape retains confirmation across internal focus and clears it on leaving", () => {
  let stops = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
    onStop: () => stops++,
  });
  composer.textarea.focus();
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  const stop = screen.getByRole("button", { name: "Press Esc again to stop" });
  act(() => stop.focus());
  fireEvent.keyDown(stop, { key: "Escape" });
  assert.equal(stops, 1);
  const outside = document.createElement("button");
  document.body.append(outside);
  try {
    act(() => composer.textarea.focus());
    fireEvent.keyDown(composer.textarea, { key: "Escape" });
    act(() => outside.focus());
    act(() => composer.textarea.focus());
    fireEvent.keyDown(composer.textarea, { key: "Escape" });
    assert.equal(stops, 1);
  } finally {
    outside.remove();
  }
});

test("Composer leaves IME Escape and modified Escape alone and gives Slash first refusal", () => {
  let stops = 0;
  const composer = renderComposer({
    stopAction: "run",
    onStop: () => stops++,
    draft: { kind: "text", text: "/" },
    slashCommands: [{ name: "new", enabled: true, disabledReason: null }],
  });
  for (const props of [
    { isComposing: true },
    { keyCode: 229 },
    { shiftKey: true },
    { ctrlKey: true },
    { altKey: true },
    { metaKey: true },
  ])
    assert.equal(
      fireEvent.keyDown(composer.textarea, { key: "Escape", ...props }),
      true,
    );
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(composer.textarea.getAttribute("aria-expanded"), "false");
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 0);
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 1);
});

test("Composer menu Escape closes only the menu before stopping can be armed", async () => {
  let stops = 0;
  renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
    onStop: () => stops++,
    modelEditable: true,
    modelLabel: "Alpha",
    selectedModelId: "alpha",
    modelOptions: [
      { selectionId: "alpha", displayName: "Alpha" },
      { selectionId: "beta", displayName: "Beta" },
    ],
    shell: composerShell({ attentionNotice: null }),
  });
  const user = userEvent.setup({ document });
  const trigger = screen.getByRole("combobox", { name: "Model" });
  await user.click(trigger);
  await screen.findByRole("listbox");
  await user.keyboard("{Escape}");
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  assert.equal(document.activeElement, trigger);
  assert.equal(stops, 0);
  assert.ok(screen.getByRole("button", { name: "Stop task" }));
  await user.keyboard("{Escape}");
  assert.equal(stops, 0);
  await user.keyboard("{Escape}");
  assert.equal(stops, 1);
});

for (const action of ["submit", "feedback"]) {
  test(`changing draft kind in the same editor keeps IME protected before ${action}`, () => {
    const composer = renderSkillComposer({ shell: composerShell() });
    const details = document.querySelector(".commandbar-alert");
    if (action === "feedback")
      fireEvent.click(details.querySelector("summary"));
    composer.input.focus();
    fireEvent.compositionStart(composer.input);
    act(() => composer.setDraft({ kind: "text", text: "next draft" }));
    const input = screen.getByRole("combobox", { name: "" });
    assert.equal(composer.input, input);
    assert.equal(document.activeElement, input);
    if (action === "submit") {
      fireEvent.keyDown(input, { key: "Enter" });
      assert.equal(composer.submissions(), 0);
      fireEvent.compositionEnd(input);
      fireEvent.keyDown(input, { key: "Enter" });
      assert.equal(composer.submissions(), 1);
    } else {
      fireEvent.keyDown(input, { key: "Escape", isComposing: true });
      assert.equal(details.open, true);
      fireEvent.compositionEnd(input);
      fireEvent.keyDown(input, { key: "Escape" });
      assert.equal(details.open, false);
      assert.equal(composer.submissions(), 0);
    }
  });
}

test("Composer buttons retain native Enter activation without a duplicate submit", async () => {
  const composer = renderComposer();
  const user = userEvent.setup({ document });
  screen.getByRole("button", { name: "Send" }).focus();
  await user.keyboard("{Enter}");
  assert.equal(composer.submissions(), 1);
});

function composerShell(overrides = {}) {
  return {
    taskTitle: "Keyboard test",
    contextVisible: true,
    attentionNotice: "Earlier stop failed",
    attentionContent: createElement("button", null, "Retry stop"),
    onSearch() {},
    left: null,
    rightPanel: createElement("div", null, "Task details"),
    rightPanelOpen: true,
    onDismissRightPanel: () =>
      assert.fail("consumed Escape must not close the right panel"),
    onToggleRightPanel() {},
    ...overrides,
  };
}

test("Shell closes feedback before Composer can arm Escape and preserves right-panel handling", () => {
  let stops = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "" },
    stopAction: "run",
    onStop: () => stops++,
    shell: composerShell(),
  });
  const details = document.querySelector(".commandbar-alert");
  const summary = details.querySelector("summary");
  fireEvent.click(summary);
  assert.equal(details.open, true);
  composer.textarea.focus();
  let preventedAtEditor = false;
  composer.textarea.addEventListener(
    "keydown",
    (event) => {
      preventedAtEditor = event.defaultPrevented;
    },
    { once: true },
  );
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(preventedAtEditor, true);
  assert.equal(details.open, false);
  assert.equal(document.activeElement, summary);
  assert.ok(screen.getByRole("button", { name: "Stop task" }));
  composer.textarea.focus();
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 0);
  assert.ok(screen.getByRole("button", { name: "Press Esc again to stop" }));
  fireEvent.keyDown(composer.textarea, { key: "Escape" });
  assert.equal(stops, 1);
});

for (const feedbackOpen of [false, true]) {
  test(`Shell preserves IME Escape and native confirmation with feedback ${feedbackOpen ? "open" : "closed"}`, () => {
    let stops = 0;
    const composer = renderComposer({
      stopAction: "run",
      onStop: () => stops++,
      shell: composerShell(),
    });
    const details = document.querySelector(".commandbar-alert");
    if (feedbackOpen) fireEvent.click(details.querySelector("summary"));
    composer.textarea.focus();
    const original = composer.textarea.value;
    for (const marker of [{ isComposing: true }, { keyCode: 229 }]) {
      for (const key of ["Escape", "Enter"]) {
        assert.equal(
          fireEvent.keyDown(composer.textarea, { key, ...marker }),
          true,
        );
        assert.equal(details.open, feedbackOpen);
        assert.equal(document.activeElement, composer.textarea);
      }
    }
    fireEvent.compositionStart(composer.textarea);
    for (const key of ["Escape", "Enter"]) {
      assert.equal(
        fireEvent.keyDown(composer.textarea, { key, isComposing: false }),
        true,
      );
      assert.equal(details.open, feedbackOpen);
    }
    fireEvent.compositionEnd(composer.textarea);
    assert.equal(composer.textarea.value, original);
    assert.equal(composer.submissions(), 0);
    assert.equal(stops, 0);
  });
}

test("Shell composition latch ends with focus leaving the composing field", () => {
  let closed = 0;
  const composer = renderComposer({
    shell: composerShell({
      attentionNotice: null,
      onDismissRightPanel: () => closed++,
    }),
  });
  composer.textarea.focus();
  fireEvent.compositionStart(composer.textarea);
  const toggle = document.querySelector(".commandbar-task-panel-toggle");
  act(() => toggle.focus());
  fireEvent.keyDown(toggle, { key: "Escape" });
  assert.equal(closed, 1);
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

test("Slash dismisses on pointer down in the Composer gutter and preserves the draft", () => {
  const { textarea, submissions } = renderComposer({
    draft: { kind: "text", text: "/" },
    slashCommands: [{ name: "new", enabled: true, disabledReason: null }],
  });
  const menu = screen.getByRole("listbox");
  fireEvent.pointerDown(textarea);
  fireEvent.pointerDown(within(menu).getByRole("option"));
  assert.equal(textarea.getAttribute("aria-expanded"), "true");

  const gutter = textarea.closest(".composer-bar");
  assert.equal(fireEvent.pointerDown(gutter), true);
  assert.equal(screen.queryByRole("listbox"), null);
  assert.equal(textarea.getAttribute("aria-expanded"), "false");
  assert.equal(textarea.value, "/");
  assert.equal(submissions(), 0);

  fireEvent.change(textarea, { target: { value: "/n" } });
  assert.ok(screen.getByRole("listbox"));
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

test("opening the chooser queries once per opening rather than per edit or render", () => {
  let refreshes = 0;
  const composer = renderComposer({
    draft: { kind: "text", text: "/" },
    onRefreshSkillCatalog() {
      refreshes += 1;
    },
  });
  assert.equal(refreshes, 1);
  act(() => composer.setDraft({ kind: "text", text: "/review" }));
  assert.equal(refreshes, 1);
  act(() => composer.setDraft({ kind: "text", text: "ordinary" }));
  act(() => composer.setDraft({ kind: "text", text: "/" }));
  assert.equal(refreshes, 2);
});

test("a changed Skill requires review and keeps the message editable", async () => {
  let latest;
  const { textarea } = renderComposer({
    draft: {
      kind: "skill",
      skillId: "old",
      skillPolicyKey: "review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "old",
      selectionRevision: "1",
      argumentNames: ["target"],
      argumentValues: ["keep this"],
      maxValues: 1,
    },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "new",
      selectionRevision: "2",
      skills: [
        {
          skillId: "new",
          skillPolicyKey: "review",
          invocationName: "review",
          displayName: "Review",
          description: "",
          argumentNames: [],
          maxValues: 0,
          enabled: true,
        },
      ],
      issues: [],
    },
    onDraftChange(value) {
      latest = value;
    },
    canSubmit: false,
  });
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Review Skill" }));
  assert.equal(latest.skillId, "new");
  assert.deepEqual(latest.argumentValues, ["keep this"]);
  assert.equal(textarea.value, "keep this");
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  await user.click(
    screen.getByRole("button", { name: "Remove selected Skill" }),
  );
  assert.deepEqual(latest, { kind: "text", text: "keep this" });
});

test("Slash selection and Backspace use the same editor and preserve the message", () => {
  const composer = renderComposer({
    draft: { kind: "text", text: "/review keep this" },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      selectionRevision: "3",
      skills: [
        {
          skillId: "builtin.review",
          skillPolicyKey: "review",
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
  const { textarea } = composer;
  const remove = () =>
    screen.queryByRole("button", { name: "Remove selected Skill" });
  assert.equal(document.activeElement, textarea);
  assert.equal(screen.getByRole("combobox"), textarea);
  assert.equal(textarea.value, "keep this");
  assert.equal(textarea.selectionStart, 0);
  assert.ok(remove());
  textarea.setSelectionRange(0, 4);
  assert.equal(fireEvent.keyDown(textarea, { key: "Backspace" }), true);
  assert.ok(remove());
  textarea.setSelectionRange(0, 0);
  fireEvent.compositionStart(textarea);
  assert.equal(
    fireEvent.keyDown(textarea, { key: "Backspace", isComposing: true }),
    true,
  );
  assert.ok(remove());
  fireEvent.compositionEnd(textarea);
  assert.equal(fireEvent.keyDown(textarea, { key: "Backspace" }), false);
  assert.equal(remove(), null);
  assert.equal(textarea.value, "keep this");
  assert.deepEqual(composer.currentDraft(), {
    kind: "text",
    text: "keep this",
  });
});

test("a Skill that cannot accept a message keeps the same editor and explains the conflict", () => {
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
          skillPolicyKey: "review",
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
  assert.equal(document.activeElement, composer.textarea);
  fireEvent.change(composer.textarea, { target: { value: "keep my message" } });
  assert.equal(composer.textarea.value, "keep my message");
  assert.match(
    screen.getByRole("status").textContent,
    /cannot use this message/,
  );
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
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

test("a restored Skill message remains visible as ordinary text", () => {
  const { textarea } = renderComposer({
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
          skillPolicyKey: "review",
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
  assert.equal(textarea.value, "src/main.zig");
});

test("editing a legacy Skill draft combines its contents into the message", () => {
  const changes = [];
  const { textarea } = renderComposer({
    draft: {
      kind: "skill",
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentNames: [],
      argumentValues: ["src/main.zig", "src/lib.zig"],
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
          skillPolicyKey: "review",
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
  assert.equal(textarea.value, "src/main.zig\nsrc/lib.zig");
  const message = "Review both files:\nsrc/main.zig\nsrc/lib.zig";
  fireEvent.change(textarea, { target: { value: message } });
  assert.deepEqual(changes, [
    {
      kind: "skill",
      skillId: "builtin.review",
      invocationName: "review",
      displayName: "Review",
      catalogRevision: "17",
      selectionRevision: "3",
      argumentNames: [],
      argumentValues: [message],
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

test("Composer Add menu selects an enabled Skill and preserves the message", async () => {
  const user = userEvent.setup({ document });
  const draftChanges = [];
  let picks = 0;
  let refreshes = 0;
  const skill = {
    skillId: "review-id",
    skillPolicyKey: "review-policy",
    invocationName: "review",
    displayName: "Review code",
    description: "",
    argumentNames: ["message"],
    maxValues: 1,
    enabled: true,
  };
  const composer = renderComposer({
    attachmentsEnabled: true,
    skillCatalog: {
      availability: "ready",
      revision: "4",
      selectionRevision: "2",
      skills: [
        skill,
        {
          ...skill,
          skillId: "disabled-id",
          invocationName: "disabled",
          displayName: "Disabled Skill",
          enabled: false,
        },
      ],
    },
    onChooseAttachments: () => picks++,
    onRefreshSkillCatalog: () => refreshes++,
    onDraftChange: (draft) => draftChanges.push(draft),
  });
  await user.click(screen.getByRole("button", { name: "Add to message" }));
  assert.ok(await screen.findByRole("menuitem", { name: "Add files" }));
  assert.equal(picks, 0);
  await user.click(screen.getByRole("menuitem", { name: "Add Skill" }));
  const option = await screen.findByRole("menuitem", { name: "Review code" });
  assert.equal(
    screen.queryByRole("menuitem", { name: "Disabled Skill" }),
    null,
  );
  assert.equal(refreshes, 1);
  await user.click(option);
  assert.equal(composer.textarea.value, "请检查当前实现");
  assert.equal(document.activeElement, composer.textarea);
  assert.equal(composer.submissions(), 0);
  assert.equal(draftChanges.at(-1).skillId, "review-id");
  assert.deepEqual(draftChanges.at(-1).argumentValues, ["请检查当前实现"]);
});

test("removing the last attachment returns keyboard focus to the Add menu", async () => {
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
    screen.getByRole("button", { name: "Add to message" }),
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
    (await screen.findByRole("option", { name: /Full access/ })).textContent,
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
  const full = await screen.findByRole("option", { name: /Full access/ });
  assert.equal(full.getAttribute("aria-disabled"), "true");
  await user.click(full);
  assert.equal(selected, 0);
});

test("Models keeps user-added model management available when the official catalog is empty", () => {
  const view = renderModelSettings({
    models: settingsModels(
      { models: [], errorCode: "no_models" },
      { errorCode: "no_models" },
    ),
  });
  assert.equal(screen.queryByRole("alert"), null);
  assert.equal(screen.queryByRole("button", { name: "Sync again" }), null);
  assert.ok(screen.getByRole("button", { name: "Add model" }));
  assert.deepEqual(view.selections.model, []);
});

test("Models keeps canonical storage recovery available without official model settings", () => {
  renderModelSettings({
    models: settingsModels({}, { persistenceHealth: "recovery_required" }),
  });
  assert.ok(
    screen.getByRole("button", { name: "Recover model configuration" }),
  );
  assert.equal(screen.queryByText("Model One"), null);
});

test("current Run switches between Send and Stop without disrupting IME", () => {
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
  fireEvent.compositionStart(composer.textarea);
  assert.ok(screen.getByRole("button", { name: "Send" }));
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  fireEvent.keyDown(composer.textarea, { key: "Enter", isComposing: true });
  assert.equal(composer.submissions(), 2);
  fireEvent.compositionEnd(composer.textarea);
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  assert.equal(stops, 1);
});

test("unavailable content keeps disabled Send until the draft is cleared", () => {
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
  fireEvent.change(composer.textarea, { target: { value: "" } });
  assert.equal(screen.queryByRole("button", { name: "Send" }), null);
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  assert.equal(stops, 1);
});

test("all interjection states render the same ordinary message with copy only", async () => {
  const { AdditionalInput } = await vite.ssrLoadModule(
    "/src/features/tasks/AdditionalInput.tsx",
  );
  for (const locale of ["en-US", "zh-CN"]) {
    let ordinaryMarkup;
    for (const state of [
      "pending",
      "adopted",
      "unadopted",
      "unknown",
      "continuing",
      "transferred",
    ]) {
      const view = render(
        createElement(
          I18nContext.Provider,
          {
            value: {
              locale,
              setLocale() {},
              t: (id, values) => translate(locale, id, values),
            },
          },
          createElement(AdditionalInput, {
            input: {
              id: "1",
              operationId: "sent",
              text: "safe preview",
              afterOutputCount: 0,
              redacted: false,
              sequence: 1,
              adoptedTurn: state === "adopted" ? 1 : null,
              order: state === "adopted" ? "1" : null,
              state,
              transferredToRunId: state === "transferred" ? "2" : null,
              continuationReason:
                state === "unadopted" ? "admission_failed" : null,
            },
          }),
        ),
      );
      const message = view.container.querySelector(
        '.ai-message[data-role="user"]',
      );
      assert.equal(message.textContent, "safe preview");
      assert.equal(message.getAttribute("aria-describedby"), null);
      assert.equal(view.getAllByRole("button").length, 1);
      assert.ok(
        view.getByRole("button", { name: translate(locale, "copy.input") }),
      );
      assert.equal(
        view.container.querySelectorAll(".message-info-bar[data-role=user]")
          .length,
        1,
      );
      ordinaryMarkup ??= message.outerHTML;
      assert.equal(message.outerHTML, ordinaryMarkup);
      assert.equal(
        view.container.textContent,
        `safe preview${translate(locale, "copy.input")}`,
      );
      view.unmount();
    }
  }
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
  await user.click(
    screen.getByRole("combobox", { name: "Choose working directory" }),
  );
  await user.click(await screen.findByRole("option", { name: "/repo/saved" }));
  assert.deepEqual(selected, ["saved"]);
  assert.equal(pickers, 0);
  assert.equal(screen.queryByText("Directory unavailable"), null);
});

for (const accessRequired of [false, true]) {
  test(`Workspace menu opens the native folder picker without changing the draft selection; accessRequired=${accessRequired}`, async () => {
    const user = userEvent.setup();
    const label = accessRequired ? "Select folder again" : "Open local folder";
    let pickers = 0;
    renderComposer({
      accessRequired,
      workspaceEditable: true,
      workspaceOptions: [
        { id: "automatic", label: "Default", authorization: "available" },
        {
          id: "saved",
          label: "/repo/saved",
          authorization: "reauthorization_required",
        },
      ],
      selectedWorkspaceOptionId: accessRequired ? "saved" : "automatic",
      onSelectWorkspace() {
        assert.fail("Opening the picker must not change the selection");
      },
      onConfirmAccess() {
        pickers++;
      },
    });
    const trigger = screen.getByRole("combobox", {
      name: "Choose working directory",
    });
    const initialLabel = trigger.textContent;
    assert.equal(screen.queryByText(label), null);
    await user.click(trigger);
    const choices = await screen.findAllByRole("option");
    assert.equal(choices.at(-2).textContent, label);
    await user.click(screen.getByRole("option", { name: label }));
    assert.equal(pickers, 1);
    assert.equal(trigger.textContent, initialLabel);
    await waitFor(() => assert.equal(screen.queryByRole("listbox"), null));
  });
}

test("new Task approval menu explains each mode only when opened and changes the draft choice", async () => {
  const { NewTaskApprovalModeMenu } = await vite.ssrLoadModule(
    "/src/features/approvals/ApprovalModeMenu.tsx",
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
    ["Manual approval", "Automatic approval", "Full access"],
  );
  assert.ok(
    options.every((option) =>
      option.querySelector("small")?.textContent.trim(),
    ),
  );
  assert.match(options[1].textContent, /asks you if unsure/);
  assert.equal(document.querySelector(".permission-policy-boundary"), null);
  await user.click(screen.getByRole("option", { name: /^Manual approval/ }));
  assert.deepEqual(choices, ["manual"]);
});

// Exercise the actual App so state, draft handoff and DOM focus are verified together.
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

test("Global search distinguishes a pending work page and exposes bounded continuation controls", () => {
  let more = 0;
  let first = 0;
  const props = {
    open: true,
    query: "needle",
    results: [],
    loading: true,
    hasMore: true,
    onQuery() {},
    onClose() {},
    onSelect() {},
    onMore() {
      more += 1;
    },
    onFirst() {
      first += 1;
    },
  };
  const view = render(searchElement(props));
  assert.equal(screen.getByRole("status").textContent, "Searching…");
  assert.equal(
    screen.getByRole("combobox").getAttribute("aria-expanded"),
    "false",
  );
  assert.equal(screen.queryByText("No results found."), null);
  assert.ok(screen.getByRole("button", { name: "Continue search" }).disabled);
  view.rerender(searchElement({ ...props, loading: false }));
  fireEvent.click(screen.getByRole("button", { name: "Continue search" }));
  fireEvent.click(screen.getByRole("button", { name: "Back to first page" }));
  assert.equal(more, 1);
  assert.equal(first, 1);
  view.unmount();
});
