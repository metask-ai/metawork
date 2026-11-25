import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement, Fragment } from "react";
import { createServer } from "vite";
import {
  deriveTaskReadingPlan,
  undisplayedOutputs,
} from "../frontend/src/features/tasks/assistant-output.ts";
import { formatFileSize } from "../frontend/src/i18n/formatters.ts";

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
  MutationObserver: dom.window.MutationObserver,
  CustomEvent: dom.window.CustomEvent,
  PointerEvent: dom.window.PointerEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  CSS: { escape: (value) => value },
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
if (!HTMLElement.prototype.scrollIntoView)
  HTMLElement.prototype.scrollIntoView = () => undefined;
dom.window.HTMLMediaElement.prototype.pause = () => undefined;

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
  await import("./renderer-testing-library.mjs");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { FileMenuProvider, FileMenuScope } = await vite.ssrLoadModule(
  "/src/components/FileMenu.tsx",
);
const { FileCard } = await vite.ssrLoadModule(
  "/src/features/tasks/FileCard.tsx",
);
const { ReplyImage } = await vite.ssrLoadModule(
  "/src/features/tasks/ReplyImage.tsx",
);
const { ReplyVideo } = await vite.ssrLoadModule(
  "/src/features/tasks/ReplyVideo.tsx",
);
const { RunFiles } = await vite.ssrLoadModule(
  "/src/features/tasks/RunFiles.tsx",
);
const { fileMenuOutcome, fileTargetShown, menuFile, menuFileTarget } =
  await vite.ssrLoadModule("/src/features/tasks/reply-files.ts");
const { FilePreviewView } = await vite.ssrLoadModule(
  "/src/features/task-panel/FilePreviewView.tsx",
);
const { TaskPanel } = await vite.ssrLoadModule(
  "/src/features/task-panel/TaskPanel.tsx",
);
const { taskPanelFileTarget } = await vite.ssrLoadModule(
  "/src/features/task-panel/task-panel-state.ts",
);
const { WorkspaceFileTree } = await vite.ssrLoadModule(
  "/src/features/workspaces/WorkspaceFileTree.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

const five = [
  "Open in default app",
  "Open folder",
  "Reference in conversation",
  "Copy path",
  "Save as…",
];
const reference = {
  kind: "reference",
  taskId: "3",
  runId: "7",
  fileReferenceId: "file-3-1-1-1",
};
const outputTarget = (outputId) => ({
  kind: "output",
  taskId: "3",
  runId: "7",
  outputId,
});
const output = (id, displayPath, values = {}) => ({
  id,
  displayPath,
  sizeBytes: "1",
  redacted: false,
  ...values,
});

function handlerFixture(values = {}) {
  const calls = [];
  return {
    calls,
    handler: {
      connected: true,
      canReference: true,
      perform: async (file, action, signal) => {
        calls.push({ target: menuFileTarget(file), action, signal });
        return null;
      },
      ...values,
    },
  };
}

function view(handler, ...children) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale: () => {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(
      FileMenuProvider,
      { value: handler },
      createElement(Fragment, null, ...children),
    ),
  );
}

function card(props = {}, scope = {}) {
  return createElement(
    FileMenuScope,
    scope,
    createElement(FileCard, {
      name: "report.docx",
      detail: ["2.3 MB"],
      menu: menuFile(reference, "results/report.docx"),
      ...props,
    }),
  );
}

async function openMenu(element, how = "pointer") {
  if (how === "pointer")
    await act(async () =>
      fireEvent.contextMenu(element, { clientX: 20, clientY: 30 }),
    );
  else
    await act(async () =>
      fireEvent.keyDown(
        element,
        how === "menu key"
          ? { key: "ContextMenu" }
          : { key: "F10", shiftKey: true },
      ),
    );
  return screen.findByRole("menu", { name: "File actions" });
}

async function closeMenu(menu) {
  await act(async () => fireEvent.keyDown(menu, { key: "Escape" }));
  await waitFor(() =>
    assert.ok(!screen.queryByRole("menu", { name: "File actions" })),
  );
}

const menuItems = (menu) =>
  within(menu)
    .getAllByRole("menuitem")
    .map((item) => ({
      name: item.textContent,
      disabled:
        item.getAttribute("aria-disabled") === "true" ||
        item.hasAttribute("data-disabled"),
    }));
const disabledItems = (menu) =>
  menuItems(menu)
    .filter((item) => item.disabled)
    .map((item) => item.name);

function observeVisibility() {
  const original = globalThis.IntersectionObserver;
  const observers = new Set();
  globalThis.IntersectionObserver = class {
    constructor(callback) {
      this.callback = callback;
      observers.add(this);
    }
    observe() {}
    disconnect() {
      observers.delete(this);
    }
  };
  return {
    set: (isIntersecting) =>
      act(async () => {
        for (const observer of [...observers])
          observer.callback([{ isIntersecting }]);
      }),
    restore: () => {
      if (original === undefined) delete globalThis.IntersectionObserver;
      else globalThis.IntersectionObserver = original;
    },
  };
}

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

test("a file menu offers the same five actions in the same order and opens without asking the Host", async () => {
  const { handler, calls } = handlerFixture();
  const loads = [];
  const load = async (target) => {
    loads.push(target);
    return { state: "missing", content: "", truncated: false, redacted: false };
  };
  render(
    view(
      handler,
      card(),
      createElement(ReplyImage, {
        target: reference,
        displayPath: "generated-images/a.png",
        enabled: true,
        load,
        onOpen: () => {},
      }),
      createElement(ReplyVideo, {
        target: reference,
        displayPath: "generated-videos/a.mp4",
        load,
      }),
    ),
  );
  await waitFor(() => assert.equal(loads.length, 2));
  for (const element of [
    screen.getByRole("group", { name: "report.docx, 2.3 MB" }),
    screen.getByRole("button", { name: "Preview generated-images/a.png" }),
    screen.getByRole("group", { name: "a.mp4" }),
  ])
    for (const how of ["pointer", "menu key", "Shift+F10"]) {
      assert.equal(element.getAttribute("aria-keyshortcuts"), "Shift+F10");
      const menu = await openMenu(element, how);
      assert.deepEqual(
        menuItems(menu).map((item) => item.name),
        five,
      );
      assert.deepEqual(disabledItems(menu), []);
      await closeMenu(menu);
    }
  // Opening a menu nine times moved nothing.
  assert.deepEqual(calls, []);
  assert.equal(loads.length, 2);
});

