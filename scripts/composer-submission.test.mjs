import { productStateFixture } from "./test-support/product-view-fixture.mjs";
import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement, createRef, useState } from "react";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
if (!dom.window.PointerEvent) dom.window.PointerEvent = dom.window.MouseEvent;

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  NodeFilter: dom.window.NodeFilter,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  HTMLInputElement: dom.window.HTMLInputElement,
  MutationObserver: dom.window.MutationObserver,
  CustomEvent: dom.window.CustomEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  PointerEvent: dom.window.PointerEvent,
});
const resizeObservers = [];
globalThis.ResizeObserver = class {
  constructor(callback) {
    this.callback = callback;
    this.target = null;
    resizeObservers.push(this);
  }

  observe(target) {
    this.target = target;
  }

  disconnect() {
    this.target = null;
  }

  notify(width = 320) {
    this.callback([
      {
        target: this.target,
        contentRect: { width },
      },
    ]);
  }
};
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

if (!HTMLElement.prototype.hasPointerCapture)
  HTMLElement.prototype.hasPointerCapture = () => false;
if (!HTMLElement.prototype.setPointerCapture)
  HTMLElement.prototype.setPointerCapture = () => undefined;
if (!HTMLElement.prototype.releasePointerCapture)
  HTMLElement.prototype.releasePointerCapture = () => undefined;
if (!HTMLElement.prototype.scrollIntoView)
  HTMLElement.prototype.scrollIntoView = () => undefined;
HTMLButtonElement.prototype.getBoundingClientRect = () => ({
  x: 16,
  y: 16,
  width: 320,
  height: 36,
  top: 16,
  right: 336,
  bottom: 52,
  left: 16,
  toJSON() {
    return this;
  },
});

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function pasteItems(target, items) {
  const event = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: {
      items,
      get files() {
        throw new Error("Do not extract the same clipboard files twice");
      },
      getData: () => "companion clipboard text",
    },
  });
  fireEvent(target, event);
  return event;
}

function imageItem(file) {
  return { kind: "file", type: file.type, getAsFile: () => file };
}

async function renderSubmissionApp(
  ctx,
  {
    newTask = false,
    draft = null,
    attachmentsEnabled,
    active = false,
    inputReady = true,
  } = {},
) {
  window.sessionStorage.clear();
  window.matchMedia = (query) => ({
    matches: false,
    media: query,
    addEventListener() {},
    removeEventListener() {},
  });
  globalThis.CSS ??= { escape: (value) => value.replace(/["\\]/g, "\\$&") };
  const { readFile } = await import("node:fs/promises");
  const { default: App } = await vite.ssrLoadModule("/src/app/App.tsx");
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  const snapshot = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  snapshot.capabilities.automaticWorkspaces = true;
  if (attachmentsEnabled !== undefined)
    snapshot.capabilities.attachments.enabled = attachmentsEnabled;
  const task = structuredClone(snapshot.tasks[0]);
  Object.assign(task, {
    title: "Submission task",
    activeOperation: null,
    currentRunId: null,
    currentRunPhase: null,
    runs: [],
  });
  if (active) {
    const live = structuredClone(snapshot.tasks[0].runs[0]);
    Object.assign(live, {
      phase: "running",
      terminal: null,
      activity: { kind: "waiting_model" },
      additionalInputs: [],
    });
    Object.assign(task, {
      activeOperation: { kind: "run", id: live.id },
      currentRunId: live.id,
      currentRunPhase: "running",
      runs: [live],
      pendingUi: null,
      inputReady,
    });
  }
  task.skillCatalog.availability = "unavailable";
  snapshot.tasks = newTask ? [] : [task];
  let revision;
  let rejectRevision;
  let connectionGeneration = 0;
  let resolveRun;
  const createResolvers = [];
  const createRejectors = [];
  const createRequests = [];
  const running = new Promise((resolve) => {
    resolveRun = resolve;
  });
  const inputs = [],
    targets = [],
    operationIds = [],
    cancellations = [];
  let creations = 0;
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onTaskOpen: () => () => {},
    onWorkbenchRevision: (callback, reject) => {
      revision = callback;
      rejectRevision = reject;
      return () => {};
    },
    connect: async () => String(++connectionGeneration),
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    createTask: (...args) => {
      creations += 1;
      createRequests.push(args);
      return new Promise((resolve, reject) => {
        createResolvers.push(resolve);
        createRejectors.push(reject);
      });
    },
    cancel: async (taskId, runId) => {
      cancellations.push([taskId, runId]);
      return { taskId, runId, cancelRequested: true };
    },
    stopTask: async (taskId) => {
      cancellations.push([taskId]);
    },
    sendInput: (operationId, taskId, input) => {
      inputs.push([taskId, null, input]);
      targets.push({ taskId });
      operationIds.push(operationId);
      return running.then((result) => {
        if (result instanceof Error) throw result;
        if (result.outcome) return result;
        return {
          taskId,
          operationId,
          outcome: result.accepted ? "accepted" : "rejected",
          reason: result.accepted ? null : result.reason,
        };
      });
    },
  }))
    ctx.mock.method(BridgeClient.prototype, name, fn);
  render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(App),
    ),
  );
  await waitFor(() => assert.ok(revision));
  await waitFor(() =>
    assert.ok(
      document.querySelector(".composer-bar textarea") &&
        !document.querySelector(".composer-bar textarea").disabled,
    ),
  );
  if (!newTask) {
    const button = (
      await screen.findAllByRole("button", { name: /Submission task/ })
    )[0];
    fireEvent.click(button);
    await screen.findByRole("button", {
      name: "Task information",
      exact: true,
    });
  }
  const textarea = document.querySelector(".composer-bar textarea");
  return {
    textarea,
    snapshot,
    task,
    inputs,
    targets,
    operationIds,
    cancellations,
    creations: () => creations,
    createRequests,
    connectionGeneration: () => connectionGeneration,
    failRevision: async () =>
      act(async () => rejectRevision(new Error("malformed revision"))),
    publish: async () => {
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      await act(async () =>
        revision(snapshot.revision, snapshot.securityEpoch ?? "1"),
      );
    },
    created: async (createdTask = task, index = 0) =>
      act(async () =>
        createResolvers[index]({
          accepted: true,
          taskId: createdTask.id,
          bindingEpoch: createdTask.binding.epoch,
        }),
      ),
    rejectCreation: async (reason, blockingTaskId, index = 0) =>
      act(async () =>
        createResolvers[index]({
          accepted: false,
          taskId: null,
          bindingEpoch: null,
          mcpAuthority: null,
          reason,
          ...(blockingTaskId ? { blockingTaskId } : {}),
        }),
      ),
    loseCreationReply: async (index = 0) =>
      act(async () => createRejectors[index](new Error("creation reply lost"))),
    settle: async (result = { accepted: true }) =>
      act(async () => resolveRun(result)),
  };
}

