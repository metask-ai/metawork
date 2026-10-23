// Real locked archives in two roots, with imports and document creation using
// the selected component's interpreters. This does not install an App component.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  lstatSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  officeDependencyRecipe,
  queryOfficeAuthoring,
} from "./office-component-sources.mjs";
import { readOfficeComponent } from "./office-environment.mjs";

if (process.platform !== "win32" || process.argv.length !== 4)
  throw Error(
    "Usage on Windows: check-office-package-layout.mjs <prepared-component> <canonical-download-cache>",
  );
const root = fileURLToPath(new URL("..", import.meta.url));
const component = readOfficeComponent(path.resolve(process.argv[2]));
const downloads = path.resolve(process.argv[3]);
const cache = path.join(root, ".zig-cache/office-package-layout");
mkdirSync(cache, { recursive: true });
const directory = mkdtempSync(path.join(cache, "run-"));
const recipe = officeDependencyRecipe(root, queryOfficeAuthoring(root));
const recipePath = path.join(directory, "recipe.json");
writeFileSync(recipePath, JSON.stringify(recipe, null, 2) + "\n");
const digest = (file) =>
  createHash("sha256").update(readFileSync(file)).digest("hex");
const inputs = [
  "src/app/office_bootstrap/packages.py",
  "src/app/office_bootstrap/msi.py",
  "src/product/control/resources/archive.py",
  "scripts/check-office-package-layout.mjs",
  "scripts/office-component-sources.mjs",
].map((name) => ({ path: name, sha256: digest(path.join(root, name)) }));
for (const name of ["python/bin/python.exe", "node/node.exe"]) {
  const expected = component.manifest.files.find(
    (entry) => entry.path === name,
  );
  assert.equal(digest(path.join(component.root, name)), expected.sha256);
}
const inventory = (base) => {
  const files = {};
  function visit(current) {
    for (const name of readdirSync(current).sort()) {
      const file = path.join(current, name),
        status = lstatSync(file);
      if (status.isDirectory()) visit(file);
      else {
        assert.ok(status.isFile() && !status.isSymbolicLink());
        files[path.relative(base, file).split(path.sep).join("/")] = {
          bytes: status.size,
          sha256: digest(file),
        };
      }
    }
  }
  visit(base);
  return files;
};
const run = (exe, args, cwd) =>
  execFileSync(exe, args, {
    cwd,
    windowsHide: true,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 1024 * 1024,
    env: {
      SystemRoot: process.env.SystemRoot,
      WINDIR: process.env.WINDIR,
      TEMP: cwd,
      TMP: cwd,
    },
  });
