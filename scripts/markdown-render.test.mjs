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

const { Markdown, renderMarkdownForClipboard } = await vite.ssrLoadModule(
  "/src/components/ai/Markdown.tsx",
);
const { runFileReferenceLinks } = await vite.ssrLoadModule(
  "/src/workbench/run-file-references.ts",
);
const { resolveWorkspaceFileLink, workspaceFileParent, workspaceFilePresence } =
  await vite.ssrLoadModule("/src/workbench/workspace-file-links.ts");

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
      '[safe](/docs) [scheme-relative](//example.com) [unsafe](javascript:alert("x"))',
    ),
  );

  assert.match(markup, /href="\/docs"/);
  assert.doesNotMatch(markup, /href="\/\//);
  assert.doesNotMatch(markup, /javascript:/);
});

test("clipboard Markdown is semantic, inert HTML without product UI", async () => {
  const markup = await renderMarkdownForClipboard(
    [
      "# 标题",
      "",
      "> 引用",
      "",
      "- [x] 完成",
      "  - 嵌套",
      "",
      "| key | value |",
      "| --- | --- |",
      "| a | b |",
      "",
      "[external](https://example.com) [mail](mailto:test@example.com)",
      "[relative](report.txt) [file](file:///tmp/report.txt)",
      "![diagram](https://example.com/diagram.png)",
      "",
      "`inline`",
      "",
      "```ts",
      "const answer = 42;",
      "```",
      "",
      "```",
      "second",
      "```",
      "",
      '<button aria-label="bad">bad</button><script>alert(1)</script>',
    ].join("\n"),
  );

  assert.match(markup, /<h1>标题<\/h1>/);
  assert.match(markup, /<blockquote>/);
  assert.match(markup, /<ul>\s*<li>\[x\] 完成/);
  assert.match(markup, /<table>/);
  assert.match(markup, /href="https:\/\/example.com"/);
  assert.match(markup, /href="mailto:test@example.com"/);
  assert.match(markup, /<span>relative<\/span>/);
  assert.match(markup, /<span>file<\/span>/);
  assert.match(markup, /<span>diagram<\/span>/);
  assert.equal((markup.match(/<pre>/g) ?? []).length, 2);
  assert.doesNotMatch(
    markup,
    /<(?:button|input|img|script)\b|class=|style=|javascript:|file:\/\//,
  );
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

function localLinkMarkup(source, resolve, names = ["random_1.txt"]) {
  const destinations = [];
  const markup = renderToStaticMarkup(
    createElement(
      Markdown,
      {
        references: new Map(
          names.map((name) => [
            name,
            { label: `Preview ${name}`, onOpen() {} },
          ]),
        ),
        localLinks(destination) {
          destinations.push(destination);
          return resolve(destination);
        },
      },
      source,
    ),
  );
  return { markup, destinations };
}

test("explicit local links without a Run reference are resolved by the feature", () => {
  const { markup, destinations } = localLinkMarkup(
    [
      "[已存在](p0-file-manifest.csv)",
      "[绝对路径](/Users/me/ws/out/report.txt)",
      "[尖括号](</Users/me/ws/my report.txt>)",
      "[文件 URL](file:///Users/me/ws/a%20b.txt)",
      "[驱动器](C:\\ws\\a.txt)",
      "[定义][manifest]",
      "",
      "[manifest]: out/manifest.csv",
    ].join("\n\n"),
    (destination) => ({ label: `Open ${destination}`, onOpen() {} }),
  );
  assert.deepEqual(destinations, [
    "p0-file-manifest.csv",
    "/Users/me/ws/out/report.txt",
    "/Users/me/ws/my report.txt",
    "file:///Users/me/ws/a%20b.txt",
    "C:\\ws\\a.txt",
    "out/manifest.csv",
  ]);
  assert.equal((markup.match(/<button/g) ?? []).length, 6);
  assert.match(markup, /aria-label="Open \/Users\/me\/ws\/my report.txt"/);
  assert.doesNotMatch(markup, /<a\b|href=/);
});

test("Run references keep precedence and other text never becomes a local link", () => {
  const { markup, destinations } = localLinkMarkup(
    [
      "[打开文件](random_1.txt) missing.txt `missing.txt`",
      "```\n[代码](missing.txt)\n```",
      "![图片](missing.png)",
      "[网页](https://example.com/a.txt) [邮箱](mailto:test@example.com)",
      "[锚点](#section) [查询](?q=1) [外部](//example.com/a.txt)",
    ].join("\n\n"),
    () => assert.fail("only explicit local destinations are resolved"),
  );
  assert.deepEqual(destinations, []);
  assert.equal((markup.match(/<button/g) ?? []).length, 1);
  assert.match(markup, /aria-label="Preview random_1.txt"/);
  assert.match(markup, /href="https:\/\/example.com\/a.txt"/);
  assert.doesNotMatch(markup, /ai-markdown-file-link-unavailable/);
});

test("unavailable local links keep their target without presenting an action", () => {
  const { markup } = localLinkMarkup(
    "[系统文件](/etc/my%20hosts)",
    () => ({ unavailable: "Can't open: outside the current workspace" }),
    [],
  );
  assert.doesNotMatch(markup, /<button|<a\b|href=/);
  assert.match(
    markup,
    /<span role="link" aria-disabled="true" aria-describedby="([^"]+)" tabindex="0" class="[^"]*ai-markdown-file-link-unavailable[^"]*"[^>]*>系统文件<\/span>/,
  );
  const id = markup.match(/aria-describedby="([^"]+)"/)[1];
  assert.match(
    markup,
    new RegExp(
      `<span id="${id}" hidden="">Can&#x27;t open: outside the current workspace /etc/my hosts</span>`,
    ),
  );
});

