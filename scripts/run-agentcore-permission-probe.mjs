import { createServer } from "node:http";
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
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
    "usage: node scripts/run-agentcore-permission-probe.mjs [--staged]",
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
const supportedTargetIds =
  process.platform === "win32"
    ? process.arch === "arm64"
      ? ["aarch64-windows-gnu", "x86_64-windows-gnu"]
      : process.arch === "x64"
        ? ["x86_64-windows-gnu"]
        : []
    : process.platform === "darwin"
      ? process.arch === "arm64"
        ? ["aarch64-macos", "x86_64-macos"]
        : process.arch === "x64"
          ? ["x86_64-macos"]
          : []
      : [];
if (!supportedTargetIds.includes(targetId))
  throw new Error(
    `permission probe cannot execute ${bundle.target} on ${process.platform}/${process.arch}`,
  );

const scratch = await realpath(
  await mkdtemp(path.join(tmpdir(), "metawork-agentcore-permission-probe-")),
);
const workspace = path.join(scratch, "workspace");
const outside = await realpath(
  await mkdtemp(
    path.join(repositoryRoot, ".agentcore-permission-probe-outside-"),
  ),
);
await mkdir(path.join(workspace, ".git"), { recursive: true });
await writeFile(path.join(workspace, "edit-target.txt"), "before");

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function powershellQuote(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function createFileCommand(file) {
  if (process.platform === "win32")
    return `powershell -NoProfile -Command "Set-Content -LiteralPath ${powershellQuote(file)} -Value '' -NoNewline"`;
  return `touch ${shellQuote(file)}`;
}

const effects = {
  accept_inside_edit: [
    {
      tool: "Read",
      arguments: {
        file_path: path.join(workspace, "edit-target.txt"),
      },
    },
    {
      tool: "Edit",
      arguments: {
        file_path: path.join(workspace, "edit-target.txt"),
        old_string: "before",
        new_string: "after",
      },
    },
  ],
  accept_inside_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(workspace, "accept-inside.txt"),
      content: "accept-inside",
    },
  },
  accept_outside_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(outside, "accept-outside.txt"),
      content: "accept-outside",
    },
  },
  accept_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "accept-bash.txt")),
    },
  },
  full_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "full-bash.txt")),
    },
  },
  full_outside_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(outside, "full-outside-write.txt"),
      content: "full-outside-write",
    },
  },
  full_protected_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(workspace, ".git", "config"),
      content: "must-not-write",
    },
  },
  deny_full_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "deny-full-bash.txt")),
    },
  },
  ask_full_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "ask-full-bash.txt")),
    },
  },
  allow_accept_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "allow-accept-bash.txt")),
    },
  },
  ask_over_allow_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "ask-over-allow.txt")),
    },
  },
  deny_over_ask_allow_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(
        path.join(workspace, "deny-over-ask-allow.txt"),
      ),
    },
  },
  session_grant: {
    tool: "Write",
    arguments: {
      file_path: path.join(outside, "session-grant.txt"),
      content: "session-grant",
    },
  },
  unavailable_accept_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(outside, "unavailable.txt"),
      content: "unavailable",
    },
  },
  auto_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(workspace, "auto-write.txt"),
      content: "auto-write",
    },
  },
  auto_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "auto-bash.txt")),
    },
  },
  dont_ask_write: {
    tool: "Write",
    arguments: {
      file_path: path.join(workspace, "dont-ask-write.txt"),
      content: "dont-ask-write",
    },
  },
  dont_ask_bash: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "dont-ask-bash.txt")),
    },
  },
  shell_disabled: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "shell-disabled.txt")),
    },
  },
  sandbox_inside: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "sandbox-inside.txt")),
    },
  },
  sandbox_outside: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(outside, "sandbox-outside.txt")),
    },
  },
  unrestricted_outside: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(
        path.join(outside, "unrestricted-outside.txt"),
      ),
    },
  },
  restore_grant: {
    tool: "Write",
    arguments: {
      file_path: path.join(outside, "restore-grant.txt"),
      content: "restore-grant",
    },
  },
  restore_full_seed: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(path.join(workspace, "restore-full-seed.txt")),
    },
  },
  restore_full_after: {
    tool: "Bash",
    arguments: {
      command: createFileCommand(
        path.join(workspace, "restore-full-after.txt"),
      ),
    },
  },
  restore_full_to_accept_seed: {
    tool: "Write",
    arguments: {
      file_path: path.join(workspace, "restore-full-to-accept-seed.txt"),
      content: "seed",
    },
  },
  restore_accept_to_full_seed: {
    tool: "Write",
    arguments: {
      file_path: path.join(workspace, "restore-accept-to-full-seed.txt"),
      content: "seed",
    },
  },
};

