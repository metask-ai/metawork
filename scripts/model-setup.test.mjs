import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement, StrictMode } from "react";
import { createServer } from "vite";
import { productStateFixture } from "./test-support/product-view-fixture.mjs";
import { modelSetupNotice } from "../frontend/src/workbench/model-setup.ts";

const fixture = JSON.parse(
  readFileSync(
    "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
    "utf8",
  ),
);
const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
dom.window.PointerEvent ??= dom.window.MouseEvent;
Object.assign(
  globalThis,
  Object.fromEntries(
    [
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
    ].map((key) => [key, key === "window" ? dom.window : dom.window[key]]),
  ),
);
Object.assign(globalThis, {
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
window.matchMedia = (media) => ({
  media,
  matches: false,
  addEventListener() {},
  removeEventListener() {},
});
for (const method of [
  "setPointerCapture",
  "releasePointerCapture",
  "scrollIntoView",
])
  HTMLElement.prototype[method] ??= () => {};
HTMLElement.prototype.hasPointerCapture ??= () => false;
globalThis.CSS ??= { escape: (value) => value.replace(/["\\]/g, "\\$&") };

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { default: App } = await vite.ssrLoadModule("/src/app/App.tsx");
const { BridgeClient, BridgeCommandTimeoutError } = await vite.ssrLoadModule(
  "/src/bridge/client.ts",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.beforeEach(() => {
  window.localStorage.clear();
  window.sessionStorage.clear();
});
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

function signedOut() {
  const snapshot = structuredClone(fixture);
  snapshot.tasks = [];
  snapshot.capabilities.automaticWorkspaces = true;
  snapshot.capabilities.customProviderManagement = true;
  snapshot.capabilities.customProviderSecretCapture = true;
  snapshot.capabilities.customModelTest = true;
  Object.assign(snapshot.account, {
    state: "signed_out",
    canCancel: false,
    accountId: "",
    displayName: "",
    emailHint: "",
    phoneHint: "",
    concurrencyLimit: null,
  });
  Object.assign(snapshot.models, {
    availability: "needs_authentication",
    defaultSelection: null,
    customProviders: [],
  });
  Object.assign(snapshot.models.providers[0], {
    catalogState: "needs_authentication",
    models: [],
    principalRef: "",
    sourceGeneration: "0",
    catalogGeneration: "0",
  });
  Object.assign(snapshot.newTaskAdmission, { available: true, reason: "none" });
  return snapshot;
}

function classify(snapshot, extra = {}) {
  return modelSetupNotice({
    account: snapshot.account,
    models: snapshot.models,
    admission: snapshot.newTaskAdmission,
    selected: snapshot.models.defaultSelection,
    valid: false,
    hasReadyModels: false,
    customProvidersAvailable: true,
    schedulesAvailable: true,
    ...extra,
  });
}

function customModels() {
  const state = signedOut();
  const model = {
    ...structuredClone(fixture.models.providers[0].models[0]),
    testStatus: "connected",
    ready: true,
  };
  state.models.availability = "ready";
  state.models.customProviders = [
    {
      id: "custom-1",
      builtinProviderId: null,
      displayName: "Own model service",
      protocol: "openai_chat_completions",
      normalizedBaseUrl: "http://127.0.0.1:8080/v1/chat/completions",
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      models: [model],
      providerRevision: "1",
      sourceGeneration: "1",
      catalogGeneration: "1",
    },
  ];
  state.models.defaultSelection = { sourceId: "custom-1", modelId: model.id };
  Object.assign(state.newTaskAdmission, { available: true, reason: "none" });
  return state;
}

async function renderApp(
  ctx,
  snapshot = signedOut(),
  { strict = false, locale = "en-US", generation = "1" } = {},
) {
  let revision;
  let notification;
  const calls = {
    login: 0,
    cancel: 0,
    refresh: 0,
    create: 0,
    input: 0,
    select: 0,
  };
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onTaskOpen: (consume) => {
      notification = consume;
      return () => {};
    },
    onWorkbenchRevision: (callback) => {
      revision = callback;
      return () => {};
    },
    connect: async () => generation,
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => productStateFixture(snapshot, scope),
    beginLogin: async () => {
      calls.login++;
      snapshot.account.state = "authorizing";
      snapshot.account.canCancel = true;
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      return { accepted: true, errorCode: "none", attemptId: "login-1" };
    },
    cancelAccountOperation: async () => {
      calls.cancel++;
      snapshot.account.state = "signed_out";
      snapshot.account.canCancel = false;
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      return { accepted: true, errorCode: "none", attemptId: null };
    },
    refreshModelsCatalog: async () => {
      calls.refresh++;
      return { accepted: true, errorCode: "none", attemptId: null };
    },
    createTask: async () => {
      calls.create++;
      throw new Error("Unexpected create");
    },
    sendInput: async () => {
      calls.input++;
      throw new Error("Unexpected send");
    },
    selectTaskModel: async () => {
      calls.select++;
      throw new Error("Unexpected selection");
    },
  }))
    ctx.mock.method(BridgeClient.prototype, name, fn);
  const element = createElement(
    I18nContext.Provider,
    {
      value: {
        locale,
        setLocale() {},
        t: (id, values) => translate(locale, id, values),
      },
    },
    createElement(App),
  );
  const mount = () =>
    render(strict ? createElement(StrictMode, null, element) : element);
  const view = mount();
  await waitFor(() =>
    assert.ok(
      document.querySelector(".composer-model-notice") ||
        window.localStorage.getItem("metawork.model-setup-handled"),
    ),
  );
  return {
    snapshot,
    calls,
    view,
    notification: async (target) => {
      await act(async () => notification(target));
    },
    mount,
    publish: async () => {
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      await act(async () =>
        revision(snapshot.revision, snapshot.securityEpoch ?? "1"),
      );
    },
  };
}

test("schedule timeout refreshes canonical state once without replaying the mutation", async (ctx) => {
  const snapshot = customModels();
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.scheduledTasks = [];
  await renderApp(ctx, snapshot);
  let mutations = 0;
  let reads = 0;
  ctx.mock.method(BridgeClient.prototype, "createScheduledTask", async () => {
    mutations++;
    throw new BridgeCommandTimeoutError("metawork.scheduledTasks.create", 10);
  });
  ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", async (scope) => {
    reads++;
    return productStateFixture(snapshot, scope);
  });
  fireEvent.click(screen.getByRole("button", { name: "Scheduled tasks" }));
  fireEvent.click(await screen.findByRole("button", { name: "New" }));
  fireEvent.change(screen.getByLabelText("Name"), {
    target: { value: "Work summary" },
  });
  fireEvent.change(screen.getByLabelText("Instruction"), {
    target: { value: "Summarize work" },
  });
  const before = reads;
  fireEvent.click(screen.getByRole("button", { name: "Confirm" }));
  await waitFor(() =>
    assert.match(document.body.textContent, /result is unconfirmed/),
  );
  assert.ok(reads > before);
  assert.equal(mutations, 1);
  assert.ok(screen.getByRole("dialog", { name: "New schedule" }));
});

test("notification selects a real Task after canonical refresh and ignores old generations", async (ctx) => {
  const snapshot = customModels();
  snapshot.workspaces = structuredClone(fixture.workspaces);
  snapshot.tasks = structuredClone(fixture.tasks);
  snapshot.capabilities.scheduledTasks = true;
  snapshot.capabilities.scheduledTaskPersistence = true;
  snapshot.capabilities.scheduledTaskPersistenceHealth = "ready";
  snapshot.scheduledTasks = [];
  const app = await renderApp(ctx, snapshot, { generation: "2" });
  fireEvent.click(screen.getByRole("button", { name: "Scheduled tasks" }));
  await screen.findByRole("button", { name: "New" });
  let reads = 0;
  ctx.mock.method(BridgeClient.prototype, "fetchSnapshot", async (scope) => {
    reads++;
    return productStateFixture(snapshot, scope);
  });
  await app.notification({ generation: "2", taskId: fixture.tasks[0].id });
  await waitFor(() =>
    assert.equal(screen.queryByRole("button", { name: "New" }), null),
  );
  await waitFor(() =>
    assert.ok(
      document.querySelector(
        '.task-list [data-task-id="3"][aria-current="page"]',
      ),
    ),
  );
  assert.ok(reads > 0);
  assert.equal(app.calls.create, 0);
  assert.equal(app.calls.input, 0);
  fireEvent.click(screen.getByRole("button", { name: "Scheduled tasks" }));
  await screen.findByRole("button", { name: "New" });
  const before = reads;
  await app.notification({ generation: "1", taskId: fixture.tasks[0].id });
  assert.ok(screen.getByRole("button", { name: "New" }));
  assert.equal(reads, before);
});

test("unconfigured and expired-login states have different recovery actions", () => {
  const state = signedOut();
  assert.deepEqual(classify(state), { reason: "required", action: "start" });
  state.models.defaultSelection = fixture.models.defaultSelection;
  assert.deepEqual(classify(state), { reason: "sign_in", action: "login" });
  assert.equal(classify(state, { valid: true }), null);
});

test("a retained Metask choice explains authorization before generic admission failures", () => {
  const state = signedOut();
  state.models.defaultSelection = structuredClone(
    fixture.models.defaultSelection,
  );
  assert.deepEqual(classify(state), { reason: "sign_in", action: "login" });
  state.account.state = "checking";
  assert.deepEqual(classify(state), { reason: "checking", action: null });
  state.account.state = "authorizing";
  state.account.canCancel = true;
  assert.deepEqual(classify(state), {
    reason: "authorizing",
    action: "cancel",
  });
  state.account.state = "authenticated";
  state.models.providers[0].catalogState = "ready";
  assert.deepEqual(classify(state), {
    reason: "model_unavailable",
    action: "models",
  });
  const custom = customModels();
  assert.deepEqual(classify(custom), {
    reason: "model_unavailable",
    action: "models",
  });
});

test("logout with retained official selection offers login after remount and preserves the draft", async (ctx) => {
  const state = structuredClone(fixture);
  state.tasks = [];
  const selected = structuredClone(state.models.defaultSelection);
  const app = await renderApp(ctx, state, { locale: "zh-CN" });
  const next = signedOut();
  next.models.defaultSelection = selected;
  state.account = next.account;
  state.models = next.models;
  state.newTaskAdmission = next.newTaskAdmission;
  await app.publish();
  await screen.findByRole("button", { name: "登录 Metask", exact: true });
  assert.ok(!screen.queryByRole("dialog"));
  app.view.unmount();
  app.mount();
  const login = await screen.findByRole("button", {
    name: "登录 Metask",
    exact: true,
  });
  assert.match(
    document.querySelector(".composer-model-notice").textContent,
    /登录 Metask 后可使用此模型/,
  );
  assert.ok(!screen.queryByRole("dialog"));
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, { target: { value: "退出登录后继续写的草稿" } });
  assert.equal(
    screen.getByRole("button", { name: "发送", exact: true }).disabled,
    true,
  );
  fireEvent.click(login);
  await waitFor(() => assert.equal(app.calls.login, 1));
  await screen.findByRole("button", { name: "取消登录", exact: true });
  assert.equal(textarea.value, "退出登录后继续写的草稿");
  assert.deepEqual(state.models.defaultSelection, selected);
  assert.equal(app.calls.create, 0);
  assert.equal(app.calls.select, 0);
});

