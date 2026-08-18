import assert from "node:assert/strict";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, useState } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
HTMLElement.prototype.hasPointerCapture = () => false;
HTMLElement.prototype.setPointerCapture = () => undefined;
HTMLElement.prototype.releasePointerCapture = () => undefined;

const { cleanup, fireEvent, render, screen } =
  await import("@testing-library/react");
const vite = await createServer({
  configFile: false,
  root: new URL("../frontend", import.meta.url).pathname,
  plugins: [(await import("@vitejs/plugin-react")).default()],
  server: { middlewareMode: true },
  logLevel: "silent",
});
const { ResizableSeparator } = await vite.ssrLoadModule(
  "/src/components/ui/ResizableSeparator.tsx",
);

test.afterEach(() => cleanup());
test.after(() => vite.close());

test("resizable separator clamps pointer movement and supports keyboard control", () => {
  const commits = [];

  function Harness() {
    const [value, setValue] = useState(248);
    return createElement(ResizableSeparator, {
      label: "Resize task sidebar",
      value,
      minimum: 208,
      maximum: 360,
      step: 16,
      onChange: setValue,
      onCommit(next) {
        commits.push(next);
      },
    });
  }

  render(createElement(Harness));
  const separator = screen.getByRole("separator", {
    name: "Resize task sidebar",
  });

  fireEvent.keyDown(separator, { key: "ArrowRight" });
  assert.equal(separator.getAttribute("aria-valuenow"), "264");
  assert.deepEqual(commits, [264]);

  fireEvent.keyDown(separator, { key: "Home" });
  assert.equal(separator.getAttribute("aria-valuenow"), "208");

  fireEvent.pointerDown(separator, { pointerId: 7, clientX: 100 });
  fireEvent.pointerMove(separator, { pointerId: 7, clientX: 500 });
  fireEvent.pointerUp(separator, { pointerId: 7, clientX: 500 });
  assert.equal(separator.getAttribute("aria-valuenow"), "360");
  assert.equal(commits.at(-1), 360);
});
