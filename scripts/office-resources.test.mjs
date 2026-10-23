import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

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
