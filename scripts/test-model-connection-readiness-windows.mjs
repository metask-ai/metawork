import { execFile, spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { buildAutomationDebugArtifact } from "./build.mjs";

if (process.platform !== "win32")
  throw new Error("Model Connection readiness requires Windows");

const execFileAsync = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const native = path.join(
  root,
  "node_modules",
  "@native-sdk",
  "cli",
  "bin",
  "native.js",
);
const binary = path.join(root, "zig-out", "bin", "metawork.exe");
const secureInputProbe = path.join(
  root,
  "scripts",
  "probe-model-connection-secure-input-windows.ps1",
);
const powershell = path.join(
  process.env.SystemRoot ?? "C:\\Windows",
  "System32",
  "WindowsPowerShell",
  "v1.0",
  "powershell.exe",
);
const commandTimeoutMs = 60_000;
const runTimeoutMs = 60_000;
const credential = "metawork-model-connection-readiness-key";
const model = "metawork-model-connection-readiness-model";
const service = "com.metask.metawork.dev.automation.account.model-connections";

if (process.env.METAWORK_MODEL_CONNECTION_READINESS_PREBUILT !== "1")
  await buildAutomationDebugArtifact(root);

const workspace = await mkdtemp(
  path.join(tmpdir(), "metawork-model-connection-readiness-"),
);
const appCwd = path.join(workspace, "app-cwd");
const platformHome = path.join(workspace, "platform-home");
await mkdir(appCwd, { recursive: true });
await mkdir(platformHome, { recursive: true });
const dataRoot = path.join(platformHome, "MetaWork Automation", "Data");
const automationDir = path.join(appCwd, ".zig-cache", "native-sdk-automation");
const provider = createProvider();
const endpoint = await provider.listen();
const appEnvironment = {
  ...process.env,
  APPDATA: platformHome,
  LOCALAPPDATA: platformHome,
  USERPROFILE: platformHome,
  METAWORK_MODEL_CONNECTION_READINESS: "1",
  METAWORK_AUTOMATION_WORKSPACE: workspace,
};
delete appEnvironment.METAWORK_AUTOMATION;

let app = null;
let exited = null;
let exitState = null;
let output = "";
let credentialTarget = null;

try {
  startApplication();
  const initial = await poll(
    async () => {
      const current = await snapshot();
      return current.account?.state === "checking" ? null : current;
    },
    commandTimeoutMs,
    "signed-out Workbench",
  );
  if (initial.account?.state !== "signed_out")
    throw new Error(
      `readiness profile was not signed out: ${JSON.stringify(initial.account)}`,
    );
  if (
    initial.capabilities?.modelConnectionManagement !== true ||
    initial.capabilities?.modelConnectionSecretCapture !== true ||
    initial.capabilities?.modelConnectionTest !== true
  )
    throw new Error(
      `Windows Host did not publish the complete Model Connection gate: ${JSON.stringify(initial.capabilities)}`,
    );
  if (initial.execution?.taskCreationAvailable !== false)
    throw new Error(
      "signed-out profile admitted Task creation before a default source",
    );

  const createResponse = invokeBridge("metawork.models.connections.create", {
    displayName: "Readiness provider",
    protocol: "openai_chat_completions",
    normalizedBaseUrl: endpoint,
    modelId: model,
    modelDisplayName: "Readiness model",
  }).then(
    (value) => ({ value, error: null }),
    (error) => ({ value: null, error }),
  );
  const secureInputResponse = execFileAsync(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      secureInputProbe,
      "-ProcessId",
      String(app.pid),
      "-HoldMilliseconds",
      "2500",
    ],
    {
      env: {
        ...process.env,
        METAWORK_READINESS_CREDENTIAL: credential,
      },
      timeout: commandTimeoutMs,
      maxBuffer: 1024 * 1024,
    },
  ).then(
    (value) => ({ value, error: null }),
    (error) => ({ value: null, error }),
  );
  const firstCreateEvent = await Promise.race([
    createResponse.then((outcome) => ({ kind: "create", outcome })),
    secureInputResponse.then((outcome) => ({ kind: "secure_input", outcome })),
  ]);
  if (firstCreateEvent.kind === "create") {
    if (firstCreateEvent.outcome.error) throw firstCreateEvent.outcome.error;
    throw new Error(
      `Model Connection create returned before secure input: ${JSON.stringify(firstCreateEvent.outcome.value)}`,
    );
  }
  if (firstCreateEvent.outcome.error) throw firstCreateEvent.outcome.error;
  const createOutcome = await createResponse;
  if (createOutcome.error) throw createOutcome.error;
  const secureInputEvidence = JSON.parse(
    firstCreateEvent.outcome.value.stdout.trim(),
  );
  if (
    secureInputEvidence.password !== true ||
    secureInputEvidence.valueReadable !== false ||
    secureInputEvidence.submitted !== true ||
    secureInputEvidence.holdMilliseconds < 2500
  )
    throw new Error(
      `secure input evidence was incomplete: ${JSON.stringify(secureInputEvidence)}`,
    );
  assertAccepted(createOutcome.value, "Model Connection create");

  const created = await poll(
    async () => {
      const current = await snapshot();
      const connection = current.models?.connections?.find(
        (item) => item.displayName === "Readiness provider",
      );
      return connection ? { current, connection } : null;
    },
    commandTimeoutMs,
    "created Model Connection",
  );
  const { connection } = created;
  if (
    !isWireId(connection.connectionGeneration) ||
    connection.protocol !== "openai_chat_completions" ||
    connection.credentialStatus !== "ready" ||
    connection.state !== "configuring" ||
    connection.testStatus !== "untested"
  )
    throw new Error(
      `created connection projection was invalid: ${JSON.stringify(connection)}`,
    );
  credentialTarget = nativeCredentialTarget(service, connection.id);

  const registryPath = path.join(dataRoot, "account", "models.json");
  const registryBytes = await readFile(registryPath);
  if (registryBytes.includes(Buffer.from(credential)))
    throw new Error(
      "Model Connection registry persisted the captured credential",
    );
  const registry = JSON.parse(registryBytes.toString("utf8"));
  if (
    registry.connections?.length !== 1 ||
    registry.connections[0]?.id !== connection.id
  )
    throw new Error(
      "Model Connection registry omitted the committed connection",
    );
  if (!(await listCredentialTargets()).includes(credentialTarget))
    throw new Error(
      "captured credential was not committed to Windows Credential Manager",
    );

  assertAccepted(
    await invokeBridge("metawork.models.connections.test", {
      connectionId: connection.id,
      expectedConnectionGeneration: connection.connectionGeneration,
      modelId: model,
    }),
    "Model Connection test",
  );
  const connected = await poll(
    async () => {
      const current = await snapshot();
      const item = current.models?.connections?.find(
        (candidate) => candidate.id === connection.id,
      );
      return item?.testStatus === "connected" ? { current, item } : null;
    },
    commandTimeoutMs,
    "connected Model Connection",
  );
  if (connected.item.state !== "ready")
    throw new Error(
      "successful connection test did not make the generation ready",
    );

  assertAccepted(
    await invokeBridge("metawork.models.selectDefault", {
      sourceId: connection.id,
      modelId: model,
      expectedSelectionRevision: connected.current.models.selectionRevision,
      expectedSourceGeneration: connection.sourceGeneration,
      expectedCatalogGeneration: connection.catalogGeneration,
    }),
    "Model Connection default selection",
  );
  const selected = await poll(
    async () => {
      const current = await snapshot();
      return current.models?.defaultSelection?.sourceId === connection.id &&
        current.models?.defaultSelection?.modelId === model &&
        current.execution?.activeSource === "model_connection" &&
        current.execution?.taskCreationAvailable === true
        ? current
        : null;
    },
    commandTimeoutMs,
    "selected Model Connection",
  );
  if (selected.account?.state !== "signed_out")
    throw new Error(
      "selecting a custom model source changed Account identity state",
    );

  const chosenWorkspace = await invokeBridge("metawork.workspaces.choose", {});
  if (
    chosenWorkspace?.selected !== true ||
    !isWireId(chosenWorkspace.workspaceId)
  )
    throw new Error(
      `readiness Workspace selection failed: ${JSON.stringify(chosenWorkspace)}`,
    );
  const workspaceId = chosenWorkspace.workspaceId;
  const workspaceReady = await poll(
    async () => {
      const current = await snapshot();
      const item = current.workspaces?.find(
        (candidate) => candidate.id === workspaceId,
      );
      const catalog = item?.skillCatalog;
      return item?.authorization === "available" &&
        (catalog?.availability === "ready" ||
          catalog?.availability === "degraded") &&
        catalog.revision !== null &&
        isWireId(catalog.selectionRevision)
        ? { current, item, catalog }
        : null;
    },
    commandTimeoutMs,
    "readiness Workspace catalog",
  );
  const createTask = await invokeBridge("metawork.tasks.create", {
    workspace: {
      kind: "manual",
      workspaceId,
      expectedWorkspaceEpoch: workspaceReady.item.epoch,
    },
    expectedExecutionGeneration:
      workspaceReady.current.execution.activeGeneration,
    expectedSkillCatalogRevision: workspaceReady.catalog.revision,
    expectedSkillSelectionRevision: workspaceReady.catalog.selectionRevision,
    permissionProfile: "approval_required",
  });
  if (createTask?.accepted !== true || !isWireId(createTask.taskId))
    throw new Error(`Task creation failed: ${JSON.stringify(createTask)}`);
  const runResult = await invokeBridge("metawork.tasks.run", {
    taskId: createTask.taskId,
    expectedBindingEpoch: createTask.bindingEpoch,
    input: {
      kind: "text",
      text: "Reply with the readiness confirmation.",
    },
  });
  if (runResult?.accepted !== true || !isWireId(runResult.runId))
    throw new Error(`Task Run submission failed: ${JSON.stringify(runResult)}`);
  const terminal = await poll(
    async () => {
      if (provider.error) throw provider.error;
      const current = await snapshot();
      const task = current.tasks?.find((item) => item.id === createTask.taskId);
      const run = task?.runs?.find((item) => item.id === runResult.runId);
      return run?.phase === "completed" ? { current, task, run } : null;
    },
    runTimeoutMs,
    "custom-source Task Run",
  );
  if (
    terminal.run.outcome !== "completed" ||
    !terminal.run.output?.response?.includes(
      "model connection readiness complete",
    )
  )
    throw new Error(
      `custom-source Run did not complete truthfully: ${JSON.stringify(terminal.run)}`,
    );
  if (JSON.stringify(terminal.current).includes(credential))
    throw new Error("captured credential reached the Renderer snapshot");
  if (output.includes(credential))
    throw new Error("captured credential reached native application output");
  if (provider.requests.length < 2)
    throw new Error(
      `provider observed only ${provider.requests.length} authenticated requests`,
    );

  await stopApplication();
  if (output.includes(credential))
    throw new Error("captured credential reached shutdown output");
  process.stdout.write(
    `Model Connection Windows readiness passed: ${JSON.stringify({
      accountState: initial.account.state,
      completeCapabilityGate: true,
      secureInput: secureInputEvidence,
      registryWithoutSecret: true,
      windowsCredentialTarget: "present",
      connectionTest: "connected",
      defaultSource: "model_connection",
      taskRun: terminal.run.outcome,
      providerRequests: provider.requests.length,
      cleanShutdown: true,
    })}\n`,
  );
} catch (error) {
  process.stderr.write(`${output.replaceAll(credential, "[REDACTED]")}\n`);
  throw error;
} finally {
  if (exitState === null && app !== null) {
    app.kill("SIGTERM");
    await withTimeout(exited, 5000, "forced readiness app stop").catch(
      async () => {
        await execFileAsync("taskkill.exe", ["/pid", String(app.pid), "/f"]);
        await withTimeout(exited, 5000, "killed readiness app stop");
      },
    );
  }
  await provider.close();
  if (credentialTarget !== null) await deleteCredentialTarget(credentialTarget);
  await removeWorkspaceWithRetry().catch((error) => {
    process.stderr.write(
      `readiness temporary directory cleanup deferred: ${error.message}\n`,
    );
  });
}

