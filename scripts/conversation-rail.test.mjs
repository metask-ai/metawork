import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

import { decodeWorkbenchSnapshot } from "../frontend/src/bridge/decode-contracts.ts";
import {
  createRailPosition,
  pendingRailJumpValid,
  railCurrentRun,
  railEntries,
  railKeyTarget,
  railScrollBehavior,
  railScrollForRow,
  railVisible,
  runMessageReadingId,
  sameRailEntries,
} from "../frontend/src/features/tasks/conversation-rail.ts";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
globalThis.CSS ??= { escape: (value) => value.replace(/["\\]/g, "\\$&") };
dom.window.CSS ??= globalThis.CSS;
const scrolls = [];
HTMLElement.prototype.scrollTo = function scrollTo(options) {
  scrolls.push({ element: this, options });
};
if (!HTMLElement.prototype.scrollIntoView)
  HTMLElement.prototype.scrollIntoView = () => undefined;

const { act, cleanup, fireEvent, render, screen, waitFor } =
  await import("./renderer-testing-library.mjs");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { ConversationRail } = await vite.ssrLoadModule(
  "/src/features/tasks/ConversationRail.tsx",
);
const { TaskContent, createTaskReadingMemory } = await vite.ssrLoadModule(
  "/src/features/tasks/TaskContent.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
test.after(async () => {
  cleanup();
  await vite.close();
});
test.afterEach(() => {
  cleanup();
  scrolls.length = 0;
});

// Assertions compare booleans or strings, never DOM nodes: a failing assert
// would inspect the whole jsdom window and exhaust the heap before reporting.
const wire = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/product-view.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
const decoded = decodeWorkbenchSnapshot(wire).taskPage;
const manifestEntry = (id, excerpt = `message ${id}`, time = null) => ({
  ...structuredClone(decoded.runManifest[0]),
  id,
  excerpt,
  submittedAtUnixMs: time,
});
const runView = (id) => ({
  ...structuredClone(decoded.task.runs[0]),
  id,
  submission: {
    presentationOrder: null,
    operationId: `op-${id}`,
    receivedAtUnixMs: null,
    anchorRunId: null,
    afterOutputCount: 0,
  },
  input: { kind: "text", text: `message ${id}`, redacted: false },
});
const taskView = (taskId, ids) => ({
  ...structuredClone(decoded.task),
  id: taskId,
  currentRunId: ids.at(-1),
  activeOperation: null,
  runs: ids.map(runView),
});

function withI18n(child, locale = "en-US") {
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

test("rail entries number projected Runs and compare by display facts only", () => {
  const entries = railEntries([
    manifestEntry("4", "first", "1700000000000"),
    manifestEntry("9", null),
  ]);
  assert.deepEqual(entries, [
    {
      runId: "4",
      turn: 1,
      excerpt: "first",
      submittedAtUnixMs: "1700000000000",
    },
    { runId: "9", turn: 2, excerpt: null, submittedAtUnixMs: null },
  ]);
  assert.equal(sameRailEntries(entries, structuredClone(entries)), true);
  assert.equal(
    sameRailEntries(entries, [entries[0], { ...entries[1], excerpt: "x" }]),
    false,
  );
  assert.equal(sameRailEntries(entries, entries.slice(1)), false);
});

test("the rail appears only for several turns that do not already fit", () => {
  assert.equal(
    railVisible({ runCount: 1, olderHistory: true, scrollable: true }),
    false,
  );
  assert.equal(
    railVisible({ runCount: 2, olderHistory: false, scrollable: false }),
    false,
  );
  assert.equal(
    railVisible({ runCount: 2, olderHistory: true, scrollable: false }),
    true,
  );
  assert.equal(
    railVisible({ runCount: 2, olderHistory: false, scrollable: true }),
    true,
  );
});

test("the current row follows the reading anchor, or the latest while following", () => {
  const entries = railEntries(["1", "2", "3"].map((id) => manifestEntry(id)));
  assert.equal(railCurrentRun(entries, "2", false), "2");
  assert.equal(railCurrentRun(entries, "2", true), "3");
  assert.equal(railCurrentRun(entries, null, false), "3");
  assert.equal(railCurrentRun(entries, "8", false), "3");
  assert.equal(railCurrentRun([], null, true), null);
});

test("rail keys move within bounds and leave every other key alone", () => {
  assert.equal(railKeyTarget("ArrowUp", 0, 5), 0);
  assert.equal(railKeyTarget("ArrowUp", 3, 5), 2);
  assert.equal(railKeyTarget("ArrowDown", 4, 5), 4);
  assert.equal(railKeyTarget("PageUp", 25, 300), 15);
  assert.equal(railKeyTarget("PageDown", 295, 300), 299);
  assert.equal(railKeyTarget("Home", 120, 300), 0);
  assert.equal(railKeyTarget("End", 0, 300), 299);
  assert.equal(railKeyTarget("Enter", 1, 5), null);
  assert.equal(railKeyTarget("a", 1, 5), null);
  assert.equal(railKeyTarget("ArrowUp", 0, 0), null);
});

test("a row is scrolled into the rail only when it is not fully visible", () => {
  const geometry = { rowHeight: 10, inset: 8, viewHeight: 100, scrollTop: 0 };
  assert.equal(railScrollForRow(3, geometry), null);
  assert.equal(railScrollForRow(20, geometry), 8 + 21 * 10 + 8 - 100);
  assert.equal(railScrollForRow(2, { ...geometry, scrollTop: 50 }), 20);
});

test("a Run's message keeps its reading identity wherever the plan places it", () => {
  assert.equal(
    runMessageReadingId({ id: "7", submission: { operationId: "op" } }),
    "submission:op",
  );
  assert.equal(runMessageReadingId({ id: "7", submission: null }), "7:root");
});

test("a waiting jump ends with its Task or its Run", () => {
  const jump = { taskId: "1", runId: "2" };
  assert.equal(pendingRailJumpValid(jump, "1", [{ id: "2" }]), true);
  assert.equal(pendingRailJumpValid(jump, "3", [{ id: "2" }]), false);
  assert.equal(pendingRailJumpValid(jump, "1", [{ id: "4" }]), false);
});

test("near jumps glide and far or reduced-motion jumps land at once", () => {
  assert.equal(railScrollBehavior(-1200, 600, false), "smooth");
  assert.equal(railScrollBehavior(-1201, 600, false), "auto");
  assert.equal(railScrollBehavior(100, 600, true), "auto");
});

test("the rail position notifies only on change", () => {
  const position = createRailPosition();
  let calls = 0;
  const stop = position.subscribe(() => calls++);
  position.set("1");
  position.set("1");
  position.set("2");
  stop();
  position.set("3");
  assert.equal(calls, 2);
  assert.equal(position.get(), "3");
});

function renderRail(props = {}) {
  const position = createRailPosition();
  position.set(props.current ?? "3");
  const jumps = [];
  const entries = railEntries([
    manifestEntry("1", "first message", "1700000000000"),
    manifestEntry("2", null),
    manifestEntry("3", "/review src"),
  ]);
  render(
    withI18n(
      createElement(ConversationRail, {
        entries,
        position,
        loadedFrom: 0,
        canLoad: true,
        pendingRunId: null,
        onJump: (runId) => jumps.push(runId),
        ...props,
        ...(props.entries ? {} : { entries }),
      }),
    ),
  );
  return { jumps, position, listbox: screen.getByRole("listbox") };
}

test("the rail is one labelled listbox with a named option per turn", () => {
  const { listbox } = renderRail();
  assert.equal(listbox.getAttribute("aria-label"), "Conversation navigation");
  assert.equal(listbox.tabIndex, 0);
  const options = screen.getAllByRole("option");
  assert.equal(options.length, 3);
  assert.match(
    options[0].getAttribute("aria-label"),
    /^Turn 1, .+, first message$/,
  );
  assert.equal(
    options[1].getAttribute("aria-label"),
    "Turn 2, Sensitive values were hidden",
  );
  assert.equal(options[2].getAttribute("aria-selected"), "true");
  assert.equal(options[0].getAttribute("aria-selected"), "false");
  assert.equal(listbox.getAttribute("aria-activedescendant"), options[2].id);
});

test("row names follow changed turns and locale but survive unrelated re-renders", () => {
  const position = createRailPosition();
  const props = (entries, locale = "en-US", loadedFrom = 0) =>
    withI18n(
      createElement(ConversationRail, {
        entries,
        position,
        loadedFrom,
        canLoad: true,
        pendingRunId: null,
        onJump() {},
      }),
      locale,
    );
  const first = railEntries([manifestEntry("1", "first"), manifestEntry("2")]);
  const view = render(props(first));
  const name = () =>
    screen.getAllByRole("option")[0].getAttribute("aria-label");
  assert.equal(name(), "Turn 1, first");
  view.rerender(props(structuredClone(first), "en-US", 1));
  assert.equal(name(), "Turn 1, first");
  view.rerender(
    props(railEntries([manifestEntry("1", "edited"), manifestEntry("2")])),
  );
  assert.equal(name(), "Turn 1, edited");
  view.rerender(
    props(
      railEntries([manifestEntry("1", "edited"), manifestEntry("2")]),
      "zh-CN",
    ),
  );
  assert.equal(name(), "第 1 轮，edited");
});

test("rail keys move the highlighted turn and Enter jumps to it", () => {
  const { jumps, listbox } = renderRail();
  const options = screen.getAllByRole("option");
  act(() => listbox.focus());
  for (const [key, expected] of [
    ["ArrowUp", 1],
    ["ArrowUp", 0],
    ["ArrowUp", 0],
    ["End", 2],
    ["Home", 0],
    ["PageDown", 2],
  ]) {
    const event = fireEvent.keyDown(listbox, { key });
    assert.equal(event, false, `${key} is the rail's own key`);
    assert.equal(
      listbox.getAttribute("aria-activedescendant"),
      options[expected].id,
      key,
    );
  }
  assert.equal(fireEvent.keyDown(listbox, { key: "a" }), true);
  assert.equal(
    fireEvent.keyDown(listbox, { key: "ArrowUp", ctrlKey: true }),
    true,
  );
  fireEvent.keyDown(listbox, { key: "Home" });
  fireEvent.keyDown(listbox, { key: "Enter" });
  assert.deepEqual(jumps, ["1"]);
});

test("pressing a row focuses the rail without moving its highlight under the pointer", () => {
  // On a long rail, highlighting the reading row on a pointer-driven focus
  // scrolls it to that row before the click lands, and the click is lost.
  const { jumps, listbox } = renderRail();
  const options = screen.getAllByRole("option");
  fireEvent.pointerDown(options[0]);
  act(() => listbox.focus());
  assert.equal(
    options.some((option) => option.hasAttribute("data-active")),
    false,
  );
  fireEvent.click(options[0]);
  assert.deepEqual(jumps, ["1"]);
  // Keyboard focus still starts at the reading row.
  act(() => listbox.blur());
  act(() => listbox.focus());
  assert.equal(options[2].hasAttribute("data-active"), true);
});

test("a turn that needs history cannot be chosen while history cannot load", () => {
  const blocked = renderRail({ loadedFrom: 2, canLoad: false });
  const options = screen.getAllByRole("option");
  assert.equal(options[0].getAttribute("aria-disabled"), "true");
  assert.equal(options[2].getAttribute("aria-disabled"), null);
  fireEvent.click(options[0]);
  act(() => blocked.listbox.focus());
  fireEvent.keyDown(blocked.listbox, { key: "Home" });
  fireEvent.keyDown(blocked.listbox, { key: "Enter" });
  fireEvent.click(options[2]);
  assert.deepEqual(blocked.jumps, ["3"]);
});

test("a keyboard-highlighted turn shows its excerpt and Escape hides it", async () => {
  const { listbox } = renderRail();
  act(() => listbox.focus());
  fireEvent.keyDown(listbox, { key: "Home" });
  await screen.findByText("first message");
  assert.ok(screen.getByText(/^Turn 1 · /));
  fireEvent.keyDown(listbox, { key: "ArrowDown" });
  await screen.findByText("Sensitive values were hidden");
  assert.ok(screen.getByText("Turn 2"));
  fireEvent.keyDown(listbox, { key: "Escape" });
  await waitFor(() =>
    assert.equal(
      screen.queryByText("Sensitive values were hidden") === null,
      true,
    ),
  );
  assert.equal(document.activeElement === listbox, true);
});

test("the current row moves with the reading position without a new rail", () => {
  const { position } = renderRail();
  act(() => position.set("1"));
  const options = screen.getAllByRole("option");
  assert.equal(options[0].getAttribute("aria-selected"), "true");
  assert.equal(options[0].hasAttribute("data-current"), true);
  assert.equal(options[2].hasAttribute("data-current"), false);
});

function contentProps(task, manifest, history, extra = {}) {
  return {
    task,
    runManifest: manifest,
    history,
    revision: "1",
    snapshotReceivedAt: 1,
    synchronized: true,
    requestingStop: false,
    composerHasDraft: false,
    retryAvailable: false,
    responseDisabled: false,
    fileChangesEnabled: false,
    outputsEnabled: false,
    webLink: () => undefined,
    onPrepareRetry() {},
    onPreviewFile() {},
    onReviewFileChanges() {},
    onRespond() {},
    renderPendingUi: () => null,
    ...extra,
  };
}

function historyRecorder() {
  const calls = [];
  return {
    calls,
    history: {
      available: true,
      loading: false,
      onLoad() {},
      onRequest: (runId) => calls.push(["request", runId]),
      onRelease: (taskId, runId) => calls.push(["release", taskId, runId]),
    },
  };
}

test("the conversation shows the rail only for several turns with more to reach", () => {
  const manifest = ["5", "6"].map((id) => manifestEntry(id));
  const { history } = historyRecorder();
  const view = render(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["5", "6"]), manifest, history),
      ),
    ),
  );
  assert.ok(screen.queryByRole("listbox", { name: "Conversation navigation" }));
  view.rerender(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["6"]), [manifestEntry("6")], {
          ...history,
          available: false,
        }),
      ),
    ),
  );
  assert.equal(screen.queryByRole("listbox") === null, true);
});