test("App image paste shares staging, rejects overlapping paste and sends the latest draft with existing images", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  fixture.snapshot.capabilities.attachments.enabled = true;
  await fixture.publish();
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  const { AttachmentAddOperation } = await vite.ssrLoadModule(
    "/src/bridge/attachment-receive.ts",
  );
  const file = new File(["image bytes"], "capture.png", { type: "image/png" });
  const descriptor = (token, name) => ({
    token: token.repeat(48),
    kind: "image",
    format: "png",
    displayName: name,
    sizeBytes: String(file.size),
  });
  const operations = [];
  const sources = [];
  const chunks = [];
  let finishSecond;
  const second = new Promise((resolve) => {
    finishSecond = resolve;
  });
  ctx.mock.method(BridgeClient.prototype, "createAttachmentAdd", () => {
    const index = operations.length;
    const op = new AttachmentAddOperation(
      {
        begin: async (source) => {
          sources.push(source);
          return { status: "accepted" };
        },
        append: async (...chunk) => {
          chunks.push(chunk);
          return { status: "accepted" };
        },
        finish: async () =>
          index === 0
            ? { status: "ready", attachments: [descriptor("a", "first.png")] }
            : second,
        cancel: async () => ({ status: "cleaned", released: true }),
        recover: async () => assert.fail("No recovery expected"),
      },
      3,
    );
    operations.push(op);
    return op;
  });
  fireEvent.change(fixture.textarea, { target: { value: "old instruction" } });
  pasteItems(fixture.textarea, [imageItem(file)]);
  await screen.findByText("first.png");
  pasteItems(fixture.textarea, [imageItem(file)]);
  await waitFor(() => assert.equal(sources.length, 2));
  fireEvent.change(fixture.textarea, {
    target: { value: "new instruction while adding" },
  });
  pasteItems(fixture.textarea, [imageItem(file)]);
  assert.match(screen.getByRole("alert").textContent, /still being processed/);
  assert.equal(operations.length, 2);
  await act(async () =>
    finishSecond({
      status: "ready",
      attachments: [descriptor("b", "second.png")],
    }),
  );
  await screen.findByText("second.png");
  assert.equal(screen.queryByRole("alert"), null);
  assert.equal(fixture.textarea.value, "new instruction while adding");
  assert.ok(screen.getByText("first.png"));
  assert.ok(sources.every((source) => source.kind === "file_bytes"));
  assert.equal(chunks.length, 2 * Math.ceil(file.size / 3));
  assert.equal(
    screen.getByRole("button", { name: "Send", exact: true }).disabled,
    false,
  );
  fireEvent.click(screen.getByRole("button", { name: "Send", exact: true }));
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.deepEqual(fixture.inputs[0][2], {
    kind: "multimodal",
    text: "new instruction while adding",
    attachmentTokens: ["a".repeat(48), "b".repeat(48)],
  });
  await fixture.settle();
});

async function renderPendingPasteApp(ctx, options) {
  const fixture = await renderSubmissionApp(ctx, options);
  fixture.snapshot.capabilities.attachments.enabled = true;
  await fixture.publish();
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  const { AttachmentAddOperation } = await vite.ssrLoadModule(
    "/src/bridge/attachment-receive.ts",
  );
  let resolveFinish,
    finishing = false,
    cancellations = 0,
    additions = 0;
  const finished = new Promise((resolve) => {
    resolveFinish = resolve;
  });
  ctx.mock.method(BridgeClient.prototype, "createAttachmentAdd", () => {
    additions++;
    return new AttachmentAddOperation(
      {
        begin: async () => ({ status: "accepted" }),
        append: async () => ({ status: "accepted" }),
        finish: () => {
          finishing = true;
          return finished;
        },
        cancel: async () => {
          cancellations++;
          return { status: "cleaned", released: true };
        },
        recover: async () => assert.fail("No connection recovery expected"),
      },
      3,
    );
  });
  const file = new File(["image"], "pending.png", { type: "image/png" });
  const attachment = {
    token: "c".repeat(48),
    kind: "image",
    format: "png",
    displayName: file.name,
    sizeBytes: String(file.size),
  };
  return {
    ...fixture,
    begin: async () => {
      pasteItems(fixture.textarea, [imageItem(file)]);
      await waitFor(() => assert.ok(finishing));
    },
    finish: async () =>
      act(async () =>
        resolveFinish({ status: "ready", attachments: [attachment] }),
      ),
    cancellations: () => cancellations,
    additions: () => additions,
    attachment,
  };
}

test("App image paste reports unavailable attachments without starting a writer", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { attachmentsEnabled: false });
  assert.ok(screen.queryByRole("button", { name: "Add files" }) === null);
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  ctx.mock.method(BridgeClient.prototype, "createAttachmentAdd", () =>
    assert.fail("Unavailable attachments must not reserve resources"),
  );
  const file = new File(["png"], "a.png", { type: "image/png" });
  const event = pasteItems(fixture.textarea, [imageItem(file)]);
  assert.equal(event.defaultPrevented, true);
  assert.match(screen.getByRole("alert").textContent, /cannot be added/);
  assert.equal(BridgeClient.prototype.createAttachmentAdd.mock.callCount(), 0);
  assert.equal(fixture.inputs.length, 0);
});

test("App cancelled image paste preserves edits and ignores a late ready result", async (ctx) => {
  const f = await renderPendingPasteApp(ctx);
  fireEvent.change(f.textarea, { target: { value: "keep original draft" } });
  await f.begin();
  fireEvent.change(f.textarea, { target: { value: "edited during staging" } });
  fireEvent.click(screen.getByRole("button", { name: "Cancel adding files" }));
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Add files" }).disabled,
      false,
    ),
  );
  await f.finish();
  assert.equal(f.cancellations(), 1);
  assert.equal(f.textarea.value, "edited during staging");
  assert.equal(screen.queryByText("pending.png"), null);
  assert.equal(f.inputs.length, 0);
});

test("App image paste cannot hand off to a Task after leaving and returning", async (ctx) => {
  const f = await renderPendingPasteApp(ctx);
  const other = structuredClone(f.task);
  other.id = String(BigInt(f.task.id) + 1n);
  other.title = "Other paste task";
  f.snapshot.tasks.push(other);
  await f.publish();
  fireEvent.change(f.textarea, { target: { value: "source Task draft" } });
  await f.begin();
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Other paste task/ }))[0],
  );
  await waitFor(() =>
    assert.equal(document.querySelector(".composer-bar textarea").value, ""),
  );
  fireEvent.change(document.querySelector(".composer-bar textarea"), {
    target: { value: "other Task draft" },
  });
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Submission task/ }))[0],
  );
  await waitFor(() =>
    assert.equal(
      document.querySelector(".composer-bar textarea").value,
      "source Task draft",
    ),
  );
  await f.finish();
  assert.equal(f.cancellations(), 1);
  assert.equal(screen.queryByText("pending.png"), null);
  assert.equal(f.inputs.length, 0);
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Other paste task/ }))[0],
  );
  assert.equal(
    document.querySelector(".composer-bar textarea").value,
    "other Task draft",
  );
  assert.equal(screen.queryByText("pending.png"), null);
});

test("App image-only paste sends through the existing multimodal Run input", async (ctx) => {
  const f = await renderPendingPasteApp(ctx);
  assert.equal(f.textarea.value, "");
  await f.begin();
  await f.finish();
  await screen.findByText("pending.png");
  const send = screen.getByRole("button", { name: "Send", exact: true });
  assert.equal(send.disabled, false);
  fireEvent.click(send);
  await waitFor(() => assert.equal(f.inputs.length, 1));
  assert.deepEqual(f.inputs[0][2], {
    kind: "multimodal",
    text: "",
    attachmentTokens: [f.attachment.token],
  });
  await f.settle();
});

for (const method of ["Enter", "click"]) {
  test(`App ${method} send keeps the editor focused and preserves edits before acknowledgement`, async (ctx) => {
    const fixture = await renderSubmissionApp(ctx);
    const user = userEvent.setup({ document });
    await user.type(fixture.textarea, "first instruction");
    if (method === "Enter") await user.keyboard("{Enter}");
    else
      await user.click(
        screen.getByRole("button", { name: "Send", exact: true }),
      );
    assert.equal(fixture.inputs.length, 1);
    assert.equal(fixture.textarea.disabled, false);
    assert.equal(document.activeElement, fixture.textarea);
    await user.clear(fixture.textarea);
    await user.type(fixture.textarea, "next instruction{Enter}");
    assert.equal(
      fixture.inputs.length,
      2,
      "the next explicit message must not wait for the first reply",
    );
    await user.type(fixture.textarea, "third unsent draft");
    await fixture.settle();
    await waitFor(() =>
      assert.equal(
        screen.getByRole("button", { name: "Send", exact: true }).disabled,
        false,
      ),
    );
    assert.equal(fixture.textarea.value, "third unsent draft");
    assert.equal(document.activeElement, fixture.textarea);
  });
}

