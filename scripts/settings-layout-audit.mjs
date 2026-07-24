import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createServer } from "vite";

const chrome =
  process.env.METAWORK_CHROME_BIN ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const outputDir = await mkdtemp(join(tmpdir(), "metawork-settings-layout-"));
const profileDir = await mkdtemp(join(tmpdir(), "metawork-settings-chrome-"));
const auditModuleId = "/virtual-settings-layout-audit.tsx";
const account = {
  sessionState: "authenticated",
  executionState: "ready",
  operation: "none",
  readiness: "ready",
  primaryAction: "none",
  canCancel: false,
  accountId: "account-1",
  profileId: "profile-1",
  displayName: "deepseek (DeepSeek-V4-Pro)",
  apiKeys: [
    {
      selectionId: "key-1",
      name: "Metask API",
      suffix: "1234",
      provider: "openai",
    },
    {
      selectionId: "key-2",
      name: "Research and automation production API",
      suffix: "5678",
      provider: "anthropic",
    },
  ],
  models: [
    { selectionId: "model-1", displayName: "MiniMax-M2.5" },
    {
      selectionId: "model-2",
      displayName: "DeepSeek-V4-Pro for long-running repository analysis",
    },
  ],
  selectedApiKeySelectionId: "key-1",
  selectedModelSelectionId: "model-1",
  candidateApiKeySelectionId: "",
  candidateModelSelectionId: "",
  modelCatalogApiKeySelectionId: "key-1",
  canCreateTask: true,
  errorCode: "none",
  safeDiagnostic: "",
  catalogGeneration: "1",
  executionGeneration: "1",
};

