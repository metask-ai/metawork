import assert from "node:assert/strict";
import test from "node:test";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createServer } from "vite";

const vite = await createServer({
  root: "frontend",
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { Markdown } = await vite.ssrLoadModule(
  "/src/components/ai/Markdown.tsx",
);
const { runFileReferenceLinks } = await vite.ssrLoadModule(
  "/src/workbench/run-file-references.ts",
);

test.after(async () => {
  await vite.close();
});

test("renders common Markdown and GFM without raw HTML", () => {
  const markup = renderToStaticMarkup(
    createElement(
      Markdown,
      null,
      "# Result\n\n- [x] done\n\n| key | value |\n| --- | --- |\n| a | b |\n\n<script>alert(1)</script>",
    ),
  );

  assert.match(markup, /<h1>Result<\/h1>/);
  assert.match(markup, /type="checkbox"/);
  assert.match(markup, /<table>/);
  assert.doesNotMatch(markup, /<script>/);
});

test("drops unsafe link protocols", () => {
  const markup = renderToStaticMarkup(
    createElement(
      Markdown,
      null,
      '[safe](/docs) [unsafe](javascript:alert("x"))',
    ),
  );

  assert.match(markup, /href="\/docs"/);
  assert.doesNotMatch(markup, /javascript:/);
});

function referenceMarkup(source, names = ["random_1.txt", "report a.txt"]) {
  return renderToStaticMarkup(
    createElement(
      Markdown,
      {
        references: new Map(
          names.map((name) => [
            name,
            { label: `Preview ${name}`, onOpen() {} },
          ]),
        ),
      },
      source,
    ),
  );
}

test("known references are inline actions in prose, inline code and Markdown links", () => {
  for (const source of [
    "已生成：random_1.txt。",
    "`random_1.txt` — 随机文件",
    "[打开文件](random_1.txt)",
    "[打开文件][ref]\n\n[ref]: random_1.txt",
    "[报告](report%20a.txt)",
  ]) {
    const markup = referenceMarkup(source);
    assert.equal((markup.match(/<button/g) ?? []).length, 1, source);
    assert.match(markup, /class="[^"]*ai-markdown-reference/);
    assert.doesNotMatch(markup, /<a\b/);
  }
  assert.match(referenceMarkup("`random_1.txt`"), /<code>random_1.txt<\/code>/);
});

test("reference matching respects text boundaries and does not alter code, images or external links", () => {
  const markup = referenceMarkup(
    [
      "random_1.txt.bak other/random_1.txt prefixrandom_1.txt random_1.txt@example.com",
      "`cat random_1.txt`",
      "```txt\nrandom_1.txt\n```",
      "```\nrandom_1.txt\n```",
      "    random_1.txt",
      "[random_1.txt](https://example.com/random_1.txt)",
      "[外部](//example.com/random_1.txt)",
      "![random_1.txt](https://example.com/image.png)",
      "[邮箱](mailto:test@example.com)",
      "[未知](missing.txt) [坏编码](%ZZ.txt)",
      "[危险](javascript:alert%281%29) [本地](file:///random_1.txt)",
    ].join("\n\n"),
  );
  assert.doesNotMatch(markup, /ai-markdown-reference/);
  assert.match(markup, /href="https:\/\/example.com\/random_1.txt"/);
  assert.match(markup, /href="mailto:test@example.com"/);
  assert.doesNotMatch(markup, /href="(?:missing|%ZZ)|javascript:|file:\/\//);
});

test("reference names are literal and longest matches win without changing surrounding text", () => {
  const markup = referenceMarkup("输出：(report[1].txt)、dir/report[1].txt。", [
    "report[1].txt",
    "dir/report[1].txt",
  ]);
  assert.equal((markup.match(/<button/g) ?? []).length, 2);
  assert.match(markup, /Preview dir\/report\[1\].txt/);
  assert.match(markup, /输出：\(/);
});

test("Run link aliases retain exact references and reject ambiguous basenames", () => {
  const old = { id: "old", displayPath: "a/index.html" };
  const latest = { id: "latest", displayPath: "a/index.html" };
  const other = { id: "other", displayPath: "b/index.html" };
  const run = {
    tools: [
      { order: "10", fileRefs: [latest] },
      { order: "2", fileRefs: [old] },
    ],
  };
  let links = runFileReferenceLinks(run);
  assert.equal(links.get("index.html"), latest);
  assert.equal(links.get("a/index.html"), latest);
  assert.equal(links.get("./a/index.html"), latest);
  run.tools.push({ order: "11", fileRefs: [other] });
  links = runFileReferenceLinks(run);
  assert.equal(links.has("index.html"), false);
  assert.equal(links.get("b/index.html"), other);
  assert.equal(links.get("a/index.html"), latest);
  assert.equal(runFileReferenceLinks({ tools: [] }).size, 0);
  assert.equal(run.tools[0].fileRefs[0], latest);
});
