import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { verifyMainPackageStage } from "./main-package-contents.mjs";

test("small Office dependencies in the runtime stage are still rejected", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "metawork-package-stage-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, "bin");
  mkdirSync(bin);
  writeFileSync(path.join(bin, "metawork.exe"), "app");
  writeFileSync(path.join(bin, "WebView2Loader.dll"), "loader");
  assert.equal(verifyMainPackageStage(root).files, 2);
  for (const name of [
    "node.exe",
    "python.exe",
    "python312.dll",
    "soffice.bin",
    "LibreOffice.app",
    "docx",
    "module.pyd",
    "library.whl",
  ]) {
    const unwanted = path.join(bin, name);
    writeFileSync(unwanted, "small");
    assert.throws(() => verifyMainPackageStage(root), /Office dependency/u);
    rmSync(unwanted);
  }
});
