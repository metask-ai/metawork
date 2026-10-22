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
import {
  officeComponentSources,
  officeAuthoringLock,
  officePublicDownloads,
  queryOfficeAuthoring,
} from "./office-component-sources.mjs";

const root = fileURLToPath(new URL("..", import.meta.url));
test("Windows component wheel identities exactly cover the pinned requirements", () => {
  assert.equal(
    officeComponentSources(root).sources.target,
    "x86_64-windows-msvc",
  );
});

test(
  "producer and public qualification use the same root-locked authoring closure",
  { skip: process.platform !== "win32" },
  () => {
    const authoring = queryOfficeAuthoring(root);
    const canonical = JSON.parse(
      readFileSync(path.join(root, "package-lock.json"), "utf8"),
    );
    const selected = [];
    for (const [location, entry] of Object.entries(authoring.lock.packages)) {
      if (!location) continue;
      const { dev, devOptional, ...expected } = canonical.packages[location];
      assert.deepEqual(entry, expected);
      selected.push({ location, version: entry.version });
    }
    assert.ok(
      selected.length > 2,
      "include transitive packages, not only the two authoring roots",
    );
    const downloads = officePublicDownloads(root, authoring);
    assert.equal(
      downloads.filter((item) => item.name.startsWith("javascript:")).length,
      selected.length,
    );
    assert.equal(
      new Set(downloads.map((item) => item.name)).size,
      downloads.length,
    );
    assert.throws(
      () => officeAuthoringLock(root, [...selected, selected[0]]),
      /root lock/u,
    );
    assert.throws(
      () =>
        officeAuthoringLock(
          root,
          selected.map((item, i) => (i ? item : { ...item, version: "wrong" })),
        ),
      /root lock/u,
    );
    assert.throws(
      () =>
        officeAuthoringLock(
          root,
          selected.filter((item) => item.location !== "node_modules/docx"),
        ),
      /required root/u,
    );
    for (const changed of [
      { resolved: "https://other.example/package.tgz" },
      { resolved: "https://registry.npmjs.org/package.tgz?latest" },
      { integrity: "sha1-old" },
      { hasInstallScript: true },
    ]) {
      const copy = structuredClone(authoring);
      Object.assign(copy.lock.packages[selected[0].location], changed);
      assert.throws(
        () => officePublicDownloads(root, copy),
        /public JavaScript source/u,
      );
    }
  },
);

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