test("choosing a loaded turn scrolls its message into place and gives it focus", () => {
  const manifest = ["5", "6", "7"].map((id) => manifestEntry(id));
  const { calls, history } = historyRecorder();
  render(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["5", "6", "7"]), manifest, history),
      ),
    ),
  );
  scrolls.length = 0;
  fireEvent.click(screen.getAllByRole("option")[0]);
  assert.equal(document.activeElement.dataset.readingId, "submission:op-5");
  const viewport = document.querySelector(".ai-conversation-viewport");
  assert.ok(scrolls.some((entry) => entry.element === viewport));
  assert.deepEqual(calls, []);
});

test("choosing an unloaded turn loads history and lands when the turn arrives", () => {
  const manifest = ["5", "6", "7"].map((id) => manifestEntry(id));
  const { calls, history } = historyRecorder();
  const view = render(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["7"]), manifest, history),
      ),
    ),
  );
  fireEvent.click(screen.getAllByRole("option")[0]);
  assert.deepEqual(calls, [["request", "5"]]);
  assert.equal(
    screen.getAllByRole("option")[0].hasAttribute("data-pending"),
    true,
  );
  // A page that does not reach the target yet keeps the jump waiting.
  view.rerender(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["6", "7"]), manifest, {
          ...history,
          loading: true,
        }),
      ),
    ),
  );
  assert.notEqual(document.activeElement.dataset.readingId, "submission:op-6");
  view.rerender(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["5", "6", "7"]), manifest, history),
      ),
    ),
  );
  assert.equal(document.activeElement.dataset.readingId, "submission:op-5");
  assert.equal(
    screen.getAllByRole("option")[0].hasAttribute("data-pending"),
    false,
  );
  assert.deepEqual(calls, [["request", "5"]]);
});

