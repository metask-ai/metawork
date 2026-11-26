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

const { act, cleanup, render, screen, waitFor, within } =
  await import("./renderer-testing-library.mjs");
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
const { SettingsPage } = await vite.ssrLoadModule(
  "/src/features/settings/SettingsPage.tsx",
);
const { AboutSettingsContent } = await vite.ssrLoadModule(
  "/src/features/account/AboutSettingsContent.tsx",
);
const {
  initialWorkbenchState: { snapshot },
} = await vite.ssrLoadModule("/src/workbench/store.ts");
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const actions = (offered = {}) => ({
  cancel: false,
  retry: false,
  login: false,
  logout: false,
  clear: false,
  ...offered,
});
const account = {
  state: "authenticated",
  actions: actions({ logout: true }),
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
const updateFailed = JSON.parse(
  readFileSync(
    new URL("../src/product/update_failed.fixture", import.meta.url),
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
        checkDiagnostic: null,
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

function renderAboutSettings(props = {}, locale = "en-US") {
  return render(
    createElement(
      I18nContext.Provider,
      {
        value: {
          locale,
          setLocale() {},
          t: (id, values) => translate(locale, id, values),
        },
      },
      createElement(SettingsPage, {
        account: snapshot.account,
        models: snapshot.models,
        automaticWorkspaceRoot: snapshot.automaticWorkspaceRoot,
        customProviderCapabilities: {
          management: false,
          secretCapture: false,
          modelTest: false,
        },
        focusTarget: "title",
        aboutContent: createElement(AboutSettingsContent, {
          updates: { ...snapshot.updates, checkState: "unchecked" },
          updateControls,
          ...props,
        }),
      }),
    ),
  );
}

test("authenticated account identity shows a compact avatar and describes the account", async () => {
  renderIdentity({});

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.equal(trigger.textContent, "M");
  assert.equal(trigger.getAttribute("aria-description"), "Metask User");
  await userEvent.setup({ document: dom.window.document }).click(trigger);
  const menu = await screen.findByRole("menu");
  assert.match(menu.textContent, /Metask User/);
  assert.doesNotMatch(menu.textContent, /Metask connected/);
});

test("authenticated account without a username uses its email hint", () => {
  const { container } = renderIdentity(
    {},
    {
      state: "authenticated",
      actions: actions({ logout: true }),
      displayName: "",
      emailHint: "m***@example.com",
      phoneHint: "138****8000",
    },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.equal(trigger.getAttribute("aria-description"), "m***@example.com");
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
});

test("authenticated phone account uses its masked phone hint", () => {
  const { container } = renderIdentity(
    {},
    {
      state: "authenticated",
      actions: actions({ logout: true }),
      displayName: "",
      emailHint: "",
      phoneHint: "138****8000",
    },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.equal(trigger.getAttribute("aria-description"), "138****8000");
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
});

test("authenticated account without profile data uses a neutral identity", () => {
  const { container } = renderIdentity(
    {},
    {
      state: "authenticated",
      actions: actions({ logout: true }),
      displayName: "",
      emailHint: "",
      phoneHint: "",
    },
  );

  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  assert.equal(trigger.getAttribute("aria-description"), "Signed in");
  assert.equal(container.querySelector(".account-avatar")?.textContent, "M");
});

test("signed-out account identity separates account, status, and login action", async () => {
  let loginCalls = 0;
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity(
    {
      onBeginLogin() {
        loginCalls += 1;
      },
      onOpenSettings() {},
      onLogout() {},
    },
    {
      state: "signed_out",
      actions: actions({ login: true }),
      displayName: "",
      emailHint: "",
      phoneHint: "",
    },
  );

  const trigger = screen.getByRole("button", {
    name: "Sign in · Account and application menu",
  });
  assert.equal(trigger.textContent, "Sign in");
  assert.equal(trigger.getAttribute("aria-description"), "Not signed in");

  await user.click(trigger);

  const menu = await screen.findByRole("menu", {
    name: "Sign in · Account and application menu",
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
    /local tasks and history, and workspace files will remain/i,
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

test("checking for updates closes the menu and reports progress, retry and the result in a compact dialog", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const signedOut = { ...account, state: "signed_out" };
  const requests = [];
  const props = {
    updateControls: {
      ...updateControls,
      check: () => new Promise((resolve) => requests.push(resolve)),
    },
  };
  const view = renderIdentity(props, signedOut, "zh-CN");
  const trigger = screen.getByRole("button", { name: /账户与应用菜单/ });
  await user.click(trigger);
  const item = await screen.findByRole("menuitem", {
    name: `检查更新 v${productVersion}`,
  });
  assert.ok(item.querySelector("svg.lucide-circle-arrow-up"));
  const items = screen.getAllByRole("menuitem");
  assert.equal(
    items[items.indexOf(item) - 1],
    screen.getByRole("menuitem", { name: "设置" }),
  );
  assert.equal(screen.queryByRole("menuitem", { name: /关于/ }), null);
  await user.click(item);
  await screen.findByText("正在检查更新…");
  const dialog = screen.getByRole("dialog", { name: "检查更新" });
  assert.equal(screen.queryByRole("menu"), null);
  assert.equal(dialog.querySelector("dl"), null);
  assert.equal(requests.length, 1);
  requests[0](false);
  await screen.findByText("暂时无法执行此操作，请查看当前状态后重试。");
  await user.click(screen.getByRole("button", { name: "重试检查" }));
  assert.equal(requests.length, 2);
  view.rerender(
    identityElement(
      {
        ...props,
        updates: {
          ...updateAvailable,
          updateAvailable: false,
          downloadAvailable: false,
        },
      },
      signedOut,
      "zh-CN",
    ),
  );
  requests[1](true);
  await screen.findByText("当前已是最新版本。");
  assert.equal(dialog.querySelectorAll("button").length, 1);
  await user.click(screen.getByRole("button", { name: "确定" }));
  await waitFor(() => assert.equal(document.activeElement, trigger));
  await user.click(trigger);
  assert.equal(screen.queryByText("当前已是最新版本。"), null);
  await screen.findByRole("menuitem", { name: "设置" });
  assert.equal(requests.length, 2);
});

test("the update dialog offers an explicit download or website handoff", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const handoffs = [];
  const controls = {
    ...updateControls,
    download: async (version) => {
      handoffs.push(version);
      return true;
    },
    website: async () => {
      handoffs.push("website");
      return true;
    },
  };
  const view = renderIdentity({
    updates: updateAvailable,
    updateControls: controls,
  });
  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  const check = await screen.findByRole("menuitem", {
    name: /Check for updates/,
  });
  assert.equal(
    screen.queryByRole("menuitem", { name: "Download update" }),
    null,
  );
  await user.click(check);
  await screen.findByText("Version 0.2.10 is available");
  assert.deepEqual(handoffs, []);
  await user.click(screen.getByRole("button", { name: "Download update" }));
  view.rerender(
    identityElement({
      updates: { ...updateAvailable, downloadState: "opened" },
      updateControls: controls,
    }),
  );
  await screen.findByText("Sent to your browser. Check the download there.");
  view.rerender(
    identityElement({
      updates: { ...updateAvailable, downloadAvailable: false },
      updateControls: controls,
    }),
  );
  await screen.findByText(translate("en-US", "updates.package_missing"));
  await user.click(
    screen.getByRole("button", {
      name: translate("en-US", "updates.website"),
    }),
  );
  assert.deepEqual(handoffs, ["0.2.10", "website"]);
  await user.keyboard("{Escape}");
  assert.equal(screen.queryByRole("dialog"), null);
});

test("closing an update check ignores its late response and allows a fresh check", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const requests = [];
  renderIdentity({
    updateControls: {
      ...updateControls,
      check: () => new Promise((resolve) => requests.push(resolve)),
    },
  });
  const trigger = screen.getByRole("button", {
    name: "Account and application menu",
  });
  async function check() {
    await user.click(trigger);
    await user.click(
      await screen.findByRole("menuitem", { name: /Check for updates/ }),
    );
    await screen.findByText(translate("en-US", "updates.checking"));
  }
  await check();
  await user.keyboard("{Escape}");
  await waitFor(() => assert.equal(document.activeElement, trigger));
  await check();
  assert.equal(requests.length, 2);
  await act(async () => requests[0](false));
  assert.equal(
    screen.getByRole("status").textContent,
    translate("en-US", "updates.checking"),
  );
  await act(async () => requests[1](false));
  await screen.findByText(translate("en-US", "updates.action_unavailable"));
});

test("the menu disables update checks while the bridge is unavailable", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity({ updateControls: { ...updateControls, disabled: true } });
  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  const item = await screen.findByRole("menuitem", {
    name: `Check for updates v${productVersion}`,
  });
  assert.equal(item.getAttribute("aria-disabled"), "true");
  assert.ok(screen.getByRole("menuitem", { name: "Settings" }));
});

test("About follows Archived tasks in settings and shows offline metadata in the content pane", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderAboutSettings(
    { updateControls: { ...updateControls, disabled: true } },
    "zh-CN",
  );
  const trigger = screen.getByRole("link", { name: "关于", exact: true });
  assert.equal(
    trigger.previousElementSibling,
    screen.getByRole("link", { name: "已归档任务" }),
  );
  assert.equal(trigger.nextElementSibling, null);
  assert.equal(screen.queryByRole("region", { name: "关于 MetaWork" }), null);

  await user.click(trigger);

  const section = await screen.findByRole("region", { name: "关于 MetaWork" });
  assert.equal(trigger.getAttribute("aria-current"), "location");
  assert.equal(screen.getAllByRole("dialog").length, 1);
  await waitFor(() =>
    assert.equal(
      document.activeElement,
      within(section).getByRole("heading", { name: "关于 MetaWork" }),
    ),
  );
  const rows = section.querySelectorAll(".settings-about-row");
  assert.equal(rows.length, 2);
  assert.ok(within(rows[0]).getByText("当前版本"));
  assert.ok(within(rows[0]).getByText(`v${productVersion}`));
  assert.equal(
    within(rows[0]).getByRole("button", { name: "检查更新" }).disabled,
    true,
  );
  assert.ok(within(rows[1]).getByText("关于 MetaWork"));
  assert.equal(
    within(rows[1]).getByRole("button", { name: "前往官网" }).disabled,
    true,
  );
  assert.equal(
    within(rows[1]).getByRole("button", { name: "联系我们" }).disabled,
    true,
  );
  await user.click(screen.getByRole("link", { name: "通用" }));
  assert.equal(screen.queryByRole("region", { name: "关于 MetaWork" }), null);
});

test("authorization without cancellation keeps app actions available without an empty group", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity(
    {},
    {
      state: "authorizing",
      actions: actions(),
      displayName: "",
    },
  );

  await user.click(
    screen.getByRole("button", { name: "Account and application menu" }),
  );
  const menu = await screen.findByRole("menu", {
    name: "Account and application menu",
  });
  assert.match(menu.textContent, /Finishing Metask sign-in/);
  assert.equal(screen.queryByRole("menuitem", { name: "Cancel" }), null);
  assert.ok(screen.getByRole("menuitem", { name: "Settings" }));
  assert.ok(screen.getByRole("menuitem", { name: /Check for updates/ }));
});

test("account menu offers keyboard sign-in once a lost renewal or cancelled sign-in leaves the account signed out", async () => {
  for (const errorCode of ["token_refresh_failed", "user_cancelled"]) {
    let loginCalls = 0;
    const user = userEvent.setup({ document: dom.window.document });
    renderIdentity(
      {
        onBeginLogin() {
          loginCalls += 1;
        },
      },
      {
        ...account,
        state: "signed_out",
        actions: actions({ login: true }),
        displayName: "",
        emailHint: "",
        errorCode,
      },
    );
    const trigger = screen.getByRole("button", {
      name: "Sign in · Account and application menu",
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

test("a held login offers each way out only while it is available", async () => {
  for (const [errorCode, retry] of [
    ["none", false],
    ["metask_service_unavailable", false],
    ["metask_service_unavailable", true],
  ]) {
    const calls = [];
    const user = userEvent.setup({ document: dom.window.document });
    renderIdentity(
      {
        onRetryRefresh: () => calls.push("retry"),
        onBeginLogin: () => calls.push("login"),
      },
      {
        ...account,
        state: "checking",
        displayName: "",
        emailHint: "",
        errorCode,
        actions: actions({ retry, login: true, logout: true }),
      },
    );
    const trigger = screen.getByRole("button", {
      name: "Account and application menu",
    });
    assert.equal(
      trigger.getAttribute("aria-description"),
      errorCode === "none"
        ? "Checking sign-in"
        : "Can't confirm your sign-in yet",
    );
    for (const [name, call, offered] of [
      ["Try again now", "retry", retry],
      ["Sign in again", "login", true],
    ]) {
      await user.click(trigger);
      await screen.findByRole("menu");
      const item = screen.queryByRole("menuitem", { name });
      if (!offered) {
        assert.equal(item, null);
      } else {
        await user.click(item);
        assert.equal(calls.at(-1), call);
      }
      await user.keyboard("{Escape}");
      await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
    }
    cleanup();
  }
});

test("a signed-out account offers reading the store again and clearing what a sign-out left", async () => {
  const calls = [];
  const user = userEvent.setup({ document: dom.window.document });
  renderIdentity(
    {
      onRetryRefresh: () => calls.push("retry"),
      onLogout: () => calls.push("clear"),
    },
    {
      ...account,
      state: "signed_out",
      displayName: "",
      emailHint: "",
      errorCode: "credential_store_read_failed",
      actions: actions({ retry: true, login: true, clear: true }),
    },
  );
  const trigger = screen.getByRole("button", {
    name: "Sign in · Account and application menu",
  });
  for (const [name, call] of [
    ["Try again now", "retry"],
    ["Clear sign-in again", "clear"],
  ]) {
    await user.click(trigger);
    await user.click(await screen.findByRole("menuitem", { name }));
    assert.equal(calls.at(-1), call);
    await waitFor(() => assert.equal(screen.queryByRole("menu"), null));
  }
  await user.click(trigger);
  await screen.findByRole("menu");
  assert.equal(screen.queryByRole("menuitem", { name: "Sign out…" }), null);
});

test("a signed-in account never offers sign-in, whatever its recent error", async () => {
  // Host signs a session out when it needs signing in again; an error on a
  // verified identity is feedback, not a reason to sign in.
  for (const errorCode of [
    "none",
    "refresh_schedule_failed",
    "token_refresh_failed",
    "metask_service_unavailable",
    "credential_store_write_failed",
    "user_cancelled",
  ]) {
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
  await user.click(
    await screen.findByRole("menuitem", { name: /Check for updates/ }),
  );
  const dialog = await screen.findByRole("dialog", {
    name: "Check for updates",
  });
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
  assert.equal(updateTrigger.parentElement.firstElementChild, updateTrigger);
  assert.ok(updateTrigger.querySelector("svg"));
  assert.equal(updateTrigger.textContent, "");
  await user.tab();
  assert.equal(document.activeElement, updateTrigger);
  assert.equal(
    (await screen.findByText("Update available")).dataset.instant,
    "focus",
  );
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

test("checking from Settings opens the compact dialog once and restores focus", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  let complete;
  let calls = 0;
  renderAboutSettings({
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
  await user.click(screen.getByRole("link", { name: "About", exact: true }));
  const check = screen.getByRole("button", { name: "Check for updates" });
  assert.equal(calls, 0);
  await user.dblClick(check);
  assert.equal(calls, 1);
  assert.equal(check.disabled, true);
  const dialog = await screen.findByRole("dialog", {
    name: "Check for updates",
  });
  assert.match(screen.getByRole("status").textContent, /Checking for updates/u);
  complete(true);
  await waitFor(() => assert.equal(check.disabled, false));
  assert.doesNotMatch(screen.getByRole("status").textContent, /up to date/iu);
  await user.click(within(dialog).getByRole("button", { name: "OK" }));
  await waitFor(() => assert.equal(document.activeElement, check));
});

test("Visit website hands off only on click and allows retry after a browser error", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const calls = [];
  renderAboutSettings({
    updateControls: {
      ...updateControls,
      website: async () => {
        calls.push("website");
        return calls.length === 2;
      },
      check: async () => {
        calls.push("check");
        return true;
      },
    },
  });
  await user.click(screen.getByRole("link", { name: "About", exact: true }));
  const visit = screen.getByRole("button", { name: "Visit website" });
  assert.deepEqual(calls, []);
  await user.click(visit);
  await screen.findByText(translate("en-US", "updates.browser_failed"));
  await user.click(visit);
  await waitFor(() => assert.equal(screen.queryByRole("alert"), null));
  assert.deepEqual(calls, ["website", "website"]);
  assert.equal(
    screen.queryByRole("dialog", { name: "Check for updates" }),
    null,
  );
});

test("Contact us opens the contact page once per click and can retry a failed handoff", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  const calls = [];
  let finish;
  renderAboutSettings({
    onOpenExternalLink: (url) => {
      calls.push(url);
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
    updateControls: {
      ...updateControls,
      website: async () => {
        calls.push("homepage");
        return true;
      },
    },
  });
  await user.click(screen.getByRole("link", { name: "About", exact: true }));
  const visit = screen.getByRole("button", { name: "Visit website" });
  const contact = screen.getByRole("button", { name: "Contact us" });
  assert.equal(visit.nextElementSibling, contact);
  assert.deepEqual(calls, []);
  const url = "https://metawork.metask-ai.com/contact.html";
  await user.dblClick(contact);
  assert.deepEqual(calls, [url]);
  assert.equal(contact.disabled, true);
  await act(async () => finish(false));
  await screen.findByText(translate("en-US", "updates.browser_failed"));
  await user.click(contact);
  await act(async () => finish(true));
  assert.equal(screen.queryByRole("alert"), null);
  assert.equal(
    screen.queryByRole("dialog", { name: "Check for updates" }),
    null,
  );
  await user.click(visit);
  assert.deepEqual(calls, [url, url, "homepage"]);
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
    {
      state: "signed_out",
      actions: actions({ login: true }),
      displayName: "",
      emailHint: "",
      phoneHint: "",
    },
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

test("a failed check keeps one sentence and hides the technical detail behind a disclosure", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderAboutSettings({ updates: updateFailed });
  await user.click(screen.getByRole("link", { name: "About", exact: true }));
  await user.click(screen.getByRole("button", { name: "Check for updates" }));
  const dialog = await screen.findByRole("dialog", {
    name: "Check for updates",
  });
  assert.match(
    screen.getByRole("status").textContent,
    /^Couldn.t check for updates\. Try again later\.$/u,
  );
  const details = dialog.querySelector("details.feedback-diagnostics");
  assert.equal(details.open, false);
  assert.equal(details.querySelector("summary").textContent, "Check details");
  assert.equal(details.querySelector("pre"), null);
  await user.click(details.querySelector("summary"));
  await waitFor(() => assert.ok(details.querySelector("pre")));
  const detail = details.querySelector("pre").textContent;
  assert.match(detail, /Stage: connecting/u);
  assert.match(detail, /Reason: the secure connection failed/u);
  assert.match(detail, /Took: a few seconds/u);
  assert.doesNotMatch(
    detail,
    /https?:|\/\/|\d+\.\d+\.\d+\.\d+|authorization|metask|manifest/iu,
  );
});

test("a check that did not fail shows no diagnostics entry at all", async () => {
  const user = userEvent.setup({ document: dom.window.document });
  renderAboutSettings({ updates: updateAvailable });
  await user.click(screen.getByRole("link", { name: "About", exact: true }));
  await user.click(screen.getByRole("button", { name: "Check for updates" }));
  const dialog = await screen.findByRole("dialog", {
    name: "Check for updates",
  });
  assert.equal(dialog.querySelector("details.feedback-diagnostics"), null);
  assert.doesNotMatch(dialog.textContent, /Check details/u);
});
