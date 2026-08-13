import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
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

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [mode] = process.argv.slice(2);
if (process.argv.length > 3 || (mode !== undefined && mode !== "--staged"))
  throw new Error("usage: node scripts/run-agentcore-run-state-probe.mjs [--staged]");
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
if (
  !(
    (process.platform === "win32" && process.arch === "x64") ||
    (process.platform === "darwin" && process.arch === "arm64")
  )
)
  throw new Error("run_state probe requires Windows x64 or macOS arm64");

const sse = [
  {
    type: "message_start",
    message: {
      id: "run-state-probe-message",
      role: "assistant",
      model: "run-state-probe-model",
      usage: { input_tokens: 1, output_tokens: 1 },
    },
  },
  {
    type: "content_block_start",
    index: 0,
    content_block: { type: "text", text: "" },
  },
  {
    type: "content_block_delta",
    index: 0,
    delta: { type: "text_delta", text: "run state probe complete" },
  },
  { type: "content_block_stop", index: 0 },
  {
    type: "message_delta",
    delta: { stop_reason: "end_turn" },
    usage: { output_tokens: 1 },
  },
  { type: "message_stop" },
]
  .map((event) => `data: ${JSON.stringify(event)}\n\n`)
  .join("");

const server = createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    try {
      if (request.method !== "POST" || request.url !== "/v1/messages")
        throw new Error(`unexpected provider route: ${request.method} ${request.url}`);
      if (request.headers.authorization !== "Bearer run-state-probe-key")
        throw new Error("probe credential did not reach AgentCore");
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (payload.model !== "run-state-probe-model")
        throw new Error("probe model did not reach AgentCore");
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "close",
      });
      response.end(sse);
    } catch (error) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: error.message }));
    }
  });
});

const scratch = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-run-state-probe-"));
try {
  const address = await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const value = server.address();
      resolve(`http://127.0.0.1:${value.port}/v1/messages`);
    });
  });
  const zigConsumerRoot = path.join(scratch, "zig-consumer");
  await mkdir(zigConsumerRoot);
  await symlink(
    bundle.root,
    path.join(zigConsumerRoot, "bundle"),
    process.platform === "win32" ? "junction" : "dir",
  );
  await writeFile(
    path.join(zigConsumerRoot, "build.zig.zon"),
    `. {
    .name = .agentcore_run_state_probe,
    .fingerprint = 0x905e307731ff2c59,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{ .agentcore = .{ .path = "bundle/bindings/zig" } },
    .paths = .{ "build.zig", "build.zig.zon", "main.zig", "bundle" },
}
`.replace(". {", ".{"),
  );
  await writeFile(
    path.join(zigConsumerRoot, "build.zig"),
    `const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agentcore = b.dependency("agentcore", .{ .target = target, .optimize = optimize }).module("metask_agentcore");
    const consumer = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    consumer.addImport("metask_agentcore", agentcore);
    const executable = b.addExecutable(.{ .name = "metawork-agentcore-run-state-probe", .root_module = consumer });
    const run = b.addRunArtifact(executable);
    b.step("run", "Observe revision 8 run_state events").dependOn(&run.step);
}
`,
  );
  const source = await readFile(
    path.join(repositoryRoot, "scripts", "probes", "agentcore-run-state-probe.zig"),
    "utf8",
  );
  await writeFile(path.join(zigConsumerRoot, "main.zig"), source.replaceAll("__BASE_URL__", address));
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
    { cwd: zigConsumerRoot, label: "isolated AgentCore run_state probe" },
  );
  console.log(
    `AgentCore run_state probe passed: ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`,
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
}
