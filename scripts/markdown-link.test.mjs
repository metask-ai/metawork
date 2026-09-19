import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  NodeFilter: dom.window.NodeFilter,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
  CustomEvent: dom.window.CustomEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

const { cleanup, fireEvent, render, screen, waitFor } =
  await import("@testing-library/react");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { Markdown } = await vite.ssrLoadModule(
  "/src/components/ai/Markdown.tsx",
);

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

test("managed Markdown links prevent WebView navigation and delegate the exact URL", async () => {
  const opened = [];
  render(
    createElement(
      Markdown,
      {
        webLink: {
          failedLabel: "Could not open",
          async onOpen(href) {
            opened.push(href);
            return true;
          },
        },
      },
      "[Open](https://example.com/a?q=1)",
    ),
  );
  const link = screen.getByRole("link", { name: "Open" });
  assert.equal(
    fireEvent.click(link, { button: 0 }),
    false,
    "the DOM event must be cancelled synchronously",
  );
  await waitFor(() => assert.deepEqual(opened, ["https://example.com/a?q=1"]));
  assert.equal(link.getAttribute("target"), null);
});

test("managed Markdown links show a local error when the Host cannot open them", async () => {
  render(
    createElement(
      Markdown,
      {
        webLink: {
          failedLabel: "Could not open",
          async onOpen() {
            return false;
          },
        },
      },
      "[Open](https://example.com)",
    ),
  );
  fireEvent.click(screen.getByRole("link", { name: "Open" }));
  assert.equal(
    await screen.findByRole("alert").then((node) => node.textContent),
    "Could not open",
  );
});

test("provisional Markdown remains inert even when a link opener exists", () => {
  render(
    createElement(
      Markdown,
      {
        interactive: false,
        webLink: {
          failedLabel: "Could not open",
          async onOpen() {
            return true;
          },
        },
      },
      "[Open](https://example.com)",
    ),
  );
  assert.equal(screen.queryByRole("link"), null);
  assert.equal(screen.getByText("Open").tagName, "SPAN");
});
