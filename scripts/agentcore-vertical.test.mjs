import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(
  new URL("./test-agentcore-vertical-macos.mjs", import.meta.url),
  "utf8",
);

test("desktop vertical uses one canonical Workspace identity for Agent file paths", () => {
  assert.match(
    source,
    /const canonicalWorkspace = await realpath\(workspace\)/,
  );
  assert.match(source, /const fixturePath = join\(canonicalWorkspace,/);
  assert.match(source, /METAWORK_AUTOMATION_WORKSPACE: canonicalWorkspace/);
  assert.match(
    source,
    /METAWORK_AUTOMATION_ATTACHMENTS: \[\s*attachmentPngPath,\s*attachmentPdfPath,\s*\]\.join\("\\n"\)/,
  );
  assert.doesNotMatch(source, /METAWORK_AUTOMATION_WORKSPACE: workspace/);
  assert.doesNotMatch(source, /const fixturePath = join\(workspace,/);
  assert.match(source, /"metawork\.attachments\.choose"/);
  assert.match(source, /kind: "multimodal"/);
});
