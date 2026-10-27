import assert from "node:assert/strict";
import test from "node:test";
import { parseBuildArguments, buildNative } from "./build.mjs";

test("ordinary debug and ReleaseFast builds do not imply an update channel", () => {
  for (const mode of ["debug", "release"]) {
    assert.equal(parseBuildArguments([mode]).automaticUpdateCheck, false);
    assert.equal(
      parseBuildArguments([mode, "aarch64-macos"]).automaticUpdateCheck,
      false,
    );
  }
  const distribution = parseBuildArguments([
    "release",
    "aarch64-macos",
    "--automatic-update-check",
  ]);
  assert.equal(distribution.automaticUpdateCheck, true);
  assert.equal(distribution.targetId, "aarch64-macos");
});

test("malformed or duplicate distribution switches fail rather than enabling implicit behavior", () => {
  for (const args of [
    [],
    ["debug", "--automatic-update-check"],
    ["release", "--automatic-update-check", "--automatic-update-check"],
    ["release", "--unknown"],
    ["release", "aarch64-macos", "x86_64-macos"],
  ]) {
    assert.throws(() => parseBuildArguments(args), /usage:/);
  }
});

test("automation cannot accidentally launch an official update-enabled build", async () => {
  await assert.rejects(
    buildNative(undefined, {
      target: "aarch64-macos.13.0",
      optimize: "Debug",
      automation: true,
      automaticUpdateCheck: true,
    }),
    /automation artifacts must not enable official update checks/,
  );
});
