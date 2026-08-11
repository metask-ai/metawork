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
  PointerEvent: dom.window.MouseEvent,
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

const { cleanup, fireEvent, render, screen, waitFor, within } =
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
  const listbox = screen.getByRole("listbox");
  assert.equal(trigger.getAttribute("aria-expanded"), "true");
  assert.ok(listbox);

  await user.keyboard("{ArrowDown}{Enter}");
  assert.deepEqual(selected, ["bravo"]);
  assert.equal(trigger.getAttribute("aria-expanded"), "false");
  assert.equal(document.activeElement, trigger);
});

test("Global search keeps focus in its combobox and restores the opener", () => {
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
  assert.equal(document.activeElement, combobox);
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
  fireEvent.keyDown(window, { key: "Escape" });
  assert.equal(closed, 1);
  view.rerender(searchElement({ ...props, open: false }));
  assert.equal(document.activeElement, opener);
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
  const blocked = screen.getByRole("option", { name: "Blocked" });
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
  await user.click(screen.getByRole("option", { name: /Bravo/ }));
  assert.deepEqual(selected, ["bravo"]);
  assert.match(trigger.textContent, /Choose workspace/);

  await user.click(trigger);
  await user.click(screen.getByRole("option", { name: /Bravo/ }));
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
  catalogState: "ready",
  canCancel: false,
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
  models: [
    { selectionId: "model-1", displayName: "Model One" },
    { selectionId: "model-2", displayName: "Model Two" },
  ],
  selectedApiKeySelectionId: "key-1",
  selectedModelSelectionId: "model-1",
  candidateApiKeySelectionId: "",
  candidateModelSelectionId: "",
  modelCatalogApiKeySelectionId: "key-1",
  canCreateTask: true,
  errorCode: "none",
  safeDiagnostic: "",
  catalogGeneration: "1",
  executionGeneration: "1",
};

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
      manualWorkspaces: [],
      tasks: [],
      focusTarget: "title",
      disabled: false,
      workspaceDisabled: false,
      workspaceBusy: false,
      cancelDisabled: false,
      onBack() {},
      onRefresh() {},
      onCancel() {},
      onSelectApiKey() {},
      onSelectModel() {},
      async onChooseWorkspace() {
        return { kind: "cancelled" };
      },
      async onRemoveWorkspace() {
        return { kind: "accepted" };
      },
      onBeginLogin() {},
      onLogout() {},
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
  };
}

function settingsWorkspace(id, authorization, lastRemovalFailure = null) {
  return {
    id,
    epoch: "3",
    kind: "manual",
    displayName: id,
    canonicalRoot: `/repo/${id}`,
    redacted: false,
    authorization,
    lastRemovalFailure,
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "1",
      skills: [],
      issues: [],
    },
    recentOrder: id,
    signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
  };
}

