import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

test("MCP detail becomes a full-width page at the narrow breakpoint", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );
  assert.match(page, /max-\[620px\]:w-full max-\[620px\]:border-l-0/);
  assert.match(
    css,
    /@media \(max-width: 620px\) \{[\s\S]*?\.mcp-access-rail \{[\s\S]*?grid-template-columns: 1fr;/,
  );
});

test("MCP facts rail replaces the fake setup pipeline", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );

  assert.match(page, /className="mcp-access-rail"/);
  assert.match(page, /mcp\.detail\.new_tasks/);
  assert.match(page, /mcp\.detail\.tool_permissions/);
  assert.match(page, /mcp\.detail\.connection_test/);
  assert.doesNotMatch(page, /mcp-pipeline|mcp\.pipeline\./);
  assert.match(css, /\.mcp-access-rail \{[\s\S]*?repeat\(3,/);
  assert.match(
    css,
    /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*?\.mcp-drawer-backdrop \{[\s\S]*?animation: none;/,
  );
});

test("MCP tool permissions use a visible foundation checkbox", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );

  assert.match(
    page,
    /className="mcp-tool-toggle"[\s\S]*?<Checkbox\.Root[\s\S]*?className="size-\[18px\] rounded-\[5px\]"/,
  );
  assert.doesNotMatch(css, /\.mcp-tool-toggle > button/);
});

test("MCP connection form keeps row groups in the drawer content column", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );

  assert.doesNotMatch(page, /<fieldset className="mcp-text-rows"/);
  assert.match(page, /className="mcp-text-rows"[\s\S]*?role="group"/);
  assert.match(
    css,
    /\.mcp-add-form \{[\s\S]*?grid-template-columns: minmax\(0, 1fr\);/,
  );
  assert.match(css, /\.mcp-text-rows \{[\s\S]*?width: 100%;/);
  assert.match(css, /\.mcp-add-form select \{[\s\S]*?appearance: none;/);
  assert.match(page, /className="mcp-advanced mcp-form-advanced"/);
});
