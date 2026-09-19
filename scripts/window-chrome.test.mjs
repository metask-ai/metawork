import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { JSDOM } from "jsdom";
import { act, createElement, StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createPortal } from "react-dom";
import ts from "typescript";
import {
  assertDisconnected,
  assertWindowChromeHandled,
  decodeWindowChromeEnvironment,
} from "../frontend/src/bridge/decode-contracts.ts";
import {
  bindWindowTitlebar,
  installWindowChromeBridge,
} from "../frontend/src/bridge/window-chrome.ts";
import { commands } from "../frontend/src/bridge/commands.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL("../src/bridge/window_chrome.fixture", import.meta.url),
    "utf8",
  ),
);
const environment = fixture.environment;
const ack = fixture.handled;
const titlebarSource = readFileSync(
  new URL("../frontend/src/components/ui/WindowTitlebar.tsx", import.meta.url),
  "utf8",
);
const titlebarModule = ts
  .transpileModule(titlebarSource, {
    compilerOptions: { module: ts.ModuleKind.ESNext, jsx: ts.JsxEmit.ReactJSX },
  })
  .outputText.replace(
    '"react/jsx-runtime"',
    JSON.stringify(import.meta.resolve("react/jsx-runtime")),
  );
const { WindowTitlebar } = await import(
  `data:text/javascript;base64,${Buffer.from(titlebarModule).toString("base64")}`
);
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
};
async function settle() {
  for (let i = 0; i < 12; i++) await Promise.resolve();
}

function setup(t, options = {}) {
  const dom = new JSDOM(
    '<!doctype html><html><body><header data-metawork-window-drag><span id="title">title</span><button data-metawork-window-control="toggle_maximize"><svg><path/></svg></button><button id="disabled" disabled>disabled</button></header><main>content</main><aside id="overlay">overlay</aside></body></html>',
    { pretendToBeVisual: true },
  );
  const previous = Object.fromEntries(
    ["window", "document", "Element"].map((k) => [k, globalThis[k]]),
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    Element: dom.window.Element,
  });
  const calls = [],
    listeners = new Map(),
    handlers = new Map();
  const nativeAdd = dom.window.document.addEventListener.bind(
    dom.window.document,
  );
  dom.window.document.addEventListener = (name, handler, ...args) => {
    assert.ok(
      !["pointerdown", "mousedown", "click"].includes(name),
      "no global window input listener",
    );
    nativeAdd(name, handler, ...args);
  };
  const currentEnvironment = { ...environment, ...options.environment };
  let refreshReply = () => currentEnvironment;
  const bridge = {
    invoke(command, payload) {
      calls.push({ command, payload });
      if (command === commands.windowChromeConnect)
        return options.connect?.promise ?? Promise.resolve(currentEnvironment);
      if (command === commands.windowChromeRefresh)
        return Promise.resolve().then(() => refreshReply());
      if (command === commands.windowChromeControl)
        return options.control?.promise ?? Promise.resolve(ack);
      if (command === commands.windowChromeGesture)
        return options.gesture?.promise ?? Promise.resolve(ack);
      if (command === commands.windowChromeDisconnect)
        return Promise.resolve({
          generation: payload.generation,
          detached: true,
        });
      throw new Error(command);
    },
    on(name, callback) {
      listeners.set(name, callback);
      return () => listeners.delete(name);
    },
  };
  dom.window.zero = bridge;
  const dispose = installWindowChromeBridge();
  const query = (selector) => dom.window.document.querySelector(selector);
  const header = query("header");
  const localAdd = header.addEventListener.bind(header);
  const localRemove = header.removeEventListener.bind(header);
  header.addEventListener = (name, handler, ...args) => {
    handlers.set(name, handler);
    localAdd(name, handler, ...args);
  };
  header.removeEventListener = (name, handler, ...args) => {
    if (handlers.get(name) === handler) handlers.delete(name);
    localRemove(name, handler, ...args);
  };
  const unbind =
    options.mount === false ? () => {} : bindWindowTitlebar(header);
  const pointer = (target, extra = {}, type = "mousedown") => {
    const path = [];
    for (let node = target; node; node = node.parentNode ?? node.host)
      path.push(node);
    const event = {
      isTrusted: true,
      isPrimary: true,
      button: 0,
      detail: 1,
      clientX: 200,
      clientY: 20,
      composedPath: () => path,
      cancelled: false,
      stopped: false,
      preventDefault() {
        this.cancelled = true;
      },
      stopImmediatePropagation() {
        this.stopped = true;
      },
      ...extra,
    };
    if (path.includes(header)) handlers.get(type)?.(event);
    return event;
  };
  const count = (command) =>
    calls.filter((call) => call.command === command).length;
  t.after(async () => {
    dispose();
    await settle();
    dom.window.close();
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  });
  return {
    dom,
    calls,
    listeners,
    handlers,
    dispose,
    unbind,
    query,
    pointer,
    count,
    refreshReply(value) {
      refreshReply = value;
    },
    get maximized() {
      return dom.window.document.documentElement.dataset
        .metaworkWindowMaximized;
    },
  };
}

