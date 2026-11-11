import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
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
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  Event: dom.window.Event,
  FormData: dom.window.FormData,
  FocusEvent: dom.window.FocusEvent,
  HTMLElement: dom.window.HTMLElement,
  HTMLInputElement: dom.window.HTMLInputElement,
  KeyboardEvent: dom.window.KeyboardEvent,
  MouseEvent: dom.window.MouseEvent,
  MutationObserver: dom.window.MutationObserver,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

const { cleanup, fireEvent, render, screen, waitFor, within } =
  await import("@testing-library/react");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { McpPage, filterMcpServers, parseMcpCommandLine, validMcpHttpEndpoint } =
  await vite.ssrLoadModule("/src/features/mcp/McpPage.tsx");
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const endpointContract = JSON.parse(
  await readFile(
    join(process.cwd(), "src/product/mcp/testdata/mcp-http-endpoints.json"),
    "utf8",
  ),
);

test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

const emptyManagement = {
  availability: "ready",
  managementHealth: "ready",
  operation: "idle",
  desiredGeneration: "0",
  runtimeAlignment: "current",
  redacted: false,
  servers: [],
};
const { McpInstallationCard } = await vite.ssrLoadModule(
  "/src/features/mcp/McpInstallationCard.tsx",
);
const installation = {
  serverId: "server-1",
  taskId: "3",
  runId: "7",
  revision: "2",
  desiredGeneration: "9",
  displayName: "Installed MCP",
  phase: "connecting",
  failure: null,
  sourceOrigin: "https://source.example",
  targetOrigin: null,
  canCancel: true,
  missingCredentials: [],
};
function installationElement(operation, actions = {}) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(McpInstallationCard, { operation, ...actions }),
  );
}
test("MCP installation cancels the exact operation without an Add step", async () => {
  const calls = [];
  render(
    installationElement(installation, {
      onCancelInstallation: async (...args) => {
        calls.push(args);
        return { outcome: "saved" };
      },
    }),
  );
  assert.equal(screen.queryByRole("button", { name: "Add manually" }), null);
  fireEvent.click(screen.getByRole("button", { name: "Cancel installation" }));
  await waitFor(() => assert.deepEqual(calls, [["server-1", "2"]]));
});
test("MCP credential input clears before awaiting Host and on revision change", async () => {
  let finish;
  const calls = [];
  const actions = {
    onCaptureInstallation: (...args) => {
      calls.push(args);
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
  };
  const operation = {
    ...installation,
    phase: "needs_credentials",
    missingCredentials: ["token"],
  };
  const view = render(installationElement(operation, actions));
  const password = document.querySelector('input[type="password"]');
  fireEvent.change(password, { target: { value: "synthetic-secret" } });
  fireEvent.click(screen.getByRole("button", { name: "Save credential" }));
  assert.deepEqual(calls, [["9", "server-1", "token", "synthetic-secret"]]);
  assert.equal(password.value, "");
  assert.equal(password.disabled, true);
  finish({ outcome: "saved" });
  await waitFor(() => assert.equal(password.disabled, false));
  fireEvent.change(password, { target: { value: "stale-secret" } });
  view.rerender(installationElement({ ...operation, revision: "3" }, actions));
  await waitFor(() => assert.equal(password.value, ""));
});
test("MCP completed installation retains its completed state", () => {
  render(
    installationElement({ ...installation, phase: "ready", canCancel: false }),
  );
  assert.ok(screen.getByText(/Installation completed/));
  assert.equal(
    screen.queryByRole("button", { name: "Cancel installation" }),
    null,
  );
  assert.equal(screen.queryByText(/Connecting and discovering/), null);
});

const servers = [
  {
    id: "github-binding",
    displayName: "GitHub",
    namespace: "github",
    transport: "streamable_http",
    authMode: "oauth",
    negotiation: "automatic",
    timeoutMs: 30_000,
    taskReferenceCount: 0,
    applyStatus: "current",
    connection: {
      kind: "streamable_http",
      endpoint: "https://github.example/mcp",
      headers: [],
      registrationKind: "automatic",
      clientId: null,
      tokenEndpointAuthMethod: null,
      clientSecretStatus: "not_required",
    },
    approvalStatus: "approved",
    authorizationStatus: "ready",
    canAuthorize: false,
    desiredEnabled: true,
    runtimeStatus: "ready",
    newTaskAccess: "available",
    safeDiagnostic: "",
    connectionTest: { status: "untested", toolCount: 0, issueCount: 0 },
    tools: [
      {
        name: "search_repositories",
        discovered: true,
        desiredAllowed: true,
        availableToNewTasks: true,
      },
      {
        name: "create_issue",
        discovered: true,
        desiredAllowed: true,
        availableToNewTasks: true,
      },
    ],
  },
  {
    id: "notion-binding",
    displayName: "Notion",
    namespace: "notion",
    transport: "streamable_http",
    authMode: "oauth",
    negotiation: "automatic",
    timeoutMs: 30_000,
    taskReferenceCount: 0,
    applyStatus: "current",
    connection: {
      kind: "streamable_http",
      endpoint: "https://notion.example/mcp",
      headers: [],
      registrationKind: "automatic",
      clientId: null,
      tokenEndpointAuthMethod: null,
      clientSecretStatus: "not_required",
    },
    approvalStatus: "approved",
    authorizationStatus: "reauth_required",
    canAuthorize: true,
    desiredEnabled: true,
    runtimeStatus: "needs_authentication",
    newTaskAccess: "unavailable",
    safeDiagnostic: "Sign in again to refresh this server's tools.",
    connectionTest: { status: "untested", toolCount: 0, issueCount: 0 },
    tools: [],
  },
  {
    id: "filesystem-binding",
    displayName: "Filesystem",
    namespace: "local_files",
    transport: "stdio",
    authMode: "none",
    negotiation: "modern_only",
    timeoutMs: 30_000,
    taskReferenceCount: 0,
    applyStatus: "current",
    connection: {
      kind: "stdio",
      command: "/usr/local/bin/filesystem-server",
      arguments: ["--root", "/workspace"],
      cwd: "/workspace",
      environment: [],
    },
    approvalStatus: "approved",
    authorizationStatus: "not_required",
    canAuthorize: false,
    desiredEnabled: false,
    runtimeStatus: "disabled",
    newTaskAccess: "not_allowed",
    safeDiagnostic: "",
    connectionTest: { status: "untested", toolCount: 0, issueCount: 0 },
    tools: [
      {
        name: "read_file",
        discovered: true,
        desiredAllowed: true,
        availableToNewTasks: false,
      },
    ],
  },
];

const unchangedMutation = async () => ({ outcome: "unchanged" });
const refreshStarted = async () => ({ outcome: "started" });

function pageElement(management, query = "", overrides = {}) {
  return createElement(
    I18nContext.Provider,
    {
      value: {
        locale: "en-US",
        setLocale() {},
        t: (id, values) => translate("en-US", id, values),
      },
    },
    createElement(McpPage, {
      management: {
        authorizationOperation: { kind: "idle" },
        configurationApply: "idle",
        retainedMemberCount: 0,
        applyFailureCount: 0,
        runtimeUncertain: false,
        runtimeTimeoutLimitMs: 120000,
        ...management,
      },
      capabilities: {
        connectionApproval: true,
        secretCapture: true,
        secretMaxBytes: 2560,
        oauth: true,
      },
      query,
      disabled: false,
      onQuery() {},
      onProbeHttpDraft: async () => ({ outcome: "connected" }),
      onVerifyAndAddHttpDraft: unchangedMutation,
      onCreateOAuthHttp: unchangedMutation,
      onUpdateStdio: unchangedMutation,
      onUpdateHttp: unchangedMutation,
      onRename: unchangedMutation,
      onApprove: unchangedMutation,
      onCaptureSecret: unchangedMutation,
      onAuthorize: async () => ({ outcome: "started", operationId: "op-1" }),
      onCancelAuthorization: async () => ({ outcome: "cancelled" }),
      onSetEnabled: unchangedMutation,
      onSetAllowedTools: unchangedMutation,
      onRemove: unchangedMutation,
      onTest: async () => ({ outcome: "started" }),
      onApply: async () => ({ outcome: "started" }),
      onRefresh: refreshStarted,
      ...overrides,
    }),
  );
}

test("MCP page groups verified server state without presenting a marketplace", () => {
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: false,
      servers,
    }),
  );

  assert.equal(screen.getByRole("heading", { level: 1 }).textContent, "MCP");
  assert.ok(screen.getByText("Needs attention"));
  assert.ok(screen.getByText("Available servers"));
  assert.ok(screen.getByRole("heading", { level: 2, name: "Disabled" }));
  assert.ok(screen.getAllByText("GitHub").length >= 1);
  assert.ok(screen.getByText("Notion"));
  assert.ok(screen.getByText("Filesystem"));
  assert.equal(screen.getAllByRole("switch").length, 3);
  assert.equal(screen.queryByText(/marketplace|install/i), null);
  assert.equal(screen.queryByRole("dialog"), null);
  assert.equal(document.querySelector(".mcp-workspace"), null);
});

