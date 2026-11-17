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
    "usage: node scripts/run-agentcore-rewind-probe.mjs [--staged]",
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
  path.join(tmpdir(), "metawork-agentcore-rewind-probe-"),
);

// The Conversation the Provider is handed is the only evidence of what a
// rewound-then-restored Session would actually rerun; the describe counter
// alone could not tell a dropped turn from a renumbered one.
const requests = [];
const answers = [
  "alpha answer",
  "beta answer",
  "gamma answer",
  "compact summary",
];
let requestError;
const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    assert.equal(request.url, "/v1/chat/completions");
    requests.push(payload.messages);
    const answer = answers[requests.length - 1] ?? "unexpected extra answer";
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(
      `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: answer }, finish_reason: null }] })}\n\n` +
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
    .name = .agentcore_rewind_probe,
    .fingerprint = 0x8ab09fdcce7996d2,
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
        .name = "metawork-agentcore-rewind-probe",
        .root_module = consumer,
    });
    const run = b.addRunArtifact(executable);
    run.setEnvironmentVariable("RG_BIN", b.pathFromRoot("bundle/${bundle.manifest.runtime_assets[0].path}"));
    run.setEnvironmentVariable("METAWORK_REWIND_PROBE_URL", "${baseUrl}");
    b.step("run", "Probe AgentCore rewind_to_user_message").dependOn(&run.step);
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
        "agentcore-rewind-probe.zig",
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
    { cwd: zigConsumerRoot, label: "isolated AgentCore rewind probe" },
  );
  await validateAgentCoreBundle(bundle.root, {
    expectedManifest: lock.manifest,
    expectedManifestBytes: lock.bytes,
  });
  if (requestError) throw requestError;

  // Core wraps a user message in the Host context block, so the text that
  // identifies the turn sits at the end. Report that tail: a head-only
  // excerpt makes every user message look alike and hides the evidence.
  const identify = (message) => {
    const content = String(
      typeof message.content === "string"
        ? message.content
        : JSON.stringify(message.content),
    );
    const tail = content.slice(-72).replaceAll("\n", " ");
    return { role: message.role, tail, bytes: content.length };
  };
  for (const [index, messages] of requests.entries())
    console.log(
      `rewind-probe provider request ${index + 1}: ${JSON.stringify(messages.map(identify))}`,
    );

  assert.ok(
    requests.length >= 3,
    "two fresh Runs and one post-restore Run must reach Provider",
  );
  const [first, second, third] = requests.map((messages) =>
    JSON.stringify(messages),
  );
  assert.ok(first.includes("rewind alpha question"));
  assert.ok(!first.includes("rewind beta question"));
  assert.ok(second.includes("rewind alpha question"));
  assert.ok(second.includes("alpha answer"));
  assert.ok(second.includes("rewind beta question"));
  // The behavioral answer. A checkpoint that had carried the pre-rewind
  // Conversation would put the dropped turn back in front of the model here.
  assert.ok(
    third.includes("rewind alpha question"),
    "restored Run keeps the context before",
  );
  assert.ok(
    third.includes("alpha answer"),
    "restored Run keeps the reply before",
  );
  assert.ok(
    third.includes("rewind gamma question"),
    "restored Run carries its own input",
  );
  assert.ok(
    !third.includes("rewind beta question"),
    "restored Run must not resurrect the dropped user message",
  );
  assert.ok(
    !third.includes("beta answer"),
    "restored Run must not resurrect the dropped reply",
  );
  console.log(
    "rewind-probe provider evidence: the restored Run reran without the dropped turn",
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
}
