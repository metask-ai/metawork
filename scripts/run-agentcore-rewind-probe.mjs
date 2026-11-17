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
//
// The compaction phase pushes megabytes of filler through here, so only the
// first few requests are kept whole. The rest keep a digest: the turn
// markers present, which is all the later assertions read.
const requests = [];
const retain_whole = 3;
const answers = ["alpha answer", "beta answer", "gamma answer"];
let requestError;
const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString("utf8");
    const payload = JSON.parse(body);
    assert.equal(request.url, "/v1/chat/completions");
    requests.push({
      messages: requests.length < retain_whole ? payload.messages : null,
      roles: payload.messages.map((message) => message.role),
      markers: [...new Set(body.match(/drift-marker-\d{3}/g) ?? [])].sort(),
      bytes: body.length,
    });
    // A short reply throughout: the filler that has to reach the model's
    // context window is the Host's own input, which the probe controls, so
    // the summarization reply stays small enough for a compact to shrink
    // anything.
    const answer =
      answers[requests.length - 1] ?? `fill reply ${requests.length}`;
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
    run.setEnvironmentVariable("METAWORK_REWIND_PROBE_REPORT", "report.json");
    run.setCwd(b.path("."));
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
    // The compaction phase pushes a Conversation up to the model's context
    // window one large Run at a time, so this has no useful upper bound -
    // unbounded like the compilation it shares the invocation with.
    {
      cwd: zigConsumerRoot,
      label: "isolated AgentCore rewind probe",
      timeoutMs: null,
    },
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
  for (const [index, request] of requests.entries())
    console.log(
      `rewind-probe provider request ${index + 1}: ${
        request.messages
          ? JSON.stringify(request.messages.map(identify))
          : JSON.stringify({
              roles: request.roles,
              markers: request.markers,
              bytes: request.bytes,
            })
      }`,
    );

  assert.ok(
    requests.length >= 3,
    "two fresh Runs and one post-restore Run must reach Provider",
  );
  const [first, second, third] = requests
    .slice(0, retain_whole)
    .map((request) => JSON.stringify(request.messages));
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

  const report = JSON.parse(
    await readFile(path.join(zigConsumerRoot, "report.json"), "utf8"),
  );
  console.log(`rewind-probe report: ${JSON.stringify(report, null, 2)}`);
  assert.equal(report.rewind_slot_non_null, true);
  assert.equal(report.count_after_first_turn + 1, report.rewound_position);
  assert.equal(report.count_after_rewind, report.rewound_position - 1);
  assert.equal(report.checkpoint_remembers_rewind, true);

  const { compaction } = report;
  assert.equal(
    compaction.engaged,
    true,
    `the canonical compact policy never acted: outcome_code ${compaction.outcome_code} at ${compaction.before_context_tokens} context tokens after ${compaction.turns} turns`,
  );
  // The premise the whole "record a position once, never recompute it"
  // design rests on. Unchanged message_count across a compact means the
  // compacted prefix is still counted and nothing was renumbered.
  assert.equal(
    compaction.count_after,
    compaction.count_before,
    "a compact that changed message_count would move every recorded position",
  );
  assert.ok(compaction.boundary_after > 0, "a compact must leave a boundary");
  // Measured precedence under the boundary: a user position reports 33, an
  // assistant position reports 32. Both were refused and changed nothing.
  assert.ok(
    compaction.compacted_user_position > 0,
    "a user position under the boundary must have been probed for code 33",
  );
  assert.equal(
    compaction.position_rewound,
    true,
    "a position recorded before the compact must still be rewindable after it",
  );
  assert.equal(compaction.probed_position_status, "ok");
  assert.equal(
    compaction.count_after_probed_rewind,
    compaction.probed_position - 1,
    "the rewind must land exactly below the recorded position",
  );
  // Behavioural half: the turn that position named is the turn that went,
  // and only it. The turn before it has to still be there, or the rewind
  // landed somewhere else entirely.
  const tail = requests.at(-1);
  const predecessor = `drift-marker-${String(compaction.turns - 1).padStart(3, "0")}`;
  assert.ok(
    !tail.markers.includes(compaction.probed_marker),
    `the Conversation after the rewind still carries ${compaction.probed_marker}`,
  );
  assert.ok(
    tail.markers.includes(predecessor),
    `the rewind went past its position: ${predecessor} is gone too (kept: ${tail.markers.join(", ")})`,
  );
  console.log(
    `rewind-probe compaction evidence: position ${compaction.probed_position} named the same message before and after a compact that set boundary ${compaction.boundary_after}; ${compaction.probed_marker} is gone from the rerun`,
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
}