test("MCP marks only the current member connecting and preserves healthy rows", () => {
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      configurationApply: "applying",
      desiredGeneration: "startup-generation",
      runtimeAlignment: "restart_required",
      redacted: false,
      servers: [
        {
          ...servers[0],
          runtimeStatus: "unreachable",
          applyStatus: "applying",
          newTaskAccess: "unavailable",
          tools: servers[0].tools.map((tool) => ({
            ...tool,
            availableToNewTasks: false,
          })),
        },
        {
          ...servers[0],
          id: "healthy",
          displayName: "Healthy",
          namespace: "healthy",
        },
      ],
    }),
  );

  const row = screen.getByRole("button", { name: /GitHub/ });
  assert.ok(within(row).getByText("Connecting"));
  assert.equal(screen.queryByText("Cannot connect"), null);
  assert.equal(screen.queryByText("Needs attention"), null);
  assert.ok(screen.getByRole("heading", { name: "Available servers" }));
  assert.equal(row.closest("li")?.dataset.status, "connecting");
  assert.equal(
    screen.getByRole("button", { name: /Healthy/ }).closest("li")?.dataset
      .status,
    "ready",
  );
});

test("MCP opens details only on request and restores the list trigger on close", async () => {
  render(
    pageElement({
      availability: "ready",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: false,
      servers: [servers[0]],
    }),
  );

  const row = screen.getByRole("button", { name: /GitHub/ });
  row.focus();
  fireEvent.click(row);
  const dialog = screen.getByRole("dialog", { name: "GitHub" });
  const heading = within(dialog).getByRole("heading", { name: "GitHub" });
  await waitFor(() => assert.ok(document.activeElement === heading));
  fireEvent.keyDown(heading, { key: "Escape" });

  await waitFor(() => assert.ok(screen.queryByRole("dialog") === null));
  await waitFor(() => assert.ok(document.activeElement === row));
});

test("MCP toggles a server from the list without opening details", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "list-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [servers[0]],
      },
      "",
      {
        onSetEnabled: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  const toggle = screen.getByRole("switch", { name: "GitHub enabled" });
  assert.equal(toggle.getAttribute("aria-checked"), "true");
  fireEvent.click(toggle);

  assert.equal(screen.queryByRole("dialog", { name: "GitHub" }), null);
  assert.equal(screen.queryByRole("alertdialog"), null);

  await waitFor(() =>
    assert.deepEqual(calls, [["list-generation", "github-binding", false]]),
  );
  assert.ok(
    screen.getByText(
      "Server disabled for new tasks. Open tasks keep their current access.",
    ),
  );
});

test("MCP locks every server switch while one mutation is pending", async () => {
  const calls = [];
  let resolveFirstMutation = () => {};
  const firstMutation = new Promise((resolve) => {
    resolveFirstMutation = resolve;
  });
  const gitlab = {
    ...servers[0],
    id: "gitlab-binding",
    displayName: "GitLab",
    namespace: "gitlab",
    connection: {
      ...servers[0].connection,
      endpoint: "https://gitlab.example/mcp",
    },
    tools: servers[0].tools.map((tool) => ({ ...tool })),
  };
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "shared-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [servers[0], gitlab],
      },
      "",
      {
        onSetEnabled: async (...args) => {
          calls.push(args);
          return args[1] === "github-binding"
            ? firstMutation
            : { outcome: "saved" };
        },
      },
    ),
  );

  const githubToggle = screen.getByRole("switch", { name: "GitHub enabled" });
  const gitlabToggle = screen.getByRole("switch", { name: "GitLab enabled" });
  fireEvent.click(githubToggle);

  await waitFor(() =>
    assert.equal(gitlabToggle.getAttribute("aria-disabled"), "true"),
  );
  fireEvent.click(gitlabToggle);
  assert.deepEqual(calls, [["shared-generation", "github-binding", false]]);

  resolveFirstMutation({ outcome: "saved" });
  await waitFor(() =>
    assert.equal(gitlabToggle.getAttribute("aria-disabled"), null),
  );
});

test("MCP keeps isolated test results in connection details", () => {
  render(
    pageElement({
      availability: "ready",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: false,
      servers: [
        {
          ...servers[0],
          connectionTest: { status: "failed", toolCount: 0, issueCount: 2 },
        },
      ],
    }),
  );

  const row = screen.getByRole("button", { name: /GitHub/ });
  assert.ok(within(row).getByText("Available to new tasks"));
  assert.equal(within(row).queryByText("Failed · 2 issues"), null);
  fireEvent.click(row);
  const dialog = screen.getByRole("dialog", { name: "GitHub" });
  assert.ok(within(dialog).getByText("Failed · 2 issues"));
  assert.equal(within(dialog).queryByText("Connection test failed"), null);
});

test("MCP retest replaces the old result and keeps feedback beside the connection controls", async () => {
  let finishRequest;
  const actions = {
    onTest: () =>
      new Promise((resolve) => {
        finishRequest = resolve;
      }),
  };
  const pageWithTest = (status, toolCount = 0, issueCount = 0) =>
    pageElement(
      {
        ...emptyManagement,
        desiredGeneration: "7",
        servers: [
          { ...servers[0], connectionTest: { status, toolCount, issueCount } },
        ],
      },
      "",
      actions,
    );
  const view = render(pageWithTest("connected", 17));
  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const dialog = within(screen.getByRole("dialog", { name: "GitHub" }));
  const testButton = dialog.getByRole("button", { name: "Test connection" });
  assert.match(dialog.getByRole("status").textContent, /Succeeded · 17 found/);

  fireEvent.click(testButton);
  assert.equal(testButton.disabled, true);
  assert.match(dialog.getByRole("status").textContent, /Testing…/);
  assert.equal(dialog.queryByText("Succeeded · 17 found"), null);

  view.rerender(pageWithTest("testing"));
  finishRequest({ outcome: "started" });
  await waitFor(() =>
    assert.match(dialog.getByRole("status").textContent, /Testing…/),
  );
  assert.equal(testButton.disabled, true);

  view.rerender(pageWithTest("connected", 17));
  await waitFor(() => assert.equal(testButton.disabled, false));
  assert.match(dialog.getByRole("status").textContent, /Succeeded · 17 found/);
  assert.equal(dialog.queryByText(/Opening an isolated test connection/), null);
  assert.equal(dialog.queryByText("Testing…"), null);

  fireEvent.click(testButton);
  finishRequest({ outcome: "busy" });
  await waitFor(() =>
    assert.match(
      dialog.getByRole("status").textContent,
      /Another connection test is already running/,
    ),
  );
  assert.equal(dialog.queryByText("Succeeded · 17 found"), null);
  assert.equal(testButton.disabled, false);
});

test("MCP retries the formal Runtime instead of promoting connection tests", async () => {
  const refreshes = [];
  render(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "runtime-retry-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [
          {
            ...servers[0],
            runtimeStatus: "unreachable",
            newTaskAccess: "unavailable",
            connectionTest: {
              status: "connected",
              toolCount: 2,
              issueCount: 0,
            },
          },
        ],
      },
      "",
      {
        onRefresh: async () => {
          refreshes.push("refresh");
          return { outcome: "started" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const dialog = screen.getByRole("dialog", { name: "GitHub" });
  assert.ok(within(dialog).getByText("Succeeded · 2 found"));
  fireEvent.click(
    within(dialog).getByRole("button", { name: "Retry connection" }),
  );
  await waitFor(() => assert.deepEqual(refreshes, ["refresh"]));
});

test("MCP keeps intentionally disabled servers out of the attention group", () => {
  const disabledAwaitingSecret = {
    ...servers[2],
    authMode: "static",
    connection: {
      ...servers[2].connection,
      environment: [{ name: "TOKEN", status: "missing" }],
    },
    authorizationStatus: "missing_static_secret",
    canAuthorize: false,
    runtimeStatus: "needs_authentication",
    newTaskAccess: "unavailable",
  };
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: false,
      servers: [disabledAwaitingSecret],
    }),
  );

  assert.equal(screen.queryByText("Needs attention"), null);
  const disabledGroup = screen
    .getByRole("heading", {
      level: 2,
      name: "Disabled",
    })
    .closest("section");
  const row = within(disabledGroup).getByRole("button", {
    name: /Filesystem/,
  });
  assert.ok(within(row).getByText("Disabled"));
  fireEvent.click(row);
  const dialog = screen.getByRole("dialog", { name: "Filesystem" });
  assert.ok(within(dialog).getByRole("button", { name: "Enable" }));
  assert.equal(
    within(dialog).queryByRole("heading", { name: "Enable this service" }),
    null,
  );
});