test("signed-out model guidance explains authorization without duplicating the recent Account error", () => {
  const state = signedOut();
  state.account.errorCode = "metask_service_unavailable";
  assert.deepEqual(classify(state), { reason: "sign_in", action: "login" });
  state.account.errorCode = "credential_store_read_failed";
  assert.deepEqual(classify(state), { reason: "sign_in", action: "login" });
});

test("Host preparation, failures and default selection are not first-use setup", () => {
  const state = signedOut();
  state.account.state = "checking";
  assert.deepEqual(classify(state), { reason: "checking", action: null });
  state.account.state = "authorizing";
  assert.deepEqual(classify(state), { reason: "authorizing", action: null });
  state.account.canCancel = true;
  assert.deepEqual(classify(state), {
    reason: "authorizing",
    action: "cancel",
  });
  state.account.state = "authenticated";
  state.models.providers[0].catalogState = "loading";
  assert.deepEqual(classify(state), { reason: "loading", action: null });
  state.models.providers[0].catalogState = "failed";
  assert.deepEqual(classify(state), {
    reason: "catalog_failed",
    action: "refresh",
  });
  state.models.providers[0].errorCode = "no_models";
  assert.deepEqual(classify(state), { reason: "no_models", action: "refresh" });
  state.newTaskAdmission.reason = "shutting_down";
  assert.deepEqual(classify(state), { reason: "preparing", action: null });
  state.models.persistenceHealth = "recovery_required";
  assert.deepEqual(classify(state), {
    reason: "persistence",
    action: "models",
  });
  state.models.persistenceHealth = "ready";
  state.newTaskAdmission.reason = "none";
  state.account.state = "signed_out";
  assert.deepEqual(classify(state, { hasReadyModels: true }), {
    reason: "choose",
    action: "choose_model",
  });
  state.models.availability = "loading";
  assert.deepEqual(classify(state), { reason: "loading", action: null });
});

