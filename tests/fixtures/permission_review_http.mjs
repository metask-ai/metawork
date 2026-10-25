import { createServer } from "node:http";

// Synthetic requests only. No model service, credentials or proposed tools run.
const state = { calls: 0, active: 0, cancelled: 0 };
const server = createServer(async (request, response) => {
  if (request.url === "/state") {
    response.end(JSON.stringify(state));
    return;
  }
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks));
    if (
      request.url !== "/v1/messages" ||
      request.method !== "POST" ||
      request.headers["x-api-key"] !== "synthetic-review-key" ||
      body.model !== "fixture-review" ||
      body.max_tokens !== 2048 ||
      body.tools !== undefined
    ) throw Error("unexpected request");
    const mode = JSON.parse(body.messages[0].content).evidence.user_intent;
    state.calls++;
    state.active++;
    response.once("close", () => {
      state.active--;
      if (mode === "hold") state.cancelled++;
    });
    if (mode === "hold") return;
    if (mode === "reject-503") {
      response.writeHead(503, { "content-type": "application/json" });
      response.end('{"error":{"type":"overloaded_error"}}');
      return;
    }
    const text = '{"decision":"allow_once","reason":"synthetic local request"}';
    const content = mode === "split-json"
      ? [{ type: "text", text: text.slice(0, 17) }, { type: "text", text: text.slice(17) }]
      : [{ type: "text", text: mode === "invalid-json" ? text.slice(0, -1) : text }];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      type: "message", content, stop_reason: "end_turn",
      usage: { input_tokens: 3, output_tokens: 8 },
    }));
  } catch {
    response.writeHead(400);
    response.end();
  }
});
server.listen(0, "127.0.0.1", () => {
  const base = `http://127.0.0.1:${server.address().port}`;
  process.stdout.write(`${JSON.stringify({ base })}\n`);
});
