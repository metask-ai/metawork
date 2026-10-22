// Qualify the fixed Application preview command against a real component.
// This does not admit a Product handle, check credentials or open Renderer UI.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readOfficeComponent } from "./office-environment.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
if (process.argv.length !== 4)
  throw new Error(
    "Usage: check-office-preview-host.mjs <prepared-component-root> <office-process-probe.exe>",
  );
const component = readOfficeComponent(path.resolve(process.argv[2]));
const host = path.resolve(process.argv[3]);
const cache = path.join(root, ".zig-cache/office-preview-host-qualification");
mkdirSync(cache, { recursive: true });
const directory = mkdtempSync(path.join(cache, "run-"));
function run(executable, args) {
  return execFileSync(executable, args, {
    cwd: directory,
    encoding: "utf8",
    timeout: 150_000,
    maxBuffer: 1024 * 1024,
    windowsHide: true,
  });
}
function digest(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}
run(component.entry, [
  "node",
  path.join(root, "scripts/create-office-engine-fixtures.mjs"),
  directory,
]);
const workbook = path.join(directory, "workbook.xlsx");
run(component.entry, [
  "python",
  "-c",
  "from openpyxl import Workbook;import sys;w=Workbook();s=w.active;s['A1']='业务 中文';s['A2']=2;s['B2']='=A2*3';w.save(sys.argv[1]);w.close()",
  workbook,
]);
run(component.entry, [
  "pdf",
  path.join(directory, "original.docx"),
  path.join(directory, "sample.pdf"),
]);
const results = [];
for (const name of [
  "original.docx",
  "sample.pptx",
  "workbook.xlsx",
  "sample.pdf",
]) {
  const source = path.join(directory, name);
  const before = digest(source);
  const output = path.join(directory, name + "-preview");
  const started = Date.now();
  const outcome = JSON.parse(
    run(host, [component.root, "120000", "0", source, output]),
  );
  assert.equal(outcome.quiescent, true);
  assert.deepEqual(outcome.term, { exited: 0 });
  const receipt = JSON.parse(outcome.stdout);
  assert.equal(receipt.status, "success");
  const manifest = JSON.parse(
    readFileSync(path.join(output, "preview.json"), "utf8"),
  );
  assert.equal(manifest.schema, 1);
  assert.equal(manifest.kind, receipt.kind);
  assert.equal(
    manifest.textScope,
    name.endsWith(".pdf")
      ? "pdf_reachable_strings_xmp_and_decoded_page_text_without_ocr"
      : "ooxml_xml_text_and_attributes_without_ocr",
  );
  const resources = [
    manifest.sourceText,
    ...(manifest.kind === "grid" ? [manifest.grid] : manifest.pages),
  ];
  for (const resource of resources) {
    assert.ok(
      /^(?:source-text\.txt|grid\.json|page-\d{4}\.png)$/u.test(resource.file),
    );
    const file = path.join(output, resource.file);
    assert.equal(readFileSync(file).length, resource.bytes);
    assert.equal(digest(file), resource.sha256);
  }
  if (manifest.kind === "grid") {
    const grid = JSON.parse(
      readFileSync(path.join(output, "grid.json"), "utf8"),
    );
    assert.equal(grid.calculation, "saved_values_only");
    const formula = grid.sheets[0].cells.find((cell) => cell.formula);
    assert.equal(formula.formula, "=A2*3");
    assert.equal(formula.value, null);
  } else assert.equal(manifest.pages.length, receipt.page_count);
  assert.equal(digest(source), before);
  results.push({ name, receipt, elapsedMs: Date.now() - started, output });
}
const evidence = {
  schema: 1,
  scope:
    "Application process owner with actual component resources; not Product/Bridge/Renderer admission",
  componentManifestSha256: component.manifestSha256,
  hostSha256: digest(host),
  results,
};
writeFileSync(
  path.join(directory, "evidence.json"),
  JSON.stringify(evidence, null, 2) + "\n",
);
console.log(JSON.stringify(evidence));