const server = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  plugins: [
    {
      name: "metawork-settings-layout-audit",
      configureServer(vite) {
        vite.middlewares.use((request, response, next) => {
          if (request.url?.split("?")[0] !== "/") return next();
          response.setHeader("Content-Type", "text/html; charset=utf-8");
          response.end(`<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>MetaWork Settings layout audit</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module">
      import RefreshRuntime from "/@react-refresh";
      RefreshRuntime.injectIntoGlobalHook(window);
      window.$RefreshReg$ = () => {};
      window.$RefreshSig$ = () => (type) => type;
      window.__vite_plugin_react_preamble_installed__ = true;
    </script>
    <script type="module" src="${auditModuleId}"></script>
  </body>
</html>`);
        });
      },
      resolveId(id) {
        return id === auditModuleId ? auditModuleId : null;
      },
      load(id) {
        if (id !== auditModuleId) return null;
        return `
import React, { useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "/src/index.css";
import { SettingsPage } from "/src/features/settings/SettingsPage.tsx";
import { I18nContext } from "/src/i18n/context.ts";
import { translate } from "/src/i18n/runtime.ts";

const account = ${JSON.stringify(account)};
const query = new URLSearchParams(window.location.search);
window.__auditEvents = [];

function AuditApp() {
  const [locale, setLocale] = useState(query.get("locale") || "zh-CN");
  const catalogAccount =
    query.get("catalog") === "single"
      ? {
          ...account,
          apiKeys: account.apiKeys.slice(0, 1),
          models: account.models.slice(0, 1),
        }
      : account;
  const accountView =
    query.get("session") === "reauth"
      ? {
          ...catalogAccount,
          sessionState: "reauth_required",
          readiness: "needs_attention",
          primaryAction: "reauthenticate",
        }
      : catalogAccount;

  useLayoutEffect(() => {
    const page = document.querySelector(".settings-page");
    const stage = document.querySelector(".task-stage");
    const nav = document.querySelector(".settings-nav");
    const content = document.querySelector(".settings-content");
    const accountSection = document.querySelector("#settings-account");
    const accountHeading = accountSection?.querySelector(
      ".settings-section-heading",
    );
    if (!page || !stage || !nav || !content || !accountHeading) return;

    const before = {
      page: page.getBoundingClientRect().toJSON(),
      stage: stage.getBoundingClientRect().toJSON(),
      nav: nav.getBoundingClientRect().toJSON(),
      content: content.getBoundingClientRect().toJSON(),
      pageScrollTop: page.scrollTop,
      contentScrollTop: content.scrollTop,
      contentScrollHeight: content.scrollHeight,
      contentClientHeight: content.clientHeight,
    };

    requestAnimationFrame(() => {
      const shouldScroll = query.get("scroll") === "account";
      if (shouldScroll) {
        content.style.scrollBehavior = "auto";
        const accountTop =
          accountHeading.getBoundingClientRect().top -
          content.getBoundingClientRect().top +
          content.scrollTop;
        content.scrollTop = Math.max(1, accountTop - 18);
        content.dispatchEvent(new Event("scroll", { bubbles: true }));
      }
      requestAnimationFrame(() => {
        const fields = document.querySelectorAll(".settings-field");
        const steps = document.querySelectorAll(".settings-field-step");
        const firstField = fields[0].getBoundingClientRect();
        const secondField = fields[1].getBoundingClientRect();
        const firstStep = steps[0].getBoundingClientRect();
        const secondStep = steps[1].getBoundingClientRect();
        const firstConnector = getComputedStyle(fields[0], "::after");
        const secondConnector = getComputedStyle(fields[1], "::before");
        const connectorStart =
          firstField.top + Number.parseFloat(firstConnector.top);
        const connectorJoin = firstField.bottom;
        const connectorResume = secondField.top;
        const connectorEnd =
          secondField.top + Number.parseFloat(secondConnector.height);
        const after = {
          page: page.getBoundingClientRect().toJSON(),
          stage: stage.getBoundingClientRect().toJSON(),
          nav: nav.getBoundingClientRect().toJSON(),
          content: content.getBoundingClientRect().toJSON(),
          pageScrollTop: page.scrollTop,
          contentScrollTop: content.scrollTop,
          contentScrollHeight: content.scrollHeight,
          contentClientHeight: content.clientHeight,
        };
        const result = {
          before,
          after,
          navShiftX: after.nav.x - before.nav.x,
          navShiftY: after.nav.y - before.nav.y,
          pageFitsStage:
            Math.abs(after.page.height - after.stage.height) <= 1 &&
            Math.abs(after.page.y - after.stage.y) <= 1,
          contentOwnsScroll:
            after.contentScrollHeight > after.contentClientHeight &&
            after.pageScrollTop === 0,
          scrollApplied: !shouldScroll || after.contentScrollTop > 0,
          connectorContinuous:
            Math.abs(connectorJoin - connectorResume) <= 1 &&
            Math.abs(
              connectorStart - (firstStep.top + firstStep.height / 2),
            ) <= 1 &&
            Math.abs(
              connectorEnd - (secondStep.top + secondStep.height / 2),
            ) <= 1,
          horizontalOverflow:
            document.documentElement.scrollWidth >
            document.documentElement.clientWidth,
        };
        document.querySelector("#audit-result").textContent =
          JSON.stringify(result);
        document.documentElement.dataset.auditReady = "true";
      });
    });
  }, []);

  return (
    <I18nContext.Provider
      value={{
        locale,
        setLocale,
        t: (id, values) => translate(locale, id, values),
      }}
    >
      <div className="app-window" data-left-open="false">
        <header className="workbench-commandbar" aria-hidden="true" />
        <div className="app-columns">
          <section className="task-stage">
            <SettingsPage
              account={accountView}
              focusTarget="title"
              disabled={false}
              cancelDisabled={false}
              onBack={() => undefined}
              onRefresh={() => window.__auditEvents.push({ type: "refresh" })}
              onCancel={() => window.__auditEvents.push({ type: "cancel" })}
              onSelectApiKey={(id) =>
                window.__auditEvents.push({ type: "api", id })
              }
              onSelectModel={(id) =>
                window.__auditEvents.push({ type: "model", id })
              }
              onReauthenticate={() => undefined}
              onLogout={() => window.__auditEvents.push({ type: "logout" })}
            />
          </section>
        </div>
      </div>
      <pre id="audit-result" hidden />
    </I18nContext.Provider>
  );
}

createRoot(document.querySelector("#root")).render(<AuditApp />);
`;
      },
    },
  ],
  server: {
    host: "127.0.0.1",
    port: 0,
    strictPort: false,
  },
});

