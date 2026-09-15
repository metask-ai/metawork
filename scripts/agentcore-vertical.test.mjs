import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(
  new URL("./test-agentcore-vertical-macos.mjs", import.meta.url),
  "utf8",
);
const windowsClipboardProbe = await readFile(
  new URL("./probe-windows-clipboard.ps1", import.meta.url),
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
    /METAWORK_AUTOMATION_ATTACHMENTS: \[\s*attachmentPngPath,\s*attachmentJpegPath,\s*\]\.join\("\\n"\)/,
  );
  assert.doesNotMatch(source, /METAWORK_AUTOMATION_WORKSPACE: workspace/);
  assert.doesNotMatch(source, /const fixturePath = join\(workspace,/);
  assert.match(source, /"metawork\.attachments\.choose"/);
  assert.match(source, /kind: "multimodal"/);
});

test("Windows desktop vertical exercises real large response and code clipboard actions", () => {
  assert.match(
    source,
    /clipboardMarkdownFixture\(\s*70 \* 1024,\s*"70K",\s*"multimodal",?\s*\)/,
  );
  assert.match(
    source,
    /clipboardMarkdownFixture\(\s*256 \* 1024,\s*"256K",\s*"text",?\s*\)/,
  );
  assert.equal(
    (source.match(/await probeWindowsClipboard\(\{/g) ?? []).length,
    2,
  );
  assert.match(source, /expectedCode: 'const clipboardProbe = "70K";'/);
  assert.match(source, /probe-windows-clipboard\.ps1/);

  assert.match(
    windowsClipboardProbe,
    /Find-MetaWorkButton '\^\(\\u590d\\u5236\\u56de\\u590d\|Copy response\)\$'/,
  );
  assert.match(
    windowsClipboardProbe,
    /Find-MetaWorkButton '\^\(\\u590d\\u5236\\u4ee3\\u7801\|Copy code\)\$'/,
  );
  assert.match(
    windowsClipboardProbe,
    /Clipboard\]::GetText\([\s\S]*UnicodeText/,
  );
  assert.match(
    windowsClipboardProbe,
    /Clipboard\]::GetText\([\s\S]*TextDataFormat\]::Html/,
  );
  assert.match(windowsClipboardProbe, /\.Replace\("`r`n", "`n"\)/);
  assert.match(windowsClipboardProbe, /<h1\\b/);
  assert.match(windowsClipboardProbe, /<table\\b/);
  assert.match(windowsClipboardProbe, /<pre\\b/);
  assert.match(windowsClipboardProbe, /<code\\b/);
  assert.match(windowsClipboardProbe, /mouse_event\(2,/);
  assert.match(windowsClipboardProbe, /Copy failed/);
});
