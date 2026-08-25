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
    "usage: node scripts/run-agentcore-provider-test.mjs [--staged]",
  );
const bundleRoot =
  mode === "--staged"
    ? stagedAgentCoreBundleRoot(repositoryRoot, defaultAgentCoreTargetId())
    : process.env.AGENTCORE_BUNDLE_ROOT;
if (!bundleRoot)
  throw new Error("AGENTCORE_BUNDLE_ROOT is required for the candidate bundle");

const targetId = await readAgentCoreBundleTargetId(bundleRoot);
const lock = await loadLockedAgentCoreManifest(repositoryRoot, targetId);
const bundle = await validateAgentCoreBundle(bundleRoot, {
  expectedManifest: lock.manifest,
  expectedManifestBytes: lock.bytes,
});

const providers = [
  {
    name: "openai",
    code: "wire.PROVIDER_OPENAI",
    apiKey: "openai-provider-test-key",
    model: "openai-provider-test-model",
    path: "/v1/chat/completions",
    baseUrlSuffix: "/v1/chat/completions",
    authorization: "Bearer openai-provider-test-key",
    bodyOk(payload) {
      return (
        payload.model === this.model &&
        Array.isArray(payload.messages) &&
        payload.messages.some(
          (message) =>
            message?.role === "user" &&
            message.content === "Reply with one short sentence.",
        )
      );
    },
    response: [
      { choices: [{ delta: { content: "openai provider test" } }] },
      { choices: [{ delta: {}, finish_reason: "stop" }] },
      "[DONE]",
    ],
  },
  {
    name: "gemini",
    code: "wire.PROVIDER_GEMINI",
    apiKey: "gemini-provider-test-key",
    model: "gemini-provider-test-model",
    path: "/v1beta/models/gemini-provider-test-model:streamGenerateContent?alt=sse",
    baseUrlSuffix: "",
    googleKey: "gemini-provider-test-key",
    bodyOk(payload) {
      return (
        Array.isArray(payload.contents) &&
        payload.contents.length === 1 &&
        payload.contents[0]?.role === "user" &&
        payload.contents[0]?.parts?.[0]?.text ===
          "Reply with one short sentence."
      );
    },
    response: [
      {
        candidates: [
          { content: { role: "model", parts: [{ text: "gemini " }] } },
        ],
      },
      {
        candidates: [
          {
            content: { role: "model", parts: [{ text: "provider test" }] },
            finishReason: "STOP",
          },
        ],
        usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 2 },
      },
    ],
  },
];

function sseFor(provider) {
  return provider.response
    .map((chunk) =>
      chunk === "[DONE]"
        ? "data: [DONE]\n\n"
        : `data: ${JSON.stringify(chunk)}\n\n`,
    )
    .join("");
}

let activeProvider = null;
let requestCount = 0;
let requestError = null;
const server = createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    try {
      if (!activeProvider) throw new Error("provider test is not active");
      const expectedPath = activeProvider.path;
      if (request.method !== "POST" || request.url !== expectedPath)
        throw new Error(
          `unexpected ${activeProvider.name} route: ${request.method} ${request.url}`,
        );
      if (activeProvider.googleKey) {
        if (request.headers["x-goog-api-key"] !== activeProvider.googleKey)
          throw new Error("Gemini API key did not reach AgentCore");
        if (request.headers.authorization !== undefined)
          throw new Error("Gemini request must not use Authorization");
      } else if (
        request.headers.authorization !== activeProvider.authorization
      ) {
        throw new Error(
          `${activeProvider.name} authorization did not reach AgentCore`,
        );
      }
      if (request.headers["content-type"] !== "application/json")
        throw new Error(
          `${activeProvider.name} request must use application/json`,
        );
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (!activeProvider.bodyOk(payload))
        throw new Error(
          `${activeProvider.name} request body was not serialized`,
        );
      requestCount += 1;
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "close",
      });
      response.end(sseFor(activeProvider));
    } catch (error) {
      requestError ??= error;
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: error.message }));
    }
  });
});

const scratch = await mkdtemp(
  path.join(tmpdir(), "metawork-agentcore-provider-test-"),
);
try {
  const serverRoot = await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () =>
      resolve(`http://127.0.0.1:${server.address().port}`),
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
    .name = .agentcore_provider_test,
    .fingerprint = 0x52ed_94bc_b822_003a,
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
    const executable = b.addExecutable(.{ .name = "metawork-agentcore-provider-test", .root_module = consumer });
    const run = b.addRunArtifact(executable);
    b.step("run", "Test AgentCore provider contracts").dependOn(&run.step);
}
`,
  );
  const source = await readFile(
    path.join(
      repositoryRoot,
      "scripts",
      "probes",
      "agentcore-provider-test.zig",
    ),
    "utf8",
  );
  const providerFailures = [];
  for (const provider of providers) {
    activeProvider = provider;
    requestCount = 0;
    requestError = null;
    const baseUrl = `${serverRoot}${provider.baseUrlSuffix}`;
    const main = source
      .replaceAll("__BASE_URL__", baseUrl)
      .replaceAll("__PROVIDER_CODE__", provider.code)
      .replaceAll("__API_KEY__", provider.apiKey)
      .replaceAll("__MODEL__", provider.model);
    await writeFile(path.join(consumerRoot, "main.zig"), main);
    try {
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
          cwd: consumerRoot,
          label: `AgentCore ${provider.name} provider test`,
        },
      );
    } catch (error) {
      providerFailures.push(new Error(`${provider.name}: ${error.message}`));
      continue;
    }
    if (requestError)
      providerFailures.push(
        new Error(`${provider.name}: ${requestError.message}`),
      );
    else if (requestCount !== 1)
      providerFailures.push(
        new Error(
          `${provider.name}: expected one request, got ${requestCount}`,
        ),
      );
    else console.log(`AgentCore ${provider.name} provider contract passed`);
  }
  if (providerFailures.length > 0)
    throw new AggregateError(
      providerFailures,
      `AgentCore provider contract failures: ${providerFailures.map(({ message }) => message).join("; ")}`,
    );
  console.log(
    `AgentCore provider contract tests passed (${providers.map(({ name }) => name).join(", ")}): ${bundle.manifest.version} ABI ${bundle.manifest.contract.binary_abi_version} revision ${bundle.manifest.contract.binary_abi_revision}`,
  );
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(scratch, { recursive: true, force: true });
}
