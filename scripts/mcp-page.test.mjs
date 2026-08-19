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
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

const { act, cleanup, fireEvent, render, screen, waitFor, within } =
  await import("@testing-library/react");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { McpPage, filterMcpServers, validMcpHttpEndpoint } =
  await vite.ssrLoadModule("/src/features/mcp/McpPage.tsx");
const { I18nContext } = await vite.ssrLoadModule("/src/i18n/context.ts");
const { translate } = await vite.ssrLoadModule("/src/i18n/runtime.ts");
const endpointContract = JSON.parse(
  await readFile(
    join(process.cwd(), "src/workbench/testdata/mcp-http-endpoints.json"),
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
    connection: {
      kind: "stdio",
      command: "/usr/local/bin/filesystem-server",
      arguments: ["--root", "/workspace"],
      cwd: "/workspace",
      environment: [],
    },
    approvalStatus: "approved",
    authorizationStatus: "not_required",
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
        ...management,
      },
      capabilities: {
        connectionApproval: true,
        secretCapture: true,
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
  assert.ok(screen.getByText("GitHub"));
  assert.ok(screen.getByText("Notion"));
  assert.ok(screen.getByText("Filesystem"));
  assert.equal(screen.queryByText(/marketplace|install/i), null);
});

test("MCP row keeps service availability separate from the last connection test", () => {
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
  assert.ok(within(row).getByText("Failed · 2 issues"));
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
  fireEvent.click(screen.getByRole("button", { name: "Close" }));
  assert.equal(screen.queryByRole("dialog"), null);
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
          connection: null,
          runtimeStatus: "invalid_catalog",
          newTaskAccess: "unavailable",
        },
      ],
    }),
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
  dialog = screen.getByRole("dialog", { name: "Edit connection settings" });
  assert.equal(
    within(dialog).getByRole("textbox", { name: "Executable" }).value,
    "/usr/local/bin/filesystem-server",
  );
  assert.equal(
    within(dialog).getByLabelText("Ordered arguments 1").value,
    "--root",
  );
  assert.equal(
    within(dialog).getByLabelText("Ordered arguments 2").value,
    "/workspace",
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
  const dialog = screen.getByRole("dialog", { name: "Add an MCP server" });
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
  const submit = within(dialog).getByRole("button", { name: "Add and enable" });

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
  const dialog = screen.getByRole("dialog", { name: "Add an MCP server" });
  fireEvent.change(
    within(dialog).getByRole("textbox", { name: "Display name" }),
    {
      target: { value: "Local files" },
    },
  );
  fireEvent.change(
    within(dialog).getByRole("textbox", { name: "Executable" }),
    {
      target: { value: "/usr/local/bin/files-mcp" },
    },
  );
  fireEvent.click(within(dialog).getByRole("button", { name: "Add argument" }));
  fireEvent.change(
    within(dialog).getByRole("textbox", { name: "Ordered arguments 1" }),
    {
      target: { value: "--readonly" },
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
  fireEvent.click(
    within(dialog).getByRole("button", { name: "Add and enable" }),
  );

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
  const dialog = screen.getByRole("dialog", { name: "Add an MCP server" });
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
  fireEvent.click(
    within(dialog).getByRole("button", { name: "Add and enable" }),
  );

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

test("MCP endpoint validation matches the Host authority contract", () => {
  for (const endpoint of endpointContract.accepted)
    assert.equal(validMcpHttpEndpoint(endpoint), true, endpoint);
  for (const endpoint of endpointContract.rejected)
    assert.equal(validMcpHttpEndpoint(endpoint), false, endpoint);
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
  fireEvent.click(
    within(confirmation).getByRole("button", { name: "Enable server" }),
  );
  await waitFor(() =>
    assert.deepEqual(calls, [["auth-generation", "filesystem-binding", true]]),
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
  fireEvent.click(screen.getByRole("button", { name: /Filesystem/ }));
  fireEvent.click(screen.getByRole("button", { name: "Connect and enable" }));
  await waitFor(() =>
    assert.deepEqual(approvals, [["13", "filesystem-binding"]]),
  );
  fireEvent.click(screen.getByRole("button", { name: "Close" }));

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
  await act(
    () =>
      new Promise((resolve) => window.requestAnimationFrame(() => resolve())),
  );
  assert.equal(
    document.activeElement,
    within(confirmation).getByRole("heading", {
      name: "Delete this server?",
    }),
  );
  fireEvent.click(within(confirmation).getByRole("button", { name: "Cancel" }));
  await act(
    () =>
      new Promise((resolve) => window.requestAnimationFrame(() => resolve())),
  );
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

test("MCP freezes unconfirmed desired state and explains restart semantics", () => {
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
  assert.ok(screen.getByText("Restart MetaWork to apply connection changes"));
  assert.ok(
    screen.getByText(
      "New tasks will not use MCP until restart. Open tasks keep their current access.",
    ),
  );
});

test("MCP page stays inside the safe Renderer projection", async () => {
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );
  assert.match(page, /<Drawer\.Root[\s\S]*?<Drawer\.Popup/);
  assert.doesNotMatch(
    page,
    /window\.zero|localStorage|apiKey|marketplace|accessToken|refreshToken|clientSecretValue/i,
  );
});
