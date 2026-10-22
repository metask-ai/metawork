import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { officeComponentSources } from "./office-component-sources.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
test("Windows component wheel identities exactly cover the pinned requirements", () => {
  assert.equal(
    officeComponentSources(root).sources.target,
    "x86_64-windows-msvc",
  );
});

test("component sources refuse stale requirements, missing wheels, duplicates and mutable transport", (t) => {
  const scratch = mkdtempSync(
    path.join(os.tmpdir(), "metawork-office-sources-"),
  );
  t.after(() => rmSync(scratch, { recursive: true, force: true }));
  mkdirSync(path.join(scratch, "build_support"));
  mkdirSync(path.join(scratch, "scripts"));
  const wheelPath = "build_support/office-python.windows-x64.lock.json";
  const restore = () => {
    for (const file of [
      wheelPath,
      "build_support/office-runtime.windows-x64.sources.json",
      "scripts/office-requirements.txt",
    ])
      writeFileSync(
        path.join(scratch, file),
        readFileSync(path.join(root, file)),
      );
  };
  for (const change of [
    (lock) => lock.wheels.pop(),
    (lock) => lock.wheels.push(lock.wheels[0]),
    (lock) => {
      lock.wheels[0].url = lock.wheels[0].url.replace("https:", "http:");
    },
    (lock) => {
      lock.wheels[0].sha256 = "not-a-digest";
    },
    (lock) => {
      lock.requirementsSha256 = "0".repeat(64);
    },
  ]) {
    restore();
    const lock = JSON.parse(
      readFileSync(path.join(scratch, wheelPath), "utf8"),
    );
    change(lock);
    writeFileSync(path.join(scratch, wheelPath), JSON.stringify(lock));
    assert.throws(() => officeComponentSources(scratch), /Office/u);
  }
});
