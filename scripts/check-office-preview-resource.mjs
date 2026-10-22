// Real Application resource lifecycle with synthetic source files. No Product
// handle, credential admission or Renderer capability is granted by this probe.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readOfficeComponent } from "./office-environment.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
if (process.argv.length !== 5)
  throw new Error(
    "Usage: check-office-preview-resource.mjs <prepared-component> <resource-probe.exe> <synthetic-fixtures-directory>",
  );
const component = readOfficeComponent(path.resolve(process.argv[2]));
const probe = path.resolve(process.argv[3]);
const fixtures = path.resolve(process.argv[4]);
const cache = path.join(root, ".zig-cache/opv");
mkdirSync(cache, { recursive: true });
const directory = mkdtempSync(path.join(cache, "run-"));
const results = [];
for (const [name, mode, pathMode] of [
  ["original.docx", "normal"],
  ["sample.pptx", "normal"],
  ["workbook.xlsx", "normal"],
  ["sample.pdf", "normal"],
  ["sample.pdf", "current"],
  ["sample.pdf", "changed"],
  ["sample.pdf", "cancel_live"],
  ["original.docx", "current"],
  ["workbook.xlsx", "current"],
  ["workbook.xlsx", "current_changed"],
  ["workbook.xlsx", "changed"],
  ["original.docx", "tamper"],
  ["workbook.xlsx", "root_swap"],
  ["original.docx", "cancel"],
  ["original.docx", "poison"],
  ["original.docx", "collision"],
  ["original.docx", "cancel_live"],
  ["original.docx", "engine_fail"],
  ["original.docx", "normal", "boundary"],
  ["original.docx", "path_limit", "long"],
]) {
  const owned = path.join(directory, `${results.length}-${mode}`);
  const sourceRoot = path.join(owned, "workspace");
  let dataRoot = path.join(owned, "鏁版嵁");
  if (pathMode) {
    const base = path.join(owned, "d");
    const target = pathMode === "boundary" ? 120 : 150;
    dataRoot = path.join(base, "x".repeat(target - 36 - base.length - 1));
    assert.equal(path.join(dataRoot, "pv", "0".repeat(32)).length, target);
  }
  mkdirSync(sourceRoot, { recursive: true });
  mkdirSync(dataRoot, { recursive: true });
  const source = path.join(sourceRoot, name);
  copyFileSync(path.join(fixtures, name), source);
  if (mode === "engine_fail") writeFileSync(source, "not an OOXML archive");
  const bytes = readFileSync(source);
  const digest = createHash("sha256").update(bytes).digest("hex");
  const started = Date.now();
  const result = JSON.parse(
    execFileSync(
      probe,
      [
        component.root,
        sourceRoot,
        name,
        dataRoot,
        String(bytes.length),
        digest,
        component.manifestSha256,
        mode,
      ],
      {
        encoding: "utf8",
        windowsHide: true,
        timeout: 180_000,
        maxBuffer: 1024 * 1024,
      },
    ),
  );
  if (mode === "normal" || mode === "current") {
    assert.equal(result.product_lane, true);
    assert.equal(result.captured_source, true);
  }
  assert.equal(result.guard, true);
  assert.equal(result.lease_released, mode !== "poison");
  if (mode === "normal" || mode === "current") {
    assert.equal(result.read_count, 3);
    assert.ok(result.source_text_bytes > 0);
    assert.ok(result.pages > 0 || result.cells > 0);
  } else {
    assert.equal(result.read_count, 0);
    assert.ok(result.failure_observed);
  }
  const namespace = path.join(dataRoot, "pv");
  const leftovers = existsSync(namespace)
    ? readdirSync(namespace, { withFileTypes: true })
    : [];
  assert.equal(leftovers.length, mode === "poison" ? 1 : 0);
  if (mode !== "changed" && mode !== "current_changed")
    assert.deepEqual(readFileSync(source), bytes);
  results.push({
    name,
    mode,
    pathMode,
    elapsedMs: Date.now() - started,
    result,
  });
}
const evidence = {
  schema: 1,
  scope:
    "Application resource and physical Product lane only; Runtime admission/Bridge/Renderer remain unqualified",
  componentManifestSha256: component.manifestSha256,
  probeSha256: createHash("sha256").update(readFileSync(probe)).digest("hex"),
  results,
};
writeFileSync(
  path.join(directory, "evidence.json"),
  JSON.stringify(evidence, null, 2) + "\n",
);
console.log(JSON.stringify({ directory, ...evidence }));
