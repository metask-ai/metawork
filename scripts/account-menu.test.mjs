import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
  errorCode: "none",
  displayName: "Metask User",
  emailHint: "m***@example.com",
  phoneHint: "",
};
const productVersion = readNativePackageManifest(process.cwd()).metadata
  .version;
const updateAvailable = JSON.parse(
  readFileSync(
    new URL("../src/product/update.fixture", import.meta.url),
    "utf8",
  ),
);
const updateControls = {
  disabled: false,
  generation: "1",
  check: async () => true,
  download: async () => true,
  website: async () => true,
};

function identityElement(callbacks, accountView = account, locale = "en-US") {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale,
        setLocale() {},
        t: (id, values) => translate(locale, id, values),
      },
    },
    createElement(AccountIdentity, {
      account: accountView,
      updates: {
        checkState: "unchecked",
        checkError: "none",
        latestVersion: null,
        updateAvailable: false,
        downloadAvailable: false,
        downloadState: "idle",
        downloadError: "none",
      },
      updateControls: {
        disabled: false,
        generation: "1",
        check: async () => true,
        download: async () => true,
        website: async () => true,
      },
      active: false,
      disabled: false,
      cancelDisabled: false,
      onBeginLogin() {},
      onCancel() {},
      onOpenSettings() {},
      onLogout() {},
      ...callbacks,
    }),
  );
}

