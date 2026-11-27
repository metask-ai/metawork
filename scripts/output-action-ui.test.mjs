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
  HTMLButtonElement: dom.window.HTMLButtonElement,
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
const { FileMenuProvider } = await vite.ssrLoadModule(
  "/src/components/FileMenu.tsx",
);
const { performFileMenuAction } = await vite.ssrLoadModule(
  "/src/features/tasks/reply-files.ts",
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
    createElement(
      FileMenuProvider,
      {
        value: {
          connected: !props.disabled,
          canReference: !!props.onReference,
          perform: (file, action, signal) =>
            performFileMenuAction(
              file,
              action,
              signal,
              props.onAction,
              props.onReference,
            ),
        },
      },
      createElement(RunOutputs, {
        taskId: "3",
        ...props,
        outputs: (props.outputs ?? [output]).map((o) => ({ ...o, runId: "7" })),
      }),
    ),
  );
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});
const described = (previewable) => async (target) => {
  described.asked.push(target);
  return {
    state: "ready",
    file: { kind: "file", sizeBytes: "42", previewable },
  };
};
described.asked = [];
const row = () => screen.getByRole("listitem");
const trigger = () => row().querySelector(".run-output-file");
async function openActions(keyboard = false) {
  const node = trigger();
  if (keyboard) fireEvent.keyDown(node, { key: "F10", shiftKey: true });
  else fireEvent.contextMenu(node, { clientX: 30, clientY: 20 });
  return screen.findByRole("menu");
}
async function chooseFileAction(name) {
  await openActions();
  fireEvent.click(screen.getByRole("menuitem", { name }));
}
test("a one-line row the preview cannot show ignores a click and opens its scoped menu by pointer or keyboard", async () => {
  const previews = [],
    requests = [];
  described.asked = [];
  render(
    view({
      onPreview: (...args) => previews.push(args),
      describe: described(false),
      onReference: async () => "edit_prepared",
      onAction: async (...args) => {
        requests.push(args);
        return "ready";
      },
    }),
  );
  assert.equal(trigger().textContent, "年度报告.docx");
  assert.match(trigger().title, /results\/年度报告.docx.*42 bytes/);
  await waitFor(() => assert.deepEqual(described.asked, [target]));
  fireEvent.click(trigger());
  assert.equal(trigger().tagName, "SPAN");
  assert.deepEqual(previews, []);
  await openActions(true);
  assert.equal(
    screen
      .getByRole("menuitem", { name: "Open in default app" })
      .getAttribute("aria-disabled"),
    "true",
  );
  assert.equal(requests.length, 0);
  fireEvent.click(screen.getByRole("menuitem", { name: "Check file" }));
  await screen.findByText("Matched delivered content when checked");
  assert.deepEqual(requests[0].slice(0, 2), [target, "check"]);
  await openActions();
  assert.equal(previews.length, 0);
  assert.ok(screen.getByRole("menuitem", { name: "Copy path" }));
});
test("a row the preview can show previews the file on click once the Host says so", async () => {
  const previews = [];
  const notes = { ...output, displayPath: "results/notes.md" };
  render(
    view({
      outputs: [notes],
      onPreview: (...args) => previews.push(args),
      describe: described(true),
    }),
  );
  // Before the Host answers, the row is not a preview button.
  assert.equal(trigger().tagName, "SPAN");
  await waitFor(() => assert.equal(trigger().tagName, "BUTTON"));
  fireEvent.click(trigger());
  assert.deepEqual(previews, [["3", notes.displayPath, trigger()]]);
});
test("delivery checks distinguish changed content and expose a truthful result", async () => {
  let resolve;
  render(
    view({
      onAction: () =>
        new Promise((r) => {
          resolve = r;
        }),
    }),
  );
  await chooseFileAction("Check file");
  await openActions();
  assert.equal(
    screen
      .getByRole("menuitem", { name: "Open folder" })
      .getAttribute("aria-disabled"),
    "true",
  );
  fireEvent.keyDown(screen.getByRole("menu"), { key: "Escape" });
  resolve("changed");
  await screen.findByText("Changed since delivery");
});
test("a check under way says so under its row and can be cancelled there", async () => {
  let signal;
  render(
    view({
      onAction: (_target, _action, s) => {
        signal = s;
        return new Promise(() => {});
      },
    }),
  );
  await chooseFileAction("Check file");
  assert.ok(await screen.findByText("Checking file…"));
  assert.ok(row().contains(screen.getByText("Checking file…")));
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(signal.aborted, true);
  assert.ok(screen.getByText("Cancelling…"));
  assert.equal(screen.getByRole("button", { name: "Cancel" }).disabled, true);
});
test("cancellation through the reopened file menu waits for the Host; unknown save results remain visible", async () => {
  let finish, fail, signal;
  render(
    view({
      onAction: (_target, _action, s) => {
        signal = s;
        return new Promise((resolve, reject) => {
          finish = resolve;
          fail = reject;
        });
      },
    }),
  );
  for (const unknown of [false, true]) {
    await chooseFileAction("Save as…");
    await chooseFileAction("Cancel");
    assert.equal(signal.aborted, true);
    assert.equal(
      row().querySelector(".file-menu-scope").getAttribute("aria-busy"),
      "true",
    );
    if (unknown) {
      fail(new Error("Transport disconnected"));
      await screen.findByText(
        "Save result is unconfirmed. Check the selected location.",
      );
    } else {
      finish("saved");
      await waitFor(() =>
        assert.equal(
          row().querySelector(".file-menu-scope").getAttribute("aria-busy"),
          "false",
        ),
      );
      assert.equal(screen.queryByRole("status"), null);
    }
  }
});
test("switching task, redaction and disconnection discard stale file references", async () => {
  let complete, signal;
  const references = [];
  const props = {
    onAction: (_target, _action, s) => {
      signal = s;
      return new Promise((resolve) => {
        complete = resolve;
      });
    },
    onReference: (...args) => {
      references.push(args);
      return "edit_prepared";
    },
  };
  const mounted = render(view(props));
  for (const change of [
    { taskId: "4" },
    { disabled: true },
    { outputs: [{ ...output, redacted: true }] },
  ]) {
    mounted.rerender(view(props));
    await chooseFileAction("Reference in conversation");
    mounted.rerender(view({ ...props, ...change }));
    assert.equal(signal.aborted, true);
    complete("ready");
    await waitFor(() => assert.equal(screen.queryByRole("status"), null));
    assert.deepEqual(references, []);
  }
  assert.equal(trigger().textContent, "File path hidden");
  assert.doesNotMatch(row().outerHTML, /年度报告|results\//);
  fireEvent.contextMenu(trigger());
  assert.equal(screen.queryByRole("menu"), null);
});
test("references use the current-file check first; the menu respects composition and Host open capabilities", async () => {
  const checks = [],
    references = [],
    previews = [];
  let finish;
  const props = {
    onAction: (...args) => {
      checks.push(args);
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
    onPreview: (...args) => previews.push(args),
    describe: described(true),
  };
  const mounted = render(view(props));
  await openActions();
  assert.equal(
    screen
      .getByRole("menuitem", { name: "Reference in conversation" })
      .getAttribute("aria-disabled"),
    "true",
  );
  assert.equal(screen.queryByRole("menuitem", { name: "View source" }), null);
  fireEvent.keyDown(screen.getByRole("menu"), { key: "Escape" });
  mounted.rerender(
    view({
      ...props,
      outputs: [
        { ...output, displayPath: "results/index.html", open: "browser" },
      ],
      onReference: (...args) => {
        references.push(args);
        return "edit_prepared";
      },
    }),
  );
  await waitFor(() => assert.equal(trigger().tagName, "BUTTON"));
  fireEvent.click(screen.getByRole("button", { name: "More file actions" }));
  assert.ok(await screen.findByRole("menuitem", { name: "Open in browser" }));
  fireEvent.click(screen.getByRole("menuitem", { name: "View source" }));
  assert.deepEqual(previews, [["3", "results/index.html", trigger()]]);
  await chooseFileAction("Reference in conversation");
  assert.equal(checks[0][1], "check_current");
  assert.deepEqual(references, []);
  finish("ready");
  await waitFor(() => assert.equal(references.length, 1));
  assert.deepEqual(references[0], [target, "results/index.html", checks[0][2]]);
});