test("a menu greys out what cannot be done and never hides it", async () => {
  const cases = [
    { handler: { connected: false }, disabled: five },
    { handler: { canReference: false }, disabled: [five[2]] },
    { facts: { available: false }, disabled: five },
    // The Host said it does not open this file.
    { facts: { openable: false }, disabled: [five[0]] },
    // Nobody asked: the Host answers when it is chosen.
    { facts: {}, disabled: [] },
    { facts: { openable: true }, disabled: [] },
  ];
  for (const { handler: values, facts, disabled } of cases) {
    const { handler, calls } = handlerFixture(values);
    render(
      view(handler, card({ menu: menuFile(reference, "report.docx", facts) })),
    );
    const menu = await openMenu(
      screen.getByRole("group", { name: /report\.docx/ }),
    );
    assert.deepEqual(
      menuItems(menu).map((item) => item.name),
      five,
    );
    assert.deepEqual(disabledItems(menu), disabled);
    for (const item of within(menu).getAllByRole("menuitem"))
      if (disabled.includes(item.textContent))
        await act(async () => fireEvent.click(item));
    assert.deepEqual(calls, []);
    cleanup();
  }
});

test("a file without a menu opens none, and neither does one outside a connected interface", async () => {
  const { handler } = handlerFixture();
  render(view(handler, card({ menu: null })));
  const element = screen.getByRole("group", { name: /report\.docx/ });
  assert.equal(element.hasAttribute("aria-keyshortcuts"), false);
  fireEvent.contextMenu(element);
  fireEvent.keyDown(element, { key: "F10", shiftKey: true });
  assert.ok(!screen.queryByRole("menu"));
  cleanup();
  render(view(null, card()));
  fireEvent.contextMenu(screen.getByRole("group", { name: /report\.docx/ }));
  assert.ok(!screen.queryByRole("menu"));
});

test("the keyboard opens a menu on its first usable item and closing returns the focus", async () => {
  const { handler } = handlerFixture();
  render(
    view(
      handler,
      createElement(
        FileMenuScope,
        {},
        createElement(FileCard, { name: "first", detail: [], menu: null }),
        createElement(FileCard, {
          name: "report.docx",
          detail: [],
          menu: menuFile(reference, "a.bin", { openable: false }),
        }),
      ),
    ),
  );
  const element = screen.getByRole("group", { name: /report\.docx/ });
  for (const how of ["menu key", "Shift+F10"]) {
    element.focus();
    const event = new dom.window.KeyboardEvent("keydown", {
      key: how === "menu key" ? "ContextMenu" : "F10",
      shiftKey: how !== "menu key",
      bubbles: true,
      cancelable: true,
    });
    await act(async () => element.dispatchEvent(event));
    // Otherwise the platform would raise its own menu after this one.
    assert.equal(event.defaultPrevented, true);
    const menu = await screen.findByRole("menu", { name: "File actions" });
    await waitFor(() =>
      assert.equal(document.activeElement?.textContent, "Open folder"),
    );
    await closeMenu(menu);
    await waitFor(() => assert.ok(document.activeElement === element));
  }
  element.focus();
  const menu = await openMenu(element);
  await waitFor(() => assert.ok(menu.contains(document.activeElement)));
  assert.notEqual(document.activeElement?.getAttribute("role"), "menuitem");
  await closeMenu(menu);
  await waitFor(() => assert.ok(document.activeElement === element));
});

test("a menu whose file went away returns the focus to its region", async () => {
  const { handler } = handlerFixture();
  const mounted = render(view(handler, card()));
  const element = screen.getByRole("group", { name: /report\.docx/ });
  element.focus();
  const menu = await openMenu(element);
  mounted.rerender(
    view(handler, createElement(FileMenuScope, {}, "gone for now")),
  );
  await closeMenu(menu);
  await waitFor(() =>
    assert.ok(document.activeElement?.classList.contains("file-menu-scope")),
  );
});

test("every menu action names its file and reports where it was asked", async () => {
  const answers = [];
  const { handler, calls } = handlerFixture({
    perform: (file, action, signal) => {
      calls.push({ target: menuFileTarget(file), action, signal });
      return new Promise((resolve) => answers.push(resolve));
    },
  });
  render(view(handler, card()));
  const element = screen.getByRole("group", { name: /report\.docx/ });
  const actions = ["open", "reveal", "reference", "copy_path", "save"];
  for (const [index, action] of actions.entries()) {
    const menu = await openMenu(element);
    await act(async () =>
      fireEvent.click(
        within(menu).getByRole("menuitem", { name: five[index] }),
      ),
    );
    assert.deepEqual(calls.at(-1).target, reference);
    assert.equal(calls.at(-1).action, action);
    assert.equal(
      screen.getByRole("status").textContent,
      action === "save" ? "Preparing and saving file…" : "Checking file…",
    );
    // One operation at a time in a region.
    await waitFor(() => assert.ok(!screen.queryByRole("menu")));
    const busy = await openMenu(element);
    assert.deepEqual(disabledItems(busy), five);
    await closeMenu(busy);
    await act(async () =>
      answers.at(-1)(
        action === "open" ? null : { message: "outputs.state.restricted" },
      ),
    );
    if (action === "open") assert.ok(!screen.queryByRole("status"));
    else
      assert.equal(
        screen.getByRole("status").textContent,
        "This file is not currently accessible",
      );
    assert.ok(!screen.queryByRole("button", { name: "Cancel" }));
  }
  assert.equal(calls.length, actions.length);
});

test("a brief answer goes away by itself and a rejected action is a failure", async (ctx) => {
  ctx.mock.timers.enable({ apis: ["setTimeout"] });
  let outcome = { message: "outputs.state.path_copied", brief: true };
  const { handler } = handlerFixture({
    perform: async () => {
      if (!outcome) throw new Error("transport");
      return outcome;
    },
  });
  const mounted = render(view(handler, card()));
  const element = screen.getByRole("group", { name: /report\.docx/ });
  const choose = async (name) => {
    await act(async () => fireEvent.contextMenu(element));
    await act(async () =>
      fireEvent.click(screen.getByRole("menuitem", { name })),
    );
  };
  await choose("Copy path");
  assert.equal(screen.getByRole("status").textContent, "Path copied");
  await act(async () => ctx.mock.timers.tick(1199));
  assert.ok(screen.queryByRole("status"));
  await act(async () => ctx.mock.timers.tick(1));
  assert.ok(!screen.queryByRole("status"));
  outcome = null;
  await choose("Open folder");
  assert.equal(
    screen.getByRole("status").textContent,
    "File operation failed. Try again.",
  );
  await act(async () => ctx.mock.timers.tick(60_000));
  assert.ok(screen.queryByRole("status"));
  mounted.unmount();
});