test("first-use setup is dismissible, repeatable manually and remembered across remounts", async (ctx) => {
  const app = await renderApp(ctx, signedOut(), { strict: true });
  const dialog = await screen.findByRole("dialog", {
    name: "Get started with MetaWork",
  });
  assert.ok(
    within(dialog).getByRole("button", { name: "Configure your own models" }),
  );
  await waitFor(() =>
    assert.ok(
      document.activeElement ===
        within(dialog).getByRole("button", { name: "Sign in with Metask" }),
      "sign-in should receive initial focus",
    ),
  );
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(
    within(dialog).getByRole("button", { name: "Skip for now" }),
  );
  await waitFor(() =>
    assert.ok(
      screen.queryByRole("dialog") === null,
      "setup dialog should be closed",
    ),
  );
  const textarea = document.querySelector(".composer-bar textarea");
  await waitFor(() =>
    assert.ok(
      document.activeElement === textarea,
      "focus should return to the Composer",
    ),
  );
  fireEvent.change(textarea, { target: { value: "Keep this task draft" } });
  fireEvent.keyDown(textarea, { key: "Enter" });
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, true);
  assert.match(
    document.querySelector(".composer-model-notice").textContent,
    /Sign in or configure/,
  );
  await app.publish();
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  await user.click(screen.getByRole("button", { name: "Get started" }));
  const reopened = await screen.findByRole("dialog");
  assert.ok(reopened);
  await user.keyboard("{Escape}");
  await waitFor(() =>
    assert.ok(
      screen.queryByRole("dialog") === null,
      "setup dialog should be closed",
    ),
  );
  assert.equal(textarea.value, "Keep this task draft");
  app.view.unmount();
  app.mount();
  await waitFor(() =>
    assert.match(
      document.querySelector(".composer-model-notice")?.textContent ?? "",
      /Sign in or configure/,
    ),
  );
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  assert.equal(
    document.querySelector(".composer-bar textarea").value,
    "Keep this task draft",
  );
  assert.deepEqual(app.calls, {
    login: 0,
    cancel: 0,
    refresh: 0,
    create: 0,
    input: 0,
    select: 0,
  });
});