test("shared Host wire fixture decodes strictly and action ack contains no state", () => {
  assert.deepEqual(decodeWindowChromeEnvironment(environment), environment);
  assertWindowChromeHandled(ack, "7");
  assertDisconnected(fixture.disconnected, "7");
  for (const malformed of [
    { ...environment, generation: "0" },
    { ...environment, insets: { ...environment.insets, top: -1 } },
    { ...environment, maximized: "false" },
    { ...environment, gestureMode: "unknown" },
    { ...environment, livePointerDrag: true },
  ])
    assert.throws(() => decodeWindowChromeEnvironment(malformed));
  for (const malformed of [
    environment,
    { ...ack, generation: "8" },
    { ...ack, handled: false },
    { ...ack, maximized: true },
  ])
    assert.throws(() => assertWindowChromeHandled(malformed, "7"));
});

test("Tauri Windows branch uses only exact detail 1/2, with no interruption history", async (t) => {
  const h = setup(t);
  await settle();
  const title = h.query("#title");
  for (const detail of [0, 1, 2, 3, 4]) {
    const event = h.pointer(title, { detail });
    assert.equal(event.cancelled, detail === 1 || detail === 2);
    assert.equal(event.stopped, event.cancelled);
  }
  h.pointer(title, { detail: 1 });
  h.pointer(h.query("#disabled"), { detail: 1 });
  h.pointer(title, { detail: 2 });
  h.pointer(title, { detail: 1 });
  h.dom.window.dispatchEvent(new h.dom.window.Event("blur"));
  h.pointer(title, { detail: 2 });
  h.pointer(title, { detail: 1 });
  h.pointer(h.query("#disabled"), { detail: 2 });
  h.pointer(title, { detail: 3 });
  assert.deepEqual(
    h.calls
      .filter((c) => c.command === commands.windowChromeGesture)
      .map((c) => c.payload.action),
    [
      "start_drag",
      "toggle_maximize",
      "start_drag",
      "toggle_maximize",
      "start_drag",
      "toggle_maximize",
      "start_drag",
    ],
  );
});

test("native press mode calls only SDK drag, with primary gating and unchanged defaults", async (t) => {
  const h = setup(t, {
    environment: { gestureMode: "native_press", rendererControls: false },
  });
  await settle();
  const title = h.query("#title");
  h.pointer(title, { detail: 2 });
  for (const detail of [0, 2]) {
    const event = h.pointer(title, { detail }, "pointerdown");
    assert.equal(event.cancelled, false);
  }
  h.pointer(title, { isPrimary: false }, "pointerdown");
  h.pointer(h.query("#disabled"), {}, "pointerdown");
  assert.deepEqual(
    h.calls
      .filter((c) => c.command === commands.windowChromeGesture)
      .map((c) => c.payload.action),
    ["start_drag", "start_drag"],
  );
});

