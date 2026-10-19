import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
dom.window.PointerEvent ??= dom.window.MouseEvent;
for (const name of [
  "window",
  "document",
  "Node",
  "NodeFilter",
  "DocumentFragment",
  "Element",
  "HTMLElement",
  "HTMLButtonElement",
  "HTMLInputElement",
  "MutationObserver",
  "CustomEvent",
  "PointerEvent",
])
  globalThis[name] = name === "window" ? dom.window : dom.window[name];
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
globalThis.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
globalThis.requestAnimationFrame = dom.window.requestAnimationFrame.bind(
  dom.window,
);
globalThis.cancelAnimationFrame = dom.window.cancelAnimationFrame.bind(
  dom.window,
);
globalThis.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
globalThis.CSS = { escape: (value) => value.replace(/["\\]/g, "\\$&") };
window.matchMedia = (query) => ({
  matches: false,
  media: query,
  addEventListener() {},
  removeEventListener() {},
});
for (const name of [
  "scrollIntoView",
  "setPointerCapture",
  "releasePointerCapture",
])
  HTMLElement.prototype[name] ??= () => {};
HTMLElement.prototype.hasPointerCapture ??= () => false;
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
const { render, screen, cleanup, fireEvent, act, waitFor } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { ImageGenerationSettings } = await vite.ssrLoadModule(
  "/src/features/settings/ImageGenerationSettings.tsx",
);
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
test.afterEach(cleanup);
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const snapshotFixture = JSON.parse(
  await readFile(
    "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
    "utf8",
  ),
);
const imageModel = {
  ...snapshotFixture.models.providers[0].models[0],
  id: "image-one",
  displayName: "Image One",
};
function imageView(overrides = {}) {
  return {
    catalogState: "ready",
    catalogGeneration: "71",
    selectionRevision: "17",
    models: [imageModel],
    selection: null,
    selectionAvailable: false,
    errorCode: "none",
    ...overrides,
  };
}
function localized(child, locale = "en-US") {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale,
        setLocale() {},
        t: (id, values) => translate(locale, id, values),
      },
    },
    child,
  );
}
function component(props = {}, locale) {
  return localized(
    createElement(ImageGenerationSettings, {
      account: {
        ...snapshotFixture.account,
        state: "authenticated",
        accountId: "synthetic-principal",
      },
      image: imageView(),
      disabled: false,
      onRefresh() {},
      onSelect: async () => true,
      ...props,
    }),
    locale,
  );
}

test("Image selection uses the keyboard, serializes a pending mutation and waits for Host state", async () => {
  const writes = [];
  const onSelect = (value) =>
    new Promise((resolve) => writes.push({ value, resolve }));
  const ui = render(component({ onSelect }));
  const user = userEvent.setup({ document });
  const trigger = screen.getByRole("combobox", { name: "Image model" });
  assert.equal(writes.length, 0);
  assert.equal(
    screen.getByRole("button", { name: "Clear selection" }).disabled,
    true,
  );
  trigger.focus();
  await user.keyboard("{ArrowDown}");
  await screen.findByRole("option", { name: /Image One/ });
  await user.keyboard("{Enter}");
  await waitFor(() => assert.equal(writes.length, 1));
  assert.equal(writes[0].value, "image-one");
  assert.equal(trigger.disabled, true);
  assert.match(screen.getByRole("status").textContent, /Saving/);
  fireEvent.click(screen.getByRole("button", { name: "Clear selection" }));
  assert.equal(writes.length, 1);
  await act(async () => writes[0].resolve(true));
  assert.match(
    screen.getByRole("status").textContent,
    /No image model selected/,
  );
  ui.rerender(
    component({
      onSelect,
      image: imageView({
        selection: { sourceId: "metask", modelId: "image-one" },
        selectionRevision: "18",
        selectionAvailable: true,
      }),
    }),
  );
  assert.match(screen.getByRole("status").textContent, /Selected: Image One/);
  await user.click(screen.getByRole("button", { name: "Clear selection" }));
  assert.equal(writes[1].value, null);
  await act(async () => writes[1].resolve(false));
  assert.match(screen.getByRole("alert").textContent, /could not be confirmed/);
  assert.match(screen.getByRole("status").textContent, /Selected: Image One/);
  await act(async () => {});
  assert.equal(writes.length, 2);
});

