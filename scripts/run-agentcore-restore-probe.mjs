import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import process from "node:process";
import {
  loadLockedAgentCoreManifest,
  readAgentCoreBundleTargetId,
  validateAgentCoreBundle,
} from "./agentcore-bundle.mjs";
import { runChild } from "./run-child-process.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const [mode] = process.argv.slice(2);
if (process.argv.length > 3 || (mode !== undefined && mode !== "--staged"))
  throw new Error(
    "usage: node scripts/run-agentcore-restore-probe.mjs [--staged]",
  );
const bundleRoot =
  mode === "--staged"
    ? path.join(repositoryRoot, ".agentcore", "bundle")
    : process.env.AGENTCORE_BUNDLE_ROOT;
if (!bundleRoot)
  throw new Error("AGENTCORE_BUNDLE_ROOT is required for the candidate probe");

const targetId = await readAgentCoreBundleTargetId(bundleRoot);
const lock = await loadLockedAgentCoreManifest(repositoryRoot, targetId);
const bundle = await validateAgentCoreBundle(bundleRoot, {
  expectedManifest: lock.manifest,
  expectedManifestBytes: lock.bytes,
});
console.log(
  `verified AgentCore ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`,
);

const scratch = await mkdtemp(
  path.join(tmpdir(), "metawork-agentcore-restore-probe-"),
);
try {
  const zigConsumerRoot = path.join(scratch, "zig-consumer");
  await mkdir(zigConsumerRoot);
  await symlink(
    bundle.root,
    path.join(zigConsumerRoot, "bundle"),
    process.platform === "win32" ? "junction" : "dir",
  );
  await writeFile(
    path.join(zigConsumerRoot, "build.zig.zon"),
    `.{
    .name = .agentcore_restore_probe,
    .fingerprint = 0x1c95480a301cfef9,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .agentcore = .{ .path = "bundle/bindings/zig" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "main.zig", "bundle" },
}
`,
  );
  await writeFile(
    path.join(zigConsumerRoot, "build.zig"),
    `const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agentcore = b.dependency("agentcore", .{
        .target = target,
        .optimize = optimize,
    }).module("metask_agentcore");
    const consumer = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    consumer.addImport("metask_agentcore", agentcore);
    const executable = b.addExecutable(.{
        .name = "metawork-agentcore-restore-probe",
        .root_module = consumer,
    });
    const run = b.addRunArtifact(executable);
    b.step("run", "Probe AgentCore checkpoint restore").dependOn(&run.step);
}
`,
  );
  await writeFile(
    path.join(zigConsumerRoot, "main.zig"),
    await readFile(
      path.join(
        repositoryRoot,
        "scripts",
        "probes",
        "agentcore-restore-probe.zig",
      ),
      "utf8",
    ),
  );
  await runChild(
    "zig",
    [
      "build",
      "--cache-dir",
      path.join(scratch, "sdk-cache"),
      "--prefix",
      path.join(scratch, "sdk-out"),
      "run",
      `-Dtarget=${bundle.target}`,
      "-Doptimize=Debug",
    ],
    {
      cwd: zigConsumerRoot,
      label: "isolated AgentCore restore probe",
    },
  );
  await validateAgentCoreBundle(bundle.root, {
    expectedManifest: lock.manifest,
    expectedManifestBytes: lock.bytes,
  });
} finally {
  await rm(scratch, { recursive: true, force: true });
}
