import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
for (const key of [
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
  globalThis[key] = key === "window" ? dom.window : dom.window[key];
for (const key of [
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
])
  globalThis[key] = dom.window[key].bind(dom.window);
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
globalThis.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
for (const key of [
  "setPointerCapture",
  "releasePointerCapture",
  "scrollIntoView",
])
  HTMLElement.prototype[key] ??= () => {};
HTMLElement.prototype.hasPointerCapture ??= () => false;
const { act, cleanup, fireEvent, render, screen, within, waitFor } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { OfficeSettings } = await vite.ssrLoadModule(
  "/src/features/settings/OfficeSettings.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const initial = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
).office;
const idle = { ...initial, supported: true, health: "ready" };
const offered = { downloadBytes: "627298237", installedBytes: "1913598758" };
const accepted = {
  accepted: true,
  generation: "8",
  operationId: "9",
  reason: null,
};
function element(view, callbacks = {}, locale = "en-US") {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale,
        setLocale() {},
        t: (id, values) => translate(locale, id, values),
      },
    },
    createElement(OfficeSettings, {
      view,
      disabled: false,
      onAction: async () => accepted,
      onCancel: async () => accepted,
      ...callbacks,
    }),
  );
}
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

test("Office basic Skills remain visible without a published runtime or supported platform", () => {
  const page = render(element(idle));
  assert.match(
    page.container.textContent,
    /Basic DOCX, XLSX and PPTX Skills are included/,
  );
  assert.match(page.container.textContent, /not yet published/);
  assert.equal(
    screen.queryByRole("button", { name: "Install environment" }),
    null,
  );
  page.rerender(element(initial));
  assert.match(page.container.textContent, /Windows x64/);
  assert.equal(screen.queryAllByRole("button").length, 0);
});

test("Office install shows cost, submits once, and reports response uncertainty without replay", async () => {
  const calls = [];
  let reject;
  const view = {
    ...idle,
    generation: "7",
    offered,
    actions: { ...idle.actions, install: true },
  };
  render(
    element(view, {
      onAction: (action, generation) => {
        calls.push({ action, generation });
        return new Promise((_, failure) => {
          reject = failure;
        });
      },
    }),
  );
  assert.match(
    document.body.textContent,
    /598.2 MiB download · 1.8 GiB installed/,
  );
  const install = screen.getByRole("button", { name: "Install environment" });
  fireEvent.click(install);
  fireEvent.click(install);
  assert.deepEqual(calls, [{ action: "install", generation: "7" }]);
  assert.equal(install.disabled, true);
  await act(async () => reject(new Error("response lost")));
  assert.match(screen.getByRole("alert").textContent, /could not be confirmed/);
  assert.equal(calls.length, 1);
});

test("Office update failure preserves the current ready state and exposes a local error", () => {
  render(
    element({
      ...idle,
      current: { state: "ready" },
      offered,
      updateAvailable: true,
      terminal: {
        id: "9",
        kind: "install",
        outcome: "failed",
        reason: "download_failed",
      },
      actions: { ...idle.actions, install: true, remove: true },
    }),
  );
  assert.equal(
    document.querySelector(".settings-office-status").textContent,
    "Ready",
  );
  assert.match(document.body.textContent, /New tasks use this environment/);
  assert.ok(screen.getByRole("button", { name: "Update environment" }));
  assert.match(screen.getByRole("alert").textContent, /Download failed/);
});

test("Office progress cancels the stable operation ID even after newer progress", async () => {
  const cancelled = [];
  const operation = {
    id: "9",
    kind: "install",
    phase: "downloading",
    bytes: "25",
    total: "100",
    cancelling: false,
  };
  const view = {
    ...idle,
    generation: "7",
    operation,
    actions: { ...idle.actions, cancel: true },
  };
  const callbacks = {
    onCancel: async (id) => {
      cancelled.push(id);
      return accepted;
    },
  };
  const page = render(element(view, callbacks));
  assert.equal(
    screen.getByRole("progressbar").getAttribute("aria-valuenow"),
    "25",
  );
  page.rerender(
    element(
      { ...view, generation: "8", operation: { ...operation, bytes: "50" } },
      callbacks,
    ),
  );
  await act(async () =>
    fireEvent.click(screen.getByRole("button", { name: "Cancel" })),
  );
  assert.deepEqual(cancelled, ["9"]);
  page.rerender(
    element(
      {
        ...view,
        operation: { ...operation, cancelling: true, total: "0" },
        actions: idle.actions,
      },
      callbacks,
    ),
  );
  assert.equal(screen.queryByRole("progressbar"), null);
  assert.match(screen.getByRole("status").textContent, /Cancelling/);
  assert.equal(
    screen.getByRole("button", { name: /Cancelling/ }).disabled,
    true,
  );
});

test("Office removal confirms its captured generation, handles rejection and restores focus", async () => {
  const calls = [];
  const view = {
    ...idle,
    generation: "7",
    current: { state: "ready" },
    actions: { ...idle.actions, remove: true },
  };
  const callbacks = {
    onAction: async (action, generation) => {
      calls.push({ action, generation });
      return {
        ...accepted,
        accepted: false,
        operationId: null,
        reason: "stale_generation",
      };
    },
  };
  const page = render(element(view, callbacks));
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(screen.getByRole("button", { name: "Remove environment" }));
  const dialog = await screen.findByRole("alertdialog");
  assert.match(dialog.textContent, /Other MetaWork versions/);
  await waitFor(() =>
    assert.equal(
      document.activeElement,
      within(dialog).getByRole("button", { name: "Cancel" }),
    ),
  );
  assert.equal(calls.length, 0);
  page.rerender(element({ ...view, generation: "8" }, callbacks));
  await user.click(
    within(dialog).getByRole("button", { name: "Remove environment" }),
  );
  assert.deepEqual(calls, [{ action: "remove", generation: "7" }]);
  await waitFor(() => assert.equal(screen.queryByRole("alertdialog"), null));
  assert.match(screen.getByRole("alert").textContent, /state changed/);
  await waitFor(() =>
    assert.equal(
      document.activeElement,
      screen.getByRole("heading", { name: "Office documents" }),
    ),
  );
});

test("Office pending cleanup explains shared resources and restart without duplicate errors", () => {
  render(
    element(
      {
        ...idle,
        health: "restart_required",
        cleanupPending: true,
        terminal: {
          id: "9",
          kind: "cleanup",
          outcome: "failed",
          reason: "process_cleanup_incomplete",
        },
      },
      {},
      "zh-CN",
    ),
  );
  assert.equal(screen.getAllByRole("alert").length, 1);
  const error = screen.getByRole("alert").textContent;
  assert.equal(document.body.textContent.split(error).length - 1, 1);
  assert.match(document.body.textContent, /MetaWork/);
  assert.equal(screen.queryByRole("button", { name: "安装环境" }), null);
});