test("MCP keeps disabled desired state separate from connection apply recovery", () => {
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "8",
      runtimeAlignment: "restart_required",
      redacted: false,
      servers: [
        {
          ...servers[2],
          newTaskAccess: "restart_required",
        },
      ],
    }),
  );

  assert.ok(screen.getByText("Connection changes were not applied"));
  assert.equal(screen.queryByText("Needs attention"), null);
  const row = screen.getByRole("button", { name: /Filesystem/ });
  assert.ok(within(row).getByText("Disabled"));
  fireEvent.click(row);
  const dialog = screen.getByRole("dialog", { name: "Filesystem" });
  assert.equal(
    within(dialog).queryByText("Connection changes were not applied"),
    null,
  );
});

test("MCP detail exposes complete non-secret configuration and the tool catalog", () => {
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: false,
      servers,
    }),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const dialog = screen.getByRole("dialog", { name: "GitHub" });
  assert.ok(dialog.textContent.includes("Remote · HTTP"));
  assert.ok(dialog.textContent.includes("https://github.example/mcp"));
  assert.ok(dialog.textContent.includes("search_repositories"));
  assert.ok(dialog.textContent.includes("create_issue"));
  assert.equal(dialog.textContent.includes("Authorization"), true);
  assert.ok(screen.getByRole("dialog", { name: "GitHub" }));
});

test("MCP keeps choosing tools as the final setup step", () => {
  const toolsNotAllowed = {
    ...servers[0],
    newTaskAccess: "not_allowed",
    tools: servers[0].tools.map((tool) => ({
      ...tool,
      desiredAllowed: false,
      availableToNewTasks: false,
    })),
  };
  render(
    pageElement({
      availability: "ready",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "choose-tools-generation",
      runtimeAlignment: "current",
      redacted: false,
      servers: [toolsNotAllowed],
    }),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const dialog = screen.getByRole("dialog", { name: "GitHub" });
  assert.ok(within(dialog).getByRole("button", { name: "Choose tools" }));
  assert.ok(
    within(dialog).getByText(
      "2 tools were discovered. Choose which ones new tasks may use.",
    ),
  );
  assert.ok(within(dialog).getByRole("heading", { name: "Tool permissions" }));
});

test("MCP keeps a missing connection read-only instead of guessing repair data", () => {
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: true,
      servers: [
        {
          ...servers[0],
          authMode: "none",
          negotiation: "automatic",
          timeoutMs: 1,
          connection: null,
          approvalStatus: "unapproved",
          authorizationStatus: "not_required",
          canAuthorize: false,
          runtimeStatus: "invalid_catalog",
          newTaskAccess: "unavailable",
          tools: [],
        },
      ],
    }),
  );

  const enablement = screen.getByRole("switch", { name: "GitHub enabled" });
  assert.equal(enablement.getAttribute("aria-disabled"), "true");
  assert.ok(
    document
      .getElementById(enablement.getAttribute("aria-describedby"))
      .textContent.includes("Connection settings are unavailable"),
  );
  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const dialog = screen.getByRole("dialog", { name: "GitHub" });
  assert.ok(dialog.textContent.includes("Connection settings unavailable"));
  assert.equal(
    within(dialog).getByRole("button", { name: "Edit connection" }).disabled,
    true,
  );
  assert.equal(
    within(dialog).queryByRole("button", { name: "Test connection" }),
    null,
  );
  assert.equal(
    within(dialog).queryByRole("button", { name: "Connect and enable" }),
    null,
  );
  assert.equal(within(dialog).queryByRole("button", { name: "Enable" }), null);
  assert.equal(
    within(dialog).getByRole("textbox", { name: "Display name" }).disabled,
    true,
  );
  assert.ok(within(dialog).getByRole("button", { name: "Delete server" }));
});

test("MCP STDIO detail and edit preserve command, ordered arguments, and cwd", () => {
  render(
    pageElement({
      availability: "ready",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "7",
      runtimeAlignment: "current",
      redacted: false,
      servers: [servers[2]],
    }),
  );

  fireEvent.click(screen.getByRole("button", { name: /Filesystem/ }));
  let dialog = screen.getByRole("dialog", { name: "Filesystem" });
  assert.ok(dialog.textContent.includes("/usr/local/bin/filesystem-server"));
  assert.ok(dialog.textContent.includes("--root"));
  assert.ok(dialog.textContent.includes("/workspace"));

  fireEvent.click(
    within(dialog).getByRole("button", { name: "Edit connection" }),
  );
  dialog = screen.getByRole("dialog", {
    name: "Edit connection settings",
  });
  assert.equal(
    within(dialog).getByRole("textbox", { name: "Executable" }).value,
    "/usr/local/bin/filesystem-server",
  );
  assert.equal(
    within(dialog).getByRole("textbox", {
      name: "Working directory (optional)",
    }).value,
    "/workspace",
  );
});

test("MCP unmodified structured Edit submits literal argv and supports independent argument editing", async () => {
  const calls = [];
  const original = [
    "",
    "--filter=$HOME",
    "`literal`",
    "C:\\Data Files\\",
    'a"b',
  ];
  const server = {
    ...servers[2],
    connection: {
      ...servers[2].connection,
      command: "C:\\Program Files\\mcp.exe",
      arguments: original,
    },
  };
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "7",
        runtimeAlignment: "current",
        redacted: false,
        servers: [server],
      },
      "",
      {
        onUpdateStdio: async (...args) => {
          calls.push(args);
          return { outcome: "rejected" };
        },
      },
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: /Filesystem/ }));
  fireEvent.click(screen.getByRole("button", { name: "Edit connection" }));
  const form = screen.getByRole("dialog", { name: "Edit connection settings" });
  const save = within(form).getByRole("button", { name: "Save connection" });
  assert.equal(save.disabled, false);
  fireEvent.click(save);
  await waitFor(() => assert.equal(calls.length, 1));
  assert.equal(calls[0][2].command, server.connection.command);
  assert.deepEqual(calls[0][2].arguments, original);
  fireEvent.change(within(form).getByRole("textbox", { name: "Argument 2" }), {
    target: { value: "changed $literal" },
  });
  fireEvent.click(save);
  await waitFor(() => assert.equal(calls.length, 2));
  assert.deepEqual(calls[1][2].arguments, [
    "",
    "changed $literal",
    ...original.slice(2),
  ]);
  assert.equal(calls[1][2].cwd, server.connection.cwd);
});

test("MCP tests a saved connection without refreshing the current Runtime", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "7",
        runtimeAlignment: "restart_required",
        redacted: false,
        servers,
      },
      "",
      {
        onTest: async (...args) => {
          calls.push(args);
          return { outcome: "started" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  fireEvent.click(screen.getByRole("button", { name: "Test connection" }));
  await waitFor(() => assert.deepEqual(calls, [["7", "github-binding"]]));
  assert.equal(
    screen.queryByText("Opening an isolated test connection."),
    null,
  );
});

test("MCP page distinguishes unavailable, empty, filtered, and redacted states", () => {
  const view = render(
    pageElement({
      availability: "unavailable",
      managementHealth: "unavailable",
      operation: "idle",
      desiredGeneration: null,
      runtimeAlignment: "unknown",
      redacted: false,
      servers: [],
    }),
  );
  assert.ok(screen.getByText("MCP management is unavailable"));

  view.rerender(
    pageElement({
      availability: "ready",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "1",
      runtimeAlignment: "current",
      redacted: false,
      servers: [],
    }),
  );
  assert.ok(screen.getByText("No MCP servers yet"));
  assert.ok(screen.getByText(/Share its link with the agent in a task/));
  assert.ok(screen.getByRole("button", { name: "Add manually" }));
  assert.equal(
    screen.queryByRole("button", { name: "Paste configuration" }),
    null,
  );

  view.rerender(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "2",
        runtimeAlignment: "current",
        redacted: true,
        servers: [servers[0]],
      },
      "missing",
    ),
  );
  assert.ok(screen.getByText("No matching servers or tools"));
  assert.equal(
    screen.queryByText(/Share its link with the agent in a task/),
    null,
  );
  assert.ok(screen.getByRole("button", { name: "Add manually" }));
  assert.equal(
    screen.queryByRole("button", { name: "Paste configuration" }),
    null,
  );
});