test("App first send preserves the textarea, caret and IME composition across Task creation", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  assert.equal(fixture.creations(), 1);
  assert.equal(fixture.textarea.disabled, false);
  await user.clear(fixture.textarea);
  await user.type(fixture.textarea, "next draft");
  await fixture.created();
  assert.equal(fixture.creations(), 1);
  fireEvent.compositionStart(fixture.textarea);
  fixture.textarea.setSelectionRange(3, 3);
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() =>
    assert.equal(
      document.querySelector(".workbench-view").dataset.view,
      "task",
    ),
  );
  assert.equal(
    document.querySelector(".composer-bar textarea"),
    fixture.textarea,
  );
  assert.equal(fixture.textarea.value, "next draft");
  assert.equal(fixture.textarea.selectionStart, 3);
  assert.equal(document.activeElement, fixture.textarea);
  await fixture.settle();
  assert.equal(fixture.textarea.value, "next draft");
  // Retaining the Composer instance also retains its in-progress IME latch.
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 1);
  fireEvent.compositionEnd(fixture.textarea);
});

test("App acknowledgement clears only the submitted draft and never steals outside focus", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  const outside = screen.getByRole("button", { name: "New task", exact: true });
  outside.focus();
  await fixture.settle();
  await waitFor(() => assert.equal(fixture.textarea.value, ""));
  assert.equal(document.activeElement, outside);
});

test("App rejected send preserves the latest edit and allows a deliberate retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await user.clear(fixture.textarea);
  await user.type(fixture.textarea, "revised instruction");
  await fixture.settle({ accepted: false, reason: "catalog_loading" });
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Send", exact: true }).disabled,
      false,
    ),
  );
  assert.equal(fixture.textarea.value, "revised instruction");
  assert.equal(document.activeElement, fixture.textarea);
});

test("App first accepted send clears its original version after Task handoff without losing focus", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle();
  await waitFor(() => assert.equal(fixture.textarea.value, ""));
  assert.equal(
    document.querySelector(".composer-bar textarea"),
    fixture.textarea,
  );
  assert.equal(document.activeElement, fixture.textarea);
  assert.equal(fixture.textarea.disabled, false);
  await user.type(fixture.textarea, "follow-up");
  assert.equal(fixture.textarea.value, "follow-up");
});

for (const catalogFirst of [true, false]) {
  test(`App reselects a disabled model after creation rejection with catalog ${catalogFirst ? "before" : "after"} the reply`, async (ctx) => {
    const fixture = await renderSubmissionApp(ctx, { newTask: true });
    const user = userEvent.setup({ document });
    const provider = fixture.snapshot.models.providers[0];
    const original = provider.models[0];
    provider.models.push({
      ...original,
      id: "replacement",
      displayName: "Replacement model",
    });
    await fixture.publish();
    await user.type(fixture.textarea, "Original instruction{Enter}");
    await waitFor(() => assert.equal(fixture.creations(), 1));

    const disableModel = async () => {
      provider.models = provider.models.filter(
        (model) => model.id !== original.id,
      );
      provider.catalogGeneration = String(
        BigInt(provider.catalogGeneration) + 1n,
      );
      Object.assign(fixture.snapshot.newTaskAdmission, {
        available: true,
        reason: "none",
      });
      await fixture.publish();
    };
    if (catalogFirst) await disableModel();
    await fixture.rejectCreation("execution_unavailable");
    if (!catalogFirst) await disableModel();

    const selector = await screen.findByRole("combobox", { name: "Model" });
    await waitFor(() => assert.equal(selector.textContent, original.id));
    assert.equal(selector.disabled, false);
    assert.equal(
      screen.getByRole("combobox", { name: "Switch workspace" }).disabled,
      false,
    );
    assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
    assert.ok(screen.getByText("Original instruction"));
    assert.equal(fixture.inputs.length, 0);
    assert.equal(fixture.creations(), 1);

    await user.click(selector);
    await user.click(
      await screen.findByRole("option", { name: "Replacement model" }),
    );
    await user.click(screen.getByRole("button", { name: "Copy to input box" }));
    assert.equal(fixture.textarea.value, "Original instruction");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await waitFor(() => assert.equal(fixture.creations(), 2));
    assert.deepEqual(fixture.createRequests[1], [
      { kind: "automatic" },
      {
        targetModelRef: { sourceId: provider.id, modelId: "replacement" },
        expectedSourceGeneration: provider.sourceGeneration,
        expectedCatalogGeneration: provider.catalogGeneration,
      },
      null,
      null,
      "auto_review",
    ]);
    await fixture.created(fixture.task, 1);
    await waitFor(() => assert.equal(fixture.inputs.length, 1));
    assert.equal(fixture.inputs[0][2].text, "Original instruction");
    await fixture.settle();
  });
}

test("App shared creation rejection preserves later edits and permits one explicit retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  for (const text of [
    "First rejected instruction",
    "Second rejected instruction",
  ]) {
    fireEvent.change(fixture.textarea, { target: { value: text } });
    fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  }
  assert.equal(fixture.creations(), 1);
  await user.type(fixture.textarea, "Newer unsent draft");
  await fixture.rejectCreation("execution_unavailable");
  const selector = await screen.findByRole("combobox", { name: "Model" });
  assert.equal(selector.disabled, false);
  assert.ok(screen.getByText("First rejected instruction"));
  assert.ok(screen.getByText("Second rejected instruction"));
  assert.equal(fixture.inputs.length, 0);
  assert.equal(fixture.creations(), 1);
  assert.equal(document.activeElement, fixture.textarea);
  await user.click(
    screen.getAllByRole("button", { name: "Copy to input box" })[0],
  );
  assert.equal(fixture.textarea.value, "Newer unsent draft");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "Newer unsent draft");
  await fixture.settle();
});

test("App creation retry captures another source and the newly selected Workspace", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  const model = fixture.snapshot.models.providers[0].models[0];
  await user.click(screen.getByRole("combobox", { name: "Model" }));
  await user.click(
    await screen.findByRole("option", { name: model.displayName }),
  );
  await user.type(fixture.textarea, "Selected official model{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  assert.equal(fixture.createRequests[0][1].targetModelRef.sourceId, "metask");
  await fixture.rejectCreation("stale_catalog");

  fixture.snapshot.models.providers[0].models = [];
  fixture.snapshot.models.providers[0].errorCode = "no_models";
  fixture.snapshot.models.customProviders = [
    {
      id: "custom-replacement",
      builtinProviderId: null,
      displayName: "Custom",
      protocol: "anthropic_messages",
      normalizedBaseUrl: "https://custom.example.com/v1/messages",
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      providerRevision: "2",
      sourceGeneration: "23",
      catalogGeneration: "29",
      models: [
        {
          ...model,
          id: "custom-model",
          displayName: "Custom replacement",
          ready: true,
          testStatus: "connected",
        },
      ],
    },
  ];
  fixture.snapshot.workspaces[0].epoch = "2";
  await fixture.publish();
  await user.click(await screen.findByRole("combobox", { name: "Model" }));
  await user.click(
    await screen.findByRole("option", { name: "Custom replacement" }),
  );
  await selectManualSubmissionWorkspace(user);
  await user.type(fixture.textarea, "Use new configuration{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 2));
  assert.deepEqual(fixture.createRequests[1], [
    {
      kind: "manual",
      workspaceId: fixture.snapshot.workspaces[0].id,
      expectedWorkspaceEpoch: "2",
    },
    {
      targetModelRef: {
        sourceId: "custom-replacement",
        modelId: "custom-model",
      },
      expectedSourceGeneration: "23",
      expectedCatalogGeneration: "29",
    },
    null,
    null,
    "auto_review",
  ]);
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "Use new configuration");
  await fixture.settle();
});

test("App unknown creation retains identity and never implicitly creates another Task", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "Unknown first instruction{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await fixture.loseCreationReply();
  assert.equal(screen.queryByRole("combobox", { name: "Model" }), null);
  assert.ok(document.querySelector(".composer-model-readonly"));
  await user.type(fixture.textarea, "Later explicit instruction{Enter}");
  await waitFor(() =>
    assert.ok(screen.getByText("Later explicit instruction")),
  );
  assert.equal(fixture.creations(), 1);
  assert.equal(fixture.inputs.length, 0);
  assert.ok(screen.getByText("Unknown first instruction"));
});

