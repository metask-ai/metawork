import assert from "node:assert/strict";
import { createServer } from "node:http";
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
  defaultAgentCoreTargetId,
  loadLockedAgentCoreManifest,
  readAgentCoreBundleTargetId,
  stagedAgentCoreBundleRoot,
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
    ? stagedAgentCoreBundleRoot(repositoryRoot, defaultAgentCoreTargetId())
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
let requestCount = 0;
let requestError;
const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    requestCount += 1;
    assert.equal(request.url, "/v1/chat/completions");
    const messages = JSON.stringify(payload.messages);
    assert.ok(messages.includes("checkpoint original conversation"));
    if (requestCount === 2) {
      assert.ok(messages.includes("checkpoint preserved answer"));
      assert.ok(messages.includes("checkpoint restored continuation"));
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(
      `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: "checkpoint preserved answer" }, finish_reason: null }] })}\n\n` +
        `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } })}\n\n` +
        "data: [DONE]\n\n",
    );
  } catch (error) {
    requestError = error;
    response.writeHead(500);
    response.end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}/v1/chat/completions`;
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
    .fingerprint = 0xcad095463de5d8dd,
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
    run.setEnvironmentVariable("RG_BIN", b.pathFromRoot("bundle/${bundle.manifest.runtime_assets[0].path}"));
    run.setEnvironmentVariable("METAWORK_RESTORE_PROBE_URL", "${baseUrl}");
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
  if (requestError) throw requestError;
  assert.equal(
    requestCount,
    2,
    "fresh and restored Run must both reach Provider",
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
}
