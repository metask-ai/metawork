import assert from "node:assert/strict";
import test from "node:test";
import { createRequire } from "node:module";
import { buildSync } from "esbuild";

const result = buildSync({
  stdin: {
    contents: `
      export { BridgeClient } from './src/demo/client.ts';
      export { demo } from './src/demo/state.ts';
      export { runFileReferenceLinks } from './src/workbench/run-file-references.ts';
    `,
    resolveDir: new URL("..", import.meta.url).pathname,
  },
  bundle: true,
  platform: "node",
  format: "cjs",
  write: false,
  define: { "import.meta.env.DEV": "false" },
});
const compiled = { exports: {} };
new Function("require", "module", "exports", result.outputFiles[0].text)(
  createRequire(import.meta.url),
  compiled,
  compiled.exports,
);
const { BridgeClient, demo, runFileReferenceLinks } = compiled.exports;

test("delivered filename has an exact reference and previews the existing delivered content", async () => {
  const client = new BridgeClient();
  const task = demo.tasks[0];
  const run = task.runs[0];
  const reference = runFileReferenceLinks(run).get(run.outputs[0].displayPath);
  assert.equal(reference?.displayPath, run.outputs[0].displayPath);
  const preview = await client.previewFile(task.id, run.id, reference.id);
  assert.equal(preview.state, "ready");
  const diff = await client.fileChangeDiff(task.id, run.id, "1");
  const deliveredText =
    diff.content
      .split("\n")
      .filter((line) => line.startsWith("+") && !line.startsWith("+++"))
      .map((line) => line.slice(1))
      .join("\n") + "\n";
  assert.equal(preview.content, deliveredText);
});

test("preview reference IDs are scoped to their task and run", async () => {
  const client = new BridgeClient();
  const content = (await client.previewFile("1", "1", "2")).content;
  for (const args of [
    ["3", "1", "2"],
    ["1", "999", "2"],
    ["1", "1", "999"],
  ]) {
    assert.notEqual((await client.previewFile(...args)).content, content);
  }
});