test("pending connect, disabled mode, late mount and cleanup never replay input", async (t) => {
  const connect = deferred();
  const h = setup(t, { connect, mount: false });
  const title = h.query("#title"),
    header = h.query("header");
  const firstCleanup = bindWindowTitlebar(header);
  assert.equal(h.pointer(title).cancelled, false);
  connect.resolve({ ...environment, gestureMode: "disabled" });
  h.refreshReply(() => ({ ...environment, gestureMode: "disabled" }));
  await settle();
  assert.equal(h.pointer(title).cancelled, false);
  h.refreshReply(() => environment);
  h.listeners.get("resize")({});
  await settle();
  const secondCleanup = bindWindowTitlebar(header);
  firstCleanup(); // A stale ref cleanup must not unbind its replacement.
  firstCleanup();
  h.pointer(title);
  assert.equal(h.count(commands.windowChromeGesture), 1);
  secondCleanup();
  h.pointer(title);
  assert.equal(h.count(commands.windowChromeGesture), 1);
  bindWindowTitlebar(header);
  h.dispose();
  h.pointer(title);
  assert.equal(h.handlers.size, 0);
  assert.equal(h.count(commands.windowChromeGesture), 1);
});

test("native local listener is absent from business events and respects stopped DOM propagation", async (t) => {
  const h = setup(t);
  await settle();
  let visits = 0;
  // Count delivery at the real header; no synthetic trusted-event override here.
  h.query("header").addEventListener("mousedown", () => visits++);
  h.query("main").dispatchEvent(
    new h.dom.window.MouseEvent("mousedown", { bubbles: true }),
  );
  h.query("#overlay").dispatchEvent(
    new h.dom.window.MouseEvent("mousedown", { bubbles: true }),
  );
  const title = h.query("#title");
  title.addEventListener("mousedown", (e) => e.stopPropagation());
  title.dispatchEvent(
    new h.dom.window.MouseEvent("mousedown", { bubbles: true }),
  );
  assert.equal(visits, 0);
  assert.equal(h.count(commands.windowChromeGesture), 0);
});

