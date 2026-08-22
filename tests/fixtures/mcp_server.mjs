import { createInterface } from "node:readline";
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const options = parseOptions(process.argv.slice(2));
if (options.transport === "stdio") startStdio();
else startHttp();

function startStdio() {
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on("line", (line) => {
    if (Buffer.byteLength(line, "utf8") > 1024 * 1024) process.exit(70);
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      process.exit(71);
    }
    trace({ transport: "stdio", direction: "request", message });
    void handle(message, (response) => {
      if (response === null) return;
      trace({ transport: "stdio", direction: "response", message: response });
      process.stdout.write(`${JSON.stringify(response)}\n`);
    });
  });
}

function startHttp() {
  let providerCalls = 0;
  const server = createServer((request, response) => {
    const chunks = [];
    let bytes = 0;
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes <= 1024 * 1024) chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        if (bytes > 1024 * 1024) throw new Error("request too large");
        if (request.method !== "POST") throw new Error("unexpected method");
        const body = Buffer.concat(chunks).toString("utf8");
        if (request.url === "/v1/messages") {
          const payload = JSON.parse(body);
          trace({
            transport: "provider",
            direction: "request",
            message: payload,
          });
          const mcpTools = payload.tools?.filter((tool) =>
            tool.name.startsWith("mcp__"),
          ) ?? [];
          const mcpTool = mcpTools[0];
          if (providerCalls === 0 && !mcpTool)
            throw new Error(
              "selected MCP tool was not offered to the provider",
            );
          if (providerCalls === 0 && mcpTools.length !== 1)
            throw new Error("provider received ambiguous MCP tool authority");
          const toolResult = payload.messages
            ?.flatMap((message) => message.content ?? [])
            .find((content) => content.type === "tool_result");
          if (
            providerCalls === 1 &&
            (!toolResult ||
              toolResult.is_error === true ||
              !toolResult.content?.includes("echo-from-agentcore"))
          )
            throw new Error(
              "successful MCP tool result did not return to provider",
            );
          const providerBody =
            providerCalls === 0
              ? providerToolSse("mcp-message-1", "mcp-call-1", mcpTool.name, {
                  text: "echo-from-agentcore",
                })
              : providerTextSse("mcp-message-2", "MCP execution complete");
          providerCalls += 1;
          response.writeHead(200, {
            "content-type": "text/event-stream",
            "cache-control": "no-cache",
            connection: "close",
          });
          response.end(providerBody);
          return;
        }
        if (request.url !== "/mcp") throw new Error("unexpected endpoint");
        if (request.headers["mcp-protocol-version"] !== options.protocolVersion)
          throw new Error("unexpected MCP protocol header");
        const message = JSON.parse(body);
        trace({ transport: "http", direction: "request", message });
        void handle(message, (rpcResponse) => {
          if (rpcResponse === null) {
            response.writeHead(202).end();
            return;
          }
          const json = JSON.stringify(rpcResponse);
          trace({
            transport: "http",
            direction: "response",
            message: rpcResponse,
          });
          if (options.framing === "sse") {
            response.writeHead(200, { "content-type": "text/event-stream" });
            response.end(
              `id: fixture-empty-event\ndata:\n\n` +
                `event: message\ndata: ${json}\n\n`,
            );
          } else {
            response.writeHead(200, { "content-type": "application/json" });
            response.end(json);
          }
        });
      } catch (error) {
        trace({ transport: "http", direction: "error", error: error.message });
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "invalid fixture request" }));
      }
    });
  });
  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    process.stdout.write(
      `${JSON.stringify({
        endpoint: `http://127.0.0.1:${address.port}/mcp`,
        providerEndpoint: `http://127.0.0.1:${address.port}/v1/messages`,
      })}\n`,
    );
  });
}

function providerToolSse(messageId, toolId, name, input) {
  return providerSse([
    {
      type: "message_start",
      message: {
        id: messageId,
        role: "assistant",
        model: "fixture",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "tool_use", id: toolId, name, input: {} },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "input_json_delta", partial_json: JSON.stringify(input) },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "tool_use" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  ]);
}

function providerTextSse(messageId, value) {
  return providerSse([
    {
      type: "message_start",
      message: {
        id: messageId,
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
      delta: { type: "text_delta", text: value },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  ]);
}

function providerSse(events) {
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
}

async function handle(message, send) {
  if (message?.jsonrpc !== "2.0" || typeof message.method !== "string")
    process.exit(72);
  if (message.method === "notifications/initialized") {
    if (Array.isArray(message.params)) process.exit(77);
    send(null);
    return;
  }
  if (!Object.hasOwn(message, "id")) process.exit(73);

  if (options.delayMs > 0)
    await new Promise((resolve) => setTimeout(resolve, options.delayMs));

  switch (message.method) {
    case "server/discover": {
      if (options.protocolVersion === "2025-06-18") {
        respondError(send, message.id, -32601, "method not found");
        return;
      }
      requireModernMetadata(message);
      respond(
        send,
        message.id,
        modernResult({
          supportedVersions: ["2026-07-28"],
          capabilities: { tools: {} },
          ...cacheHints(),
        }),
      );
      return;
    }
    case "initialize": {
      if (options.protocolVersion === "2026-07-28") process.exit(75);
      if (
        message.params?.protocolVersion !== options.protocolVersion &&
        !(
          options.protocolVersion === "2025-06-18" &&
          message.params?.protocolVersion === "2025-11-25"
        )
      )
        process.exit(74);
      respond(send, message.id, {
        protocolVersion: options.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "metawork-mcp-fixture", version: "1.0.0" },
      });
      return;
    }
    case "tools/list": {
      if (Array.isArray(message.params)) process.exit(77);
      if (options.protocolVersion === "2026-07-28")
        requireModernMetadata(message);
      if (options.invalidCatalog) {
        respond(
          send,
          message.id,
          result({
            ...cacheHints(),
            tools: [
              {
                name: "",
                description: "invalid empty tool identity",
                inputSchema: { type: "object" },
              },
            ],
          }),
        );
        return;
      }
      respond(
        send,
        message.id,
        result({
          ...cacheHints(),
          tools: [
            {
              name: "echo",
              description: "Return one bounded text value",
              inputSchema: {
                $schema: "http://json-schema.org/draft-07/schema#",
                type: "object",
                properties: { text: { type: "string", maxLength: 256 } },
                required: ["text"],
                additionalProperties: false,
              },
            },
          ],
        }),
      );
      return;
    }
    case "tools/call": {
      if (options.protocolVersion === "2026-07-28")
        requireModernMetadata(message);
      if (
        message.params?.name !== "echo" ||
        typeof message.params?.arguments?.text !== "string" ||
        Buffer.byteLength(message.params.arguments.text, "utf8") > 256
      ) {
        respondError(send, message.id, -32602, "invalid echo arguments");
        return;
      }
      respond(
        send,
        message.id,
        result({
          content: [{ type: "text", text: message.params.arguments.text }],
          isError: false,
        }),
      );
      return;
    }
    default:
      respondError(send, message.id, -32601, "method not found");
  }
}

function result(value) {
  return options.protocolVersion === "2026-07-28" ? modernResult(value) : value;
}

function cacheHints() {
  return options.protocolVersion === "2026-07-28"
    ? { ttlMs: 60_000, cacheScope: "private" }
    : {};
}

function modernResult(value) {
  return {
    ...value,
    resultType: "complete",
    _meta: {
      "io.modelcontextprotocol/serverInfo": {
        name: "metawork-mcp-fixture",
        version: "1.0.0",
      },
    },
  };
}

function requireModernMetadata(message) {
  const metadata = message.params?._meta;
  if (
    metadata?.["io.modelcontextprotocol/protocolVersion"] !== "2026-07-28" ||
    typeof metadata?.["io.modelcontextprotocol/clientCapabilities"] !== "object"
  )
    process.exit(76);
}

function respond(send, id, result) {
  const message = { jsonrpc: "2.0", id, result };
  send(message);
}

function respondError(send, id, code, message) {
  const response = { jsonrpc: "2.0", id, error: { code, message } };
  send(response);
}

function trace(event) {
  if (options.tracePath)
    appendFileSync(options.tracePath, `${JSON.stringify(event)}\n`, "utf8");
}

function parseOptions(args) {
  let protocolVersion = null;
  let delayMs = 0;
  let invalidCatalog = false;
  let tracePath = null;
  let transport = "stdio";
  let framing = "json";
  for (let index = 0; index < args.length; index += 1) {
    switch (args[index]) {
      case "--protocol":
        protocolVersion = args[(index += 1)] ?? null;
        break;
      case "--delay-ms":
        delayMs = Number(args[(index += 1)] ?? "");
        break;
      case "--invalid-catalog":
        invalidCatalog = true;
        break;
      case "--trace":
        tracePath = args[(index += 1)] ?? null;
        break;
      case "--transport":
        transport = args[(index += 1)] ?? null;
        break;
      case "--framing":
        framing = args[(index += 1)] ?? null;
        break;
      default:
        throw new Error(`unknown MCP fixture option: ${args[index]}`);
    }
  }
  if (
    !["2026-07-28", "2025-11-25", "2025-06-18"].includes(protocolVersion) ||
    !["stdio", "http"].includes(transport) ||
    !["json", "sse"].includes(framing) ||
    !Number.isSafeInteger(delayMs) ||
    delayMs < 0 ||
    delayMs > 10_000
  )
    throw new Error("invalid MCP fixture configuration");
  return {
    protocolVersion,
    delayMs,
    invalidCatalog,
    tracePath,
    transport,
    framing,
  };
}
