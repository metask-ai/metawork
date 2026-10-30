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

function renderHeatmap(visibleHistory = history, locale = "en-US") {
  return render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale,
          setLocale() {},
          t: (id, values) => translate(locale, id, values),
        },
      },
      createElement(AccountUsageHeatmap, { history: visibleHistory }),
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

function renderedMonthLabels(container) {
  return [...container.querySelectorAll(".settings-account-months span")].map(
    (label) => [Number(label.style.gridColumn), label.textContent],
  );
}

test("Account history month axis keeps November over a truncated October in the same week", () => {
  const { container } = renderHeatmap(
    { ...history, startDate: "2025-10-31", endDate: "2026-10-28", days: [] },
    "zh-CN",
  );
  assert.deepEqual(renderedMonthLabels(container), [
    [1, "11月"],
    [6, "12月"],
    [10, "1月"],
    [14, "2月"],
    [18, "3月"],
    [23, "4月"],
    [27, "5月"],
    [32, "6月"],
    [36, "7月"],
    [40, "8月"],
    [45, "9月"],
    [49, "10月"],
  ]);
  assert.ok(screen.getByRole("gridcell", { name: /2025年10月31日/ }));
});

for (const compact of [false, true]) {
  test(`Account history month axis prefers the later month across a year boundary (${compact ? 13 : 53} weeks)`, () => {
    narrow = compact;
    const { container } = renderHeatmap({
      ...history,
      startDate: "2025-12-31",
      endDate: "2026-01-02",
      days: [],
    });
    assert.deepEqual(renderedMonthLabels(container), [[1, "Jan"]]);
    assert.equal(screen.getAllByRole("gridcell").length, 3);
    assert.ok(screen.getByRole("gridcell", { name: /December 31, 2025/ }));
  });
}

test("Account history month axis retains months starting in separate week columns", () => {
  const { container } = renderHeatmap({
    ...history,
    startDate: "2025-10-26",
    endDate: "2025-11-05",
    days: [],
  });
  assert.deepEqual(renderedMonthLabels(container), [
    [1, "Oct"],
    [2, "Nov"],
  ]);
});

test("Account history month axis follows the visible range after narrow-screen clipping", () => {
  narrow = true;
  const { container } = renderHeatmap({
    ...history,
    startDate: "2025-10-31",
    endDate: "2026-10-28",
    days: [],
  });
  assert.deepEqual(renderedMonthLabels(container), [
    [1, "Aug"],
    [5, "Sep"],
    [9, "Oct"],
  ]);
  assert.equal(screen.getAllByRole("gridcell").length, 87);
});