test("App old creation rejection cannot unlock a newer pending creation", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  const original = fixture.snapshot.models.providers[0].models[0];
  await user.click(screen.getByRole("combobox", { name: "Model" }));
  await user.click(
    await screen.findByRole("option", { name: original.displayName }),
  );
  await user.type(fixture.textarea, "Old pending creation{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await user.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  await screen.findByRole("combobox", { name: "Model" });
  await user.type(fixture.textarea, "New pending creation{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await user.type(fixture.textarea, "Draft after new creation");
  await fixture.rejectCreation("execution_unavailable", undefined, 0);
  assert.equal(screen.queryByRole("combobox", { name: "Model" }), null);
  assert.equal(fixture.textarea.value, "Draft after new creation");
  assert.equal(document.activeElement, fixture.textarea);
  assert.equal(fixture.creations(), 2);
  await fixture.created(fixture.task, 1);
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "New pending creation");
  assert.equal(fixture.textarea.value, "Draft after new creation");
  await fixture.settle();
});

test("App send rejection keeps the created Task identity for a later send", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "First send{Enter}");
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle({ accepted: false, reason: "capacity_reached" });
  await user.type(fixture.textarea, "Later send{Enter}");
  await waitFor(() => assert.equal(fixture.inputs.length, 2));
  assert.equal(fixture.creations(), 1);
  assert.ok(
    fixture.targets.every((target) => target.taskId === fixture.task.id),
  );
});

test("App rejected creation restores attachment text without reusing staged tokens", async (ctx) => {
  const fixture = await renderPendingPasteApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "Instruction with attachment");
  await fixture.begin();
  await fixture.finish();
  await screen.findByText(fixture.attachment.displayName);
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await fixture.rejectCreation("execution_unavailable");
  await screen.findByRole("combobox", { name: "Model" });
  await user.click(screen.getByRole("button", { name: "Copy to input box" }));
  assert.equal(fixture.textarea.value, "Instruction with attachment");
  assert.ok(screen.getByText(/Add them again before sending/));
  assert.equal(fixture.additions(), 1);
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.deepEqual(fixture.inputs[0][2], {
    kind: "text",
    text: "Instruction with attachment",
  });
  await fixture.settle();
});

test("App cancelled creation can reselect only after Host definitively rejects it", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "Cancel before creation reply{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await user.click(screen.getByRole("button", { name: "Stop task" }));
  await screen.findByText("Stopped");
  assert.equal(screen.queryByRole("combobox", { name: "Model" }), null);
  await fixture.rejectCreation("execution_unavailable");
  const selector = await screen.findByRole("combobox", { name: "Model" });
  assert.equal(selector.disabled, false);
  assert.equal(fixture.creations(), 1);
  assert.equal(fixture.inputs.length, 0);
});

test("App releases rejected identity before the follow-up Snapshot finishes", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "Reject with delayed refresh{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  let releaseRead;
  const delayed = new Promise((resolve) => {
    releaseRead = resolve;
  });
  ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", async (scope) => {
    await delayed;
    return productStateFixture(fixture.snapshot, scope);
  });
  try {
    await fixture.rejectCreation("execution_unavailable");
    const selector = await screen.findByRole("combobox", { name: "Model" });
    assert.equal(selector.disabled, false);
    assert.equal(fixture.creations(), 1);
    assert.equal(fixture.inputs.length, 0);
  } finally {
    await act(async () => releaseRead());
  }
});

test("App empty catalog after creation rejection keeps input and exposes catalog recovery", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "No replacement available{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  fixture.snapshot.models.providers[0].models = [];
  fixture.snapshot.models.providers[0].errorCode = "no_models";
  fixture.snapshot.newTaskAdmission.available = false;
  await fixture.publish();
  await fixture.rejectCreation("execution_unavailable");
  const recovery = await screen.findByRole("button", {
    name: "Retry",
    exact: true,
  });
  assert.equal(recovery.disabled, false);
  assert.equal(screen.queryByRole("combobox", { name: "Model" }), null);
  await user.click(screen.getByRole("button", { name: "Copy to input box" }));
  assert.equal(fixture.textarea.value, "No replacement available");
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  assert.equal(fixture.creations(), 1);
  assert.equal(fixture.inputs.length, 0);
});

test("App previous-generation rejection cannot disturb a new connection's creation", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "Old connection creation{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await fixture.failRevision();
  await user.click(
    await screen.findByRole("button", { name: "Retry syncing", exact: true }),
  );
  await waitFor(() => assert.equal(fixture.connectionGeneration(), 2));
  await screen.findByRole("combobox", { name: "Model" });
  await user.type(fixture.textarea, "New connection creation{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.rejectCreation("execution_unavailable", undefined, 0);
  assert.equal(screen.queryByRole("combobox", { name: "Model" }), null);
  assert.equal(fixture.creations(), 2);
  assert.equal(fixture.inputs.length, 0);
  await fixture.created(fixture.task, 1);
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "New connection creation");
  await fixture.settle();
});

