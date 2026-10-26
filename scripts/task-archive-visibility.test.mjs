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

async function renderApp(ctx, { archivedTask = {} } = {}) {
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
    ...archivedTask,
  });
  snapshot.workspaces[0].signals.running = 0;
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
  await screen.findAllByRole("button", { name: "Archive target" });
  const user = userEvent.setup({ document });
  return {
    user,
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
  });
}

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
