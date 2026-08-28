import { execFile, spawn } from "node:child_process";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { buildAutomationDebugArtifact } from "./build.mjs";

if (process.platform !== "win32")
  throw new Error("test-single-instance-windows requires Windows");

const execFileAsync = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appCwd = process.env.METAWORK_SINGLE_INSTANCE_APP_CWD
  ? path.resolve(process.env.METAWORK_SINGLE_INSTANCE_APP_CWD)
  : path.join(root, "zig-out", "bin");
const binary = path.join(appCwd, "metawork.exe");
const native = path.join(
  root,
  "node_modules",
  "@native-sdk",
  "cli",
  "bin",
  "native.js",
);
const windowProbe = path.join(
  root,
  "scripts",
  "probe-windows-window-chrome.ps1",
);
const automationDir = path.join(appCwd, ".zig-cache", "native-sdk-automation");
const timeoutMs = 20_000;
const outputLimit = 1024 * 1024;
const powershell =
  "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

if (process.env.METAWORK_SINGLE_INSTANCE_PREBUILT !== "1")
  await buildAutomationDebugArtifact(root);

const fixtureRoot = await mkdtemp(
  path.join(tmpdir(), "metawork-single-instance-"),
);
const canonicalFixtureRoot = await realpath(fixtureRoot);
const children = new Set();
const environment = {
  ...process.env,
  APPDATA: canonicalFixtureRoot,
  LOCALAPPDATA: canonicalFixtureRoot,
  METAWORK_AUTOMATION: "1",
  METAWORK_AUTOMATION_WORKSPACE: canonicalFixtureRoot,
};

await rm(automationDir, { recursive: true, force: true });

try {
  const contenders = Array.from({ length: 20 }, (_, index) =>
    startInstance([`--single-instance-contender=${index}`]),
  );
  let primary = await waitForPrimary(contenders);
  for (const contender of contenders) {
    if (contender === primary) continue;
    assertCleanSecondary(
      await withTimeout(contender.exited, timeoutMs, "concurrent Secondary"),
    );
  }
  assertAlive(primary, "concurrent Primary");

  await runWindowProbe(primary.child.pid, "close");
  await runSecondary(primary, ["--from-hidden-window"], canonicalFixtureRoot);
  await runWindowProbe(primary.child.pid, "activated");

  await runWindowProbe(primary.child.pid, "minimize");
  await runSecondary(primary, ["--from-minimized-window"], fixtureRoot);
  await runWindowProbe(primary.child.pid, "activated");

  if (!primary.child.kill()) throw new Error("failed to terminate Primary");
  await withTimeout(primary.exited, timeoutMs, "forced Primary termination");
  await rm(automationDir, { recursive: true, force: true });

  primary = startInstance(["--after-crash"]);
  await waitForOutput(primary, /metawork\.smoke\.event_ack sequence=1/u);
  await runSecondary(primary, ["--lease-recovered"], canonicalFixtureRoot);

  await execFileAsync(
    process.execPath,
    [native, "automate", "tray-action", "2"],
    {
      cwd: appCwd,
      timeout: timeoutMs,
      maxBuffer: outputLimit,
    },
  );
  const final = await withTimeout(primary.exited, timeoutMs, "clean shutdown");
  if (final.code !== 0 || final.signal !== null)
    throw new Error(
      `replacement Primary exited abnormally: ${JSON.stringify(final)}`,
    );
  if (!/runtime\.event.*event="stop"/u.test(primary.output()))
    throw new Error("clean Runtime stop was not observed");

  process.stdout.write(
    "Windows 20-process arbitration, hidden/minimized activation, argv/cwd handoff, crash recovery, and clean shutdown passed.\n",
  );
} catch (error) {
  for (const child of children)
    if (child.exitState() === null) process.stderr.write(child.output());
  throw error;
} finally {
  for (const child of children)
    if (child.exitState() === null) child.child.kill();
  await Promise.all(
    [...children].map((child) =>
      withTimeout(child.exited, 5_000, "app cleanup").catch(() => {}),
    ),
  );
  await rm(fixtureRoot, { recursive: true, force: true });
}

function startInstance(args = [], cwd = appCwd) {
  let output = "";
  let exitState = null;
  const child = spawn(binary, args, {
    cwd,
    env: environment,
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (const stream of [child.stdout, child.stderr]) {
    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
      output += chunk;
      if (output.length > outputLimit)
        output = output.slice(output.length - outputLimit);
    });
  }
  const exited = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      exitState = { code, signal };
      resolve(exitState);
    });
  });
  const instance = {
    child,
    exited,
    output: () => output,
    exitState: () => exitState,
  };
  children.add(instance);
  return instance;
}

async function waitForPrimary(instances) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const ready = instances.filter((instance) =>
      /metawork\.smoke\.event_ack sequence=1/u.test(instance.output()),
    );
    if (ready.length > 1)
      throw new Error(
        `multiple Primary processes reached Runtime readiness: ${ready.length}`,
      );
    if (ready.length === 1) return ready[0];
    if (instances.every((instance) => instance.exitState() !== null))
      throw new Error(
        "all contenders exited before a Primary reached readiness",
      );
    await delay(25);
  }
  throw new Error("concurrent Primary readiness timed out");
}

async function runSecondary(primary, args, cwd) {
  const secondary = startInstance(args, cwd);
  assertCleanSecondary(
    await withTimeout(secondary.exited, timeoutMs, "Secondary handoff"),
  );
  assertAlive(primary, "Primary after Secondary handoff");
}

function assertCleanSecondary(state) {
  if (state.code !== 0 || state.signal !== null)
    throw new Error(`Secondary exited abnormally: ${JSON.stringify(state)}`);
}

function assertAlive(instance, label) {
  if (instance.exitState() !== null)
    throw new Error(
      `${label} exited unexpectedly: ${JSON.stringify(instance.exitState())}`,
    );
}

async function runWindowProbe(processId, mode) {
  await execFileAsync(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      windowProbe,
      "-ProcessId",
      String(processId),
      "-Mode",
      mode,
    ],
    { timeout: timeoutMs, maxBuffer: outputLimit },
  );
}

async function waitForOutput(instance, pattern) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pattern.test(instance.output())) return;
    if (instance.exitState() !== null)
      throw new Error(
        `app exited before ${pattern}: ${JSON.stringify(instance.exitState())}`,
      );
    await delay(25);
  }
  throw new Error(`timed out waiting for ${pattern}`);
}

function withTimeout(promise, milliseconds, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${milliseconds}ms`)),
      milliseconds,
    );
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