function startApplication() {
  app = spawn(binary, [], {
    cwd: appCwd,
    env: appEnvironment,
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
  exited = new Promise((resolve, reject) => {
    app.once("error", reject);
    app.once("exit", (code, signal) => {
      exitState = { code, signal };
      resolve(exitState);
    });
  });
}

async function stopApplication() {
  await automate("tray-action", "2");
  const final = await withTimeout(
    exited,
    commandTimeoutMs,
    "readiness app stop",
  );
  if (final.code !== 0 || final.signal !== null)
    throw new Error(
      `readiness app exited abnormally: ${JSON.stringify(final)}`,
    );
  if (!/runtime\.event.*event="stop"/.test(output))
    throw new Error("readiness app did not report normal runtime stop");
}

async function automate(...args) {
  return execFileAsync(process.execPath, [native, "automate", ...args], {
    cwd: appCwd,
    timeout: commandTimeoutMs,
    maxBuffer: 1024 * 1024,
  });
}

async function invokeBridge(command, payload) {
  const id = `model-connection-readiness-${Date.now()}-${Math.random().toString(16).slice(2)}`;
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
        await readFile(path.join(automationDir, "bridge-response.txt"), "utf8"),
      );
      if (latest.id === id) response = latest;
    } catch {
      // Product events may replace the latest response before this read.
    }
  }
  if (response === null)
    throw new Error(`${command} produced no correlated Bridge response`);
  if (!response.ok)
    throw new Error(`${command} failed: ${JSON.stringify(response.error)}`);
  return response.result;
}

