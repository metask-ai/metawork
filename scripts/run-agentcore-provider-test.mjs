import { createServer } from "node:http";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { crc32 } from "node:zlib";
import {
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
const [mode, hostFlag] = process.argv.slice(2);
const hostMode = hostFlag === "--host";
if (
  process.argv.length > 4 ||
  (mode !== undefined && mode !== "--staged") ||
  (hostFlag !== undefined && (!hostMode || mode !== "--staged"))
)
  throw new Error(
    "usage: node scripts/run-agentcore-provider-test.mjs [--staged [--host]]",
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
    name: "responses",
    code: "wire.PROVIDER_OPENAI",
    protocol: "wire.OPENAI_PROTOCOL_RESPONSES",
    apiKey: "responses-provider-test-key",
    model: "gpt-4o",
    path: "/v1/responses",
    baseUrlSuffix: "/v1/responses",
    authorization: "Bearer responses-provider-test-key",
    bodyOk(payload) {
      return (
        payload.model === this.model &&
        payload.input?.some(
          (message) =>
            message.role === "user" &&
            (message.content === "Reply with one short sentence." ||
              message.content?.some(
                (part) =>
                  part.type === "input_text" &&
                  part.text === "Reply with one short sentence.",
              )),
        )
      );
    },
    response: [
      {
        type: "response.created",
        response: { id: "resp_fixture", status: "in_progress" },
      },
      {
        type: "response.output_item.added",
        output_index: 0,
        item: {
          type: "message",
          id: "msg_fixture",
          role: "assistant",
          content: [],
        },
      },
      {
        type: "response.content_part.added",
        output_index: 0,
        content_index: 0,
        part: { type: "output_text", text: "", annotations: [] },
      },
      {
        type: "response.output_text.delta",
        output_index: 0,
        content_index: 0,
        delta: "responses provider test",
      },
      {
        type: "response.completed",
        response: {
          id: "resp_fixture",
          status: "completed",
          output: [
            {
              type: "message",
              id: "msg_fixture",
              role: "assistant",
              content: [
                {
                  type: "output_text",
                  text: "responses provider test",
                  annotations: [],
                },
              ],
            },
          ],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
        },
      },
    ],
  },
  {
    name: "anthropic",
    code: "wire.PROVIDER_ANTHROPIC",
    apiKey: "anthropic-provider-test-key",
    // Keep the wire protocol and model family independent: AgentCore must
    // admit known vision models even when they use an Anthropic-compatible
    // endpoint rather than a Claude model name.
    model: "gpt-5.6-sol",
    path: "/v1/messages",
    baseUrlSuffix: "/v1/messages",
    authorization: "Bearer anthropic-provider-test-key",
    anthropicVersion: "2023-06-01",
    bodyOk(payload) {
      return (
        payload.model === this.model &&
        Array.isArray(payload.messages) &&
        payload.messages.some(
          (message) =>
            message?.role === "user" &&
            (message.content === "Reply with one short sentence." ||
              message.content?.some?.(
                (content) =>
                  content?.type === "text" &&
                  content.text === "Reply with one short sentence.",
              )),
        )
      );
    },
    response: [
      {
        type: "message_start",
        message: {
          id: "anthropic-provider-test-message",
          role: "assistant",
          model: "fixture",
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
        delta: { type: "text_delta", text: "anthropic provider test" },
      },
      { type: "content_block_stop", index: 0 },
      {
        type: "message_delta",
        delta: { stop_reason: "end_turn" },
        usage: { output_tokens: 1 },
      },
      { type: "message_stop" },
    ],
  },
  {
    name: "openai",
    code: "wire.PROVIDER_OPENAI",
    apiKey: "openai-provider-test-key",
    model: "gpt-4o",
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
    model: "gemini-2.5-flash",
    path: "/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
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

// These are transport fixtures, not a test of a remote model's visual reasoning.
const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
const gif = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
// A valid PNG with a large ancillary text chunk exercises checkpoint string
// limits without a large pixel allocation or a checked-in binary fixture.
const pngBytes = Buffer.from(png, "base64");
const ancillary = Buffer.concat([
  Buffer.from("Comment\0"),
  Buffer.alloc(800 * 1024, 65),
]);
const ancillaryHeader = Buffer.alloc(8);
ancillaryHeader.writeUInt32BE(ancillary.length);
ancillaryHeader.write("tEXt", 4);
const ancillaryCrc = Buffer.alloc(4);
ancillaryCrc.writeUInt32BE(
  crc32(Buffer.concat([ancillaryHeader.subarray(4), ancillary])),
);
const largePng = Buffer.concat([
  pngBytes.subarray(0, -12),
  ancillaryHeader,
  ancillary,
  ancillaryCrc,
  pngBytes.subarray(-12),
]).toString("base64");
function mediaIdentity(mime, data) {
  return {
    mime,
    bytes: data.length,
    sha256: createHash("sha256").update(data).digest("hex"),
  };
}
function userParts(provider, payload) {
  const messages = payload.input ?? payload.messages ?? payload.contents;
  return messages
    .filter((message) => message.role === "user")
    .map((message) => {
      const parts = message.content ?? message.parts;
      if (typeof parts === "string") return [{ text: parts }];
      return parts.map((part) => {
        if (typeof part.text === "string") return { text: part.text };
        if (part.type === "image")
          return mediaIdentity(part.source.media_type, part.source.data);
        if (part.type === "image_url" || part.type === "input_image") {
          const url =
            typeof part.image_url === "string"
              ? part.image_url
              : part.image_url.url;
          const match = /^data:([^;]+);base64,(.+)$/.exec(url);
          assert.ok(match, `${provider.name}: expected inline image`);
          return mediaIdentity(match[1], match[2]);
        }
        const inline = part.inlineData ?? part.inline_data;
        assert.ok(inline, `${provider.name}: unexpected content part`);
        return mediaIdentity(inline.mimeType ?? inline.mime_type, inline.data);
      });
    });
}

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
      if (
        activeProvider.anthropicVersion &&
        request.headers["anthropic-version"] !== activeProvider.anthropicVersion
      )
        throw new Error("Anthropic protocol version did not reach AgentCore");
      if (request.headers["content-type"] !== "application/json")
        throw new Error(
          `${activeProvider.name} request must use application/json`,
        );
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (requestCount === 0 && !activeProvider.bodyOk(payload))
        throw new Error(
          `${activeProvider.name} request body was not serialized`,
        );
      if (requestCount > 0) {
        const users = userParts(activeProvider, payload);
        const expectedUsers = [
          [{ text: "Reply with one short sentence." }],
          [
            { text: "First image." },
            mediaIdentity("image/png", png),
            { text: "Second image." },
            mediaIdentity("image/gif", gif),
          ],
          [{ text: "Continue with the images." }],
          [mediaIdentity("image/png", largePng)],
          [{ text: "Continue after restore." }],
          [{ text: "Continue after rejection." }],
        ];
        for (let index = 1; index < users.length; index += 1)
          assert.deepEqual(users[index], expectedUsers[index]);
        assert.equal(
          users.length,
          requestCount + 1,
          "rejected input must not enter history",
        );
      }
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

const scratch = await realpath(
  await mkdtemp(path.join(tmpdir(), "metawork-agentcore-provider-test-")),
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
  if (hostMode) {
    await writeFile(
      path.join(consumerRoot, "image.png"),
      Buffer.from(png, "base64"),
    );
    await writeFile(
      path.join(consumerRoot, "image.gif"),
      Buffer.from(gif, "base64"),
    );
    await writeFile(
      path.join(consumerRoot, "large.png"),
      Buffer.from(largePng, "base64"),
    );
  }
  if (!hostMode) {
    await writeFile(path.join(consumerRoot, "image.b64"), largePng);
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
    run.setEnvironmentVariable("RG_BIN", b.pathFromRoot("bundle/${bundle.manifest.runtime_assets[0].path}"));
    b.step("run", "Test AgentCore provider contracts").dependOn(&run.step);
}
`,
    );
  }
  const source = hostMode
    ? null
    : await readFile(
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
    if (source !== null) {
      const main = source
        .replaceAll("__BASE_URL__", baseUrl)
        .replaceAll("__PROVIDER_CODE__", provider.code)
        .replaceAll(
          "__PROTOCOL_CODE__",
          provider.protocol ?? "wire.PROTOCOL_DEFAULT",
        )
        .replaceAll("__PNG__", png)
        .replaceAll("__GIF__", gif)
        .replaceAll(
          "__EXPECT_UNKNOWN_IMAGE_REJECTION__",
          String(provider.name !== "gemini"),
        )
        .replaceAll("__API_KEY__", provider.apiKey)
        .replaceAll("__MODEL__", provider.model);
      await writeFile(path.join(consumerRoot, "main.zig"), main);
    }
    try {
      if (hostMode) {
        await runChild(
          "zig",
          [
            "build",
            "test-agent-multimodal",
            `-Dtarget=${bundle.target}`,
            "--",
            provider.name,
            baseUrl,
            provider.apiKey,
            provider.model,
            consumerRoot,
          ],
          {
            cwd: repositoryRoot,
            label: `Agent Host ${provider.name} multimodal acceptance`,
          },
        );
      } else {
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
      }
    } catch (error) {
      providerFailures.push(
        new Error(
          `${provider.name}: ${requestError?.message ?? error.message}`,
        ),
      );
      continue;
    }
    if (requestError)
      providerFailures.push(
        new Error(`${provider.name}: ${requestError.message}`),
      );
    else if (requestCount !== 6)
      providerFailures.push(
        new Error(`${provider.name}: expected 6 requests, got ${requestCount}`),
      );
    else
      console.log(
        `${hostMode ? "Agent Host" : "AgentCore"} ${provider.name} provider contract passed`,
      );
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