test("MCP search covers server identity, transport, and tool name", () => {
  assert.deepEqual(
    filterMcpServers(servers, "CREATE_ISSUE").map((server) => server.id),
    ["github-binding"],
  );
  assert.deepEqual(
    filterMcpServers(servers, "read_file").map((server) => server.id),
    ["filesystem-binding"],
  );
  assert.deepEqual(
    filterMcpServers(servers, "streamable_http").map((server) => server.id),
    ["github-binding", "notion-binding"],
  );
});

test("MCP checks a remote draft before asking the user to add it", async () => {
  const calls = [];
  const tests = [];
  const probes = [];
  let finishProbe;
  const view = render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "generation-9",
        runtimeAlignment: "current",
        redacted: false,
        servers: [],
      },
      "",
      {
        onProbeHttpDraft: (...args) => {
          probes.push(args);
          return new Promise((resolve) => {
            finishProbe = resolve;
          });
        },
        onVerifyAndAddHttpDraft: async (...args) => {
          calls.push(args);
          return {
            outcome: "saved",
            desiredGeneration: "generation-10",
            serverId: "local-search-binding",
          };
        },
        onTest: async (...args) => {
          tests.push(args);
          return { outcome: "started" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: "Add manually" }));
  const dialog = screen.getByRole("dialog", {
    name: "Add an MCP server",
  });
  assert.equal(
    within(dialog).queryByRole("textbox", { name: "Executable" }),
    null,
  );
  assert.equal(
    within(dialog).queryByRole("group", { name: "Connection type" }),
    null,
  );
  assert.equal(
    within(dialog).queryByRole("group", { name: "Authentication" }),
    null,
  );
  assert.equal(within(dialog).queryByRole("checkbox"), null);
  assert.equal(within(dialog).queryByText("Protocol policy"), null);
  assert.equal(within(dialog).queryByText("Timeout (ms)"), null);
  const endpoint = within(dialog).getByRole("textbox", {
    name: "Server address",
  });
  const displayName = within(dialog).getByRole("textbox", {
    name: "Display name",
  });
  assert.equal(displayName.value, "");
  const submit = within(dialog).getByRole("button", { name: "Continue" });
  assert.equal(
    within(dialog).queryByRole("button", { name: "Add server" }),
    null,
  );
  assert.equal(endpoint.hasAttribute("aria-describedby"), false);

  fireEvent.change(endpoint, {
    target: { value: "http://example.com/mcp" },
  });
  assert.equal(endpoint.getAttribute("aria-invalid"), "true");
  assert.ok(endpoint.getAttribute("aria-describedby"));
  assert.equal(submit.disabled, true);
  fireEvent.change(endpoint, {
    target: { value: "http://127.0.0.1:4312/mcp" },
  });
  assert.equal(displayName.value, "");
  assert.equal(submit.disabled, true);
  fireEvent.change(displayName, { target: { value: "Local search" } });
  assert.equal(submit.disabled, false);
  fireEvent.click(submit);
  assert.deepEqual(probes, [
    ["generation-9", "Local search", "http://127.0.0.1:4312/mcp"],
  ]);
  assert.equal(calls.length, 0);
  finishProbe({ outcome: "failed" });
  await within(dialog).findByText(/Couldn't complete the MCP handshake/);
  assert.equal(calls.length, 0);
  assert.equal(displayName.value, "Local search");
  assert.equal(endpoint.value, "http://127.0.0.1:4312/mcp");
  fireEvent.click(submit);
  assert.equal(probes.length, 2);
  assert.equal(calls.length, 0);
  finishProbe({ outcome: "connected" });

  let review = await screen.findByRole("dialog", {
    name: "Confirm MCP server",
  });
  assert.equal(calls.length, 0);
  assert.ok(within(review).getByText("Local search"));
  assert.ok(within(review).getByText("http://127.0.0.1:4312/mcp"));
  fireEvent.click(within(review).getByRole("button", { name: "Back" }));
  const draft = screen.getByRole("dialog", { name: "Add an MCP server" });
  const draftEndpoint = within(draft).getByRole("textbox", {
    name: "Server address",
  });
  assert.equal(draftEndpoint.value, "http://127.0.0.1:4312/mcp");
  fireEvent.change(draftEndpoint, {
    target: { value: "http://127.0.0.1:4312/updated" },
  });
  fireEvent.click(within(draft).getByRole("button", { name: "Continue" }));
  assert.deepEqual(probes.at(-1), [
    "generation-9",
    "Local search",
    "http://127.0.0.1:4312/updated",
  ]);
  finishProbe({ outcome: "connected" });
  review = await screen.findByRole("dialog", { name: "Confirm MCP server" });
  assert.equal(calls.length, 0);
  fireEvent.click(within(review).getByRole("button", { name: "Add server" }));

  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], [
    "generation-9",
    "Local search",
    "http://127.0.0.1:4312/updated",
    [],
  ]);
  assert.equal(tests.length, 0);
  // The form stays open until the refreshed canonical projection surfaces the
  // saved server; the Renderer does not guess its new identity.
  assert.ok(screen.getByRole("dialog"));
  view.rerender(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "generation-10",
        runtimeAlignment: "restart_required",
        redacted: false,
        servers: [
          {
            ...servers[0],
            id: "local-search-binding",
            displayName: "Local search",
            namespace: "mcp_local_search",
            authMode: "none",
            authorizationStatus: "not_required",
            canAuthorize: false,
            connectionTest: {
              status: "untested",
              toolCount: 0,
              issueCount: 0,
            },
          },
        ],
      },
      "",
      {
        onTest: async (...args) => {
          tests.push(args);
          return { outcome: "started" };
        },
      },
    ),
  );
  await waitFor(() =>
    assert.ok(screen.getByRole("dialog", { name: "Local search" })),
  );
  assert.equal(tests.length, 0);
});

