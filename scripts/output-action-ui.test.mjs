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
  await import("./renderer-testing-library.mjs");
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
const target = { kind: "output", taskId: "3", runId: "7", outputId: output.id };
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
  assert.deepEqual(calls[0].slice(0, 2), [target, "check"]);
  assert.equal(
    screen.getByRole("button", { name: "Open folder" }).disabled,
    true,
  );
  resolve("changed");
  await screen.findByText("Changed since delivery");
  fireEvent.click(screen.getByRole("button", { name: "Open folder" }));
  assert.equal(calls[1][1], "reveal");
  resolve("revealed");
  await screen.findByText("Requested location in file manager");
  assert.equal(screen.queryByRole("link"), null);
});
test("Output cancellation aborts the Host request and ignores its late success", async () => {
  let signal;
  let resolve;
  render(
    view({
      onAction: async (_target, _action, s) => {
        signal = s;
        return new Promise((r) => {
          resolve = r;
        });
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Open folder" }));
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
  const onAction = async (_target, _action, s) => {
    signal = s;
    return new Promise((r) => {
      resolve = r;
    });
  };
  const mounted = render(view({ onAction }));
  fireEvent.click(screen.getByRole("button", { name: "Open folder" }));
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
    screen.getByRole("button", { name: "Open folder" }).disabled,
    true,
  );
  assert.equal(screen.queryByText("年度报告.docx"), null);
});

test("Save cancellation waits for the actual Host result and preserves a committed success", async () => {
  let signal;
  let finish;
  render(
    view({
      onAction: async (_target, action, s) => {
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

test("Referencing a file in the conversation waits for the scoped Host check before preparing a draft and never submits", async () => {
  let complete;
  const checks = [];
  const prepared = [];
  render(
    view({
      onAction: async (...args) => {
        checks.push(args);
        return new Promise((resolve) => {
          complete = resolve;
        });
      },
      onReference: (...args) => {
        prepared.push(args);
        return "edit_prepared";
      },
    }),
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Reference in conversation" }),
  );
  assert.deepEqual(checks[0].slice(0, 2), [target, "check_current"]);
  assert.deepEqual(prepared, []);
  complete("ready");
  await screen.findByText("File reference added to the input.");
  assert.deepEqual(prepared, [[target, output.displayPath]]);
  assert.equal(checks.length, 1);
});
test("Referencing a file in the conversation preserves a conflicting draft and cannot prepare a changed source", async () => {
  let result = "changed";
  let preparations = 0;
  render(
    view({
      onAction: async () => result,
      onReference: () => {
        preparations++;
        return "edit_draft_busy";
      },
    }),
  );
  fireEvent.click(
    screen.getByRole("button", { name: "Reference in conversation" }),
  );
  await screen.findByText("The file changed during the operation. Try again.");
  assert.equal(preparations, 0);
  result = "ready";
  fireEvent.click(
    screen.getByRole("button", { name: "Reference in conversation" }),
  );
  await screen.findByText(
    "Skill draft preserved. Finish the current input first.",
  );
  assert.equal(preparations, 1);
});
test("Referencing a file in the conversation discards a late check after switching Tasks or disabling the source", async () => {
  let complete;
  let signal;
  let preparations = 0;
  const onAction = async (_target, _action, s) => {
    signal = s;
    return new Promise((resolve) => {
      complete = resolve;
    });
  };
  const onReference = () => {
    preparations++;
    return "edit_prepared";
  };
  const mounted = render(view({ onAction, onReference }));
  fireEvent.click(
    screen.getByRole("button", { name: "Reference in conversation" }),
  );
  mounted.rerender(view({ taskId: "4", onAction, onReference }));
  assert.equal(signal.aborted, true);
  complete("ready");
  await waitFor(() => assert.equal(screen.queryByRole("status"), null));
  assert.equal(preparations, 0);
  fireEvent.click(
    screen.getByRole("button", { name: "Reference in conversation" }),
  );
  mounted.rerender(
    view({ taskId: "4", disabled: true, onAction, onReference }),
  );
  assert.equal(signal.aborted, true);
  complete("ready");
  await waitFor(() => assert.equal(screen.queryByRole("status"), null));
  assert.equal(preparations, 0);
  mounted.rerender(view({ taskId: "4", onAction, onReference }));
  fireEvent.click(
    screen.getByRole("button", { name: "Reference in conversation" }),
  );
  mounted.rerender(
    view({
      taskId: "4",
      onAction,
      onReference,
      outputs: [{ ...output, redacted: true, displayPath: "" }],
    }),
  );
  assert.equal(signal.aborted, true);
  complete("ready");
  await waitFor(() => assert.equal(screen.queryByRole("status"), null));
  assert.equal(preparations, 0);
  assert.equal(
    screen.getByRole("button", { name: "Reference in conversation" }).disabled,
    true,
  );
});

test("Referencing a file is offered only while the conversation can take it", () => {
  const mounted = render(view({ onAction: async () => "ready" }));
  assert.equal(
    screen.queryByRole("button", { name: "Reference in conversation" }),
    null,
  );
  mounted.rerender(
    view({
      onAction: async () => "ready",
      onReference: () => "edit_prepared",
    }),
  );
  assert.ok(screen.getByRole("button", { name: "Reference in conversation" }));
});

test("Opening an output is offered only where the Host opens it, by its own name", async () => {
  const actions = [];
  const onAction = async (_target, action) => {
    actions.push(action);
    return action === "open" ? "open_failed" : "ready";
  };
  const buttons = () =>
    screen.getAllByRole("button").map((button) => button.textContent);
  const names = ["Check file", "Open folder", "Save as…"];
  const rows = (value) =>
    view({
      onAction,
      onPreview: () => {},
      outputs: [{ ...output, ...value }],
    });
  // The extension says nothing: only the projection does.
  const mounted = render(rows({ displayPath: "results/report.html" }));
  assert.deepEqual(buttons(), names);
  mounted.rerender(
    rows({ displayPath: "results/report.html", open: "browser" }),
  );
  assert.deepEqual(buttons(), ["Open in browser", "View source", ...names]);
  mounted.rerender(
    rows({ displayPath: "results/report.pdf", open: "default_app" }),
  );
  assert.deepEqual(buttons(), ["Open in default app", ...names]);
  fireEvent.click(screen.getByRole("button", { name: "Open in default app" }));
  await screen.findByText(
    "The system did not open this file. It may have no associated app.",
  );
  assert.deepEqual(actions, ["open"]);
});