test("login leaves setup, permits cancellation and never sends the preserved draft", async (ctx) => {
  const app = await renderApp(ctx);
  const user = userEvent.setup({ document: dom.window.document });
  let dialog = await screen.findByRole("dialog");
  await user.click(
    within(dialog).getByRole("button", { name: "Skip for now" }),
  );
  await waitFor(() =>
    assert.ok(
      screen.queryByRole("dialog") === null,
      "setup dialog should be closed",
    ),
  );
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, { target: { value: "Do this after setup" } });
  await user.click(screen.getByRole("button", { name: "Get started" }));
  dialog = await screen.findByRole("dialog");
  await user.click(
    within(dialog).getByRole("button", { name: "Sign in with Metask" }),
  );
  await screen.findByRole("button", { name: "Cancel sign-in" });
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  assert.equal(app.calls.login, 1);
  assert.equal(textarea.value, "Do this after setup");
  await user.click(screen.getByRole("button", { name: "Cancel sign-in" }));
  await screen.findByRole("button", { name: "Get started" });
  assert.equal(app.calls.cancel, 1);
  app.snapshot.account = structuredClone(fixture.account);
  app.snapshot.models = structuredClone(fixture.models);
  app.snapshot.newTaskAdmission = structuredClone(fixture.newTaskAdmission);
  await app.publish();
  await waitFor(() =>
    assert.ok(!document.querySelector(".composer-model-notice")),
  );
  assert.equal(textarea.value, "Do this after setup");
  assert.equal(app.calls.create, 0);
  assert.equal(app.calls.input, 0);
});

