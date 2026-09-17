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
const {
  copyRunInput,
  latestCopyableResponseId,
  responseCopyEligible,
  runInputClipboardText,
} = await vite.ssrLoadModule("/src/features/tasks/response-copy.ts");

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

  assert.equal(await writeRichClipboard(markdown, () => html), "rich");
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

test("rich clipboard preserves product-limit Markdown and expanded HTML", async () => {
  const writes = [];
  installClipboard(
    {
      async write(items) {
        writes.push(items);
      },
      async writeText() {
        assert.fail("rich-capable clipboard must not use the fallback");
      },
    },
    MockClipboardItem,
  );
  const markdown = `PLAIN_256K\n${"x".repeat(256 * 1024 - 11)}`;
  const html = `<p>HTML_BEGIN</p><table>${"<tr><td>内容</td></tr>".repeat(50_000)}</table><p>HTML_END</p>`;

  assert.equal(await writeRichClipboard(markdown, () => html), "rich");
  const item = writes[0][0];
  assert.equal(await (await item.getType("text/plain")).text(), markdown);
  assert.equal(await (await item.getType("text/html")).text(), html);
  assert.equal(new TextEncoder().encode(markdown).length, 256 * 1024);
  assert.ok(new TextEncoder().encode(html).length > 1_000_000);
});

test("explicit missing rich capability falls back to complete Markdown text", async () => {
  const markdown = `PLAIN_256K\n${"x".repeat(256 * 1024 - 11)}`;
  const textWrites = [];
  let rendered = false;
  installClipboard({
    async writeText(value) {
      textWrites.push(value);
    },
  });

  assert.equal(
    await writeRichClipboard(markdown, () => {
      rendered = true;
      return "<p>large</p>";
    }),
    "plain",
  );
  assert.equal(new TextEncoder().encode(textWrites[0]).length, 256 * 1024);
  assert.equal(textWrites[0], markdown);
  assert.equal(rendered, false);
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

  assert.equal(
    await writeRichClipboard("markdown", () => "<p>html</p>"),
    "plain",
  );
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

  await assert.rejects(
    writeRichClipboard("markdown", () => "<p>html</p>"),
    /denied/,
  );
  assert.equal(textWrites, 0);
});

test("rich write starts in the user gesture stack before lazy HTML resolves", async () => {
  let resolveHtml;
  const html = new Promise((resolve) => {
    resolveHtml = resolve;
  });
  let writeStarted = false;
  let htmlObserved = null;
  installClipboard(
    {
      async write(items) {
        writeStarted = true;
        htmlObserved = await (await items[0].getType("text/html")).text();
      },
      async writeText() {
        assert.fail("rich-capable clipboard must not use the fallback");
      },
    },
    MockClipboardItem,
  );

  const writing = writeRichClipboard("markdown", () => html);
  assert.equal(writeStarted, true);
  assert.equal(htmlObserved, null);
  resolveHtml("<p>lazy</p>");
  assert.equal(await writing, "rich");
  assert.equal(htmlObserved, "<p>lazy</p>");
});

test("lazy HTML conversion failure rejects the already-started rich write", async () => {
  installClipboard(
    {
      async write(items) {
        await items[0].getType("text/html");
      },
      async writeText() {
        assert.fail("conversion failure must not trigger the text fallback");
      },
    },
    MockClipboardItem,
  );

  await assert.rejects(
    writeRichClipboard("markdown", async () => {
      throw new Error("render failed");
    }),
    /render failed/,
  );
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

test("plain copy prefers a MIME clipboard item when the desktop WebView supports it", async () => {
  const writes = [];
  installClipboard(
    {
      async write(items) {
        writes.push(items);
      },
      async writeText() {
        assert.fail("the supported MIME clipboard path must be preferred");
      },
    },
    MockClipboardItem,
  );

  await writePlainClipboard("copy me");
  assert.equal(writes.length, 1);
  assert.equal(writes[0].length, 1);
  assert.deepEqual(writes[0][0].types, ["text/plain"]);
  assert.equal(
    await (await writes[0][0].getType("text/plain")).text(),
    "copy me",
  );
});

test("input copy preserves text and projects structured inputs readably", async () => {
  assert.equal(
    runInputClipboardText({
      kind: "text",
      text: "  inspect this\n",
      redacted: false,
    }),
    "  inspect this\n",
  );
  assert.equal(
    runInputClipboardText({
      kind: "skill",
      skillId: "builtin.review",
      catalogRevision: "8",
      invocationName: "review",
      displayName: "Review",
      argumentValues: ["src/app.ts", "strict"],
      redacted: false,
    }),
    "/review src/app.ts strict",
  );
  assert.equal(
    runInputClipboardText({
      kind: "multimodal",
      text: "Compare these",
      attachments: [
        {
          kind: "image",
          format: "png",
          displayName: "before.png",
          sizeBytes: "12",
          redacted: false,
        },
        {
          kind: "file",
          displayName: "notes.md",
          sizeBytes: "24",
          redacted: false,
        },
      ],
      redacted: false,
    }),
    "Compare these\nbefore.png\nnotes.md",
  );

  const writes = [];
  installClipboard({
    async writeText(value) {
      writes.push(value);
    },
  });
  await copyRunInput({ kind: "text", text: "copy me", redacted: false });
  assert.deepEqual(writes, ["copy me"]);
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