let chromeProcess;
let chromeClient;
try {
  await server.listen();
  const address = server.httpServer?.address();
  assert.ok(address && typeof address !== "string");
  const origin = `http://127.0.0.1:${address.port}`;
  ({ process: chromeProcess, client: chromeClient } = await launchChrome());
  const desktop = await capture({
    origin,
    name: "settings-desktop",
    width: 1320,
    height: 812,
    query: "locale=zh-CN",
  });
  const desktopScrolled = await capture({
    origin,
    name: "settings-desktop-scrolled",
    width: 1320,
    height: 812,
    query: "locale=zh-CN&scroll=account",
  });
  const narrow = await capture({
    origin,
    name: "settings-narrow",
    width: 720,
    height: 812,
    query: "locale=zh-CN&scroll=account",
  });
  const compact = await capture({
    origin,
    name: "settings-compact",
    width: 540,
    height: 812,
    query: "locale=zh-CN&scroll=account",
  });
  const interaction = await auditInteractions(origin);
  const singleton = await auditSingletonCatalog(origin);

  for (const [name, result] of [
    ["desktop", desktop],
    ["desktopScrolled", desktopScrolled],
    ["narrow", narrow],
    ["compact", compact],
  ]) {
    assert.equal(result.horizontalOverflow, false, `${name} overflowed`);
    assert.equal(result.pageFitsStage, true, `${name} page escaped its stage`);
    assert.equal(
      result.contentOwnsScroll,
      true,
      `${name} content did not own scrolling`,
    );
    assert.equal(result.scrollApplied, true, `${name} did not actually scroll`);
    assert.equal(
      result.connectorContinuous,
      true,
      `${name} API-to-model connector was broken`,
    );
    assert.equal(result.navShiftX, 0, `${name} navigation shifted on x`);
    assert.equal(result.navShiftY, 0, `${name} navigation shifted on y`);
  }

  console.log(
    JSON.stringify(
      {
        outputDir,
        desktop,
        desktopScrolled,
        narrow,
        compact,
        interaction,
        singleton,
      },
      null,
      2,
    ),
  );
} finally {
  chromeClient?.close();
  await stopChrome(chromeProcess);
  await server.close();
  await rm(profileDir, {
    recursive: true,
    force: true,
    maxRetries: 3,
    retryDelay: 50,
  });
}