test("MCP continues to authentication after a bare 401 without guessing a sign-in method", async () => {
  const calls = [];
  render(
    pageElement(emptyManagement, "", {
      onProbeHttpDraft: async () => ({ outcome: "authentication_required" }),
      onVerifyAndAddHttpDraft: async (...args) => {
        calls.push(args);
        return { outcome: "failed" };
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Add manually" }));
  const first = screen.getByRole("dialog", { name: "Add an MCP server" });
  fireEvent.change(within(first).getByLabelText("Display name"), {
    target: { value: "Protected service" },
  });
  fireEvent.change(within(first).getByLabelText("Server address"), {
    target: { value: "https://mcp.example.test/mcp" },
  });
  fireEvent.click(within(first).getByRole("button", { name: "Continue" }));
  const review = await screen.findByRole("dialog", {
    name: "Confirm MCP server",
  });
  assert.match(review.textContent, /server requires authentication/);
  assert.equal(
    within(review).queryAllByRole("radio", { checked: true }).length,
    0,
  );
  assert.equal(
    within(review).getByRole("button", { name: "Add server" }).disabled,
    true,
  );
  assert.deepEqual(calls, []);
});

test("MCP saves a detected OAuth server and offers sign-in in its details", async () => {
  const pendingServer = {
    ...servers[1],
    displayName: "Protected service",
    authorizationStatus: "client_registration_required",
    runtimeStatus: "not_loaded",
    safeDiagnostic: "",
  };
  const creates = [];
  const authorizations = [];
  const actions = {
    onProbeHttpDraft: async () => ({ outcome: "oauth_automatic" }),
    onCreateOAuthHttp: async (...args) => {
      creates.push(args);
      return {
        outcome: "saved",
        desiredGeneration: "1",
        serverId: pendingServer.id,
      };
    },
    onAuthorize: async (...args) => {
      authorizations.push(args);
      return { outcome: "started", operationId: "op-1" };
    },
  };
  const view = render(pageElement(emptyManagement, "", actions));
  fireEvent.click(screen.getByRole("button", { name: "Add manually" }));
  const first = screen.getByRole("dialog", { name: "Add an MCP server" });
  fireEvent.change(within(first).getByLabelText("Display name"), {
    target: { value: pendingServer.displayName },
  });
  fireEvent.change(within(first).getByLabelText("Server address"), {
    target: { value: pendingServer.connection.endpoint },
  });
  fireEvent.click(within(first).getByRole("button", { name: "Continue" }));
  const review = await screen.findByRole("dialog", {
    name: "Confirm MCP server",
  });
  fireEvent.click(within(review).getByRole("button", { name: "Add server" }));
  await waitFor(() =>
    assert.deepEqual(creates, [
      [
        "0",
        {
          displayName: pendingServer.displayName,
          endpoint: pendingServer.connection.endpoint,
          authMode: "oauth",
          negotiation: "automatic",
          timeoutMs: 30000,
          registration: { kind: "automatic" },
          headerNames: [],
        },
      ],
    ]),
  );
  view.rerender(
    pageElement(
      {
        ...emptyManagement,
        desiredGeneration: "1",
        servers: [pendingServer],
      },
      "",
      actions,
    ),
  );
  const details = await screen.findByRole("dialog", {
    name: pendingServer.displayName,
  });
  assert.deepEqual(authorizations, []);
  const signIn = within(details).getAllByRole("button", { name: "Sign in" })[0];
  fireEvent.click(signIn);
  await waitFor(() =>
    assert.deepEqual(authorizations, [["1", pendingServer.id]]),
  );
});

test("MCP checks the redirected address for OAuth and uses it for final verification", async () => {
  const probes = [];
  const calls = [];
  let finishVerification;
  render(
    pageElement(emptyManagement, "", {
      onProbeHttpDraft: async (_generation, _name, endpoint) => {
        probes.push(endpoint);
        return probes.length === 1
          ? {
              outcome: "redirected",
              endpoint: "https://mcp.example.test/connect?route=updated",
            }
          : { outcome: "oauth_automatic" };
      },
      onVerifyAndAddHttpDraft: (...args) => {
        calls.push(args);
        return new Promise((resolve) => {
          finishVerification = resolve;
        });
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Add manually" }));
  const first = screen.getByRole("dialog", { name: "Add an MCP server" });
  fireEvent.change(within(first).getByLabelText("Display name"), {
    target: { value: "Protected service" },
  });
  fireEvent.change(within(first).getByLabelText("Server address"), {
    target: { value: "https://mcp.example.test/entry?route=original" },
  });
  fireEvent.click(within(first).getByRole("button", { name: "Continue" }));
  const review = await screen.findByRole("dialog", {
    name: "Confirm MCP server",
  });
  assert.deepEqual(probes, [
    "https://mcp.example.test/entry?route=original",
    "https://mcp.example.test/connect?route=updated",
  ]);
  assert.ok(
    within(review).getByText("https://mcp.example.test/connect?route=updated"),
  );
  assert.equal(
    within(review).getByRole("radio", { name: "OAuth Detected" }).checked,
    true,
  );
  assert.equal(
    within(review).getByRole("radio", {
      name: "Register automatically Detected",
    }).checked,
    true,
  );
  const add = within(review).getByRole("button", { name: "Add server" });
  assert.equal(add.disabled, false);
  fireEvent.click(within(review).getByRole("radio", { name: "Without OAuth" }));
  fireEvent.click(within(review).getByText("Request headers"));
  fireEvent.click(within(review).getByRole("button", { name: "Add header" }));
  assert.equal(add.disabled, true);
  fireEvent.change(within(review).getByLabelText("Name"), {
    target: { value: "Authorization" },
  });
  const value = within(review).getByLabelText("Value");
  assert.equal(value.type, "password");
  fireEvent.change(value, { target: { value: "Bearer fixture-draft" } });
  fireEvent.click(add);
  assert.deepEqual(calls, [
    [
      "0",
      "Protected service",
      "https://mcp.example.test/connect?route=updated",
      [{ name: "Authorization", value: "Bearer fixture-draft" }],
    ],
  ]);
  assert.equal(value.value, "");
  finishVerification({ outcome: "failed" });
  await within(review).findByText(
    /final configuration could not complete the MCP handshake/,
  );
  assert.equal(within(review).getByLabelText("Name").value, "Authorization");
});

test("MCP ignores a successful draft check after the user cancels", async () => {
  let finishProbe;
  const calls = [];
  render(
    pageElement(emptyManagement, "", {
      onProbeHttpDraft: () =>
        new Promise((resolve) => {
          finishProbe = resolve;
        }),
      onVerifyAndAddHttpDraft: async (...args) => {
        calls.push(args);
      },
    }),
  );
  fireEvent.click(screen.getByRole("button", { name: "Add manually" }));
  const dialog = screen.getByRole("dialog", { name: "Add an MCP server" });
  fireEvent.change(within(dialog).getByLabelText("Display name"), {
    target: { value: "New service" },
  });
  fireEvent.change(within(dialog).getByLabelText("Server address"), {
    target: { value: "https://mcp.example.test/mcp" },
  });
  fireEvent.click(within(dialog).getByRole("button", { name: "Continue" }));
  fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }));
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  await Promise.resolve(finishProbe({ outcome: "connected" }));
  assert.deepEqual(calls, []);
  fireEvent.click(screen.getByRole("button", { name: "Add manually" }));
  assert.equal(screen.getByLabelText("Display name").value, "");
});

test("MCP edit can add OAuth to a saved remote server", async () => {
  const calls = [];
  const server = {
    ...servers[0],
    authMode: "none",
    authorizationStatus: "not_required",
    connection: {
      ...servers[0].connection,
      endpoint: "https://mcp.example.test/mcp",
      registrationKind: null,
    },
  };
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "12",
        runtimeAlignment: "current",
        redacted: false,
        servers: [server],
      },
      "",
      {
        onUpdateHttp: async (...args) => {
          calls.push(args);
          return { outcome: "saved", desiredGeneration: "13" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  fireEvent.click(screen.getByRole("button", { name: "Edit connection" }));
  const dialog = screen.getByRole("dialog", {
    name: "Edit connection settings",
  });
  assert.equal(
    within(dialog).getByRole("textbox", { name: "Server address" }).value,
    server.connection.endpoint,
  );
  fireEvent.click(within(dialog).getByRole("radio", { name: "OAuth" }));
  fireEvent.click(
    within(dialog).getByRole("combobox", { name: "Client registration" }),
  );
  const existingClientOption = await screen.findByRole("option", {
    name: "Existing client",
  });
  fireEvent.pointerDown(existingClientOption);
  fireEvent.click(existingClientOption);
  await waitFor(() =>
    within(dialog).getByRole("textbox", { name: "Client ID" }),
  );
  fireEvent.change(within(dialog).getByRole("textbox", { name: "Client ID" }), {
    target: { value: "desktop-client" },
  });
  fireEvent.click(
    within(dialog).getByRole("combobox", {
      name: "Token endpoint client authentication",
    }),
  );
  const clientSecretBasicOption = await screen.findByRole("option", {
    name: "Client secret (HTTP Basic)",
  });
  fireEvent.pointerDown(clientSecretBasicOption);
  fireEvent.click(clientSecretBasicOption);
  fireEvent.click(
    within(dialog).getByRole("button", { name: "Save connection" }),
  );

  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], [
    "12",
    server.id,
    {
      displayName: server.displayName,
      negotiation: "automatic",
      timeoutMs: 30000,
      endpoint: "https://mcp.example.test/mcp",
      authMode: "oauth",
      headerNames: [],
      registration: {
        kind: "pre_registered",
        clientId: "desktop-client",
        tokenEndpointAuthMethod: "client_secret_basic",
      },
    },
  ]);
  assert.equal(JSON.stringify(calls).includes("clientSecret"), false);
});

test("MCP gates OAuth client secret recovery and configuration on credential submission", async () => {
  const oauthAwaitingSecret = {
    ...servers[0],
    connection: {
      ...servers[0].connection,
      registrationKind: "pre_registered",
      clientId: "desktop-client",
      tokenEndpointAuthMethod: "client_secret_basic",
      clientSecretStatus: "missing",
    },
    authorizationStatus: "capability_unavailable",
    canAuthorize: false,
    runtimeStatus: "needs_authentication",
    newTaskAccess: "unavailable",
  };
  render(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "oauth-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [oauthAwaitingSecret],
      },
      "",
      {
        capabilities: {
          connectionApproval: true,
          secretCapture: false,
          secretMaxBytes: 2560,
          oauth: true,
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const detail = screen.getByRole("dialog", { name: "GitHub" });
  assert.ok(
    within(detail).getAllByText(
      "Credential submission is currently unavailable.",
    ).length >= 1,
  );
  assert.equal(
    within(detail).queryByRole("button", { name: "Set credentials" }),
    null,
  );

  fireEvent.click(
    within(detail).getByRole("button", { name: "Edit connection" }),
  );
  const form = screen.getByRole("dialog", {
    name: "Edit connection settings",
  });
  fireEvent.click(
    within(form).getByRole("combobox", {
      name: "Token endpoint client authentication",
    }),
  );
  const basic = await screen.findByRole("option", {
    name: "Client secret (HTTP Basic)",
  });
  const post = screen.getByRole("option", {
    name: "Client secret (request body)",
  });
  assert.notEqual(basic.getAttribute("aria-disabled"), "true");
  assert.equal(post.getAttribute("aria-disabled"), "true");
  assert.ok(
    within(form).getByText(
      "Credential submission is temporarily unavailable. An existing selection can be preserved.",
    ),
  );
});

test("MCP endpoint validation matches the Host authority contract", () => {
  for (const endpoint of endpointContract.accepted)
    assert.equal(validMcpHttpEndpoint(endpoint), true, endpoint);
  for (const endpoint of endpointContract.rejected)
    assert.equal(validMcpHttpEndpoint(endpoint), false, endpoint);
});

test("MCP launch command is tokenized without invoking shell syntax", () => {
  assert.deepEqual(
    parseMcpCommandLine(
      'npx -y "@modelcontextprotocol/server-filesystem" "/workspace files"',
    ),
    [
      "npx",
      "-y",
      "@modelcontextprotocol/server-filesystem",
      "/workspace files",
    ],
  );
  assert.equal(parseMcpCommandLine("npx server | tee output"), null);
  assert.equal(parseMcpCommandLine("npx $(whoami)"), null);
  assert.equal(parseMcpCommandLine('npx "unterminated'), null);
});

test("MCP tool allowlist mutation sends exact desired tools and generation", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "7",
        runtimeAlignment: "current",
        redacted: false,
        servers: [servers[0]],
      },
      "",
      {
        onSetAllowedTools: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  fireEvent.click(
    screen.getByRole("checkbox", { name: /Allow create_issue for new tasks/ }),
  );
  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], ["7", "github-binding", ["search_repositories"]]);
});

test("MCP edit preloads and preserves the complete public destination", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "replacement-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [servers[0]],
      },
      "",
      {
        onUpdateHttp: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  fireEvent.click(screen.getByRole("button", { name: "Edit connection" }));
  const dialog = screen.getByRole("dialog", {
    name: "Edit connection settings",
  });
  assert.ok(
    dialog.textContent.includes("Change the saved non-secret settings"),
  );
  const endpoint = within(dialog).getByRole("textbox", {
    name: "Server address",
  });
  const submit = within(dialog).getByRole("button", {
    name: "Save connection",
  });
  assert.equal(endpoint.value, "https://github.example/mcp");
  assert.equal(submit.disabled, false);
  fireEvent.click(submit);

  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], [
    "replacement-generation",
    "github-binding",
    {
      displayName: "GitHub",
      negotiation: "automatic",
      timeoutMs: 30000,
      endpoint: "https://github.example/mcp",
      authMode: "oauth",
      headerNames: [],
      registration: { kind: "automatic" },
    },
  ]);
});

test("MCP keeps approved enable intent separate from authentication readiness", async () => {
  const calls = [];
  const awaitingSecret = {
    ...servers[2],
    authMode: "static",
    connection: {
      ...servers[2].connection,
      environment: [{ name: "TOKEN", status: "missing" }],
    },
    approvalStatus: "approved",
    authorizationStatus: "missing_static_secret",
    canAuthorize: false,
    desiredEnabled: false,
    runtimeStatus: "needs_authentication",
    newTaskAccess: "unavailable",
  };
  render(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "auth-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [awaitingSecret],
      },
      "",
      {
        onSetEnabled: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /Filesystem/ }));
  const enable = screen.getByRole("button", { name: "Enable" });
  assert.equal(enable.disabled, false);
  fireEvent.click(enable);
  const confirmation = screen.getByRole("alertdialog", {
    name: "Enable this server?",
  });
  assert.ok(
    confirmation.textContent.includes(
      "this restores the previous tool access (1 selected) for new tasks",
    ),
  );
  fireEvent.click(
    within(confirmation).getByRole("button", { name: "Enable server" }),
  );
  await waitFor(() =>
    assert.deepEqual(calls, [["auth-generation", "filesystem-binding", true]]),
  );
});

