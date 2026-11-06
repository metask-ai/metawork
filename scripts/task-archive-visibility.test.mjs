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

function projectHeading() {
  return screen.getByRole("button", { name: "metawork-test", exact: true });
}

function assertFocused(element) {
  // Report bounded diagnostics when waitFor observes focus in transit.
  const actual = document.activeElement;
  const describe = (node) => node?.outerHTML.slice(0, 240) ?? "none";
  assert.ok(
    actual === element,
    `Expected focus on ${describe(element)}, received ${describe(actual)}`,
  );
}

async function renderApp(
  ctx,
  {
    archivedTask = {},
    workspace = {},
    emptyProject = false,
    historyRuns = [],
    projectTask = {},
    projectHidden = false,
  } = {},
) {
  const snapshot = structuredClone(initialSnapshot);
  Object.assign(snapshot.workspaces[0], workspace);
  snapshot.workspaces[0].projectRemoved = projectHidden;
  const task = snapshot.tasks[0];
  Object.assign(task, {
    title: "Archive target",
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    inputReady: true,
    runs: historyRuns,
    ...projectTask,
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
  const projectRemovals = [];
  const historyReads = [];
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
    removeProject: async (workspaceId, expectedWorkspaceEpoch) => {
      projectRemovals.push({ workspaceId, expectedWorkspaceEpoch });
      snapshot.workspaces.find(
        (entry) => entry.id === workspaceId,
      ).projectRemoved = true;
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      return {
        workspaceId,
        expectedWorkspaceEpoch,
        accepted: true,
        reason: null,
      };
    },
    chooseWorkspace: async () => {
      snapshot.workspaces[0].projectRemoved = false;
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      return { selected: true, workspaceId: snapshot.workspaces[0].id };
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
    fetchSnapshot: async (scope) => {
      if (scope.beforeRunId !== null) historyReads.push(scope.beforeRunId);
      return productStateFixture(snapshot, scope);
    },
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
  if (projectHidden) await waitFor(() => assert.equal(taskRows("3").length, 1));
  else await waitFor(projectHeading);
  const user = userEvent.setup({ document });
  return {
    user,
    snapshot,
    requests,
    renames,
    deletions,
    projectRemovals,
    historyReads,
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

test("Composer recalls only the current Task's saved text after remount and pages without moving the conversation reader", async (ctx) => {
  const historyRuns = ["one", "two", "three", "four", "four", "six"].map(
    (text, index) => ({
      ...structuredClone(initialSnapshot.tasks[0].runs[0]),
      id: String(index + 1),
      phase: "completed",
      terminal: {
        outcome: "completed",
        cause: null,
        diagnosticDisposition: "absent",
        recordingIncomplete: false,
        modelError: null,
      },
      input: { kind: "text", text, redacted: false },
      additionalInputs: [],
    }),
  );
  for (let mount = 0; mount < 2; mount++) {
    // Simulate cold Renderer startup with no saved draft or recall cache.
    window.sessionStorage.clear();
    const app = await renderApp(ctx, { historyRuns });
    await app.user.click(taskRows("3")[0]);
    const textarea = await screen.findByPlaceholderText(
      "Enter your instructions…",
    );
    assert.equal(textarea.value, "");
    fireEvent.keyDown(textarea, { key: "ArrowUp" });
    await waitFor(() => assert.equal(textarea.value, "six"));
    assert.deepEqual(app.historyReads, ["3"]);
    for (const expected of ["four", "three", "two", "one", "one"]) {
      fireEvent.keyDown(textarea, { key: "ArrowUp" });
      assert.equal(textarea.value, expected);
    }
    // The original four-Run window has not been expanded by recall reads.
    assert.deepEqual(
      [...document.querySelectorAll(".task-input-copy")].map(
        (node) => node.textContent,
      ),
      ["three", "four", "four", "six"],
    );
    fireEvent.change(textarea, { target: { value: "one edited" } });
    fireEvent.keyDown(textarea, { key: "ArrowDown" });
    assert.equal(textarea.value, "one edited");
    fireEvent.change(textarea, { target: { value: "" } });
    fireEvent.keyDown(textarea, { key: "ArrowUp" });
    await waitFor(() => assert.equal(textarea.value, "six"));
    assert.deepEqual(
      app.historyReads,
      ["3"],
      "reentering recall reuses the App-owned reader",
    );
    fireEvent.keyDown(window, { key: "n", metaKey: true });
    await waitFor(() => assert.equal(textarea.value, ""));
    fireEvent.keyDown(textarea, { key: "ArrowUp" });
    await act(async () => {});
    assert.equal(textarea.value, "");
    cleanup();
  }
});

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
    await screen.findByRole("menuitem", {
      name: "Permanently delete",
      exact: true,
    }),
  );
  await screen.findByRole("alertdialog");
  assert.ok(
    screen.getByRole("heading", { name: "Delete task “Archive target”?" }),
  );
  assert.deepEqual(app.requests, []);
  assert.deepEqual(app.deletions, []);
  await app.user.click(
    screen.getByRole("button", { name: "Permanently delete", exact: true }),
  );
  await waitFor(() => assert.deepEqual(app.deletions, ["3"]));
  assert.equal(app.requests.length, 0);
});

test("settings deletes an archived Task without leaving settings or restoring it", async (ctx) => {
  const app = await renderApp(ctx);
  await app.openArchives();
  await app.user.click(
    screen.getByRole("button", { name: "Permanently delete", exact: true }),
  );
  await screen.findByRole("alertdialog");
  await app.user.click(
    screen.getByRole("button", { name: "Permanently delete", exact: true }),
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
    within(list).getByRole("button", {
      name: "Permanently delete",
      exact: true,
    }).disabled,
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
    screen.getByRole("button", { name: "Permanently delete", exact: true }),
  );
  await screen.findByRole("alertdialog");
  await app.user.click(
    screen.getByRole("button", { name: "Permanently delete", exact: true }),
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
    await screen.findByRole("menuitem", {
      name: "Permanently delete",
      exact: true,
    }),
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
  fireEvent.contextMenu(projectHeading());
  await user.click(
    await screen.findByRole("menuitem", {
      name: "Remove project",
      exact: true,
    }),
  );
  return screen.findByRole("alertdialog");
}

test("task ellipsis entries reuse the context menu without selecting a Task or changing its draft", async (ctx) => {
  const { user } = await renderApp(ctx);
  const editor = document.querySelector(".ai-composer textarea");
  assert.ok(editor);
  fireEvent.change(editor, { target: { value: "Keep the new Task draft" } });
  const rows = [...taskRows("3")];
  assert.equal(rows.length, 2);
  const expected = ["Rename", "Archive", "Permanently delete"];
  for (const row of rows) {
    assert.equal(
      row.querySelector("button"),
      null,
      "interactive buttons must not be nested",
    );
    const trigger = row.parentElement.querySelector(".task-list-menu-trigger");
    assert.equal(
      trigger.getAttribute("aria-label"),
      "Actions for “Archive target”",
    );
    await user.click(trigger);
    const menu = await screen.findByRole("menu", { name: "Task actions" });
    assert.deepEqual(
      within(menu)
        .getAllByRole("menuitem")
        .map((item) => item.textContent),
      expected,
    );
    assert.ok(
      rows.every((entry) => entry.getAttribute("aria-current") === null),
    );
    assert.equal(document.querySelector(".ai-composer textarea"), editor);
    assert.equal(editor.value, "Keep the new Task draft");
    await user.keyboard("{Escape}");
    await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
    await waitFor(() => assertFocused(trigger));
  }
  fireEvent.contextMenu(rows[0]);
  const contextMenu = await screen.findByRole("menu", { name: "Task actions" });
  assert.deepEqual(
    within(contextMenu)
      .getAllByRole("menuitem")
      .map((item) => item.textContent),
    expected,
  );
  await user.keyboard("{Escape}");
  await user.click(
    rows[0].parentElement.querySelector(".task-list-menu-trigger"),
  );
  await user.click(
    await screen.findByRole("menuitem", { name: "Rename", exact: true }),
  );
  const dialog = await screen.findByRole("dialog", { name: "Rename task" });
  assert.equal(
    within(dialog).getByRole("textbox", { name: "Task name" }).value,
    "Archive target",
  );
});

test("task ellipsis supports keyboard navigation, anchors to its button, and restores focus", async (ctx) => {
  mockContextMenuGeometry(ctx);
  const { user } = await renderApp(ctx);
  // Finish the initial Composer focus before starting a keyboard interaction.
  await act(
    async () => new Promise((resolve) => window.requestAnimationFrame(resolve)),
  );
  const trigger = taskRows("3")[0].parentElement.querySelector(
    ".task-list-menu-trigger",
  );
  ctx.mock.method(trigger, "getBoundingClientRect", () => ({
    x: 250,
    y: 100,
    left: 250,
    top: 100,
    right: 282,
    bottom: 132,
    width: 32,
    height: 32,
  }));
  await act(async () => trigger.focus());
  await user.keyboard("{Enter}");
  const rename = await screen.findByRole("menuitem", {
    name: "Rename",
    exact: true,
  });
  await waitFor(() => assertFocused(rename));
  await waitFor(() =>
    assert.deepEqual(contextMenuPosition(), { x: 250, y: 134 }),
  );
  await user.keyboard("{ArrowDown}");
  await waitFor(() =>
    assertFocused(
      screen.getByRole("menuitem", { name: "Archive", exact: true }),
    ),
  );
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  await waitFor(() => assertFocused(trigger));
  await user.keyboard(" ");
  const reopened = await screen.findByRole("menuitem", {
    name: "Rename",
    exact: true,
  });
  await waitFor(() => assert.ok(document.activeElement === reopened));
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  await waitFor(() => assertFocused(trigger));
});

test("task quick archive uses the existing archive flow once and preserves the current draft", async (ctx) => {
  const app = await renderApp(ctx);
  const editor = document.querySelector(".ai-composer textarea");
  assert.ok(editor);
  fireEvent.change(editor, {
    target: { value: "Keep this draft while archiving" },
  });
  const row = taskRows("3")[1];
  const archive = row.parentElement.querySelector(".task-list-archive-trigger");
  assert.equal(archive.getAttribute("aria-label"), "Archive “Archive target”");
  await app.user.dblClick(archive);
  await waitFor(() => assert.equal(app.requests.length, 1));
  assert.deepEqual(
    { taskId: app.requests[0].taskId, archived: app.requests[0].archived },
    { taskId: "3", archived: true },
  );
  assert.equal(screen.queryByRole("menu"), null);
  assert.ok(
    [...taskRows("3")].every(
      (entry) => entry.getAttribute("aria-current") === null,
    ),
  );
  assert.equal(editor.value, "Keep this draft while archiving");
  await app.settle({ archived: true });
  await waitFor(() => assert.equal(taskRows("3").length, 0));
  assert.equal(document.querySelector(".ai-composer textarea"), editor);
  assert.equal(editor.value, "Keep this draft while archiving");
});

test("task quick archive and menu share the running Task restriction", async (ctx) => {
  const run = structuredClone(initialSnapshot.tasks[0].runs[0]);
  run.phase = "running";
  const app = await renderApp(ctx, {
    historyRuns: [run],
    projectTask: {
      activeOperation: { kind: "run", id: run.id },
      currentRunId: run.id,
      currentRunPhase: "running",
    },
  });
  const row = taskRows("3")[0];
  const archive = row.parentElement.querySelector(".task-list-archive-trigger");
  assert.equal(archive.disabled, true);
  await app.user.click(archive);
  assert.equal(app.requests.length, 0);
  fireEvent.contextMenu(row);
  const menuArchive = await screen.findByRole("menuitem", {
    name: "Archive",
    exact: true,
  });
  assert.equal(menuArchive.getAttribute("aria-disabled"), "true");
});

test("project heading toggles only its task list by pointer and keyboard", async (ctx) => {
  const { user } = await renderApp(ctx);
  const heading = projectHeading();
  const rows = screen.getAllByRole("button", { name: "Archive target" });
  const [projectTask, recentTask] = rows;
  await user.click(projectTask);
  const editor = document.querySelector(".ai-composer textarea");
  fireEvent.change(editor, { target: { value: "Keep the active task draft" } });
  assert.equal(heading.getAttribute("aria-expanded"), "true");

  await user.click(heading);
  assert.equal(heading.getAttribute("aria-expanded"), "false");
  assert.ok(
    screen.getByRole("button", { name: "Archive target" }) === recentTask,
  );
  assert.equal(recentTask.getAttribute("aria-current"), "page");
  assert.equal(editor.value, "Keep the active task draft");

  await user.keyboard("{Enter}");
  assert.equal(heading.getAttribute("aria-expanded"), "true");
  assert.equal(
    screen.getAllByRole("button", { name: "Archive target" }).length,
    2,
  );
  await user.keyboard(" ");
  assert.equal(heading.getAttribute("aria-expanded"), "false");
});

test("project expansion is restored by Workspace identity after remount", async (ctx) => {
  const { user } = await renderApp(ctx);
  await user.click(projectHeading());
  cleanup();

  await renderApp(ctx, { workspace: { id: "2" }, emptyProject: true });
  assert.equal(projectHeading().getAttribute("aria-expanded"), "true");
  cleanup();

  const reopened = await renderApp(ctx);
  assert.equal(projectHeading().getAttribute("aria-expanded"), "false");
  await reopened.user.click(projectHeading());
  cleanup();

  await renderApp(ctx);
  assert.equal(projectHeading().getAttribute("aria-expanded"), "true");
});

for (const emptyProject of [false, true])
  test(`project new conversation opens its own draft without creating a Task and preserves other drafts; empty=${emptyProject}`, async (ctx) => {
    const { user, snapshot } = await renderApp(ctx, { emptyProject });
    const before = structuredClone(snapshot);
    let hostCalls = 0;
    for (const command of ["chooseWorkspace", "createTask", "sendInput"])
      ctx.mock.method(BridgeClient.prototype, command, async () => {
        hostCalls++;
      });
    const newConversation = screen.getByRole("button", {
      name: "New conversation in “metawork-test”",
    });
    await user.click(
      screen.getByRole("button", { name: "Skills", exact: true }),
    );
    await act(async () => newConversation.focus());
    await user.keyboard("{Enter}");
    let editor = await screen.findByPlaceholderText("Enter your instructions…");
    await waitFor(() => assert.ok(document.activeElement === editor));
    assert.equal(
      document.querySelector(".composer-workspace-trigger").textContent,
      snapshot.workspaces[0].displayName,
    );
    assert.equal(editor.value, "");
    fireEvent.change(editor, { target: { value: "Saved project draft" } });
    const newTask = screen.getByRole("button", {
      name: "New task",
      exact: true,
    });
    await user.click(newTask);
    editor = await screen.findByPlaceholderText("Enter your instructions…");
    assert.equal(editor.value, "");
    fireEvent.change(editor, { target: { value: "Saved automatic draft" } });
    if (!emptyProject) {
      await user.click(taskRows("3")[0]);
      editor = await screen.findByPlaceholderText("Enter your instructions…");
      fireEvent.change(editor, {
        target: { value: "Saved existing Task draft" },
      });
    }
    await user.click(newConversation);
    editor = await screen.findByPlaceholderText("Enter your instructions…");
    assert.equal(editor.value, "Saved project draft");
    assert.equal(
      document.querySelector(".composer-workspace-trigger").textContent,
      snapshot.workspaces[0].displayName,
    );
    assert.ok(
      [...taskRows("3")].every(
        (row) => row.getAttribute("aria-current") === null,
      ),
    );
    assert.equal(screen.queryByRole("menu"), null);
    await user.click(newTask);
    assert.equal(
      (await screen.findByPlaceholderText("Enter your instructions…")).value,
      "Saved automatic draft",
    );
    if (!emptyProject) {
      await user.click(taskRows("3")[0]);
      assert.equal(
        (await screen.findByPlaceholderText("Enter your instructions…")).value,
        "Saved existing Task draft",
      );
    }
    assert.equal(hostCalls, 0);
    assert.deepEqual(snapshot, before);
  });

for (const authorization of ["reauthorization_required", "removing"])
  test(`project new conversation is disabled for ${authorization} directories`, async (ctx) => {
    const { user } = await renderApp(ctx, { workspace: { authorization } });
    const editor = document.querySelector(".ai-composer textarea");
    fireEvent.change(editor, {
      target: { value: "Preserve the current draft" },
    });
    const trigger = screen.getByRole("button", {
      name: "New conversation in “metawork-test”",
    });
    assert.equal(trigger.disabled, true);
    await user.click(trigger);
    assert.ok(document.querySelector(".ai-composer textarea") === editor);
    assert.equal(editor.value, "Preserve the current draft");
    assert.equal(screen.queryByRole("menu"), null);
  });

for (const emptyProject of [false, true])
  test(`project menu opens its own directory without changing the selected Task; empty=${emptyProject}`, async (ctx) => {
    const { user, snapshot } = await renderApp(ctx, { emptyProject });
    if (!emptyProject) await user.click(taskRows("3")[0]);
    const before = structuredClone(snapshot);
    const calls = [];
    ctx.mock.method(
      BridgeClient.prototype,
      "openWorkspace",
      async (...args) => {
        calls.push(args);
        return { opened: true };
      },
    );
    await user.click(
      screen.getByRole("button", { name: "Project actions for metawork-test" }),
    );
    await user.click(
      await screen.findByRole("menuitem", { name: "Open project folder" }),
    );
    assert.deepEqual(calls, [
      [snapshot.workspaces[0].id, snapshot.workspaces[0].epoch],
    ]);
    assert.deepEqual(snapshot, before);
    if (!emptyProject)
      assert.equal(taskRows("3")[0].getAttribute("aria-current"), "page");
    assert.equal(taskRows("3").length, emptyProject ? 0 : 2);
    assert.equal(screen.queryByRole("alertdialog"), null);
  });

test("unavailable project directory cannot be opened but its entry can still be removed", async (ctx) => {
  const { user } = await renderApp(ctx, {
    workspace: { authorization: "reauthorization_required" },
  });
  let calls = 0;
  ctx.mock.method(BridgeClient.prototype, "openWorkspace", async () => {
    calls++;
    return { opened: true };
  });
  fireEvent.contextMenu(projectHeading());
  const open = await screen.findByRole("menuitem", {
    name: "Open project folder",
  });
  assert.equal(open.getAttribute("aria-disabled"), "true");
  await user.click(open);
  assert.equal(calls, 0);
  await user.click(
    screen.getByRole("menuitem", { name: "Remove project", exact: true }),
  );
  assert.ok(await screen.findByRole("alertdialog"));
});

for (const failure of ["unavailable", "rejected"])
  test(`project folder opening reports ${failure} without removing its group`, async (ctx) => {
    const { user } = await renderApp(ctx);
    ctx.mock.method(BridgeClient.prototype, "openWorkspace", async () => {
      if (failure === "rejected") throw new Error("Host unavailable");
      return { opened: false };
    });
    fireEvent.contextMenu(projectHeading());
    await user.click(
      await screen.findByRole("menuitem", { name: "Open project folder" }),
    );
    assert.match(
      (await screen.findByRole("alert")).textContent,
      /Could not open the project folder/,
    );
    assert.equal(taskRows("3").length, 2);
  });

test("project removal requires confirmation and Cancel restores focus without a command", async (ctx) => {
  const { user } = await renderApp(ctx);
  let calls = 0;
  ctx.mock.method(BridgeClient.prototype, "removeWorkspace", async () => {
    calls++;
  });
  const dialog = await openProjectRemoval(user);
  assert.match(dialog.textContent, /tasks in progress are unaffected/);
  const cancel = within(dialog).getByRole("button", { name: "Cancel" });
  await waitFor(() => assert.ok(document.activeElement === cancel));
  await user.click(cancel);
  assert.equal(calls, 0);
  await waitFor(() => assertFocused(projectHeading()));
});

async function confirmProjectRemoval(user) {
  const dialog = await openProjectRemoval(user);
  await user.click(
    within(dialog).getByRole("button", { name: "Remove project", exact: true }),
  );
  await waitFor(() =>
    assert.ok(!document.querySelector(".task-project-context")),
  );
}

for (const emptyProject of [false, true])
  test(`project removal hides only its group and preserves Workspace authority; empty=${emptyProject}`, async (ctx) => {
    const { user, snapshot, projectRemovals } = await renderApp(ctx, {
      emptyProject,
      workspace: { authorization: "reauthorization_required" },
    });
    if (!emptyProject) await user.click(taskRows("3")[0]);
    const before = structuredClone(snapshot);
    const calls = [];
    ctx.mock.method(BridgeClient.prototype, "removeWorkspace", async () =>
      calls.push("remove"),
    );
    ctx.mock.method(BridgeClient.prototype, "stopTask", async () =>
      calls.push("stop"),
    );
    await confirmProjectRemoval(user);
    assert.deepEqual(calls, []);
    before.workspaces[0].projectRemoved = true;
    before.revision = snapshot.revision;
    assert.deepEqual(snapshot, before);
    assert.deepEqual(projectRemovals, [
      { workspaceId: "1", expectedWorkspaceEpoch: "1" },
    ]);
    assert.equal(taskRows("3").length, emptyProject ? 0 : 1);
    if (!emptyProject)
      assert.equal(taskRows("3")[0].getAttribute("aria-current"), "page");
  });

for (const phase of ["queued", "running", "waiting_ui", "stopping"])
  test(`removing a project leaves its ${phase} Task and current draft untouched`, async (ctx) => {
    const run = structuredClone(initialSnapshot.tasks[0].runs[0]);
    run.phase = phase;
    const { user, snapshot } = await renderApp(ctx, {
      historyRuns: [run],
      projectTask: {
        activeOperation: { kind: "run", id: run.id },
        currentRunId: run.id,
        currentRunPhase: phase,
      },
    });
    await user.click(taskRows("3")[0]);
    const editor = document.querySelector(".ai-composer textarea");
    if (editor && !editor.disabled)
      fireEvent.change(editor, { target: { value: "Keep this draft" } });
    const draft = editor?.value;
    const before = structuredClone(snapshot);
    const calls = [];
    ctx.mock.method(BridgeClient.prototype, "removeWorkspace", async () =>
      calls.push("remove"),
    );
    ctx.mock.method(BridgeClient.prototype, "stopTask", async () =>
      calls.push("stop"),
    );
    await confirmProjectRemoval(user);
    assert.deepEqual(calls, []);
    before.workspaces[0].projectRemoved = true;
    before.revision = snapshot.revision;
    assert.deepEqual(snapshot, before);
    assert.equal(taskRows("3").length, 1);
    assert.equal(taskRows("3")[0].getAttribute("aria-current"), "page");
    assert.equal(document.querySelector(".ai-composer textarea"), editor);
    assert.equal(editor?.value, draft);
    await user.click(taskRows("3")[0]);
    assert.equal(taskRows("3")[0].getAttribute("aria-current"), "page");
  });

test("project removal waits for Host acceptance and allows retry after rejection", async (ctx) => {
  const { user, snapshot } = await renderApp(ctx);
  let resolveRemoval;
  let calls = 0;
  ctx.mock.method(BridgeClient.prototype, "removeProject", () => {
    calls++;
    return new Promise((resolve) => {
      resolveRemoval = resolve;
    });
  });
  const dialog = await openProjectRemoval(user);
  const remove = within(dialog).getByRole("button", {
    name: "Remove project",
    exact: true,
  });
  await user.click(remove);
  assert.equal(calls, 1);
  assert.ok(remove.disabled);
  assert.ok(document.querySelector(".task-project-context"));
  await user.click(remove);
  assert.equal(calls, 1);
  await act(async () =>
    resolveRemoval({
      accepted: false,
      workspaceId: "1",
      reason: "workspace_changed",
    }),
  );
  await within(dialog).findByRole("alert");
  assert.ok(document.querySelector(".task-project-context"));
  await user.click(remove);
  snapshot.workspaces[0].projectRemoved = true;
  snapshot.revision = String(BigInt(snapshot.revision) + 1n);
  await act(async () =>
    resolveRemoval({ accepted: true, workspaceId: "1", reason: null }),
  );
  await waitFor(() =>
    assert.equal(document.querySelector(".task-project-context"), null),
  );
  assert.equal(calls, 2);
});

test("timed out project removal reconciles the Host state without resending", async (ctx) => {
  const { user, snapshot } = await renderApp(ctx);
  let calls = 0;
  ctx.mock.method(BridgeClient.prototype, "removeProject", async () => {
    calls++;
    snapshot.workspaces[0].projectRemoved = true;
    snapshot.revision = String(BigInt(snapshot.revision) + 1n);
    throw new Error("timeout");
  });
  await confirmProjectRemoval(user);
  assert.equal(calls, 1);
  assert.equal(taskRows("3").length, 1);
});

async function openLocalWorkspaceFolder(user) {
  await user.click(
    screen.getByRole("combobox", { name: "Choose working directory" }),
  );
  await user.click(
    await screen.findByRole("option", { name: "Open local folder" }),
  );
}

test("Host project removal survives remount and native folder selection restores its group", async (ctx) => {
  const { user } = await renderApp(ctx);
  await confirmProjectRemoval(user);
  cleanup();
  const remounted = await renderApp(ctx, { projectHidden: true });
  assert.equal(document.querySelector(".task-project-context"), null);
  assert.equal(taskRows("3").length, 1);
  await remounted.user.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  const picker = screen.getByRole("combobox", {
    name: "Choose working directory",
  });
  await remounted.user.click(picker);
  assert.equal((await screen.findAllByRole("option")).length, 2);
  assert.ok(
    screen.getByRole("option", {
      name: "No working directory",
      selected: true,
    }),
  );
  await remounted.user.click(
    screen.getByRole("option", { name: "Open local folder" }),
  );
  await waitFor(projectHeading);
  assert.equal(taskRows("3").length, 2);

  await remounted.user.click(picker);
  await screen.findByRole("option", { name: "metawork-test", exact: true });
  assert.equal(screen.queryByText("/tmp/metawork-test"), null);
});

for (const outcome of ["selected", "cancelled", "superseded"])
  test(`native folder selection uses Host project state without switching a superseded Task: ${outcome}`, async (ctx) => {
    const { user, snapshot, publishTask } = await renderApp(ctx);
    await confirmProjectRemoval(user);
    await user.click(
      screen.getByRole("button", { name: "New task", exact: true }),
    );
    let resolveChoice;
    ctx.mock.method(
      BridgeClient.prototype,
      "chooseWorkspace",
      () =>
        new Promise((resolve) => {
          resolveChoice = resolve;
        }),
    );
    await openLocalWorkspaceFolder(user);
    assert.equal(typeof resolveChoice, "function");
    if (outcome === "superseded") await user.click(taskRows("3")[0]);
    if (outcome !== "cancelled") snapshot.workspaces[0].projectRemoved = false;
    await act(async () =>
      resolveChoice(
        outcome === "cancelled"
          ? { selected: false }
          : { selected: true, workspaceId: snapshot.workspaces[0].id },
      ),
    );
    if (outcome === "superseded") await publishTask("3", {});
    await waitFor(() =>
      assert.equal(taskRows("3").length, outcome !== "cancelled" ? 2 : 1),
    );
    assert.equal(
      document.querySelector(".task-project-context") !== null,
      outcome !== "cancelled",
    );
    if (outcome === "superseded")
      assert.equal(taskRows("3")[0].getAttribute("aria-current"), "page");
  });

test("project removal menu and confirmation can be operated with the keyboard", async (ctx) => {
  const { user } = await renderApp(ctx);
  const trigger = projectHeading();
  await user.click(taskRows("3")[0]);
  await act(async () => trigger.focus());
  assert.ok(
    document.activeElement === trigger,
    "project menu trigger owns keyboard focus",
  );
  await user.keyboard("{Shift>}{F10}{/Shift}");
  const open = await screen.findByRole("menuitem", {
    name: "Open project folder",
    exact: true,
  });
  await waitFor(() => assertFocused(open));
  await user.keyboard("{ArrowDown}");
  const remove = await screen.findByRole("menuitem", {
    name: "Remove project",
    exact: true,
  });
  await waitFor(() =>
    assert.ok(
      document.activeElement === remove,
      `project menu item receives keyboard focus; current=${document.activeElement?.textContent}`,
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

test("project ellipsis shares the heading context menu without selecting a Task or changing its draft", async (ctx) => {
  const { user } = await renderApp(ctx);
  const editor = document.querySelector(".ai-composer textarea");
  fireEvent.change(editor, {
    target: { value: "Keep the project menu draft" },
  });
  const heading = projectHeading();
  const trigger = screen.getByRole("button", {
    name: "Project actions for metawork-test",
  });
  const expected = ["Open project folder", "Remove project"];
  await user.click(heading);
  assert.equal(screen.queryByRole("menu"), null);
  await user.click(trigger);
  let menu = await screen.findByRole("menu");
  assert.equal(heading.getAttribute("aria-expanded"), "false");
  assert.deepEqual(
    within(menu)
      .getAllByRole("menuitem")
      .map((item) => item.textContent),
    expected,
  );
  assert.ok(
    [...taskRows("3")].every(
      (row) => row.getAttribute("aria-current") === null,
    ),
  );
  assert.equal(document.querySelector(".ai-composer textarea"), editor);
  assert.equal(editor.value, "Keep the project menu draft");
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  await waitFor(() => assertFocused(trigger));
  fireEvent.contextMenu(heading);
  menu = await screen.findByRole("menu");
  assert.deepEqual(
    within(menu)
      .getAllByRole("menuitem")
      .map((item) => item.textContent),
    expected,
  );
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  await waitFor(() => assertFocused(heading));
  fireEvent.keyDown(heading, { key: "ContextMenu" });
  await screen.findByRole("menuitem", { name: "Remove project", exact: true });
});

test("project ellipsis anchors its menu, supports keyboard navigation and restores focus after confirmation", async (ctx) => {
  mockContextMenuGeometry(ctx);
  const { user } = await renderApp(ctx);
  await act(
    async () => new Promise((resolve) => window.requestAnimationFrame(resolve)),
  );
  const trigger = screen.getByRole("button", {
    name: "Project actions for metawork-test",
  });
  ctx.mock.method(trigger, "getBoundingClientRect", () => ({
    x: 250,
    y: 100,
    left: 250,
    top: 100,
    right: 274,
    bottom: 132,
    width: 24,
    height: 32,
  }));
  await act(async () => trigger.focus());
  await user.keyboard("{Enter}");
  const open = await screen.findByRole("menuitem", {
    name: "Open project folder",
    exact: true,
  });
  await waitFor(() => assertFocused(open));
  await waitFor(() =>
    assert.deepEqual(contextMenuPosition(), { x: 250, y: 134 }),
  );
  await user.keyboard("{ArrowDown}");
  await waitFor(() =>
    assertFocused(
      screen.getByRole("menuitem", { name: "Remove project", exact: true }),
    ),
  );
  await user.keyboard("{Enter}");
  const dialog = await screen.findByRole("alertdialog");
  await waitFor(() =>
    assertFocused(within(dialog).getByRole("button", { name: "Cancel" })),
  );
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("alertdialog"), null));
  await waitFor(() => assertFocused(trigger));
  await user.keyboard("{Shift>}{F10}{/Shift}");
  await screen.findByRole("menu");
  await waitFor(() =>
    assert.deepEqual(contextMenuPosition(), { x: 250, y: 134 }),
  );
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  await waitFor(() => assertFocused(trigger));
  await user.keyboard(" ");
  const reopened = await screen.findByRole("menuitem", {
    name: "Open project folder",
    exact: true,
  });
  await waitFor(() => assert.ok(document.activeElement === reopened));
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  await waitFor(() => assertFocused(trigger));
});

for (const kind of ["project", "task"])
  test(`${kind} ellipsis mouse click keeps items unhighlighted and preserves button positioning`, async (ctx) => {
    mockContextMenuGeometry(ctx);
    const { user } = await renderApp(ctx);
    const trigger =
      kind === "project"
        ? screen.getByRole("button", {
            name: "Project actions for metawork-test",
          })
        : taskRows("3")[0].parentElement.querySelector(
            ".task-list-menu-trigger",
          );
    ctx.mock.method(trigger, "getBoundingClientRect", () => ({
      x: 250,
      y: 100,
      left: 250,
      top: 100,
      right: 274,
      bottom: 132,
      width: 24,
      height: 32,
    }));
    await user.click(trigger);
    const menu = await screen.findByRole("menu");
    await act(
      async () =>
        new Promise((resolve) =>
          window.requestAnimationFrame(() =>
            window.requestAnimationFrame(resolve),
          ),
        ),
    );
    const items = within(menu).getAllByRole("menuitem");
    assert.ok(
      document.activeElement === menu,
      "mouse opening focuses the popup, not its first item",
    );
    assert.ok(items.every((item) => !item.hasAttribute("data-highlighted")));
    await waitFor(() =>
      assert.deepEqual(contextMenuPosition(), { x: 250, y: 134 }),
    );
    await user.keyboard("{ArrowDown}");
    await waitFor(() => assertFocused(items[0]));
    await user.keyboard("{Escape}");
    await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
    await waitFor(() => assertFocused(trigger));
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
    const target = kind === "project" ? projectHeading() : taskRows("3")[0];
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
    const target = kind === "project" ? projectHeading() : taskRows("3")[0];
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
          name: "Permanently delete",
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
        screen.getByRole("button", { name: "Permanently delete", exact: true }),
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
    await screen.findByRole("menuitem", {
      name: "Permanently delete",
      exact: true,
    }),
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