function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((item) => item?.type === "text" && typeof item.text === "string")
    .map((item) => item.text)
    .join("\n");
}

function latestScenario(messages) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const text = textFromContent(messages[index]?.content);
    const match = /(?:^|\n)scenario:([a-z_]+)/.exec(text);
    if (match) return { name: match[1], messageIndex: index };
  }
  return null;
}

function toolResultCountAfter(messages, messageIndex) {
  return messages
    .slice(messageIndex + 1)
    .reduce(
      (count, message) =>
        count +
        (Array.isArray(message?.content)
          ? message.content.filter((item) => item?.type === "tool_result")
              .length
          : 0),
      0,
    );
}

function toolSse(scenario, callIndex, effect) {
  const id = `tu_${scenario}_${callIndex}`;
  return (
    `data: ${JSON.stringify({
      type: "message_start",
      message: {
        id: `msg_${scenario}_${callIndex}`,
        role: "assistant",
        model: "permission-probe",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    })}\n\n` +
    `data: ${JSON.stringify({
      type: "content_block_start",
      index: 0,
      content_block: { type: "tool_use", id, name: effect.tool, input: {} },
    })}\n\n` +
    `data: ${JSON.stringify({
      type: "content_block_delta",
      index: 0,
      delta: {
        type: "input_json_delta",
        partial_json: JSON.stringify(effect.arguments),
      },
    })}\n\n` +
    `data: ${JSON.stringify({ type: "content_block_stop", index: 0 })}\n\n` +
    `data: ${JSON.stringify({
      type: "message_delta",
      delta: { stop_reason: "tool_use" },
      usage: { output_tokens: 1 },
    })}\n\n` +
    `data: ${JSON.stringify({ type: "message_stop" })}\n\n`
  );
}

function finalSse(scenario) {
  return (
    `data: ${JSON.stringify({
      type: "message_start",
      message: {
        id: `final_${scenario}`,
        role: "assistant",
        model: "permission-probe",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    })}\n\n` +
    `data: ${JSON.stringify({
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    })}\n\n` +
    `data: ${JSON.stringify({
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: `done ${scenario}` },
    })}\n\n` +
    `data: ${JSON.stringify({ type: "content_block_stop", index: 0 })}\n\n` +
    `data: ${JSON.stringify({
      type: "message_delta",
      delta: { stop_reason: "end_turn" },
      usage: { output_tokens: 1 },
    })}\n\n` +
    `data: ${JSON.stringify({ type: "message_stop" })}\n\n`
  );
}

let requestCount = 0;
let requestError = null;
const server = createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    try {
      if (request.method !== "POST" || request.url !== "/v1/messages")
        throw new Error(
          `unexpected provider route: ${request.method} ${request.url}`,
        );
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const scenario = latestScenario(payload.messages ?? []);
      if (!scenario || !effects[scenario.name])
        throw new Error("provider request omitted a known scenario");
      requestCount += 1;
      const promptCount = (payload.messages ?? []).filter((message) =>
        textFromContent(message?.content).includes(`scenario:${scenario.name}`),
      ).length;
      const configured = effects[scenario.name];
      const sequence = Array.isArray(configured) ? configured : [configured];
      const completedEffects = toolResultCountAfter(
        payload.messages,
        scenario.messageIndex,
      );
      const body =
        completedEffects >= sequence.length
          ? finalSse(scenario.name)
          : toolSse(
              scenario.name,
              `${promptCount}_${completedEffects}`,
              sequence[completedEffects],
            );
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "close",
      });
      response.end(body);
    } catch (error) {
      requestError ??= error;
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: error.message }));
    }
  });
});

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

