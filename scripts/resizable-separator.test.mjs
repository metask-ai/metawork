import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, useState } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;
dom.window.matchMedia = (query) => ({
  matches: query === "(max-width: 819px)" && dom.window.innerWidth < 820,
  media: query,
  addEventListener() {},
  removeEventListener() {},
});

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
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  server: { middlewareMode: true },
  logLevel: "silent",
});
const { ResizableSeparator } = await vite.ssrLoadModule(
  "/src/components/ui/ResizableSeparator.tsx",
);
const { AppShell } = await vite.ssrLoadModule("/src/app/AppShell.tsx");
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => {
  cleanup();
  dom.window.localStorage.clear();
  Object.defineProperty(dom.window, "innerWidth", {
    configurable: true,
    value: 1024,
  });
});
test.after(() => vite.close());

function renderTaskPanelShell(viewportWidth) {
  Object.defineProperty(dom.window, "innerWidth", {
    configurable: true,
    value: viewportWidth,
  });
  function shell(open) {
    return createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(
        AppShell,
        {
          taskTitle: "Task",
          contextVisible: true,
          attentionNotice: null,
          onSearch() {},
          left: createElement("p", null, "Navigation"),
          rightPanel: createElement("p", null, "Task details"),
          rightPanelOpen: open,
          onDismissRightPanel() {},
        },
        createElement("p", null, "Task stage"),
      ),
    );
  }
  const view = render(shell(true));
  return {
    root: document.querySelector(".app-window"),
    rerenderOpen(open) {
      view.rerender(shell(open));
    },
  };
}

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

test("right-side separator reverses pointer and arrow direction", () => {
  const commits = [];

  function Harness() {
    const [value, setValue] = useState(400);
    return createElement(ResizableSeparator, {
      label: "Resize side panel",
      value,
      minimum: 320,
      maximum: 640,
      step: 16,
      reverse: true,
      onChange: setValue,
      onCommit(next) {
        commits.push(next);
      },
    });
  }

  render(createElement(Harness));
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  fireEvent.keyDown(separator, { key: "ArrowLeft" });
  assert.equal(separator.getAttribute("aria-valuenow"), "416");
  fireEvent.keyDown(separator, { key: "ArrowRight" });
  assert.equal(separator.getAttribute("aria-valuenow"), "400");

  fireEvent.pointerDown(separator, { pointerId: 8, clientX: 600 });
  fireEvent.pointerMove(separator, { pointerId: 8, clientX: 540 });
  fireEvent.pointerUp(separator, { pointerId: 8, clientX: 540 });
  assert.equal(separator.getAttribute("aria-valuenow"), "460");
  assert.equal(commits.at(-1), 460);
});

test("lost pointer capture commits and closes the active resize transaction", () => {
  const commits = [];
  let resizeEnds = 0;

  render(
    createElement(ResizableSeparator, {
      label: "Resize side panel",
      value: 400,
      minimum: 320,
      maximum: 640,
      step: 16,
      reverse: true,
      onChange() {},
      onCommit(next) {
        commits.push(next);
      },
      onResizeEnd() {
        resizeEnds += 1;
      },
    }),
  );
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  fireEvent.pointerDown(separator, { pointerId: 9, clientX: 600 });
  fireEvent.pointerMove(separator, { pointerId: 9, clientX: 540 });
  fireEvent.lostPointerCapture(separator, { pointerId: 9 });

  assert.deepEqual(commits, [460]);
  assert.equal(resizeEnds, 1);
});

test("an overlay Task Panel can resize back into the docked layout", () => {
  const { root } = renderTaskPanelShell(1100);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");

  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });
  fireEvent.keyDown(separator, { key: "ArrowRight" });
  fireEvent.keyDown(separator, { key: "ArrowRight" });

  assert.equal(root?.getAttribute("data-right-panel-docked"), "true");
  assert.equal(
    screen.getByRole("separator", { name: "Resize side panel" }),
    separator,
  );
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.width"),
    "368",
  );
});

test("Task Panel resize survives a dock-to-overlay transition", () => {
  const { root } = renderTaskPanelShell(1200);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "true");

  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });
  fireEvent.pointerDown(separator, { pointerId: 10, clientX: 600 });
  fireEvent.pointerMove(separator, { pointerId: 10, clientX: 520 });

  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
  assert.equal(root?.getAttribute("data-resizing-right"), "true");
  assert.equal(
    screen.getByRole("separator", { name: "Resize side panel" }),
    separator,
  );

  fireEvent.pointerUp(separator, { pointerId: 10, clientX: 520 });
  assert.equal(root?.getAttribute("data-resizing-right"), "false");
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.width"),
    "480",
  );
});

test("a viewport-capped overlay resizes from its rendered width", () => {
  dom.window.localStorage.setItem("metawork.panel.task.width", "640");
  const { root } = renderTaskPanelShell(650);
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
  assert.equal(separator.getAttribute("aria-valuenow"), "606");
  assert.equal(separator.getAttribute("aria-valuemax"), "606");

  fireEvent.keyDown(separator, { key: "ArrowRight" });
  assert.equal(separator.getAttribute("aria-valuenow"), "590");
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.width"),
    "590",
  );
});

test("closing the Task Panel finalizes an active resize", () => {
  const { root, rerenderOpen } = renderTaskPanelShell(1200);
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  fireEvent.pointerDown(separator, { pointerId: 11, clientX: 600 });
  fireEvent.pointerMove(separator, { pointerId: 11, clientX: 560 });
  assert.equal(root?.getAttribute("data-resizing-right"), "true");

  rerenderOpen(false);
  assert.equal(root?.getAttribute("data-resizing-right"), "false");
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.width"),
    "440",
  );
  assert.equal(
    screen.queryByRole("separator", { name: "Resize side panel" }),
    null,
  );
});
