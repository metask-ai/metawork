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

const { SelectionMenu } = await vite.ssrLoadModule(
  "/src/components/ui/SelectionMenu.tsx",
);
const { ComposerFooter } = await vite.ssrLoadModule(
  "/src/features/composer/ComposerFooter.tsx",
);
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { GlobalSearch } = await vite.ssrLoadModule(
  "/src/features/search/GlobalSearch.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

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

test("SelectionMenu uses combobox semantics and keyboard selection", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderMenu((value) => selected.push(value));

  const trigger = screen.getByRole("combobox", { name: "Switch workspace" });
  await user.click(trigger);
  const listbox = await screen.findByRole("listbox");
  assert.equal(trigger.getAttribute("aria-expanded"), "true");
  assert.ok(listbox);

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
  errorCode: "none",
  safeDiagnostic: "",
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
      apiKeys: [
        {
          id: "key-1",
          name: "Primary",
          suffix: "1234",
          protocol: "anthropic_messages",
        },
        {
          id: "key-2",
          name: "Backup",
          suffix: "5678",
          protocol: "openai_chat_completions",
        },
      ],
      models: [
        { id: "model-1", displayName: "Model One" },
        { id: "model-2", displayName: "Model Two" },
      ],
      selectedApiKeyId: "key-1",
      catalogGeneration: "1",
      sourceGeneration: "1",
      errorCode: "none",
      safeDiagnostic: "",
    },
  ],
  metaskSelection: { sourceId: "metask:key-1", modelId: "model-1" },
  metaskSelectionRevision: "1",
  defaultSelection: { sourceId: "metask:key-1", modelId: "model-1" },
  selectionRevision: "1",
  operation: "idle",
  errorCode: "none",
  connections: [],
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
      modelConnectionCapabilities: {
        management: true,
        secretCapture: false,
        connectionTest: true,
      },
      permissionProfiles: {
        enabled: false,
        available: [],
        defaultProfile: "approval_required",
        busy: false,
      },
      focusTarget: "title",
      initialSection: "models",
      disabled: false,
      accountDisabled: false,
      executionDisabled: false,
      cancelDisabled: false,
      onBack() {},
      onRefresh() {},
      onCancel() {},
      onSelectApiKey() {},
      onSelectModel() {},
      onCreateModelConnection() {
        return Promise.resolve(false);
      },
      onUpdateModelConnection() {
        return Promise.resolve(false);
      },
      onRemoveModelConnection() {
        return Promise.resolve(false);
      },
      onTestModelConnection() {},
      onSelectModelConnection() {},
      onActivateMetask() {},
      onBeginLogin() {},
      onLogout() {},
      onSetDefaultPermissionProfile() {},
      ...overrides,
    }),
  );
}