test("App new Task lists all Providers while existing Tasks preserve their source and actual Run model", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const provider = fixture.snapshot.models.providers[0];
  const model = provider.models[0];
  provider.models = [
    { ...model, id: "minimax-m3", displayName: "minimax-m3" },
    { ...model, id: "glm-5.3-flash", displayName: "glm-5.3-flash" },
    {
      ...model,
      id: "DeepSeek-V4.1-Flash-1017",
      displayName: "DeepSeek-V4.1-Flash-1017",
    },
    { ...model, id: "kimi-k3.1-pro", displayName: "kimi-k3.1-pro" },
  ];
  fixture.snapshot.models.customProviders = [
    {
      id: "cc",
      builtinProviderId: null,
      displayName: "cc",
      protocol: "anthropic_messages",
      normalizedBaseUrl: "https://custom.example.com/v1",
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      providerRevision: "1",
      sourceGeneration: "23",
      catalogGeneration: "29",
      models: [
        {
          ...model,
          id: "gpt-5.6-sol",
          displayName: "gpt-5.6-sol",
          ready: true,
          testStatus: "connected",
        },
      ],
    },
  ];
  const defaultModel = { sourceId: "metask", modelId: "minimax-m3" };
  fixture.snapshot.models.defaultSelection = defaultModel;
  await fixture.publish();
  const selector = screen.getByRole("combobox", { name: "Model" });
  await waitFor(() => assert.match(selector.textContent, /minimax-m3/));
  assert.equal(
    selector.querySelector(".model-vendor-icon")?.dataset.vendor,
    "minimax",
  );
  const user = userEvent.setup({ document });
  await user.click(selector);
  const customOption = await screen.findByRole("option", {
    name: /gpt-5.6-sol/,
  });
  assert.equal(customOption.textContent, "gpt-5.6-sol");
  assert.equal(
    customOption.querySelector(".model-vendor-icon")?.dataset.vendor,
    "custom",
  );
  const customGroup = screen.getByRole("group", { name: "Custom models" });
  assert.equal(customOption.closest('[role="group"]'), customGroup);
  assert.equal(customGroup.querySelector("small"), null);
  for (const [name, vendor] of [
    ["minimax-m3", "minimax"],
    ["glm-5.3-flash", "glm"],
    ["DeepSeek-V4.1-Flash-1017", "deepseek"],
    ["kimi-k3.1-pro", "kimi"],
  ]) {
    assert.equal(
      screen
        .getByRole("option", { name, exact: true })
        .querySelector(".model-vendor-icon")?.dataset.vendor,
      vendor,
    );
  }
  assert.deepEqual(
    screen
      .getAllByRole("option")
      .map(
        (option) =>
          option.querySelector(".selection-menu-item-copy").textContent,
      ),
    [
      "minimax-m3",
      "glm-5.3-flash",
      "DeepSeek-V4.1-Flash-1017",
      "kimi-k3.1-pro",
      "gpt-5.6-sol",
    ],
  );
  await user.click(customOption);
  await waitFor(() =>
    assert.equal(
      document.querySelector(".composer-model-trigger").textContent,
      "gpt-5.6-sol",
    ),
  );
  assert.equal(
    selector.querySelector(".model-vendor-icon")?.dataset.vendor,
    "custom",
  );
  assert.deepEqual(fixture.snapshot.models.defaultSelection, defaultModel);
  await user.click(selector);
  await user.click(
    await screen.findByRole("option", { name: /glm-5.3-flash/ }),
  );
  assert.equal(
    selector.querySelector(".model-vendor-icon")?.dataset.vendor,
    "glm",
  );
  await user.type(fixture.textarea, "How can we forecast the weather?{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  assert.deepEqual(
    BridgeClient.prototype.createTask.mock.calls[0].arguments[1],
    {
      targetModelRef: { sourceId: "metask", modelId: "glm-5.3-flash" },
      expectedSourceGeneration: provider.sourceGeneration,
      expectedCatalogGeneration: provider.catalogGeneration,
    },
  );
  fixture.task.binding.model = "glm-5.3-flash";
  fixture.task.modelIntent = {
    modelRef: { sourceId: "metask", modelId: "glm-5.3-flash" },
    selectionRevision: "1",
    state: "committed",
  };
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  const { readFile } = await import("node:fs/promises");
  const run = JSON.parse(
    await readFile(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  ).tasks[0].runs[0];
  run.execution.model = "glm-5.3-flash";
  fixture.task.activeOperation = { kind: "run", id: run.id };
  fixture.task.currentRunId = run.id;
  fixture.task.currentRunPhase = run.phase;
  fixture.task.runs = [run];
  await fixture.settle();
  await fixture.publish();
  await waitFor(() => {
    const label = document.querySelector(".composer-model-trigger").textContent;
    assert.equal(label, "glm-5.3-flash");
    assert.doesNotMatch(label, /Next run/);
  });
  ctx.mock.method(
    BridgeClient.prototype,
    "selectTaskModel",
    async (_taskId, _revision, modelRef) => {
      fixture.task.modelIntent = {
        modelRef,
        selectionRevision: "2",
        state: "committed",
      };
      return {
        accepted: true,
        taskId: fixture.task.id,
        selectionRevision: "2",
        reason: null,
      };
    },
  );
  fixture.snapshot.models.defaultSelection = {
    sourceId: "cc",
    modelId: "gpt-5.6-sol",
  };
  await fixture.publish();
  await user.click(screen.getByRole("combobox", { name: "Model" }));
  assert.equal(screen.queryByRole("option", { name: /gpt-5.6-sol/ }), null);
  await user.click(await screen.findByRole("option", { name: /minimax-m3/ }));
  await waitFor(() => {
    const label = document.querySelector(".composer-model-trigger").textContent;
    assert.equal(label, "minimax-m3");
    assert.doesNotMatch(label, /Next run/);
  });
  await user.click(screen.getByRole("button", { name: "Task information" }));
  const fact = screen.getByText("Current run model").parentElement;
  assert.equal(fact.querySelector("dd").textContent, "glm-5.3-flash");
  assert.equal(
    screen.getByText("Selected provider").parentElement.querySelector("dd")
      .textContent,
    "Metask",
  );
  assert.equal(
    screen.getByText("Current run protocol").parentElement.querySelector("dd")
      .textContent,
    "Anthropic Messages",
  );
  await user.keyboard("{Escape}");
  assert.deepEqual(fixture.snapshot.models.defaultSelection, {
    sourceId: "cc",
    modelId: "gpt-5.6-sol",
  });
  await user.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  await user.click(screen.getByRole("combobox", { name: "Model" }));
  assert.ok(await screen.findByRole("option", { name: /minimax-m3/ }));
  assert.ok(screen.getByRole("option", { name: /glm-5.3-flash/ }));
  assert.deepEqual(
    screen
      .getAllByRole("option")
      .map(
        (option) =>
          option.querySelector(".selection-menu-item-copy").textContent,
      ),
    [
      "minimax-m3",
      "glm-5.3-flash",
      "DeepSeek-V4.1-Flash-1017",
      "kimi-k3.1-pro",
      "gpt-5.6-sol",
    ],
  );
  await user.click(screen.getByRole("option", { name: /gpt-5.6-sol/ }));
  await waitFor(() =>
    assert.equal(
      document.querySelector(".composer-model-trigger").textContent,
      "gpt-5.6-sol",
    ),
  );
  await user.type(fixture.textarea, "Use my custom Provider{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 2));
  assert.deepEqual(
    BridgeClient.prototype.createTask.mock.calls[1].arguments[1],
    {
      targetModelRef: { sourceId: "cc", modelId: "gpt-5.6-sol" },
      expectedSourceGeneration: "23",
      expectedCatalogGeneration: "29",
    },
  );
  assert.deepEqual(fixture.snapshot.models.defaultSelection, {
    sourceId: "cc",
    modelId: "gpt-5.6-sol",
  });
});

test("App late send result preserves another Task's draft and focus", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx);
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await user.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  const next = document.querySelector(".composer-bar textarea");
  await user.type(next, "different task draft");
  await fixture.settle();
  assert.equal(next.value, "different task draft");
  assert.equal(document.activeElement, next);
});

test("App leaving Task creation keeps the submitted target and preserves the other draft", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await user.type(fixture.textarea, "first instruction{Enter}");
  await fixture.created();
  const other = {
    ...structuredClone(fixture.task),
    id: "4",
    title: "Other task",
  };
  fixture.snapshot.tasks = [other];
  await fixture.publish();
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Other task/ }))[0],
  );
  await user.type(
    document.querySelector(".composer-bar textarea"),
    "other task draft",
  );
  fixture.snapshot.tasks.push(fixture.task);
  await fixture.publish();
  assert.equal(fixture.inputs.length, 1);
  assert.equal(
    document.querySelector(".composer-bar textarea").value,
    "other task draft",
  );
  const { readNewTaskDraft, unscopedNewTaskDraftId } = await vite.ssrLoadModule(
    "/src/features/composer/drafts.ts",
  );
  assert.equal(readNewTaskDraft(unscopedNewTaskDraftId).text, "");
});

test("App sends to the current Run without preparation and shows Stop when its busy draft is cleared", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  const editor = fixture.textarea;
  fireEvent.change(editor, { target: { value: "new constraint" } });
  fireEvent.keyDown(editor, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.deepEqual(fixture.targets, [{ taskId: fixture.task.id }]);
  assert.equal(fixture.creations(), 0);
  fireEvent.change(editor, { target: { value: "newer unsent intent" } });
  assert.equal(screen.queryByRole("button", { name: "Stop task" }), null);
  assert.ok(screen.getByRole("button", { name: "Send" }));
  fireEvent.change(editor, { target: { value: "" } });
  const stop = screen.getByRole("button", { name: "Stop task" });
  assert.equal(stop.disabled, false);
  fireEvent.click(stop);
  await waitFor(() => assert.equal(fixture.cancellations.length, 1));
  fireEvent.change(editor, { target: { value: "newer unsent intent" } });
  await fixture.settle();
  assert.equal(editor.value, "newer unsent intent");
  assert.equal(fixture.inputs.length, 1);
});

test("App double Escape uses the existing Task stop path and preserves an unsent draft", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  fireEvent.change(fixture.textarea, { target: { value: "keep this unsent" } });
  fixture.textarea.focus();
  fireEvent.keyDown(fixture.textarea, { key: "Escape" });
  assert.deepEqual(fixture.cancellations, []);
  fireEvent.keyDown(fixture.textarea, { key: "Escape", repeat: true });
  assert.deepEqual(fixture.cancellations, []);
  fireEvent.keyDown(fixture.textarea, { key: "Escape" });
  await waitFor(() =>
    assert.deepEqual(fixture.cancellations, [[fixture.task.id]]),
  );
  fireEvent.keyDown(fixture.textarea, { key: "Escape" });
  fireEvent.keyDown(fixture.textarea, { key: "Escape" });
  assert.equal(fixture.cancellations.length, 1);
  assert.equal(fixture.textarea.value, "keep this unsent");
  assert.deepEqual(fixture.inputs, []);
});

