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

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
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

async function renderApp(
  ctx,
  { archivedTask = {}, workspace = {}, emptyProject = false } = {},
) {
  const snapshot = structuredClone(initialSnapshot);
  Object.assign(snapshot.workspaces[0], workspace);
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
    ...archivedTask,
  });
  snapshot.workspaces[0].signals.running = 0;
  if (emptyProject) snapshot.tasks = [];
  const requests = [];
  const renames = [];
  let onRevision;
  let shortcut;
  const deletions = [];
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: (callback) => {
      shortcut = callback;
      return () => {};
    },
    deleteTask: async (taskId) => {
      deletions.push(taskId);
      snapshot.tasks = snapshot.tasks.filter((task) => task.id !== taskId);
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
    },
    onHostSignal: () => () => {},
    onTaskOpen: () => () => {},
    onWorkbenchRevision: (callback) => {
      onRevision = callback;
      return () => {};
    },
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    renameTask: async (taskId, title) => {
      const result = await new Promise((resolve) =>
        renames.push({ taskId, title, resolve }),
      );
      if (result.committed || !result.error) {
        snapshot.tasks.find((entry) => entry.id === taskId).title = title;
        snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      }
      if (result.error) throw result.error;
    },
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
  await screen.findByRole("group", {
    name: "Project actions for metawork-test",
  });
  const user = userEvent.setup({ document });
  return {
    user,
    snapshot,
    requests,
    renames,
    deletions,
    async openRename(taskId = "3", select = true) {
      const row = taskRows(taskId)[0];
      if (select) await user.click(row);
      fireEvent.contextMenu(row);
      await user.click(
        await screen.findByRole("menuitem", { name: "Rename", exact: true }),
      );
      const dialog = await screen.findByRole("dialog", { name: "Rename task" });
      const input = within(dialog).getByRole("textbox", { name: "Task name" });
      await waitFor(() => assert.ok(document.activeElement === input));
      assert.equal(input.selectionStart, 0);
      assert.equal(input.selectionEnd, input.value.length);
      return input;
    },
    async settleRename(result = {}) {
      await act(async () => renames.at(-1).resolve(result));
    },
    async openArchives() {
      await act(async () => shortcut({ id: "settings.open" }));
      await user.click(
        await screen.findByRole("link", { name: "Archived tasks" }),
      );
      await screen.findByRole("heading", { name: "Archived tasks" });
    },
    async invoke(id, action) {
      const row = taskRows(id)[0];
      assert.ok(row, "Task must be visible before opening its menu");
      await user.click(row);
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
      await act(async () => requests.at(-1).resolve(result));
    },
    async publishTask(taskId, patch) {
      if (patch === null) {
        snapshot.tasks = snapshot.tasks.filter((task) => task.id !== taskId);
      } else {
        Object.assign(
          snapshot.tasks.find((task) => task.id === taskId),
          patch,
        );
      }
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      await act(async () =>
        onRevision(snapshot.revision, snapshot.securityEpoch ?? "1"),
      );
    },
  };
}

for (const activation of [
  "mouse click",
  "button Enter",
  "button Space",
  "input Enter",
]) {
  test(`rename via ${activation} submits once and updates the header and navigation after confirmation`, async (ctx) => {
    const app = await renderApp(ctx);
    const input = await app.openRename();
    const title = "P1 QA 7429 代码读取与修复";
    await app.user.clear(input);
    await app.user.type(input, `  ${title}  `);
    const save = screen.getByRole("button", { name: "Save", exact: true });
    if (activation === "mouse click") {
      await app.user.click(save);
    } else if (activation === "input Enter") {
      await app.user.keyboard("{Enter}");
    } else {
      await app.user.tab();
      assert.ok(
        document.activeElement ===
          screen.getByRole("button", { name: "Cancel" }),
      );
      await app.user.tab();
      assert.ok(document.activeElement === save);
      await app.user.keyboard(activation === "button Enter" ? "{Enter}" : " ");
    }
    await waitFor(() => assert.equal(app.renames.length, 1));
    assert.equal(app.renames[0].taskId, "3");
    assert.equal(app.renames[0].title, title);
    assert.ok(screen.getByRole("textbox", { name: "Task name" }) === input);
    assert.equal(save.disabled, true);
    for (const row of taskRows("3"))
      assert.equal(row.textContent, "Archive target");

    await app.settleRename();
    await waitFor(() => {
      assert.ok(screen.queryByRole("textbox", { name: "Task name" }) === null);
      assert.equal(
        document.querySelector(".commandbar-task").textContent,
        title,
      );
      assert.equal(taskRows("3").length, 2);
      for (const row of taskRows("3")) assert.equal(row.textContent, title);
    });
    assert.equal(app.renames.length, 1);
    assert.equal(app.requests.length, 0);
    assert.equal(app.deletions.length, 0);
  });
}

