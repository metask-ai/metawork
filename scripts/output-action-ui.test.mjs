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

const { RunOutputs } = await vite.ssrLoadModule(
  "/src/features/tasks/RunOutputs.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const output = {
  id: "03".repeat(16),
  displayPath: "results/年度报告.docx",
  sizeBytes: "42",
  redacted: false,
};
const view = (props = {}) =>
  createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale: () => {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(RunOutputs, {
      outputs: [output],
      taskId: "3",
      runId: "7",
      ...props,
    }),
  );
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});
test("Output actions show checked states and always submit identity intent anew", async () => {
  const calls = [];
  let resolve;
  render(
    view({
      onAction: async (...args) => {
        calls.push(args);
        return new Promise((r) => {
          resolve = r;
        });
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Check file" }));
  assert.deepEqual(calls[0].slice(0, 4), ["3", "7", output.id, "check"]);
  assert.equal(
    screen.getByRole("button", { name: "Show in folder" }).disabled,
    true,
  );
  resolve("changed");
  await screen.findByText("Changed since delivery");
  fireEvent.click(screen.getByRole("button", { name: "Show in folder" }));
  assert.equal(calls[1][3], "reveal");
  resolve("revealed");
  await screen.findByText("Requested location in file manager");
  assert.equal(screen.queryByRole("link"), null);
});
test("Output cancellation aborts the Host request and ignores its late success", async () => {
  let signal;
  let resolve;
  render(
    view({
      onAction: async (_t, _r, _o, _a, s) => {
        signal = s;
        return new Promise((r) => {
          resolve = r;
        });
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Show in folder" }));
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(signal.aborted, true);
  resolve("revealed");
  await waitFor(() =>
    assert.equal(screen.getByRole("status").textContent, "Operation cancelled"),
  );
  assert.equal(
    screen.getByRole("button", { name: "Check file" }).disabled,
    false,
  );
});
test("Task replacement and disconnection invalidate in-flight results; hidden paths cannot act", async () => {
  let signal;
  let resolve;
  const onAction = async (_t, _r, _o, _a, s) => {
    signal = s;
    return new Promise((r) => {
      resolve = r;
    });
  };
  const mounted = render(view({ onAction }));
  fireEvent.click(screen.getByRole("button", { name: "Show in folder" }));
  mounted.rerender(view({ taskId: "4", onAction }));
  assert.equal(signal.aborted, true);
  resolve("revealed");
  await waitFor(() => assert.equal(screen.queryByRole("status"), null));
  fireEvent.click(screen.getByRole("button", { name: "Check file" }));
  mounted.rerender(view({ taskId: "4", disabled: true, onAction }));
  assert.equal(signal.aborted, true);
  resolve("ready");
  await waitFor(() => assert.equal(screen.queryByRole("status"), null));
  mounted.rerender(
    view({
      onAction,
      outputs: [{ ...output, redacted: true, displayPath: "" }],
    }),
  );
  assert.equal(
    screen.getByRole("button", { name: "Check file" }).disabled,
    true,
  );
  assert.equal(
    screen.getByRole("button", { name: "Show in folder" }).disabled,
    true,
  );
  assert.equal(screen.queryByText("年度报告.docx"), null);
});

test("Save cancellation waits for the actual Host result and preserves a committed success", async () => {
  let signal;
  let finish;
  render(
    view({
      onAction: async (_t, _r, _o, action, s) => {
        assert.equal(action, "save");
        signal = s;
        return new Promise((resolve) => {
          finish = resolve;
        });
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Save as…" }));
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(signal.aborted, true);
  assert.equal(screen.getByRole("button", { name: "Cancel" }).disabled, true);
  assert.equal(screen.getByRole("status").textContent, "Cancelling…");
  finish("saved");
  await screen.findByText("File saved");
  assert.equal(
    screen.getByRole("button", { name: "Save as…" }).disabled,
    false,
  );
  assert.equal(screen.queryByText("Operation cancelled"), null);
});

test("Save transport failure after cancel does not claim the destination was untouched", async () => {
  let reject;
  render(
    view({
      onAction: async () =>
        new Promise((_resolve, fail) => {
          reject = fail;
        }),
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Save as…" }));
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  reject(new Error("Transport lost after a possible commit"));
  await screen.findByText(
    "Save result is unconfirmed. Check the selected location.",
  );
  assert.equal(screen.queryByText("Operation cancelled"), null);
});