test("real WindowTitlebar ref survives StrictMode, view switches and portals, then unbinds on unmount", async (t) => {
  const h = setup(t, { mount: false });
  await settle();
  const previousAct = globalThis.IS_REACT_ACT_ENVIRONMENT;
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const prototype = h.dom.window.HTMLElement.prototype;
  const add = prototype.addEventListener,
    remove = prototype.removeEventListener;
  const bound = new Map();
  prototype.addEventListener = function (name, handler, ...args) {
    if (
      this.tagName === "HEADER" &&
      ["mousedown", "pointerdown", "click"].includes(name)
    ) {
      const handlers = bound.get(this) ?? new Map();
      assert.equal(handlers.has(name), false, `duplicate ${name}`);
      handlers.set(name, handler);
      bound.set(this, handlers);
    }
    return add.call(this, name, handler, ...args);
  };
  prototype.removeEventListener = function (name, handler, ...args) {
    const handlers = bound.get(this);
    if (handlers?.get(name) === handler) handlers.delete(name);
    return remove.call(this, name, handler, ...args);
  };
  const root = createRoot(h.query("main"));
  try {
    for (const page of ["account", "workbench", "account"]) {
      await act(async () =>
        root.render(
          createElement(
            StrictMode,
            null,
            createElement(
              WindowTitlebar,
              { key: page, className: page, ref: bindWindowTitlebar },
              createElement("span", null, page),
              createPortal(
                createElement(
                  "button",
                  { "data-metawork-window-control": "close" },
                  "portal",
                ),
                h.query("#overlay"),
              ),
            ),
          ),
        ),
      );
      const header = h.query("main header"),
        title = header.querySelector("span");
      assert.equal(bound.get(header).size, 3);
      for (const [oldHeader, listeners] of bound)
        if (oldHeader !== header) assert.equal(listeners.size, 0);
      bound.get(header).get("mousedown")({
        isTrusted: true,
        button: 0,
        detail: 1,
        clientX: 200,
        clientY: 20,
        composedPath: () => [
          title,
          header,
          h.query("main"),
          h.dom.window.document.body,
        ],
        preventDefault() {},
        stopImmediatePropagation() {},
      });
      h.query("#overlay button").click(); // React ancestry is not native DOM ancestry.
      assert.equal(h.count(commands.windowChromeControl), 0);
    }
    assert.equal(h.count(commands.windowChromeGesture), 3);
    await act(async () => root.unmount());
    for (const listeners of bound.values()) assert.equal(listeners.size, 0);
  } finally {
    prototype.addEventListener = add;
    prototype.removeEventListener = remove;
    if (previousAct === undefined) delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    else globalThis.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
});

test("local input excludes controls, SVG, portals, inert and interactive ancestors without cancelling them", async (t) => {
  const h = setup(t);
  await settle();
  h.pointer(h.query("#title"));
  for (const selector of ["path", "#disabled", "main", "#overlay"])
    assert.equal(h.pointer(h.query(selector)).cancelled, false);
  const title = h.query("#title");
  for (const attrs of [
    { contenteditable: "" },
    { role: "button" },
    { tabindex: "-1" },
    { "data-metawork-window-drag-exclude": "" },
  ]) {
    for (const [key, value] of Object.entries(attrs))
      title.setAttribute(key, value);
    h.pointer(title);
    for (const key of Object.keys(attrs)) title.removeAttribute(key);
  }
  h.query("header").setAttribute("inert", "");
  h.pointer(title);
  h.query("header").removeAttribute("inert");
  // A shadow descendant still excludes its button through the composed path.
  const host = h.dom.window.document.createElement("span");
  h.query("header").append(host);
  const shadow = host.attachShadow({ mode: "open" });
  shadow.innerHTML = "<button><span>shadow control</span></button>";
  h.pointer(shadow.querySelector("span"));
  h.pointer(title, { isTrusted: false });
  h.pointer(title, { button: 2 });
  await settle();
  const pointers = h.calls.filter(
    (c) => c.command === commands.windowChromeGesture,
  );
  assert.deepEqual(pointers[0].payload, {
    generation: "7",
    action: "start_drag",
    x: 200,
    y: 20,
  });
  assert.equal(pointers.length, 1);
});

test("DOM changes and pointer classification do not scan or measure the document", async (t) => {
  const h = setup(t);
  await settle();
  const before = h.calls.length;
  h.query("main").append(h.dom.window.document.createElement("button"));
  await settle();
  assert.equal(h.calls.length, before);
  h.dom.window.document.querySelectorAll = () => {
    throw new Error("document scan");
  };
  const title = h.query("#title");
  title.getBoundingClientRect = () => {
    throw new Error("layout read");
  };
  h.pointer(title);
  await settle();
  assert.equal(h.count(commands.windowChromeGesture), 1);
});

test("SDK resize coalesces in-flight refresh and rejects stale state without reconnecting", async (t) => {
  const h = setup(t);
  await settle();
  const first = deferred(),
    second = deferred();
  let reads = 0;
  h.refreshReply(() => (++reads === 1 ? first.promise : second.promise));
  h.listeners.get("resize")({});
  await settle();
  h.listeners.get("resize")({});
  h.listeners.get("resize")({});
  first.resolve({ ...environment, maximized: true });
  await settle();
  assert.equal(h.maximized, "false");
  assert.equal(reads, 2);
  second.resolve(environment);
  await settle();
  assert.equal(h.count(commands.windowChromeConnect), 1);
  assert.equal(h.count(commands.windowChromeRefresh), 3);
});

test("control invalidates an older read and refreshes state even without resize", async (t) => {
  const control = deferred();
  const h = setup(t, { control });
  await settle();
  const oldRead = deferred();
  h.refreshReply(() => oldRead.promise);
  h.listeners.get("resize")({});
  await settle();
  h.query("path").dispatchEvent(
    new h.dom.window.MouseEvent("click", { bubbles: true }),
  );
  oldRead.resolve({ ...environment, maximized: true });
  await settle();
  assert.equal(h.maximized, "false");
  h.refreshReply(() => ({ ...environment, maximized: true }));
  control.resolve(ack);
  await settle();
  assert.equal(h.maximized, "true");
  assert.equal(h.query("[data-metawork-window-control]").disabled, false);
  assert.equal(h.query("#disabled").disabled, true);
});

test("refresh failure preserves controls and focus can refresh without reconnecting", async (t) => {
  const h = setup(t);
  await settle();
  h.refreshReply(() => {
    throw new Error("unavailable");
  });
  h.listeners.get("resize")({});
  await settle();
  assert.equal(h.maximized, "false");
  h.dom.window.dispatchEvent(new h.dom.window.Event("blur"));
  h.refreshReply(() => ({ ...environment, maximized: true }));
  h.dom.window.dispatchEvent(new h.dom.window.Event("focus"));
  await settle();
  assert.equal(h.maximized, "true");
  assert.equal(h.count(commands.windowChromeConnect), 1);
  assert.equal(h.count(commands.windowChromeGesture), 0);
});

test("pending gesture ack does not queue a second gesture or replay failed input", async (t) => {
  const pending = deferred();
  const h = setup(t, { gesture: pending });
  await settle();
  h.pointer(h.query("#title"));
  h.pointer(h.query("main"));
  h.pointer(h.query("#title"), { detail: 2 });
  assert.equal(h.count(commands.windowChromeGesture), 2);
  pending.reject(new Error("rejected"));
  await settle();
  assert.equal(h.count(commands.windowChromeGesture), 2);
  assert.equal(h.count(commands.windowChromeConnect), 1);
});

test("late connect after dispose only revokes its generation and cannot revive UI", async (t) => {
  const connect = deferred();
  const h = setup(t, { connect });
  h.dispose();
  h.dom.window.document.documentElement.dataset.metaworkWindowChrome =
    "replacement";
  connect.resolve(environment);
  await settle();
  assert.equal(h.count(commands.windowChromeDisconnect), 1);
  assert.equal(h.count(commands.windowChromeRefresh), 0);
  assert.equal(
    h.dom.window.document.documentElement.dataset.metaworkWindowChrome,
    "replacement",
  );
  assert.equal(h.listeners.size, 0);
});

test("pagehide disposes listeners once and late refresh cannot overwrite replacement UI", async (t) => {
  const h = setup(t);
  await settle();
  const pending = deferred();
  h.refreshReply(() => pending.promise);
  h.listeners.get("resize")({});
  await settle();
  h.dom.window.dispatchEvent(new h.dom.window.Event("pagehide"));
  h.dispose();
  h.dom.window.document.documentElement.dataset.metaworkWindowMaximized =
    "replacement";
  pending.resolve({ ...environment, maximized: true });
  await settle();
  assert.equal(h.maximized, "replacement");
  assert.equal(h.count(commands.windowChromeDisconnect), 1);
});

test("late control completion cannot enable replacement controls after cleanup", async (t) => {
  const control = deferred();
  const h = setup(t, { control });
  await settle();
  const button = h.query("[data-metawork-window-control]");
  button.click();
  assert.equal(button.disabled, true);
  h.dispose();
  assert.equal(button.disabled, false);
  button.disabled = true; // Owned by a replacement document installation.
  control.resolve(ack);
  await settle();
  assert.equal(button.disabled, true);
});
