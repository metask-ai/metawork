import { execFile, spawn } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { buildAutomationDebugArtifact } from "./build.mjs";

if (process.platform !== "win32") {
  throw new Error("test-window-chrome-windows requires Windows");
}

const execFileAsync = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appCwd = process.env.METAWORK_WINDOW_CHROME_APP_CWD
  ? path.resolve(process.env.METAWORK_WINDOW_CHROME_APP_CWD)
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
const hitTestProbe = path.join(
  root,
  "scripts",
  "probe-windows-window-chrome.ps1",
);
const automationDir = path.join(appCwd, ".zig-cache", "native-sdk-automation");
const bridgeResponsePath = path.join(automationDir, "bridge-response.txt");
const timeoutMs = 20_000;
const resizeSessionOnly = process.argv.includes("--resize-session-only");

// This harness owns the automation Debug artifact it drives; build before the
// fixture directory exists so a build failure leaves nothing to clean up.
await buildAutomationDebugArtifact(root);

const fixtureRoot = await mkdtemp(
  path.join(tmpdir(), "metawork-window-chrome-"),
);
const canonicalFixtureRoot = await realpath(fixtureRoot);

await rm(automationDir, { recursive: true, force: true });

let output = "";
let exitState = null;
const waiters = new Set();
const app = spawn(binary, [], {
  cwd: appCwd,
  env: {
    ...process.env,
    APPDATA: canonicalFixtureRoot,
    LOCALAPPDATA: canonicalFixtureRoot,
    METAWORK_AUTOMATION: "1",
    METAWORK_AUTOMATION_WORKSPACE: canonicalFixtureRoot,
  },
  stdio: ["ignore", "pipe", "pipe"],
});

for (const stream of [app.stdout, app.stderr]) {
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => {
    output += chunk;
    for (const notify of waiters) notify();
  });
}

const exited = new Promise((resolve, reject) => {
  app.once("error", reject);
  app.once("exit", (code, signal) => {
    exitState = { code, signal };
    for (const notify of waiters) notify();
    resolve(exitState);
  });
});

try {
  const rendererChromeReady = waitForRendererChromeReady();
  await waitForOutput(/metawork\.smoke\.event_ack sequence=1/);
  await rendererChromeReady;
  if (!resizeSessionOnly) {
    await execFileAsync(
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        hitTestProbe,
        "-ProcessId",
        String(app.pid),
        "-Mode",
        "drag",
      ],
      { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
    );
  }
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      hitTestProbe,
      "-ProcessId",
      String(app.pid),
      "-Mode",
      "resize",
    ],
    { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      hitTestProbe,
      "-ProcessId",
      String(app.pid),
      "-Mode",
      "controls",
    ],
    { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      hitTestProbe,
      "-ProcessId",
      String(app.pid),
      "-Mode",
      "close",
    ],
    { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  await execFileAsync(
    process.execPath,
    [native, "automate", "tray-action", "1"],
    { cwd: appCwd, timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  await execFileAsync(
    process.execPath,
    [native, "automate", "tray-action", "2"],
    { cwd: appCwd, timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  const final = await withTimeout(exited, timeoutMs, "Runtime shutdown");
  if (final.code !== 0 || final.signal !== null)
    throw new Error(`app exited abnormally: ${JSON.stringify(final)}`);
  if (!/runtime\.event.*event="stop"/.test(output))
    throw new Error("normal Runtime stop was not observed");
  process.stdout.write(
    resizeSessionOnly
      ? "Windows resize session, Renderer controls, close-policy hide/reopen, and clean Runtime shutdown passed.\n"
      : "Windows Renderer controls, close-policy hide/reopen, ordinary drag, maximized drag restore, and clean Runtime shutdown passed.\n",
  );
} catch (error) {
  process.stderr.write(output);
  throw error;
} finally {
  if (exitState === null) app.kill("SIGTERM");
  await withTimeout(exited, 5_000, "app exit").catch(() => {});
  await rm(fixtureRoot, { recursive: true, force: true });
}

async function waitForRendererChromeReady() {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = JSON.parse(await readFile(bridgeResponsePath, "utf8"));
      if (
        response?.ok === true &&
        /^[1-9][0-9]*$/.test(response.result?.generation) &&
        Number.isFinite(response.result?.insets?.top)
      )
        return;
    } catch (error) {
      if (error?.code !== "ENOENT" && !(error instanceof SyntaxError))
        throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Renderer window chrome did not reach a synchronized state");
}

function waitForOutput(pattern) {
  return new Promise((resolve, reject) => {
    let timer;
    const check = () => {
      if (pattern.test(output)) {
        clearTimeout(timer);
        waiters.delete(check);
        resolve();
      } else if (exitState !== null) {
        clearTimeout(timer);
        waiters.delete(check);
        reject(
          new Error(
            `app exited before ${pattern}: ${JSON.stringify(exitState)}`,
          ),
        );
      }
    };
    timer = setTimeout(() => {
      waiters.delete(check);
      reject(new Error(`timed out waiting for ${pattern}`));
    }, timeoutMs);
    waiters.add(check);
    check();
  });
}

function withTimeout(promise, milliseconds, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(
        () => reject(new Error(`${label} timed out after ${milliseconds}ms`)),
        milliseconds,
      ),
    ),
  ]);
}
