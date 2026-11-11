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
const mediaQueryLists = new Set();
dom.window.matchMedia = (query) => {
  const evaluate = () =>
    query === "(max-width: 819px)" && dom.window.innerWidth < 820;
  const listeners = new Set();
  const list = {
    matches: evaluate(),
    media: query,
    addEventListener(type, listener) {
      if (type === "change") listeners.add(listener);
    },
    removeEventListener(type, listener) {
      listeners.delete(listener);
    },
    reevaluate() {
      const matches = evaluate();
      if (matches === list.matches) return;
      list.matches = matches;
      for (const listener of listeners) listener({ matches, media: query });
    },
  };
  mediaQueryLists.add(list);
  return list;
};

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

const { act, cleanup, fireEvent, render, screen } =
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
const { AppShell, isTaskStageExposed } = await vite.ssrLoadModule(
  "/src/app/AppShell.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => {
  cleanup();
  mediaQueryLists.clear();
  dom.window.localStorage.clear();
  Object.defineProperty(dom.window, "innerWidth", {
    configurable: true,
    value: 1024,
  });
});
test.after(() => vite.close());

test("Task stage exposure excludes every full-covering surface", () => {
  const visible = {
    viewportWidth: 1200,
    leftOpen: true,
    rightPanelOpen: true,
    rightPanelDocked: true,
    overlayOpen: false,
  };
  assert.equal(isTaskStageExposed(visible), true);
  assert.equal(isTaskStageExposed({ ...visible, overlayOpen: true }), false);
  assert.equal(isTaskStageExposed({ ...visible, viewportWidth: 700 }), false);
  assert.equal(
    isTaskStageExposed({ ...visible, rightPanelDocked: false }),
    false,
  );
});

function renderTaskPanelShell(viewportWidth, overrides = {}) {
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
          ...overrides,
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
    resizeViewport(width) {
      Object.defineProperty(dom.window, "innerWidth", {
        configurable: true,
        value: width,
      });
      fireEvent(dom.window, new dom.window.Event("resize"));
      act(() => {
        for (const list of mediaQueryLists) list.reevaluate();
      });
    },
  };
}

test("resizable separator clamps pointer movement and supports keyboard control", () => {
  const commits = [];

  function Harness() {
    const [value, setValue] = useState(320);
    return createElement(ResizableSeparator, {
      label: "Resize task sidebar",
      value,
      minimum: 240,
      maximum: 480,
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
  assert.equal(separator.getAttribute("aria-valuenow"), "336");
  assert.deepEqual(commits, [336]);

  fireEvent.keyDown(separator, { key: "Home" });
  assert.equal(separator.getAttribute("aria-valuenow"), "240");

  fireEvent.pointerDown(separator, { pointerId: 7, clientX: 100 });
  fireEvent.pointerMove(separator, { pointerId: 7, clientX: 500 });
  fireEvent.pointerUp(separator, { pointerId: 7, clientX: 500 });
  assert.equal(separator.getAttribute("aria-valuenow"), "480");
  assert.equal(commits.at(-1), 480);
});

test("Task sidebar defaults to 320px with the 240–480px contract", () => {
  const { root } = renderTaskPanelShell(1400);
  const separator = screen.getByRole("separator", {
    name: "Resize task sidebar",
  });

  assert.equal(root?.style.getPropertyValue("--left-column-width"), "320px");
  assert.equal(separator.getAttribute("aria-valuenow"), "320");
  assert.equal(separator.getAttribute("aria-valuemin"), "240");
  assert.equal(separator.getAttribute("aria-valuemax"), "480");
});

test("Task sidebar clamps a legacy stored width to the new minimum", () => {
  dom.window.localStorage.setItem("metawork.panel.workspaces.width", "208");
  const { root } = renderTaskPanelShell(1400);
  const separator = screen.getByRole("separator", {
    name: "Resize task sidebar",
  });

  assert.equal(root?.style.getPropertyValue("--left-column-width"), "240px");
  assert.equal(separator.getAttribute("aria-valuenow"), "240");
});

test("left resizing recomputes the middle and right allocation without changing share", () => {
  const { root } = renderTaskPanelShell(1440);
  const leftSeparator = screen.getByRole("separator", {
    name: "Resize task sidebar",
  });
  const initialWidth = root?.style.getPropertyValue("--right-panel-width");

  fireEvent.keyDown(leftSeparator, { key: "ArrowRight" });

  assert.equal(root?.style.getPropertyValue("--left-column-width"), "336px");
  assert.equal(
    screen
      .getByRole("separator", { name: "Resize side panel" })
      .getAttribute("aria-valuenow"),
    "368",
  );
  assert.equal(initialWidth, "374px");
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "368px");
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.share"),
    null,
  );
});

test("left resizing moves the right panel to overlay when docked minimums no longer fit", () => {
  const { root } = renderTaskPanelShell(1079);
  const leftSeparator = screen.getByRole("separator", {
    name: "Resize task sidebar",
  });
  assert.equal(root?.getAttribute("data-right-panel-docked"), "true");

  fireEvent.keyDown(leftSeparator, { key: "End" });

  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
  assert.equal(
    screen.queryByRole("separator", { name: "Resize side panel" }),
    null,
  );
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "400px");
});