test("MCP enables a server directly when no tool authority is restored", async () => {
  const calls = [];
  const noGrantedTools = {
    ...servers[2],
    tools: servers[2].tools.map((tool) => ({
      ...tool,
      desiredAllowed: false,
    })),
  };
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "empty-authority-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [noGrantedTools],
      },
      "",
      {
        onSetEnabled: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("switch", { name: "Filesystem enabled" }));
  assert.equal(screen.queryByRole("alertdialog"), null);
  await waitFor(() =>
    assert.deepEqual(calls, [
      ["empty-authority-generation", "filesystem-binding", true],
    ]),
  );
});

test("MCP approval and OAuth operation actions stay Host-owned and typed", async () => {
  const approvals = [];
  const cancellations = [];
  const unapproved = {
    ...servers[2],
    approvalStatus: "unapproved",
    desiredEnabled: false,
    runtimeStatus: "needs_authentication",
    newTaskAccess: "unavailable",
  };
  const view = render(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "13",
        runtimeAlignment: "current",
        redacted: false,
        servers: [unapproved],
      },
      "",
      {
        onApprove: async (...args) => {
          approvals.push(args);
          return { outcome: "saved" };
        },
        onCancelAuthorization: async (...args) => {
          cancellations.push(args);
          return { outcome: "cancelled" };
        },
      },
    ),
  );
  const enablement = screen.getByRole("switch", {
    name: "Filesystem enabled",
  });
  assert.equal(enablement.getAttribute("aria-disabled"), "true");
  assert.ok(
    document
      .getElementById(enablement.getAttribute("aria-describedby"))
      .textContent.includes("finish connecting this server"),
  );
  fireEvent.click(screen.getByRole("button", { name: /Filesystem/ }));
  fireEvent.click(screen.getByRole("button", { name: "Connect and enable" }));
  await waitFor(() =>
    assert.deepEqual(approvals, [["13", "filesystem-binding"]]),
  );
  view.rerender(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        authorizationOperation: {
          kind: "awaiting_browser",
          serverId: "notion-binding",
          operationId: "oauth-op-7",
        },
        desiredGeneration: "14",
        runtimeAlignment: "current",
        redacted: false,
        servers: [servers[1]],
      },
      "",
      {
        onCancelAuthorization: async (...args) => {
          cancellations.push(args);
          return { outcome: "cancelled" };
        },
      },
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: /Notion/ }));
  assert.equal(
    screen.getByRole("button", { name: "Edit connection" }).disabled,
    true,
  );
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  await waitFor(() => assert.deepEqual(cancellations, [["oauth-op-7"]]));
});

test("MCP destructive changes require an explicit confirmation", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "7",
        runtimeAlignment: "current",
        redacted: false,
        servers: [servers[0]],
      },
      "",
      {
        onRemove: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  const deleteButton = screen.getByRole("button", { name: "Delete server" });
  fireEvent.click(deleteButton);
  let confirmation = screen.getByRole("alertdialog", {
    name: "Delete this server?",
  });
  const cancel = within(confirmation).getByRole("button", { name: "Cancel" });
  assert.equal(document.activeElement, cancel);
  assert.ok(within(confirmation).getByText(/Renewal stops after deletion/));

  fireEvent.keyDown(document.activeElement, { key: "Escape" });
  await waitFor(() => assert.equal(screen.queryByRole("alertdialog"), null));
  await new Promise((resolve) => window.requestAnimationFrame(resolve));
  assert.equal(document.activeElement, deleteButton);

  fireEvent.click(deleteButton);
  confirmation = screen.getByRole("alertdialog", {
    name: "Delete this server?",
  });
  assert.equal(calls.length, 0);
  fireEvent.click(
    within(confirmation).getByRole("button", { name: "Delete server" }),
  );
  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], ["7", "github-binding"]);
});

test("MCP freezes unconfirmed desired state and offers in-place apply recovery", () => {
  const view = render(
    pageElement({
      availability: "unavailable",
      managementHealth: "outcome_unknown",
      operation: "idle",
      desiredGeneration: null,
      runtimeAlignment: "unknown",
      redacted: false,
      servers: [],
    }),
  );
  assert.ok(screen.getByText("The last save result is unknown"));
  // Frozen unknown-outcome state hides mutating entry points entirely.
  assert.equal(screen.queryByRole("button", { name: "Add manually" }), null);

  view.rerender(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "8",
      runtimeAlignment: "restart_required",
      redacted: false,
      servers: [
        {
          ...servers[0],
          newTaskAccess: "restart_required",
        },
      ],
    }),
  );
  assert.ok(screen.getByText("Connection changes were not applied"));
  assert.ok(
    screen.getByText(
      "Your settings are saved. Open a service to retry its connection or sign in again.",
    ),
  );
  assert.ok(screen.getByRole("button", { name: "Retry connection" }));
});