test("cancelling waits for the Host, and a change of file, Task or connection drops what is in flight", async () => {
  const requests = [];
  const perform = (_file, action, signal) =>
    new Promise((resolve) => requests.push({ action, signal, resolve }));
  const { handler } = handlerFixture({ perform });
  const mounted = render(view(handler, card({}, { resetKey: "first" })));
  const choose = async (name) => {
    const menu = await openMenu(
      screen.getByRole("group", { name: /report\.docx/ }),
    );
    await act(async () =>
      fireEvent.click(within(menu).getByRole("menuitem", { name })),
    );
    await waitFor(() => assert.ok(!screen.queryByRole("menu")));
  };
  await choose("Save as…");
  await act(async () =>
    fireEvent.click(screen.getByRole("button", { name: "Cancel" })),
  );
  assert.equal(requests[0].signal.aborted, true);
  assert.equal(screen.getByRole("status").textContent, "Cancelling…");
  assert.equal(screen.getByRole("button", { name: "Cancel" }).disabled, true);
  // Too late: what happened is what is reported.
  await act(async () =>
    requests[0].resolve({ message: "outputs.state.saved" }),
  );
  assert.equal(screen.getByRole("status").textContent, "File saved");

  await choose("Open folder");
  mounted.rerender(view(handler, card({}, { resetKey: "second" })));
  assert.equal(requests[1].signal.aborted, true);
  assert.ok(!screen.queryByRole("status"));
  await act(async () =>
    requests[1].resolve({ message: "outputs.state.restricted" }),
  );
  assert.ok(!screen.queryByRole("status"));

  await choose("Copy path");
  mounted.rerender(
    view({ ...handler, connected: false }, card({}, { resetKey: "second" })),
  );
  assert.equal(requests[2].signal.aborted, true);
  await act(async () =>
    requests[2].resolve({ message: "outputs.state.path_copied" }),
  );
  assert.ok(!screen.queryByRole("status"));
  mounted.rerender(view(handler, card({}, { resetKey: "second" })));
  await choose("Copy path");
  mounted.unmount();
  assert.equal(requests[3].signal.aborted, true);
});

test("an action's answer is said only where it is needed", () => {
  for (const state of ["opened", "revealed"])
    assert.equal(fileMenuOutcome("open", state), null);
  assert.deepEqual(fileMenuOutcome("copy_path", "path_copied"), {
    message: "outputs.state.path_copied",
    brief: true,
  });
  // Nothing in a menu compares with a delivery.
  assert.deepEqual(fileMenuOutcome("save", "changed"), {
    message: "outputs.state.file_changed",
  });
  for (const state of [
    "saved",
    "copy_failed",
    "open_unsupported",
    "open_failed",
    "missing",
    "restricted",
    "busy",
    "stale_security",
    "edit_prepared",
    "edit_unavailable",
  ]) {
    const outcome = fileMenuOutcome("open", state);
    assert.deepEqual(outcome, { message: `outputs.state.${state}` });
    for (const locale of ["zh-CN", "en-US"])
      assert.notEqual(translate(locale, outcome.message), outcome.message);
  }
  assert.equal(
    translate("zh-CN", "outputs.state.open_unsupported"),
    "这种类型的文件不能在默认应用打开，请用“打开文件夹”。",
  );
  assert.deepEqual(
    ["open", "reveal", "edit", "copy_path", "save"].map((name) =>
      translate("zh-CN", `outputs.${name}`).replace("…", ""),
    ),
    ["在默认应用打开", "打开文件夹", "在对话中引用", "复制路径", "另存为"],
  );
});

test("a file is referenced only while the interface still shows it", () => {
  const task = {
    id: "3",
    workspaceId: "2",
    runs: [
      {
        id: "7",
        outputs: [output("a", "a.md"), output("h", "", { redacted: true })],
        fileReferences: {
          media: [],
          links: [{ id: "file-3-1-1-1", title: "", displayPath: "a.md" }],
          linksComplete: true,
        },
      },
    ],
    conversationOutputs: [{ ...output("old", "old.md"), runId: "5" }],
  };
  const workspaces = [{ id: "2", epoch: "4" }];
  const workspace = {
    kind: "workspace",
    taskId: "3",
    workspaceId: "2",
    workspaceEpoch: "4",
    path: "a.md",
  };
  const shown = (target) => fileTargetShown(task, workspaces, target);
  for (const target of [
    reference,
    outputTarget("a"),
    { ...outputTarget("old"), runId: "5" },
    workspace,
  ]) {
    assert.equal(shown(target), true);
    assert.equal(shown({ ...target, taskId: "4" }), false);
  }
  for (const target of [
    { ...reference, fileReferenceId: "file-3-1-1-2" },
    { ...reference, runId: "8" },
    outputTarget("h"),
    outputTarget("missing"),
    { ...outputTarget("old"), runId: "6" },
    { ...workspace, workspaceEpoch: "5" },
    { ...workspace, workspaceId: "9" },
  ])
    assert.equal(shown(target), false);
});

test("file sizes read as file managers show them", () => {
  for (const [bytes, text] of [
    ["0", "0 B"],
    ["1023", "1,023 B"],
    ["1024", "1.0 KB"],
    ["52941", "51.7 KB"],
    ["1048524", "1,023.9 KB"],
    ["1048575", "1.0 MB"],
    ["2411725", "2.3 MB"],
    ["5368709120", "5.0 GB"],
    ["18446744073709551615", "16,777,216.0 TB"],
  ])
    assert.equal(formatFileSize("en-US", bytes), text);
});

function imageResource() {
  let current = true;
  return {
    expire: () => {
      current = false;
    },
    image: {
      id: "image",
      mediaType: "image/jpeg",
      width: 40,
      height: 20,
      securityEpoch: "1",
      src: "data:image/jpeg;base64,AA==",
      valid: () => true,
      current: () => current,
      subscribe: () => () => {},
      beginDecode: async () => () => {},
    },
  };
}

