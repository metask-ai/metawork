import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  localOfficeEnvironment,
  officeEnvironmentPath,
} from "./office-environment.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
if (!existsSync(officeEnvironmentPath(root)))
  throw new Error(
    "Prepare the local Office environment before running this check.",
  );
const config = JSON.parse(readFileSync(officeEnvironmentPath(root), "utf8"));
const env = localOfficeEnvironment(root);
const cache = path.join(root, ".zig-cache", "office-smoke");
mkdirSync(cache, { recursive: true });
const output = mkdtempSync(path.join(cache, "run-"));
const assets = path.join(root, "src", "product", "skill", "assets");
function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: output,
    env,
    encoding: "utf8",
    timeout: 60_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(
      `${path.basename(command)} ${args.join(" ")} failed: ${result.stdout}\n${result.stderr}`,
    );
  return result.stdout;
}
function helper(skill, script, args) {
  return run(config.python, [
    path.join(assets, skill, "scripts", script),
    ...args,
  ]);
}
run(config.python, [
  path.join(root, "scripts", "check-office-failures.py"),
  assets,
]);
run(process.execPath, [
  path.join(root, "scripts/sync-office-archive.mjs"),
  "--check",
]);
run(config.python, [path.join(root, "scripts/check-office-archives.py")]);
for (const skill of ["docx", "xlsx", "pptx"])
  run(config.python, [
    path.join(root, "scripts/check-office-validators.py"),
    path.join(assets, skill, "scripts/office"),
  ]);
const marker = "MetaWork Office smoke";
run(process.execPath, [
  "-e",
  `
  const fs = require('node:fs');
  const { Document, Packer, Paragraph } = require('docx');
  const PptxGenJS = require('pptxgenjs');
  (async () => {
    fs.writeFileSync('sample.docx', await Packer.toBuffer(new Document({ sections: [{ children: [new Paragraph(${JSON.stringify(marker)})] }] })));
    const deck = new PptxGenJS(); deck.layout = 'LAYOUT_WIDE';
    const slide = deck.addSlide(); slide.addText(${JSON.stringify(marker)}, { x: 0.5, y: 0.5, w: 10, h: 1, fontSize: 24 });
    slide.addShape(deck.ShapeType.rect, { x: 0.5, y: 2, w: 4, h: 1, fill: { color: '327C67' } });
    await deck.writeFile({ fileName: 'sample.pptx' });
  })().catch(error => { console.error(error); process.exitCode = 1; });
`,
]);
run(config.python, [
  "-c",
  "from openpyxl import Workbook; w=Workbook(); s=w.active; s['A1']='Amount'; s['A2']=5; s['B2']=7; s['C2']='=A2+B2'; w.save('sample.xlsx')",
]);
for (const skill of ["docx", "pptx"]) {
  const source = path.join(output, `sample.${skill}`);
  const unpacked = path.join(output, `${skill}-unpacked`);
  helper(skill, "office/unpack.py", [source, unpacked]);
  const part = path.join(
    unpacked,
    skill === "docx" ? "word/document.xml" : "ppt/slides/slide1.xml",
  );
  const xml = readFileSync(part, "utf8");
  assert.ok(xml.includes(marker));
  writeFileSync(part, xml.replace(marker, "MetaWork Office edited"));
  helper(skill, "office/pack.py", [
    unpacked,
    path.join(output, `edited.${skill}`),
    "--original",
    source,
  ]);
  helper(skill, "office/validate.py", [
    path.join(output, `edited.${skill}`),
    "--original",
    source,
  ]);
  if (skill === "pptx")
    assert.ok(
      run(config.python, [
        "-m",
        "markitdown",
        path.join(output, "edited.pptx"),
      ]).includes("MetaWork Office edited"),
    );
}
const workbook = path.join(output, "sample.xlsx");
let summary = JSON.parse(helper("xlsx", "recalc.py", [workbook, "30"]));
assert.equal(summary.status, "success");
assert.equal(summary.total_formulas, 1);
run(config.python, [
  "-c",
  "from openpyxl import load_workbook; w=load_workbook('sample.xlsx', data_only=True); assert w.active['C2'].value == 12; w.close(); w=load_workbook('sample.xlsx'); w.active['A2']=15; w.save('sample.xlsx')",
]);
summary = JSON.parse(helper("xlsx", "recalc.py", [workbook, "30"]));
assert.equal(summary.status, "success");
run(config.python, [
  "-c",
  "from openpyxl import load_workbook; w=load_workbook('sample.xlsx', data_only=True); assert w.active['C2'].value == 22; w.close(); w=load_workbook('sample.xlsx'); assert w.active['C2'].value == '=A2+B2'; w.close()",
]);
helper("xlsx", "office/unpack.py", [
  workbook,
  path.join(output, "xlsx-unpacked"),
]);
assert.ok(
  readFileSync(
    path.join(output, "xlsx-unpacked/xl/worksheets/sheet1.xml"),
    "utf8",
  ).includes("22"),
);
for (const [skill, filename] of [
  ["docx", "edited.docx"],
  ["pptx", "edited.pptx"],
  ["xlsx", "sample.xlsx"],
]) {
  const profile = pathToFileURL(path.join(output, `${skill}-profile`)).href;
  helper(skill, "office/soffice.py", [
    `-env:UserInstallation=${profile}`,
    "--headless",
    "--convert-to",
    "pdf",
    "--outdir",
    output,
    path.join(output, filename),
  ]);
  const basename = path.basename(filename, path.extname(filename));
  run("pdftoppm", [
    "-f",
    "1",
    "-singlefile",
    "-png",
    "-r",
    "72",
    path.join(output, `${basename}.pdf`),
    path.join(output, `${skill}-page`),
  ]);
  assert.ok(readFileSync(path.join(output, `${skill}-page.png`)).length > 1000);
}
console.log(
  `Office create/read/edit/validate/recalculate/render checks passed: ${output}`,
);
