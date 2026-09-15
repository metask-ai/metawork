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

let narrow = false;
window.matchMedia = (media) => ({
  matches: narrow,
  media,
  onchange: null,
  addEventListener() {},
  removeEventListener() {},
  addListener() {},
  removeListener() {},
  dispatchEvent() {
    return false;
  },
});

const { cleanup, fireEvent, render, screen } =
  await import("@testing-library/react");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { AccountUsageHeatmap } = await vite.ssrLoadModule(
  "/src/features/settings/AccountUsageHeatmap.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => {
  cleanup();
  narrow = false;
});
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const history = {
  availability: "ready",
  startDate: "2025-09-15",
  endDate: "2026-09-15",
  days: [
    {
      date: "2026-09-14",
      inputTokens: "1",
      outputTokens: "2",
      cacheCreationTokens: "3",
      cacheReadTokens: "4",
      totalTokens: "10",
      actualCostU: "0.5",
    },
  ],
  syncedAt: "1789343000000",
  errorCode: "none",
  safeDiagnostic: "",
};

function renderHeatmap() {
  return render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(AccountUsageHeatmap, { history }),
    ),
  );
}

test("Account history heatmap selects today and uses one roving tab stop with arrow-key navigation", () => {
  renderHeatmap();
  const cells = screen.getAllByRole("gridcell");
  assert.equal(cells.length, 366);
  assert.equal(cells.filter((cell) => cell.tabIndex === 0).length, 1);

  const latest = screen.getByRole("gridcell", {
    name: /September 15, 2026, 0 Token/,
  });
  latest.focus();
  fireEvent.keyDown(latest, { key: "ArrowLeft" });

  assert.match(
    document.activeElement?.getAttribute("aria-label") ?? "",
    /September 14, 2026, 10 Token/,
  );
  assert.match(
    screen.getByText(/September 14, 2026, 10 Token/).textContent ?? "",
    /September 14, 2026/,
  );
});

test("Account history heatmap renders the latest 13 week columns on narrow screens", () => {
  narrow = true;
  renderHeatmap();
  assert.equal(screen.getAllByRole("gridcell").length, 86);
  assert.ok(screen.getByText("Past 13 weeks · Daily"));
});
