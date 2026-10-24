import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

test("shipped full Office archive matches canonical Skills, helpers and locked environments", () => {
  execFileSync(
    process.execPath,
    ["scripts/sync-office-archive.mjs", "--check"],
    { stdio: "pipe" },
  );
  execFileSync(
    process.execPath,
    ["scripts/build-office-skills.mjs", "--check"],
    { stdio: "pipe" },
  );
});

test("Office dependencies are complete minimal locks, independent of application development packages", () => {
  const base = "src/product/skill/office_environment/";
  const requirements = readFileSync(base + "requirements.txt", "utf8")
    .trim()
    .split(/\r?\n/);
  assert.equal(requirements.length, 5);
  assert.ok(
    requirements.every((line) =>
      /^[\w-]+==[\w.]+ --hash=sha256:[0-9a-f]{64}$/.test(line),
    ),
  );
  const pkg = JSON.parse(readFileSync(base + "package.json"));
  const lock = JSON.parse(readFileSync(base + "package-lock.json"));
  assert.deepEqual(Object.keys(pkg.dependencies).sort(), ["docx", "pptxgenjs"]);
  assert.deepEqual(lock.packages[""].dependencies, pkg.dependencies);
  for (const [name, dependency] of Object.entries(lock.packages)) {
    if (!name) continue;
    assert.match(dependency.integrity, /^sha512-/);
    assert.equal(dependency.dev, undefined);
  }
});

test("changed dependency locks cannot retain stale download totals", (t) => {
  const fixture = mkdtempSync(path.join(tmpdir(), "office-download-totals-"));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));
  const base = "src/product/skill/office_environment/";
  for (const file of [
    "scripts/build-office-skills.mjs",
    "build_support/office-environment.json",
    base + "requirements.txt",
    base + "package-lock.json",
  ]) {
    const target = path.join(fixture, file);
    mkdirSync(path.dirname(target), { recursive: true });
    copyFileSync(file, target);
  }
  for (const [language, name] of [
    ["python", "requirements.txt"],
    ["node", "package-lock.json"],
  ]) {
    const file = path.join(fixture, base, name);
    const original = readFileSync(file);
    writeFileSync(file, Buffer.concat([original, Buffer.from("\n")]));
    assert.throws(
      () =>
        execFileSync(
          process.execPath,
          [path.join(fixture, "scripts/build-office-skills.mjs")],
          { stdio: "pipe" },
        ),
      (error) =>
        error.stderr
          .toString()
          .includes(`Remeasure Office ${language} download totals`),
    );
    writeFileSync(file, original);
  }
});
