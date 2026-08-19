import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

test("MCP master-detail workspace stacks at the narrow breakpoint", async () => {
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
    /className="mcp-workspace"[\s\S]*?className="mcp-detail-pane"/,
  );
  assert.match(
    css,
    /@media \(max-width: 1100px\) \{[\s\S]*?\.mcp-workspace \{[\s\S]*?grid-template-columns: minmax\(0, 1fr\);/,
  );
});

test("MCP connection trace exposes real connection, handshake, and tool stages", async () => {
  const css = await readFile(
    join(process.cwd(), "frontend/src/index.css"),
    "utf8",
  );
  const page = await readFile(
    join(process.cwd(), "frontend/src/features/mcp/McpPage.tsx"),
    "utf8",
  );

  assert.match(page, /className="mcp-connection-trace"/);
  assert.match(page, /"connection"/);
  assert.match(page, /"handshake"/);
  assert.match(page, /"tools"/);
  assert.doesNotMatch(page, /mcp-pipeline|mcp\.pipeline\./);
  assert.match(css, /\.mcp-connection-trace \{[\s\S]*?repeat\(3,/);
  assert.doesNotMatch(page, /<Drawer\.Backdrop/);
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

test("MCP confirmations use the modal foundation alert dialog", async () => {
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
    /<AlertDialog\.Root[\s\S]*?<AlertDialog\.Backdrop \/>[\s\S]*?<AlertDialog\.Popup>/,
  );
  assert.doesNotMatch(page, /role="alertdialog"|mcp-confirm-panel/);
  assert.doesNotMatch(css, /\.mcp-confirm-panel/);
});

test("MCP connection form keeps row groups in the detail pane", async () => {
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