test("configure opens Models for user-added model management and preserves the draft", async (ctx) => {
  const app = await renderApp(ctx);
  const user = userEvent.setup({ document: dom.window.document });
  let dialog = await screen.findByRole("dialog");
  await user.click(
    within(dialog).getByRole("button", { name: "Skip for now" }),
  );
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, {
    target: { value: "Preserve my configuration task" },
  });
  await user.click(await screen.findByRole("button", { name: "Get started" }));
  dialog = await screen.findByRole("dialog");
  await user.click(
    within(dialog).getByRole("button", { name: "Configure your own models" }),
  );
  await screen.findByRole("heading", { name: "Custom models" });
  await waitFor(() =>
    assert.ok(
      screen.queryByRole("dialog", { name: "Get started with MetaWork" }) ===
        null,
      "setup dialog should be closed",
    ),
  );
  assert.equal(screen.queryByRole("link", { name: "Providers" }), null);
  assert.equal(screen.queryByRole("combobox", { name: "Default model" }), null);
  await screen.findByRole("heading", { name: "Models" });
  await user.click(screen.getByRole("button", { name: "Back to workbench" }));
  await waitFor(() =>
    assert.ok(
      document.activeElement === textarea,
      "focus returns to the draft",
    ),
  );
  assert.equal(textarea.value, "Preserve my configuration task");
  assert.equal(app.calls.login, 0);
  assert.equal(app.calls.select, 0);
  assert.equal(app.calls.refresh, 0);
});

for (const capability of [
  "customProviderManagement",
  "customProviderSecretCapture",
  "customModelTest",
])
  test(`setup hides custom configuration without ${capability}`, async (ctx) => {
    const state = signedOut();
    state.capabilities[capability] = false;
    await renderApp(ctx, state);
    const dialog = await screen.findByRole("dialog");
    assert.equal(
      within(dialog).queryByRole("button", {
        name: "Configure your own models",
      }),
      null,
    );
    assert.match(dialog.textContent, /Sign in with Metask to choose a model/);
  });