function renderSettings(account, overrides = {}) {
  const selections = { api: [], model: [] };
  const callbacks = {
    onSelectApiKey(value) {
      selections.api.push(value);
    },
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

test("Settings exposes Model connections only for the complete Host gate", () => {
  const incomplete = renderSettings(readySettingsAccount);
  assert.equal(
    screen.queryByRole("heading", { name: "Model connections" }),
    null,
  );
  incomplete.unmount();

  render(
    settingsElement(readySettingsAccount, {
      modelConnectionCapabilities: {
        management: true,
        secretCapture: true,
        connectionTest: true,
      },
    }),
  );
  fireEvent.click(screen.getByRole("link", { name: "Model connections" }));
  assert.ok(screen.getByRole("heading", { name: "Model connections" }));
  assert.ok(screen.getByRole("button", { name: "Add connection" }));
});

test("Settings completes the API transaction before replacing committed defaults", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount);

  await user.click(screen.getByRole("combobox", { name: "Default API" }));
  await user.click(await screen.findByRole("option", { name: /Backup/ }));
  assert.deepEqual(view.selections.api, ["key-2"]);
  assert.match(
    screen.getByRole("combobox", { name: "Default API" }).textContent,
    /Backup.*OpenAI.*5678/,
  );
  assert.match(screen.getByText("Pending change").textContent, /Pending/);

  view.rerenderModels(
    settingsModels(
      { catalogState: "loading" },
      { operation: "refreshing_catalog" },
    ),
  );
  assert.match(screen.getByRole("status").textContent, /Preparing Backup/);
  assert.match(
    screen.getByRole("status").textContent,
    /current default stays active/i,
  );
  assert.match(
    dom.window.document.getElementById("settings-model")?.textContent ?? "",
    /Model One/,
  );

  view.rerenderModels(
    settingsModels(
      { catalogState: "loading", models: [] },
      { operation: "refreshing_catalog" },
    ),
  );

  const api = screen.getByRole("combobox", { name: "Default API" });
  const model = screen.getByRole("combobox", { name: "Default model" });
  assert.match(api.textContent, /Backup.*OpenAI.*5678/);
  assert.equal(api.getAttribute("aria-busy"), "true");
  assert.match(model.textContent, /Loading models/);
  assert.equal(model.hasAttribute("disabled"), true);

  view.rerenderModels(
    settingsModels({
      catalogState: "choosing",
      models: [{ id: "model-2", displayName: "Model Two" }],
    }),
  );
  assert.match(
    screen.getByRole("status").textContent,
    /Choose a model for Backup/,
  );
  assert.equal(
    screen
      .getByRole("combobox", { name: "Default model" })
      .hasAttribute("disabled"),
    false,
  );
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
  assert.equal(screen.queryByRole("button", { name: "Cancel" }), null);

  view.rerenderModels(
    settingsModels(
      {
        models: [{ id: "model-2", displayName: "Model Two" }],
        selectedApiKeyId: "key-2",
      },
      {
        metaskSelection: { sourceId: "metask:key-2", modelId: "model-2" },
        defaultSelection: { sourceId: "metask:key-2", modelId: "model-2" },
      },
    ),
  );
  assert.match(
    screen.getByRole("combobox", { name: "Default API" }).textContent,
    /Backup/,
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

test("Settings keeps Metask available while a model connection is the default", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let activations = 0;
  renderSettings(readySettingsAccount, {
    models: {
      ...readySettingsModels,
      defaultSelection: { sourceId: "connection-1", modelId: "gpt-5" },
      connections: [
        {
          id: "connection-1",
          displayName: "Team OpenAI",
          protocol: "openai_chat_completions",
          normalizedBaseUrl: "https://api.openai.com/v1/chat/completions",
          state: "ready",
          testStatus: "connected",
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
          ],
          selectedModel: "gpt-5",
          connectionRevision: "1",
          sourceGeneration: "1",
          catalogGeneration: "1",
        },
      ],
    },
    onActivateMetask() {
      activations += 1;
    },
  });

  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model One/,
  );
  await user.click(
    screen.getByRole("button", { name: "Use Metask for new tasks" }),
  );
  assert.equal(activations, 1);
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
      .getByRole("combobox", { name: "Default API" })
      .hasAttribute("disabled"),
    true,
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
    screen.getByRole("combobox", { name: "Default API" }).textContent,
    /Primary/,
  );
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

test("Settings changes only the future Task permission default in one action", async () => {
  const selected = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderSettings(readySettingsAccount, {
    permissionProfiles: {
      enabled: true,
      available: ["approval_required", "full_access"],
      defaultProfile: "approval_required",
      busy: false,
    },
    initialSection: "permissions",
    onSetDefaultPermissionProfile(profile) {
      selected.push(profile);
    },
  });

  assert.ok(screen.getByRole("link", { name: "Permissions" }));
  assert.match(
    document.querySelector(".permission-policy-boundary").textContent,
    /not root access or a sandbox setting/,
  );
  const trigger = screen.getByRole("combobox", {
    name: "Default for new Tasks",
  });
  await user.click(trigger);
  await screen.findByRole("listbox");
  await user.keyboard("{ArrowDown}{Enter}");
  assert.deepEqual(selected, ["full_access"]);
  assert.equal(screen.queryByRole("alertdialog"), null);
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
      onActivateMetask() {},
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

test("Composer explains a missing executable default and offers Metask recovery", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let activations = 0;
  renderComposer({
    canSubmit: false,
    defaultSelectionMissing: true,
    onActivateMetask() {
      activations += 1;
    },
  });

  assert.match(
    screen.getByRole("status").textContent,
    /No executable default model is selected/,
  );
  const recover = screen.getByRole("button", {
    name: "Use Metask for new tasks",
  });
  assert.ok(recover);
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  await user.click(recover);
  assert.equal(activations, 1);
});

test("Composer does not show recovery for a normal custom default", () => {
  renderComposer({ defaultSelectionMissing: false });
  assert.equal(screen.queryByRole("status"), null);
  assert.equal(
    screen.queryByRole("button", { name: "Use Metask for new tasks" }),
    null,
  );
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
          kind: "pdf",
          format: "pdf",
          displayName: "brief.pdf",
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
          kind: "pdf",
          format: "pdf",
          displayName: "brief.pdf",
          sizeBytes: "2048",
        },
      ],
    }),
  );
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(
    document.activeElement,
    screen.getByRole("button", { name: "Remove brief.pdf" }),
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
    screen.getByRole("button", { name: "Add images or PDFs" }),
  );
});