async function snapshot() {
  const descriptor = await invokeBridge("metawork.workbench.snapshot", {});
  if (
    !descriptor ||
    !isWireId(descriptor.snapshotId) ||
    !Number.isSafeInteger(descriptor.bytes) ||
    descriptor.bytes <= 0 ||
    !Number.isSafeInteger(descriptor.chunkBytes) ||
    descriptor.chunkBytes <= 0
  )
    throw new Error(
      `invalid snapshot descriptor: ${JSON.stringify(descriptor)}`,
    );
  const bytes = Buffer.alloc(descriptor.bytes);
  for (
    let offset = 0;
    offset < descriptor.bytes;
    offset += descriptor.chunkBytes
  ) {
    const chunk = await invokeBridge("metawork.workbench.snapshot.chunk", {
      snapshotId: descriptor.snapshotId,
      offset: String(offset),
    });
    const decoded = Buffer.from(chunk.data, "base64");
    decoded.copy(bytes, offset);
  }
  return JSON.parse(bytes.toString("utf8"));
}

function assertAccepted(result, label) {
  if (result?.accepted !== true || result.reason !== null)
    throw new Error(`${label} was rejected: ${JSON.stringify(result)}`);
}

function isWireId(value) {
  return typeof value === "string" && /^[1-9][0-9]*$/.test(value);
}

