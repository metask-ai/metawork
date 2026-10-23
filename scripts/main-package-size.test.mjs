import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  verifyMainPackageSize,
  verifyMainPackageStage,
} from "./main-package-size.mjs";

test("main installer budget covers the whole artifact and rejects excess bytes", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "metawork-package-size-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const artifact = path.join(root, "installer.exe");
  writeFileSync(artifact, "");
  for (const target of ["x86_64-windows-msvc", "aarch64-windows-msvc"]) {
    truncateSync(artifact, 1);
    const { maximumBytes } = verifyMainPackageSize(target, artifact);
    truncateSync(artifact, maximumBytes);
    assert.equal(verifyMainPackageSize(target, artifact).bytes, maximumBytes);
    truncateSync(artifact, maximumBytes + 1);
    assert.throws(
      () => verifyMainPackageSize(target, artifact),
      /size rejected/u,
    );
  }
  truncateSync(artifact, 0);
  assert.throws(
    () => verifyMainPackageSize("x86_64-windows-msvc", artifact),
    /size rejected/u,
  );
  assert.throws(() => verifyMainPackageSize("unknown", artifact), /baseline/u);
});

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
