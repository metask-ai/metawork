import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { JSDOM } from "jsdom";
import { createElement } from "react";
import { createServer } from "vite";

import { readNativePackageManifest } from "./package-metadata.mjs";

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

if (!HTMLElement.prototype.hasPointerCapture)
  HTMLElement.prototype.hasPointerCapture = () => false;
if (!HTMLElement.prototype.setPointerCapture)
  HTMLElement.prototype.setPointerCapture = () => undefined;
if (!HTMLElement.prototype.releasePointerCapture)
  HTMLElement.prototype.releasePointerCapture = () => undefined;

const { cleanup, render, screen, waitFor } =
  await import("@testing-library/react");
const { default: userEvent } = await import("@testing-library/user-event");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { AccountIdentity } = await vite.ssrLoadModule(
  "/src/features/account/AccountIdentity.tsx",
);
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const account = {
  state: "authenticated",
  displayName: "Metask User",
};
const productVersion = readNativePackageManifest(process.cwd()).metadata
  .version;

function renderIdentity(callbacks, accountView = account) {
  return render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale: "en-US",
          setLocale() {},
          t: (id, values) => translate("en-US", id, values),
        },
      },
      createElement(AccountIdentity, {
        account: accountView,
        active: false,
        disabled: false,
        cancelDisabled: false,
        onBeginLogin() {},
        onCancel() {},
        onOpenSettings() {},
        onLogout() {},
        ...callbacks,
      }),
    ),
  );
}

test("authenticated account identity does not repeat a healthy connection status", () => {
  renderIdentity({});

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.match(trigger.textContent, /Metask User/);
  assert.doesNotMatch(trigger.textContent, /Metask connected/);
  assert.equal(trigger.querySelector("small"), null);
});

test("signed-out account identity separates account, status, and login action", async () => {
  let loginCalls = 0;
  const user = userEvent.setup({ document: dom.window.document });
  const { container } = renderIdentity(
    {
      onBeginLogin() {
        loginCalls += 1;
      },
      onOpenSettings() {},
      onLogout() {},
    },
    { state: "signed_out", displayName: "" },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.match(trigger.textContent, /Metask/);
  assert.match(trigger.textContent, /Not signed in/);
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
  assert.doesNotMatch(trigger.textContent, /Sign in with Metask/);

  await user.click(trigger);

  const menu = await screen.findByRole("menu", {
    name: "Account and application menu",
  });
  assert.doesNotMatch(menu.textContent, /Metask account/);
  assert.doesNotMatch(menu.textContent, /Not signed in/);
  assert.doesNotMatch(menu.textContent, /Sign in to MetaWork/);

  await user.click(
    screen.getByRole("menuitem", { name: "Sign in with Metask" }),
  );
  assert.equal(loginCalls, 1);
});

test("account-menu sign out confirms in place without opening settings", async () => {
  const calls = { settings: 0, logout: 0 };
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity({
    onOpenSettings() {
      calls.settings += 1;
    },
    onLogout() {
      calls.logout += 1;
    },
  });

  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  const signOutItem = await screen.findByRole("menuitem", {
    name: "Sign out…",
  });
  assert.notEqual(signOutItem.querySelector("svg"), null);
  assert.equal(signOutItem.classList.contains("is-danger"), false);
  await user.click(signOutItem);

  const confirmation = await screen.findByRole("alertdialog");
  assert.match(
    confirmation.textContent,
    /local tasks and history will remain/i,
  );
  assert.deepEqual(calls, { settings: 0, logout: 0 });

  await user.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(screen.queryByRole("alertdialog"), null);
  assert.deepEqual(calls, { settings: 0, logout: 0 });

  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  await user.click(await screen.findByRole("menuitem", { name: "Sign out…" }));
  await user.click(
    await screen.findByRole("button", {
      name: "Sign out and clear this device",
    }),
  );

  assert.deepEqual(calls, { settings: 0, logout: 1 });
  assert.equal(screen.queryByRole("alertdialog"), null);
});

test("about MetaWork shows developer and version metadata and returns focus", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const { container } = renderIdentity({});
  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });

  await user.click(trigger);
  await user.click(await screen.findByRole("menuitem", { name: "About" }));

  const dialog = await screen.findByRole("dialog", {
    name: "MetaWork",
  });
  assert.doesNotMatch(dialog.textContent, /native desktop workbench/iu);
  assert.match(dialog.textContent, /DeveloperMetask/u);
  assert.match(
    dialog.textContent,
    new RegExp(productVersion.replaceAll(".", "\\."), "u"),
  );
  assert.equal(dialog.querySelector(".about-dialog-mark img") !== null, true);

  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  await waitFor(() => assert.equal(dom.window.document.activeElement, trigger));
  assert.equal(container.querySelector(".account-menu"), null);
});

test("authorization without cancellation keeps app actions available without an empty group", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity(
    {},
    {
      state: "authorizing",
      displayName: "",
      canCancel: false,
    },
  );

  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  const menu = await screen.findByRole("menu", {
    name: "Account and application menu",
  });
  assert.equal(menu.querySelector('[role="separator"]'), null);
  await user.click(screen.getByRole("menuitem", { name: "About" }));
  assert.notEqual(
    await screen.findByRole("dialog", { name: "MetaWork" }),
    null,
  );
});
