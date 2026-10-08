import assert from "node:assert/strict";
import test from "node:test";
import {
  macosExecutableMinimumSystemVersion,
  macosExecutableSections,
  verifyMacosExecutableSections,
} from "./macos-executable-integrity.mjs";

function executable(padding = 16) {
  const bytes = Buffer.alloc(32 + 152 + padding + 32);
  bytes.writeUInt32LE(0xfeedfacf, 0);
  bytes.writeUInt32LE(1, 16);
  bytes.writeUInt32LE(152, 20);
  bytes.writeUInt32LE(0x19, 32);
  bytes.writeUInt32LE(152, 36);
  bytes.writeUInt32LE(1, 96);
  bytes.write("__text", 104);
  bytes.write("__TEXT", 120);
  bytes.writeBigUInt64LE(0x100001330n, 136);
  bytes.writeBigUInt64LE(32n, 144);
  bytes.writeUInt32LE(184 + padding, 152);
  bytes.fill(0x55, 184 + padding);
  return bytes;
}

function addSignatureCommand(bytes) {
  const signed = Buffer.concat([bytes, Buffer.alloc(16)]);
  signed.writeUInt32LE(2, 16);
  signed.writeUInt32LE(168, 20);
  signed.writeUInt32LE(0x1d, 184);
  signed.writeUInt32LE(16, 188);
  signed.writeUInt32LE(bytes.length, 192);
  signed.writeUInt32LE(16, 196);
  return signed;
}

function buildVersion(version = 13 << 16) {
  const bytes = Buffer.alloc(56);
  bytes.writeUInt32LE(0xfeedfacf, 0);
  bytes.writeUInt32LE(1, 16);
  bytes.writeUInt32LE(24, 20);
  bytes.writeUInt32LE(0x32, 32);
  bytes.writeUInt32LE(24, 36);
  bytes.writeUInt32LE(1, 40);
  bytes.writeUInt32LE(version, 44);
  return bytes;
}

test("minimum macOS declaration derives from the executable deployment target", () => {
  assert.equal(macosExecutableMinimumSystemVersion(buildVersion()), "13.0");
  assert.equal(
    macosExecutableMinimumSystemVersion(
      buildVersion((14 << 16) | (2 << 8) | 1),
    ),
    "14.2.1",
  );
});

test("missing, non-macOS or malformed deployment targets fail closed", () => {
  assert.throws(
    () => macosExecutableMinimumSystemVersion(executable()),
    /expected one LC_BUILD_VERSION/u,
  );
  const wrongPlatform = buildVersion();
  wrongPlatform.writeUInt32LE(2, 40);
  assert.throws(
    () => macosExecutableMinimumSystemVersion(wrongPlatform),
    /platform is not macOS/u,
  );
  const malformed = buildVersion();
  malformed.writeUInt32LE(1, 52);
  assert.throws(
    () => macosExecutableMinimumSystemVersion(malformed),
    /invalid LC_BUILD_VERSION size/u,
  );
});

test("signing may add load commands and signature without changing sections", () => {
  const unsigned = executable();
  verifyMacosExecutableSections(
    macosExecutableSections(unsigned),
    addSignatureCommand(unsigned),
  );
});

test("rejects the x64 signature command overwriting the first eight code bytes", () => {
  const unsigned = executable(8);
  const sections = macosExecutableSections(unsigned);
  assert.throws(
    () =>
      verifyMacosExecutableSections(sections, addSignatureCommand(unsigned)),
    /__TEXT,__text overlaps load commands/u,
  );
});

test("rejects modified code even when headers and signature are well formed", () => {
  const unsigned = executable();
  const signed = addSignatureCommand(unsigned);
  signed[200] = 0x90;
  assert.throws(
    () =>
      verifyMacosExecutableSections(macosExecutableSections(unsigned), signed),
    /changed executable sections/u,
  );
});

test("rejects malformed section bounds and truncated commands", () => {
  const bytes = executable();
  bytes.writeBigUInt64LE(0xffffffffffffffffn, 144);
  assert.throws(() => macosExecutableSections(bytes), /exceeds file size/u);
  assert.throws(
    () => macosExecutableSections(executable().subarray(0, 120)),
    /truncated load commands/u,
  );
});
