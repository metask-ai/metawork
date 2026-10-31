import { createServer } from "node:http";
import { appendFileSync, mkdirSync, existsSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { protocolTextSse } from "./provider_protocol.mjs";

const [tracePath, mode, archive] = process.argv.slice(2);
const workspace = dirname(tracePath);
const resources = join(workspace, "resources");
const skillResources = mode.startsWith("skill-resource-");
mkdirSync(resources);
const unpack = spawnSync(
  process.platform === "win32" ? "tar.exe" : "/usr/bin/tar",
  ["-xf", archive, "-C", resources],
);
if (unpack.status !== 0)
  throw Error("Office fixture resource extraction failed");
const trace = (value) =>
  appendFileSync(tracePath, JSON.stringify(value) + "\n");
let requests = 0;
const send = (event) =>
  `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
function start() {
  return [
    {
      type: "message_start",
      message: {
        id: "office-pipeline",
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
      delta: { type: "text_delta", text: "Checking the requested operation. " },
    },
  ];
}
function command() {
  if (mode === "nonzero")
    return process.platform === "win32"
      ? "[IO.File]::WriteAllText('operation.txt', 'controlled-exit-7'); [Console]::Write([IO.File]::ReadAllText('operation.txt')); exit 7"
      : "printf 'controlled-exit-7' > operation.txt; cat operation.txt; exit 7";
  if (mode === "deny")
    return process.platform === "win32"
      ? "[IO.File]::WriteAllText('denied.txt', 'must-not-execute')"
      : "printf 'must-not-execute' > denied.txt";
  if (mode === "stale-entry" || mode === "unreachable-preparation") {
    if (process.platform !== "darwin") throw Error("macOS preparation-path fixture required");
    const quote = (text) => "'" + text.replaceAll("'", "'\\''") + "'";
    if (mode === "stale-entry")
      return "/bin/sh " + quote(join(workspace, "expired-activation/environment/run.sh")) + " python unused.py";
    // Only this child gets an isolated HOME and an unreachable loopback proxy.
    // The unchanged official prepare entry cannot reach its download source.
    const proxy = "http://127.0.0.1:1";
    return "HOME=" + quote(workspace) + " " +
      ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
        .map((name) => name + "=" + quote(proxy)).join(" ") +
      " NO_PROXY='' no_proxy='' /bin/sh " +
      quote(join(resources, "xlsx/environment/prepare.sh")) + " python";
  }
  if (mode === "missing-environment") {
    const entry = join(
      resources,
      "xlsx/environment",
      process.platform === "win32" ? "run.cmd" : "run.sh",
    );
    if (process.platform === "win32") {
      const quote = (text) => "'" + text.replaceAll("'", "''") + "'";
      return (
        "$env:LOCALAPPDATA=" +
        quote(workspace) +
        "; & " +
        quote(entry) +
        " python missing.py; exit $LASTEXITCODE"
      );
    }
    const quote = (text) => "'" + text.replaceAll("'", "'\\''") + "'";
    return (
      "HOME=" +
      quote(workspace) +
      " /bin/sh " +
      quote(entry) +
      " python missing.py"
    );
  }
  return process.platform === "win32"
    ? "[IO.File]::WriteAllText('operation.txt', 'controlled-office-tool'); [Console]::Write([IO.File]::ReadAllText('operation.txt'))"
    : "printf 'controlled-office-tool' > operation.txt; cat operation.txt";
}
function strings(value) {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  if (value && typeof value === "object")
    return Object.values(value).flatMap(strings);
  return [];
}
function skillResponse(payload, results) {
  const marker = "QA028_DIRECTORY_REFERENCE_7429";
  if (
    results.some(
      (r) => !r.is_error && strings(r.content).join("\n").includes(marker),
    )
  ) {
    trace({ kind: "skill-resource-read", success: true });
    return protocolTextSse("anthropic", "QA_SKILL_OK_7429 " + marker);
  }
  const content = strings(payload.messages).join("\n");
  const directory = content.match(/Skill resource directory: ([^\r\n]+)/)?.[1];
  let name, input;
  if (!directory && mode === "skill-resource-tool" && requests === 1) {
    name = "Skill";
    input = { name: "qa-resource-context" };
  } else {
    if (
      !directory ||
      !directory.includes("activation-") ||
      directory.includes("${")
    )
      throw Error("Skill did not supply its materialized directory");
    if (requests > 3) throw Error("Skill resource read did not complete");
    name = "Read";
    input = { file_path: join(directory, "qa-reference.txt") };
    trace({ kind: "skill-resource-path", supplied_by_context: true });
  }
  return [
    ...start(),
    { type: "content_block_stop", index: 0 },
    {
      type: "content_block_start",
      index: 1,
      content_block: {
        type: "tool_use",
        id: "resource-" + requests,
        name,
        input: {},
      },
    },
    {
      type: "content_block_delta",
      index: 1,
      delta: { type: "input_json_delta", partial_json: JSON.stringify(input) },
    },
    { type: "content_block_stop", index: 1 },
    {
      type: "message_delta",
      delta: { stop_reason: "tool_use" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  ]
    .map(send)
    .join("");
}
const server = createServer(async (request, response) => {
  try {
    const chunks = [];
    let bytes = 0;
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > 2 * 1024 * 1024) throw Error("fixture request budget");
      chunks.push(chunk);
    }
    const payload = JSON.parse(Buffer.concat(chunks));
    if (request.method !== "POST" || request.url !== "/v1/messages")
      throw Error("fixture target");
    if (!Array.isArray(payload.tools)) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(protocolTextSse("anthropic", "Office pipeline task"));
    }
    requests++;
    const last = payload.messages.at(-1);
    const results = Array.isArray(last.content)
      ? last.content.filter((part) => part.type === "tool_result")
      : [];
    trace({ kind: "request", requests, results });
    if (mode === "fixture-error") throw Error("Controlled fixture assertion");
    if (skillResources) {
      const body = skillResponse(payload, results);
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(body);
    }
    if (mode === "retry" && requests === 1) {
      response.writeHead(503, { "content-type": "application/json" });
      return response.end(
        JSON.stringify({
          type: "error",
          error: { type: "overloaded_error", message: "Controlled retry" },
        }),
      );
    }
    if (mode === "cancel") {
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const event of start()) response.write(send(event));
      return; // Product cancellation must close this actual streaming request.
    }
    if (mode === "consumer-starvation") {
      response.writeHead(200, { "content-type": "text/event-stream" });
      const events = start();
      for (let index = 0; index < 256; index++)
        events.push({
          type: "content_block_delta",
          index: 0,
          delta: { type: "text_delta", text: "Synthetic stream chunk. " },
        });
      events.push(
        { type: "content_block_stop", index: 0 },
        {
          type: "message_delta",
          delta: { stop_reason: "end_turn" },
          usage: { output_tokens: 256 },
        },
        { type: "message_stop" },
      );
      response.end(events.map(send).join(""));
      writeFileSync(join(workspace, "starvation-ready"), "ready");
      return;
    }
    if (mode === "stream-interruption" && requests === 1) {
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const event of start()) response.write(send(event));
      const timer = setTimeout(() => response.destroy(), 100);
      response.on("close", () => clearTimeout(timer));
      return;
    }
    if (results.length) {
      const failed = ["nonzero", "missing-environment", "stale-entry", "unreachable-preparation", "deny"].includes(mode);
      const result = results.at(-1);
      if (mode === "deny") {
        if (!result.is_error) throw Error("denied operation was not refused");
      } else {
        // Bash invocation success and the child process exit are distinct.
        // A nonzero process exit remains a structured Bash result.
        const bash = JSON.parse(result.content);
        const expectedExit = ({ nonzero: 7, "missing-environment": 3,
          "stale-entry": 127, "unreachable-preparation": 7 })[mode] ?? 0;
        if (
          result.is_error ||
          bash.schema_version !== "metacodes.bash-result.v2" ||
          bash.exit_code !== expectedExit
        )
          throw Error(`unexpected process exit classification: expected ${expectedExit}, got ${bash.exit_code}, is_error=${!!result.is_error}, stderr=${bash.stderr?.slice(0, 1024)}`);
        if (["success", "nonzero", "retry", "multi-run"].includes(mode)) {
          const expectedOutput = mode === "nonzero"
            ? "controlled-exit-7"
            : "controlled-office-tool";
          if (bash.stdout !== expectedOutput || bash.stderr !== "" ||
              readFileSync(join(workspace, "operation.txt"), "utf8") !== expectedOutput)
            throw Error("unexpected controlled process output");
        }
        if (mode === "unreachable-preparation") {
          if (!bash.stderr.includes("curl: (7)") || !bash.stderr.includes("127.0.0.1"))
            throw Error("Official preparation did not fail at the loopback proxy");
          const metadata = JSON.parse(readFileSync(join(resources, "xlsx/environment/environment.json"), "utf8"));
          const dependencies = join(workspace, "Library/Application Support", metadata.namespace);
          if (!existsSync(dependencies) || readdirSync(dependencies).length !== 0)
            throw Error("Failed preparation published an environment or retained a stage");
          trace({ kind: "preparation-cleanup", exit_code: bash.exit_code,
            published_environment: false, stage_count: 0 });
        }
      }
      if (mode === "deny" && existsSync(join(workspace, "denied.txt")))
        throw Error("denied operation executed");
      response.writeHead(200, { "content-type": "text/event-stream" });
      return response.end(
        protocolTextSse(
          "anthropic",
          failed
            ? "The controlled tool failed as expected."
            : "The controlled tool completed.",
        ),
      );
    }
    const events = [
      ...start(),
      { type: "content_block_stop", index: 0 },
      {
        type: "content_block_start",
        index: 1,
        content_block: {
          type: "tool_use",
          id: "bash-" + requests,
          name: "Bash",
          input: {},
        },
      },
      {
        type: "content_block_delta",
        index: 1,
        delta: {
          type: "input_json_delta",
          partial_json: JSON.stringify({ command: command(), timeout: 10000 }),
        },
      },
      { type: "content_block_stop", index: 1 },
      {
        type: "message_delta",
        delta: { stop_reason: "tool_use" },
        usage: { output_tokens: 1 },
      },
      { type: "message_stop" },
    ];
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(events.map(send).join(""));
  } catch (error) {
    trace({ kind: "fixture_error", type: error.name, reason: error.message });
    // A broken fixture must fail the test, rather than trigger Provider retries.
    if (!response.headersSent) {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({
        type: "error",
        error: { type: "invalid_request_error", message: "Office fixture assertion failed" },
      }));
    } else response.end();
  }
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