// A browser's image and canvas, as far as encoding one needs them.
function installImageEncoding(t, { decode, png = "png", write }) {
  const images = dom.window.HTMLImageElement.prototype;
  const canvas = dom.window.HTMLCanvasElement.prototype;
  const drawn = [];
  const originals = {
    Image: globalThis.Image,
    ClipboardItem: globalThis.ClipboardItem,
    getContext: canvas.getContext,
    toBlob: canvas.toBlob,
  };
  const writes = [];
  Object.assign(globalThis, {
    Image: dom.window.Image,
    ClipboardItem: class {
      static supports = (type) => type === "image/png";
      constructor(items) {
        this.items = items;
      }
    },
  });
  Object.defineProperty(dom.window.navigator, "clipboard", {
    configurable: true,
    value: {
      write: (items) => {
        writes.push(...items);
        return (
          write?.() ??
          Promise.all(items.flatMap((item) => Object.values(item.items)))
        );
      },
    },
  });
  images.decode = function () {
    // The displayed one is in the document; the other is being copied.
    return this.isConnected ? Promise.resolve() : decode();
  };
  Object.defineProperties(images, {
    naturalWidth: { configurable: true, get: () => 400 },
    naturalHeight: { configurable: true, get: () => 200 },
  });
  canvas.getContext = function () {
    return {
      drawImage: (image) =>
        drawn.push({
          canvas: this,
          source: image.src,
          width: this.width,
          height: this.height,
        }),
    };
  };
  canvas.toBlob = function (done, type) {
    assert.equal(type, "image/png");
    done(png && new Blob([png], { type }));
  };
  t.after(() => {
    delete dom.window.navigator.clipboard;
    delete images.decode;
    delete images.naturalWidth;
    delete images.naturalHeight;
    canvas.getContext = originals.getContext;
    canvas.toBlob = originals.toBlob;
    globalThis.Image = originals.Image;
    if (originals.ClipboardItem === undefined) delete globalThis.ClipboardItem;
    else globalThis.ClipboardItem = originals.ClipboardItem;
  });
  return { drawn, writes };
}

async function shownImage(handler, resource) {
  const mounted = render(
    view(
      handler,
      createElement(ReplyImage, {
        target: reference,
        displayPath: "generated-images/a.jpg",
        enabled: true,
        load: async () => ({
          state: "ready",
          content: "",
          truncated: false,
          redacted: false,
          image: resource.image,
          release: () => {},
        }),
        onOpen: () => {},
      }),
    ),
  );
  await waitFor(() =>
    assert.ok(mounted.container.querySelector("img")?.getAttribute("src")),
  );
  return {
    button: screen.getByRole("button", { name: /^Preview/ }),
    decode: () =>
      act(async () => fireEvent.load(mounted.container.querySelector("img"))),
  };
}

test("copying an image is offered first, on an image alone, once it is shown", async (t) => {
  installImageEncoding(t, { decode: async () => {} });
  const { handler, calls } = handlerFixture();
  const { button, decode } = await shownImage(handler, imageResource());
  let menu = await openMenu(button);
  assert.deepEqual(
    menuItems(menu).map((item) => item.name),
    ["Copy image", ...five],
  );
  assert.deepEqual(disabledItems(menu), ["Copy image"]);
  await closeMenu(menu);
  await decode();
  menu = await openMenu(button);
  assert.deepEqual(disabledItems(menu), []);
  await closeMenu(menu);
  assert.deepEqual(calls, []);
  cleanup();

  // Nothing to copy from what is not shown.
  render(
    view(
      handler,
      createElement(ReplyImage, {
        target: reference,
        displayPath: "a.png",
        enabled: true,
        load: async () => ({
          state: "missing",
          content: "",
          truncated: false,
          redacted: false,
        }),
        onOpen: () => {},
      }),
      card(),
    ),
  );
  const failed = screen.getByRole("button", { name: /^Preview/ });
  menu = await openMenu(failed);
  assert.deepEqual(disabledItems(menu), ["Copy image"]);
  await closeMenu(menu);
  menu = await openMenu(screen.getByRole("group", { name: /report\.docx/ }));
  assert.deepEqual(
    menuItems(menu).map((item) => item.name),
    five,
  );
  await closeMenu(menu);
});

test("an image is copied within the click, in its own size and as PNG alone", async (t) => {
  let finishDecode;
  const { drawn, writes } = installImageEncoding(t, {
    decode: () =>
      new Promise((resolve) => {
        finishDecode = resolve;
      }),
  });
  const { handler, calls } = handlerFixture();
  const resource = imageResource();
  const { button, decode } = await shownImage(handler, resource);
  await decode();
  const menu = await openMenu(button);
  const item = within(menu).getByRole("menuitem", { name: "Copy image" });
  act(() => {
    fireEvent.click(item);
    assert.equal(writes.length, 1);
  });
  assert.deepEqual(Object.keys(writes[0].items), ["image/png"]);
  assert.equal(screen.getByRole("status").textContent, "Copying image…");
  await act(async () => {});
  await act(async () => finishDecode());
  assert.equal(screen.getByRole("status").textContent, "Image copied");
  const blob = await writes[0].items["image/png"];
  assert.equal(blob.type, "image/png");
  assert.equal(drawn.length, 1);
  assert.deepEqual(
    [drawn[0].source, drawn[0].width, drawn[0].height],
    [resource.image.src, 400, 200],
  );
  // Its pixels are given back as soon as they are encoded.
  assert.deepEqual([drawn[0].canvas.width, drawn[0].canvas.height], [0, 0]);
  // Neither the Host nor its path took part.
  assert.deepEqual(calls, []);
});

test("an image that cannot be copied says why and writes nothing", async (t) => {
  const failed = "Could not copy. Try again.";
  for (const { setup, meanwhile, message } of [
    { setup: { decode: async () => Promise.reject(Error()) }, message: failed },
    { setup: { decode: async () => {}, png: null }, message: failed },
    {
      setup: {
        decode: async () => {},
        write: () => Promise.reject(new Error("refused")),
      },
      message: failed,
    },
    {
      setup: {},
      meanwhile: (resource) => resource.expire(),
      message: "Authorization changed. Check again.",
    },
    {
      setup: {},
      meanwhile: () =>
        fireEvent.click(screen.getByRole("button", { name: "Cancel" })),
      message: "Operation cancelled",
    },
  ]) {
    await t.test(message, async (t) => {
      let finishDecode;
      const { writes } = installImageEncoding(t, {
        decode: () =>
          new Promise((resolve) => {
            finishDecode = resolve;
          }),
        ...setup,
      });
      const { handler } = handlerFixture();
      const resource = imageResource();
      const { button, decode } = await shownImage(handler, resource);
      await decode();
      const menu = await openMenu(button);
      const settled = [];
      await act(async () => {
        fireEvent.click(
          within(menu).getByRole("menuitem", { name: "Copy image" }),
        );
        writes[0].items["image/png"].then(
          () => settled.push("written"),
          () => settled.push("refused"),
        );
      });
      if (meanwhile) {
        await act(async () => meanwhile(resource));
        await act(async () => finishDecode());
      }
      assert.equal(screen.getByRole("status").textContent, message);
      if (!setup.write) assert.deepEqual(settled, ["refused"]);
      cleanup();
    });
  }
});

