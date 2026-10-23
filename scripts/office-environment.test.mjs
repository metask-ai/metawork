import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  localOfficeEnvironment,
  officeEnvironmentPath,
} from "./office-environment.mjs";

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), "metawork-office-env-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const filename = officeEnvironmentPath(root);
  mkdirSync(path.dirname(filename), { recursive: true });
  const component = path.join(root, "component");
  const files = [];
  for (const name of [
    "bin/office.exe",
    "python/bin/python.exe",
    "skills/docx/SKILL.md",
    "skills/xlsx/SKILL.md",
    "skills/pptx/SKILL.md",
  ]) {
    const bytes = Buffer.from("fixture " + name);
    mkdirSync(path.dirname(path.join(component, name)), { recursive: true });
    writeFileSync(path.join(component, name), bytes);
    files.push({
      path: name,
      bytes: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    });
  }
  const manifest = JSON.stringify({
    schema: 1,
    target: "x86_64-windows-msvc",
    files,
  });
  writeFileSync(path.join(component, "office-runtime.json"), manifest);
  const config = {
    schema: 2,
    componentRoot: component,
    manifestSha256: createHash("sha256").update(manifest).digest("hex"),
  };
  return { root, filename, config };
}

test("unprepared Office leaves the Application default basic Skill source intact", (t) => {
  const { root } = fixture(t);
  const inherited = {
    PATH: "ambient",
    NODE_PATH: "user modules",
    KEEP: "value",
  };
  assert.deepEqual(localOfficeEnvironment(root, inherited), inherited);
  assert.equal(
    localOfficeEnvironment(root, inherited).METAWORK_LOCAL_SKILL_ROOT,
    undefined,
  );
});

test(
  "prepared Office selects only its Skill root and does not take over Task libraries",
  { skip: process.platform !== "win32" || process.arch !== "x64" },
  (t) => {
    const { root, filename, config } = fixture(t);
    writeFileSync(filename, JSON.stringify(config));
    const inherited = {
      PATH: "ambient",
      NODE_PATH: "user modules",
      KEEP: "value",
    };
    const result = localOfficeEnvironment(root, inherited);
    assert.deepEqual(result, {
      ...inherited,
      METAWORK_LOCAL_SKILL_ROOT: path.join(config.componentRoot, "skills"),
    });
    assert.equal(inherited.METAWORK_LOCAL_SKILL_ROOT, undefined);
    writeFileSync(
      path.join(config.componentRoot, "skills/docx/SKILL.md"),
      "changed Skill",
    );
    assert.throws(
      () => localOfficeEnvironment(root, inherited),
      /resource changed/u,
    );
  },
);

test("legacy, malformed or changed component selection cannot fall back to ambient tools", (t) => {
  const { root, filename, config } = fixture(t);
  for (const invalid of [
    null,
    { schema: 1, python: "old interpreter", toolDirectories: [] },
    { ...config, extra: true },
  ]) {
    writeFileSync(filename, JSON.stringify(invalid));
    assert.throws(
      () => localOfficeEnvironment(root, { PATH: "ambient" }),
      /selection is invalid/u,
    );
  }
  writeFileSync(filename, "{broken");
  assert.throws(() => localOfficeEnvironment(root), SyntaxError);
});