test("Settings completes the API transaction before replacing committed defaults", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const view = renderSettings(readySettingsAccount);

  await user.click(screen.getByRole("combobox", { name: "Default API" }));
  await user.click(screen.getByRole("option", { name: "Backup" }));
  assert.deepEqual(view.selections.api, ["key-2"]);
  assert.match(
    screen.getByRole("combobox", { name: "Default API" }).textContent,
    /Backup.*OpenAI.*5678/,
  );
  assert.match(screen.getByText("Pending change").textContent, /Pending/);

  view.rerenderAccount({
    ...readySettingsAccount,
    catalogState: "loading",
    candidateApiKeySelectionId: "key-2",
    canCreateTask: false,
    canCancel: true,
  });
  assert.match(screen.getByRole("status").textContent, /Preparing Backup/);
  assert.match(
    screen.getByRole("status").textContent,
    /current default stays active/i,
  );
  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model One/,
  );

  view.rerenderAccount({
    ...readySettingsAccount,
    catalogState: "loading",
    candidateApiKeySelectionId: "key-2",
    modelCatalogApiKeySelectionId: "key-2",
    models: [],
    canCreateTask: false,
    canCancel: true,
  });

  const api = screen.getByRole("combobox", { name: "Default API" });
  const model = screen.getByRole("combobox", { name: "Default model" });
  assert.match(api.textContent, /Backup.*OpenAI.*5678/);
  assert.equal(api.getAttribute("aria-busy"), "true");
  assert.match(model.textContent, /Loading models/);
  assert.equal(model.hasAttribute("disabled"), true);

  view.rerenderAccount({
    ...readySettingsAccount,
    catalogState: "choosing",
    candidateApiKeySelectionId: "key-2",
    modelCatalogApiKeySelectionId: "key-2",
    models: [{ selectionId: "model-2", displayName: "Model Two" }],
    canCreateTask: false,
    canCancel: true,
  });
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
  await user.click(screen.getByRole("option", { name: "Model Two" }));
  assert.deepEqual(view.selections.model, ["model-2"]);

  view.rerenderAccount({
    ...readySettingsAccount,
    catalogState: "loading",
    candidateApiKeySelectionId: "key-2",
    candidateModelSelectionId: "model-2",
    modelCatalogApiKeySelectionId: "key-2",
    models: [{ selectionId: "model-2", displayName: "Model Two" }],
    canCreateTask: false,
    canCancel: false,
  });
  assert.match(screen.getByRole("status").textContent, /Preparing Model Two/);
  assert.equal(screen.queryByRole("button", { name: "Cancel" }), null);

  view.rerenderAccount({
    ...readySettingsAccount,
    models: [{ selectionId: "model-2", displayName: "Model Two" }],
    selectedApiKeySelectionId: "key-2",
    selectedModelSelectionId: "model-2",
    modelCatalogApiKeySelectionId: "key-2",
    executionGeneration: "2",
  });
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
  await user.click(screen.getByRole("option", { name: "Model Two" }));

  assert.deepEqual(view.selections.model, ["model-2"]);
  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model Two/,
  );
  assert.equal(readySettingsAccount.selectedModelSelectionId, "model-1");
});

