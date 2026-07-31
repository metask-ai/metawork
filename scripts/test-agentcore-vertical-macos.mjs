import { execFile, spawn } from "node:child_process";
import { createServer } from "node:http";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

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
const binary = path.join(
  root,
  "zig-out",
  "bin",
  process.platform === "win32" ? "metawork.exe" : "metawork",
);
const appCwd = process.env.METAWORK_TEST_APP_CWD
  ? path.resolve(root, process.env.METAWORK_TEST_APP_CWD)
  : root;
const automationDir = path.join(appCwd, ".zig-cache", "native-sdk-automation");
const visualCaptureDir = process.env.METAWORK_VISUAL_CAPTURE_DIR
  ? path.resolve(process.env.METAWORK_VISUAL_CAPTURE_DIR)
  : null;
const visualCaptureScript = path.join(
  root,
  "scripts",
  "capture-windows-window.ps1",
);
const macosWindowLookupScript = path.join(
  root,
  "scripts",
  "capture-macos-window.swift",
);
const windowsChromeProbeScript = path.join(
  root,
  "scripts",
  "probe-windows-window-chrome.ps1",
);
const commandTimeoutMs = 20_000;
const runTimeoutMs = 60_000;
const workspace = await mkdtemp(join(tmpdir(), "metawork-agentcore-vertical-"));
const canonicalWorkspace = await realpath(workspace);
const fixturePath = join(workspace, "fixture.txt");
await writeFile(fixturePath, "agentcore-vertical-before\n", { mode: 0o600 });
// This fixture targets an AgentCore-owned canonical project source. No
// MetaWork product module reads, configures, or exposes this physical path.
const skillDirectory = join(workspace, ".metacodes", "skills", "review");
await mkdir(skillDirectory, { recursive: true });
await writeFile(
  join(skillDirectory, "SKILL.md"),
  [
    "---",
    "name: Review",
    "description: Exercise the real AgentCore typed Skill vertical",
    "arguments: [target]",
    "disable-model-invocation: true",
    "---",
    "METAWORK_TYPED_SKILL_VERTICAL",
    "Review $target. Exercise Read, Bash, Edit, and AskUserQuestion, then finish.",
    "",
  ].join("\n"),
  { mode: 0o600 },
);
await rm(automationDir, { recursive: true, force: true });

const responses = [
  toolSse("m1", "read-1", "Read", { file_path: fixturePath }),
  toolSse("m2", "bash-1", "Bash", {
    command: "echo agentcore-vertical-bash-ok",
  }),
  toolSse("m3", "edit-1", "Edit", {
    file_path: fixturePath,
    old_string: "agentcore-vertical-before",
    new_string: "agentcore-vertical-after",
  }),
  toolSse("m4", "ask-1", "AskUserQuestion", {
    questions: [
      {
        question: "Continue the AgentCore vertical run?",
        header: "Continue",
        options: [
          { label: "Yes", description: "Finish the run" },
          { label: "No", description: "Stop here" },
        ],
      },
    ],
  }),
  textSse("m5", "metawork agentcore vertical complete"),
];
const provider = createProvider(responses, visualCaptureDir ? 1_500 : 0);
const baseUrl = await provider.listen();