test("scrolling by hand cancels a waiting jump and stops its history", () => {
  const manifest = ["5", "6", "7"].map((id) => manifestEntry(id));
  const { calls, history } = historyRecorder();
  const view = render(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["7"]), manifest, history),
      ),
    ),
  );
  fireEvent.click(screen.getAllByRole("option")[0]);
  fireEvent.wheel(document.querySelector(".ai-conversation-viewport"), {
    deltaY: 40,
  });
  assert.deepEqual(calls, [
    ["request", "5"],
    ["release", "1", "7"],
  ]);
  view.rerender(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["5", "6", "7"]), manifest, history),
      ),
    ),
  );
  assert.notEqual(document.activeElement.dataset.readingId, "submission:op-5");
});

test("a waiting jump ends when its Run is replaced or its Task changes", () => {
  for (const next of [
    // An edit replaced the target turn: it left the manifest.
    (history) =>
      contentProps(
        taskView("1", ["7"]),
        ["6", "7"].map((id) => manifestEntry(id)),
        history,
      ),
    // Another Task opened.
    (history) =>
      contentProps(
        taskView("2", ["9"]),
        ["8", "9"].map((id) => manifestEntry(id)),
        history,
      ),
  ]) {
    const manifest = ["5", "6", "7"].map((id) => manifestEntry(id));
    const { calls, history } = historyRecorder();
    const view = render(
      withI18n(
        createElement(
          TaskContent,
          contentProps(taskView("1", ["7"]), manifest, history),
        ),
      ),
    );
    fireEvent.click(screen.getAllByRole("option")[0]);
    view.rerender(withI18n(createElement(TaskContent, next(history))));
    assert.deepEqual(calls, [
      ["request", "5"],
      ["release", "1", "7"],
    ]);
    cleanup();
  }
});

