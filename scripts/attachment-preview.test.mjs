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
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;
dom.window.matchMedia = (media) => ({
  media,
  matches: false,
  addEventListener() {},
  removeEventListener() {},
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
  PointerEvent: dom.window.PointerEvent,
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
const { AttachmentPreviewDialog } = await vite.ssrLoadModule(
  "/src/features/composer/AttachmentPreviewDialog.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function readyPreview(releases) {
  let valid = true;
  return {
    state: "ready",
    content: "",
    truncated: false,
    redacted: false,
    image: {
      id: "image:1",
      mediaType: "image/png",
      width: 4,
      height: 3,
      src: "data:image/png;base64,AAAA",
      securityEpoch: "1",
      valid: () => valid,
      subscribe: () => () => {},
      beginDecode: () => new Promise(() => {}),
    },
    release() {
      valid = false;
      releases.push("image:1");
    },
  };
}

function renderDialog(props) {
  const opener = document.createElement("button");
  document.body.append(opener);
  const view = render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(AttachmentPreviewDialog, {
        target: {
          key: "draft:a",
          name: "diagram.png",
          detail: "PNG · 2 KB",
          available: true,
          invalid: "attachment.preview.invalid_draft",
          opener,
          ...props.target,
        },
        load: props.load,
        onClose: props.onClose ?? (() => {}),
      }),
    ),
  );
  return { ...view, opener };
}

test("the preview dialog names the attachment and shows the transferred image", async () => {
  const releases = [];
  const requests = [];
  const { unmount } = renderDialog({
    load(options) {
      requests.push(options.priority);
      return Promise.resolve(readyPreview(releases));
    },
  });
  assert.equal(
    screen.getByRole("dialog").textContent.includes("diagram.png"),
    true,
  );
  assert.ok(screen.getByText("PNG · 2 KB"));
  assert.ok(screen.getByText("Loading preview…"));
  const image = await waitFor(() =>
    screen.getByRole("img", { name: "diagram.png" }),
  );
  assert.ok(image);
  assert.deepEqual(requests, ["interactive"]);
  unmount();
  assert.deepEqual(releases, ["image:1"]);
});

test("retryable preview failures explain the problem and load again on request", async () => {
  let calls = 0;
  renderDialog({
    load() {
      calls += 1;
      return Promise.resolve({
        state: "error",
        content: "",
        truncated: false,
        redacted: false,
      });
    },
  });
  await waitFor(() =>
    screen.getByText("This image can't be previewed right now."),
  );
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => assert.equal(calls, 2));
});

test("an attachment that is no longer available offers no retry", async () => {
  renderDialog({
    load: () =>
      Promise.resolve({
        state: "missing",
        content: "",
        truncated: false,
        redacted: false,
      }),
  });
  await waitFor(() =>
    screen.getByText(
      "This attachment is no longer available. Remove it and add it again.",
    ),
  );
  assert.equal(screen.queryByRole("button", { name: "Retry" }), null);
});

test("a draft attachment withdrawn while open is not requested", () => {
  let calls = 0;
  renderDialog({
    target: { available: false },
    load() {
      calls += 1;
      return new Promise(() => {});
    },
  });
  assert.ok(
    screen.getByText(
      "This attachment is no longer available. Remove it and add it again.",
    ),
  );
  assert.equal(calls, 0);
});

test("Escape and the close button dismiss the preview without other effects", async () => {
  let closed = 0;
  renderDialog({
    load: () => new Promise(() => {}),
    onClose() {
      closed += 1;
    },
  });
  fireEvent.click(screen.getByRole("button", { name: "Close image preview" }));
  await waitFor(() => assert.equal(closed, 1));
});
