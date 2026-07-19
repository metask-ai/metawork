import { execFile, spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const native = `${root}node_modules/.bin/native`;
const binary = `${root}zig-out/bin/metawork`;
const automationDir = `${root}.zig-cache/native-sdk-automation`;
const commandTimeoutMs = 20_000;
const runTimeoutMs = 60_000;
const workspace = await mkdtemp("/tmp/metawork-gate6-");
const fixturePath = join(workspace, "fixture.txt");
await writeFile(fixturePath, "gate6-before\n", { mode: 0o600 });
await rm(automationDir, { recursive: true, force: true });

const responses = [
  toolSse("m1", "read-1", "Read", { file_path: fixturePath }),
  toolSse("m2", "bash-1", "Bash", { command: "printf gate6-bash-ok" }),
  toolSse("m3", "edit-1", "Edit", {
    file_path: fixturePath,
    old_string: "gate6-before",
    new_string: "gate6-after",
  }),
  toolSse("m4", "ask-1", "AskUserQuestion", {
    questions: [
      {
        question: "Continue the Gate 6 run?",
        header: "Continue",
        options: [
          { label: "Yes", description: "Finish the run" },
          { label: "No", description: "Stop here" },
        ],
      },
    ],
  }),
  textSse("m5", "metawork gate6 complete"),
];
const provider = createProvider(responses);
const baseUrl = await provider.listen();

let output = "";
let exitState = null;
const app = spawn(binary, [], {
  cwd: root,
  env: {
    ...process.env,
    METAWORK_GATE0_AUTOMATION: "1",
    METAWORK_PROVIDER_API_KEY: "metawork-gate6-fixture-key",
    METAWORK_PROVIDER_MODEL: "metawork-gate6-fixture-model",
    METAWORK_PROVIDER_KIND: "anthropic",
    METAWORK_PROVIDER_BASE_URL: baseUrl,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
app.stdout.setEncoding("utf8");
app.stderr.setEncoding("utf8");
app.stdout.on("data", (chunk) => {
  output += chunk;
});
app.stderr.on("data", (chunk) => {
  output += chunk;
});
const exited = new Promise((resolve, reject) => {
  app.once("error", reject);
  app.once("exit", (code, signal) => {
    exitState = { code, signal };
    resolve(exitState);
  });
});

try {
  await waitForBridge();
  const beforeCreate = await snapshot();
  await invokeBridge("metawork.tasks.create", {
    workspaceRoot: workspace,
  });
  const createdTask = await poll(
    async () => {
      const current = await snapshot();
      return (
        current.tasks.find(
          (item) => !beforeCreate.tasks.some((prior) => prior.id === item.id),
        ) ?? null
      );
    },
    commandTimeoutMs,
    "Task creation",
  );
  const taskId = createdTask.id;
  await invokeBridge("metawork.tasks.run", {
    taskId,
    prompt: "Exercise Read, Bash, Edit, and AskUserQuestion, then finish.",
  });
  const submittedRun = await poll(
    async () => {
      const current = await snapshot();
      return current.tasks.find((item) => item.id === taskId)?.runs[0] ?? null;
    },
    commandTimeoutMs,
    "Run submission",
  );
  const runId = submittedRun.id;
  let reloadedRequest = null;
  const answered = new Set();
  const terminal = new Set([
    "completed",
    "stopped",
    "cancelled",
    "interrupted",
    "failed",
  ]);
  const finalSnapshot = await poll(
    async () => {
      if (provider.error) throw provider.error;
      const current = await snapshot();
      const task = current.tasks.find((item) => item.id === taskId);
      const run = task?.runs.find((item) => item.id === runId);
      if (!task || !run) return null;
      const pending = task.pendingUi;
      if (pending && !answered.has(pending.requestId)) {
        if (typeof pending.redacted !== "boolean")
          throw new Error("pending UI omitted its projection privacy state");
        if (pending.runId !== runId)
          throw new Error(
            `pending UI routed to another run: ${JSON.stringify(pending)}`,
          );
        let responsePayload;
        if (pending.kind === "permission") {
          responsePayload = {
            taskId,
            runId,
            requestId: pending.requestId,
            kind: "permission",
            permission: "allow_once",
          };
        } else if (pending.kind === "ask_question") {
          if (reloadedRequest === null) {
            reloadedRequest = pending.requestId;
            await automate("reload");
            await waitForBridge();
            const restored = await snapshot();
            const restoredTask = restored.tasks.find(
              (item) => item.id === taskId,
            );
            if (
              restoredTask?.pendingUi?.requestId !== pending.requestId ||
              restoredTask.pendingUi.runId !== runId
            )
              throw new Error(
                "Renderer reload lost or rerouted the pending UI request",
              );
          }
          responsePayload = {
            taskId,
            runId,
            requestId: pending.requestId,
            kind: "answers",
            answers: ["Yes"],
          };
        } else {
          throw new Error(
            `unexpected Gate 6 UI request: ${JSON.stringify(pending)}`,
          );
        }
        await invokeBridge("metawork.tasks.respondUi", responsePayload);
        await expectBridgeFailure(
          "metawork.tasks.respondUi",
          responsePayload,
          `duplicate UI response ${pending.requestId}`,
        );
        answered.add(pending.requestId);
      }
      if (terminal.has(run.phase)) return current;
      return null;
    },
    runTimeoutMs,
    "AgentCore run",
  );

  const task = finalSnapshot.tasks.find((item) => item.id === taskId);
  const run = task.runs.find((item) => item.id === runId);
  if (task.continuationAvailable !== true)
    throw new Error("completed Task did not remain available for continuation");
  if (run.phase !== "completed" || run.outcome !== "completed")
    throw new Error(`run did not complete truthfully: ${JSON.stringify(run)}`);
  if (run.cause !== null || task.cause !== null)
    throw new Error(
      `completed run retained a Host cause: ${JSON.stringify(task)}`,
    );
  if (!run.assistant.includes("metawork gate6 complete"))
    throw new Error("final assistant text was not projected");
  const activityOrders = [];
  for (const [name, evidence] of [
    ["Read", "gate6-before"],
    ["Bash", "gate6-bash-ok"],
    ["Edit", ""],
  ]) {
    const tool = run.tools.find((item) => item.name === name);
    if (!tool || tool.state !== "completed" || tool.isError)
      throw new Error(`${name} did not complete: ${JSON.stringify(tool)}`);
    if (!/^[1-9][0-9]*$/.test(tool.order))
      throw new Error(`${name} omitted its stable activity order`);
    activityOrders.push(tool.order);
    for (const field of [
      "inputTruncated",
      "progressTruncated",
      "contentTruncated",
      "redacted",
    ])
      if (typeof tool[field] !== "boolean")
        throw new Error(`${name} omitted projection safety flag ${field}`);
    if (evidence && !tool.content.includes(evidence))
      throw new Error(`${name} result omitted ${evidence}`);
  }
  if (reloadedRequest === null)
    throw new Error("AskUserQuestion did not exercise reload-safe resume");
  if (task.pendingUi !== null)
    throw new Error("completed run retained an actionable UI request");
  if (!Array.isArray(task.uiHistory) || task.uiHistory.length === 0)
    throw new Error("resolved UI requests were not retained in Task history");
  for (const record of task.uiHistory) {
    if (!/^[1-9][0-9]*$/.test(record.order))
      throw new Error("resolved UI request omitted its stable activity order");
    activityOrders.push(record.order);
  }
  if (new Set(activityOrders).size !== activityOrders.length)
    throw new Error("Run activity order was not unique");
  for (const requestId of answered)
    if (!task.uiHistory.some((item) => item.requestId === requestId))
      throw new Error(`resolved UI request ${requestId} was lost from history`);
  if (
    !task.uiHistory.some(
      (item) => item.kind === "permission" && item.state === "allowed_once",
    )
  )
    throw new Error("permission decision was not retained in Task history");
  const restoredAnswer = task.uiHistory.find(
    (item) => item.requestId === reloadedRequest,
  );
  if (
    restoredAnswer?.kind !== "ask_question" ||
    restoredAnswer.state !== "answered"
  )
    throw new Error("reload-safe question did not resolve into UI history");
  const edited = await readFile(fixturePath, "utf8");
  if (edited !== "gate6-after\n")
    throw new Error(
      `Edit did not update the workspace: ${JSON.stringify(edited)}`,
    );
  if (provider.served !== responses.length)
    throw new Error(
      `provider served ${provider.served}/${responses.length} responses`,
    );
  if (provider.error) throw provider.error;

  await invokeBridge("metawork.tasks.rename", {
    taskId,
    title: "Gate 6 release audit",
  });
  let metadataSnapshot = await snapshot();
  let metadataTask = metadataSnapshot.tasks.find((item) => item.id === taskId);
  if (metadataTask?.title !== "Gate 6 release audit")
    throw new Error("Task rename was not projected");
  await invokeBridge("metawork.tasks.archive", {
    taskId,
    archived: true,
  });
  metadataSnapshot = await snapshot();
  metadataTask = metadataSnapshot.tasks.find((item) => item.id === taskId);
  if (metadataTask?.archived !== true)
    throw new Error("Task archive was not projected");
  await invokeBridge("metawork.tasks.archive", {
    taskId,
    archived: false,
  });

  const transport = await automate("snapshot");
  assertTransport(transport.stdout);
  await invokeBridge("metawork.tasks.close", { taskId });
  await poll(
    async () => {
      const current = await snapshot();
      return current.tasks.find((item) => item.id === taskId)?.lifecycle ===
        "closed"
        ? current
        : null;
    },
    commandTimeoutMs,
    "Task close",
  );
  await invokeBridge("metawork.tasks.delete", { taskId });
  const afterDelete = await snapshot();
  if (afterDelete.tasks.some((item) => item.id === taskId))
    throw new Error("Deleted Task record remained in the projection");

  await invokeBridge("native-sdk.window.close", { label: "main" });
  const final = await withTimeout(exited, commandTimeoutMs, "app stop");
  if (final.code !== 0 || final.signal !== null)
    throw new Error(`app exited abnormally: ${JSON.stringify(final)}`);
  if (!/runtime\.event.*event="stop"/.test(output))
    throw new Error("normal runtime stop was not observed");

  process.stdout.write(
    "Gate 6 macOS vertical passed: real bundle, Read/Bash/Edit, permission UI, duplicate UI-response rejection, reload-safe AskUserQuestion resume, Task metadata lifecycle, async close.\n",
  );
} catch (error) {
  process.stderr.write(`${output}\n`);
  throw error;
} finally {
  if (exitState === null) {
    app.kill("SIGTERM");
    await withTimeout(exited, 5_000, "forced app stop").catch(async () => {
      app.kill("SIGKILL");
      await withTimeout(exited, 5_000, "killed app stop");
    });
  }
  await provider.close();
  await rm(workspace, { recursive: true, force: true });
}

async function invokeBridge(command, payload) {
  const id = `gate6-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const result = await automate(
    "bridge",
    JSON.stringify({ id, command, payload }),
  );
  const responses = result.stdout
    .trim()
    .split("\n")
    .reverse()
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  let response = responses.find((value) => value.id === id) ?? null;
  if (response === null) {
    try {
      const latest = JSON.parse(
        await readFile(join(automationDir, "bridge-response.txt"), "utf8"),
      );
      if (latest.id === id) response = latest;
    } catch {
      // The runtime replaces this file, so another bridge call may win.
    }
  }
  if (response && !response.ok)
    throw new Error(`${command} failed: ${JSON.stringify(response.error)}`);
  return response?.result ?? null;
}

async function expectBridgeFailure(command, payload, context) {
  try {
    await invokeBridge(command, payload);
  } catch {
    return;
  }
  throw new Error(`${context} was accepted`);
}

async function snapshot() {
  const descriptor = await invokeBridge("metawork.workbench.snapshot", {});
  if (
    !descriptor ||
    !/^[1-9][0-9]*$/.test(descriptor.snapshotId) ||
    !Number.isSafeInteger(descriptor.bytes) ||
    descriptor.bytes <= 0 ||
    descriptor.bytes > 8 * 1024 * 1024 ||
    !Number.isSafeInteger(descriptor.chunkBytes) ||
    descriptor.chunkBytes <= 0 ||
    descriptor.chunkBytes > 256 * 1024
  )
    throw new Error(
      `invalid snapshot descriptor: ${JSON.stringify(descriptor)}`,
    );

  const assembled = Buffer.alloc(descriptor.bytes);
  for (
    let offset = 0;
    offset < descriptor.bytes;
    offset += descriptor.chunkBytes
  ) {
    const chunk = await invokeBridge("metawork.workbench.snapshot.chunk", {
      snapshotId: descriptor.snapshotId,
      offset: String(offset),
    });
    const expectedBytes = Math.min(
      descriptor.chunkBytes,
      descriptor.bytes - offset,
    );
    const decoded = Buffer.from(chunk?.data ?? "", "base64");
    if (
      chunk?.snapshotId !== descriptor.snapshotId ||
      chunk?.offset !== offset ||
      chunk?.bytes !== expectedBytes ||
      decoded.length !== expectedBytes
    )
      throw new Error(`invalid snapshot chunk: ${JSON.stringify(chunk)}`);
    decoded.copy(assembled, offset);
  }
  const encoded = assembled.toString("utf8");
  if (encoded.includes("metawork-gate6-fixture-key"))
    throw new Error("Host provider credential reached the Renderer snapshot");
  const parsed = JSON.parse(encoded);
  if (parsed.schemaVersion !== 5 || !Array.isArray(parsed.tasks))
    throw new Error("invalid Workbench snapshot");
  return parsed;
}

async function automate(...args) {
  return execFileAsync(native, ["automate", ...args], {
    cwd: root,
    timeout: commandTimeoutMs,
    maxBuffer: 1024 * 1024,
  });
}

async function waitForBridge() {
  return poll(
    async () => {
      try {
        return await snapshot();
      } catch {
        return null;
      }
    },
    commandTimeoutMs,
    "Renderer bridge connection",
  );
}

async function poll(operation, milliseconds, label) {
  const deadline = Date.now() + milliseconds;
  let lastError = null;
  while (Date.now() < deadline) {
    if (exitState !== null)
      throw new Error(
        `app exited while waiting for ${label}: ${JSON.stringify(exitState)}`,
      );
    try {
      const value = await operation();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    if (provider.error) throw provider.error;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `${label} timed out${lastError ? `: ${lastError.message}` : ""}`,
  );
}

function createProvider(queue) {
  let served = 0;
  let providerError = null;
  const server = createServer((request, response) => {
    const chunks = [];
    let bytes = 0;
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes <= 2 * 1024 * 1024) chunks.push(chunk);
    });
    request.on("end", () => {
      try {
        if (bytes > 2 * 1024 * 1024)
          throw new Error("provider request exceeded the Gate 6 fixture bound");
        if (request.method !== "POST" || request.url !== "/v1/messages")
          throw new Error("AgentCore used an unexpected provider endpoint");
        if (
          request.headers.authorization !== "Bearer metawork-gate6-fixture-key"
        )
          throw new Error("Host credential did not reach AgentCore correctly");
        const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (payload.model !== "metawork-gate6-fixture-model")
          throw new Error("Host model did not reach AgentCore correctly");
        const body = queue[served];
        if (!body) throw new Error("unexpected extra provider request");
        served += 1;
        response.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "close",
        });
        response.end(body);
      } catch (error) {
        providerError ??= error;
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "invalid fixture request" }));
      }
    });
  });
  return {
    get served() {
      return served;
    },
    get error() {
      return providerError;
    },
    listen() {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
          const address = server.address();
          resolve(`http://127.0.0.1:${address.port}/v1/messages`);
        });
      });
    },
    close() {
      return new Promise((resolve) => server.close(resolve));
    },
  };
}

function toolSse(messageId, toolId, name, input) {
  return sse([
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

function textSse(messageId, text) {
  return sse([
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
      delta: { type: "text_delta", text },
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

function sse(events) {
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
}

function assertTransport(snapshot) {
  if (
    !/dispatch_errors=0/.test(snapshot) ||
    !/dropped_trace_records=0/.test(snapshot)
  )
    throw new Error(
      `automation snapshot reports transport errors:\n${snapshot}`,
    );
}

function withTimeout(promise, milliseconds, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} timed out`)),
      milliseconds,
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
