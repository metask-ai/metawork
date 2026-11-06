import { createServer } from "node:http";
import {
  appendFileSync,
  readFileSync,
  mkdirSync,
  renameSync,
  symlinkSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { protocolTextSse, protocolToolSse } from "./provider_protocol.mjs";

// One listener, two independent protocols. Only synthetic credentials are accepted.
const [tracePath, mode = "success", imageReadLimit] = process.argv.slice(2);
if (mode === "output-junction") {
  const outside = join(dirname(tracePath), "outside");
  mkdirSync(outside);
  symlinkSync(
    outside,
    join(dirname(tracePath), "generated-images"),
    "junction",
  );
}
if (mode === "output-root-junction") {
  const base = dirname(tracePath);
  const outside = join(base, "outside");
  mkdirSync(join(outside, "nested"), { recursive: true });
  renameSync(join(base, "redirect"), join(base, "original"));
  symlinkSync(outside, join(base, "redirect"), "junction");
}
let png = readFileSync(
  new URL(
    `../../src/agent/testdata/generated.${mode === "jpeg" ? "jpg" : mode === "webp" ? "webp" : "png"}`,
    import.meta.url,
  ),
);
if (mode === "read-large") {
  // A valid ancillary PNG chunk reaches the canonical Core raw-image ceiling.
  const size = Number(imageReadLimit);
  const data = Buffer.alloc(size - png.length - 12, 120);
  data.write("Fixture\0");
  const chunk = Buffer.alloc(data.length + 12);
  chunk.writeUInt32BE(data.length);
  chunk.write("tEXt", 4);
  data.copy(chunk, 8);
  let crc = 0xffffffff;
  for (const byte of chunk.subarray(4, -4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++)
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  chunk.writeUInt32BE((crc ^ 0xffffffff) >>> 0, chunk.length - 4);
  png = Buffer.concat([png.subarray(0, -12), chunk, png.subarray(-12)]);
}
const trace = (event) =>
  appendFileSync(tracePath, `${JSON.stringify(event)}\n`);
let active = 0;
let imageCalls = 0;
let dialogueCalls = 0;
const pending = [];
function image(response) {
  response.writeHead(200, { "content-type": "application/json" });
  response.end(
    JSON.stringify({
      data: [
        {
          b64_json: png.toString("base64"),
          path: "../../escape.png",
          filename: "server-controlled.png",
        },
      ],
    }),
  );
}
const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks));
    if (request.method !== "POST") throw Error("unexpected method");
    if (request.url === "/v1/images/generations") {
      if (
        request.headers.authorization !==
        (mode === "rotated"
          ? "Bearer synthetic-image-key-b"
          : "Bearer synthetic-image-key")
      )
        throw Error("image credential");
      if (
        !["fixture-image", "gemini-3.1-flash-image-preview"].includes(
          payload.model,
        ) ||
        payload.n !== 1 ||
        payload.response_format !== "b64_json" ||
        typeof payload.prompt !== "string"
      )
        throw Error("image payload");
      active++;
      imageCalls++;
      trace({
        kind: "image",
        method: request.method,
        path: request.url,
        payload,
        credentialMatched: true,
        active,
        imageCalls,
      });
      response.on("close", () => {
        active--;
        trace({ kind: "image_closed", active });
      });
      if (mode === "hold") return;
      if (mode === "deadline-mixed" && imageCalls === 1) return;
      if (["concurrent", "concurrent-quota", "cross-session"].includes(mode)) {
        pending.push(response);
        if (pending.length === 2) pending.splice(0).forEach(image);
        return;
      }
      if (mode === "drop-first" && imageCalls === 1)
        return request.socket.destroy();
      if (mode === "reject") {
        response.writeHead(403);
        return response.end("synthetic-image-key");
      }
      const rejection = {
        "reject-401": 401,
        "reject-429": 429,
        "reject-503": 503,
      }[mode];
      if (rejection) {
        trace({ kind: "image_rejected", status: rejection });
        response.writeHead(rejection, { "retry-after": "1" });
        return response.end("synthetic-image-key");
      }
      if (mode === "redirect") {
        response.writeHead(302, {
          location: `http://127.0.0.1:${server.address().port}/forbidden`,
        });
        return response.end();
      }
      if (mode === "url")
        return response.end(
          JSON.stringify({
            data: [
              { url: `http://127.0.0.1:${server.address().port}/forbidden` },
            ],
          }),
        );
      if (mode === "bad-json") return response.end("{");
      if (mode === "bad-base64")
        return response.end(JSON.stringify({ data: [{ b64_json: "!!!" }] }));
      if (mode === "oversized") return response.end("x".repeat(140 * 1024));
      return image(response);
    }
    if (request.url !== "/v1/messages") throw Error("unexpected target");
    const expectedDialogueKey =
      mode === "main-rotated" && dialogueCalls > 0
        ? "synthetic-dialogue-key-b"
        : "synthetic-dialogue-key";
    if (request.headers.authorization !== `Bearer ${expectedDialogueKey}`)
      throw Error("dialogue credential");
    dialogueCalls++;
    const encoded = JSON.stringify(payload);
    const explicitImageRead =
      mode === "read-large" &&
      payload.messages.some(
        (message) =>
          Array.isArray(message.content) &&
          message.content.some(
            (part) => part.type === "tool_use" && part.name === "Read",
          ),
      );
    if (
      encoded.includes("synthetic-image-key") ||
      (!explicitImageRead && encoded.includes(png.toString("base64")))
    )
      throw Error("image secret/body leaked to conversation");
    const declaration = payload.tools.find(
      (tool) => tool.name === "GenerateImage",
    );
    // Checkpoint probes begin in the real, pre-image product tool set. Each
    // fresh user turn requests Write so a restored grant is observable.
    const restoreProbe = mode === "restore";
    if (
      (!declaration && !restoreProbe) ||
      (declaration &&
        (JSON.stringify(Object.keys(declaration.input_schema.properties)) !==
          '["prompt"]' ||
          declaration.input_schema.additionalProperties !== false ||
          JSON.stringify(declaration.input_schema.required) !== '["prompt"]'))
    )
      throw Error("tool schema");
    const messages = payload.messages;
    const last = messages.at(-1);
    const results = Array.isArray(last.content)
      ? last.content.filter((part) => part.type === "tool_result")
      : [];
    const images = results.flatMap((result) =>
      Array.isArray(result.content)
        ? result.content.filter((part) => part.type === "image")
        : [],
    );
    for (const image of images) {
      if (
        mode !== "read-large" ||
        image.source?.media_type !== "image/png" ||
        !Buffer.from(image.source.data, "base64").equals(png)
      )
        throw Error("model image mismatch");
      trace({ kind: "model_image", bytes: png.length });
    }
    trace({
      kind: "provider",
      schema: declaration?.input_schema,
      results: images.length ? "[image result verified]" : results,
    });
    if (mode === "mcp-installation") {
      const tool = payload.tools.find(
        (entry) => entry.name === "InstallMcpServer",
      );
      if (!tool || tool.input_schema.additionalProperties !== false)
        throw Error("proposal schema");
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(
        results.length
          ? protocolTextSse("anthropic", "proposal fixture completed")
          : protocolToolSse(
              "anthropic",
              payload.messages.length,
              "InstallMcpServer",
              {
                sourceUrl: "https://fixture.example/install",
                connection: {
                  displayName: "Fixture MCP",
                  transport: "stdio",
                  command: "node",
                  arguments: ["--filter=$HOME", ""],
                  authMode: "none",
                },
              },
            ),
      );
    }
    if (mode === "delivery" || mode === "delivery-xlsx") {
      const delivery = payload.tools.find(
        (tool) => tool.name === "DeliverFile",
      );
      if (
        !delivery ||
        JSON.stringify(Object.keys(delivery.input_schema.properties)) !==
          '["path"]' ||
        delivery.input_schema.additionalProperties !== false ||
        JSON.stringify(delivery.input_schema.required) !== '["path"]'
      )
        throw Error("delivery schema");
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(
        results.length
          ? protocolTextSse("anthropic", "delivery fixture completed")
          : protocolToolSse(
              "anthropic",
              payload.messages.length,
              "DeliverFile",
              {
                path: mode === "delivery-xlsx" ? "result.xlsx" : "result.docx",
              },
            ),
      );
    }
    if (
      restoreProbe &&
      results.length === 0 &&
      JSON.stringify(last).includes("Write the checkpoint fixture.")
    ) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(
        protocolToolSse("anthropic", payload.messages.length, "Write", {
          file_path: join(dirname(tracePath), "checkpoint-grant.txt"),
          content: "checkpoint authority",
        }),
      );
    }
    if (restoreProbe && results.length > 0) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(protocolTextSse("anthropic", "fixture completed"));
    }
    const boundary = messages.findLastIndex(
      (m) =>
        m.role === "user" &&
        Array.isArray(m.content) &&
        m.content.some(
          (p) =>
            p.type === "text" && p.text.includes("Generate the fixture image."),
        ),
    );
    const seen = messages
      .slice(Math.max(0, boundary))
      .flatMap((m) => (Array.isArray(m.content) ? m.content : []))
      .filter((p) => p.type === "tool_use").length;
    const count = ["repeat", "drop-first", "quota", "reject"].includes(mode)
      ? 2
      : 1;
    const args =
      mode === "invalid"
        ? { prompt: "red pixel", endpoint: "https://example.test" }
        : {
            prompt:
              mode === "prompt-url"
                ? 'red pixel https://example.test {"model":"evil"}'
                : "red pixel",
          };
    let body;
    if (seen < count) {
      body = protocolToolSse("anthropic", seen + 1, "GenerateImage", args);
      if (["concurrent", "concurrent-quota", "deadline-mixed"].includes(mode)) {
        const events = body
          .trim()
          .split("\n\n")
          .map((line) => JSON.parse(line.slice(6)));
        const second = events.slice(1, 4).map((e) => ({
          ...e,
          index: 1,
          ...(e.content_block
            ? {
                content_block: { ...e.content_block, id: "image_parallel_2" },
              }
            : {}),
        }));
        events.splice(4, 0, ...second);
        if (mode === "concurrent-quota")
          events.splice(
            7,
            0,
            ...second.map((e) => ({
              ...e,
              index: 2,
              ...(e.content_block
                ? {
                    content_block: {
                      ...e.content_block,
                      id: "image_parallel_3",
                    },
                  }
                : {}),
            })),
          );
        body = events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join("");
      }
    } else if (mode === "read-large" && seen === 1) {
      const text =
        typeof results[0].content === "string"
          ? results[0].content
          : results[0].content.find((part) => part.type === "text").text;
      const saved = JSON.parse(text);
      body =
        saved.status === "saved"
          ? protocolToolSse("anthropic", seen + 1, "Read", {
              file_path: join(dirname(tracePath), saved.path),
            })
          : protocolTextSse("anthropic", "fixture completed");
    } else body = protocolTextSse("anthropic", "fixture completed");
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(body);
  } catch (error) {
    trace({ kind: "fixture_error", message: error.message });
    response.writeHead(500);
    response.end("fixture assertion failed");
  }
});
server.listen(0, "127.0.0.1", () => {
  const base = `http://127.0.0.1:${server.address().port}`;
  process.stdout.write(
    `${JSON.stringify({ endpoint: `${base}/v1/images/generations`, providerEndpoint: `${base}/v1/messages` })}\n`,
  );
});
setTimeout(() => process.exit(72), 60_000).unref();