const described = {
  image: {
    state: "ready",
    file: { kind: "image", sizeBytes: "10", width: 40, height: 20 },
  },
  video: { state: "ready", file: { kind: "video", sizeBytes: "20" } },
  text: {
    state: "ready",
    file: { kind: "file", sizeBytes: "1536", previewable: true },
  },
  opaque: {
    state: "ready",
    file: { kind: "file", sizeBytes: "2411725", previewable: false },
  },
};

function filesView(handler, props) {
  return view(
    handler,
    createElement(RunFiles, {
      taskId: "3",
      runId: "7",
      enabled: true,
      load: async () => ({
        state: "missing",
        content: "",
        truncated: false,
        redacted: false,
      }),
      onOpen: () => {},
      ...props,
    }),
  );
}

test("a reply asks about its files one by one and arranges them once, by what they are", async () => {
  const { handler } = handlerFixture();
  const asked = [];
  const describe = (target, options) =>
    new Promise((resolve) => asked.push({ target, options, resolve }));
  const outputs = [
    output("text", "results/notes.md"),
    output("video", "results/clip.txt"),
    output("opaque", "results/report.docx", { open: "default_app" }),
    output("image", "results/chart.txt"),
  ];
  const layouts = new Set();
  const mounted = render(filesView(handler, { outputs, describe }));
  const layout = () =>
    [
      ...mounted.container.querySelectorAll(
        ".reply-image, .reply-video, .file-card",
      ),
    ]
      .map((element) =>
        element.matches(".file-card")
          ? `${element.dataset.pending ? "pending" : "card"}:${element.querySelector(".file-card-name").textContent}`
          : element.className.split(" ")[0],
      )
      .join(" ");
  for (const index of outputs.keys()) {
    await waitFor(() => assert.equal(asked.length, index + 1));
    layouts.add(layout());
    // Nothing to activate, and nothing to focus, before it is known.
    assert.ok(!mounted.container.querySelector("button, [tabindex='0']"));
    assert.equal(
      mounted.container.querySelectorAll('li[aria-busy="true"]').length,
      outputs.length,
    );
    assert.deepEqual(asked[index].target, outputTarget(outputs[index].id));
    assert.equal(asked[index].options.priority, "prefetch");
    await act(async () => asked[index].resolve(described[outputs[index].id]));
  }
  assert.equal(
    layout(),
    "reply-image reply-video card:notes.md card:report.docx",
  );
  assert.deepEqual(
    [...layouts],
    ["pending:notes.md pending:clip.txt pending:report.docx pending:chart.txt"],
  );
  assert.ok(!mounted.container.querySelector('li[aria-busy="true"]'));
  // The place an image takes is its own before it is loaded.
  const image = mounted.container.querySelector(".reply-image-open");
  assert.equal(image.style.width, "40px");
  assert.match(image.style.aspectRatio, /40 ?\/ ?20/);
});

test("a reply keeps its files while they cannot be read and asks again when one is delivered again", async () => {
  const { handler } = handlerFixture();
  const asked = [];
  const describe = async (target) => {
    asked.push(target.outputId);
    return described[target.outputId];
  };
  const outputs = [output("video", "clip.mp4"), output("text", "notes.md")];
  const mounted = render(filesView(handler, { outputs, describe }));
  await waitFor(() =>
    assert.ok(mounted.container.querySelector(".reply-video")),
  );
  assert.deepEqual(asked, ["video", "text"]);
  mounted.rerender(filesView(handler, { outputs, describe, enabled: false }));
  // No player without a connection, but still the file.
  assert.ok(!mounted.container.querySelector(".reply-video"));
  assert.ok(screen.getByRole("group", { name: "clip.mp4, 20 B" }));
  mounted.rerender(filesView(handler, { outputs, describe }));
  await waitFor(() =>
    assert.ok(mounted.container.querySelector(".reply-video")),
  );
  await waitFor(() => assert.equal(asked.length, 4));
  // The same files again are the same question; another delivery is not.
  mounted.rerender(
    filesView(handler, {
      outputs: outputs.map((item) => ({ ...item })),
      describe,
    }),
  );
  await act(async () => {});
  assert.equal(asked.length, 4);
  mounted.rerender(
    filesView(handler, {
      outputs: [outputs[0], { ...outputs[1], sizeBytes: "2" }],
      describe,
    }),
  );
  await waitFor(() => assert.equal(asked.length, 6));
});

test("a card that can be previewed is a button, and one that cannot does nothing but keep its menu", async () => {
  const { handler, calls } = handlerFixture();
  const opened = [];
  const asked = [];
  const outputs = [
    output("text", "results/notes.md", { updated: true }),
    output("opaque", "results/report.docx"),
  ];
  const props = {
    outputs,
    describe: async (target) => {
      asked.push(target);
      return described[target.outputId];
    },
    load: async () => assert.fail("a card loads nothing"),
    onOpen: (path, opener) => opened.push({ path, opener }),
  };
  const mounted = render(filesView(handler, props));
  const button = await screen.findByRole("button", {
    name: "Preview notes.md, 1.5 KB, File changed during this turn",
  });
  assert.equal(button.hasAttribute("aria-haspopup"), false);
  fireEvent.click(button);
  assert.deepEqual(opened, [{ path: "results/notes.md", opener: button }]);

  const still = screen.getByRole("group", { name: "report.docx, 2.3 MB" });
  assert.equal(still.tagName, "DIV");
  assert.equal(still.tabIndex, 0);
  assert.doesNotMatch(still.getAttribute("aria-label"), /Preview/);
  assert.ok(!still.closest("button"));
  const before = asked.length;
  const user = userEvent.setup({ document: dom.window.document });
  still.focus();
  await user.click(still);
  await user.keyboard("{Enter}");
  await user.keyboard(" ");
  assert.equal(opened.length, 1);
  assert.equal(asked.length, before);
  assert.deepEqual(calls, []);
  const menu = await openMenu(still, "Shift+F10");
  // It was delivered and the Host opens no such file.
  assert.deepEqual(disabledItems(menu), [five[0]]);
  await closeMenu(menu);

  // Nothing is previewed while the Workspace cannot be browsed.
  mounted.rerender(filesView(handler, { ...props, onOpen: undefined }));
  assert.ok(!screen.queryByRole("button", { name: /Preview/ }));
  assert.ok(
    screen.getByRole("group", {
      name: "notes.md, 1.5 KB, File changed during this turn",
    }),
  );
});