test("the stable app window owns layout measurement", () => {
  let callback;
  let observedElement;
  globalThis.ResizeObserver = class {
    constructor(next) {
      callback = next;
    }
    observe(element) {
      observedElement = element;
    }
    disconnect() {}
  };
  try {
    const { root } = renderTaskPanelShell(1400);
    assert.equal(root?.getAttribute("data-right-panel-docked"), "true");
    assert.equal(observedElement, root);

    act(() =>
      callback([
        {
          target: root,
          contentRect: { width: 1000 },
        },
      ]),
    );

    assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
    assert.equal(root?.style.getPropertyValue("--right-panel-width"), "400px");
  } finally {
    delete globalThis.ResizeObserver;
  }
});

test("an empty minimized viewport keeps the sidebar and the measured layout", () => {
  let callback;
  let observedElement;
  globalThis.ResizeObserver = class {
    constructor(next) {
      callback = next;
    }
    observe(element) {
      observedElement = element;
    }
    disconnect() {}
  };
  const observe = (width) =>
    act(() => callback([{ target: observedElement, contentRect: { width } }]));
  try {
    const { root, resizeViewport } = renderTaskPanelShell(1400);
    const rightWidth = root?.style.getPropertyValue("--right-panel-width");
    assert.equal(root?.getAttribute("data-left-open"), "true");

    // The root min-width keeps the app window at 320px in an empty viewport.
    resizeViewport(0);
    observe(320);
    assert.equal(root?.getAttribute("data-left-open"), "true");
    assert.equal(root?.getAttribute("data-right-panel-docked"), "true");
    assert.equal(
      root?.style.getPropertyValue("--right-panel-width"),
      rightWidth,
    );

    resizeViewport(1400);
    observe(1400);
    assert.equal(root?.getAttribute("data-left-open"), "true");
  } finally {
    delete globalThis.ResizeObserver;
  }
});

test("regaining the desktop width restores the saved sidebar choice", () => {
  // A minimized window on a scaled Windows display can report a narrow,
  // non-empty viewport, so the sidebar must return with the real width.
  const { root, resizeViewport } = renderTaskPanelShell(1400);

  resizeViewport(787);
  assert.equal(root?.getAttribute("data-left-open"), "false");
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.workspaces"),
    null,
  );

  resizeViewport(1400);
  assert.equal(root?.getAttribute("data-left-open"), "true");
});

test("an explicitly collapsed sidebar stays collapsed after a narrow layout", () => {
  const { root, resizeViewport } = renderTaskPanelShell(1400);
  fireEvent.click(screen.getByRole("button", { name: "Toggle task sidebar" }));
  assert.equal(root?.getAttribute("data-left-open"), "false");

  resizeViewport(787);
  resizeViewport(1400);
  assert.equal(root?.getAttribute("data-left-open"), "false");
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

test("an overlay Task Panel is not resizable and restores its saved share", () => {
  dom.window.localStorage.setItem("metawork.panel.task.share", "0.4");
  const { root, resizeViewport } = renderTaskPanelShell(1039);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
  assert.equal(
    screen.queryByRole("separator", { name: "Resize side panel" }),
    null,
  );
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "400px");

  resizeViewport(1400);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "true");
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });
  assert.equal(separator.getAttribute("aria-valuenow"), "432");
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "432px");
});

test("docked Task Panel resizing persists a proportional share", () => {
  const { root } = renderTaskPanelShell(1400);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "true");

  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });
  assert.equal(separator.getAttribute("aria-valuenow"), "360");
  fireEvent.keyDown(separator, { key: "ArrowLeft" });

  assert.equal(separator.getAttribute("aria-valuenow"), "376");
  assert.equal(
    Number(dom.window.localStorage.getItem("metawork.panel.task.share")),
    376 / 1080,
  );
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "376px");
});