test("MCP distinguishes unapplied connections from a loaded runtime missing its catalog", async () => {
  const calls = [];
  const pending = {
    ...servers[0],
    runtimeStatus: "not_loaded",
    newTaskAccess: "unavailable",
    safeDiagnostic: "Tool catalog is unavailable. Select Refresh to retry.",
    tools: [],
  };
  const management = {
    availability: "unavailable",
    managementHealth: "ready",
    operation: "idle",
    desiredGeneration: "8",
    runtimeAlignment: "current",
    configurationApply: "idle",
    redacted: false,
    servers: [pending],
  };
  const handlers = {
    onApply: async () => {
      calls.push("apply");
      return { outcome: "started" };
    },
    onRefresh: async () => {
      calls.push("refresh");
      return { outcome: "started" };
    },
  };
  const view = render(pageElement(management, "", handlers));
  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  let dialog = screen.getByRole("dialog");
  assert.equal(within(dialog).queryByText("Cannot connect"), null);
  assert.ok(within(dialog).getByText(pending.safeDiagnostic));
  assert.equal(
    within(dialog).queryByRole("heading", { name: "Tool permissions" }),
    null,
  );
  fireEvent.click(
    within(dialog).getByRole("button", { name: "Retry connection" }),
  );
  await waitFor(() => assert.deepEqual(calls, ["refresh"]));
  view.rerender(
    pageElement(
      {
        ...management,
        configurationApply: "failed",
        runtimeAlignment: "restart_required",
        applyFailureCount: 1,
        servers: [
          {
            ...pending,
            applyStatus: "rejected",
            safeDiagnostic:
              "Configuration changes were not applied. Retry the connection.",
          },
        ],
      },
      "",
      handlers,
    ),
  );
  dialog = screen.getByRole("dialog");
  fireEvent.click(
    within(dialog).getByRole("button", { name: "Retry connection" }),
  );
  await waitFor(() => assert.deepEqual(calls, ["refresh", "apply"]));
  assert.ok(
    within(dialog).getByText(
      "The settings are saved. The server has not loaded.",
    ),
  );
  assert.equal(within(dialog).queryByText(/^Connection requested\./), null);
  assert.equal(within(dialog).queryByText("Needs attention"), null);
  assert.ok(screen.getByText("Connection changes were not applied"));
  assert.equal(screen.queryByText("Cannot connect"), null);
});

test("MCP password input submits once and clears drafts on cancel, byte limit, revision and close", async () => {
  const server = {
    ...servers[2],
    authMode: "static",
    connection: {
      ...servers[2].connection,
      environment: [{ name: "TOKEN", status: "set" }],
    },
  };
  const management = {
    availability: "ready",
    managementHealth: "ready",
    operation: "idle",
    desiredGeneration: "7",
    runtimeAlignment: "current",
    redacted: false,
    servers: [server],
  };
  const calls = [];
  let complete;
  const overrides = {
    onCaptureSecret: (...args) => {
      calls.push(args);
      return new Promise((resolve) => {
        complete = resolve;
      });
    },
  };
  const view = render(pageElement(management, "", overrides));
  const open = () =>
    fireEvent.click(screen.getByRole("button", { name: /Filesystem/ }));
  const field = () => screen.getByLabelText("TOKEN");
  open();
  assert.equal(field().type, "password");
  assert.equal(field().value, "");
  fireEvent.change(field(), { target: { value: " opaque Ω value " } });
  fireEvent.submit(field().closest("form"));
  fireEvent.submit(field().closest("form"));
  assert.deepEqual(calls, [
    [
      "7",
      server.id,
      { kind: "stdio_environment", name: "TOKEN" },
      " opaque Ω value ",
    ],
  ]);
  assert.equal(field().value, "");
  complete({ outcome: "rejected" });
  await waitFor(() => assert.equal(field().disabled, false));
  assert.equal(field().value, "");

  fireEvent.change(field(), { target: { value: "cancelled-draft" } });
  fireEvent.click(
    within(field().closest("form")).getByRole("button", { name: "Cancel" }),
  );
  assert.equal(field().value, "");
  fireEvent.change(field(), { target: { value: "x".repeat(2561) } });
  assert.equal(field().validity.customError, true);
  view.rerender(
    pageElement(management, "", {
      ...overrides,
      capabilities: {
        connectionApproval: true,
        secretCapture: true,
        secretMaxBytes: 1024,
        oauth: true,
      },
    }),
  );
  assert.equal(field().value, "");
  assert.equal(field().validity.customError, false);
  fireEvent.change(field(), { target: { value: "x".repeat(1025) } });
  fireEvent.submit(field().closest("form"));
  assert.equal(field().validity.customError, true);
  assert.equal(calls.length, 1);
  fireEvent.change(field(), { target: { value: "stale-draft" } });
  view.rerender(
    pageElement({ ...management, desiredGeneration: "8" }, "", overrides),
  );
  assert.equal(field().value, "");

  fireEvent.change(field(), { target: { value: "closed-draft" } });
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", { name: "Close" }),
  );
  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  open();
  assert.equal(field().value, "");

  fireEvent.change(field(), { target: { value: "unavailable-draft" } });
  view.rerender(
    pageElement({ ...management, desiredGeneration: "8" }, "", {
      ...overrides,
      disabled: true,
    }),
  );
  await waitFor(() => assert.equal(field().value, ""));
  assert.equal(field().disabled, true);
  assert.equal(calls.length, 1);
});

test("MCP HTTP and OAuth credentials use the same empty password form", async () => {
  for (const [oauth, maxBytes] of [
    [false, 2560],
    [true, 4096],
  ]) {
    const server = {
      ...servers[0],
      authMode: oauth ? "oauth" : "static",
      connection: {
        ...servers[0].connection,
        headers: oauth ? [] : [{ name: "Authorization", status: "missing" }],
        registrationKind: oauth ? "pre_registered" : null,
        clientId: oauth ? "client-1" : null,
        tokenEndpointAuthMethod: oauth ? "client_secret_basic" : null,
        clientSecretStatus: oauth ? "missing" : "not_required",
      },
      authorizationStatus: oauth
        ? "missing_oauth_client_secret"
        : "missing_static_secret",
      runtimeStatus: "needs_authentication",
      newTaskAccess: "unavailable",
    };
    const calls = [];
    render(
      pageElement(
        {
          availability: "degraded",
          managementHealth: "ready",
          operation: "idle",
          desiredGeneration: "7",
          runtimeAlignment: "current",
          redacted: false,
          servers: [server],
        },
        "",
        {
          capabilities: {
            connectionApproval: true,
            secretCapture: true,
            secretMaxBytes: maxBytes,
            oauth: true,
          },
          onCaptureSecret: async (...args) => {
            calls.push(args);
            return { outcome: "saved" };
          },
        },
      ),
    );
    fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
    const input = screen.getByLabelText(
      oauth ? "OAuth client secret" : "Authorization",
    );
    assert.equal(input.type, "password");
    assert.equal(input.value, "");
    for (const value of [
      "x".repeat(maxBytes + 1),
      "界".repeat(Math.floor(maxBytes / 3) + 1),
      "🔑".repeat(maxBytes / 4 + 1),
    ]) {
      fireEvent.change(input, { target: { value } });
      assert.equal(input.validity.customError, true);
      assert.equal(
        input.validationMessage,
        `The credential exceeds ${maxBytes.toLocaleString("en-US")} UTF-8 bytes. Shorten it and try again.`,
      );
      fireEvent.submit(input.closest("form"));
      assert.equal(calls.length, 0);
      assert.equal(input.value, value);
    }
    fireEvent.click(
      within(input.closest("form")).getByRole("button", { name: "Cancel" }),
    );
    assert.equal(input.value, "");
    assert.equal(input.validity.customError, false);
    const cjkBoundary =
      "界".repeat(Math.floor(maxBytes / 3)) + "x".repeat(maxBytes % 3);
    fireEvent.change(input, { target: { value: cjkBoundary } });
    assert.equal(input.checkValidity(), true);
    // Accept the Host-provided bound for both ASCII and supplementary Unicode.
    const secret = oauth ? "🔑".repeat(maxBytes / 4) : "x".repeat(maxBytes);
    fireEvent.change(input, { target: { value: secret } });
    assert.equal(input.checkValidity(), true);
    fireEvent.submit(input.closest("form"));
    await waitFor(() => assert.equal(calls.length, 1));
    assert.deepEqual(calls[0], [
      "7",
      server.id,
      oauth
        ? { kind: "oauth_client_secret" }
        : { kind: "http_header", name: "Authorization" },
      secret,
    ]);
    assert.equal(input.value, "");
    cleanup();
  }
});

test("MCP Renderer does not persist credentials or access OAuth tokens or native APIs", async () => {
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );
  assert.doesNotMatch(
    page,
    /window\.zero|localStorage|apiKey|marketplace|accessToken|refreshToken|clientSecretValue/i,
  );
});

