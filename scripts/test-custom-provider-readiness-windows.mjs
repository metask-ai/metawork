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
  throw new Error("Custom Provider readiness requires Windows");

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
const commandTimeoutMs = 60_000;
const runTimeoutMs = 60_000;
const credential = "metawork-custom-provider-readiness-key";
const model = "metawork-custom-provider-readiness-model";
const service = "com.metask.metawork.dev.automation.account.custom-providers";

if (process.env.METAWORK_CUSTOM_PROVIDER_READINESS_PREBUILT !== "1")
  await buildAutomationDebugArtifact(root);

const workspace = await mkdtemp(
  path.join(tmpdir(), "metawork-custom-provider-readiness-"),
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
  METAWORK_CUSTOM_PROVIDER_READINESS: "1",
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
    initial.capabilities?.customProviderManagement !== true ||
    initial.capabilities?.customProviderSecretCapture !== true ||
    initial.capabilities?.customModelTest !== true
  )
    throw new Error(
      `Windows Host did not publish the complete Custom Provider gate: ${JSON.stringify(initial.capabilities)}`,
    );
  if (initial.newTaskAdmission?.available !== false)
    throw new Error(
      "signed-out profile admitted Task creation before a default source",
    );

  assertAcceptedIfPresent(
    await invokeBridge("metawork.models.customProviders.create", {
      displayName: "Readiness provider",
      protocol: "openai_chat_completions",
      normalizedBaseUrl: endpoint,
      apiKey: credential,
    }),
    "Custom Provider create",
  );

  const created = await poll(
    async () => {
      const current = await snapshot();
      const provider = current.models?.customProviders?.find(
        (item) => item.displayName === "Readiness provider",
      );
      return provider ? { current, provider } : null;
    },
    commandTimeoutMs,
    "created Custom Provider",
  );
  let { provider: configuredProvider } = created;
  if (
    !isWireId(configuredProvider.providerRevision) ||
    configuredProvider.protocol !== "openai_chat_completions" ||
    configuredProvider.credentialStatus !== "ready" ||
    configuredProvider.state !== "configuring"
  )
    throw new Error(
      `created provider projection was invalid: ${JSON.stringify(configuredProvider)}`,
    );
  credentialTarget = nativeCredentialTarget(service, configuredProvider.id);

  const registryPath = path.join(dataRoot, "account", "models.json");
  const registryBytes = await readFile(registryPath);
  if (registryBytes.includes(Buffer.from(credential)))
    throw new Error(
      "Custom Provider registry persisted the captured credential",
    );
  const registry = JSON.parse(registryBytes.toString("utf8"));
  if (
    registry.custom_providers?.length !== 1 ||
    registry.custom_providers[0]?.id !== configuredProvider.id
  )
    throw new Error("Custom Provider registry omitted the committed provider");
  if (!(await listCredentialTargets()).includes(credentialTarget))
    throw new Error(
      "captured credential was not committed to Windows Credential Manager",
    );

  assertAcceptedIfPresent(
    await invokeBridge("metawork.models.customModels.add", {
      providerId: configuredProvider.id,
      expectedProviderRevision: configuredProvider.providerRevision,
      expectedCatalogGeneration: configuredProvider.catalogGeneration,
      model: { id: model, displayName: "Readiness model" },
    }),
    "Provider model add",
  );
  const configured = await poll(
    async () => {
      const current = await snapshot();
      const item = current.models?.customProviders?.find(
        (candidate) => candidate.id === configuredProvider.id,
      );
      return item?.models?.some((candidate) => candidate.id === model)
        ? { current, item }
        : null;
    },
    commandTimeoutMs,
    "configured Provider model",
  );
  configuredProvider = configured.item;

  assertAcceptedIfPresent(
    await invokeBridge("metawork.models.customModels.test", {
      model: { sourceId: configuredProvider.id, modelId: model },
      expectedProviderRevision: configuredProvider.providerRevision,
      expectedSourceGeneration: configuredProvider.sourceGeneration,
      expectedCatalogGeneration: configuredProvider.catalogGeneration,
    }),
    "Custom Provider test",
  );
  const connected = await poll(
    async () => {
      const current = await snapshot();
      const item = current.models?.customProviders?.find(
        (candidate) => candidate.id === configuredProvider.id,
      );
      const configuredModel = item?.models?.find(
        (candidate) => candidate.id === model,
      );
      return configuredModel?.testStatus === "connected"
        ? { current, item }
        : null;
    },
    commandTimeoutMs,
    "connected Custom Provider",
  );
  if (connected.item.state !== "ready")
    throw new Error("successful model test did not make the provider ready");

  assertAcceptedIfPresent(
    await invokeBridge("metawork.models.selectDefault", {
      sourceId: configuredProvider.id,
      modelId: model,
      expectedSelectionRevision: connected.current.models.selectionRevision,
      expectedSourceGeneration: configuredProvider.sourceGeneration,
      expectedCatalogGeneration: configuredProvider.catalogGeneration,
    }),
    "Custom Provider default selection",
  );
  const selected = await poll(
    async () => {
      const current = await snapshot();
      return current.models?.defaultSelection?.sourceId ===
        configuredProvider.id &&
        current.models?.defaultSelection?.modelId === model &&
        current.newTaskAdmission?.activeModelRef?.sourceId ===
          configuredProvider.id &&
        current.newTaskAdmission?.available === true
        ? current
        : null;
    },
    commandTimeoutMs,
    "selected Custom Provider",
  );
  if (selected.account?.state !== "signed_out")
    throw new Error(
      "selecting a custom model source changed Account identity state",
    );

  const workspaceIdsBefore = new Set(
    selected.workspaces.map((item) => item.id),
  );
  const chosenWorkspace = await invokeBridge("metawork.workspaces.choose", {});
  if (
    chosenWorkspace !== null &&
    (chosenWorkspace.selected !== true ||
      !isWireId(chosenWorkspace.workspaceId))
  )
    throw new Error(
      `readiness Workspace selection failed: ${JSON.stringify(chosenWorkspace)}`,
    );
  const workspaceId =
    chosenWorkspace?.workspaceId ??
    (
      await poll(
        async () => {
          const current = await snapshot();
          const created = current.workspaces.filter(
            (item) => !workspaceIdsBefore.has(item.id),
          );
          return created.length === 1 ? created[0] : null;
        },
        commandTimeoutMs,
        "committed readiness Workspace after response loss",
      )
    ).id;
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
  const taskIdsBefore = new Set(
    workspaceReady.current.tasks.map((item) => item.id),
  );
  const createTaskResponse = await invokeBridge("metawork.tasks.create", {
    workspace: {
      kind: "manual",
      workspaceId,
      expectedWorkspaceEpoch: workspaceReady.item.epoch,
    },
    expectedExecutionGeneration:
      workspaceReady.current.newTaskAdmission.activeGeneration,
    expectedSelectionRevision:
      workspaceReady.current.newTaskAdmission.activeSelectionRevision,
    modelSelection: null,
    expectedSkillCatalogRevision: workspaceReady.catalog.revision,
    expectedSkillSelectionRevision: workspaceReady.catalog.selectionRevision,
    permissionProfile: "approval_required",
  });
  if (
    createTaskResponse !== null &&
    (createTaskResponse.accepted !== true ||
      !isWireId(createTaskResponse.taskId) ||
      !isWireId(createTaskResponse.bindingEpoch))
  )
    throw new Error(
      `Task creation failed: ${JSON.stringify(createTaskResponse)}`,
    );
  const committedTask = await poll(
    async () => {
      const current = await snapshot();
      const created = current.tasks.filter(
        (item) =>
          item.workspaceId === workspaceId && !taskIdsBefore.has(item.id),
      );
      return created.length === 1 ? created[0] : null;
    },
    commandTimeoutMs,
    "committed readiness Task",
  );
  const taskId = createTaskResponse?.taskId ?? committedTask.id;
  const bindingEpoch =
    createTaskResponse?.bindingEpoch ?? committedTask.binding.epoch;
  if (
    committedTask.id !== taskId ||
    committedTask.binding.epoch !== bindingEpoch
  )
    throw new Error("Task response disagreed with the committed projection");
  const runIdsBefore = new Set(committedTask.runs.map((item) => item.id));
  const runResponse = await invokeBridge("metawork.tasks.run", {
    taskId,
    expectedBindingEpoch: bindingEpoch,
    input: {
      kind: "text",
      text: "Reply with the readiness confirmation.",
    },
  });
  if (
    runResponse !== null &&
    (runResponse.accepted !== true || !isWireId(runResponse.runId))
  )
    throw new Error(
      `Task Run submission failed: ${JSON.stringify(runResponse)}`,
    );
  const runId =
    runResponse?.runId ??
    (
      await poll(
        async () => {
          const current = await snapshot();
          const task = current.tasks.find((item) => item.id === taskId);
          const created = task?.runs.filter(
            (item) => !runIdsBefore.has(item.id),
          );
          return created?.length === 1 ? created[0] : null;
        },
        commandTimeoutMs,
        "committed readiness Run after response loss",
      )
    ).id;
  const terminal = await poll(
    async () => {
      if (provider.error) throw provider.error;
      const current = await snapshot();
      const task = current.tasks?.find((item) => item.id === taskId);
      const run = task?.runs?.find((item) => item.id === runId);
      return run?.phase === "completed" ? { current, task, run } : null;
    },
    runTimeoutMs,
    "custom-source Task Run",
  );
  if (
    terminal.run.terminal?.outcome !== "completed" ||
    !terminal.run.output?.response?.includes(
      "custom provider readiness complete",
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
    `Custom Provider Windows readiness passed: ${JSON.stringify({
      accountState: initial.account.state,
      completeCapabilityGate: true,
      registryWithoutSecret: true,
      windowsCredentialTarget: "present",
      modelTest: "connected",
      defaultSource: "custom_provider",
      taskRun: terminal.run.terminal?.outcome,
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
  const id = `custom-provider-readiness-${Date.now()}-${Math.random().toString(16).slice(2)}`;
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
      // Another Bridge response may replace this single-slot artifact.
    }
  }
  if (response && !response.ok) {
    const error = new Error(
      `${command} failed: ${JSON.stringify(response.error)}`,
    );
    error.bridgeCommand = command;
    error.bridgeResponseError = response.error;
    throw error;
  }
  return response?.result ?? null;
}

async function snapshot() {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await readSnapshot();
    } catch (error) {
      const stale =
        error?.bridgeCommand === "metawork.workbench.snapshot.chunk" &&
        error?.bridgeResponseError?.code === "handler_failed" &&
        error?.bridgeResponseError?.message === "StaleSnapshot";
      if ((!stale && error?.retryableSnapshotRead !== true) || attempt >= 4)
        throw error;
    }
  }
}

async function readSnapshot() {
  const descriptor = await invokeBridge("metawork.workbench.snapshot", {});
  if (descriptor === null) {
    const error = new Error("snapshot descriptor response was unavailable");
    error.retryableSnapshotRead = true;
    throw error;
  }
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
    if (chunk === null) {
      const error = new Error("snapshot chunk response was unavailable");
      error.retryableSnapshotRead = true;
      throw error;
    }
    const decoded = Buffer.from(chunk.data, "base64");
    decoded.copy(bytes, offset);
  }
  return JSON.parse(bytes.toString("utf8"));
}

function assertAcceptedIfPresent(result, label) {
  if (result === null) return;
  if (
    result?.accepted !== true ||
    result.errorCode !== "none" ||
    result.attemptId !== null
  )
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
                      content: "custom provider readiness complete",
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
