import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  archiveEnvironmentPath,
  archiveHelperPath,
  localArchiveEnvironment,
} from "./archive-environment.mjs";

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), "metawork-archive-env-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const filename = archiveEnvironmentPath(root);
  const helper = archiveHelperPath(root);
  mkdirSync(path.dirname(filename), { recursive: true });
  mkdirSync(path.dirname(helper), { recursive: true });
  const python = path.join(root, "python with spaces");
  writeFileSync(python, "fixture interpreter");
  writeFileSync(helper, "fixture helper");
  return { root, filename, helper, config: { schema: 1, python } };
}

test("unprepared archive environment does not advertise inherited capabilities", (t) => {
  const { root } = fixture(t);
  const inherited = {
    KEEP: "value",
    METAWORK_LOCAL_ARCHIVE_HELPER: "other checkout",
    METAWORK_LOCAL_ARCHIVE_PYTHON: "ambient",
  };
  assert.deepEqual(localArchiveEnvironment(root, inherited), { KEEP: "value" });
  assert.equal(inherited.METAWORK_LOCAL_ARCHIVE_PYTHON, "ambient");
});

test("archive environment needs only a configured Python and repository helper", (t) => {
  const { root, filename, helper, config } = fixture(t);
  writeFileSync(filename, JSON.stringify(config));
  assert.deepEqual(localArchiveEnvironment(root, { PATH: "ambient" }), {
    PATH: "ambient",
    METAWORK_LOCAL_ARCHIVE_PYTHON: config.python,
    METAWORK_LOCAL_ARCHIVE_HELPER: helper,
  });
});

test("configured archive environment fails closed on invalid metadata or missing resources", (t) => {
  const { root, filename, helper, config } = fixture(t);
  for (const invalid of [
    null,
    { ...config, schema: 2 },
    { ...config, extra: true },
    { ...config, python: "relative" },
    { ...config, python: root },
    { ...config, python: path.join(root, "missing") },
  ]) {
    writeFileSync(filename, JSON.stringify(invalid));
    assert.throws(
      () => localArchiveEnvironment(root),
      /environment is invalid/,
    );
  }
  writeFileSync(filename, JSON.stringify(config));
  rmSync(helper);
  assert.throws(() => localArchiveEnvironment(root), /environment is invalid/);
});
