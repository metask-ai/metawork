import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { localOfficeComponent } from "./office-environment.mjs";
import { officeWorkflowInventory } from "./office-workflows.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
officeWorkflowInventory(root);
const component = localOfficeComponent(root);
if (!component)
  throw new Error(
    "Select a prepared Office component with office:setup -- --component <absolute-root>",
  );
const cache = path.join(root, ".zig-cache/office-smoke");
mkdirSync(cache, { recursive: true });
const output = mkdtempSync(path.join(cache, "run-"));
function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: output,
    encoding: "utf8",
    timeout: 240_000,
    maxBuffer: 4 * 1024 * 1024,
    windowsHide: true,
  });
  if (result.error || result.status !== 0)
    throw new Error(
      `Office check failed: ${result.stdout ?? ""}\n${result.stderr ?? ""}`,
    );
  return result.stdout;
}
const python = (args) => run(component.entry, ["python", ...args]);
const helper = (skill, name, args) =>
  python([path.join(component.skillsRoot, skill, "scripts", name), ...args]);
run(component.entry, ["selftest"]);
run(process.execPath, [
  path.join(root, "scripts/sync-office-archive.mjs"),
  "--check",
]);
python([
  path.join(root, "scripts/check-office-failures.py"),
  component.skillsRoot,
]);
python([path.join(root, "scripts/check-office-archives.py")]);
for (const skill of ["docx", "xlsx", "pptx"])
  python([
    path.join(root, "scripts/check-office-validators.py"),
    path.join(component.skillsRoot, skill, "scripts/office"),
    "--entry",
    component.entry,
  ]);
run(component.entry, [
  "node",
  path.join(root, "scripts/create-office-engine-fixtures.mjs"),
  output,
]);
for (const [skill, sourceName, xmlName, marker] of [
  ["docx", "original.docx", "word/document.xml", "Windows Office 中文验收"],
  ["pptx", "sample.pptx", "ppt/slides/slide1.xml", "第一页 First slide"],
]) {
  const source = path.join(output, sourceName);
  const original = readFileSync(source);
  const unpacked = path.join(output, `${skill}-unpacked`);
  helper(skill, "office/unpack.py", [source, unpacked]);
  const xml = path.join(unpacked, xmlName);
  const content = readFileSync(xml, "utf8");
  assert.ok(content.includes(marker));
  writeFileSync(xml, content.replace(marker, "MetaWork edited 中文"));
  const edited = path.join(output, `edited.${skill}`);
  helper(skill, "office/pack.py", [unpacked, edited, "--original", source]);
  helper(skill, "office/validate.py", [edited, "--original", source]);
  const text = path.join(output, `${skill}-text.json`);
  run(component.entry, ["text", edited, text]);
  assert.ok(readFileSync(text, "utf8").includes("MetaWork edited 中文"));
  assert.deepEqual(readFileSync(source), original);
}
python([path.join(root, "scripts/check-office-authoring.py"), component.root]);
python([path.join(root, "scripts/check-office-engine.py"), component.root]);
python([path.join(root, "scripts/check-office-previews.py"), component.root]);
console.log(`Office packaged workflows passed: ${output}`);