test("provisional and resolver-free Markdown keep local links inert", () => {
  const inert = renderToStaticMarkup(
    createElement(
      Markdown,
      {
        interactive: false,
        localLinks: () => assert.fail("provisional output is not resolved"),
      },
      "[文件](report.txt)",
    ),
  );
  assert.equal(
    inert,
    '<div class="ai-markdown"><p><span>文件</span></p></div>',
  );
  const unresolved = referenceMarkup("[文件](missing.txt)");
  assert.match(unresolved, /<span>文件<\/span>/);
  assert.doesNotMatch(unresolved, /role="link"|<button/);
});

test("Workspace file links map local destinations to Host-acceptable relative paths", () => {
  const root = "/Users/me/ws";
  const path = (destination, workspaceRoot = root) =>
    resolveWorkspaceFileLink(destination, workspaceRoot);
  for (const [destination, expected] of [
    ["p0-file-manifest.csv", "p0-file-manifest.csv"],
    ["./out/./report.txt", "out/report.txt"],
    ["out/tmp/../report.txt", "out/report.txt"],
    ["my%20report.txt", "my report.txt"],
    ["my report.txt", "my report.txt"],
    ["100%.txt", "100%.txt"],
    ["report.md#L10", "report.md"],
    ["report.md?plain=1", "report.md"],
    ["notes%23draft.md", "notes#draft.md"],
    ["/Users/me/ws/out/report.txt", "out/report.txt"],
    ["/Users/me/ws/sub/../report.txt", "report.txt"],
    ["file:///Users/me/ws/a%20b.txt", "a b.txt"],
    ["file://localhost/Users/me/ws/a.txt", "a.txt"],
    ["报告/结果.md", "报告/结果.md"],
  ])
    assert.deepEqual(
      path(destination),
      { kind: "path", path: expected },
      destination,
    );

  for (const [destination, reason, workspaceRoot = root] of [
    ["../outside.txt", "outside_workspace"],
    ["out/../../outside.txt", "outside_workspace"],
    ["/etc/hosts", "outside_workspace"],
    ["/Users/me/ws2/report.txt", "outside_workspace"],
    ["/Users/me/ws/../other/report.txt", "outside_workspace"],
    ["/Users/me/report.txt", "outside_workspace"],
    ["C:\\ws\\report.txt", "outside_workspace"],
    ["/Users/me/ws/report.txt", "workspace_unavailable", null],
    ["file:///Users/me/ws/a.txt", "workspace_unavailable", null],
    ["file://server/share/a.txt", "unsupported_path"],
    ["file:report.txt", "unsupported_path"],
    ["~/report.txt", "unsupported_path"],
    ["src/main.ts:42", "unsupported_path"],
    ["out\\report.txt", "unsupported_path"],
    ["out//report.txt", "unsupported_path"],
    ["out/", "unsupported_path"],
    ["./", "unsupported_path"],
    ["/Users/me/ws", "unsupported_path"],
    ["/Users/me/ws/", "unsupported_path"],
    ["bad%0Aname.txt", "unsupported_path"],
    [`${"a/".repeat(64)}b.txt`, "unsupported_path"],
    [`${"界".repeat(1366)}.txt`, "unsupported_path"],
  ])
    assert.deepEqual(
      path(destination, workspaceRoot),
      { kind: "unavailable", reason },
      destination,
    );
  // Relative destinations do not need the publishable root.
  assert.deepEqual(path("report.txt", null), {
    kind: "path",
    path: "report.txt",
  });
});

