import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { staticHtmlPreview } from "../frontend/src/features/task-panel/static-html-preview.ts";

test("static workspace HTML keeps document structure and admits only embedded raster images", () => {
  const host = new JSDOM();
  const previousDocument = globalThis.document;
  globalThis.document = host.window.document;
  try {
    const preview = new JSDOM(
      staticHtmlPreview(`<!doctype html>
      <head><meta charset="utf-8"><link rel="stylesheet" href="external.css"></head>
      <body><h1>预算</h1><table><tr><th>收入</th><td>12</td></tr></table>
      <a href="details.html">详情</a><style>body { color: red }</style>
      <img src="chart.png"><img src="data:image/png;base64,AAAA" alt="Chart">
      <form><button>Send</button></form><script>window.untrusted = true</script>
      <iframe src="another.html"></iframe><svg><text>Other markup</text></svg>
      </body>`),
    );
    try {
      const doc = preview.window.document;
      assert.equal(doc.querySelector("h1").textContent, "预算");
      assert.equal(doc.querySelector("td").textContent, "12");
      assert.equal(doc.querySelector("a").textContent, "详情");
      assert.equal(doc.querySelector("a").hasAttribute("href"), false);
      assert.equal(doc.querySelector("img[src]").getAttribute("alt"), "Chart");
      assert.equal(doc.querySelectorAll("img[src]").length, 1);
      assert.equal(
        doc.querySelector("script, style, link, form, iframe, svg"),
        null,
      );
      assert.equal(
        doc.querySelector("meta[http-equiv]").content,
        "default-src 'none'; img-src data:; base-uri 'none'; form-action 'none'",
      );
    } finally {
      preview.window.close();
    }
  } finally {
    globalThis.document = previousDocument;
    host.window.close();
  }
});