test("checking and catalog failures never open onboarding or pretend that identity was lost", async (ctx) => {
  const state = signedOut();
  state.account.state = "checking";
  const app = await renderApp(ctx, state);
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  state.account = structuredClone(fixture.account);
  state.models.availability = "failed";
  state.models.providers[0].catalogState = "failed";
  await app.publish();
  const retry = await screen.findByRole("button", {
    name: "Retry",
    exact: true,
  });
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  fireEvent.click(retry);
  await waitFor(() => assert.equal(app.calls.refresh, 1));
  assert.equal(app.calls.login, 0);
});

test("existing configuration marks onboarding handled before it later becomes unavailable", async (ctx) => {
  const state = structuredClone(fixture);
  state.tasks = [];
  const app = await renderApp(ctx, state);
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  const next = signedOut();
  state.account = next.account;
  state.models = next.models;
  state.newTaskAdmission = next.newTaskAdmission;
  await app.publish();
  await screen.findByRole("button", { name: "Get started" });
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
});

test("a retained draft defers automatic onboarding and remains editable", async (ctx) => {
  // Account checking must not interrupt a user who has already begun writing.
  const state = signedOut();
  state.account.state = "checking";
  const app = await renderApp(ctx, state);
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, {
    target: { value: "Writing while the account is checked" },
  });
  state.account.state = "signed_out";
  await app.publish();
  await screen.findByRole("button", { name: "Get started" });
  assert.ok(
    screen.queryByRole("dialog") === null,
    "setup dialog should be closed",
  );
  assert.equal(textarea.value, "Writing while the account is checked");
});

test("signed-out users with a ready custom model can send without seeing setup", async (ctx) => {
  const state = customModels();
  const app = await renderApp(ctx, state);
  assert.ok(
    !screen.queryByRole("dialog", { name: "Get started with MetaWork" }),
  );
  assert.ok(!document.querySelector(".composer-model-notice"));
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, { target: { value: "Use my model service" } });
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false);
  assert.equal(app.calls.login, 0);
  assert.equal(app.calls.select, 0);
});

test("an available model is selected in the task input rather than model management", async (ctx) => {
  const state = customModels();
  state.models.defaultSelection = null;
  const app = await renderApp(ctx, state);
  const user = userEvent.setup({ document: dom.window.document });
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.change(textarea, {
    target: { value: "Keep this draft while choosing" },
  });
  await user.click(
    screen.getByRole("button", { name: "Choose a model", exact: true }),
  );
  const option = await screen.findByRole("option", { name: /Fixture model/ });
  await user.click(option);
  assert.equal(textarea.value, "Keep this draft while choosing");
  assert.equal(screen.getByRole("button", { name: "Send" }).disabled, false);
  assert.equal(screen.queryByRole("dialog", { name: "Settings" }), null);
  assert.equal(app.calls.select, 0);
  assert.equal(app.calls.create, 0);
});

test("model credential recovery opens Models and has no retired Provider entry", () => {
  const state = customModels();
  state.models.defaultSelection = null;
  state.models.customProviders[0].models = [];
  state.models.customProviders[0].state = "configuring";
  state.models.customProviders[0].credentialStatus = "missing";
  state.newTaskAdmission.available = false;
  for (const accountState of ["checking", "signed_out", "authenticated"]) {
    state.account.state = accountState;
    assert.deepEqual(classify(state), {
      reason: "provider_unavailable",
      action: "models",
    });
  }
  assert.deepEqual(classify(state, { customProvidersAvailable: false }), {
    reason: "provider_unavailable",
    action: null,
  });
});

test("active IME composition is not interrupted by delayed startup checks", async (ctx) => {
  const state = signedOut();
  state.account.state = "checking";
  const app = await renderApp(ctx, state);
  const textarea = document.querySelector(".composer-bar textarea");
  fireEvent.compositionStart(textarea);
  state.account.state = "signed_out";
  await app.publish();
  await screen.findByRole("button", { name: "Get started" });
  assert.ok(!screen.queryByRole("dialog"));
  fireEvent.change(textarea, { target: { value: "正在输入" } });
  fireEvent.compositionEnd(textarea);
  assert.ok(!screen.queryByRole("dialog"));
  assert.equal(textarea.value, "正在输入");
});

