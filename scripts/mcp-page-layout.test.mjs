import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

test("MCP detail becomes a full-width page at the narrow breakpoint", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  assert.match(
    css,
    /@media \(max-width: 620px\) \{[\s\S]*?\.mcp-drawer \{[\s\S]*?width: 100%;[\s\S]*?border-left: 0;/,
  );
  assert.match(
    css,
    /@media \(max-width: 620px\) \{[\s\S]*?\.mcp-authority-strip \{[\s\S]*?grid-template-columns: 1fr;/,
  );
});

test("MCP authority layers remain one deliberate visual system", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );

  assert.match(page, /className="mcp-authority-strip"/);
  assert.match(page, /mcp\.detail\.desired/);
  assert.match(page, /mcp\.detail\.runtime/);
  assert.match(page, /mcp\.detail\.new_tasks/);
  assert.match(css, /\.mcp-authority-strip \{[\s\S]*?repeat\(3,/);
  assert.match(
    css,
    /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*?\.mcp-drawer-backdrop,[\s\S]*?animation: none;/,
  );
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
});
