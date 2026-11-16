import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  formatMainPackageSizeDelta,
  mainPackageSizeBaseline,
  mainPackageSizePolicy,
  parseMainPackageSizeArguments,
  recordedMainPackageSizePolicy,
  reportMainPackageSize,
  verifyMainPackageStage,
} from "./main-package-size.mjs";

const releasedPolicy = JSON.parse(
  readFileSync(
    new URL("../build_support/main-package-size.json", import.meta.url),
    "utf8",
  ),
);

test("the whole installer is measured against its own released baseline instead of a budget", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "metawork-package-size-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const artifact = path.join(root, "installer.exe");
  writeFileSync(artifact, "");
  for (const target of ["x86_64-windows-msvc", "aarch64-windows-msvc"]) {
    const baseline = mainPackageSizeBaseline(releasedPolicy, target);
    truncateSync(artifact, baseline.bytes);
    const unchanged = reportMainPackageSize(target, artifact);
    assert.deepEqual(
      {
        bytes: unchanged.bytes,
        baselineVersion: unchanged.baselineVersion,
        baselineBytes: unchanged.baselineBytes,
        deltaBytes: unchanged.deltaBytes,
        deltaPercent: unchanged.deltaPercent,
      },
      {
        bytes: baseline.bytes,
        baselineVersion: baseline.version,
        baselineBytes: baseline.bytes,
        deltaBytes: 0,
        deltaPercent: 0,
      },
    );
    assert.match(
      unchanged.summary,
      new RegExp(`\\+0 bytes \\(\\+0\\.00%\\).*${baseline.version}`, "u"),
    );

    // Growth is reported, never rejected: an installer far past the former
    // budget still returns a measurement and the caller keeps going.
    truncateSync(artifact, baseline.bytes + 4_194_304);
    const grown = reportMainPackageSize(target, artifact);
    assert.equal(grown.deltaBytes, 4_194_304);
    assert.ok(grown.deltaPercent > 0);
    assert.match(grown.summary, /\+4194304 bytes \(\+\d+\.\d\d%\)/u);

    truncateSync(artifact, baseline.bytes - 1024);
    const shrunk = reportMainPackageSize(target, artifact);
    assert.equal(shrunk.deltaBytes, -1024);
    assert.match(shrunk.summary, /-1024 bytes \(-0\.\d\d%\)/u);
  }

  // An artifact that cannot be measured is still a failure: the report must
  // describe a real file or say nothing.
  truncateSync(artifact, 0);
  assert.throws(
    () => reportMainPackageSize("x86_64-windows-msvc", artifact),
    /not measurable/u,
  );
  assert.throws(
    () => reportMainPackageSize("x86_64-windows-msvc", root),
    /not measurable/u,
  );
  assert.throws(
    () => reportMainPackageSize("unknown", artifact),
    /baseline: unknown/u,
  );
});

test("released baselines name a per-target version, artifact, digest, and size", () => {
  assert.equal(mainPackageSizePolicy(releasedPolicy), releasedPolicy);
  for (const target of ["x86_64-windows-msvc", "aarch64-windows-msvc"]) {
    const baseline = mainPackageSizeBaseline(releasedPolicy, target);
    assert.match(baseline.artifact, new RegExp(`-${baseline.version}-`, "u"));
  }
});

test("a malformed size policy fails immediately rather than reporting against a guess", () => {
  const baseline = {
    version: "0.2.11",
    artifact: "metawork-0.2.11-windows-x64.exe",
    sha256: "a".repeat(64),
    bytes: 9863352,
  };
  const policy = { schema: 2, targets: { "x86_64-windows-msvc": baseline } };
  assert.equal(mainPackageSizePolicy(policy), policy);
  for (const broken of [
    null,
    [],
    "{}",
    {},
    { schema: 2 },
    { schema: 1, targets: { "x86_64-windows-msvc": baseline } },
    { schema: 3, targets: { "x86_64-windows-msvc": baseline } },
    { schema: 2, targets: {} },
    { schema: 2, targets: [] },
    { schema: 2, targets: { "x86_64-windows-msvc": baseline }, extra: 1 },
    // The former upper-bound field must not survive as dead weight that a
    // reader could still mistake for a limit.
    {
      schema: 2,
      targets: {
        "x86_64-windows-msvc": { ...baseline, allowanceBytes: 1048576 },
      },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, bytes: 0 } },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, bytes: 9863352.5 } },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, bytes: "9863352" } },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, sha256: "abc" } },
    },
    {
      schema: 2,
      targets: {
        "x86_64-windows-msvc": { ...baseline, sha256: "A".repeat(64) },
      },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, version: "0.2" } },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, version: 0.2 } },
    },
    {
      schema: 2,
      targets: { "x86_64-windows-msvc": { ...baseline, artifact: "" } },
    },
    {
      schema: 2,
      targets: {
        "x86_64-windows-msvc": { ...baseline, artifact: "../installer.exe" },
      },
    },
    // One broken entry fails the document, so a release cannot record half a
    // policy and keep packaging the other architecture.
    {
      schema: 2,
      targets: {
        "x86_64-windows-msvc": baseline,
        "aarch64-windows-msvc": { ...baseline, bytes: -1 },
      },
    },
  ]) {
    assert.throws(
      () => mainPackageSizePolicy(broken),
      /Invalid main package size policy document|baseline/u,
      JSON.stringify(broken),
    );
  }
});

