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
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  MutationObserver: dom.window.MutationObserver,
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
    desiredEnabled: true,
    runtimeStatus: "ready",
    newTaskAccess: "available",
    safeDiagnostic: "",
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
    desiredEnabled: true,
    runtimeStatus: "needs_authentication",
    newTaskAccess: "unavailable",
    safeDiagnostic: "Sign in again to refresh this server's tools.",
    tools: [],
  },
  {
    id: "filesystem-binding",
    displayName: "Filesystem",
    namespace: "local_files",
    transport: "stdio",
    desiredEnabled: false,
    runtimeStatus: "disabled",
    newTaskAccess: "not_allowed",
    safeDiagnostic: "",
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
      management,
      query,
      disabled: false,
      onQuery() {},
      onCreate: unchangedMutation,
      onRename: unchangedMutation,
      onSetEnabled: unchangedMutation,
      onSetAllowedTools: unchangedMutation,
      onRemove: unchangedMutation,
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

test("MCP detail exposes bounded product facts and the discovered tool catalog", () => {
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
  assert.ok(dialog.textContent.includes("search_repositories"));
  assert.ok(dialog.textContent.includes("create_issue"));
  assert.equal(dialog.textContent.includes("Authorization"), false);
  fireEvent.click(screen.getByRole("button", { name: "Close" }));
  assert.equal(screen.queryByRole("dialog"), null);
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

test("MCP add accepts only the bounded HTTP surface and preserves exact input", async () => {
  const calls = [];
  render(
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
        onCreate: async (...args) => {
          calls.push(args);
          return { outcome: "saved" };
        },
      },
    ),
  );

  fireEvent.click(screen.getAllByRole("button", { name: "Add server" })[0]);
  const dialog = screen.getByRole("dialog", { name: "Add an HTTP server" });
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
    "Local Search",
    "http://127.0.0.1:4312/mcp",
  ]);
  assert.equal(screen.queryByRole("dialog"), null);
});

test("MCP endpoint validation rejects ambient authority and unsafe HTTP", () => {
  assert.equal(validMcpHttpEndpoint("https://mcp.example.com/path"), true);
  assert.equal(validMcpHttpEndpoint("http://localhost:3000/mcp"), true);
  assert.equal(validMcpHttpEndpoint("http://[::1]:3000/mcp"), true);
  assert.equal(validMcpHttpEndpoint("http://192.168.1.2/mcp"), false);
  assert.equal(validMcpHttpEndpoint("https:example.com/mcp"), false);
  assert.equal(validMcpHttpEndpoint("https://example.com/mcp?"), false);
  assert.equal(validMcpHttpEndpoint("https://example.com/mcp#"), false);
  assert.equal(validMcpHttpEndpoint("https://@example.com/mcp"), false);
  assert.equal(validMcpHttpEndpoint("https://user@example.com/mcp"), false);
  assert.equal(validMcpHttpEndpoint("https://example.com/mcp?token=x"), false);
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
    screen.getByRole("checkbox", { name: "Allow create_issue for new tasks" }),
  );
  await waitFor(() => assert.equal(calls.length, 1));
  assert.deepEqual(calls[0], ["7", "github-binding", ["search_repositories"]]);
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
  assert.equal(
    screen.queryByRole("button", { name: "Add server" }).disabled,
    true,
  );

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
  assert.match(page, /aria-modal="true"/);
  assert.doesNotMatch(
    page,
    /window\.zero|localStorage|Authorization|headers|apiKey|marketplace/i,
  );
});