test("App double Escape cancels delayed creation without consuming a later instruction", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "cancel before identity" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  fireEvent.keyDown(fixture.textarea, { key: "Escape" });
  assert.equal(screen.queryByText("Stopped"), null);
  fireEvent.keyDown(fixture.textarea, { key: "Escape" });
  await screen.findByText("Stopped");
  fireEvent.change(fixture.textarea, { target: { value: "later intent" } });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await fixture.created();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "later intent");
  await fixture.settle();
});

test("App sends while the Run is not ready and keeps later drafts independent", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, {
    active: true,
    inputReady: false,
  });
  fireEvent.change(fixture.textarea, { target: { value: "A" } });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 1);
  assert.equal(fixture.textarea.value, "");
  fireEvent.change(fixture.textarea, { target: { value: "B" } });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 2);
  assert.equal(fixture.textarea.value, "");
  fireEvent.change(fixture.textarea, { target: { value: "unsent C" } });
  await fixture.settle();
  assert.equal(fixture.textarea.value, "unsent C");
  assert.equal(fixture.inputs.length, 2);
});

function finishWithPendingContinuation(fixture) {
  const run = fixture.task.runs[0];
  Object.assign(run, {
    phase: "completed",
    activity: null,
    terminal: {
      outcome: "completed",
      cause: null,
      diagnosticDisposition: "absent",
      recordingIncomplete: false,
      modelError: null,
    },
    additionalInputs: [
      {
        submission: null,
        id: "1",
        afterOutputCount: 0,
        operationId: "already-submitted",
        text: "submitted follow up",
        redacted: false,
        sequence: 1,
        adoptedTurn: null,
        order: null,
        state: "continuing",
        transferredToRunId: null,
        continuationReason: null,
      },
    ],
  });
  Object.assign(fixture.task, {
    activeOperation: null,
    currentRunPhase: null,
    inputReady: false,
    continuationAvailable: false,
    continuationRecoveryAvailable: false,
  });
  return run;
}

test("App can Stop a completed source while its continuation is reserved", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  const source = finishWithPendingContinuation(fixture);
  await fixture.publish();
  await waitFor(() => assert.ok(screen.getByText("submitted follow up")));
  assert.equal(fixture.textarea.disabled, false);
  assert.equal(
    screen.queryByRole("button", { name: "Put back in the editor" }),
    null,
  );
  const stop = screen.getByRole("button", { name: "Stop task" });
  assert.equal(stop.disabled, false);
  fireEvent.click(stop);
  await waitFor(() =>
    assert.deepEqual(fixture.cancellations, [[fixture.task.id]]),
  );
  assert.deepEqual(fixture.inputs, []);
});

test("App accepts a new message during continuation cleanup", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  finishWithPendingContinuation(fixture);
  await fixture.publish();
  fireEvent.change(fixture.textarea, {
    target: { value: "new explicit intent" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 1);
  assert.deepEqual(fixture.targets, [{ taskId: fixture.task.id }]);
  await fixture.settle();
  assert.equal(fixture.textarea.value, "");
});
test("App accepts text while a Skill Run is active", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, {
    active: true,
    inputReady: false,
  });
  fixture.task.runs[0].input = {
    kind: "skill",
    skillId: "review",
    catalogRevision: "1",
    invocationName: "review",
    displayName: "Review",
    argumentValues: [],
    redacted: false,
  };
  await fixture.publish();
  fireEvent.change(fixture.textarea, { target: { value: "new constraint" } });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.inputs.length, 1);
  await fixture.settle();
  assert.equal(fixture.textarea.value, "");
});

test("App keeps the current Run draft editable through a transient snapshot failure without submitting on recovery", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  const editor = fixture.textarea;
  fireEvent.change(editor, {
    target: { value: "unsent before transport loss" },
  });
  editor.focus();
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  let reads = 0;
  let releaseRead;
  const recovered = new Promise((resolve) => {
    releaseRead = resolve;
  });
  ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", async (scope) => {
    if (++reads === 1) throw new Error("snapshot temporarily unavailable");
    await recovered;
    return productStateFixture(fixture.snapshot, scope);
  });
  try {
    await fixture.publish();
    await waitFor(() =>
      assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true),
    );
    assert.equal(editor.disabled, false);
    assert.equal(document.activeElement, editor);
    fireEvent.change(editor, { target: { value: "newer unsent constraint" } });
    fireEvent.keyDown(editor, { key: "Enter" });
    assert.equal(fixture.inputs.length, 0);
    await act(async () => releaseRead());
    await waitFor(() =>
      assert.equal(
        screen.getByRole("button", { name: "Send" }).disabled,
        false,
      ),
    );
    assert.equal(editor.value, "newer unsent constraint");
    assert.equal(document.activeElement, editor);
    assert.equal(fixture.inputs.length, 0);
  } finally {
    releaseRead();
  }
});

test("App uncertain submission is retained as a message and never replays on completion", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "possibly submitted" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle(new Error("response lost"));
  assert.equal(fixture.textarea.value, "");
  assert.ok(screen.getByText(/Submission is unconfirmed/));
  fixture.task.activeOperation = null;
  fixture.task.currentRunPhase = "completed";
  fixture.task.inputReady = false;
  Object.assign(fixture.task.runs[0], {
    phase: "completed",
    activity: null,
    terminal: {
      outcome: "completed",
      cause: null,
      diagnosticDisposition: "absent",
      recordingIncomplete: false,
      modelError: null,
    },
  });
  await fixture.publish();
  assert.equal(fixture.inputs.length, 1);
  assert.equal(fixture.textarea.value, "");
});

test("App resolves a late canonical input receipt without erasing a newer draft or resending", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "original uncertain input" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  await fixture.settle(new Error("response lost"));
  await screen.findAllByText(/Submission is unconfirmed/);
  fireEvent.change(fixture.textarea, {
    target: { value: "newer unsent draft" },
  });
  fixture.task.inputSubmissions = [
    {
      submission: {
        operationId: fixture.operationIds[0],
        receivedAtUnixMs: null,
        presentationOrder: null,
        anchorRunId: fixture.task.currentRunId,
        afterOutputCount: 0,
      },
      input: {
        kind: "text",
        text: "original uncertain input",
        redacted: false,
      },
      state: "waiting",
      reason: null,
    },
  ];
  await fixture.publish();
  await waitFor(() =>
    assert.equal(screen.queryAllByText(/Submission is unconfirmed/).length, 0),
  );
  assert.equal(fixture.textarea.value, "newer unsent draft");
  assert.equal(fixture.inputs.length, 1);
});

test("App idle follow-up addresses only Task when currentRunId is zero", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  const previous = fixture.task.runs[0].id;
  fixture.task.activeOperation = null;
  fixture.task.currentRunId = "0";
  fixture.task.currentRunPhase = null;
  fixture.task.inputReady = false;
  Object.assign(fixture.task.runs[0], {
    phase: "completed",
    activity: null,
    terminal: {
      outcome: "completed",
      cause: null,
      diagnosticDisposition: "absent",
      recordingIncomplete: false,
      modelError: null,
    },
  });
  await fixture.publish();
  await waitFor(() =>
    assert.equal(
      document.querySelector(".ai-composer")?.getAttribute("data-state"),
      "normal",
    ),
  );
  fireEvent.change(fixture.textarea, {
    target: { value: "Explicit next Run" },
  });
  await waitFor(() =>
    assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false),
  );
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.deepEqual(fixture.targets, [{ taskId: fixture.task.id }]);
  await fixture.settle();
  assert.equal(fixture.textarea.value, "");
});

test("late creation does not select a newly opened draft", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "old submitted intent" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  fireEvent.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  fireEvent.change(fixture.textarea, { target: { value: "new unsent draft" } });
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  assert.equal(
    document.querySelector(".workbench-view").dataset.view,
    "new-task",
  );
  assert.equal(fixture.textarea.value, "new unsent draft");
  assert.equal(fixture.inputs.length, 1);
  await fixture.settle();
});

