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
  throw new Error("usage: node scripts/run-agentcore-model-mutation-probe.mjs [--staged]");
const bundleRoot = mode === "--staged"
  ? path.join(repositoryRoot, ".agentcore", "bundle")
  : process.env.AGENTCORE_BUNDLE_ROOT;
if (!bundleRoot) throw new Error("AGENTCORE_BUNDLE_ROOT is required for the candidate probe");

const targetId = await readAgentCoreBundleTargetId(bundleRoot);
const lock = await loadLockedAgentCoreManifest(repositoryRoot, targetId);
const bundle = await validateAgentCoreBundle(bundleRoot, {
  expectedManifest: lock.manifest,
  expectedManifestBytes: lock.bytes,
});
if (process.platform !== "win32" || process.arch !== "x64")
  throw new Error("model mutation probe requires Windows x64");

const sse = (model) => [
  { type: "message_start", message: { id: "model-mutation-probe", role: "assistant", model, usage: { input_tokens: 1, output_tokens: 1 } } },
  { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
  { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "mutation probe complete" } },
  { type: "content_block_stop", index: 0 },
  { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } },
  { type: "message_stop" },
].map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");

let requestCount = 0;
const server = createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    try {
      if (request.method !== "POST" || request.url !== "/v1/messages")
        throw new Error(`unexpected provider route: ${request.method} ${request.url}`);
      if (request.headers.authorization !== "Bearer model-mutation-probe-key")
        throw new Error("probe credential did not reach AgentCore");
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (payload.model !== "model-b" && payload.model !== "model-a")
        throw new Error(`unexpected model ${payload.model}`);
      requestCount += 1;
      console.log(`provider_request count=${requestCount} model=${payload.model}`);
      const body = sse(payload.model);
      const send = () => {
        response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "close" });
        response.end(body);
      };
      if (requestCount === 2) setTimeout(send, 5000);
      else send();
    } catch (error) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: error.message }));
    }
  });
});

const scratch = await mkdtemp(path.join(tmpdir(), "metawork-agentcore-model-mutation-probe-"));
try {
  const address = await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}/v1/messages`));
  });
  const consumerRoot = path.join(scratch, "zig-consumer");
  await mkdir(consumerRoot);
  await symlink(bundle.root, path.join(consumerRoot, "bundle"), "junction");
  await writeFile(path.join(consumerRoot, "build.zig.zon"), `.{
    .name = .agentcore_model_mutation_probe,
    .fingerprint = 0xf1b0125305df8145,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{ .agentcore = .{ .path = "bundle/bindings/zig" } },
    .paths = .{ "build.zig", "build.zig.zon", "main.zig", "bundle" },
}
`);
  await writeFile(path.join(consumerRoot, "build.zig"), `const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agentcore = b.dependency("agentcore", .{ .target = target, .optimize = optimize }).module("metask_agentcore");
    const consumer = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    consumer.addImport("metask_agentcore", agentcore);
    const executable = b.addExecutable(.{ .name = "metawork-agentcore-model-mutation-probe", .root_module = consumer });
    const run = b.addRunArtifact(executable);
    b.step("run", "Probe AgentCore model mutation boundaries").dependOn(&run.step);
}
`);
  const source = await readFile(path.join(repositoryRoot, "scripts", "probes", "agentcore-model-mutation-probe.zig"), "utf8");
  await writeFile(path.join(consumerRoot, "main.zig"), source.replaceAll("__BASE_URL__", address));
  await runChild("zig", [
    "build", "--cache-dir", path.join(scratch, "sdk-cache"), "--prefix", path.join(scratch, "sdk-out"),
    "run", `-Dtarget=${bundle.target}`, "-Doptimize=Debug",
  ], { cwd: consumerRoot, label: "isolated AgentCore model mutation probe" });
  console.log(`AgentCore model mutation probe passed: ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`);
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
}