async function auditSingletonCatalog(origin) {
  await chromeClient.call("Emulation.setDeviceMetricsOverride", {
    width: 1320,
    height: 812,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await chromeClient.call("Page.navigate", {
    url: `${origin}/?locale=zh-CN&catalog=single&scroll=account`,
  });
  await waitForAudit();

  const state = await evaluate(`({
    catalogCount: document.querySelector(".settings-catalog-count").textContent,
    apiHelp: document.querySelector(".settings-field-api .settings-field-copy p").textContent,
    modelHelp: document.querySelector(".settings-field-api + .settings-field .settings-field-copy p").textContent,
    apiDisabled: document.querySelector("#settings-api").disabled,
    modelDisabled: document.querySelector("#settings-model").disabled,
    actions: [...document.querySelectorAll(".settings-control .selection-trigger-action")].map((element) => element.textContent),
  })`);
  assert.equal(state.catalogCount, "API 1 · 模型 1");
  assert.match(state.apiHelp, /只返回这一个可用 API/);
  assert.match(state.modelHelp, /只提供这一个可用模型/);
  assert.equal(
    state.apiDisabled,
    false,
    "single API control was not clickable",
  );
  assert.equal(
    state.modelDisabled,
    false,
    "single model control was not clickable",
  );
  assert.deepEqual(state.actions, ["查看选项", "查看选项"]);

  await clickElement("#settings-api");
  await waitForExpression("document.querySelector('[role=\"listbox\"]')");
  const apiOptionCount = await evaluate(
    "document.querySelectorAll('[role=\"option\"]').length",
  );
  assert.equal(apiOptionCount, 1, "single API catalog did not open directly");
  await pressKey("Escape");
  await waitForExpression("!document.querySelector('[role=\"listbox\"]')");

  await clickElement("#settings-model");
  await waitForExpression("document.querySelector('[role=\"listbox\"]')");
  const modelOptionCount = await evaluate(
    "document.querySelectorAll('[role=\"option\"]').length",
  );
  assert.equal(
    modelOptionCount,
    1,
    "single model catalog did not open directly",
  );
  const screenshotResult = await chromeClient.call("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await writeFile(
    join(outputDir, "settings-single-model-menu-1320x812.png"),
    Buffer.from(screenshotResult.data, "base64"),
  );
  await pressKey("Escape");

  return {
    ...state,
    apiOptionCount,
    modelOptionCount,
  };
}

async function capture({ origin, name, width, height, query }) {
  const url = `${origin}/?${query}`;
  const screenshot = join(outputDir, `${name}-${width}x${height}.png`);
  await chromeClient.call("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await chromeClient.call("Page.navigate", { url });
  await waitForAudit();
  const result = await chromeClient.call("Runtime.evaluate", {
    expression: 'document.querySelector("#audit-result").textContent',
    returnByValue: true,
  });
  const captureResult = await chromeClient.call("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await writeFile(screenshot, Buffer.from(captureResult.data, "base64"));
  return JSON.parse(result.result.value);
}

async function auditInteractions(origin) {
  await chromeClient.call("Emulation.setDeviceMetricsOverride", {
    width: 1320,
    height: 812,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await chromeClient.call("Page.navigate", {
    url: `${origin}/?locale=zh-CN`,
  });
  await waitForAudit();
  const connectedStatusColor = await evaluate(
    "getComputedStyle(document.querySelector('.settings-identity-copy span'), '::before').backgroundColor",
  );
  await chromeClient.call("Page.navigate", {
    url: `${origin}/?locale=zh-CN&session=reauth`,
  });
  await waitForAudit();
  const attentionStatusColor = await evaluate(
    "getComputedStyle(document.querySelector('.settings-identity-copy span'), '::before').backgroundColor",
  );
  await chromeClient.call("Page.navigate", {
    url: `${origin}/?locale=zh-CN`,
  });
  await waitForAudit();
  await chromeClient.call("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-reduced-motion", value: "reduce" }],
  });

  const initialFocus = await evaluate(
    'document.activeElement === document.querySelector(".settings-header h1")',
  );
  const statusColors = {
    connected: connectedStatusColor,
    attention: attentionStatusColor,
  };
  const directControls =
    await evaluate(`["settings-api", "settings-model"].map((id) => {
    const element = document.querySelector("#" + id);
    const style = getComputedStyle(element);
    return {
      id,
      borderWidth: style.borderTopWidth,
      borderStyle: style.borderTopStyle,
      borderColor: style.borderTopColor,
      backgroundColor: style.backgroundColor,
      cursor: style.cursor,
      action: element.querySelector(".selection-trigger-action")?.textContent,
    };
  })`);
  await clickElement('a[href="#settings-account"]');
  await waitForExpression(
    'document.querySelector(\'a[href="#settings-account"]\').getAttribute("aria-current") === "location"',
  );
  const accountNavActive = await evaluate(
    'document.querySelector(\'a[href="#settings-account"]\').getAttribute("aria-current") === "location"',
  );

  await evaluate(
    'document.querySelector(\'[role="combobox"][aria-label="默认模型"]\').focus()',
  );
  await pressKey("Enter");
  await waitForExpression("document.querySelector('[role=\"listbox\"]')");
  const modelMenu = await evaluate(`({
    activeElement: document.activeElement?.textContent,
    listbox: document.querySelector('[role="listbox"]')?.getBoundingClientRect().toJSON(),
    options: [...document.querySelectorAll('[role="option"]')].map((element) => ({
      text: element.textContent,
      disabled: element.hasAttribute("data-disabled"),
      rect: element.getBoundingClientRect().toJSON(),
    })),
  })`);
  const modelMenuScreenshot = await chromeClient.call(
    "Page.captureScreenshot",
    {
      format: "png",
      captureBeyondViewport: false,
    },
  );
  await writeFile(
    join(outputDir, "settings-model-menu-1320x812.png"),
    Buffer.from(modelMenuScreenshot.data, "base64"),
  );
  await clickElement('[role="option"]', 1);
  await waitForExpression(
    'window.__auditEvents.some((event) => event.type === "model")',
  );
  const modelSelection = await evaluate(
    'window.__auditEvents.find((event) => event.type === "model")?.id',
  );
  const modelFocusRestoredAfterSelection = await evaluate(
    'document.activeElement === document.querySelector(\'[role="combobox"][aria-label="默认模型"]\')',
  );

  await evaluate(
    'document.querySelector(\'[role="combobox"][aria-label="默认 API"]\').focus()',
  );
  await pressKey("Enter");
  await waitForExpression("document.querySelector('[role=\"listbox\"]')");
  const menu = await evaluate(`({
    optionCount: document.querySelectorAll('[role="option"]').length,
    text: document.querySelector('[role="listbox"]').textContent,
    nativeSelectCount: document.querySelectorAll('select').length,
    animationName: getComputedStyle(document.querySelector('.selection-menu-content')).animationName,
    chevronTransition: getComputedStyle(document.querySelector('.selection-trigger-chevron')).transitionDuration,
  })`);
  const screenshotResult = await chromeClient.call("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await writeFile(
    join(outputDir, "settings-api-menu-1320x812.png"),
    Buffer.from(screenshotResult.data, "base64"),
  );
  await clickElement('[role="option"]', 1);
  await waitForExpression(
    'window.__auditEvents.some((event) => event.type === "api")',
  );
  const apiSelection = await evaluate(
    'window.__auditEvents.find((event) => event.type === "api")?.id',
  );
  const focusRestoredAfterSelection = await evaluate(
    'document.activeElement === document.querySelector(\'[role="combobox"][aria-label="默认 API"]\')',
  );

  await evaluate(
    'document.querySelector(\'[role="combobox"][aria-label="默认 API"]\').focus()',
  );
  await pressKey("Enter");
  await waitForExpression("document.querySelector('[role=\"listbox\"]')");
  await pressKey("Escape");
  await waitForExpression("!document.querySelector('[role=\"listbox\"]')");
  await waitForExpression(
    'document.activeElement === document.querySelector(\'[role="combobox"][aria-label="默认 API"]\')',
  );
  const focusRestoredAfterEscape = await evaluate(
    'document.activeElement === document.querySelector(\'[role="combobox"][aria-label="默认 API"]\')',
  );

  await evaluate(
    'document.querySelector(".settings-content").scrollTop = document.querySelector(".settings-content").scrollHeight',
  );
  await waitForExpression(
    'document.querySelector(".settings-content").scrollTop > 100',
  );
  await evaluate(
    'document.querySelector(".settings-danger-zone .danger-button").click()',
  );
  await waitForExpression(
    'document.querySelector(".settings-signout-confirmation")',
  );
  await waitForExpression(
    'document.activeElement === document.querySelector(".settings-signout-confirmation .secondary-button")',
  );
  const cancelFocused = await evaluate(
    'document.activeElement === document.querySelector(".settings-signout-confirmation .secondary-button")',
  );
  await pressKey("Escape");
  await waitForExpression(
    '!document.querySelector(".settings-signout-confirmation")',
  );
  const signOutFocusRestored = await evaluate(
    'document.activeElement === document.querySelector(".settings-danger-zone .danger-button")',
  );

  assert.equal(
    initialFocus,
    true,
    "settings title did not receive initial focus",
  );
  assert.equal(accountNavActive, true, "account navigation did not activate");
  for (const control of directControls) {
    assert.equal(
      control.borderWidth,
      "1px",
      `${control.id} did not render a visible control border`,
    );
    assert.equal(
      control.borderStyle,
      "solid",
      `${control.id} did not render a solid control border`,
    );
    assert.notEqual(
      control.backgroundColor,
      "rgba(0, 0, 0, 0)",
      `${control.id} rendered with a transparent background`,
    );
    assert.equal(
      control.cursor,
      "pointer",
      `${control.id} did not advertise direct interaction`,
    );
    assert.equal(
      control.action,
      "更改",
      `${control.id} did not expose a direct change affordance`,
    );
  }
  assert.notEqual(
    statusColors.connected,
    statusColors.attention,
    "connection attention reused the healthy status color",
  );
  assert.equal(menu.optionCount, 2, "API menu did not expose both APIs");
  assert.equal(
    modelMenu.options.length,
    2,
    "model menu did not expose both models",
  );
  assert.match(modelMenu.options[0].text, /MiniMax-M2\.5/);
  assert.match(
    modelMenu.options[1].text,
    /DeepSeek-V4-Pro for long-running repository analysis/,
  );
  assert.match(menu.text, /Metask API.*OpenAI.*1234/s);
  assert.match(
    menu.text,
    /Research and automation production API.*Anthropic.*5678/s,
  );
  assert.equal(menu.nativeSelectCount, 0, "native select leaked into settings");
  assert.equal(
    menu.animationName,
    "none",
    "reduced motion kept menu animation",
  );
  assert.ok(
    Number.parseFloat(menu.chevronTransition) <= 0.001,
    `reduced motion kept chevron transition: ${menu.chevronTransition}`,
  );
  assert.equal(apiSelection, "key-2", "pointer did not select the next API");
  assert.equal(
    modelSelection,
    "model-2",
    "pointer did not select the next default model",
  );
  assert.equal(
    focusRestoredAfterSelection,
    true,
    "API trigger did not regain focus after selection",
  );
  assert.equal(
    modelFocusRestoredAfterSelection,
    true,
    "model trigger did not regain focus after selection",
  );
  assert.equal(
    focusRestoredAfterEscape,
    true,
    "API trigger did not regain focus after Escape",
  );
  assert.equal(cancelFocused, true, "sign-out cancel did not receive focus");
  assert.equal(
    signOutFocusRestored,
    true,
    "sign-out trigger did not regain focus after Escape",
  );
  await chromeClient.call("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-reduced-motion", value: "no-preference" }],
  });

  return {
    initialFocus,
    statusColors,
    directControls,
    accountNavActive,
    menu,
    modelMenu,
    apiSelection,
    modelSelection,
    focusRestoredAfterSelection,
    modelFocusRestoredAfterSelection,
    focusRestoredAfterEscape,
    cancelFocused,
    signOutFocusRestored,
  };
}