test("an existing Task stays selected when model authorization becomes unavailable", async (ctx) => {
  const state = signedOut();
  state.account.state = "checking";
  state.tasks = [structuredClone(fixture.tasks[0])];
  state.tasks[0].title = "Saved work";
  const app = await renderApp(ctx, state);
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(
    (await screen.findAllByRole("button", { name: /Saved work/ }))[0],
  );
  await screen.findByRole("button", { name: "Task information", exact: true });
  state.account.state = "signed_out";
  await app.publish();
  await waitFor(() =>
    assert.ok(!document.querySelector(".composer-model-notice")),
  );
  assert.ok(
    !screen.queryByRole("dialog", { name: "Get started with MetaWork" }),
  );
  assert.ok(
    screen.getByRole("button", { name: "Task information", exact: true }),
  );
  assert.equal(app.calls.create, 0);
});

test("optional preference storage failure still suppresses repeat setup in this session", async (ctx) => {
  ctx.mock.method(window.Storage.prototype, "getItem", () => {
    throw new Error("Storage unavailable");
  });
  ctx.mock.method(window.Storage.prototype, "setItem", () => {
    throw new Error("Storage unavailable");
  });
  const app = await renderApp(ctx);
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(
    within(await screen.findByRole("dialog")).getByRole("button", {
      name: "Skip for now",
    }),
  );
  await waitFor(() => assert.ok(!screen.queryByRole("dialog")));
  await app.publish();
  assert.ok(!screen.queryByRole("dialog"));
  assert.ok(screen.getByRole("button", { name: "Get started" }));
});

test("Chinese setup and the persistent hint remain actionable", async (ctx) => {
  await renderApp(ctx, signedOut(), { locale: "zh-CN" });
  const user = userEvent.setup({ document: dom.window.document });
  const dialog = await screen.findByRole("dialog", {
    name: "开始使用 MetaWork",
  });
  assert.ok(within(dialog).getByRole("button", { name: "配置自己的模型" }));
  await user.click(within(dialog).getByRole("button", { name: "暂时跳过" }));
  await screen.findByRole("button", { name: "开始使用", exact: true });
  assert.match(
    document.querySelector(".composer-model-notice").textContent,
    /登录或配置模型后即可发送/,
  );
});

test("a retained Metask choice can reopen alternative setup without changing its source", async (ctx) => {
  window.localStorage.setItem("metawork.model-setup-handled", "true");
  const state = signedOut();
  state.models.defaultSelection = structuredClone(
    fixture.models.defaultSelection,
  );
  const original = structuredClone(state.models.defaultSelection);
  const app = await renderApp(ctx, state);
  const user = userEvent.setup({ document: dom.window.document });
  assert.match(
    document.querySelector(".composer-model-notice").textContent,
    /Sign in with Metask to use this model/,
  );
  await user.click(screen.getByRole("button", { name: "Other options" }));
  const dialog = await screen.findByRole("dialog", {
    name: "Get started with MetaWork",
  });
  await user.click(
    within(dialog).getByRole("button", { name: "Configure your own models" }),
  );
  await screen.findByRole("heading", { name: "Custom models" });
  assert.deepEqual(state.models.defaultSelection, original);
  assert.equal(app.calls.select, 0);
  assert.equal(app.calls.login, 0);
});