test("a new choice replaces a waiting jump and releases its history first", () => {
  const manifest = ["4", "5", "6", "7"].map((id) => manifestEntry(id));
  const { calls, history } = historyRecorder();
  render(
    withI18n(
      createElement(
        TaskContent,
        contentProps(taskView("1", ["6", "7"]), manifest, history),
      ),
    ),
  );
  fireEvent.click(screen.getAllByRole("option")[0]);
  // A later unloaded target must not keep loading toward the earlier one.
  fireEvent.click(screen.getAllByRole("option")[1]);
  assert.deepEqual(calls, [
    ["request", "4"],
    ["release", "1", "6"],
    ["request", "5"],
  ]);
  assert.equal(
    screen.getAllByRole("option")[1].hasAttribute("data-pending"),
    true,
  );
  // A loaded choice lands at once and ends the waiting jump.
  fireEvent.click(screen.getAllByRole("option")[3]);
  assert.deepEqual(calls.slice(3), [["release", "1", "6"]]);
  assert.equal(document.activeElement.dataset.readingId, "submission:op-7");
  assert.equal(
    screen
      .getAllByRole("option")
      .some((option) => option.hasAttribute("data-pending")),
    false,
  );
});

test("a sent image keeps one address from waiting through its Run", () => {
  const image = { kind: "image", format: "png", displayName: "shot.png" };
  const input = {
    kind: "multimodal",
    text: "Look",
    attachments: [{ ...image, sizeBytes: "10", media: true, redacted: false }],
    skill: null,
    redacted: false,
  };
  const submission = {
    ...runView("9").submission,
    operationId: "op-image",
    anchorRunId: "5",
  };
  const loaded = [];
  const loadAttachmentThumbnail = (target) => {
    loaded.push(target);
    return new Promise(() => {});
  };
  const show = (task) =>
    withI18n(
      createElement(
        TaskContent,
        contentProps(task, [], undefined, { loadAttachmentThumbnail }),
      ),
    );
  const executed = (ids, own) => {
    const task = taskView("1", ids);
    Object.assign(task.runs.at(-1), { submission: own, input });
    return show(task);
  };
  const address = (message) => ({
    kind: "messageAttachment",
    taskId: "1",
    message,
    index: 0,
  });
  const accepted = address({ kind: "submission", operationId: "op-image" });
  const waiting = { submission, input, state: "waiting", reason: null };

  const view = render(
    show({ ...taskView("1", ["5"]), inputSubmissions: [waiting] }),
  );
  // Becoming a Run moves nothing and asks for nothing again.
  view.rerender(executed(["5", "9"], submission));
  assert.deepEqual(loaded, [accepted]);
  // Without its anchor loaded the message moves, and its address does not.
  view.rerender(executed(["9"], submission));
  assert.deepEqual(loaded, [accepted, accepted]);
  // Only a Run nothing was accepted for is addressed by itself.
  view.rerender(executed(["12"], null));
  assert.deepEqual(loaded.at(-1), address({ kind: "run", runId: "12" }));
});