async function evaluate(expression) {
  const result = await chromeClient.call("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails)
    throw new Error(result.exceptionDetails.exception?.description);
  return result.result.value;
}

async function pressKey(key) {
  const keyCodes = { Enter: 13, Escape: 27, ArrowDown: 40 };
  const code = keyCodes[key];
  await chromeClient.call("Input.dispatchKeyEvent", {
    type: "rawKeyDown",
    key,
    code: key,
    windowsVirtualKeyCode: code,
    nativeVirtualKeyCode: code,
  });
  await chromeClient.call("Input.dispatchKeyEvent", {
    type: "keyUp",
    key,
    code: key,
    windowsVirtualKeyCode: code,
    nativeVirtualKeyCode: code,
  });
}

async function clickElement(selector, index = 0) {
  const bounds = await evaluate(`(() => {
    const element = document.querySelectorAll(${JSON.stringify(selector)})[${index}];
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  })()`);
  if (!bounds) throw new Error(`Cannot click missing element: ${selector}`);
  await chromeClient.call("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: bounds.x,
    y: bounds.y,
  });
  await chromeClient.call("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: bounds.x,
    y: bounds.y,
    button: "left",
    clickCount: 1,
  });
  await chromeClient.call("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: bounds.x,
    y: bounds.y,
    button: "left",
    clickCount: 1,
  });
}

