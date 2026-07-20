import { spawn } from "node:child_process";
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
import { validateAgentCoreBundle } from "./agentcore-bundle.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const [mode] = process.argv.slice(2);
if (process.argv.length > 3 || (mode !== undefined && mode !== "--staged"))
  throw new Error("usage: node scripts/run-agentcore-probe.mjs [--staged]");
const bundleRoot =
  mode === "--staged"
    ? path.join(repositoryRoot, ".agentcore", "bundle")
    : process.env.AGENTCORE_BUNDLE_ROOT;
if (!bundleRoot)
  throw new Error("AGENTCORE_BUNDLE_ROOT is required for the candidate probe");

const lockPath = path.join(
  repositoryRoot,
  "spikes",
  "agentcore-contract",
  "bundle.lock.json",
);
const lockBytes = await readFile(lockPath, "utf8");
const expectedManifest = JSON.parse(lockBytes);
const bundle = await validateAgentCoreBundle(bundleRoot, {
  expectedManifest,
  expectedManifestBytes: lockBytes,
});
console.log(
  `verified AgentCore ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`,
);

async function runZig(arguments_, cwd, label) {
  const child = spawn("zig", arguments_, {
    cwd,
    stdio: "inherit",
    detached: true,
  });
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    try {
      if (child.pid) process.kill(-child.pid, "SIGKILL");
    } catch {
      child.kill("SIGKILL");
    }
  }, 30_000);
  let exitCode;
  try {
    exitCode = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("exit", resolve);
    });
  } finally {
    clearTimeout(timeout);
  }
  if (timedOut) throw new Error(`${label} exceeded 30 seconds`);
  if (exitCode !== 0)
    throw new Error(`${label} failed with exit code ${exitCode}`);
}

const scratch = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-probe-"));
try {
  const zigConsumerRoot = path.join(scratch, "zig-consumer");
  await mkdir(zigConsumerRoot);
  await symlink(bundle.root, path.join(zigConsumerRoot, "bundle"), "dir");
  await writeFile(
    path.join(zigConsumerRoot, "build.zig.zon"),
    `.{
    .name = .agentcore_candidate_probe,
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
        .name = "metawork-agentcore-candidate-probe",
        .root_module = consumer,
    });
    const run = b.addRunArtifact(executable);
    b.step("run", "Discover AgentCore through its official Zig package").dependOn(&run.step);
}
`,
  );
  await writeFile(
    path.join(zigConsumerRoot, "main.zig"),
    `const agentcore = @import("metask_agentcore");

pub fn main() !void {
    _ = try agentcore.Api.discover();
}
`,
  );
  await runZig(
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
    zigConsumerRoot,
    "source-free AgentCore Zig package consumer",
  );
  await runZig(
    [
      "build",
      "--cache-dir",
      path.join(scratch, "raw-cache"),
      "--prefix",
      path.join(scratch, "raw-out"),
      "test",
      `-Dbundle-root=${bundle.root}`,
      `-Dtarget=${bundle.target}`,
      "-Doptimize=Debug",
    ],
    path.join(repositoryRoot, "spikes", "agentcore-contract"),
    "raw AgentCore C contract probe",
  );
  await validateAgentCoreBundle(bundle.root, {
    expectedManifest,
    expectedManifestBytes: lockBytes,
  });
} finally {
  await rm(scratch, { recursive: true, force: true });
}