test("a file that cannot be reached says why in place of its size and greys its menu", async () => {
  const { handler } = handlerFixture();
  const states = {
    missing: "File is no longer available",
    restricted: "This file is not currently accessible",
    changing: "The file is changing",
    error: "This file cannot be read right now",
    thrown: "This file cannot be read right now",
  };
  const outputs = Object.keys(states).map((state) =>
    output(state, `${state}.md`, { open: "default_app" }),
  );
  render(
    filesView(handler, {
      outputs: [...outputs, output("hidden", "", { redacted: true })],
      describe: async (target) => {
        if (target.outputId === "thrown") throw new Error("transport");
        return { state: target.outputId, file: null };
      },
    }),
  );
  for (const [state, reason] of Object.entries(states)) {
    const element = await screen.findByRole("group", {
      name: `${state}.md, ${reason}`,
    });
    const menu = await openMenu(element);
    assert.deepEqual(disabledItems(menu), five);
    await closeMenu(menu);
  }
  // A hidden path has no name to show and no file to act on.
  const hidden = screen.getByRole("group", { name: "File path hidden" });
  fireEvent.contextMenu(hidden);
  assert.ok(!screen.queryByRole("menu"));
  assert.equal(hidden.hasAttribute("aria-keyshortcuts"), false);
});

test("a reply asks again when it comes back into view and keeps its arrangement until it knows better", async () => {
  const visibility = observeVisibility();
  try {
    const { handler } = handlerFixture();
    const asked = [];
    const describe = (target, options) =>
      new Promise((resolve) => asked.push({ target, options, resolve }));
    const outputs = [output("text", "notes.md"), output("opaque", "a.docx")];
    const mounted = render(filesView(handler, { outputs, describe }));
    assert.equal(asked.length, 0);
    await visibility.set(true);
    await act(async () => asked[0].resolve(described.text));
    // Leaving drops what is in flight, and what was not yet complete.
    await visibility.set(false);
    assert.equal(asked[1].options.signal.aborted, true);
    await act(async () => asked[1].resolve(described.opaque));
    assert.equal(
      mounted.container.querySelectorAll('[data-pending="true"]').length,
      2,
    );
    await visibility.set(true);
    await act(async () => asked[2].resolve(described.text));
    await act(async () => asked[3].resolve(described.opaque));
    const button = screen.getByRole("button", {
      name: "Preview notes.md, 1.5 KB",
    });
    button.focus();
    await visibility.set(false);
    await visibility.set(true);
    assert.equal(asked.length, 5);
    assert.ok(
      screen.getByRole("button", { name: "Preview notes.md, 1.5 KB" }) ===
        button,
    );
    // It is not text any more: the focus stays on the card it was on.
    await act(async () => asked[4].resolve(described.opaque));
    await act(async () => asked[5].resolve(described.opaque));
    assert.ok(!screen.queryByRole("button", { name: /Preview/ }));
    assert.ok(
      document.activeElement ===
        screen.getByRole("group", { name: "notes.md, 2.3 MB" }),
    );
  } finally {
    visibility.restore();
  }
});

test("an image or video that is not shown in place becomes a card of the same file", async () => {
  const { handler } = handlerFixture();
  const empty = { content: "", truncated: false, redacted: false };
  for (const result of [
    { ...empty, state: "unsupported" },
    { ...empty, state: "unsupported", reason: "image_limit" },
    { ...empty, state: "unsupported", reason: "animated_image" },
    // What it holds now is text: it is still not something to preview here.
    { ...empty, state: "ready", content: "text" },
  ])
    for (const [component, path] of [
      [ReplyImage, "generated-images/a.png"],
      [ReplyVideo, "generated-videos/a.mp4"],
    ]) {
      const asked = [];
      const loads = [];
      let released = 0;
      render(
        view(
          handler,
          createElement(component, {
            target: reference,
            displayPath: path,
            enabled: true,
            load: async (target) => {
              loads.push(target);
              return { ...result, release: () => released++ };
            },
            describe: async (target) => {
              asked.push(target);
              return described.opaque;
            },
            onOpen: () => assert.fail("a card that cannot be previewed"),
          }),
        ),
      );
      const name = path.split("/").at(-1);
      const element = await screen.findByRole("group", {
        name: `${name}, 2.3 MB`,
      });
      assert.deepEqual(asked, [reference]);
      assert.equal(loads.length, 1);
      assert.equal(released, 1);
      fireEvent.click(element);
      const menu = await openMenu(element);
      // A name the Host wrote opens; nobody has to be asked first.
      assert.deepEqual(disabledItems(menu), []);
      await closeMenu(menu);
      cleanup();
    }
  for (const result of [
    { ...empty, state: "missing" },
    { ...empty, state: "restricted" },
    { ...empty, state: "changing" },
    { ...empty, state: "error", reason: "capacity" },
  ]) {
    const mounted = render(
      view(
        handler,
        createElement(ReplyImage, {
          target: reference,
          displayPath: "a.png",
          enabled: true,
          load: async () => result,
          describe: async () => assert.fail("its kind did not change"),
          onOpen: () => {},
        }),
      ),
    );
    await waitFor(() =>
      assert.doesNotMatch(mounted.container.textContent, /Loading preview/),
    );
    assert.ok(!mounted.container.querySelector(".file-card"));
    assert.ok(mounted.container.querySelector(".reply-image"));
    cleanup();
  }
});

test("a video the system cannot play keeps its place and its menu", async () => {
  const { handler } = handlerFixture();
  const mounted = render(
    view(
      handler,
      createElement(ReplyVideo, {
        target: outputTarget("video"),
        displayPath: "results/clip.mp4",
        openable: true,
        load: async () => ({
          state: "ready",
          content: "",
          truncated: false,
          redacted: false,
          video: {
            src: "blob:video",
            valid: () => true,
            subscribe: () => () => {},
          },
          release: () => {},
        }),
        describe: async () => assert.fail("it is still a video"),
      }),
    ),
  );
  const group = screen.getByRole("group", { name: "clip.mp4" });
  assert.equal(group.tabIndex, 0);
  await waitFor(() => assert.ok(mounted.container.querySelector("video")));
  await act(async () =>
    fireEvent.loadedData(mounted.container.querySelector("video")),
  );
  // Its own controls hold the focus, and the menu opens from inside them too.
  assert.equal(group.tabIndex, -1);
  const menu = await openMenu(mounted.container.querySelector("video"));
  assert.deepEqual(disabledItems(menu), []);
  await closeMenu(menu);
  await act(async () =>
    fireEvent.error(mounted.container.querySelector("video")),
  );
  assert.ok(!mounted.container.querySelector("video"));
  assert.ok(!mounted.container.querySelector(".file-card"));
  assert.equal(group.tabIndex, 0);
  assert.equal(
    mounted.container.querySelector(".reply-video [role=status]").textContent,
    translate("en-US", "video_preview.failed"),
  );
  await closeMenu(await openMenu(group, "menu key"));
});