test("stop during delayed creation immediately marks the local message and still accepts a later send", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "cancel before identity" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  await screen.findByText("Stopped");
  fireEvent.change(fixture.textarea, {
    target: { value: "new intent after stop" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 1);
  await fixture.created();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "new intent after stop");
  await fixture.settle();
});

test("pending Task identity keeps later input independent of a changed new-Task default", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fireEvent.change(fixture.textarea, { target: { value: "first intent" } });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  fixture.snapshot.newTaskAdmission.available = false;
  await fixture.publish();
  fireEvent.change(fixture.textarea, { target: { value: "second intent" } });
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false);
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 1);
  await fixture.created();
  await waitFor(() => assert.equal(fixture.inputs.length, 2));
  await fixture.settle();
});

async function selectManualSubmissionWorkspace(user) {
  fireEvent.keyDown(
    screen.getByRole("combobox", { name: "Switch workspace" }),
    { key: "ArrowDown" },
  );
  await user.click(
    await screen.findByRole("option", { name: /\/tmp\/metawork-test/ }),
  );
}

test("App creates a separate Task when the same Workspace is used for another new task", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await selectManualSubmissionWorkspace(user);
  fireEvent.change(fixture.textarea, { target: { value: "first Task input" } });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  await fixture.settle();

  fireEvent.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  await selectManualSubmissionWorkspace(user);
  fireEvent.change(fixture.textarea, {
    target: { value: "second Task input" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 2);
  assert.equal(fixture.inputs.length, 1);

  const secondTask = {
    ...structuredClone(fixture.task),
    id: "4",
    title: "Second task",
  };
  await fixture.created(secondTask, 1);
  assert.deepEqual(fixture.targets, [
    { taskId: fixture.task.id },
    { taskId: secondTask.id },
  ]);
  assert.deepEqual(
    fixture.inputs.map((entry) => entry[2].text),
    ["first Task input", "second Task input"],
  );
});

test("late Workspace creation cannot attach old messages or selection to a newly opened draft", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  await selectManualSubmissionWorkspace(user);
  fireEvent.change(fixture.textarea, {
    target: { value: "old pending creation" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  fireEvent.click(
    screen.getByRole("button", { name: "New task", exact: true }),
  );
  await selectManualSubmissionWorkspace(user);
  fireEvent.change(fixture.textarea, { target: { value: "new unsent draft" } });

  await fixture.created();
  fixture.snapshot.tasks = [fixture.task];
  await fixture.publish();
  assert.equal(
    document.querySelector(".workbench-view").dataset.view,
    "new-task",
  );
  assert.equal(fixture.textarea.value, "new unsent draft");
  assert.equal(Boolean(screen.queryByText("old pending creation")), false);
  assert.equal(fixture.inputs.length, 1);

  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 2);
  const secondTask = { ...structuredClone(fixture.task), id: "4" };
  await fixture.created(secondTask, 1);
  await fixture.settle();
  assert.deepEqual(fixture.targets, [
    { taskId: fixture.task.id },
    { taskId: secondTask.id },
  ]);
});

test("App retains unknown messages across Tasks at local capacity and preserves the next draft until reconciliation", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { active: true });
  await fixture.settle(new Error("response lost"));
  async function sendUnknown(text) {
    fireEvent.change(fixture.textarea, { target: { value: text } });
    fireEvent.keyDown(fixture.textarea, { key: "Enter" });
    await act(async () => {});
  }
  for (let i = 0; i < 32; i++) await sendUnknown(`first-unknown-${i}`);
  const secondTask = {
    ...structuredClone(fixture.task),
    id: "4",
    title: "Second task",
  };
  fixture.snapshot.tasks.push(secondTask);
  await fixture.publish();
  fireEvent.click(
    (await screen.findAllByRole("button", { name: /Second task/ }))[0],
  );
  await screen.findByRole("button", { name: "Task information", exact: true });
  for (let i = 0; i < 32; i++) await sendUnknown(`second-unknown-${i}`);

  await sendUnknown("draft kept at capacity");
  assert.equal(fixture.inputs.length, 64);
  assert.equal(fixture.textarea.value, "draft kept at capacity");
  assert.equal(fixture.textarea.disabled, false);
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  assert.ok(screen.getByText(/Local submission storage is full/));
  assert.equal(
    document.querySelectorAll(".local-input-submissions .task-input-copy")
      .length,
    32,
  );

  fireEvent.click(
    screen.getAllByRole("button", { name: /Submission task/ })[0],
  );
  assert.ok(screen.getByText("first-unknown-0"));
  assert.equal(
    document.querySelectorAll(".local-input-submissions .task-input-copy")
      .length,
    32,
  );
  fireEvent.click(screen.getAllByRole("button", { name: /Second task/ })[0]);
  assert.equal(fixture.textarea.value, "draft kept at capacity");

  fixture.task.inputSubmissions = [
    {
      submission: {
        operationId: fixture.operationIds[0],
        receivedAtUnixMs: null,
        presentationOrder: null,
        anchorRunId: null,
        afterOutputCount: 0,
      },
      input: { kind: "text", text: "first-unknown-0", redacted: false },
      state: "waiting",
      reason: null,
    },
  ];
  await fixture.publish();
  assert.equal(fixture.inputs.length, 64);
  await waitFor(() =>
    assert.equal(
      Boolean(screen.queryByText(/Local submission storage is full/)),
      false,
    ),
  );
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false);
  assert.equal(fixture.textarea.value, "draft kept at capacity");
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await act(async () => {});
  assert.equal(fixture.inputs.length, 65);
  assert.equal(fixture.inputs.at(-1)[2].text, "draft kept at capacity");
});

test("App names the Task blocking Session release and allows a later explicit creation retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "My unsent instruction" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await fixture.rejectCreation("session_close_failed", "7");
  await screen.findByText(
    "The session for task “7” could not close. Resolve that task before retrying.",
  );
  assert.equal(fixture.inputs.length, 0);
  fireEvent.change(fixture.textarea, {
    target: { value: "My deliberate retry" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "My deliberate retry");
  await fixture.settle();
});

test("security refresh during first creation preserves local Stop and later input ordering", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fireEvent.change(fixture.textarea, {
    target: { value: "cancel before identity" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  fixture.snapshot.securityEpoch = "2";
  await fixture.publish();
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Stop task" }).disabled,
      false,
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  await screen.findByText("Stopped");
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, { target: { value: "after security and stop" } });
  fireEvent.keyDown(textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 1);
  await fixture.created();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "after security and stop");
  assert.equal(fixture.cancellations.length, 1);
  await fixture.settle();
});

for (const missingSource of [false, true]) {
  test(`App lets a historical Task ${missingSource ? "whose source was deleted" : "without intent"} explicitly choose any ready source`, async (ctx) => {
    const fixture = await renderSubmissionApp(ctx);
    fixture.task.modelIntent = missingSource
      ? {
          modelRef: { sourceId: "deleted-source", modelId: "old-model" },
          selectionRevision: "7",
          state: "committed",
        }
      : null;
    const nextRevision = missingSource ? "8" : "1";
    const model = fixture.snapshot.models.providers[0].models[0];
    fixture.snapshot.models.customProviders = [
      {
        id: "historical-choice",
        displayName: "Other source",
        enabled: true,
        state: "ready",
        credentialStatus: "ready",
        sourceGeneration: "7",
        catalogGeneration: "8",
        protocol: "openai_responses",
        normalizedBaseUrl: "https://example.test/responses",
        providerRevision: "1",
        builtinProviderId: null,
        models: [
          {
            ...model,
            id: "other-model",
            displayName: "Other model",
            ready: true,
            testStatus: "connected",
          },
        ],
      },
    ];
    const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
    const selection = ctx.mock.method(
      BridgeClient.prototype,
      "selectTaskModel",
      async (taskId, revision, modelRef) => {
        fixture.task.modelIntent = {
          modelRef,
          selectionRevision: nextRevision,
          state: "committed",
        };
        return {
          accepted: true,
          taskId,
          selectionRevision: nextRevision,
          reason: null,
        };
      },
    );
    await fixture.publish();
    const user = userEvent.setup({ document });
    await user.type(fixture.textarea, "Keep this draft");
    await user.click(screen.getByRole("combobox", { name: "Model" }));
    await user.click(
      await screen.findByRole("option", { name: "Other model", exact: true }),
    );
    await waitFor(() => assert.equal(selection.mock.callCount(), 1));
    assert.deepEqual(selection.mock.calls[0].arguments, [
      fixture.task.id,
      missingSource ? "7" : "0",
      { sourceId: "historical-choice", modelId: "other-model" },
      "7",
      "8",
    ]);
    assert.equal(fixture.creations(), 0);
    assert.equal(fixture.inputs.length, 0);
    assert.equal(fixture.textarea.value, "Keep this draft");
  });
}

test("App schedule_persistence_failed preserves later edits and permits one explicit retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  for (const text of [
    "First rejected instruction",
    "Second rejected instruction",
  ]) {
    fireEvent.change(fixture.textarea, { target: { value: text } });
    fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  }
  assert.equal(fixture.creations(), 1);
  await user.type(fixture.textarea, "Newer unsent draft");
  await fixture.rejectCreation("schedule_persistence_failed");
  const selector = await screen.findByRole("combobox", { name: "Model" });
  assert.equal(selector.disabled, false);
  assert.ok(screen.getByText("First rejected instruction"));
  assert.ok(screen.getByText("Second rejected instruction"));
  assert.equal(fixture.inputs.length, 0);
  assert.equal(fixture.creations(), 1);
  assert.equal(document.activeElement, fixture.textarea);
  await user.click(
    screen.getAllByRole("button", { name: "Copy to input box" })[0],
  );
  assert.equal(fixture.textarea.value, "Newer unsent draft");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "Newer unsent draft");
  await fixture.settle();
});

