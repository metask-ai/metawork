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
});
