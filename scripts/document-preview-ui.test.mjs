import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
dom.window.PointerEvent ??= dom.window.MouseEvent;
for (const key of [
  "window",
  "document",
  "Node",
  "NodeFilter",
  "DocumentFragment",
  "Element",
  "HTMLElement",
  "HTMLButtonElement",
  "HTMLInputElement",
  "MutationObserver",
  "CustomEvent",
  "PointerEvent",
])
  globalThis[key] = key === "window" ? dom.window : dom.window[key];
for (const key of [
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
])
  globalThis[key] = dom.window[key].bind(dom.window);
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
globalThis.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};
for (const key of [
  "setPointerCapture",
  "releasePointerCapture",
  "scrollIntoView",
])
  HTMLElement.prototype[key] ??= () => {};
HTMLElement.prototype.hasPointerCapture ??= () => false;
const { act, cleanup, fireEvent, render, renderHook, screen, within, waitFor } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { DocumentPreviewView } = await vite.ssrLoadModule(
  "/src/app/DocumentPreviewView.tsx",
);
const { RunOutputs } = await vite.ssrLoadModule(
  "/src/features/tasks/RunOutputs.tsx",
);
const { useFilePreviewTabs } = await vite.ssrLoadModule(
  "/src/features/task-panel/useFilePreviewTabs.ts",
);
const { createTaskPanelPreviewTab } = await vite.ssrLoadModule(
  "/src/features/task-panel/task-panel-state.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const fixture = JSON.parse(
  readFileSync(
    new URL("../src/bridge/document_preview.fixture", import.meta.url),
    "utf8",
  ),
);
let nextId = 1;
class Preview {
  id = String(nextId++);
  calls = [];
  closed = 0;
  listeners = new Set();
  value;
  constructor(document = fixture.open) {
    this.document = { ...document, token: this.id.padStart(48, "0") };
    this.value = {
      state: "ready",
      document: this.document,
      content: { state: "loading" },
    };
  }
  getSnapshot = () => this.value;
  subscribe = (listener) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  publish(value) {
    this.value = value;
    for (const listener of this.listeners) listener();
  }
  read = async (selection) => {
    this.calls.push(selection);
    if (selection.kind === "region") {
      this.publish({
        state: "ready",
        document: this.document,
        content: {
          ...fixture.region,
          sheet: Number(selection.sheet),
          row: Number(selection.row),
          column: Number(selection.column),
          rows: Number(selection.rows),
          columns: Number(selection.columns),
        },
      });
    } else {
      this.publish({
        state: "ready",
        document: this.document,
        content: {
          state: "ready",
          kind: "page",
          page: Number(selection.page),
          image: {
            id: `${this.id}:${selection.page}`,
            src: "data:image/png;base64,AA==",
            width: 1,
            height: 1,
            valid: () => true,
            subscribe: () => () => {},
            beginDecode: async () => () => {},
          },
        },
      });
    }
  };
  close = async () => {
    this.closed++;
    this.publish({ state: "cancelled" });
    return true;
  };
}
function element(Component, props, locale = "en-US") {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale,
        setLocale() {},
        t: (id, values) => translate(locale, id, values),
      },
    },
    createElement(Component, props),
  );
}
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