const workspaceTarget = (path) => ({
  kind: "workspace",
  taskId: "3",
  workspaceId: "1",
  workspaceEpoch: "2",
  path,
});

test("a file in the tree opens the same menu and a directory opens none", async () => {
  const { handler, calls } = handlerFixture();
  const opened = [];
  const toggled = [];
  const props = {
    tree: {
      directories: {
        "": {
          state: "ready",
          entries: [
            { name: "docs", kind: "directory" },
            { name: "a.md", kind: "file" },
            { name: "b.md", kind: "file" },
          ],
          truncated: false,
          redacted: false,
        },
      },
      expanded: new Set(),
      capacity: false,
      request() {},
      refresh() {},
      toggle: (path) => toggled.push(path),
    },
    available: true,
    selectedPath: null,
    onOpen: (path) => opened.push(path),
    fileOf: (path) => menuFile(workspaceTarget(path), path),
  };
  const mounted = render(
    view(handler, createElement(WorkspaceFileTree, props)),
  );
  const entry = (name) => screen.getByRole("treeitem", { name });
  for (const how of ["pointer", "menu key", "Shift+F10"]) {
    entry("b.md").focus();
    const menu = await openMenu(entry("b.md"), how);
    assert.deepEqual(
      menuItems(menu).map((item) => item.name),
      five,
    );
    assert.deepEqual(disabledItems(menu), []);
    await closeMenu(menu);
    await waitFor(() => assert.ok(document.activeElement === entry("b.md")));
  }
  fireEvent.contextMenu(entry("docs"));
  fireEvent.keyDown(entry("docs"), { key: "F10", shiftKey: true });
  assert.ok(!screen.queryByRole("menu"));
  assert.equal(entry("docs").hasAttribute("aria-keyshortcuts"), false);

  const menu = await openMenu(entry("a.md"));
  await act(async () =>
    fireEvent.click(within(menu).getByRole("menuitem", { name: "Copy path" })),
  );
  assert.deepEqual(
    calls.map(({ target, action }) => [target, action]),
    [[workspaceTarget("a.md"), "copy_path"]],
  );
  await waitFor(() => assert.ok(!screen.queryByRole("menu")));
  // The keys of the tree are the ones it had.
  entry("a.md").focus();
  await act(async () => fireEvent.keyDown(entry("a.md"), { key: "ArrowDown" }));
  assert.ok(document.activeElement === entry("b.md"));
  await act(async () => fireEvent.keyDown(entry("b.md"), { key: "Home" }));
  assert.ok(document.activeElement === entry("docs"));
  fireEvent.click(entry("a.md"));
  fireEvent.click(entry("docs"));
  assert.deepEqual([opened, toggled], [["a.md"], ["docs"]]);
  // Without a Workspace to act in there is nothing to open.
  mounted.rerender(
    view(
      handler,
      createElement(WorkspaceFileTree, { ...props, fileOf: () => null }),
    ),
  );
  fireEvent.contextMenu(entry("a.md"));
  assert.ok(!screen.queryByRole("menu"));
});

const panelTabs = [
  {
    kind: "preview",
    tabId: "preview",
    taskId: "3",
    runId: "7",
    referenceId: "file-3-1-1-1",
    title: "a.md",
    displayPath: "a.md",
  },
  {
    tabId: "workspace",
    title: "b.md",
    displayPath: "b.md",
    ...workspaceTarget("b.md"),
  },
  { kind: "review", tabId: "review", taskId: "3", runId: "7" },
  { kind: "outputs", tabId: "outputs", taskId: "3" },
];
const panelFile = (tab) => {
  const target = taskPanelFileTarget(tab);
  return target && menuFile(target, tab.displayPath);
};
const panel = (props = {}, children = null) =>
  createElement(
    TaskPanel,
    {
      title: "Panel",
      fileTreeOpen: false,
      onToggleFileTree() {},
      tabs: panelTabs,
      activeTabId: "preview",
      fileOf: panelFile,
      attention: null,
      onSelectTab() {},
      onCloseTab() {},
      onClose() {},
      ...props,
    },
    children,
  );

test("the tab of a file opens its menu and a tab of no one file opens none", async () => {
  const { handler, calls } = handlerFixture();
  const selected = [];
  render(
    view(handler, panel({ onSelectTab: (tabId) => selected.push(tabId) })),
  );
  const tab = (name) => screen.getByRole("tab", { name });
  const targets = [];
  for (const name of ["a.md", "b.md"]) {
    const menu = await openMenu(tab(name), "Shift+F10");
    assert.deepEqual(
      menuItems(menu).map((item) => item.name),
      five,
    );
    await act(async () =>
      fireEvent.click(within(menu).getByRole("menuitem", { name: "Save as…" })),
    );
    await waitFor(() => assert.ok(!screen.queryByRole("menu")));
    targets.push(calls.at(-1).target);
  }
  assert.deepEqual(targets, [reference, workspaceTarget("b.md")]);
  for (const name of ["Review changes", "Delivered files"]) {
    fireEvent.contextMenu(tab(name));
    assert.ok(!screen.queryByRole("menu"));
    assert.equal(tab(name).hasAttribute("aria-keyshortcuts"), false);
  }
  // Opening a menu selects nothing, and the keys of the tabs still move.
  assert.deepEqual(selected, []);
  tab("a.md").focus();
  await act(async () => fireEvent.keyDown(tab("a.md"), { key: "ArrowRight" }));
  assert.ok(document.activeElement === tab("b.md"));
});

