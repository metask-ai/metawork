import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
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
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

const { cleanup, render, screen } = await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: "frontend",
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { CopyButton } = await vite.ssrLoadModule(
  "/src/components/ui/CopyButton.tsx",
);

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function renderCopyButton(onCopy) {
  return render(
    createElement(CopyButton, {
      copyLabel: "Copy response",
      copiedLabel: "Copied",
      failedLabel: "Copy failed",
      onCopy,
    }),
  );
}

test("copy feedback reports actual success and restores the action", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let calls = 0;
  renderCopyButton(async () => {
    calls += 1;
  });

  await user.click(screen.getByRole("button", { name: "Copy response" }));
  assert.equal(calls, 1);
  assert.equal(screen.getByRole("button").dataset.copyState, "copied");
  assert.equal(screen.getByRole("button").textContent, "Copied");

  await delay(1250);
  assert.equal(screen.getByRole("button").dataset.copyState, "idle");
  assert.equal(screen.getByRole("button").textContent, "Copy response");
});

test("copy feedback exposes rejection instead of fake success", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderCopyButton(async () => {
    throw new DOMException("denied", "NotAllowedError");
  });

  await user.click(screen.getByRole("button", { name: "Copy response" }));
  assert.equal(screen.getByRole("button").dataset.copyState, "failed");
  assert.equal(screen.getByRole("button").textContent, "Copy failed");
});

test("a repeated successful copy owns a fresh feedback timer", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderCopyButton(async () => {});

  await user.click(screen.getByRole("button", { name: "Copy response" }));
  await delay(700);
  await user.click(screen.getByRole("button", { name: "Copied" }));
  await delay(700);
  assert.equal(screen.getByRole("button").textContent, "Copied");
  await delay(550);
  assert.equal(screen.getByRole("button").textContent, "Copy response");
});
