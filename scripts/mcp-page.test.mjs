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
      onCreateStdio: unchangedMutation,
      onCreateHttp: unchangedMutation,
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
  fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));

  await waitFor(() => assert.equal(screen.queryByRole("dialog"), null));
  await waitFor(() => assert.equal(document.activeElement, row));
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

test("MCP shares the centered management-page frame and foundation Drawer", async () => {
  const [page, css] = await Promise.all([
    readFile(
      join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
      "utf8",
    ),
    readFile(join(process.cwd(), "frontend/src/index.css"), "utf8"),
  ]);

  assert.match(page, /<Drawer\.Root[\s\S]*?<Drawer\.Popup/);
  assert.match(page, /label: t\("mcp\.negotiation\.automatic"\)/);
  assert.doesNotMatch(page, /label: "Automatic"/);
  assert.match(
    css,
    /\.mcp-page-inner \{[\s\S]*?width: min\(100%, 944px\);[\s\S]*?margin: 0 auto;/,
  );
  assert.doesNotMatch(css, /\.mcp-workspace\s*\{/);
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
  assert.equal(
    dialog.querySelector(".mcp-connection-trace > div:last-child")?.dataset
      .state,
    "active",
  );
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
    within(dialog).getByRole("textbox", { name: /Launch command/ }).value,
    "/usr/local/bin/filesystem-server --root /workspace",
  );
  assert.equal(
    within(dialog).getByRole("textbox", {
      name: "Working directory (optional)",
    }).value,
    "/workspace",
  );
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
  assert.ok(screen.getByText("Opening an isolated test connection."));
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

test("MCP add selects Streamable HTTP and preserves its typed public input", async () => {
  const calls = [];
  const tests = [];
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
        onCreateHttp: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
        onTest: async (...args) => {
          tests.push(args);
          return { outcome: "started" };
        },
      },
    ),
  );

  fireEvent.click(screen.getAllByRole("button", { name: "Add server" })[0]);
  const dialog = screen.getByRole("dialog", {
    name: "Add an MCP server",
  });
  assert.ok(
    dialog.textContent.includes(
      "Credentials are collected separately and never enter this form.",
    ),
  );
  fireEvent.click(
    within(dialog).getByRole("button", { name: /Streamable HTTP/ }),
  );
  const name = within(dialog).getByRole("textbox", { name: "Display name" });
  const endpoint = within(dialog).getByRole("textbox", { name: "Endpoint" });
  const submit = within(dialog).getByRole("button", { name: "Add server" });

  fireEvent.change(name, { target: { value: "Local Search" } });
  fireEvent.change(endpoint, {
    target: { value: "http://example.com/mcp" },
  });
  assert.equal(submit.disabled, true);
  fireEvent.change(endpoint, {
    target: { value: "http://127.0.0.1:4312/mcp" },
  });
  fireEvent.change(name, { target: { value: "界".repeat(100) } });
  assert.equal(submit.disabled, true);
  fireEvent.change(name, { target: { value: "Local Search" } });
  assert.equal(submit.disabled, false);
  fireEvent.click(submit);

  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], [
    "generation-9",
    {
      displayName: "Local Search",
      negotiation: "automatic",
      timeoutMs: 30000,
      endpoint: "http://127.0.0.1:4312/mcp",
      authMode: "none",
      headerNames: [],
      registration: null,
    },
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
            displayName: "Local Search",
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
    assert.ok(screen.getByRole("dialog", { name: "Local Search" })),
  );
  assert.equal(tests.length, 0);
});

test("MCP STDIO add preserves ordered argv and names without secret values", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "11",
        runtimeAlignment: "current",
        redacted: false,
        servers: [],
      },
      "",
      {
        onCreateStdio: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getAllByRole("button", { name: "Add server" })[0]);
  const dialog = screen.getByRole("dialog", {
    name: "Add an MCP server",
  });
  fireEvent.change(
    within(dialog).getByRole("textbox", { name: "Display name" }),
    {
      target: { value: "Local files" },
    },
  );
  fireEvent.change(
    within(dialog).getByRole("textbox", { name: /Launch command/ }),
    {
      target: { value: "/usr/local/bin/files-mcp --readonly" },
    },
  );
  fireEvent.click(
    within(dialog).getByRole("radio", { name: "Static secrets" }),
  );
  fireEvent.change(
    within(dialog).getByRole("textbox", {
      name: "Environment variable names 1",
    }),
    { target: { value: "FILES_TOKEN" } },
  );
  fireEvent.click(within(dialog).getByRole("button", { name: "Add server" }));

  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], [
    "11",
    {
      displayName: "Local files",
      negotiation: "automatic",
      timeoutMs: 30000,
      command: "/usr/local/bin/files-mcp",
      arguments: ["--readonly"],
      cwd: null,
      environmentNames: ["FILES_TOKEN"],
    },
  ]);
});

test("MCP OAuth add carries an explicit client auth method and no secret", async () => {
  const calls = [];
  render(
    pageElement(
      {
        availability: "ready",
        managementHealth: "ready",
        operation: "idle",
        desiredGeneration: "12",
        runtimeAlignment: "current",
        redacted: false,
        servers: [],
      },
      "",
      {
        onCreateHttp: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getAllByRole("button", { name: "Add server" })[0]);
  const dialog = screen.getByRole("dialog", {
    name: "Add an MCP server",
  });
  fireEvent.click(
    within(dialog).getByRole("button", { name: /Streamable HTTP/ }),
  );
  fireEvent.change(
    within(dialog).getByRole("textbox", { name: "Display name" }),
    {
      target: { value: "Remote OAuth" },
    },
  );
  fireEvent.change(within(dialog).getByRole("textbox", { name: "Endpoint" }), {
    target: { value: "https://mcp.example.test/mcp" },
  });
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
  fireEvent.click(within(dialog).getByRole("button", { name: "Add server" }));

  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], [
    "12",
    {
      displayName: "Remote OAuth",
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
  const endpoint = within(dialog).getByRole("textbox", { name: "Endpoint" });
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
  assert.equal(screen.queryByRole("button", { name: "Add server" }), null);

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
  let drawer = screen.getByRole("dialog");
  assert.equal(within(drawer).queryByText("Cannot connect"), null);
  assert.ok(within(drawer).getByText(pending.safeDiagnostic));
  fireEvent.click(
    within(drawer).getByRole("button", { name: "Retry connection" }),
  );
  await waitFor(() => assert.deepEqual(calls, ["refresh"]));
  view.rerender(
    pageElement(
      {
        ...management,
        configurationApply: "failed",
        runtimeAlignment: "restart_required",
        applyFailureCount: 1,
        servers: [{ ...pending, applyStatus: "rejected" }],
      },
      "",
      handlers,
    ),
  );
  drawer = screen.getByRole("dialog");
  fireEvent.click(
    within(drawer).getByRole("button", { name: "Retry connection" }),
  );
  await waitFor(() => assert.deepEqual(calls, ["refresh", "apply"]));
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

test("MCP keeps an explicit sign-in exit for a failed ready OAuth target", async () => {
  const authorized = [];
  const retried = [];
  const server = {
    ...servers[1],
    authorizationStatus: "ready",
    canAuthorize: true,
    applyStatus: "rejected",
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
    const stages = dialog.querySelectorAll(".mcp-connection-trace > div");
    assert.equal(stages[0].dataset.state, "active");
    assert.equal(stages[1].dataset.state, "pending");
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