for (const dismissal of ["Cancel", "Escape", "backdrop"]) {
  test(`rename ${dismissal} discards the draft without submitting`, async (ctx) => {
    const app = await renderApp(ctx);
    const input = await app.openRename();
    await app.user.clear(input);
    await app.user.type(input, "Discard this draft");
    if (dismissal === "Cancel") {
      await app.user.click(screen.getByRole("button", { name: "Cancel" }));
    } else if (dismissal === "backdrop") {
      await app.user.click(
        screen
          .getAllByRole("presentation", { hidden: true })
          .find((element) => element.hasAttribute("data-open")),
      );
    } else {
      await app.user.keyboard("{Escape}");
    }
    await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
    assert.equal(app.renames.length, 0);
    assert.equal((await app.openRename()).value, "Archive target");
  });
}

test("rename rejects a blank draft through both Save and input Enter", async (ctx) => {
  const app = await renderApp(ctx);
  const input = await app.openRename();
  await app.user.clear(input);
  await app.user.type(input, "   ");
  const save = screen.getByRole("button", { name: "Save", exact: true });
  assert.equal(save.disabled, true);
  await app.user.click(save);
  await app.user.click(input);
  await app.user.keyboard("{Enter}");
  assert.equal(app.renames.length, 0);
  assert.ok(screen.getByRole("textbox", { name: "Task name" }) === input);
});

test("rename rejection preserves the draft and permits an explicit retry", async (ctx) => {
  const app = await renderApp(ctx);
  const input = await app.openRename();
  await app.user.clear(input);
  await app.user.type(input, "Retry this title");
  await app.user.click(
    screen.getByRole("button", { name: "Save", exact: true }),
  );
  await waitFor(() => assert.equal(app.renames.length, 1));
  await app.settleRename({ error: new Error("Host rejected rename") });
  const error = await within(screen.getByRole("dialog")).findByRole("alert");
  assert.equal(error.textContent, "The task could not be renamed. Try again.");
  assert.equal(
    screen.getByRole("textbox", { name: "Task name" }).value,
    "Retry this title",
  );
  const save = screen.getByRole("button", { name: "Save", exact: true });
  assert.equal(save.disabled, false);
  assert.equal(app.renames.length, 1);
  await app.user.click(save);
  await waitFor(() => assert.equal(app.renames.length, 2));
  assert.equal(app.renames[1].taskId, "3");
  assert.equal(app.renames[1].title, "Retry this title");
  await app.settleRename();
  await waitFor(() =>
    assert.ok(screen.queryByRole("textbox", { name: "Task name" }) === null),
  );
});

test("rename Dialog traps focus and leaves the task title as display text", async (ctx) => {
  const app = await renderApp(ctx);
  await app.openRename();
  assert.equal(
    document.querySelector(".commandbar-task").textContent,
    "Archive target",
  );
  assert.equal(document.querySelector(".commandbar-context input"), null);
  assert.ok(
    screen.getByRole("dialog").closest("[data-native-window-drag-exclude]"),
  );
  await app.user.tab({ shift: true });
  const dialog = screen.getByRole("dialog");
  await waitFor(() =>
    assert.ok(
      dialog.contains(document.activeElement),
      document.activeElement.outerHTML.slice(0, 300),
    ),
  );
  for (let index = 0; index < 4; index++) {
    await app.user.tab();
    await waitFor(() =>
      assert.ok(
        dialog.contains(document.activeElement),
        document.activeElement.outerHTML.slice(0, 300),
      ),
    );
  }
});

test("rename IME confirmation does not submit or dismiss the Dialog", async (ctx) => {
  const app = await renderApp(ctx);
  const input = await app.openRename();
  fireEvent.compositionStart(input);
  fireEvent.change(input, { target: { value: "中文任务名称" } });
  await app.user.keyboard("{Enter}{Escape}");
  assert.ok(screen.getByRole("dialog"));
  assert.equal(app.renames.length, 0);
  fireEvent.compositionEnd(input);
  await app.user.keyboard("{Enter}");
  await waitFor(() => assert.equal(app.renames.length, 1));
  assert.equal(app.renames[0].title, "中文任务名称");
  await app.settleRename();
});

test("pending rename cannot be edited, dismissed or submitted again", async (ctx) => {
  const app = await renderApp(ctx);
  const input = await app.openRename();
  await app.user.type(input, "Pending title");
  await app.user.keyboard("{Enter}");
  await waitFor(() => assert.equal(app.renames.length, 1));
  assert.equal(input.disabled, true);
  const saving = screen.getByRole("button", { name: "Saving…" });
  assert.equal(saving.disabled, true);
  await app.user.keyboard("{Enter}{Escape}");
  await app.user.click(screen.getByRole("button", { name: "Cancel" }));
  await app.user.click(
    screen
      .getAllByRole("presentation", { hidden: true })
      .find((element) => element.hasAttribute("data-open")),
  );
  await app.user.click(saving);
  assert.ok(screen.getByRole("dialog"));
  assert.equal(app.renames.length, 1);
  await app.settleRename();
  await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
});

