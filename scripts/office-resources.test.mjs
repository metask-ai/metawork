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
    "scripts/office-environment.mjs",
    "build_support/office-environment.json",
    base + "requirements.txt",
    base + "package-lock.json",
    base + "requirements.windows-aarch64.txt",
    base + "requirements.macos-aarch64.txt",
    base + "requirements.macos-x86_64.txt",
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

test("all Office targets are exact and Windows x64 keeps its installed identities", async () => {
  const { environment } = await import("./office-environment.mjs");
  const config = environment(process.cwd());
  assert.equal(
    config.targets["windows-x86_64"].pythonId,
    "bd948c50c30962f7f7703b852233b9ec4f98859d7b8a0dc218d311a7b41ad89c",
  );
  assert.equal(
    config.targets["windows-x86_64"].nodeId,
    "b7046de901f3a4d91ffa2c5b4ec5b2706bf2ab4d27f9f698405ae5204179e4d8",
  );
  assert.equal(
    new Set(
      Object.values(config.targets).flatMap((t) => [t.pythonId, t.nodeId]),
    ).size,
    8,
  );
});

test("Office manifest rejects missing targets, wrong architecture and stale target locks", async (t) => {
  const { environment } = await import("./office-environment.mjs");
  const { cpSync } = await import("node:fs");
  const fixture = mkdtempSync(path.join(tmpdir(), "office-targets-"));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));
  mkdirSync(path.join(fixture, "build_support"));
  cpSync(
    "src/product/skill/office_environment",
    path.join(fixture, "src/product/skill/office_environment"),
    { recursive: true },
  );
  const file = path.join(fixture, "build_support/office-environment.json");
  const original = JSON.parse(
    readFileSync("build_support/office-environment.json"),
  );
  for (const mutate of [
    (c) => {
      delete c.targets["macos-x86_64"];
    },
    (c) => {
      c.targets["windows-aarch64"].python.target = "windows-x86_64";
    },
    (c) => {
      c.targets["macos-aarch64"].node.url = c.targets["macos-x86_64"].node.url;
    },
    (c) => {
      c.targets["macos-aarch64"].layout.nodeExecutable = "../node";
    },
    (c) => {
      c.targets["macos-x86_64"].downloadTotals.python.lockSha256 = "0".repeat(
        64,
      );
    },
  ]) {
    const copy = structuredClone(original);
    mutate(copy);
    writeFileSync(file, JSON.stringify(copy));
    assert.throws(() => environment(fixture));
  }
  const copy = structuredClone(original);
  copy.targets["macos-aarch64"].downloadTotals.node.librariesBytes++;
  copy.targets["macos-aarch64"].downloadTotals.node.totalBytes++;
  writeFileSync(file, JSON.stringify(copy));
  assert.equal(
    environment(fixture).targets["macos-aarch64"].nodeId,
    environment(process.cwd()).targets["macos-aarch64"].nodeId,
  );
});

test("each packed Office Skill contains the shared platform and consent instructions", async () => {
  const { gunzipSync } = await import("node:zlib");
  const bytes = gunzipSync(readFileSync("src/app/office-skills.tar.gz"));
  const definitions = [];
  for (let offset = 0; offset + 512 <= bytes.length;) {
    const header = bytes.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) break;
    const name = header.subarray(0, 100).toString().replace(/\0.*$/, "");
    const size = parseInt(
      header.subarray(124, 136).toString().replace(/\0.*$/, ""),
      8,
    );
    if (/^(docx|xlsx|pptx)\/SKILL\.md$/.test(name))
      definitions.push(
        bytes.subarray(offset + 512, offset + 512 + size).toString(),
      );
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  assert.equal(definitions.length, 3);
  for (const text of definitions) {
    assert.doesNotMatch(text, /\{\{OFFICE_[A-Z_]+\}\}/);
    for (const required of [
      "/environment/run.sh",
      "/environment/run.cmd",
      "fresh Node preparation requires",
      "Download agreement does not grant",
      "DeliverFile",
      "checked_copy",
    ])
      assert.ok(text.includes(required), required);
  }
});