test("a security epoch keeps where a Task was read and the Run it is anchored in", () => {
  const ids = ["5", "6", "7", "8"];
  const manifest = ids.map((id) => manifestEntry(id));
  const { history } = historyRecorder();
  const memory = createTaskReadingMemory();
  memory.reading.set("1", {
    scrollTop: 40,
    followingLatest: false,
    anchor: { runId: "6", offset: 0 },
  });
  memory.toolDisclosure.set("1:6", new Set(["tool-1"]));
  const content = (task, key) =>
    withI18n(
      createElement(TaskContent, {
        key,
        memory,
        ...contentProps(task, task ? manifest : [], history),
      }),
    );
  const current = () =>
    screen
      .getAllByRole("option")
      .findIndex((option) => option.hasAttribute("data-current"));
  const view = render(content(taskView("1", ids), "epoch-1"));
  assert.equal(current(), 1);
  // As the App does on a newer epoch: the transcript is remounted and shows
  // nothing until the next snapshot, while the reading memory is kept.
  view.rerender(content(undefined, "epoch-2"));
  view.rerender(content(taskView("1", ids), "epoch-2"));
  assert.equal(memory.reading.get("1").anchor.runId, "6");
  assert.equal(memory.reading.get("1").followingLatest, false);
  assert.ok(memory.toolDisclosure.get("1:6").has("tool-1"));
  assert.equal(current(), 1);
});