for (const committed of [true, false]) {
  test(`rename timeout reads back committed=${committed} without resending`, async (ctx) => {
    const app = await renderApp(ctx);
    const input = await app.openRename();
    await app.user.clear(input);
    await app.user.type(input, "Uncertain rename");
    await app.user.keyboard("{Enter}");
    await waitFor(() => assert.equal(app.renames.length, 1));
    await app.settleRename({
      committed,
      error: new BridgeCommandTimeoutError("metawork.tasks.rename", 10000),
    });
    if (committed) {
      await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
      assert.equal(
        document.querySelector(".commandbar-task").textContent,
        "Uncertain rename",
      );
    } else {
      await screen.findByRole("alert");
      assert.equal(
        screen.getByRole("textbox", { name: "Task name" }).value,
        "Uncertain rename",
      );
      assert.equal(
        screen.getByRole("button", { name: "Save" }).disabled,
        false,
      );
      await app.user.keyboard("{Escape}");
      await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
    }
    assert.equal(app.renames.length, 1);
    assert.ok(
      !document.querySelector(".commandbar-alert"),
      "a legacy timeout stops occupying the command bar after trusted synchronization",
    );
  });
}

test("legacy timeout synchronization failure belongs only to connection feedback", async (ctx) => {
  const app = await renderApp(ctx);
  const input = await app.openRename();
  await app.user.clear(input);
  await app.user.type(input, "Unconfirmed while offline");
  await app.user.keyboard("{Enter}");
  await waitFor(() => assert.equal(app.renames.length, 1));
  ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", async () => {
    throw new Error("fixture read unavailable");
  });
  await app.settleRename({
    error: new BridgeCommandTimeoutError("metawork.tasks.rename", 10000),
  });
  await waitFor(
    () =>
      assert.match(
        document.querySelector(".commandbar-alert summary")?.textContent ?? "",
        /not synced/,
      ),
    { timeout: 7000 },
  );
  assert.equal(app.renames.length, 1);
  fireEvent.click(document.querySelector(".commandbar-alert summary"));
  assert.equal(
    document.querySelectorAll(".commandbar-alert-content .feedback-notice")
      .length,
    1,
  );
});

for (const patch of [
  null,
  { archived: true },
  {
    continuationUnavailableReason: "history_read_only",
    continuationAvailable: false,
  },
  { lifecycle: "closing", deletionStatus: "deleting" },
]) {
  test(`rename closes when target becomes ${JSON.stringify(patch)}`, async (ctx) => {
    const app = await renderApp(ctx);
    await app.openRename();
    await app.publishTask("3", patch);
    await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
    assert.equal(app.renames.length, 0);
  });
}

test("a late rename result does not clear another Task's Dialog", async (ctx) => {
  const app = await renderApp(ctx);
  await app.publishTask("4", { archived: false });
  const input = await app.openRename();
  await app.user.type(input, "First rename");
  await app.user.keyboard("{Enter}");
  await waitFor(() => assert.equal(app.renames.length, 1));
  await app.publishTask("3", { archived: true });
  await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
  const nextInput = await app.openRename("4", false);
  await app.user.clear(nextInput);
  await app.user.type(nextInput, "Second draft");
  await app.settleRename();
  assert.equal(
    screen.getByRole("textbox", { name: "Task name" }).value,
    "Second draft",
  );
  await app.user.keyboard("{Enter}");
  await waitFor(() => assert.equal(app.renames.length, 2));
  assert.equal(app.renames[1].taskId, "4");
  assert.equal(app.renames[1].title, "Second draft");
  await app.settleRename();
});

test("archive hides Task from Recent and Projects and settings manages the same history", async (ctx) => {
  const app = await renderApp(ctx);
  assert.equal(taskRows("3").length, 2);
  assert.equal(taskRows("4").length, 0);
  assert.equal(screen.queryByRole("button", { name: /Show archived/ }), null);
  await app.invoke("3", "Archive");
  await app.settle({ archived: true });
  await waitFor(() => assert.equal(taskRows("3").length, 0));
  await app.openArchives();
  assert.ok(screen.getByRole("button", { name: "Archive target" }));
  assert.ok(screen.getByRole("button", { name: "Earlier archive" }));
  await app.user.type(
    screen.getByRole("searchbox", { name: "Search archived tasks" }),
    "Earlier",
  );
  assert.equal(screen.queryByRole("button", { name: "Archive target" }), null);
  assert.ok(screen.getByRole("button", { name: "Earlier archive" }));
});

test("settings restore keeps its page and returns the same Task to navigation", async (ctx) => {
  const app = await renderApp(ctx);
  await app.openArchives();
  await app.user.click(
    within(screen.getByRole("list", { name: "Archived tasks" })).getByRole(
      "button",
      { name: "Restore", exact: true },
    ),
  );
  await waitFor(() => assert.equal(app.requests.length, 1));
  assert.deepEqual(
    { taskId: app.requests[0].taskId, archived: app.requests[0].archived },
    { taskId: "4", archived: false },
  );
  await app.settle({ archived: false });
  await screen.findByText("Archived tasks will appear here.");
  assert.ok(screen.getByRole("heading", { name: "Archived tasks" }));
  assert.equal(taskRows("4").length, 2);
});