async function waitForExpression(expression) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (await evaluate(`Boolean(${expression})`)) return;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error(`Timed out waiting for: ${expression}`);
}

async function waitForAudit() {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const result = await chromeClient.call("Runtime.evaluate", {
      expression: 'document.documentElement.dataset.auditReady === "true"',
      returnByValue: true,
    });
    if (result.result.value === true) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const state = await chromeClient.call("Runtime.evaluate", {
    expression:
      "({ readyState: document.readyState, body: document.body?.innerText, html: document.documentElement?.outerHTML.slice(0, 2000) })",
    returnByValue: true,
  });
  throw new Error(
    `Settings layout audit did not become ready: ${JSON.stringify({
      page: state.result.value,
      events: chromeClient.events.slice(-10),
    })}`,
  );
}

async function launchChrome() {
  const process = spawn(
    chrome,
    [
      "--headless=new",
      "--disable-gpu",
      "--hide-crash-restore-bubble",
      "--no-first-run",
      `--user-data-dir=${profileDir}`,
      "--remote-debugging-port=0",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  const browserWebSocket = await new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Chrome DevTools endpoint did not start")),
      10_000,
    );
    process.once("error", reject);
    process.stderr.setEncoding("utf8");
    process.stderr.on("data", (chunk) => {
      const match = chunk.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (!match) return;
      clearTimeout(timeout);
      resolve(match[1]);
    });
  });
  const endpoint = new URL(browserWebSocket);
  const targets = await fetch(`http://${endpoint.host}/json/list`).then(
    (response) => response.json(),
  );
  const page = targets.find((target) => target.type === "page");
  assert.ok(page?.webSocketDebuggerUrl, "Chrome did not expose a page target");
  const client = await connectCdp(page.webSocketDebuggerUrl);
  await client.call("Page.enable");
  await client.call("Runtime.enable");
  await client.call("Log.enable");
  return { process, client };
}

async function stopChrome(process) {
  if (!process || process.exitCode !== null) return;
  const exited = new Promise((resolve) => process.once("exit", resolve));
  process.kill();
  await Promise.race([
    exited,
    new Promise((resolve) => setTimeout(resolve, 2_000)),
  ]);
}

async function connectCdp(url) {
  const socket = new WebSocket(url);
  let nextId = 0;
  const pending = new Map();
  const events = [];
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id === undefined) {
      if (
        message.method === "Runtime.exceptionThrown" ||
        message.method === "Log.entryAdded"
      )
        events.push(message);
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(message.error.message));
    else request.resolve(message.result);
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  return {
    events,
    call(method, params = {}) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        socket.send(JSON.stringify({ id, method, params }));
      });
    },
    close() {
      socket.close();
    },
  };
}
