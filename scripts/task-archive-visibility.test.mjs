import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";
import { productStateFixture } from "./test-support/product-view-fixture.mjs";

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
window.matchMedia = (media) => ({
  media,
  matches: false,
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

const { act, cleanup, fireEvent, render, screen, waitFor } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { default: App } = await vite.ssrLoadModule("/src/app/App.tsx");
const { BridgeClient, BridgeCommandTimeoutError } = await vite.ssrLoadModule(
  "/src/bridge/client.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const initialSnapshot = JSON.parse(
  readFileSync(
    "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
    "utf8",
  ),
);

test.beforeEach(() => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  window.localStorage.setItem("metawork.model-setup-handled", "true");
});
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function taskRows(id) {
  return document.querySelectorAll(`.task-list [data-task-id="${id}"]`);
}

async function renderApp(ctx) {
  const snapshot = structuredClone(initialSnapshot);
  const task = snapshot.tasks[0];
  Object.assign(task, {
    title: "Archive target",
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    inputReady: true,
    runs: [],
  });
  snapshot.tasks.push({
    ...structuredClone(task),
    id: "4",
    title: "Earlier archive",
    archived: true,
  });
  snapshot.workspaces[0].signals.running = 0;
  const requests = [];
  let onRevision;
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onWorkbenchRevision: (callback) => {
      onRevision = callback;
      return () => {};
    },
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    setTaskArchived: async (taskId, archived) => {
      const result = await new Promise((resolve) =>
        requests.push({ taskId, archived, resolve }),
      );
      if (result.archived !== undefined) {
        snapshot.tasks.find((entry) => entry.id === taskId).archived =
          result.archived;
        snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      }
      if (result.error) throw result.error;
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
  await screen.findByRole("button", { name: "Show archived (1)" });
  const user = userEvent.setup({ document });
  return {
    user,
    requests,
    async invoke(id, action) {
      const row = taskRows(id)[0];
      assert.ok(row, "Task must be visible before opening its menu");
      fireEvent.contextMenu(row);
      await user.click(
        await screen.findByRole("menuitem", { name: action, exact: true }),
      );
      await waitFor(() => assert.equal(requests.length, 1));
      assert.deepEqual(
        { taskId: requests[0].taskId, archived: requests[0].archived },
        { taskId: id, archived: action === "Archive" },
      );
    },
    async settle(result) {
      await act(async () => requests[0].resolve(result));
    },
    async publishArchive(taskId, archived) {
      snapshot.tasks.find((entry) => entry.id === taskId).archived = archived;
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      await act(async () =>
        onRevision(snapshot.revision, snapshot.securityEpoch ?? "1"),
      );
    },
  };
}

test("App archive preserves hidden archives in both Recent and Projects", async (ctx) => {
  const app = await renderApp(ctx);
  assert.equal(taskRows("3").length, 2);
  assert.equal(taskRows("4").length, 0);
  await app.invoke("3", "Archive");
  await app.settle({ archived: true });
  await screen.findByRole("button", { name: "Show archived (2)" });
  assert.equal(taskRows("3").length, 0);
  assert.equal(taskRows("4").length, 0);
  assert.equal(screen.queryByRole("menu"), null);

  await app.user.click(
    screen.getByRole("button", { name: "Show archived (2)" }),
  );
  assert.equal(taskRows("3").length, 2);
  assert.equal(taskRows("4").length, 2);
  assert.ok(taskRows("3")[0].querySelector('[aria-label="Archived"]'));
});

test("App archive preserves the choice to show archives", async (ctx) => {
  const app = await renderApp(ctx);
  await app.user.click(
    screen.getByRole("button", { name: "Show archived (1)" }),
  );
  await app.invoke("3", "Archive");
  await app.settle({ archived: true });
  await screen.findByPlaceholderText("Restore this task to continue");
  assert.ok(screen.getByRole("button", { name: "Hide archived" }));
  assert.equal(taskRows("3").length, 2);
  assert.ok(taskRows("3")[0].querySelector('[aria-label="Archived"]'));
});

test("App archive response does not overwrite a display choice made while pending", async (ctx) => {
  const app = await renderApp(ctx);
  await app.user.click(
    screen.getByRole("button", { name: "Show archived (1)" }),
  );
  await app.invoke("3", "Archive");
  await app.user.click(screen.getByRole("button", { name: "Hide archived" }));
  await app.settle({ archived: true });
  await screen.findByRole("button", { name: "Show archived (2)" });
  assert.equal(taskRows("3").length, 0);
  assert.equal(taskRows("4").length, 0);
});

for (const shown of [false, true]) {
  test(`App archive failure preserves ${shown ? "shown" : "hidden"} archives`, async (ctx) => {
    const app = await renderApp(ctx);
    if (shown)
      await app.user.click(
        screen.getByRole("button", { name: "Show archived (1)" }),
      );
    await app.invoke("3", "Archive");
    await app.settle({ error: new Error("Host rejected archive") });
    await screen.findAllByText("The task could not be archived. Try again.");
    assert.ok(
      screen.getByRole("button", {
        name: shown ? "Hide archived" : "Show archived (1)",
      }),
    );
    assert.equal(taskRows("3").length, 2);
    assert.equal(taskRows("4").length, shown ? 2 : 0);
  });
}

for (const archived of [false, true]) {
  test(`App archive timeout reads back archived=${archived} without changing visibility or retrying`, async (ctx) => {
    const app = await renderApp(ctx);
    await app.invoke("3", "Archive");
    await app.settle({
      archived,
      error: new BridgeCommandTimeoutError("metawork.tasks.archive", 10000),
    });
    await screen.findByRole("button", {
      name: `Show archived (${archived ? 2 : 1})`,
    });
    assert.equal(taskRows("3").length, archived ? 0 : 2);
    assert.equal(taskRows("4").length, 0);
    assert.equal(app.requests.length, 1);
  });
}

for (const hideWhilePending of [false, true]) {
  test(`App restore preserves archives ${hideWhilePending ? "hidden while pending" : "shown"}`, async (ctx) => {
    const app = await renderApp(ctx);
    await app.user.click(
      screen.getByRole("button", { name: "Show archived (1)" }),
    );
    await app.invoke("4", "Restore");
    if (hideWhilePending)
      await app.user.click(
        screen.getByRole("button", { name: "Hide archived" }),
      );
    await app.settle({ archived: false });
    await waitFor(() => assert.equal(taskRows("4").length, 2));
    assert.equal(screen.queryByRole("button", { name: /archived/i }), null);
    assert.equal(
      taskRows("4")[0].querySelector('[aria-label="Archived"]'),
      null,
    );

    // A new Host archive makes the toggle observable again, so its absence at
    // zero archived Tasks cannot mask a reset of the user's display choice.
    await app.publishArchive("3", true);
    await screen.findByRole("button", {
      name: hideWhilePending ? "Show archived (1)" : "Hide archived",
    });
    assert.equal(taskRows("3").length, hideWhilePending ? 0 : 2);
  });
}
