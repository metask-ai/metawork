import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { buildSync } from "esbuild";

// Exercise the actual renderer with synthetic data; no browser or live service.
const result = buildSync({
  entryPoints: [
    fileURLToPath(new URL("./reply-hierarchy.fixture.tsx", import.meta.url)),
  ],
  bundle: true,
  platform: "node",
  format: "cjs",
  write: false,
  jsx: "automatic",
  define: { "import.meta.env.DEV": "false" },
});
const compiled = { exports: {} };
new Function("require", "module", "exports", result.outputFiles[0].text)(
  createRequire(import.meta.url),
  compiled,
  compiled.exports,
);
const { renderScenario } = compiled.exports;

test("completed reply prioritizes answer and delivery; execution content is collapsed", () => {
  const html = renderScenario("completed");
  assert.ok(html.indexOf("RESULT_SENTINEL") < html.indexOf("交付成果"));
  assert.ok(
    html.indexOf("产品设计计划.md") < html.indexOf('class="run-process"'),
  );
  assert.match(html, /data-expanded="false"/);
  assert.doesNotMatch(
    html,
    /PROCESS_NOTE_SENTINEL|DeepSeek-V4|审查更改|需求梳理.md/,
  );
  assert.match(html, /继续修改/);
  assert.match(html, /aria-haspopup="menu"/);
});

test("expanded details retain model, process notes, file changes, and tool access", () => {
  const html = renderScenario("expanded");
  const details = html.slice(html.indexOf('class="run-process"'));
  for (const text of [
    "DeepSeek-V4",
    "PROCESS_NOTE_SENTINEL",
    "审查更改",
    "需求梳理.md",
  ])
    assert.ok(details.includes(text));
  assert.equal(html.split("RESULT_SENTINEL").length - 1, 1);
  assert.equal(html.split("PROCESS_NOTE_SENTINEL").length - 1, 1);
});

test("provider failure remains visible outside collapsed execution details", () => {
  const html = renderScenario("failed");
  assert.match(html, /data-state="failed"/);
  assert.ok(
    html.indexOf('data-state="failed"') < html.indexOf('class="run-process"'),
  );
  assert.match(html, /data-expanded="false"/);
  assert.doesNotMatch(html, /PROCESS_NOTE_SENTINEL/);
});

test("model and file details remain reachable for replies with no tool calls", () => {
  const html = renderScenario("expanded-no-tools");
  assert.match(html, /data-expanded="true"/);
  assert.match(html, /DeepSeek-V4/);
  assert.match(html, /审查更改/);
});

test("delivered-file links never open an unrelated file with the same basename", () => {
  const html = renderScenario("basename-collision");
  assert.match(html, /产品设计计划.md/);
  assert.doesNotMatch(html, /aria-label="预览 产品设计计划.md"/);
});

test("pending approval remains actionable outside collapsed execution details", () => {
  const html = renderScenario("approval");
  assert.ok(html.includes("PENDING_SENTINEL"));
  assert.ok(
    html.indexOf("PENDING_SENTINEL") < html.indexOf('class="run-process"'),
  );
  assert.match(html, /data-expanded="false"/);
  assert.doesNotMatch(html, /PROCESS_NOTE_SENTINEL/);
});

test("unclassified streaming answer remains readable while process notes are hidden", () => {
  const html = renderScenario("streaming");
  assert.match(html, /STREAMING_SENTINEL/);
  assert.doesNotMatch(html, /PROCESS_NOTE_SENTINEL/);
});