test("An unavailable saved model stays visible and can be explicitly cleared without inventing candidates", async () => {
  const writes = [];
  render(
    component({
      image: imageView({
        selection: { sourceId: "metask", modelId: "removed-image" },
      }),
      onSelect: async (value) => {
        writes.push(value);
        return true;
      },
    }),
  );
  const user = userEvent.setup({ document });
  assert.match(
    screen.getByRole("status").textContent,
    /unavailable: removed-image/,
  );
  screen.getByRole("combobox", { name: "Image model" }).focus();
  await user.keyboard("{ArrowDown}");
  await screen.findByRole("option", { name: /Image One/ });
  assert.equal(screen.getAllByRole("option").length, 1);
  assert.match(screen.getByRole("option").textContent, /Image One/);
  await user.keyboard("{Escape}");
  await user.click(screen.getByRole("button", { name: "Clear selection" }));
  assert.deepEqual(writes, [null]);
  assert.match(screen.getByRole("status").textContent, /removed-image/);
});

test("Unavailable catalog states never write or synchronize on mount and only explicit refresh retries", async () => {
  let refreshes = 0,
    writes = 0;
  const props = {
    onRefresh: () => refreshes++,
    onSelect: async () => {
      writes++;
      return false;
    },
  };
  const ui = render(
    component({
      ...props,
      account: { ...snapshotFixture.account, state: "signed_out" },
    }),
  );
  const user = userEvent.setup({ document });
  assert.match(screen.getByRole("status").textContent, /Sign in/);
  for (const state of ["loading", "failed", "unavailable"]) {
    ui.rerender(
      component({
        ...props,
        image: imageView({ catalogState: state, models: [] }),
      }),
    );
    assert.equal(screen.getByRole("combobox").disabled, true);
    assert.equal(refreshes, 0);
    assert.equal(writes, 0);
  }
  await user.click(screen.getByRole("button", { name: "Sync again" }));
  assert.equal(refreshes, 1);
  ui.rerender(component({ ...props, image: imageView({ models: [] }) }));
  assert.match(
    screen.getByRole("status").textContent,
    /No image models are available/,
  );
  assert.equal(screen.getByRole("combobox").disabled, true);
  assert.equal(writes, 0);
});

test("Image settings explain charges, next Run and PNG in both languages without offering generation", () => {
  for (const [locale, charges, next] of [
    ["en-US", /may incur charges/, /next run/],
    ["zh-CN", /费用/, /下一/],
  ]) {
    const ui = render(component({}, locale));
    assert.match(ui.container.textContent, charges);
    assert.match(ui.container.textContent, next);
    assert.match(ui.container.textContent, /PNG/);
    assert.doesNotMatch(
      ui.container.textContent,
      /catalogGeneration|selectionRevision|https:|\$\d/,
    );
    assert.equal(screen.getAllByRole("button").length, 2);
    ui.unmount();
  }
});

test("Ordinary Models settings keep the image entry closed until the formal Host Tool Gate", () => {
  render(
    localized(
      createElement(SettingsPage, {
        account: snapshotFixture.account,
        models: { ...snapshotFixture.models, imageGeneration: imageView() },
        automaticWorkspaceRoot: snapshotFixture.automaticWorkspaceRoot,
        customProviderCapabilities: {
          management: false,
          secretCapture: false,
          modelTest: false,
        },
        initialSection: "models",
        focusTarget: "title",
        disabled: false,
        accountDisabled: false,
        executionDisabled: false,
        cancelDisabled: false,
        onBack() {},
        onRefresh() {},
        onSelectModel() {},
      }),
    ),
  );
  assert.ok(screen.getByRole("combobox", { name: "Default model" }));
  assert.equal(screen.queryByRole("combobox", { name: "Image model" }), null);
  assert.equal(screen.queryByRole("group", { name: "Image model" }), null);
});
