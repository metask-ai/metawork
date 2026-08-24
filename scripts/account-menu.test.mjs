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

const { cleanup, render, screen } = await import("@testing-library/react");
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
        onBeginLogin() {},
        ...callbacks,
      }),
    ),
  );
}

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
    name: "Metask account menu",
  });
  assert.match(trigger.textContent, /Metask/);
  assert.match(trigger.textContent, /Not signed in/);
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
  assert.doesNotMatch(trigger.textContent, /Sign in with Metask/);

  await user.click(trigger);

  const menu = await screen.findByRole("menu", {
    name: "Metask account menu",
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

  await user.click(screen.getByRole("button", { name: "Metask account menu" }));
  await user.click(await screen.findByRole("menuitem", { name: "Sign out…" }));

  const confirmation = await screen.findByRole("alertdialog");
  assert.match(
    confirmation.textContent,
    /local tasks and history will remain/i,
  );
  assert.deepEqual(calls, { settings: 0, logout: 0 });

  await user.click(screen.getByRole("button", { name: "Cancel" }));
  assert.equal(screen.queryByRole("alertdialog"), null);
  assert.deepEqual(calls, { settings: 0, logout: 0 });

  await user.click(screen.getByRole("button", { name: "Metask account menu" }));
  await user.click(await screen.findByRole("menuitem", { name: "Sign out…" }));
  await user.click(
    await screen.findByRole("button", {
      name: "Sign out and clear this device",
    }),
  );

  assert.deepEqual(calls, { settings: 0, logout: 1 });
  assert.equal(screen.queryByRole("alertdialog"), null);
});