test("Settings limits API transaction locking and keeps a real cancel path", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let cancellations = 0;
  renderSettings(
    {
      ...readySettingsAccount,
      catalogState: "loading",
      candidateApiKeySelectionId: "key-2",
      modelCatalogApiKeySelectionId: "key-2",
      models: [],
      canCreateTask: false,
      canCancel: true,
    },
    {
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
  assert.equal(
    screen.getByRole("combobox", { name: "Language" }).hasAttribute("disabled"),
    false,
  );
  assert.equal(
    screen
      .getByRole("link", { name: "Account & models" })
      .hasAttribute("aria-disabled"),
    false,
  );

  await user.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(cancellations, 1);
});

test("Settings reports failed and cancelled switches without replacing committed defaults", () => {
  const view = renderSettings({
    ...readySettingsAccount,
    errorCode: "metask_service_unavailable",
  });

  assert.match(
    screen.getByRole("combobox", { name: "Default API" }).textContent,
    /Primary/,
  );
  assert.match(
    screen.getByRole("combobox", { name: "Default model" }).textContent,
    /Model One/,
  );
  assert.match(screen.getByRole("alert").textContent, /No default was changed/);
  assert.match(screen.getByRole("alert").textContent, /Primary · Model One/);

  view.rerenderAccount({
    ...readySettingsAccount,
    errorCode: "user_cancelled",
  });
  assert.equal(screen.queryByRole("alert"), null);
  assert.match(screen.getByRole("status").textContent, /Change cancelled/);
  assert.match(screen.getByRole("status").textContent, /Primary · Model One/);
});

test("Settings keeps section navigation fixed while content scrolls independently", () => {
  renderSettings(readySettingsAccount);
  const page = document.querySelector(".settings-page");
  const content = document.querySelector(".settings-content");
  const workspaceSection = document.querySelector("#settings-workspaces");
  const accountSection = document.querySelector("#settings-account");
  Object.defineProperty(content, "clientHeight", {
    configurable: true,
    value: 680,
  });
  content.getBoundingClientRect = () => ({ top: 100 });
  workspaceSection.getBoundingClientRect = () => ({
    top: 360 - content.scrollTop,
  });
  accountSection.getBoundingClientRect = () => ({
    top: 520 - content.scrollTop,
  });

  page.scrollTop = 300;
  fireEvent.scroll(page);
  assert.equal(
    screen.getByRole("link", { name: "General" }).getAttribute("aria-current"),
    "location",
  );

  content.scrollTop = 0;
  fireEvent.scroll(content);
  assert.equal(
    screen.getByRole("link", { name: "General" }).getAttribute("aria-current"),
    "location",
  );

  content.scrollTop = 300;
  fireEvent.scroll(content);
  assert.equal(
    screen
      .getByRole("link", { name: "Account & models" })
      .getAttribute("aria-current"),
    "location",
  );
});

test(
  "Settings owns Workspace lifecycle without restoring sidebar navigation",
  { timeout: 2_000 },
  async () => {
    const removals = [];
    renderSettings(readySettingsAccount, {
      manualWorkspaces: [
        {
          id: "workspace-1",
          epoch: "3",
          kind: "manual",
          displayName: "metawork",
          canonicalRoot: "/Users/example/Projects/metawork",
          redacted: false,
          authorization: "available",
          lastRemovalFailure: null,
          skillCatalog: {
            availability: "ready",
            redacted: false,
            revision: "1",
            skills: [],
            issues: [],
          },
          recentOrder: "1",
          signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
        },
      ],
      tasks: [],
      async onRemoveWorkspace(workspaceId) {
        removals.push(workspaceId);
        return { kind: "accepted" };
      },
    });

    assert.equal(
      screen.getByRole("link", { name: "Work directories" }) != null,
      true,
    );
    assert.match(
      screen.getByText("/Users/example/Projects/metawork").textContent,
      /metawork/,
    );
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    assert.match(
      screen.getByRole("group", { name: "Remove this work directory?" })
        .textContent,
      /local files will remain/,
    );
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    assert.equal(screen.queryByText("Remove this work directory?"), null);
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove directory" }));
    await Promise.resolve();
    assert.deepEqual(removals, ["workspace-1"]);
  },
);

test("Workspace settings expose canonical removal and authorization recovery states", () => {
  renderSettings(readySettingsAccount, {
    manualWorkspaces: [
      settingsWorkspace("reauthorize", "reauthorization_required"),
      settingsWorkspace("failed", "available", "task_close_failed"),
      settingsWorkspace("removing", "removing"),
    ],
  });

  assert.equal(
    screen.getByRole("button", { name: "Confirm access" }) != null,
    true,
  );
  assert.equal(
    screen.getByRole("button", { name: "Retry removal" }) != null,
    true,
  );
  assert.equal(screen.getByText("Removing") != null, true);
});

test("Workspace reauthorization preserves the target Host identity", async () => {
  const intents = [];
  renderSettings(readySettingsAccount, {
    manualWorkspaces: [settingsWorkspace("target", "reauthorization_required")],
    async onChooseWorkspace(intent) {
      intents.push(intent);
      return {
        kind: "target_mismatch",
        chosenWorkspaceId: "different",
      };
    },
  });

  fireEvent.click(screen.getByRole("button", { name: "Confirm access" }));
  await waitFor(() =>
    assert.match(
      screen.getByRole("alert").textContent,
      /selected directory was added.*still needs access/i,
    ),
  );
  assert.deepEqual(intents, [{ kind: "reauthorize", workspaceId: "target" }]);
  const row = screen
    .getByText("/repo/target")
    .closest(".settings-workspace-row");
  assert.equal(row.contains(screen.getByRole("alert")), true);
});

test(
  "Workspace mutation rejection stays with the affected directory",
  { timeout: 2_000 },
  async () => {
    renderSettings(readySettingsAccount, {
      manualWorkspaces: [
        settingsWorkspace("target", "available"),
        settingsWorkspace("other", "available"),
      ],
      async onRemoveWorkspace() {
        return { kind: "rejected", reason: "workspace_changed" };
      },
    });

    const targetRow = screen
      .getByText("/repo/target")
      .closest(".settings-workspace-row");
    fireEvent.click(within(targetRow).getByRole("button", { name: "Remove" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove directory" }));
    await waitFor(() =>
      assert.equal(targetRow.querySelector('[role="alert"]') != null, true),
    );
    assert.equal(
      screen
        .getByText("/repo/other")
        .closest(".settings-workspace-row")
        .querySelector('[role="alert"]'),
      null,
    );
  },
);

test(
  "canonical Workspace removal closes confirmation onto stable focus",
  { timeout: 2_000 },
  async () => {
    const available = settingsWorkspace("target", "available");
    const view = renderSettings(readySettingsAccount, {
      manualWorkspaces: [available],
    });
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    assert.equal(
      document.activeElement,
      screen.getByRole("button", { name: "Cancel" }),
    );

    view.rerender(
      settingsElement(readySettingsAccount, {
        manualWorkspaces: [{ ...available, authorization: "removing" }],
      }),
    );
    await new Promise((resolve) => window.requestAnimationFrame(resolve));
    assert.equal(screen.queryByText("Remove this work directory?"), null);
    assert.equal(
      document.activeElement,
      screen.getByRole("heading", { name: "Work directories" }),
    );
  },
);

function renderComposer(overrides = {}) {
  const textareaRef = createRef();
  let submissions = 0;
  const initialDraft = overrides.draft ?? {
    kind: "text",
    text: "请检查当前实现",
  };
  const externalOnDraftChange = overrides.onDraftChange;
  function ComposerHarness() {
    const [draft, setDraft] = useState(initialDraft);
    return createElement(ComposerFooter, {
      textareaRef,
      archived: false,
      closing: false,
      closed: false,
      unavailable: false,
      unavailableReason: null,
      recoveryAvailable: false,
      recoveryInProgress: false,
      recoveryDisabled: false,
      draft,
      skillCatalog: {
        availability: "ready",
        redacted: false,
        revision: "4",
        skills: [],
        issues: [],
      },
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
      actionDisabled: false,
      onSubmit() {
        submissions += 1;
      },
      onRestore() {},
      onSlashCommand() {},
      onRefreshSkillCatalog() {},
      onConfirmAccess() {},
      onSelectWorkspace() {},
      onSelectModel() {},
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
  };
}

test("Conversation recovery invokes only its explicit Composer action", async () => {
  let restores = 0;
  const user = userEvent.setup({ document: dom.window.document });
  renderComposer({
    unavailable: true,
    unavailableReason: "session_recovery_required",
    recoveryAvailable: true,
    composeDisabled: true,
    onRestore() {
      restores += 1;
    },
  });
  await user.click(
    screen.getByRole("button", { name: "Restore conversation" }),
  );
  assert.equal(restores, 1);
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
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "Review a target",
          argumentNames: ["target"],
          maxValues: 1,
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
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "Review the current task",
          argumentNames: [],
          maxValues: 0,
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
      argumentNames: [],
      argumentValues: ["src/main.zig"],
      maxValues: 1,
    },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "",
          argumentNames: [],
          maxValues: 1,
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
      argumentNames: [],
      argumentValues: [],
      maxValues: 3,
    },
    skillCatalog: {
      availability: "ready",
      redacted: false,
      revision: "17",
      skills: [
        {
          skillId: "builtin.review",
          invocationName: "review",
          displayName: "Review",
          description: "",
          argumentNames: [],
          maxValues: 3,
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
      argumentNames: [],
      argumentValues: ["", ""],
      maxValues: 3,
    },
  ]);
});