test("unarchived Task deletes directly after one fixed-target confirmation", async (ctx) => {
  const app = await renderApp(ctx);
  fireEvent.contextMenu(taskRows("3")[0]);
  await app.user.click(
    await screen.findByRole("menuitem", { name: "Delete record", exact: true }),
  );
  await screen.findByRole("alertdialog");
  assert.ok(
    screen.getByRole("heading", { name: "Delete task “Archive target”?" }),
  );
  assert.deepEqual(app.requests, []);
  assert.deepEqual(app.deletions, []);
  await app.user.click(
    screen.getByRole("button", { name: "Delete record", exact: true }),
  );
  await waitFor(() => assert.deepEqual(app.deletions, ["3"]));
  assert.equal(app.requests.length, 0);
});

test("settings deletes an archived Task without leaving settings or restoring it", async (ctx) => {
  const app = await renderApp(ctx);
  await app.openArchives();
  await app.user.click(
    screen.getByRole("button", { name: "Delete record", exact: true }),
  );
  await screen.findByRole("alertdialog");
  await app.user.click(
    screen.getByRole("button", { name: "Delete record", exact: true }),
  );
  await waitFor(() => assert.deepEqual(app.deletions, ["4"]));
  await screen.findByText("Archived tasks will appear here.");
  assert.equal(app.requests.length, 0);
});

test("archive failure preserves navigation and does not expose hidden archives", async (ctx) => {
  const app = await renderApp(ctx);
  await app.invoke("3", "Archive");
  await app.settle({ error: new Error("Host rejected archive") });
  await screen.findAllByText("The task could not be archived. Try again.");
  assert.equal(taskRows("3").length, 2);
  assert.equal(taskRows("4").length, 0);
});

for (const archived of [false, true]) {
  test(`archive timeout reads canonical archived=${archived} without retrying`, async (ctx) => {
    const app = await renderApp(ctx);
    await app.invoke("3", "Archive");
    await app.settle({
      archived,
      error: new BridgeCommandTimeoutError("metawork.tasks.archive", 10000),
    });
    await waitFor(() => assert.equal(taskRows("3").length, archived ? 0 : 2));
    assert.equal(taskRows("4").length, 0);
    assert.equal(app.requests.length, 1);
  });
}

test("confirmed archive offers undo for its exact Task and keeps the history read-only", async (ctx) => {
  const app = await renderApp(ctx);
  await app.invoke("3", "Archive");
  await app.settle({ archived: true });
  await screen.findByText(
    "Task archived. Find it in Settings → Archived tasks.",
  );
  assert.ok(screen.getByText("This task is archived. Restore it to continue."));
  assert.equal(screen.queryByRole("textbox"), null);
  assert.equal(taskRows("3").length, 0);
  await app.user.click(
    screen.getByRole("button", { name: "Undo", exact: true }),
  );
  await waitFor(() => assert.equal(app.requests.length, 2));
  assert.deepEqual(
    { taskId: app.requests[1].taskId, archived: app.requests[1].archived },
    { taskId: "3", archived: false },
  );
  await app.settle({ archived: false });
  await waitFor(() => assert.equal(taskRows("3").length, 2));
  assert.equal(
    screen.queryByText("Task archived. Find it in Settings → Archived tasks."),
    null,
  );
});

test("archive notice View opens the archived settings section", async (ctx) => {
  const app = await renderApp(ctx);
  await app.invoke("3", "Archive");
  await app.settle({ archived: true });
  await app.user.click(
    await screen.findByRole("button", { name: "View", exact: true }),
  );
  await screen.findByRole("heading", { name: "Archived tasks" });
  assert.ok(screen.getByRole("button", { name: "Archive target" }));
});

test("archived history returns to settings with query, scroll and focus preserved", async (ctx) => {
  const app = await renderApp(ctx);
  await app.openArchives();
  await app.user.type(
    screen.getByRole("searchbox", { name: "Search archived tasks" }),
    "Earlier",
  );
  const content = document.querySelector(".settings-content");
  content.scrollTop = 240;
  fireEvent.scroll(content);
  await app.user.click(screen.getByRole("button", { name: "Earlier archive" }));
  await screen.findByText("This task is archived. Restore it to continue.");
  assert.equal(screen.queryByRole("textbox"), null);
  await app.user.click(
    screen.getByRole("button", { name: "Back to archived tasks" }),
  );
  await screen.findByRole("heading", { name: "Archived tasks" });
  assert.equal(
    screen.getByRole("searchbox", { name: "Search archived tasks" }).value,
    "Earlier",
  );
  assert.equal(document.querySelector(".settings-content").scrollTop, 240);
  await waitFor(() =>
    assert.equal(document.activeElement.textContent, "Earlier archive"),
  );
});

