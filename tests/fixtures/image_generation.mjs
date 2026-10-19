import { createServer } from "node:http";
import { appendFileSync, readFileSync } from "node:fs";
import { protocolTextSse, protocolToolSse } from "./provider_protocol.mjs";

// One listener, two independent protocols. Only synthetic credentials are accepted.
const [tracePath, mode = "success"] = process.argv.slice(2);
const png = readFileSync(
  new URL("../../src/agent/testdata/generated.png", import.meta.url),
);
const trace = (event) =>
  appendFileSync(tracePath, `${JSON.stringify(event)}\n`);
let active = 0;
let imageCalls = 0;
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
      if (request.headers.authorization !== "Bearer synthetic-image-key")
        throw Error("image credential");
      if (
        payload.model !== "fixture-image" ||
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
    const encoded = JSON.stringify(payload);
    if (
      encoded.includes("synthetic-image-key") ||
      encoded.includes(png.toString("base64"))
    )
      throw Error("image secret/body leaked to conversation");
    const declaration = payload.tools.find(
      (tool) => tool.name === "GenerateImage",
    );
    if (
      !declaration ||
      JSON.stringify(Object.keys(declaration.input_schema.properties)) !==
        '["prompt"]' ||
      declaration.input_schema.additionalProperties !== false ||
      JSON.stringify(declaration.input_schema.required) !== '["prompt"]'
    )
      throw Error("tool schema");
    const messages = payload.messages;
    const last = messages.at(-1);
    const results = Array.isArray(last.content)
      ? last.content.filter((part) => part.type === "tool_result")
      : [];
    trace({ kind: "provider", schema: declaration.input_schema, results });
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
        const second = events
          .slice(1, 4)
          .map((e) => ({
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