test("recording a baseline takes the measured artifact of the named release", (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), "metawork-package-record-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const artifact = path.join(root, "metawork-0.2.13-windows-x64.exe");
  writeFileSync(artifact, "installer");
  const recorded = recordedMainPackageSizePolicy(
    releasedPolicy,
    "x86_64-windows-msvc",
    artifact,
    "0.2.13",
  );
  assert.deepEqual(recorded.targets["x86_64-windows-msvc"], {
    version: "0.2.13",
    artifact: "metawork-0.2.13-windows-x64.exe",
    sha256: createHash("sha256").update("installer").digest("hex"),
    bytes: 9,
  });
  // Recording one target leaves the other release untouched, and the result is
  // still a valid policy document.
  assert.deepEqual(
    recorded.targets["aarch64-windows-msvc"],
    releasedPolicy.targets["aarch64-windows-msvc"],
  );
  assert.deepEqual(
    Object.keys(recorded.targets),
    Object.keys(releasedPolicy.targets),
  );
  assert.equal(mainPackageSizePolicy(recorded), recorded);
  assert.notEqual(
    releasedPolicy.targets["x86_64-windows-msvc"].version,
    "0.2.13",
  );

  for (const [targetId, artifactPath, version, message] of [
    ["x86_64-windows-msvc", artifact, "0.2.12", /not a 0\.2\.12 release/u],
    ["x86_64-windows-msvc", artifact, "0.2", /Invalid main package release/u],
    [
      "x86_64-windows-msvc",
      artifact,
      undefined,
      /Invalid main package release/u,
    ],
    ["unknown", artifact, "0.2.13", /baseline: unknown/u],
    [
      "x86_64-windows-msvc",
      path.join(root, "metawork-0.2.13-windows-x64.exe.missing"),
      "0.2.13",
      /ENOENT/u,
    ],
  ]) {
    assert.throws(
      () =>
        recordedMainPackageSizePolicy(
          releasedPolicy,
          targetId,
          artifactPath,
          version,
        ),
      message,
    );
  }
});

test("the release recorder entry takes exactly one target and one artifact", () => {
  assert.deepEqual(
    parseMainPackageSizeArguments([
      "--record-size",
      "x86_64-windows-msvc",
      "zig-out/package/metawork-0.2.13-windows-x64.exe",
    ]),
    {
      targetId: "x86_64-windows-msvc",
      artifactPath: "zig-out/package/metawork-0.2.13-windows-x64.exe",
    },
  );
  for (const args of [
    [],
    ["--record-size"],
    ["--record-size", "x86_64-windows-msvc"],
    ["--record-size", "x86_64-windows-msvc", "a.exe", "b.exe"],
    ["--record-size", "--x86_64-windows-msvc", "a.exe"],
    ["--record-size", "x86_64-windows-msvc", "--a.exe"],
    ["--record", "x86_64-windows-msvc", "a.exe"],
    ["x86_64-windows-msvc", "a.exe"],
  ]) {
    assert.throws(() => parseMainPackageSizeArguments(args), /usage:/u);
  }
});

test("the reported delta names the signed difference and the baseline release", () => {
  assert.equal(
    formatMainPackageSizeDelta({
      bytes: 9_900_000,
      baselineVersion: "0.2.11",
      baselineBytes: 9_863_352,
      deltaBytes: 36_648,
      deltaPercent: (36_648 / 9_863_352) * 100,
    }),
    "9900000 bytes, +36648 bytes (+0.37%) against the 0.2.11 baseline of 9863352 bytes",
  );
  assert.equal(
    formatMainPackageSizeDelta({
      bytes: 9_800_000,
      baselineVersion: "0.2.12",
      baselineBytes: 9_863_352,
      deltaBytes: -63_352,
      deltaPercent: (-63_352 / 9_863_352) * 100,
    }),
    "9800000 bytes, -63352 bytes (-0.64%) against the 0.2.12 baseline of 9863352 bytes",
  );
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
