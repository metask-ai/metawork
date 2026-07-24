import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, createRef } from "react";
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

const { cleanup, fireEvent, render, screen } =
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

function renderComposer(overrides = {}) {
  const textareaRef = createRef();
  let submissions = 0;
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
      createElement(ComposerFooter, {
        textareaRef,
        archived: false,
        closing: false,
        closed: false,
        unavailable: false,
        prompt: "请检查当前实现",
        composeDisabled: false,
        canSubmit: true,
        runInFlight: false,
        accessRequired: false,
        workspaceMissing: false,
        workspaceLabel: "metawork",
        workspaceTitle: "/repo/metawork",
        workspaceOptions: [],
        selectedWorkspaceId: "1",
        workspaceEditable: false,
        modelLabel: null,
        modelOptions: [],
        selectedModelId: "",
        modelEditable: false,
        modelSelectionDisabled: false,
        modelSelectionPending: false,
        modelContextTitle: "",
        actionDisabled: false,
        onPromptChange() {},
        onSubmit() {
          submissions += 1;
        },
        onConfirmAccess() {},
        onSelectWorkspace() {},
        onSelectModel() {},
        ...overrides,
      }),
    ),
  );
  return {
    textarea: textareaRef.current,
    submissions: () => submissions,
  };
}

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