function renderIdentity(callbacks, accountView = account, locale = "en-US") {
  return render(identityElement(callbacks, accountView, locale));
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

test("authenticated account without a username uses its email hint", () => {
  const { container } = renderIdentity(
    {},
    {
      state: "authenticated",
      displayName: "",
      emailHint: "m***@example.com",
      phoneHint: "138****8000",
    },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.match(trigger.textContent, /m\*\*\*@example\.com/);
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
});

test("authenticated phone account uses its masked phone hint", () => {
  const { container } = renderIdentity(
    {},
    {
      state: "authenticated",
      displayName: "",
      emailHint: "",
      phoneHint: "138****8000",
    },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.match(trigger.textContent, /138\*\*\*\*8000/);
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
});

test("authenticated account without profile data uses a neutral identity", () => {
  const { container } = renderIdentity(
    {},
    { state: "authenticated", displayName: "", emailHint: "", phoneHint: "" },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.match(trigger.textContent, /Signed in/);
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
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
    { state: "signed_out", displayName: "", emailHint: "", phoneHint: "" },
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
      name: "Sign out",
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

test("account menu preserves keyboard sign-in after refresh failure or cancelled reauthorization", async () => {
  for (const errorCode of ["token_refresh_failed", "user_cancelled"]) {
    let loginCalls = 0;
    const user = userEvent.setup({ document: dom.window.document });
    renderIdentity(
      {
        onBeginLogin() {
          loginCalls += 1;
        },
      },
      { ...account, errorCode },
    );
    const trigger = screen.getByRole("button", {
      name: "Account and application menu",
    });
    await user.click(trigger);
    const loginItem = await screen.findByRole("menuitem", {
      name: "Sign in with Metask",
    });
    loginItem.focus();
    await user.keyboard("{Enter}");
    assert.equal(loginCalls, 1);
    await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
    await waitFor(() => assert.equal(document.activeElement, trigger));
    cleanup();
  }
});

test("healthy account and refresh scheduling failure do not offer reauthorization", async () => {
  for (const errorCode of ["none", "refresh_schedule_failed"]) {
    const user = userEvent.setup({ document: dom.window.document });
    renderIdentity({}, { ...account, errorCode });
    await user.click(
      screen.getByRole("button", { name: "Account and application menu" }),
    );
    await screen.findByRole("menu");
    assert.equal(
      screen.queryByRole("menuitem", { name: "Sign in with Metask" }),
      null,
    );
    cleanup();
  }
});

test("native drag exclusions cover mounted menu/dialog portals and their backdrops", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity({});
  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  const menu = await screen.findByRole("menu");
  assert.ok(
    menu.closest("[data-base-ui-portal][data-native-window-drag-exclude]"),
  );
  await user.click(await screen.findByRole("menuitem", { name: "About" }));
  const dialog = await screen.findByRole("dialog", { name: "MetaWork" });
  const portal = dialog.closest("[data-base-ui-portal]");
  assert.ok(portal.hasAttribute("data-native-window-drag-exclude"));
  assert.ok(
    portal.querySelector('[class*="fixed inset-0"]'),
    "dialog backdrop must share the excluded portal",
  );
});

test("new version uses a separate corner button without a dropdown arrow or accidental menu", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let download;
  renderIdentity({
    updates: updateAvailable,
    updateControls: {
      ...updateControls,
      download: async (version) => {
        download = version;
        return true;
      },
    },
  });
  const accountTrigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.equal(accountTrigger.querySelector("svg"), null);
  assert.equal(accountTrigger.querySelector("button"), null);
  const updateTrigger = screen.getByRole("button", {
    name: "View new version 0.2.10",
  });
  assert.equal(updateTrigger.parentElement, accountTrigger.parentElement);
  await user.click(accountTrigger);
  assert.ok(await screen.findByRole("menu"));
  await user.click(updateTrigger);
  assert.equal(screen.queryByRole("menu"), null);
  const dialog = await screen.findByRole("dialog", { name: "MetaWork" });
  assert.match(dialog.textContent, /Version 0.2.10 is available/u);
  assert.equal(download, undefined);
  await user.click(screen.getByRole("button", { name: "Download update" }));
  await waitFor(() => assert.equal(download, "0.2.10"));
  await user.keyboard("{Escape}");
  await waitFor(() => assert.ok(document.activeElement === updateTrigger));
});

test("invalid download offers an explicit website action without automatically opening it", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let websites = 0;
  renderIdentity({
    updates: {
      ...updateAvailable,
      downloadState: "failed",
      downloadError: "invalid_link",
    },
    updateControls: {
      ...updateControls,
      website: async () => {
        websites++;
        return true;
      },
    },
  });
  await user.click(
    screen.getByRole("button", { name: "View new version 0.2.10" }),
  );
  assert.match(
    screen.getByRole("alert").textContent,
    /download link is unavailable/iu,
  );
  assert.equal(websites, 0);
  await user.click(screen.getByRole("button", { name: "Download website" }));
  await waitFor(() => assert.equal(websites, 1));
});

test("update statuses distinguish a missing package, last confirmed release and browser handoff", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  for (const [patch, message] of [
    [
      { downloadAvailable: false },
      /package for this platform is not available/iu,
    ],
    [
      { checkState: "failed", checkError: "network" },
      /last confirmed version/iu,
    ],
    [{ downloadState: "opened" }, /Sent to your browser/iu],
  ]) {
    renderIdentity({ updates: { ...updateAvailable, ...patch } });
    await user.click(
      screen.getByRole("button", { name: "View new version 0.2.10" }),
    );
    const dialog = await screen.findByRole("dialog", { name: "MetaWork" });
    assert.match(dialog.textContent, message);
    assert.doesNotMatch(
      dialog.textContent,
      /download complete|installed|up to date/iu,
    );
    assert.ok(screen.getByRole("button", { name: "Download website" }));
    if (patch.downloadAvailable === false)
      assert.equal(
        screen.queryByRole("button", { name: "Download update" }),
        null,
      );
    cleanup();
  }
});

test("manual check prevents duplicate clicks and waits for authoritative state", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let complete;
  let calls = 0;
  renderIdentity({
    updateControls: {
      ...updateControls,
      check: () => {
        calls++;
        return new Promise((resolve) => {
          complete = resolve;
        });
      },
    },
  });
  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  await user.click(await screen.findByRole("menuitem", { name: "About" }));
  await user.dblClick(
    screen.getByRole("button", { name: "Check for updates" }),
  );
  assert.equal(calls, 1);
  assert.equal(
    screen.getByRole("button", { name: "Check for updates" }).disabled,
    true,
  );
  assert.match(screen.getByRole("status").textContent, /Checking for updates/u);
  complete(true);
  await waitFor(() =>
    assert.equal(
      screen.getByRole("button", { name: "Check for updates" }).disabled,
      false,
    ),
  );
  assert.doesNotMatch(screen.getByRole("status").textContent, /up to date/iu);
});

test(
  "closing About invalidates late action feedback and a disappeared update restores account focus",
  { timeout: 10000 },
  async () => {
    const user = userEvent.setup({ document: dom.window.document });
    let complete;
    const controls = {
      ...updateControls,
      download: () =>
        new Promise((resolve) => {
          complete = resolve;
        }),
    };
    const rendered = renderIdentity({
      updates: updateAvailable,
      updateControls: controls,
    });
    await user.click(
      screen.getByRole("button", { name: "View new version 0.2.10" }),
    );
    await user.click(screen.getByRole("button", { name: "Download update" }));
    await user.keyboard("{Escape}");
    await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
    await user.click(
      screen.getByRole("button", { name: "View new version 0.2.10" }),
    );
    complete(false);
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(screen.queryByRole("alert"), null);
    rendered.rerender(
      identityElement({
        updates: {
          ...updateAvailable,
          updateAvailable: false,
          downloadAvailable: false,
        },
      }),
    );
    await user.keyboard("{Escape}");
    await waitFor(() =>
      assert.ok(
        document.activeElement ===
          screen.getByRole("button", { name: "Account and application menu" }),
      ),
    );
  },
);

test("update entry works signed out in Chinese and never depends on account command availability", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity(
    { updates: updateAvailable, disabled: true },
    { state: "signed_out", displayName: "", emailHint: "", phoneHint: "" },
    "zh-CN",
  );
  await user.click(screen.getByRole("button", { name: "查看新版本 0.2.10" }));
  assert.match(screen.getByRole("dialog").textContent, /新版本 0.2.10 可用/u);
  assert.equal(
    screen.getByRole("button", { name: "下载新版" }).disabled,
    false,
  );
  assert.ok(screen.getByRole("button", { name: "官网下载" }));
});
