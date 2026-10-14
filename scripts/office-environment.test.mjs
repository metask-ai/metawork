import assert from "node:assert/strict";
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
  const python = path.join(
    path.dirname(filename),
    "venv",
    process.platform === "win32" ? "Scripts/python.exe" : "bin/python",
  );
  mkdirSync(path.dirname(python), { recursive: true });
  writeFileSync(python, "fixture executable");
  const tools = path.join(root, "tools");
  mkdirSync(tools);
  const config = { schema: 1, python, toolDirectories: [tools] };
  return { root, filename, config };
}

test("unprepared Office setup preserves the inherited environment", (t) => {
  const { root } = fixture(t);
  const inherited = { PATH: "ambient", KEEP: "value" };
  assert.deepEqual(localOfficeEnvironment(root, inherited), inherited);
});

test("prepared Office runtime is supplied to Task processes without mutating the caller", (t) => {
  const { root, filename, config } = fixture(t);
  writeFileSync(filename, JSON.stringify(config));
  const inherited = {
    PATH: "ambient",
    NODE_PATH: "ambient modules",
    KEEP: "value",
  };
  const result = localOfficeEnvironment(root, inherited);
  assert.equal(
    result.PATH,
    [
      path.dirname(config.python),
      ...config.toolDirectories,
      path.dirname(process.execPath),
      inherited.PATH,
    ].join(path.delimiter),
  );
  assert.equal(result.NODE_PATH, path.join(root, "node_modules"));
  assert.equal(result.PYTHONDONTWRITEBYTECODE, "1");
  assert.equal(inherited.NODE_PATH, "ambient modules");
});

test("invalid prepared runtime fails instead of falling back to ambient tools", (t) => {
  const { root, filename, config } = fixture(t);
  for (const invalid of [
    null,
    { ...config, schema: 2 },
    { ...config, extra: true },
    { ...config, python: process.execPath },
    { ...config, toolDirectories: ["relative"] },
    { ...config, toolDirectories: [config.python] },
    { ...config, toolDirectories: [path.join(root, "missing")] },
  ]) {
    writeFileSync(filename, JSON.stringify(invalid));
    assert.throws(
      () => localOfficeEnvironment(root, { PATH: "ambient" }),
      /environment is invalid/,
    );
  }
  writeFileSync(filename, "{broken");
  assert.throws(() => localOfficeEnvironment(root), SyntaxError);
});
