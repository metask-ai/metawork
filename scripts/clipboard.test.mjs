import assert from "node:assert/strict";
import test from "node:test";

import { createServer } from "vite";

const vite = await createServer({
  root: "frontend",
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { writePlainClipboard, writeRichClipboard } = await vite.ssrLoadModule(
  "/src/platform/clipboard.ts",
);
const { latestCopyableResponseId, responseCopyEligible } =
  await vite.ssrLoadModule("/src/features/tasks/response-copy.ts");

test.after(async () => {
  await vite.close();
});

function installClipboard(clipboard, Item) {
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { clipboard },
  });
  if (Item) globalThis.ClipboardItem = Item;
  else delete globalThis.ClipboardItem;
}

class MockClipboardItem {
  static supports(type) {
    return type === "text/html" || type === "text/plain";
  }

  constructor(items) {
    this.items = items;
    this.types = Object.keys(items);
  }

  getType(type) {
    return Promise.resolve(this.items[type]);
  }
}

test("rich clipboard writes one ordered item and preserves exact Markdown", async () => {
  const writes = [];
  const textWrites = [];
  installClipboard(
    {
      async write(items) {
        writes.push(items);
      },
      async writeText(value) {
        textWrites.push(value);
      },
    },
    MockClipboardItem,
  );
  const markdown = "  # 标题\n\n```ts\nconst x = 1;\n```\n\n";
  const html = "<h1>标题</h1><pre><code>const x = 1;\n</code></pre>";

  assert.equal(await writeRichClipboard(markdown, html), "rich");
  assert.equal(writes.length, 1);
  assert.equal(writes[0].length, 1);
  assert.deepEqual(writes[0][0].types, ["text/html", "text/plain"]);
  assert.equal(
    await (await writes[0][0].getType("text/plain")).text(),
    markdown,
  );
  assert.equal(await (await writes[0][0].getType("text/html")).text(), html);
  assert.deepEqual(textWrites, []);
});

test("explicit missing rich capability falls back to complete Markdown text", async () => {
  const markdown = `PLAIN_256K\n${"x".repeat(256 * 1024 - 11)}`;
  const textWrites = [];
  installClipboard({
    async writeText(value) {
      textWrites.push(value);
    },
  });

  assert.equal(await writeRichClipboard(markdown, "<p>large</p>"), "plain");
  assert.equal(new TextEncoder().encode(textWrites[0]).length, 256 * 1024);
  assert.equal(textWrites[0], markdown);
});

test("an explicit MIME support rejection uses the text fallback", async () => {
  const textWrites = [];
  class PlainOnlyClipboardItem extends MockClipboardItem {
    static supports(type) {
      return type === "text/plain";
    }
  }
  installClipboard(
    {
      async write() {
        assert.fail("rich write must not run");
      },
      async writeText(value) {
        textWrites.push(value);
      },
    },
    PlainOnlyClipboardItem,
  );

  assert.equal(await writeRichClipboard("markdown", "<p>html</p>"), "plain");
  assert.deepEqual(textWrites, ["markdown"]);
});

test("a rich clipboard runtime failure does not retry through writeText", async () => {
  let textWrites = 0;
  installClipboard(
    {
      async write() {
        throw new DOMException("denied", "NotAllowedError");
      },
      async writeText() {
        textWrites += 1;
      },
    },
    MockClipboardItem,
  );

  await assert.rejects(writeRichClipboard("markdown", "<p>html</p>"), /denied/);
  assert.equal(textWrites, 0);
});

test("plain code copy preserves only the supplied displayed value", async () => {
  const writes = [];
  installClipboard({
    async writeText(value) {
      writes.push(value);
    },
  });

  await writePlainClipboard("const answer = 42;");
  assert.deepEqual(writes, ["const answer = 42;"]);
});

function run(
  id,
  { terminal = {}, responseKind = "final", response = "ok" } = {},
) {
  return { id, terminal, output: { responseKind, response } };
}

test("only frozen non-empty final or partial responses are copyable", () => {
  assert.equal(responseCopyEligible(run("final")), true);
  assert.equal(
    responseCopyEligible(run("partial", { responseKind: "partial" })),
    true,
  );
  assert.equal(responseCopyEligible(run("stream", { terminal: null })), false);
  assert.equal(
    responseCopyEligible(run("none", { responseKind: null })),
    false,
  );
  assert.equal(responseCopyEligible(run("empty", { response: "" })), false);
  assert.equal(
    latestCopyableResponseId([
      run("old"),
      run("stream", { terminal: null }),
      run("latest", { responseKind: "partial" }),
    ]),
    "latest",
  );
});