test("docked Task Panel exposes dynamic keyboard bounds", () => {
  const { root } = renderTaskPanelShell(1200);
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  assert.equal(separator.getAttribute("aria-valuemin"), "360");
  assert.equal(separator.getAttribute("aria-valuemax"), "520");
  fireEvent.keyDown(separator, { key: "End" });
  assert.equal(separator.getAttribute("aria-valuenow"), "520");
  assert.equal(
    Number(dom.window.localStorage.getItem("metawork.panel.task.share")),
    520 / 880,
  );
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "520px");
});

test("wide docked layouts have no fixed maximum or proportional range", () => {
  const { root } = renderTaskPanelShell(1920);
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  assert.equal(separator.getAttribute("aria-valuemin"), "360");
  assert.equal(separator.getAttribute("aria-valuemax"), "1240");
  fireEvent.keyDown(separator, { key: "End" });
  assert.equal(separator.getAttribute("aria-valuenow"), "1240");
  assert.equal(
    Number(dom.window.localStorage.getItem("metawork.panel.task.share")),
    0.775,
  );
  fireEvent.keyDown(separator, { key: "Home" });
  assert.equal(separator.getAttribute("aria-valuenow"), "360");
  assert.equal(
    Number(dom.window.localStorage.getItem("metawork.panel.task.share")),
    0.225,
  );
});

test("overlay width is independent from legacy absolute-width preferences", () => {
  dom.window.localStorage.setItem("metawork.panel.task.width", "640");
  const { root } = renderTaskPanelShell(650);

  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "400px");
  assert.equal(
    screen.queryByRole("separator", { name: "Resize side panel" }),
    null,
  );
  assert.equal(
    dom.window.localStorage.getItem("metawork.panel.task.share"),
    null,
  );
});

test("closing the Task Panel finalizes an active proportional resize", () => {
  const { root, rerenderOpen } = renderTaskPanelShell(1400);
  const separator = screen.getByRole("separator", {
    name: "Resize side panel",
  });

  fireEvent.pointerDown(separator, { pointerId: 11, clientX: 600 });
  fireEvent.pointerMove(separator, { pointerId: 11, clientX: 560 });
  assert.equal(root?.getAttribute("data-resizing-right"), "true");

  rerenderOpen(false);
  assert.equal(root?.getAttribute("data-resizing-right"), "false");
  assert.equal(
    Number(dom.window.localStorage.getItem("metawork.panel.task.share")),
    400 / 1080,
  );
  assert.equal(
    screen.queryByRole("separator", { name: "Resize side panel" }),
    null,
  );
});

test("a closed Task Panel preserves its target placement for exit motion", () => {
  const { root, rerenderOpen, resizeViewport } = renderTaskPanelShell(1400);
  const openWidth = root?.style.getPropertyValue("--right-panel-width");

  rerenderOpen(false);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "true");
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), openWidth);
  assert.equal(
    screen.queryByRole("separator", { name: "Resize side panel" }),
    null,
  );

  resizeViewport(1039);
  assert.equal(root?.getAttribute("data-right-panel-docked"), "false");
  assert.equal(root?.style.getPropertyValue("--right-panel-width"), "400px");
});

test("native titlebar declarations exclude controls and the hittable inert outer groups", () => {
  const audit = () => {
    const header = document.querySelector("header[data-native-window-drag]");
    assert.ok(header);
    for (const element of header.querySelectorAll(
      'button,input,select,textarea,label,details,summary,a,[tabindex],[contenteditable],[inert],[role="button"]',
    ))
      assert.ok(
        element.closest("[data-native-window-drag-exclude]"),
        element.outerHTML,
      );
    return header;
  };
  renderTaskPanelShell(1200, {
    headerActions: createElement("button", null, "Dynamic task action"),
    attentionNotice: "Connection failed",
  });
  const header = audit();
  assert.equal(
    header
      .querySelector(".commandbar-task")
      .closest("[data-native-window-drag-exclude]"),
    null,
    "ordinary title text must remain draggable",
  );
  cleanup();
  renderTaskPanelShell(390, {
    overlayOpen: true,
    attentionNotice: "Connection failed",
  });
  audit();
  for (const element of document.querySelectorAll("header [inert]")) {
    const outer = element.parentElement;
    assert.ok(
      !outer.inert && outer.hasAttribute("data-native-window-drag-exclude"),
      "inert hit-test retargeting must land on an excluded outer element",
    );
  }
});