test("archive timeout shows success only when canonical archive is confirmed", async (ctx) => {
  const app = await renderApp(ctx);
  await app.invoke("3", "Archive");
  await app.settle({
    archived: true,
    error: new BridgeCommandTimeoutError("metawork.tasks.archive", 10000),
  });
  await screen.findByText(
    "Task archived. Find it in Settings → Archived tasks.",
  );
  assert.equal(app.requests.length, 1);
});

test("archive notice pauses dismissal while hovered or keyboard-focused", async (ctx) => {
  const { ArchiveNotice } = await vite.ssrLoadModule(
    "/src/features/tasks/ArchiveNotice.tsx",
  );
  ctx.mock.timers.enable({ apis: ["setTimeout"] });
  let dismissed = 0;
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
      createElement(ArchiveNotice, {
        notice: { id: 1, taskId: "3", kind: "archived" },
        disabled: false,
        onUndo() {},
        onView() {},
        onDismiss() {
          dismissed++;
        },
      }),
    ),
  );
  const notice = document.querySelector(".archive-notice");
  fireEvent.mouseEnter(notice);
  await act(async () => ctx.mock.timers.tick(9000));
  assert.equal(dismissed, 0);
  await act(async () =>
    screen.getByRole("button", { name: "Undo", exact: true }).focus(),
  );
  fireEvent.mouseLeave(notice);
  await act(async () => ctx.mock.timers.tick(9000));
  assert.equal(dismissed, 0);
  await act(async () =>
    screen.getByRole("button", { name: "Undo", exact: true }).blur(),
  );
  await act(async () => ctx.mock.timers.tick(8000));
  assert.equal(dismissed, 1);
});

test("restore failure stays actionable on the archived settings row", async (ctx) => {
  const app = await renderApp(ctx);
  await app.openArchives();
  const list = screen.getByRole("list", { name: "Archived tasks" });
  await app.user.click(
    within(list).getByRole("button", { name: "Restore", exact: true }),
  );
  await waitFor(() => assert.equal(app.requests.length, 1));
  await app.settle({ error: new Error("Host refused restore") });
  await screen.findByText("The task could not be restored. Try again.");
  assert.ok(screen.getByRole("button", { name: "Earlier archive" }));
  assert.equal(
    within(list).getByRole("button", { name: "Restore", exact: true }).disabled,
    false,
  );
});

test("newer-version archived history remains readable without mutation controls", async (ctx) => {
  const app = await renderApp(ctx, {
    archivedTask: {
      continuationUnavailableReason: "history_read_only",
      continuationAvailable: false,
      continuationRecoveryAvailable: false,
    },
  });
  await app.openArchives();
  const list = screen.getByRole("list", { name: "Archived tasks" });
  assert.equal(
    within(list).getByRole("button", { name: "Restore", exact: true }).disabled,
    true,
  );
  assert.equal(
    within(list).getByRole("button", { name: "Delete record", exact: true })
      .disabled,
    true,
  );
  assert.equal(
    within(list).getByRole("button", { name: "Earlier archive" }).disabled,
    false,
  );
});

test("deleting another Task in settings preserves the selected conversation", async (ctx) => {
  const app = await renderApp(ctx);
  await app.user.click(taskRows("3")[0]);
  await app.openArchives();
  await app.user.click(
    screen.getByRole("button", { name: "Delete record", exact: true }),
  );
  await screen.findByRole("alertdialog");
  await app.user.click(
    screen.getByRole("button", { name: "Delete record", exact: true }),
  );
  await screen.findByText("Archived tasks will appear here.");
  await app.user.click(
    screen.getByRole("button", { name: "Back to workbench" }),
  );
  await waitFor(() =>
    assert.equal(taskRows("3")[0].getAttribute("aria-current"), "page"),
  );
  assert.deepEqual(app.deletions, ["4"]);
});

test("delete confirmation defaults to cancel and cancelling has no effect", async (ctx) => {
  const app = await renderApp(ctx);
  fireEvent.contextMenu(taskRows("3")[0]);
  await app.user.click(
    await screen.findByRole("menuitem", { name: "Delete record", exact: true }),
  );
  await screen.findByRole("alertdialog");
  await waitFor(() =>
    assert.equal(
      document.activeElement.textContent,
      "Cancel",
      document.activeElement.outerHTML.slice(0, 500),
    ),
  );
  await app.user.click(
    screen.getByRole("button", { name: "Cancel", exact: true }),
  );
  assert.deepEqual(app.deletions, []);
  assert.deepEqual(app.requests, []);
  assert.equal(taskRows("3").length, 2);
});

async function openProjectRemoval(user) {
  fireEvent.contextMenu(
    screen.getByRole("group", { name: "Project actions for metawork-test" }),
  );
  await user.click(
    await screen.findByRole("menuitem", {
      name: "Remove project",
      exact: true,
    }),
  );
  return screen.findByRole("alertdialog");
}