function nativeCredentialTarget(serviceName, account) {
  return `native-sdk:${Buffer.byteLength(serviceName)}:${serviceName}${account}`;
}

async function listCredentialTargets() {
  const { stdout } = await execFileAsync("cmdkey.exe", ["/list"], {
    timeout: commandTimeoutMs,
    maxBuffer: 1024 * 1024,
  });
  return stdout;
}

async function deleteCredentialTarget(target) {
  try {
    await execFileAsync("cmdkey.exe", [`/delete:${target}`], {
      timeout: commandTimeoutMs,
      maxBuffer: 1024 * 1024,
    });
  } catch (error) {
    const current = await listCredentialTargets();
    if (current.includes(target)) throw error;
  }
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

function withTimeout(promise, milliseconds, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds),
    ),
  ]);
}

async function removeWorkspaceWithRetry() {
  let lastError = null;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      await rm(workspace, { recursive: true, force: true });
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  throw lastError;
}

function createProvider() {
  const requests = [];
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
        if (request.method !== "POST" || request.url !== "/v1/chat/completions")
          throw new Error(
            `unexpected readiness provider route: ${request.method} ${request.url}`,
          );
        if (bytes > 2 * 1024 * 1024)
          throw new Error("readiness provider request exceeded its bound");
        if (request.headers.authorization !== `Bearer ${credential}`)
          throw new Error(
            "captured credential did not reach the provider exactly",
          );
        const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (payload.model !== model || !Array.isArray(payload.messages))
          throw new Error("selected model did not reach the provider exactly");
        requests.push(payload);
        if (payload.stream === true) {
          response.writeHead(200, {
            "content-type": "text/event-stream",
            "cache-control": "no-cache",
            connection: "close",
          });
          response.end(
            [
              {
                choices: [
                  {
                    index: 0,
                    delta: {
                      content: "model connection readiness complete",
                    },
                  },
                ],
              },
              { choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
            ]
              .map((item) => `data: ${JSON.stringify(item)}\n\n`)
              .join("") + "data: [DONE]\n\n",
          );
          return;
        }
        response.writeHead(200, {
          "content-type": "application/json",
          connection: "close",
        });
        response.end(
          JSON.stringify({
            choices: [
              {
                message: { role: "assistant", content: "OK" },
                finish_reason: "stop",
              },
            ],
            usage: { prompt_tokens: 1, completion_tokens: 1 },
          }),
        );
      } catch (error) {
        providerError ??= error;
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "invalid readiness request" }));
      }
    });
  });
  return {
    requests,
    get error() {
      return providerError;
    },
    listen() {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
          const address = server.address();
          resolve(`http://127.0.0.1:${address.port}/v1/chat/completions`);
        });
      });
    },
    close() {
      return new Promise((resolve) => server.close(resolve));
    },
  };
}
