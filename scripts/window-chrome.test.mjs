import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";

import {
  assertDisconnected,
  decodeWindowChromeEnvironment,
} from "../frontend/src/bridge/decode-contracts.ts";
import { installWindowChromeBridge } from "../frontend/src/bridge/window-chrome.ts";
import { commands } from "../frontend/src/bridge/commands.ts";

const environment = {
  generation: "7",
  insets: { top: 52, left: 72, bottom: 0, right: 138 },
  buttons: { x: 0, y: 0, width: 138, height: 52 },
  livePointerDrag: true,
  rendererControls: true,
  maximized: false,
};

test("window chrome environment is runtime-decoded at the Bridge boundary", () => {
  assert.deepEqual(decodeWindowChromeEnvironment(environment), environment);
  const fractionalDpiEnvironment = {
    ...environment,
    insets: { top: 32.8, left: 0, bottom: 0, right: 138.4 },
    buttons: { x: 1041.6, y: 0, width: 138.4, height: 32.8 },
  };
  assert.deepEqual(
    decodeWindowChromeEnvironment(fractionalDpiEnvironment),
    fractionalDpiEnvironment,
  );
  for (const malformed of [
    { ...environment, generation: "0" },
    { ...environment, insets: { ...environment.insets, top: -1 } },
    { ...environment, buttons: { ...environment.buttons, width: Infinity } },
    { ...environment, livePointerDrag: "false" },
    { ...environment, rendererControls: "true" },
    { ...environment, maximized: "false" },
  ])
    assert.throws(() => decodeWindowChromeEnvironment(malformed));
});

test("window chrome disconnect acknowledges the exact document generation", () => {
  assert.doesNotThrow(() =>
    assertDisconnected({ generation: "7", detached: true }, "7"),
  );
  assert.throws(() =>
    assertDisconnected({ generation: "8", detached: true }, "7"),
  );
});

test("Native SDK resize keeps one generation and latest-only sync preserves controls on failure", async () => {
  const dom = new JSDOM(
    '<!doctype html><html><body><div data-metawork-window-drag><button data-metawork-window-control="minimize">minimize</button></div></body></html>',
    { pretendToBeVisual: true },
  );
  const previous = {
    window: globalThis.window,
    document: globalThis.document,
    Element: globalThis.Element,
    ResizeObserver: globalThis.ResizeObserver,
    MutationObserver: globalThis.MutationObserver,
  };
  const frames = [];
  let nextFrame = 1;
  const listeners = new Map();
  const calls = [];
  const pendingSyncs = [];
  let failNextSync = false;
  let unsubscribed = false;

  class ResizeObserverStub {
    observe() {}
    unobserve() {}
    disconnect() {}
  }

  const bridge = {
    invoke(command, payload) {
      calls.push({ command, payload });
      if (command === commands.windowChromeConnect)
        return Promise.resolve(environment);
      if (command === commands.windowChromeSync) {
        if (failNextSync) {
          failNextSync = false;
          return Promise.reject(new Error("sync failed"));
        }
        if (pendingSyncs.length > 0)
          return new Promise((resolve) => pendingSyncs.shift()(resolve));
        return Promise.resolve(environment);
      }
      if (command === commands.windowChromeDisconnect)
        return Promise.resolve({ generation: "7", detached: true });
      return Promise.resolve(environment);
    },
    on(name, callback) {
      listeners.set(name, callback);
      return () => {
        listeners.delete(name);
        unsubscribed = true;
      };
    },
  };

  try {
    globalThis.window = dom.window;
    globalThis.document = dom.window.document;
    globalThis.Element = dom.window.Element;
    globalThis.ResizeObserver = ResizeObserverStub;
    globalThis.MutationObserver = dom.window.MutationObserver;
    Object.defineProperty(dom.window, "zero", {
      configurable: true,
      value: bridge,
    });
    dom.window.requestAnimationFrame = (callback) => {
      frames.push(callback);
      return nextFrame++;
    };
    dom.window.cancelAnimationFrame = () => {};
    const candidate = dom.window.document.querySelector(
      "[data-metawork-window-drag]",
    );
    const control = dom.window.document.querySelector("button");
    candidate.getBoundingClientRect = () => domRect(dom.window, 0, 0, 500, 40);
    control.getBoundingClientRect = () => domRect(dom.window, 450, 0, 46, 40);

    const cleanup = installWindowChromeBridge();
    await settle();
    flushFrame(frames);
    await settle();
    assert.equal(countCalls(calls, commands.windowChromeConnect), 1);
    assert.equal(countCalls(calls, commands.windowChromeSync), 1);
    assert.equal(
      dom.window.document.documentElement.dataset
        .metaworkRendererWindowControls,
      "true",
    );

    pendingSyncs.push((resolve) => {
      pendingSyncs.resolve = resolve;
    });
    listeners.get("resize")({ width: 900, height: 600, scale: 1 });
    flushFrame(frames);
    await settle();
    listeners.get("resize")({ width: 910, height: 610, scale: 1 });
    listeners.get("resize")({ width: 920, height: 620, scale: 1 });
    assert.equal(countCalls(calls, commands.windowChromeConnect), 1);
    assert.equal(countCalls(calls, commands.windowChromeSync), 2);
    pendingSyncs.resolve(environment);
    await settle();
    flushFrame(frames);
    await settle();
    assert.equal(countCalls(calls, commands.windowChromeSync), 3);

    failNextSync = true;
    listeners.get("resize")({ width: 930, height: 630, scale: 1 });
    flushFrame(frames);
    await settle();
    assert.equal(countCalls(calls, commands.windowChromeConnect), 1);
    assert.equal(countCalls(calls, commands.windowChromeDisconnect), 0);
    assert.equal(
      dom.window.document.documentElement.dataset
        .metaworkRendererWindowControls,
      "true",
    );

    dom.window.dispatchEvent(new dom.window.Event("blur"));
    await settle();
    const resets = calls.filter(
      (call) =>
        call.command === commands.windowChromePointer &&
        call.payload.phase === "reset",
    );
    assert.deepEqual(resets, [
      {
        command: commands.windowChromePointer,
        payload: { generation: "7", phase: "reset" },
      },
    ]);

    cleanup();
    await settle();
    assert.equal(countCalls(calls, commands.windowChromeDisconnect), 1);
    assert.equal(unsubscribed, true);
  } finally {
    dom.window.close();
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  }
});

function domRect(window, x, y, width, height) {
  return new window.DOMRect(x, y, width, height);
}

function flushFrame(frames) {
  const frame = frames.shift();
  assert.ok(frame, "an animation frame should be scheduled");
  frame(0);
}

async function settle() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function countCalls(calls, command) {
  return calls.filter((call) => call.command === command).length;
}
