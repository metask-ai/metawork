// A local Anthropic Messages provider for the user-instruction integration
// test. It records what each request carried -- the system content and the
// latest user text -- and answers every request with one short reply, so the
// test reads from the trace what canonical Core actually sent.
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
import { protocolTextSse, protocolToolSse } from "./provider_protocol.mjs";

const [tracePath, globalPath] = process.argv.slice(2);
const trace = (value) =>
  appendFileSync(tracePath, JSON.stringify(value) + "\n");

function systemText(payload) {
  const system = payload.system ?? [];
  return typeof system === "string"
    ? system
    : system.map((part) => part.text ?? "").join("\n");
}

function latestUserText(payload) {
  const users = (payload.messages ?? []).filter(
    (message) => message.role === "user",
  );
  const content = users.at(-1)?.content ?? [];
  return typeof content === "string"
    ? content
    : content.map((part) => part.text ?? "").join("\n");
}

function probeName(payload) {
  for (const message of [...payload.messages].reverse()) {
    if (message.role !== "user") continue;
    const text =
      typeof message.content === "string"
        ? message.content
        : message.content.map((part) => part.text ?? "").join("\n");
    if (text)
      return /Instructions boundary probe (Write|Edit|Bash)\./.exec(text)?.[1];
  }
}

const server = createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    try {
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const user = latestUserText(payload);
      trace({
        kind: "request",
        system: systemText(payload),
        user,
      });
      response.writeHead(200, { "content-type": "text/event-stream" });
      const operation = probeName(payload);
      if (!operation) {
        response.end(protocolTextSse("anthropic", "Done."));
        return;
      }
      const previousTool = payload.messages
        .at(-2)
        ?.content?.find?.((entry) => entry.type === "tool_use")?.name;
      if (!user && previousTool !== "Read") {
        response.end(protocolTextSse("anthropic", "Done."));
        return;
      }
      if (user && operation !== "Bash") {
        response.end(
          protocolToolSse("anthropic", payload.messages.length, "Read", {
            file_path: globalPath,
          }),
        );
        return;
      }
      const quote =
        process.platform === "win32"
          ? (text) => "'" + text.replaceAll("'", "''") + "'"
          : (text) => "'" + text.replaceAll("'", "'\\''") + "'";
      const instructions = {
        Write: { file_path: globalPath, content: "ordinary Write" },
        Edit: {
          file_path: globalPath,
          old_string: "initial",
          new_string: "ordinary Edit",
        },
        Bash: {
          command:
            process.platform === "win32"
              ? `Set-Content -LiteralPath ${quote(globalPath)} -Value 'ordinary Bash' -NoNewline`
              : `printf %s 'ordinary Bash' > ${quote(globalPath)}`,
        },
      };
      response.end(
        protocolToolSse(
          "anthropic",
          payload.messages.length,
          operation,
          instructions[operation],
        ),
      );
    } catch (error) {
      trace({ kind: "fixture_error", type: error.name, reason: error.message });
      // A broken fixture must fail the test, rather than trigger retries.
      response.writeHead(400, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          type: "error",
          error: {
            type: "invalid_request_error",
            message: "Instructions fixture failed",
          },
        }),
      );
    }
  });
});
// A test panic must not leave an orphan holding the Zig runner's stderr pipe.
process.stdin.resume();
process.stdin.on("end", () => {
  server.closeAllConnections();
  server.close(() => process.exit(0));
});
server.listen(0, "127.0.0.1", () =>
  process.stdout.write(
    JSON.stringify({
      endpoint: `http://127.0.0.1:${server.address().port}/v1/messages`,
    }) + "\n",
  ),
);
