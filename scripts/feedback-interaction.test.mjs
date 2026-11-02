import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createElement, StrictMode } from "react";
import { createServer } from "vite";
import { productStateFixture } from "./test-support/product-view-fixture.mjs";

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
HTMLButtonElement.prototype.getBoundingClientRect = () => ({
  x: 16,
  y: 16,
  width: 320,
  height: 44,
  top: 16,
  right: 336,
  bottom: 60,
  left: 16,
  toJSON() {
    return this;
  },
});
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

async function setup(ctx, errorCode = "metask_service_unavailable") {
  window.localStorage.setItem("metawork.model-setup-handled", "true");
  const snapshot = structuredClone(fixture);
  snapshot.tasks = [];
  Object.assign(snapshot.account, {
    state: "signed_out",
    canCancel: false,
    accountId: "",
    displayName: "",
    emailHint: "",
    phoneHint: "",
    concurrencyLimit: null,
    errorCode,
    safeDiagnostic: "request-id: example-safe-id\n<plain text>",
  });
  let revision;
  const controls = {
    failRead: false,
    attempts: 0,
    reads: 0,
    invoke: null,
    generation: "1",
  };
  for (const [name, fn] of Object.entries({
    available: () => true,
    onShortcut: () => () => {},
    onHostSignal: () => () => {},
    onTaskOpen: () => () => {},
    onWorkbenchRevision: (callback) => {
      revision = callback;
      return () => {};
    },
    connect: async () => controls.generation,
    disconnect: async () => {},
    ping: async () => {},
    fetchSnapshot: async (scope) => {
      controls.reads++;
      if (controls.failRead) throw new Error("fixture sync unavailable");
      return productStateFixture(snapshot, scope);
    },
    beginLogin: async () => {
      controls.attempts++;
      if (controls.invoke) return controls.invoke();
      // The intermediate errorCode=none commit was coalesced: same error remains.
      snapshot.revision = String(BigInt(snapshot.revision) + 2n);
      return {
        accepted: true,
        errorCode: "none",
        attemptId: String(controls.attempts),
      };
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
  await waitFor(() =>
    assert.ok(document.querySelector(".account-identity-trigger")),
  );
  await waitFor(() =>
    assert.equal(document.querySelector(".sidebar-capability").disabled, false),
  );
  return {
    controls,
    snapshot,
    publish: async () => {
      snapshot.revision = String(BigInt(snapshot.revision) + 1n);
      await act(async () =>
        revision(snapshot.revision, snapshot.securityEpoch ?? "1"),
      );
    },
    openAccount: async () => {
      const user = userEvent.setup({ document });
      await user.click(
        screen.getByRole("button", {
          name: translate("en-US", "app.account_and_application_menu"),
        }),
      );
      await user.click(
        await screen.findByRole("menuitem", { name: "Settings" }),
      );
      await user.click(screen.getByRole("link", { name: "Account" }));
      return user;
    },
    closeSettings: async () => {
      fireEvent.click(
        screen.getByRole("button", { name: "Back to workbench" }),
      );
      await waitFor(() =>
        assert.ok(
          !document.querySelector(".settings-page"),
          "settings must close",
        ),
      );
    },
  };
}

test("restored account result is local and silent; details collapse keeps focus and dismissal survives repeated snapshots", async (ctx) => {
  const app = await setup(ctx);
  const live = document.querySelector(".commandbar-alert-slot > [role=status]");
  assert.equal(live.textContent, "");
  assert.doesNotMatch(
    document.querySelector(".commandbar-alert summary").textContent,
    /Metask was unavailable/,
  );
  const user = await app.openAccount();
  assert.match(
    document.querySelector(".feedback-notice").textContent,
    /at the time/,
  );
  assert.ok(
    !document.querySelector(".feedback-notice-details"),
    "details must be collapsed",
  );
  const details = screen.getByRole("button", { name: "Technical details" });
  await user.click(details);
  assert.equal(details.getAttribute("aria-expanded"), "true");
  assert.equal(
    document.getElementById(details.getAttribute("aria-controls")).textContent,
    "request-id: example-safe-id\n<plain text>",
  );
  assert.ok(
    !document.querySelector(".feedback-notice-details plain"),
    "diagnostics are plain text",
  );
  await user.click(details);
  assert.ok(
    document.activeElement === details,
    "focus stays on details button",
  );
  assert.ok(
    !document.querySelector(".feedback-notice-details"),
    "details must be collapsed",
  );
  await user.click(screen.getByRole("button", { name: "Dismiss this notice" }));
  await waitFor(() =>
    assert.ok(
      document.activeElement === document.querySelector("#settings-account h2"),
      "focus returns to Account heading",
    ),
  );
  await app.publish();
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.ok(
    !document.querySelector(".feedback-notice"),
    "notice must be absent",
  );
});

test("accepted account retry reopens the same coalesced error once and finishes the received display", async (ctx) => {
  const app = await setup(ctx);
  const user = await app.openAccount();
  await user.click(screen.getByRole("button", { name: "Dismiss this notice" }));
  await user.click(screen.getByRole("button", { name: "Sign in with Metask" }));
  await waitFor(() =>
    assert.match(
      document.querySelector(".feedback-notice")?.textContent ?? "",
      /at the time/,
    ),
  );
  assert.equal(app.controls.attempts, 1);
  assert.doesNotMatch(
    document.querySelector(".feedback-notice").textContent,
    /awaiting current state/,
  );
  const live = document.querySelector(".commandbar-alert-slot > [role=status]");
  assert.match(live.textContent, /at the time/);
  const announced = live.firstElementChild;
  await app.publish();
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.ok(
    live.firstElementChild === announced,
    "repeat must not replace announcement",
  );
  assert.equal(
    document.querySelectorAll(".settings-page .feedback-notice").length,
    1,
  );
});

test("an accepted command with failed sync has only connection sync feedback; recovery observes the account result", async (ctx) => {
  const app = await setup(ctx, "none");
  await app.openAccount();
  app.controls.invoke = () => {
    app.snapshot.account.errorCode = "metask_service_unavailable";
    app.controls.failRead = true;
    return { accepted: true, errorCode: "none", attemptId: "71" };
  };
  fireEvent.click(screen.getByRole("button", { name: "Sign in with Metask" }));
  await waitFor(
    () =>
      assert.match(
        document.querySelector(".commandbar-alert summary")?.textContent ?? "",
        /not synced/,
      ),
    { timeout: 7000 },
  );
  assert.match(
    document.querySelector(".settings-page .feedback-notice").textContent,
    /request received/,
  );
  assert.doesNotMatch(
    document.querySelector(".settings-page").textContent,
    /latest state.*loaded|not synced|already succeeded/i,
  );
  await app.closeSettings();
  app.controls.failRead = false;
  fireEvent.click(document.querySelector(".commandbar-alert summary"));
  fireEvent.click(screen.getByRole("button", { name: "Retry syncing" }));
  await waitFor(() =>
    assert.equal(
      document.querySelector(".commandbar-alert summary")?.textContent,
      "View account operation result",
    ),
  );
  assert.equal(app.controls.attempts, 1);
  await app.openAccount();
  assert.match(
    document.querySelector(".settings-page .feedback-notice").textContent,
    /at the time/,
  );
  assert.doesNotMatch(
    document.querySelector(".settings-page .feedback-notice").textContent,
    /request received/,
  );
});

test("a successful snapshot cannot confirm a timed out account mutation or replay it", async (ctx) => {
  const app = await setup(ctx, "none");
  await app.openAccount();
  app.controls.invoke = () => {
    throw new BridgeCommandTimeoutError("metawork.account.login", 10);
  };
  const reads = app.controls.reads;
  fireEvent.click(screen.getByRole("button", { name: "Sign in with Metask" }));
  await waitFor(() =>
    assert.match(
      document.querySelector(".feedback-notice")?.textContent ?? "",
      /outcome is not confirmed/,
    ),
  );
  await waitFor(() => assert.ok(app.controls.reads > reads));
  await app.publish();
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.match(
    document.querySelector(".feedback-notice").textContent,
    /outcome is not confirmed/,
  );
  assert.equal(app.controls.attempts, 1);
});

test("independent account result remains accessible alongside a connection failure", async (ctx) => {
  const app = await setup(ctx);
  app.controls.failRead = true;
  await app.publish();
  await waitFor(
    () =>
      assert.match(
        document.querySelector(".commandbar-alert summary")?.textContent ?? "",
        /View feedback \(2\)/,
      ),
    { timeout: 7000 },
  );
  fireEvent.click(document.querySelector(".commandbar-alert summary"));
  assert.ok(
    screen.getByRole("button", { name: "View account operation result" }),
  );
  assert.ok(screen.getByRole("button", { name: "Retry syncing" }));
  app.controls.failRead = false;
  fireEvent.click(screen.getByRole("button", { name: "Retry syncing" }));
  await waitFor(() =>
    assert.equal(
      document.querySelector(".commandbar-alert summary")?.textContent,
      "View account operation result",
    ),
  );
});

test("a rejected command result survives unrelated snapshots and is not misreported as an accepted operation", async (ctx) => {
  const app = await setup(ctx, "none");
  await app.openAccount();
  app.controls.invoke = () => ({
    accepted: false,
    errorCode: "invalid_state",
    attemptId: null,
  });
  fireEvent.click(screen.getByRole("button", { name: "Sign in with Metask" }));
  await waitFor(() =>
    assert.match(
      document.querySelector(".feedback-notice")?.textContent ?? "",
      /no longer available/i,
    ),
  );
  const notice = document.querySelector(".feedback-notice").textContent;
  await app.publish();
  await new Promise((resolve) => setTimeout(resolve, 75));
  assert.equal(document.querySelector(".feedback-notice").textContent, notice);
  assert.equal(app.controls.attempts, 1);
});

test("a new authoritative recent result removes the old account error without declaring service recovery", async (ctx) => {
  const app = await setup(ctx);
  await app.openAccount();
  assert.ok(document.querySelector(".feedback-notice"));
  app.snapshot.account.errorCode = "none";
  app.snapshot.account.safeDiagnostic = "";
  await app.publish();
  await waitFor(() =>
    assert.ok(
      !document.querySelector(".settings-page .feedback-notice"),
      "account notice must be absent",
    ),
  );
  assert.ok(
    !document.querySelector(".commandbar-alert"),
    "global marker must be absent",
  );
});

test("security reset clears disclosure and dismissal; late accepted command cannot restore an old cycle", async (ctx) => {
  const app = await setup(ctx);
  const user = await app.openAccount();
  await user.click(screen.getByRole("button", { name: "Technical details" }));
  let resolve;
  app.controls.invoke = () =>
    new Promise((done) => {
      resolve = done;
    });
  fireEvent.click(screen.getByRole("button", { name: "Sign in with Metask" }));
  await waitFor(() => assert.equal(typeof resolve, "function"));
  app.snapshot.securityEpoch = "2";
  await app.publish();
  await waitFor(() =>
    assert.match(
      document.querySelector(".settings-page .feedback-notice")?.textContent ??
        "",
      /at the time/,
    ),
  );
  assert.ok(
    !document.querySelector(".feedback-notice-details"),
    "details must be collapsed",
  );
  await act(async () =>
    resolve({ accepted: true, errorCode: "none", attemptId: "old" }),
  );
  assert.match(
    document.querySelector(".settings-page .feedback-notice").textContent,
    /at the time/,
  );
  assert.doesNotMatch(
    document.querySelector(".settings-page .feedback-notice").textContent,
    /request received/,
  );
  assert.equal(
    screen.getByRole("button", { name: "Sign in with Metask" }).disabled,
    false,
  );
});