test("project removal requires confirmation and Cancel restores focus without a command", async (ctx) => {
  const { user } = await renderApp(ctx);
  let calls = 0;
  ctx.mock.method(BridgeClient.prototype, "removeWorkspace", async () => {
    calls++;
  });
  const dialog = await openProjectRemoval(user);
  assert.match(dialog.textContent, /Local files and task history will be kept/);
  const cancel = within(dialog).getByRole("button", { name: "Cancel" });
  await waitFor(() => assert.ok(document.activeElement === cancel));
  await user.click(cancel);
  assert.equal(calls, 0);
  assert.ok(
    screen.getByRole("group", { name: "Project actions for metawork-test" }),
  );
  await waitFor(() =>
    assert.equal(
      document.activeElement?.getAttribute("aria-label"),
      "Project actions for metawork-test",
    ),
  );
});

for (const emptyProject of [false, true])
  test(`project removal syncs navigation and preserves history; empty=${emptyProject}`, async (ctx) => {
    const { user, snapshot } = await renderApp(ctx, {
      emptyProject,
      workspace: { authorization: "reauthorization_required" },
    });
    if (!emptyProject) await user.click(taskRows("3")[0]);
    const historyCount = snapshot.tasks.length;
    const calls = [];
    let finish;
    ctx.mock.method(
      BridgeClient.prototype,
      "removeWorkspace",
      async (id, epoch) => {
        calls.push({ id, epoch });
        await new Promise((resolve) => {
          finish = resolve;
        });
        snapshot.workspaces = [];
        snapshot.revision = String(BigInt(snapshot.revision) + 1n);
        return { accepted: true, workspaceId: id, reason: null };
      },
    );
    const dialog = await openProjectRemoval(user);
    await user.click(
      within(dialog).getByRole("button", {
        name: "Remove project",
        exact: true,
      }),
    );
    await waitFor(() => assert.equal(calls.length, 1));
    assert.deepEqual(calls, [{ id: "1", epoch: "1" }]);
    assert.equal(
      within(dialog).getByRole("button", { name: "Removing" }).disabled,
      true,
    );
    await act(async () => finish());
    await waitFor(() =>
      assert.equal(
        screen.queryByRole("group", {
          name: "Project actions for metawork-test",
        }),
        null,
      ),
    );
    assert.equal(snapshot.tasks.length, historyCount);
    assert.equal(taskRows("3").length, 0);
  });

test("project close failure remains visible and an explicit retry uses the refreshed epoch", async (ctx) => {
  const { user, snapshot } = await renderApp(ctx);
  const epochs = [];
  ctx.mock.method(
    BridgeClient.prototype,
    "removeWorkspace",
    async (id, epoch) => {
      epochs.push(epoch);
      snapshot.workspaces[0].epoch = "2";
      snapshot.workspaces[0].lastRemovalFailure = "task_close_failed";
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      return { accepted: false, workspaceId: id, reason: "task_close_failed" };
    },
  );
  const dialog = await openProjectRemoval(user);
  await user.click(
    within(dialog).getByRole("button", { name: "Remove project", exact: true }),
  );
  await within(dialog).findByRole("alert");
  assert.equal(epochs.length, 1);
  assert.ok(document.querySelector(".task-project-context"));
  await user.click(
    within(dialog).getByRole("button", { name: "Remove project", exact: true }),
  );
  await waitFor(() => assert.deepEqual(epochs, ["1", "2"]));
});

for (const committed of [true, false])
  test(`project removal timeout reconciles without resending; committed=${committed}`, async (ctx) => {
    const { user, snapshot } = await renderApp(ctx);
    let calls = 0;
    ctx.mock.method(BridgeClient.prototype, "removeWorkspace", async () => {
      calls++;
      if (committed) snapshot.workspaces = [];
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      throw new BridgeCommandTimeoutError("metawork.workspaces.remove", 10000);
    });
    const dialog = await openProjectRemoval(user);
    await user.click(
      within(dialog).getByRole("button", {
        name: "Remove project",
        exact: true,
      }),
    );
    if (committed)
      await waitFor(() =>
        assert.equal(document.querySelector(".task-project-context"), null),
      );
    else
      assert.match(
        (await within(dialog).findByRole("alert")).textContent,
        /could not be confirmed/,
      );
    assert.equal(calls, 1);
  });

test("pending project removal disables duplicate actions", async (ctx) => {
  const { user } = await renderApp(ctx, {
    workspace: { authorization: "removing" },
  });
  const trigger = screen.getByRole("group", {
    name: "Project actions for metawork-test",
  });
  assert.equal(trigger.getAttribute("aria-disabled"), "true");
  fireEvent.contextMenu(trigger);
  assert.equal(screen.queryByRole("menu"), null);
  assert.ok(screen.getByText("Removing"));
});