test("Windows Workspace roots accept drive paths, either separator and any letter case", () => {
  const root = "C:\\Users\\Me\\Project";
  for (const [destination, expected] of [
    ["C:\\Users\\Me\\Project\\out\\report.txt", "out/report.txt"],
    ["c:/users/me/project/out/report.txt", "out/report.txt"],
    ["file:///C:/Users/Me/Project/a%20b.txt", "a b.txt"],
    ["out\\report.txt", "out/report.txt"],
  ])
    assert.deepEqual(
      resolveWorkspaceFileLink(destination, root),
      { kind: "path", path: expected },
      destination,
    );
  for (const destination of ["D:\\Project\\a.txt", "/Users/Me/Project/a.txt"])
    assert.deepEqual(
      resolveWorkspaceFileLink(destination, root),
      { kind: "unavailable", reason: "outside_workspace" },
      destination,
    );
  assert.deepEqual(resolveWorkspaceFileLink("out/a:b.txt", root), {
    kind: "unavailable",
    reason: "unsupported_path",
  });
});

test("only a complete Host listing proves a Workspace link target missing", () => {
  assert.deepEqual(workspaceFileParent("report.txt"), {
    directory: "",
    name: "report.txt",
  });
  assert.deepEqual(workspaceFileParent("notes/2026/qa preview.txt"), {
    directory: "notes/2026",
    name: "qa preview.txt",
  });
  const listing = (entries, overrides = {}) => ({
    state: "ready",
    entries,
    truncated: false,
    redacted: false,
    ...overrides,
  });
  const entries = [
    { name: "Report.TXT", kind: "file" },
    { name: "cafe\u0301.md", kind: "file" },
    { name: "docs", kind: "directory" },
  ];
  for (const [name, expected] of [
    ["Report.TXT", "present"],
    // Case and Unicode normalization differences resolve on macOS and Windows.
    ["report.txt", "present"],
    ["caf\u00e9.md", "present"],
    ["docs", "missing"],
    ["missing.csv", "missing"],
  ])
    assert.equal(workspaceFilePresence(listing(entries), name), expected, name);
  assert.equal(
    workspaceFilePresence(listing(entries, { truncated: true }), "missing.csv"),
    "unknown",
  );
  assert.equal(
    workspaceFilePresence(listing(entries, { truncated: true }), "report.txt"),
    "present",
  );
  assert.equal(
    workspaceFilePresence(listing([], { redacted: true }), "missing.csv"),
    "missing",
  );
  for (const state of ["missing", "restricted"])
    assert.equal(
      workspaceFilePresence(listing([], { state }), "report.txt"),
      "missing",
      state,
    );
  for (const state of ["busy", "error"])
    assert.equal(
      workspaceFilePresence(listing([], { state }), "report.txt"),
      "unknown",
      state,
    );
});