test("document navigation issues bounded reads, shows image only after DOM decode, and refresh resets page", async () => {
  const preview = new Preview({ ...fixture.open, pageCount: 3 });
  let refreshed = 0;
  const page = render(
    element(DocumentPreviewView, {
      preview,
      title: "report.docx",
      onRefresh: () => refreshed++,
    }),
  );
  await waitFor(() => assert.equal(preview.calls.length, 1));
  assert.deepEqual(preview.calls[0], { kind: "page", page: "1" });
  const image = page.container.querySelector("img");
  image.decode = async () => {};
  await waitFor(() => assert.ok(image.src));
  assert.equal(
    page.container.querySelector(".file-preview-decoded").dataset.ready,
    "false",
  );
  fireEvent.load(image);
  await waitFor(() =>
    assert.equal(
      page.container.querySelector(".file-preview-decoded").dataset.ready,
      "true",
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: "Next page" }));
  await waitFor(() => assert.equal(preview.calls.at(-1).page, "2"));
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  assert.equal(refreshed, 1);
  const fresh = new Preview({ ...fixture.open, pageCount: 1 });
  page.rerender(
    element(DocumentPreviewView, {
      preview: fresh,
      title: "report.docx",
      onRefresh() {},
    }),
  );
  await waitFor(() =>
    assert.deepEqual(fresh.calls, [{ kind: "page", page: "1" }]),
  );
});
test("grid preserves formulas and saved values, exposes hidden sheets and omissions without evaluating markup", async () => {
  const preview = new Preview({
    ...fixture.open,
    kind: "grid",
    format: "xlsx",
    textScope: fixture.openWorkbook.textScope,
    layout: { state: "unsupported", omissions: [] },
    pageCount: 0,
    sheets: [
      {
        index: 1,
        name: "<script>unsafe</script>",
        hidden: false,
        rows: 26,
        columns: 21,
      },
      { index: 2, name: "Hidden sheet", hidden: true, rows: 1, columns: 1 },
    ],
    omissions: ["charts", "merged_cells"],
  });
  const page = render(
    element(DocumentPreviewView, {
      preview,
      title: "table.xlsx",
      onRefresh() {},
    }),
  );
  await waitFor(() => assert.equal(preview.calls.length, 1));
  assert.equal(preview.calls[0].rows, "25");
  assert.equal(preview.calls[0].columns, "10");
  assert.match(page.container.textContent, /Charts.*Merged cells/);
  assert.equal(page.container.querySelector("script"), null);
  fireEvent.click(screen.getByRole("button", { name: "A1", exact: true }));
  assert.match(
    page.container.querySelector(".document-preview-cell").textContent,
    /=1\+1/,
  );
  fireEvent.click(screen.getByRole("button", { name: "Next 25 rows" }));
  await waitFor(() => assert.equal(preview.calls.at(-1).row, "26"));
  assert.equal(preview.calls.at(-1).rows, "1");
  fireEvent.change(screen.getByRole("combobox"), { target: { value: "2" } });
  await waitFor(() => assert.equal(preview.calls.at(-1).sheet, "2"));
  assert.equal(preview.calls.at(-1).row, "1");
  assert.match(
    screen.getByRole("option", { name: /Hidden sheet/ }).textContent,
    /Hidden/,
  );
});
test("empty workbook settles and invalidation removes page and cell content immediately", async () => {
  const preview = new Preview({
    ...fixture.open,
    kind: "grid",
    format: "xlsx",
    textScope: fixture.openWorkbook.textScope,
    layout: { state: "unsupported", omissions: [] },
    pageCount: 0,
    sheets: [],
  });
  const page = render(
    element(DocumentPreviewView, {
      preview,
      title: "empty.xlsx",
      onRefresh() {},
    }),
  );
  assert.match(page.container.textContent, /worksheet is empty/);
  assert.equal(preview.calls.length, 0);
  assert.equal(
    page.container.querySelector("section").getAttribute("aria-busy"),
    "false",
  );
  const content = new Preview();
  page.rerender(
    element(DocumentPreviewView, {
      preview: content,
      title: "report.docx",
      onRefresh() {},
    }),
  );
  await waitFor(() => assert.ok(page.container.querySelector("img")));
  act(() => content.publish({ state: "expired" }));
  assert.equal(page.container.querySelector("img"), null);
  assert.match(page.container.textContent, /Preview expired/);
});