test("project removal menu and confirmation can be operated with the keyboard", async (ctx) => {
  const { user } = await renderApp(ctx);
  const trigger = screen.getByRole("group", {
    name: "Project actions for metawork-test",
  });
  await user.click(taskRows("3")[0]);
  await act(async () => trigger.focus());
  assert.ok(
    document.activeElement === trigger,
    "project menu trigger owns keyboard focus",
  );
  await user.keyboard("{Shift>}{F10}{/Shift}");
  const remove = await screen.findByRole("menuitem", {
    name: "Remove project",
    exact: true,
  });
  await waitFor(() =>
    assert.ok(
      document.activeElement === remove,
      "project menu item receives keyboard focus",
    ),
  );
  await user.keyboard("{Enter}");
  const dialog = await screen.findByRole("alertdialog");
  await waitFor(() =>
    assert.ok(
      document.activeElement ===
        within(dialog).getByRole("button", { name: "Cancel" }),
    ),
  );
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("alertdialog"), null));
});

test("project heading has no dropdown button and opens its menu with right click or the menu key", async (ctx) => {
  const { user } = await renderApp(ctx);
  const heading = screen.getByRole("group", {
    name: "Project actions for metawork-test",
  });
  assert.equal(within(heading).queryByRole("button"), null);
  await user.click(heading);
  assert.equal(screen.queryByRole("menu"), null);
  fireEvent.contextMenu(heading);
  await screen.findByRole("menuitem", { name: "Remove project", exact: true });
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  fireEvent.keyDown(heading, { key: "ContextMenu" });
  await screen.findByRole("menuitem", { name: "Remove project", exact: true });
});

function mockContextMenuGeometry(ctx) {
  const overrides = [
    [document.documentElement, "clientWidth", () => 1024],
    [document.documentElement, "clientHeight", () => 768],
    [
      HTMLElement.prototype,
      "offsetWidth",
      function () {
        return this.style.position === "fixed" ||
          this.getAttribute("role") === "menu"
          ? 180
          : 0;
      },
    ],
    [
      HTMLElement.prototype,
      "offsetHeight",
      function () {
        return this.style.position === "fixed" ||
          this.getAttribute("role") === "menu"
          ? 108
          : 0;
      },
    ],
  ];
  for (const [target, name, get] of overrides) {
    const descriptor = Object.getOwnPropertyDescriptor(target, name);
    Object.defineProperty(target, name, { configurable: true, get });
    ctx.after(() =>
      descriptor
        ? Object.defineProperty(target, name, descriptor)
        : delete target[name],
    );
  }
}

function contextMenuPosition() {
  const positioner = screen.getByRole("menu").parentElement;
  const match = positioner.style.transform.match(
    /translate\(([-\d.]+)px,\s*([-\d.]+)px\)/,
  );
  return match
    ? { x: Number(match[1]), y: Number(match[2]) }
    : {
        x: parseFloat(positioner.style.left),
        y: parseFloat(positioner.style.top),
      };
}

for (const kind of ["project", "task"])
  test(`${kind} context menu follows each right-click and stays inside window edges`, async (ctx) => {
    mockContextMenuGeometry(ctx);
    const { user } = await renderApp(ctx);
    const target =
      kind === "project"
        ? screen.getByRole("group", {
            name: "Project actions for metawork-test",
          })
        : taskRows("3")[0];
    fireEvent.contextMenu(target, { clientX: 120, clientY: 180, button: 2 });
    await screen.findByRole("menu");
    await waitFor(() =>
      assert.deepEqual(contextMenuPosition(), { x: 120, y: 180 }),
    );
    fireEvent.contextMenu(target, { clientX: 280, clientY: 320, button: 2 });
    await screen.findByRole("menu");
    await waitFor(() =>
      assert.deepEqual(contextMenuPosition(), { x: 280, y: 320 }),
    );
    await user.keyboard("{Escape}");
    fireEvent.contextMenu(target, { clientX: 1018, clientY: 762, button: 2 });
    await screen.findByRole("menu");
    await waitFor(() => {
      const point = contextMenuPosition();
      assert.ok(
        point.x >= 8 && point.x + 180 <= 1016,
        `horizontal collision: ${point.x}`,
      );
      assert.ok(
        point.y >= 8 && point.y + 108 <= 760,
        `vertical collision: ${point.y}`,
      );
    });
  });

for (const kind of ["project", "task"])
  test(`${kind} keyboard menu uses the list item and returns focus`, async (ctx) => {
    mockContextMenuGeometry(ctx);
    const { user } = await renderApp(ctx);
    await user.click(taskRows("3")[0]);
    // Let the selected Task finish its scheduled Composer focus before testing the menu.
    await act(
      async () =>
        new Promise((resolve) => window.requestAnimationFrame(resolve)),
    );
    const target =
      kind === "project"
        ? screen.getByRole("group", {
            name: "Project actions for metawork-test",
          })
        : taskRows("3")[0];
    ctx.mock.method(target, "getBoundingClientRect", () => ({
      x: 16,
      y: 16,
      left: 16,
      top: 16,
      right: 336,
      bottom: 52,
      width: 320,
      height: 36,
    }));
    await act(async () => target.focus());
    await user.keyboard("{Shift>}{F10}{/Shift}");
    await screen.findByRole("menu");
    await waitFor(() =>
      assert.deepEqual(contextMenuPosition(), { x: 16, y: 54 }),
    );
    await user.keyboard("{Escape}");
    await waitFor(() =>
      assert.ok(
        document.activeElement === target,
        "context menu returns focus to its opener",
      ),
    );
  });