test("what a panel says about a file goes with its tab, and what it is doing does not", async () => {
  const requests = [];
  const { handler } = handlerFixture({
    perform: (_file, _action, signal) =>
      new Promise((resolve) => requests.push({ signal, resolve })),
  });
  const mounted = render(view(handler, panel()));
  const choose = async (name) => {
    const menu = await openMenu(screen.getByRole("tab", { name: "a.md" }));
    await act(async () =>
      fireEvent.click(within(menu).getByRole("menuitem", { name })),
    );
    await waitFor(() => assert.ok(!screen.queryByRole("menu")));
  };
  await choose("Save as…");
  mounted.rerender(view(handler, panel({ activeTabId: "workspace" })));
  assert.equal(requests[0].signal.aborted, false);
  await act(async () =>
    requests[0].resolve({ message: "outputs.state.saved" }),
  );
  assert.equal(screen.getByRole("status").textContent, "File saved");
  mounted.rerender(view(handler, panel({ activeTabId: "preview" })));
  assert.ok(!screen.queryByRole("status"));
  await choose("Copy path");
  mounted.rerender(
    view(
      handler,
      panel({ tabs: panelTabs.map((tab) => ({ ...tab, taskId: "4" })) }),
    ),
  );
  assert.equal(requests[1].signal.aborted, true);
  await act(async () =>
    requests[1].resolve({ message: "outputs.state.path_copied" }),
  );
  assert.ok(!screen.queryByRole("status"));
});

test("an image in the panel opens the menu of its tab with the image to copy, and text opens none", async (t) => {
  const { writes } = installImageEncoding(t, { decode: async () => {} });
  const { handler, calls } = handlerFixture();
  const content = (preview) =>
    createElement(FilePreviewView, {
      state: {
        selected: {
          id: reference.fileReferenceId,
          title: "",
          displayPath: "a.png",
        },
        phase: "settled",
        preview: {
          state: "ready",
          content: "",
          truncated: false,
          redacted: false,
          ...preview,
        },
      },
      file: menuFile(reference, "a.png"),
      mode: "preview",
      scrollTop: 0,
      onModeChange() {},
      onScrollTopChange() {},
      onRetry() {},
      webLink: { failedLabel: "", onOpen: async () => true },
    });
  const mounted = render(
    view(handler, panel({}, content({ image: imageResource().image }))),
  );
  const group = screen.getByRole("group", { name: "a.png" });
  assert.equal(group.tabIndex, 0);
  let menu = await openMenu(group, "menu key");
  assert.deepEqual(disabledItems(menu), ["Copy image"]);
  await closeMenu(menu);
  await waitFor(() =>
    assert.ok(mounted.container.querySelector("img")?.getAttribute("src")),
  );
  await act(async () => fireEvent.load(mounted.container.querySelector("img")));
  menu = await openMenu(group);
  assert.deepEqual(
    menuItems(menu).map((item) => item.name),
    ["Copy image", ...five],
  );
  assert.deepEqual(disabledItems(menu), []);
  await act(async () =>
    fireEvent.click(within(menu).getByRole("menuitem", { name: "Copy image" })),
  );
  assert.equal(writes.length, 1);
  await waitFor(() =>
    assert.equal(screen.getByRole("status").textContent, "Image copied"),
  );
  assert.deepEqual(calls, []);
  await waitFor(() => assert.ok(!screen.queryByRole("menu")));

  // The secondary button stays with the text it selects.
  mounted.rerender(
    view(handler, panel({}, content({ content: "plain text" }))),
  );
  fireEvent.contextMenu(screen.getByText("plain text"));
  assert.ok(!screen.queryByRole("menu"));
});

test("a reply shows each of its files once", () => {
  const media = (kind, displayPath) => ({
    kind,
    identity: `9:${kind}:${displayPath}`,
    reference: { id: displayPath, title: "", displayPath },
  });
  const text = {
    kind: "assistant",
    identity: "9:output:0",
    parts: [
      {
        identity: "9:output:0",
        ordinal: 0,
        content: "See [notes](notes.md) and [clip](other/clip.mp4).",
        disposition: "final",
      },
    ],
    redacted: false,
  };
  const entries = [text, media("image", "a.png"), media("video", "clip.mp4")];
  const shown = (outputs, flow = entries) =>
    undisplayedOutputs(outputs, flow).map((item) => item.id);
  // An image or a video of this reply is the delivery itself.
  assert.deepEqual(shown([output("1", "a.png"), output("2", "clip.mp4")]), []);
  // A link is a mention: the card stays.
  assert.deepEqual(shown([output("3", "notes.md")]), ["3"]);
  assert.deepEqual(shown([output("4", "other/clip.mp4")]), ["4"]);
  // A hidden path matches nothing, not even another hidden path.
  assert.deepEqual(
    shown([output("5", "", { redacted: true })], [media("image", "")]),
    ["5"],
  );
  // Another reply showing it does not count.
  assert.deepEqual(shown([output("1", "a.png")], [text]), ["1"]);
  // Nor does a video that has no place in the reading flow.
  assert.deepEqual(shown([output("2", "clip.mp4")], [text]), ["2"]);
  assert.deepEqual(shown([], entries), []);
});

test("the files of a reply follow its last output and come before what supplements it", () => {
  const run = (values = {}) => ({
    id: "9",
    phase: "completed",
    terminal: { outcome: "completed", cause: null, feedback: {} },
    activity: null,
    input: { kind: "text", text: "", redacted: false },
    submission: null,
    additionalInputs: [],
    output: {
      commentary: ["Working"],
      response: "Done",
      responseKind: "final",
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    fileReferences: {
      media: [
        {
          id: "image",
          title: "",
          displayPath: "a.png",
          generatedImage: true,
          presentationAnchor: { afterOutputCount: 1, presentationOrder: "1" },
        },
        // An old video without an anchor has no place in the flow.
        {
          id: "video",
          title: "",
          displayPath: "old.mp4",
          generatedVideo: true,
        },
      ],
      links: [],
      linksComplete: true,
    },
    toolLog: { count: "0", revision: "0", runningName: null },
    fileChanges: null,
    outputs: [
      output("1", "a.png"),
      output("2", "notes.md"),
      output("3", "old.mp4"),
    ],
    ...values,
  });
  const plan = (value) =>
    deriveTaskReadingPlan({ id: "3", runs: [value], inputSubmissions: [] })
      .runs[0].entries;
  const entries = plan(run());
  assert.deepEqual(
    entries.map((entry) => entry.kind),
    ["assistant", "image", "files", "supplement"],
  );
  assert.deepEqual(
    entries.find((entry) => entry.kind === "files").outputs.map((o) => o.id),
    ["2", "3"],
  );
  assert.equal(
    entries.find((entry) => entry.kind === "files").identity,
    "9:files",
  );
  // Nothing left to show is no entry at all.
  assert.equal(
    plan(run({ outputs: [output("1", "a.png")] })).some(
      (entry) => entry.kind === "files",
    ),
    false,
  );
});
