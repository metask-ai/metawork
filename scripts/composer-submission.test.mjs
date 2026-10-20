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
  let resolveRun;
  const createResolvers = [];
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
    onWorkbenchRevision: (callback) => {
      revision = callback;
      return () => {};
    },
    connect: async () => "1",
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    createTask: () => {
      creations += 1;
      return new Promise((resolve) => createResolvers.push(resolve));
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

async function renderPendingPasteApp(ctx) {
  const fixture = await renderSubmissionApp(ctx);
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

test("App Composer scopes model choices to its Provider and preserves the actual Run model", async (ctx) => {
  const fixture = await renderSubmissionApp(ctx, { newTask: true });
  const provider = fixture.snapshot.models.providers[0];
  const model = provider.models[0];
  provider.models = [
    { ...model, id: "minimax-m3", displayName: "minimax-m3" },
    { ...model, id: "glm-5.3-flash", displayName: "glm-5.3-flash" },
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
  fixture.snapshot.newTaskAdmission.activeModelRef = defaultModel;
  await fixture.publish();
  const selector = screen.getByRole("combobox", { name: "Default model" });
  await waitFor(() => assert.match(selector.textContent, /minimax-m3/));
  const user = userEvent.setup({ document });
  await user.click(selector);
  assert.equal(screen.queryByRole("option", { name: /gpt-5.6-sol/ }), null);
  await user.click(
    await screen.findByRole("option", { name: /glm-5.3-flash/ }),
  );
  await user.type(fixture.textarea, "How can we forecast the weather?{Enter}");
  await waitFor(() => assert.equal(fixture.creations(), 1));
  const { BridgeClient } = await vite.ssrLoadModule("/src/bridge/client.ts");
  assert.deepEqual(
    BridgeClient.prototype.createTask.mock.calls[0].arguments[3],
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
  fixture.snapshot.newTaskAdmission.activeModelRef =
    fixture.snapshot.models.defaultSelection;
  await fixture.publish();
  await user.click(screen.getByRole("combobox", { name: "Default model" }));
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
  await user.click(screen.getByRole("combobox", { name: "Default model" }));
  assert.ok(await screen.findByRole("option", { name: "gpt-5.6-sol" }));
  assert.equal(
    screen.queryByRole("option", { name: /minimax-m3|glm-5.3-flash/ }),
    null,
  );
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
  assert.ok(screen.getByRole("button", { name: "Stop task" }));
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