test("workbook switches between cells and print pages within one preview and uses view-specific omissions", async () => {
  const preview = new Preview(fixture.openWorkbook);
  const page = render(
    element(DocumentPreviewView, {
      preview,
      title: "book.xlsx",
      onRefresh() {},
    }),
  );
  await waitFor(() => assert.equal(preview.calls.at(-1)?.kind, "region"));
  assert.match(page.container.textContent, /Charts/);
  const layout = screen.getByRole("button", { name: "Print layout" });
  layout.focus();
  await userEvent.setup({ document: dom.window.document }).keyboard("{Enter}");
  await waitFor(() =>
    assert.deepEqual(preview.calls.at(-1), { kind: "page", page: "1" }),
  );
  assert.equal(layout.getAttribute("aria-pressed"), "true");
  assert.equal(page.container.querySelector("table"), null);
  assert.match(page.container.textContent, /without saved values/);
  assert.doesNotMatch(
    page.container.textContent,
    /Omitted from this preview: Charts/,
  );
  fireEvent.click(screen.getByRole("button", { name: "Next page" }));
  await waitFor(() => assert.equal(preview.calls.at(-1)?.page, "2"));
  fireEvent.click(screen.getByRole("button", { name: "Read-only cells" }));
  await waitFor(() => assert.equal(preview.calls.at(-1)?.kind, "region"));
  assert.ok(page.container.querySelector("table"));
  assert.equal(page.container.querySelector("img"), null);
  assert.equal(preview.closed, 0);
});

test("unavailable workbook layout stays explicit and preserves the usable grid", async () => {
  for (const state of ["unsupported", "limit"]) {
    const preview = new Preview({
      ...fixture.openWorkbook,
      pageCount: 0,
      layout: { state, omissions: [] },
    });
    const page = render(
      element(DocumentPreviewView, {
        preview,
        title: "book.xlsx",
        onRefresh() {},
      }),
    );
    await waitFor(() => assert.equal(preview.calls.length, 1));
    fireEvent.click(screen.getByRole("button", { name: "Print layout" }));
    assert.equal(preview.calls.length, 1);
    assert.match(page.container.textContent, /still use the read-only grid/);
    assert.equal(page.container.querySelector("table"), null);
    assert.equal(page.container.querySelector("img"), null);
    fireEvent.click(screen.getByRole("button", { name: "Read-only cells" }));
    await waitFor(() => assert.equal(preview.calls.length, 2));
    assert.ok(page.container.querySelector("table"));
    page.unmount();
  }
});
test("file preview tabs route Office without invoking ordinary preview and close on Task switch", () => {
  const reference = { id: "ref", title: "Report", displayPath: "report.docx" };
  const tab = createTaskPanelPreviewTab("3", "7", reference);
  const ids = new Set([tab.tabId]);
  let ordinary = 0;
  let suppliedSignal;
  const preview = new Preview();
  const { result, rerender, unmount } = renderHook(
    ({ task }) =>
      useFilePreviewTabs(
        task,
        ids,
        async () => {
          ordinary++;
          throw Error("ordinary lane must not run");
        },
        (task, run, id, signal) => {
          assert.deepEqual([task, run, id], ["3", "7", "ref"]);
          suppliedSignal = signal;
          return preview;
        },
      ),
    { initialProps: { task: "3" } },
  );
  act(() => result.current.open("3", "7", reference));
  assert.equal(result.current.resources[tab.tabId].kind, "document");
  assert.equal(ordinary, 0);
  rerender({ task: "4" });
  assert.equal(suppliedSignal.aborted, true);
  assert.ok(preview.closed > 0);
  assert.equal(Object.keys(result.current.resources).length, 0);
  unmount();
});
test("Outputs opens the exact delivered identity and closes preview before returning focus", async () => {
  const preview = new Preview(),
    calls = [];
  const output = {
    id: "03".repeat(16),
    displayPath: "results/report.pdf",
    sizeBytes: "42",
    redacted: false,
  };
  const page = render(
    element(RunOutputs, {
      outputs: [output],
      taskId: "3",
      runId: "7",
      onAction: async () => "ready",
      renderPreview: (preview, title, onRefresh) =>
        element(DocumentPreviewView, { preview, title, onRefresh }),
      onPreview: (...args) => {
        calls.push(args);
        return preview;
      },
    }),
  );
  const opener = screen.getByRole("button", { name: "Preview", exact: true });
  fireEvent.click(opener);
  await waitFor(() =>
    assert.ok(page.container.querySelector(".document-preview")),
  );
  assert.deepEqual(calls, [["3", "7", output.id]]);
  fireEvent.click(screen.getByRole("button", { name: "Close preview" }));
  assert.equal(page.container.querySelector(".document-preview"), null);
  assert.equal(preview.closed, 1);
  assert.equal(document.activeElement, opener);
});
