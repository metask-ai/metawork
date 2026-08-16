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
