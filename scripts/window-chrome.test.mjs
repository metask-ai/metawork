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
    '<!doctype html><html><body><header data-native-window-drag><span id="title">title</span><button data-metawork-window-control="toggle_maximize"><svg><path/></svg></button><button id="disabled" disabled>disabled</button></header><main>content</main><aside id="overlay">overlay</aside></body></html>',
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
    { ...environment, gestureMode: "browser_mouse" },
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
      assert.deepEqual([...bound.get(header).keys()], ["click"]);
      assert.ok(header.hasAttribute("data-native-window-drag"));
      for (const [oldHeader, listeners] of bound)
        if (oldHeader !== header) assert.equal(listeners.size, 0);
      h.query("#overlay button").click(); // React ancestry is not native DOM ancestry.
      assert.equal(h.count(commands.windowChromeControl), 0);
    }
    assert.equal(
      h.calls.some((c) => c.command.endsWith(".gesture")),
      false,
    );
    await act(async () => root.unmount());
    for (const listeners of bound.values()) assert.equal(listeners.size, 0);
  } finally {
    prototype.addEventListener = add;
    prototype.removeEventListener = remove;
    if (previousAct === undefined) delete globalThis.IS_REACT_ACT_ENVIRONMENT;
    else globalThis.IS_REACT_ACT_ENVIRONMENT = previousAct;
  }
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
  assert.equal(
    h.calls.some((c) => c.command.endsWith(".gesture")),
    false,
  );
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