try {
  const serverRoot = await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () =>
      resolve(`http://127.0.0.1:${server.address().port}/v1/messages`),
    );
  });
  const consumerRoot = path.join(scratch, "zig-consumer");
  await mkdir(consumerRoot);
  await symlink(
    bundle.root,
    path.join(consumerRoot, "bundle"),
    process.platform === "win32" ? "junction" : "dir",
  );
  await writeFile(
    path.join(consumerRoot, "build.zig.zon"),
    `.{
    .name = .agentcore_permission_probe,
    .fingerprint = 0x8e4f_b76a_bef6_5d41,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{ .agentcore = .{ .path = "bundle/bindings/zig" } },
    .paths = .{ "build.zig", "build.zig.zon", "main.zig", "bundle" },
}
`,
  );
  await writeFile(
    path.join(consumerRoot, "build.zig"),
    `const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agentcore = b.dependency("agentcore", .{ .target = target, .optimize = optimize }).module("metask_agentcore");
    const consumer = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    consumer.addImport("metask_agentcore", agentcore);
    const executable = b.addExecutable(.{ .name = "metawork-agentcore-permission-probe", .root_module = consumer });
    const run = b.addRunArtifact(executable);
    run.setEnvironmentVariable("RG_BIN", b.pathFromRoot("bundle/${bundle.manifest.runtime_assets[0].path}"));
    b.step("run", "Probe AgentCore permission behavior").dependOn(&run.step);
}
`,
  );
  const source = await readFile(
    path.join(
      repositoryRoot,
      "scripts",
      "probes",
      "agentcore-permission-probe.zig",
    ),
    "utf8",
  );
  await writeFile(
    path.join(consumerRoot, "main.zig"),
    source
      .replaceAll("__BASE_URL__", JSON.stringify(serverRoot))
      .replaceAll("__WORKSPACE__", JSON.stringify(workspace)),
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
    { cwd: consumerRoot, label: "isolated AgentCore permission probe" },
  );
  if (requestError) throw requestError;
  const expectedRequestCount = process.platform === "win32" ? 53 : 57;
  if (requestCount !== expectedRequestCount)
    throw new Error(
      `permission probe observed ${requestCount} provider requests instead of ${expectedRequestCount}`,
    );

  const expectedPresent = [
    path.join(workspace, "accept-inside.txt"),
    path.join(outside, "accept-outside.txt"),
    path.join(workspace, "accept-bash.txt"),
    path.join(workspace, "full-bash.txt"),
    path.join(outside, "full-outside-write.txt"),
    ...(process.platform === "win32"
      ? [path.join(workspace, ".git", "config")]
      : []),
    path.join(workspace, "ask-full-bash.txt"),
    path.join(workspace, "allow-accept-bash.txt"),
    path.join(workspace, "ask-over-allow.txt"),
    path.join(outside, "session-grant.txt"),
    ...(process.platform === "win32"
      ? []
      : [path.join(workspace, "sandbox-inside.txt")]),
    path.join(outside, "unrestricted-outside.txt"),
    path.join(outside, "restore-grant.txt"),
    path.join(workspace, "restore-full-seed.txt"),
    path.join(workspace, "restore-full-after.txt"),
    path.join(workspace, "restore-full-to-accept-seed.txt"),
    path.join(workspace, "restore-accept-to-full-seed.txt"),
    path.join(workspace, "auto-write.txt"),
    path.join(workspace, "auto-bash.txt"),
  ];
  const expectedAbsent = [
    ...(process.platform === "win32"
      ? []
      : [path.join(workspace, ".git", "config")]),
    path.join(workspace, "deny-full-bash.txt"),
    path.join(outside, "unavailable.txt"),
    path.join(workspace, "shell-disabled.txt"),
    path.join(workspace, "deny-over-ask-allow.txt"),
    ...(process.platform === "win32"
      ? [path.join(workspace, "sandbox-inside.txt")]
      : []),
    path.join(outside, "sandbox-outside.txt"),
    path.join(workspace, "dont-ask-write.txt"),
    path.join(workspace, "dont-ask-bash.txt"),
  ];
  for (const file of expectedPresent) {
    if (!(await exists(file)))
      throw new Error(`expected effect missing: ${file}`);
  }
  for (const file of expectedAbsent) {
    if (await exists(file))
      throw new Error(`forbidden effect occurred: ${file}`);
  }
  const edited = await readFile(
    path.join(workspace, "edit-target.txt"),
    "utf8",
  );
  if (edited !== "after")
    throw new Error(
      `accept_edits did not apply the in-workspace Edit effect: ${JSON.stringify(edited)}`,
    );
  await validateAgentCoreBundle(bundle.root, {
    expectedManifest: lock.manifest,
    expectedManifestBytes: lock.bytes,
  });
  console.log(
    `AgentCore permission probe passed: ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}, provider_requests=${requestCount}`,
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
  await rm(outside, { recursive: true, force: true });
}