test("security refresh retains archive admission and processes its original failure", async (ctx) => {
  const app = await renderApp(ctx);
  await app.invoke("3", "Archive");
  app.snapshot.securityEpoch = "2";
  await app.publishTask("3", {});
  await waitFor(() => assert.ok(taskRows("3").length));
  fireEvent.contextMenu(taskRows("3")[0]);
  await app.user.click(
    await screen.findByRole("menuitem", { name: "Archive", exact: true }),
  );
  assert.equal(app.requests.length, 1);
  await app.settle({
    error: new Error("diagnostic from before security refresh"),
  });
  await waitFor(() => assert.ok(document.querySelector(".archive-notice")));
  await app.user.click(
    screen.getByRole("button", { name: "Task information", exact: true }),
  );
  assert.ok(screen.queryByText("Operation diagnostics") === null);
  assert.ok(
    !document.body.textContent.includes(
      "diagnostic from before security refresh",
    ),
  );
});

for (const dialog of ["delete", "rename"]) {
  test(`security refresh preserves ${dialog} intent through an unloaded snapshot`, async (ctx) => {
    const app = await renderApp(ctx);
    if (dialog === "rename") {
      const input = await app.openRename();
      await app.user.clear(input);
      await app.user.type(input, "unsaved rename survives");
    } else {
      fireEvent.contextMenu(taskRows("3")[0]);
      await app.user.click(
        await screen.findByRole("menuitem", {
          name: "Delete record",
          exact: true,
        }),
      );
      await screen.findByRole("alertdialog");
    }
    let release,
      hold = true;
    ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", (scope) => {
      if (!hold)
        return Promise.resolve(productStateFixture(app.snapshot, scope));
      return new Promise((resolve) => {
        release = () => {
          hold = false;
          resolve(productStateFixture(app.snapshot, scope));
        };
      });
    });
    app.snapshot.securityEpoch = "2";
    await app.publishTask("3", {});
    await waitFor(() => assert.equal(typeof release, "function"));
    await act(async () => release());
    if (dialog === "rename") {
      assert.equal(
        (await screen.findByRole("textbox", { name: "Task name" })).value,
        "unsaved rename survives",
      );
    } else {
      await screen.findByRole("alertdialog");
      await app.user.click(
        screen.getByRole("button", { name: "Delete record", exact: true }),
      );
      await waitFor(() => assert.deepEqual(app.deletions, ["3"]));
    }
  });
}

test("a loaded empty index confirms the last Task removal and closes its deletion intent", async (ctx) => {
  const app = await renderApp(ctx);
  app.snapshot.tasks = app.snapshot.tasks.filter((t) => t.id === "3");
  await app.publishTask("3", {});
  fireEvent.contextMenu(taskRows("3")[0]);
  await app.user.click(
    await screen.findByRole("menuitem", { name: "Delete record", exact: true }),
  );
  await screen.findByRole("alertdialog");
  await app.publishTask("3", null);
  await waitFor(() => assert.ok(screen.queryByRole("alertdialog") === null));
  assert.equal(app.snapshot.tasks.length, 0);
});

test("generation replacement isolates old archive replies from a newer operation", async (ctx) => {
  const { WorkbenchConnection } = await vite.ssrLoadModule(
    "/src/bridge/connection.ts",
  );
  const start = WorkbenchConnection.prototype.start;
  let connection;
  ctx.mock.method(WorkbenchConnection.prototype, "start", function () {
    connection = this;
    return start.call(this);
  });
  let generation = "1";
  const app = await renderApp(ctx);
  ctx.mock.method(BridgeClient.prototype, "connect", async () => generation);
  await app.invoke("3", "Archive");
  generation = "2";
  await act(async () => connection.retry({ replaceConnection: true }));
  await waitFor(() => assert.ok(taskRows("3").length));
  const invoke = async () => {
    fireEvent.contextMenu(taskRows("3")[0]);
    await app.user.click(
      await screen.findByRole("menuitem", { name: "Archive", exact: true }),
    );
  };
  await invoke();
  await waitFor(() => assert.equal(app.requests.length, 2));
  await act(async () =>
    app.requests[0].resolve({
      error: new Error("old generation archive failure"),
    }),
  );
  assert.ok(!document.querySelector(".archive-notice"));
  await invoke();
  assert.equal(app.requests.length, 2);
  await app.settle({ archived: true });
  await waitFor(() => assert.ok(document.querySelector(".archive-notice")));
});