test("a ready alternative does not immediately close manually opened setup", async (ctx) => {
  const state = customModels();
  state.models.defaultSelection = structuredClone(
    fixture.models.defaultSelection,
  );
  Object.assign(state.newTaskAdmission, { available: true, reason: "none" });
  const app = await renderApp(ctx, state);
  const user = userEvent.setup({ document: dom.window.document });
  await user.click(screen.getByRole("button", { name: "Other options" }));
  // Observe the settled controlled state, not the first portal render before
  // App's readiness effect gets a chance to run.
  await act(
    async () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  const dialog = await screen.findByRole("dialog", {
    name: "Get started with MetaWork",
  });
  assert.ok(
    !dialog.hasAttribute("data-ending-style"),
    "manual setup must remain open",
  );
  await user.click(
    within(dialog).getByRole("button", { name: "Configure your own models" }),
  );
  await screen.findByRole("heading", { name: "Custom models" });
  assert.equal(app.calls.login, 0);
  assert.equal(app.calls.select, 0);
});

test("a saved service with no tested model goes directly to Models", () => {
  const state = customModels();
  state.models.defaultSelection = null;
  state.models.customProviders[0].models = [];
  state.models.customProviders[0].state = "configuring";
  state.newTaskAdmission.available = false;
  assert.deepEqual(classify(state), {
    reason: "provider_unavailable",
    action: "models",
  });
});

test("generic workspace admission does not masquerade as a model failure", () => {
  const state = signedOut();
  state.newTaskAdmission = {
    available: false,
    reason: "workspace_unavailable",
  };
  assert.deepEqual(classify(state), { reason: "required", action: "start" });
  state.newTaskAdmission.reason = "shutting_down";
  assert.deepEqual(classify(state), { reason: "preparing", action: null });
});

test("schedule persistence recovery opens its existing page without starting model setup", async (ctx) => {
  const state = signedOut();
  state.capabilities.scheduledTaskPersistenceHealth = "write_failed";
  state.capabilities.scheduledTaskRecoveryAvailable = true;
  const app = await renderApp(ctx, state);
  const user = userEvent.setup({ document: dom.window.document });
  assert.ok(
    !screen.queryByRole("dialog", { name: "Get started with MetaWork" }),
  );
  await user.click(screen.getByRole("button", { name: "Scheduled tasks" }));
  await screen.findByRole("heading", { name: "Scheduled tasks" });
  assert.ok(screen.getByRole("button", { name: "Start with a clean store" }));
  assert.equal(app.calls.login, 0);
  assert.equal(app.calls.select, 0);
  assert.equal(app.calls.create, 0);
});

test("an accepted model reset remains accepted when its own refresh advances security", async (ctx) => {
  window.localStorage.setItem("metawork.model-setup-handled", "true");
  const state = customModels();
  state.models.persistenceHealth = "recovery_required";
  let calls = 0;
  ctx.mock.method(BridgeClient.prototype, "resetModelsStore", async () => {
    calls++;
    state.securityEpoch = "2";
    state.revision = String(BigInt(state.revision) + 1n);
    return { accepted: true, errorCode: "none" };
  });
  await renderApp(ctx, state);
  const user = userEvent.setup({ document });
  await user.click(
    screen.getByRole("button", {
      name: translate("en-US", "app.account_and_application_menu"),
    }),
  );
  await user.click(
    await screen.findByRole("menuitem", { name: "Settings", exact: true }),
  );
  await user.click(screen.getByRole("link", { name: "Models", exact: true }));
  await user.click(
    screen.getByRole("button", {
      name: translate("en-US", "settings.models_reset_action"),
      exact: true,
    }),
  );
  await user.click(
    screen.getByRole("button", {
      name: translate("en-US", "settings.models_reset_confirm"),
      exact: true,
    }),
  );
  await waitFor(() => assert.equal(calls, 1));
  await waitFor(() => assert.ok(screen.queryByRole("alertdialog") === null));
  assert.ok(
    !document.body.textContent.includes(
      translate("en-US", "settings.models_reset_failed"),
    ),
  );
  assert.equal(
    screen.getByRole("button", {
      name: translate("en-US", "settings.models_reset_action"),
      exact: true,
    }).disabled,
    false,
  );
});