const results = [];
for (const name of ["first", "different 中文 root"]) {
  const destination = path.join(directory, name);
  mkdirSync(destination);
  const assembled = JSON.parse(
    run(
      component.python,
      [
        "-I",
        "-S",
        "-B",
        "-X",
        "utf8",
        path.join(root, "src/app/office_bootstrap/packages.py"),
        recipePath,
        downloads,
        destination,
        "--archive-helper",
        path.join(root, "src/product/control/resources/archive.py"),
      ],
      directory,
    ),
  );
  const before = inventory(destination);
  const outputs = path.join(directory, name + "-outputs");
  mkdirSync(outputs);
  const python = JSON.parse(
    run(
      component.python,
      [
        "-I",
        "-S",
        "-B",
        "-X",
        "utf8",
        "-c",
        `
import sys,json,importlib.metadata as md
from pathlib import Path
vendor=Path(sys.argv[1]);sys.path.insert(0,str(vendor))
import numpy,pandas,openpyxl,pypdf,defusedxml,lxml.etree,PIL.Image,et_xmlfile,dateutil,pytz,six,tzdata,xlsxwriter
modules=[numpy,pandas,openpyxl,pypdf,defusedxml,lxml.etree,PIL.Image,et_xmlfile,dateutil,pytz,six,tzdata,xlsxwriter]
assert all(Path(module.__file__).resolve().is_relative_to(vendor) for module in modules)
assert int(numpy.dot([2,3],[4,5]))==23
assert pandas.DataFrame({'value':[1,2]}).value.sum()==3
w=openpyxl.Workbook();w.active['A1']='中文';w.active['B1']='=1+2';w.save(sys.argv[2]);w.close()
print(json.dumps({'modules':len(modules),'numpy':md.version('numpy'),'pandas':md.version('pandas')}))
`,
        path.join(destination, "python-packages"),
        path.join(outputs, "sample.xlsx"),
      ],
      outputs,
    ),
  );
  const javascript = JSON.parse(
    run(
      path.join(component.root, "node/node.exe"),
      [
        "-e",
        `
const {createRequire}=require('node:module');const fs=require('node:fs'),path=require('node:path');
const base=process.argv[1], out=process.argv[2], local=createRequire(path.join(base,'package.json'));
const {Document,Packer,Paragraph}=local('docx'), PptxGenJS=local('pptxgenjs');
for(const name of ['docx','pptxgenjs'])if(!local.resolve(name).startsWith(base+path.sep))throw Error('ambient package');
(async()=>{fs.writeFileSync(path.join(out,'sample.docx'),await Packer.toBuffer(new Document({sections:[{children:[new Paragraph('Offline package layout 中文')]}]})));
const p=new PptxGenJS();p.addSlide().addText('Offline package layout 中文',{x:1,y:1,w:8,h:1});await p.writeFile({fileName:path.join(out,'sample.pptx')});
console.log(JSON.stringify({created:['docx','pptx']}));})().catch(e=>{console.error(e);process.exitCode=1});
`,
        path.join(destination, "authoring"),
        outputs,
      ],
      outputs,
    ),
  );
  run(
    component.python,
    [
      "-I",
      "-S",
      "-B",
      "-c",
      `
from zipfile import ZipFile
import sys
from pathlib import Path
root=Path(sys.argv[1])
for name,member in [('sample.docx','word/document.xml'),('sample.pptx','ppt/slides/slide1.xml')]:
 with ZipFile(root/name) as z:assert 'Offline package layout' in z.read(member).decode('utf-8')
`,
      outputs,
    ],
    outputs,
  );
  assert.deepEqual(
    inventory(destination),
    before,
    "library use changed immutable vendored files",
  );
  results.push({
    destination,
    assembled,
    python,
    javascript,
    inventory: before,
  });
}
assert.deepEqual(
  results[0].inventory,
  results[1].inventory,
  "assembly depends on its absolute destination",
);
const componentLibraries = Object.fromEntries(
  component.manifest.files
    .filter((entry) => /^(?:python-packages|authoring)\//u.test(entry.path))
    .map(({ path: name, bytes, sha256 }) => [name, { bytes, sha256 }]),
);
assert.deepEqual(
  results[0].inventory,
  componentLibraries,
  "producer payload differs from current offline assembly",
);
for (const input of inputs)
  assert.equal(
    digest(path.join(root, input.path)),
    input.sha256,
    "qualification input changed while running",
  );
const evidence = {
  schema: 1,
  passed: true,
  scope:
    "Fixed public dependency vendoring only; not client install/signing/clean-machine acceptance",
  componentManifestSha256: component.manifestSha256,
  recipeSha256: digest(recipePath),
  assemblerSha256: digest(
    path.join(root, "src/app/office_bootstrap/packages.py"),
  ),
  collectorSha256: digest(fileURLToPath(import.meta.url)),
  inputs,
  producerPayloadMatches: true,
  files: Object.keys(results[0].inventory).length,
  bytes: Object.values(results[0].inventory).reduce(
    (sum, entry) => sum + entry.bytes,
    0,
  ),
  results,
};
writeFileSync(
  path.join(directory, "evidence.json"),
  JSON.stringify(evidence, null, 2) + "\n",
);
console.log(
  JSON.stringify({
    directory,
    files: evidence.files,
    bytes: evidence.bytes,
    passed: true,
  }),
);