let output = "";
let exitState = null;
const app = spawn(binary, [], {
  cwd: appCwd,
  env: {
    ...process.env,
    METAWORK_AUTOMATION: "1",
    METAWORK_AUTOMATION_WORKSPACE: workspace,
    METAWORK_AGENTCORE_VERTICAL_PROVIDER_BASE_URL: baseUrl,
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
  await captureVisual("new-task", 1320, 812);
  await captureVisual("search-keyboard", 1320, 812, false, true);
  await probeWindowsChrome("exercise");
  const chosenWorkspace = await invokeBridge("metawork.workspaces.choose", {});
  let workspaceId;
  if (chosenWorkspace === null) {
    // Native SDK exposes one latest-response artifact for automation and the
    // live WebView. A product notification can replace that artifact before
    // the harness reads it, so never replay a mutation: reconcile from the
    // authoritative snapshot instead.
    const reconciled = await snapshot();
    const selected = reconciled.workspaces.find(
      (item) => item.id === reconciled.selectedWorkspaceId,
    );
    if (!selected)
      throw new Error("Workspace choice had no response or committed state");
    workspaceId = selected.id;
  } else if (
    chosenWorkspace?.selected !== true ||
    !isWireId(chosenWorkspace.workspaceId)
  ) {
    throw new Error(
      `automation Workspace choice returned an invalid identity: ${JSON.stringify(chosenWorkspace)}`,
    );
  } else {
    workspaceId = chosenWorkspace.workspaceId;
  }
  const afterChoose = await snapshot();
  const selectedWorkspace = afterChoose.workspaces.find(
    (item) => item.id === workspaceId,
  );
  if (
    afterChoose.selectedWorkspaceId !== workspaceId ||
    selectedWorkspace?.authorization !== "available" ||
    selectedWorkspace.canonicalRoot !== canonicalWorkspace ||
    !isWireId(selectedWorkspace.epoch) ||
    selectedWorkspace.lastRemovalFailure !== null
  )
    throw new Error(
      `Workspace choice was not committed to the product snapshot: ${JSON.stringify(afterChoose.workspaces)}`,
    );
  const expectedWorkspaceEpoch = selectedWorkspace.epoch;
  const expectedExecutionGeneration = afterChoose.account.executionGeneration;
  if (!isWireId(expectedExecutionGeneration))
    throw new Error("snapshot omitted the current execution generation");
  const catalogSnapshot = await poll(
    async () => {
      const current = await snapshot();
      const selected = current.workspaces.find(
        (item) => item.id === workspaceId,
      );
      const catalog = selected?.skillCatalog;
      if (
        (catalog?.availability !== "ready" &&
          catalog?.availability !== "degraded") ||
        !isOpaqueRevision(catalog.revision)
      )
        return null;
      const skill = catalog.skills.find(
        (item) => item.invocationName === "review",
      );
      return skill ? { catalog, skill } : null;
    },
    commandTimeoutMs,
    "Workspace Skill catalog",
  );
  if (
    !/^[0-9a-f]{64}$/.test(catalogSnapshot.skill.skillId) ||
    catalogSnapshot.skill.displayName !== "Review" ||
    !catalogSnapshot.skill.argumentNames.includes("target")
  )
    throw new Error(
      `Workspace catalog omitted the review Skill projection: ${JSON.stringify(catalogSnapshot)}`,
    );
  const createResult = await invokeBridge("metawork.tasks.create", {
    workspaceId,
    expectedWorkspaceEpoch,
    expectedExecutionGeneration,
    expectedSkillCatalogRevision: catalogSnapshot.catalog.revision,
  });
  if (
    createResult !== null &&
    (createResult.accepted !== true ||
      createResult.reason !== null ||
      !isWireId(createResult.taskId) ||
      !isWireId(createResult.bindingEpoch))
  ) {
    throw new Error(
      `Task creation was not accepted truthfully: ${JSON.stringify(createResult)}`,
    );
  }
  const acceptedTaskId = createResult?.taskId ?? null;
  const createdTask = await poll(
    async () => {
      const current = await snapshot();
      return (
        current.tasks.find((item) =>
          acceptedTaskId
            ? item.id === acceptedTaskId
            : item.workspaceId === workspaceId,
        ) ?? null
      );
    },
    commandTimeoutMs,
    "Task creation",
  );
  const taskId = createdTask.id;
  const expectedBindingEpoch =
    createResult?.bindingEpoch ?? createdTask.binding?.epoch;
  if (!isWireId(taskId) || !isWireId(expectedBindingEpoch))
    throw new Error("Task creation omitted its authoritative identity");
  if (createdTask.binding?.epoch !== expectedBindingEpoch)
    throw new Error(
      `Task snapshot disagrees with the accepted binding epoch: ${JSON.stringify(createdTask.binding)}`,
    );
  const runResult = await invokeBridge("metawork.tasks.run", {
    taskId,
    expectedBindingEpoch,
    input: {
      kind: "skill",
      skillId: catalogSnapshot.skill.skillId,
      catalogRevision: catalogSnapshot.catalog.revision,
      argumentValues: ["fixture.txt"],
    },
  });
  if (
    runResult !== null &&
    (runResult.accepted !== true ||
      runResult.reason !== null ||
      runResult.taskId !== taskId ||
      !isWireId(runResult.runId))
  ) {
    throw new Error(
      `Run submission was not accepted truthfully: ${JSON.stringify(runResult)}`,
    );
  }
  const acceptedRunId = runResult?.runId ?? null;
  const submittedRun = await poll(
    async () => {
      const current = await snapshot();
      return (
        current.tasks
          .find((item) => item.id === taskId)
          ?.runs.find((item) =>
            acceptedRunId ? item.id === acceptedRunId : true,
          ) ?? null
      );
    },
    commandTimeoutMs,
    "Run submission",
  );
  const runId = submittedRun.id;
  if (!isWireId(runId)) throw new Error("Run submission omitted its identity");
  if (acceptedRunId !== null && submittedRun.id !== acceptedRunId)
    throw new Error("Run snapshot disagrees with the accepted Run identity");
  if (
    submittedRun.input?.kind !== "skill" ||
    submittedRun.input.skillId !== catalogSnapshot.skill.skillId ||
    submittedRun.input.catalogRevision !== catalogSnapshot.catalog.revision ||
    submittedRun.input.invocationName !== "review" ||
    submittedRun.input.displayName !== "Review" ||
    submittedRun.input.redacted !== false ||
    JSON.stringify(submittedRun.input.argumentValues) !==
      JSON.stringify(["fixture.txt"])
  )
    throw new Error(
      `Run history lost its typed Skill input: ${JSON.stringify(submittedRun.input)}`,
    );
  await captureVisual("running", 1320, 812);
  let reloadedRequest = null;
  let deliveryEmitsBeforeReload = null;
  let visualAttentionCaptured = false;
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
        if (!visualAttentionCaptured) {
          await captureVisual("attention", 1320, 812);
          if (process.platform === "win32")
            await captureVisual("attention-inspector", 960, 680);
          visualAttentionCaptured = true;
        }
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
            deliveryEmitsBeforeReload = productDeliveryEmitCount();
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
            answers: [["Yes"]],
          };
        } else {
          throw new Error(
            `unexpected AgentCore vertical UI request: ${JSON.stringify(pending)}`,
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
  await captureVisual("terminal", 1320, 812);
  await captureVisual("settings", 1320, 812, true);
  if (run.cause !== null || task.cause !== null)
    throw new Error(
      `completed run retained a Host cause: ${JSON.stringify(task)}`,
    );
  if (!run.assistant.includes("metawork agentcore vertical complete"))
    throw new Error("final assistant text was not projected");
  const activityOrders = [];
  for (const [name, evidence] of [
    ["Read", "agentcore-vertical-before"],
    ["Bash", "agentcore-vertical-bash-ok"],
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
  if (
    deliveryEmitsBeforeReload === null ||
    productDeliveryEmitCount() <= deliveryEmitsBeforeReload
  )
    throw new Error(
      "the real ProductDelivery path did not publish a revision after Renderer reload",
    );
  if (/metawork\.product_delivery\.emit.*main_thread=false/.test(output))
    throw new Error(
      "ProductDelivery emitted a Renderer revision off the main thread",
    );
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
  if (edited !== "agentcore-vertical-after\n")
    throw new Error(
      `Edit did not update the workspace: ${JSON.stringify(edited)}`,
    );
  if (provider.served !== responses.length)
    throw new Error(
      `provider served ${provider.served}/${responses.length} responses`,
    );
  if (provider.error) throw provider.error;
  const providerInput = JSON.stringify(provider.requests);
  if (
    !providerInput.includes("METAWORK_TYPED_SKILL_VERTICAL") ||
    !providerInput.includes("fixture.txt")
  )
    throw new Error("provider did not receive the materialized Skill input");
  if (providerInput.includes("/review"))
    throw new Error("raw slash syntax reached the AgentCore provider");

  await invokeBridge("metawork.tasks.rename", {
    taskId,
    title: "AgentCore vertical release audit",
  });
  let metadataSnapshot = await snapshot();
  let metadataTask = metadataSnapshot.tasks.find((item) => item.id === taskId);
  if (metadataTask?.title !== "AgentCore vertical release audit")
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

  if (process.platform === "win32") await probeWindowsChrome("close");
  else await invokeBridge("native-sdk.window.close", { label: "main" });
  const final = await withTimeout(exited, commandTimeoutMs, "app stop");
  if (final.code !== 0 || final.signal !== null)
    throw new Error(`app exited abnormally: ${JSON.stringify(final)}`);
  if (!/runtime\.event.*event="stop"/.test(output))
    throw new Error("normal runtime stop was not observed");

  process.stdout.write(
    "AgentCore desktop vertical passed: real typed Skill catalog/run, materialized arguments without raw slash, main-thread ProductDelivery, Read/Bash/Edit, permission UI, duplicate UI-response rejection, reload-safe AskUserQuestion resume, Task metadata lifecycle, async close.\n",
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
  const id = `agentcore-vertical-${Date.now()}-${Math.random().toString(16).slice(2)}`;
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

function productDeliveryEmitCount() {
  return (
    output.match(
      /metawork\.product_delivery\.emit event=metawork:workbench-changed main_thread=true/g,
    ) ?? []
  ).length;
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
    descriptor.bytes > 16 * 1024 * 1024 ||
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
  if (encoded.includes("metawork-agentcore-vertical-fixture-key"))
    throw new Error("Host provider credential reached the Renderer snapshot");
  const parsed = JSON.parse(encoded);
  if (
    typeof parsed.account !== "object" ||
    parsed.account === null ||
    Array.isArray(parsed.account) ||
    !Array.isArray(parsed.workspaces) ||
    !Array.isArray(parsed.tasks)
  )
    throw new Error("invalid Workbench snapshot");
  return parsed;
}

function isWireId(value) {
  return typeof value === "string" && /^[1-9][0-9]*$/.test(value);
}

function isOpaqueRevision(value) {
  return typeof value === "string" && value.length > 0;
}

async function automate(...args) {
  return execFileAsync(process.execPath, [native, "automate", ...args], {
    cwd: appCwd,
    timeout: commandTimeoutMs,
    maxBuffer: 1024 * 1024,
  });
}

async function captureVisual(
  name,
  width,
  height,
  openSettings = false,
  openSearch = false,
) {
  if (visualCaptureDir === null) return;
  if (process.platform === "darwin" && (openSettings || openSearch)) return;
  if (process.platform !== "darwin" && process.platform !== "win32") return;
  await mkdir(visualCaptureDir, { recursive: true });
  if (process.platform === "darwin") {
    await automate("reload");
    await waitForBridge();
  } else {
    await automate("resize", String(width), String(height));
  }
  await new Promise((resolve) => setTimeout(resolve, 750));
  if (process.platform === "darwin") {
    const { stdout } = await execFileAsync("/usr/bin/xcrun", [
      "swift",
      macosWindowLookupScript,
      String(app.pid),
    ]);
    const windowId = stdout.trim();
    if (!/^[1-9][0-9]*$/.test(windowId))
      throw new Error(`could not resolve MetaWork window id: ${windowId}`);
    await execFileAsync("/usr/sbin/screencapture", [
      "-x",
      "-l",
      windowId,
      path.join(visualCaptureDir, `${name}.png`),
    ]);
    return;
  }
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    visualCaptureScript,
    "-ProcessId",
    String(app.pid),
    "-OutputPath",
    path.join(visualCaptureDir, `${name}.png`),
    "-Width",
    String(width),
    "-Height",
    String(height),
  ];
  if (openSettings) args.push("-OpenSettings");
  if (selectFirstTask) args.push("-SelectFirstTask");
  if (openSearch) args.push("-OpenSearch");
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    args,
    { timeout: commandTimeoutMs, maxBuffer: 1024 * 1024 },
  );
}

async function probeWindowsChrome(mode) {
  if (process.platform !== "win32") return;
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      windowsChromeProbeScript,
      "-ProcessId",
      String(app.pid),
      "-Mode",
      mode,
    ],
    { timeout: commandTimeoutMs, maxBuffer: 1024 * 1024 },
  );
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

function createProvider(queue, responseDelayMs = 0) {
  let served = 0;
  let providerError = null;
  const requests = [];
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
          throw new Error(
            "provider request exceeded the AgentCore vertical fixture bound",
          );
        if (request.method !== "POST" || request.url !== "/v1/messages")
          throw new Error("AgentCore used an unexpected provider endpoint");
        if (
          request.headers.authorization !==
          "Bearer metawork-agentcore-vertical-fixture-key"
        )
          throw new Error("Host credential did not reach AgentCore correctly");
        const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        requests.push(payload);
        if (payload.model !== "metawork-agentcore-vertical-fixture-model")
          throw new Error("Host model did not reach AgentCore correctly");
        const body = queue[served];
        if (!body) throw new Error("unexpected extra provider request");
        served += 1;
        response.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "close",
        });
        if (responseDelayMs > 0)
          setTimeout(() => response.end(body), responseDelayMs);
        else response.end(body);
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
    get requests() {
      return requests;
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