test("MCP keeps rejected members visible after another success and retries only the selected member", async () => {
  const calls = [];
  const rejected = {
    ...servers[0],
    id: "bad",
    displayName: "Bad",
    namespace: "bad",
    applyStatus: "rejected",
    runtimeStatus: "not_loaded",
    newTaskAccess: "unavailable",
    tools: [],
  };
  render(
    pageElement(
      {
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        configurationApply: "idle",
        desiredGeneration: "8",
        runtimeAlignment: "current",
        redacted: false,
        applyFailureCount: 1,
        servers: [rejected, servers[0]],
      },
      "",
      {
        onApply: async (id) => {
          calls.push(id);
          return { outcome: "started" };
        },
      },
    ),
  );
  assert.ok(screen.getByText("Connection changes were not applied"));
  assert.ok(screen.getByText("Change rejected"));
  assert.equal(
    screen.getByRole("button", { name: /GitHub/ }).closest("li")?.dataset
      .status,
    "ready",
  );
  fireEvent.click(screen.getByRole("button", { name: /Bad/ }));
  fireEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Retry connection",
    }),
  );
  await waitFor(() => assert.deepEqual(calls, ["bad"]));
});

test("MCP shows retained members after deletion and keeps disabled edits dormant", async () => {
  const management = {
    availability: "ready",
    managementHealth: "ready",
    operation: "idle",
    desiredGeneration: "8",
    runtimeAlignment: "current",
    redacted: false,
    retainedMemberCount: 1,
    servers: [],
  };
  const view = render(pageElement(management));
  assert.ok(screen.getByText(/Services kept for existing tasks: 1/));
  view.rerender(
    pageElement({
      ...management,
      servers: [{ ...servers[2], taskReferenceCount: 2 }],
    }),
  );
  assert.ok(screen.getByText("Task references: 2"));
  const row = screen.getByRole("button", { name: /Filesystem/ });
  assert.equal(row.closest("li")?.dataset.status, "disabled");
  fireEvent.click(row);
  assert.ok(
    within(screen.getByRole("dialog")).getByText(
      /Existing tasks keep the applied configuration/,
    ),
  );
  assert.equal(
    within(screen.getByRole("dialog")).queryByRole("button", {
      name: "Retry connection",
    }),
    null,
  );
});

test("MCP unknown takeover pauses effects while retaining canonical Desired visibility", () => {
  render(
    pageElement({
      availability: "unavailable",
      managementHealth: "ready",
      operation: "idle",
      configurationApply: "failed",
      runtimeUncertain: true,
      desiredGeneration: "8",
      runtimeAlignment: "unknown",
      redacted: false,
      servers: [
        {
          ...servers[0],
          applyStatus: "unknown",
          runtimeStatus: "not_loaded",
          newTaskAccess: "unavailable",
          tools: [],
        },
      ],
    }),
  );
  assert.ok(screen.getByText("Connection change could not be confirmed"));
  assert.ok(screen.getByRole("button", { name: /GitHub/ }));
  assert.equal(
    screen.getByRole("button", { name: "Refresh tools" }).disabled,
    true,
  );
  assert.equal(
    screen.queryByRole("button", { name: "Retry connection" }),
    null,
  );
});

const oauthRecoveryProjections = JSON.parse(
  await readFile(
    new URL(
      "../src/product/mcp/testdata/oauth-recovery-view.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
for (const projection of [
  oauthRecoveryProjections.failed,
  oauthRecoveryProjections.blocked_replacement,
]) {
  test(`MCP keeps an explicit sign-in exit for a failed ready OAuth target (${projection.applyStatus})`, async () => {
    const authorized = [];
    const retried = [];
    const server = {
      ...servers[1],
      ...projection,
      runtimeStatus: "not_loaded",
      tools: [],
    };
    const management = {
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "failed-generation",
      runtimeAlignment: "current",
      redacted: false,
      applyFailureCount: 1,
      configurationApply: "failed",
      servers: [server],
    };
    const view = render(
      pageElement(management, "", {
        onAuthorize: async (...args) => {
          authorized.push(args);
          return { outcome: "started", operationId: "new-login" };
        },
        onApply: async (...args) => {
          retried.push(args);
          return { outcome: "started" };
        },
      }),
    );
    fireEvent.click(screen.getByRole("button", { name: /Notion/ }));
    const dialog = screen.getByRole("dialog", { name: "Notion" });
    fireEvent.click(
      within(dialog).getByRole("button", { name: "Retry connection" }),
    );
    await waitFor(() => assert.equal(retried.length, 1));
    assert.deepEqual(retried[0], [server.id]);
    fireEvent.click(
      within(dialog).getByRole("button", { name: "Sign in again" }),
    );
    await waitFor(() => assert.equal(authorized.length, 1));
    assert.deepEqual(authorized[0], ["failed-generation", server.id]);
    view.rerender(
      pageElement({
        ...management,
        servers: [{ ...server, canAuthorize: false }],
      }),
    );
    assert.equal(screen.queryByRole("button", { name: "Sign in again" }), null);
    view.rerender(
      pageElement(management, "", {
        capabilities: {
          connectionApproval: true,
          secretCapture: true,
          secretMaxBytes: 2560,
          oauth: false,
        },
      }),
    );
    assert.equal(screen.queryByRole("button", { name: "Sign in again" }), null);
  });
}

test("MCP distinguishes authorization waiting and refreshing without offering cancel or retry", () => {
  for (const authorizationStatus of ["ready", "refreshing"]) {
    const server = {
      ...servers[1],
      authorizationStatus,
      canAuthorize: false,
      applyStatus: "waiting_auth",
      runtimeStatus: "not_loaded",
      tools: [],
    };
    render(
      pageElement({
        availability: "degraded",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "waiting-generation",
        runtimeAlignment: "current",
        redacted: false,
        servers: [server],
        authorizationOperation:
          authorizationStatus === "refreshing"
            ? {
                kind: "exchanging",
                serverId: server.id,
                operationId: "refresh",
              }
            : { kind: "idle" },
      }),
    );
    const row = screen.getByRole("button", { name: /Notion/ });
    assert.ok(
      within(row).getByText(
        authorizationStatus === "refreshing"
          ? "Updating authorization"
          : "Waiting for authorization recovery",
      ),
    );
    fireEvent.click(row);
    const dialog = screen.getByRole("dialog", { name: "Notion" });
    assert.ok(
      within(dialog).getByText(
        "Authorization will be recovered before this connection is retried automatically.",
      ),
    );
    assert.equal(
      within(dialog).queryByRole("button", { name: "Retry connection" }),
      null,
    );
    assert.equal(
      within(dialog).queryByRole("button", { name: "Cancel authorization" }),
      null,
    );
    assert.equal(dialog.querySelector(".mcp-diagnostic"), null);

    cleanup();
  }
});

test("MCP explains the global connection wait during browser authorization", () => {
  render(
    pageElement({
      availability: "degraded",
      managementHealth: "ready",
      operation: "idle",
      desiredGeneration: "browser-generation",
      runtimeAlignment: "current",
      redacted: false,
      servers: [servers[1]],
      authorizationOperation: {
        kind: "awaiting_browser",
        serverId: servers[1].id,
        operationId: "browser",
      },
    }),
  );
  assert.ok(
    screen.getByText(
      "New server connections wait until authorization finishes. Existing tasks keep their current tools.",
    ),
  );
});

test("MCP sensitive address uses a one-shot password field and never refills a saved private address", async () => {
  const calls = [];
  let finish;
  const server = {
    ...servers[0],
    connection: {
      ...servers[0].connection,
      endpoint: "https://mcp.example",
      sensitiveEndpoint: true,
    },
  };
  render(
    pageElement(
      { ...emptyManagement, desiredGeneration: "9", servers: [server] },
      "",
      {
        onUpdateHttp: (...args) => {
          calls.push(args);
          return new Promise((resolve) => {
            finish = resolve;
          });
        },
      },
    ),
  );
  fireEvent.click(screen.getByRole("button", { name: /GitHub/ }));
  fireEvent.click(screen.getByRole("button", { name: "Edit connection" }));
  const form = screen.getByRole("dialog", { name: "Edit connection settings" });
  const replacement = within(form).getByLabelText("Server address");
  assert.equal(replacement.type, "password");
  assert.equal(replacement.value, "");
  assert.equal(
    within(form)
      .getByRole("checkbox", {
        name: /This address contains credentials/,
      })
      .getAttribute("aria-checked"),
    "true",
  );
  fireEvent.change(replacement, {
    target: { value: "https://mcp.example/k/synthetic-key?scope=one" },
  });
  fireEvent.click(
    within(form).getByRole("button", { name: "Save connection" }),
  );
  assert.equal(calls.length, 1);
  assert.equal(replacement.value, "");
  assert.equal(calls[0][2].sensitiveEndpoint, true);
  assert.equal(
    calls[0][2].endpoint,
    "https://mcp.example/k/synthetic-key?scope=one",
  );
  finish({ outcome: "rejected", desiredGeneration: "9" });
  await waitFor(() => assert.equal(replacement.disabled, false));
});
