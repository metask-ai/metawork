import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createServer } from "vite";

const chrome =
  process.env.METAWORK_CHROME_BIN ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const outputDir = await mkdtemp(join(tmpdir(), "metawork-mcp-layout-"));
const profileDir = await mkdtemp(join(tmpdir(), "metawork-mcp-chrome-"));
const auditModuleId = "/virtual-mcp-layout-audit.tsx";

const management = {
  availability: "ready",
  managementHealth: "ready",
  operation: "idle",
  desiredGeneration: "7",
  runtimeAlignment: "current",
  redacted: false,
  authorizationOperation: { kind: "idle" },
  servers: [],
};

const server = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  plugins: [
    {
      name: "metawork-mcp-layout-audit",
      configureServer(vite) {
        vite.middlewares.use((request, response, next) => {
          if (request.url?.split("?")[0] !== "/") return next();
          response.setHeader("Content-Type", "text/html; charset=utf-8");
          response.end(`<!doctype html>
<html>
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>MetaWork MCP layout audit</title>
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
import React from "react";
import { createRoot } from "react-dom/client";
import "/src/index.css";
import { McpPage } from "/src/features/mcp/McpPage.tsx";
import { I18nContext } from "/src/i18n/context.ts";
import { translate } from "/src/i18n/runtime.ts";

const management = ${JSON.stringify(management)};
const unchanged = async () => ({ outcome: "unchanged" });

function AuditApp() {
  return (
    <I18nContext.Provider
      value={{
        locale: "zh-CN",
        setLocale: () => undefined,
        t: (id, values) => translate("zh-CN", id, values),
      }}
    >
      <div className="app-window" data-left-open="false">
        <header className="workbench-commandbar" aria-hidden="true" />
        <div className="app-columns">
          <section className="task-stage">
            <McpPage
              management={management}
              capabilities={{ connectionApproval: true, secretCapture: true, oauth: true }}
              query=""
              disabled={false}
              onQuery={() => undefined}
              onCreateStdio={unchanged}
              onCreateHttp={unchanged}
              onUpdateStdio={unchanged}
              onUpdateHttp={unchanged}
              onRename={unchanged}
              onApprove={unchanged}
              onCaptureSecret={unchanged}
              onAuthorize={async () => ({ outcome: "started", operationId: "op-1" })}
              onCancelAuthorization={async () => ({ outcome: "cancelled" })}
              onSetEnabled={unchanged}
              onSetAllowedTools={unchanged}
              onRemove={unchanged}
              onTest={async () => ({ outcome: "started" })}
              onRefresh={async () => ({ outcome: "started" })}
            />
          </section>
        </div>
      </div>
    </I18nContext.Provider>
  );
}

createRoot(document.querySelector("#root")).render(<AuditApp />);
document.documentElement.dataset.auditReady = "true";
`;
      },
    },
  ],
  server: { host: "127.0.0.1", port: 0, strictPort: false },
});

let chromeProcess;
let chromeClient;
try {
  await server.listen();
  const address = server.httpServer?.address();
  assert.ok(address && typeof address !== "string");
  const origin = `http://127.0.0.1:${address.port}`;
  ({ process: chromeProcess, client: chromeClient } = await launchChrome());

  const desktop = await captureAddDrawer(origin, 1320, 812, "desktop");
  const compact = await captureAddDrawer(origin, 540, 812, "compact");

  for (const [name, result] of [
    ["desktop", desktop],
    ["compact", compact],
  ]) {
    assert.equal(result.horizontalOverflow, false, `${name} overflowed`);
    assert.equal(result.labelWritingMode, "horizontal-tb");
    assert.equal(
      result.drawerOpacity,
      "1",
      `${name} drawer stayed translucent`,
    );
    assert.equal(result.drawerBackground, "rgb(251, 250, 252)");
    assert.ok(result.rowWidth > 250, `${name} dynamic row collapsed`);
    assert.ok(result.addRowWidth > 250, `${name} add-row collapsed`);
    assert.ok(result.labelWidth > 100, `${name} label collapsed`);
    assert.equal(result.selectAppearance, "none");
    assert.equal(result.selectBoxShadow, "none");
  }
  assert.ok(
    desktop.protocolWidth > desktop.timeoutWidth,
    "protocol control lost its intended width",
  );
  assert.equal(compact.drawerX, 0, "compact drawer did not cover the stage");

  console.log(JSON.stringify({ outputDir, desktop, compact }, null, 2));
} finally {
  chromeClient?.close();
  await stopChrome(chromeProcess);
  await server.close();
  await rm(profileDir, { recursive: true, force: true, maxRetries: 3 });
}

async function captureAddDrawer(origin, width, height, name) {
  await chromeClient.call("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await chromeClient.call("Page.navigate", { url: origin });
  await waitForExpression(
    'document.documentElement.dataset.auditReady === "true" && document.querySelector(".mcp-header .primary-button")',
  );
  await evaluate(
    'document.querySelector(".mcp-header .primary-button").click()',
  );
  await waitForExpression('document.querySelector(".mcp-add-form")');
  await evaluate('document.querySelector(".mcp-add-row").click()');
  await waitForExpression('document.querySelector(".mcp-text-rows > div")');
  await new Promise((resolve) => setTimeout(resolve, 250));
  const result = await evaluate(`(() => {
    const drawer = document.querySelector(".mcp-drawer");
    const form = document.querySelector(".mcp-add-form");
    const label = document.querySelector(".mcp-field-label");
    const row = document.querySelector(".mcp-text-rows > div");
    const addRow = document.querySelector(".mcp-add-row");
    const select = document.querySelector(".mcp-form-pair select");
    const pairLabels = document.querySelectorAll(".mcp-form-pair > label");
    const rect = (element) => element.getBoundingClientRect();
    return {
      drawerWidth: rect(drawer).width,
      drawerX: rect(drawer).x,
      drawerOpacity: getComputedStyle(drawer).opacity,
      drawerBackground: getComputedStyle(drawer).backgroundColor,
      formWidth: rect(form).width,
      labelWidth: rect(label).width,
      labelWritingMode: getComputedStyle(label).writingMode,
      rowWidth: rect(row).width,
      addRowWidth: rect(addRow).width,
      protocolWidth: rect(pairLabels[0]).width,
      timeoutWidth: rect(pairLabels[1]).width,
      selectAppearance: getComputedStyle(select).appearance,
      selectBoxShadow: getComputedStyle(select).boxShadow,
      horizontalOverflow:
        document.documentElement.scrollWidth > document.documentElement.clientWidth ||
        form.scrollWidth > form.clientWidth,
    };
  })()`);
  const capture = await chromeClient.call("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: false,
  });
  await writeFile(
    join(outputDir, `mcp-add-${name}-${width}x${height}.png`),
    Buffer.from(capture.data, "base64"),
  );
  return result;
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

async function waitForExpression(expression) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (await evaluate(`Boolean(${expression})`)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for: ${expression}`);
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
  assert.ok(page?.webSocketDebuggerUrl);
  const client = await connectCdp(page.webSocketDebuggerUrl);
  await client.call("Page.enable");
  await client.call("Runtime.enable");
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
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id === undefined) return;
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
