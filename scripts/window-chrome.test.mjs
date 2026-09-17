import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { JSDOM } from "jsdom";
import {
  assertDisconnected,
  assertWindowChromeHandled,
  decodeWindowChromeEnvironment,
} from "../frontend/src/bridge/decode-contracts.ts";
import { installWindowChromeBridge } from "../frontend/src/bridge/window-chrome.ts";
import { commands } from "../frontend/src/bridge/commands.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL("../src/bridge/window_chrome.fixture", import.meta.url),
    "utf8",
  ),
);
const environment = fixture.environment;
const ack = fixture.handled;
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
    handlers.set(name, handler);
    nativeAdd(name, handler, ...args);
  };
  let refreshReply = () => environment;
  const bridge = {
    invoke(command, payload) {
      calls.push({ command, payload });
      if (command === commands.windowChromeConnect)
        return options.connect?.promise ?? Promise.resolve(environment);
      if (command === commands.windowChromeRefresh)
        return Promise.resolve().then(() => refreshReply());
      if (command === commands.windowChromeControl)
        return options.control?.promise ?? Promise.resolve(ack);
      if (command === commands.windowChromePointer)
        return options.pointer?.promise ?? Promise.resolve(ack);
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
  const pointer = (target, extra = {}) => {
    const path = [];
    for (let node = target; node; node = node.parentNode ?? node.host)
      path.push(node);
    handlers.get("pointerdown")({
      isTrusted: true,
      isPrimary: true,
      button: 0,
      clientX: 200,
      clientY: 20,
      composedPath: () => path,
      ...extra,
    });
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

test("trusted pointer routes actual event path including SVG, controls, portals and inert ancestors", async (t) => {
  const h = setup(t);
  await settle();
  h.pointer(h.query("#title"));
  for (const selector of ["path", "#disabled", "main", "#overlay"])
    h.pointer(h.query(selector));
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
  h.pointer(title, { isPrimary: false });
  h.pointer(title, { button: 2 });
  await settle();
  const pointers = h.calls.filter(
    (c) => c.command === commands.windowChromePointer,
  );
  assert.deepEqual(pointers[0].payload, {
    generation: "7",
    phase: "down",
    x: 200,
    y: 20,
  });
  assert.equal(pointers.length, 11);
  for (const call of pointers.slice(1))
    assert.deepEqual(call.payload, { generation: "7", phase: "reset" });
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
  assert.equal(h.count(commands.windowChromePointer), 1);
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
  assert.deepEqual(
    h.calls.find((c) => c.command === commands.windowChromePointer).payload,
    { generation: "7", phase: "reset" },
  );
});

test("pending pointer ack does not queue a second gesture or replay failed input", async (t) => {
  const pending = deferred();
  const h = setup(t, { pointer: pending });
  await settle();
  h.pointer(h.query("#title"));
  h.pointer(h.query("main"));
  h.pointer(h.query("#title"));
  assert.equal(h.count(commands.windowChromePointer), 3);
  pending.reject(new Error("rejected"));
  await settle();
  assert.equal(h.count(commands.windowChromePointer), 3);
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
