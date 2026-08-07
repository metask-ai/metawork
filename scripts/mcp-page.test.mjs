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

const { cleanup, fireEvent, render, screen } =
  await import("@testing-library/react");

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { McpPage, filterMcpServers } = await vite.ssrLoadModule(
  "/src/features/mcp/McpPage.tsx",
);
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

function pageElement(management, query = "") {
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
      onQuery() {},
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
