import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";
import { rendererWireBuildArguments } from "./generate-renderer-wire.mjs";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

// The ARM64 release packaging run on an x64 runner panicked in build.zig's
// configure phase with "cannot read AgentCore bundle manifest" before wire
// generation had started: the step was invoked without -Dtarget, so the build
// injected the host architecture and demanded an x86_64 bundle that a job
// staging only its own target never put there. Packaging for a target the host
// is not has to reach the generator with that target named.
test("wire generation names the target it is packaging for", () => {
  const cache = "/tmp/zig-global";
  const target = "aarch64-windows.win10...win11_dt-msvc";
  assert.deepEqual(rendererWireBuildArguments(cache, target), [
    "build",
    "generate-renderer-wire",
    "--global-cache-dir",
    cache,
    `-Dtarget=${target}`,
  ]);
});

// Callers that build for the host - the repository test runner's staleness
// check, the generator's own --check entry - name no target and keep build.zig's
// own host default, so this cannot change what they resolve.
test("host builds still pass no target at all", () => {
  const cache = "/tmp/zig-global";
  const args = rendererWireBuildArguments(cache, undefined);
  assert.deepEqual(args, [
    "build",
    "generate-renderer-wire",
    "--global-cache-dir",
    cache,
  ]);
  assert.ok(!args.some((argument) => argument.startsWith("-Dtarget")));
  assert.match(
    read("scripts/run-tests.mjs"),
    /generateRendererWire\(\{ check: true \}\)/u,
  );
});

// The break was a target dropped between two scripts that each had it, so the
// invariant is about every call site rather than the one that failed: a
// Renderer build is always started for a named target, and the generator
// forwards it instead of accepting and ignoring it.
test("every Renderer build names the target it was verified for", () => {
  const build = read("scripts/build.mjs");
  assert.match(build, /\{ outDir, signal, target \} = \{\}/u);
  assert.match(build, /generateRendererWire\(\{ signal, target \}\)/u);
  let callSites = 0;
  for (const name of readdirSync(new URL("scripts/", root))) {
    if (!name.endsWith(".mjs") || name.endsWith(".test.mjs")) continue;
    const source = read(`scripts/${name}`);
    for (const call of source.match(/await buildFrontend\([^;]*?\);/gsu) ??
      []) {
      assert.match(call, /target: bundle\.target/u, `${name}: ${call}`);
      callSites += 1;
    }
  }
  assert.equal(callSites, 4);
});

// The same canonical target the main build is given, taken from the verified
// bundle manifest: wire generation configures the build graph that the build
// right after it then compiles.
test("packaging passes one canonical target to both builds", () => {
  const windows = read("scripts/package-windows.mjs");
  assert.match(
    windows,
    /await buildFrontend\(repositoryRoot, \{ target: bundle\.target \}\);/u,
  );
  assert.match(windows, /`-Dtarget=\$\{bundle\.target\}`/u);
});