test("App schedule_persistence_unavailable preserves later edits and permits one explicit retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  for (const text of [
    "First rejected instruction",
    "Second rejected instruction",
  ]) {
    fireEvent.change(fixture.textarea, { target: { value: text } });
    fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  }
  assert.equal(fixture.creations(), 1);
  await user.type(fixture.textarea, "Newer unsent draft");
  await fixture.rejectCreation("schedule_persistence_unavailable");
  const selector = await screen.findByRole("combobox", { name: "Model" });
  assert.equal(selector.disabled, false);
  assert.ok(screen.getByText("First rejected instruction"));
  assert.ok(screen.getByText("Second rejected instruction"));
  assert.equal(fixture.inputs.length, 0);
  assert.equal(fixture.creations(), 1);
  assert.equal(document.activeElement, fixture.textarea);
  await user.click(
    screen.getAllByRole("button", { name: "Copy to input box" })[0],
  );
  assert.equal(fixture.textarea.value, "Newer unsent draft");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "Newer unsent draft");
  await fixture.settle();
});

test("App schedule_persistence_outcome_unknown preserves later edits and permits one explicit retry", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const user = userEvent.setup({ document });
  for (const text of [
    "First rejected instruction",
    "Second rejected instruction",
  ]) {
    fireEvent.change(fixture.textarea, { target: { value: text } });
    fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  }
  assert.equal(fixture.creations(), 1);
  await user.type(fixture.textarea, "Newer unsent draft");
  await fixture.rejectCreation("schedule_persistence_outcome_unknown");
  const selector = await screen.findByRole("combobox", { name: "Model" });
  assert.equal(selector.disabled, false);
  assert.ok(screen.getByText("First rejected instruction"));
  assert.ok(screen.getByText("Second rejected instruction"));
  assert.equal(fixture.inputs.length, 0);
  assert.equal(fixture.creations(), 1);
  assert.equal(document.activeElement, fixture.textarea);
  await user.click(
    screen.getAllByRole("button", { name: "Copy to input box" })[0],
  );
  assert.equal(fixture.textarea.value, "Newer unsent draft");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await waitFor(() => assert.equal(fixture.creations(), 2));
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "Newer unsent draft");
  await fixture.settle();
});

test("preference save failure is separate feedback and keeps valid creation and model selection available", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fixture.snapshot.models.errorCode = "preference_not_saved";
  await fixture.publish();
  const message =
    "Your model preference could not be saved. Confirmed task choices are unchanged.";
  const feedback = await screen.findByLabelText(message, {
    selector: "summary",
  });
  fireEvent.click(feedback);
  await screen.findByRole("region", { name: message });
  fireEvent.click(screen.getByRole("button", { name: "Dismiss this notice" }));
  await fixture.publish();
  assert.equal(screen.queryByLabelText(message, { selector: "summary" }), null);
  assert.equal(screen.getByRole("combobox", { name: "Model" }).disabled, false);
  fireEvent.change(fixture.textarea, {
    target: { value: "Send with the explicitly selected model" },
  });
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false);
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.creations(), 1));
  await fixture.created();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(
    fixture.inputs[0][2].text,
    "Send with the explicitly selected model",
  );
  await fixture.settle();
});

test("dismissed preference failure survives security refresh while first creation can still stop and retain later input", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  fixture.snapshot.models.errorCode = "preference_not_saved";
  await fixture.publish();
  const message =
    "Your model preference could not be saved. Confirmed task choices are unchanged.";
  fireEvent.click(
    await screen.findByLabelText(message, { selector: "summary" }),
  );
  fireEvent.click(
    await screen.findByRole("button", { name: "Dismiss this notice" }),
  );
  fireEvent.change(fixture.textarea, {
    target: { value: "cancel this creation input" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 1);
  assert.ok(fixture.createRequests[0][1].targetModelRef);
  fixture.snapshot.securityEpoch = "2";
  await fixture.publish();
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Stop task" }).disabled,
      false,
    ),
  );
  assert.ok(screen.queryByLabelText(message, { selector: "summary" }) === null);
  fireEvent.click(screen.getByRole("button", { name: "Stop task" }));
  await screen.findByText("Stopped");
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, {
    target: { value: "send only this later input" },
  });
  fireEvent.keyDown(textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 1);
  await fixture.created();
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "send only this later input");
  assert.equal(fixture.cancellations.length, 1);
  assert.ok(screen.queryByLabelText(message, { selector: "summary" }) === null);
  await fixture.settle();
});

test("creation rejection after security refresh releases its session for an explicit new model choice", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const provider = fixture.snapshot.models.providers[0];
  provider.models.push({
    ...structuredClone(provider.models[0]),
    id: "integration-alternative",
    displayName: "Integration alternative",
  });
  await fixture.publish();
  fireEvent.change(fixture.textarea, {
    target: { value: "first rejected instruction" },
  });
  fireEvent.keyDown(fixture.textarea, { key: "Enter" });
  assert.equal(fixture.creations(), 1);
  const first = fixture.createRequests[0][1].targetModelRef;
  fixture.snapshot.securityEpoch = "2";
  await fixture.publish();
  await fixture.rejectCreation("execution_unavailable");
  await waitFor(() =>
    assert.equal(
      screen.getByRole("combobox", { name: "Model" }).disabled,
      false,
    ),
  );
  const source = fixture.snapshot.models.providers.find(
    (provider) => provider.id === first.sourceId,
  );
  const next = source.models.find(
    (model) => model.id !== first.modelId && model.ready !== false,
  );
  assert.ok(next);
  const user = userEvent.setup({ document });
  await user.click(screen.getByRole("combobox", { name: "Model" }));
  await user.click(
    await screen.findByRole("option", { name: next.displayName, exact: true }),
  );
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, {
    target: { value: "explicit retry with new model" },
  });
  fireEvent.keyDown(textarea, { key: "Enter" });
  await waitFor(() => assert.equal(fixture.creations(), 2));
  assert.deepEqual(fixture.createRequests[1][1].targetModelRef, {
    sourceId: source.id,
    modelId: next.id,
  });
  assert.equal(fixture.inputs.length, 0);
  await fixture.created(fixture.task, 1);
  await waitFor(() => assert.equal(fixture.inputs.length, 1));
  assert.equal(fixture.inputs[0][2].text, "explicit retry with new model");
  await fixture.settle();
});
