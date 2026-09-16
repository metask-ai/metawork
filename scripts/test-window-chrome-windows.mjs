import { execFile, spawn } from "node:child_process";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { buildAutomationDebugArtifact } from "./build.mjs";
import {
  allocateWebViewTestPort,
  connectTestWebView,
  probeTopResizePaint,
} from "./window-top-resize-paint.mjs";

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
const timeoutMs = 20_000;
const resizeSessionOnly = process.argv.includes("--resize-session-only");
const evidenceDir = process.env.METAWORK_WINDOW_CHROME_EVIDENCE_DIR;

// This harness owns the automation Debug artifact it drives; build before the
// fixture directory exists so a build failure leaves nothing to clean up.
await buildAutomationDebugArtifact(root);

const fixtureRoot = await mkdtemp(
  path.join(tmpdir(), "metawork-window-chrome-"),
);
const canonicalFixtureRoot = await realpath(fixtureRoot);
const debugPort = await allocateWebViewTestPort();

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
    WEBVIEW2_USER_DATA_FOLDER: path.join(canonicalFixtureRoot, "webview"),
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${debugPort} --remote-debugging-address=127.0.0.1`,
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
  // Keep this isolated window unobscured until the harness shuts it down.
  // Stationary paint checks must not raise or activate it after a DOM update.
  await runProbe("top-resize", ["-Direct", "-KeepTopmost"]);
  await runProbe("top-resize");
  await runProbe("top-lifecycle");
  await runProbe("top-resize", ["-Repeat", "3"]);
  await probeTopResizePaint({ port: debugPort, runProbe, evidenceDir });
  await execFileAsync(process.execPath, [native, "automate", "reload"], {
    cwd: appCwd,
    timeout: timeoutMs,
    maxBuffer: 1024 * 1024,
  });
  await waitForOutput(/metawork\.smoke\.event_ack sequence=2/);
  await waitForRendererChromeReady();
  await runProbe("top-resize", ["-Direct"]);
  await runProbe("top-resize", ["-AllMonitors"]);
  if (evidenceDir) {
    await execFileAsync(
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        path.join(root, "scripts", "capture-windows-window.ps1"),
        "-ProcessId",
        String(app.pid),
        "-OutputPath",
        path.join(evidenceDir, "top-resize.png"),
        "-Width",
        "900",
        "-Height",
        "620",
      ],
      { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
    );
  }
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
        "doubleclick",
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
  await runProbe("top-resize", ["-Direct"]);
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
      ? "Windows top-edge resize/cursors, native double click, sequence reset, paint/reload, resize session, controls, hide/reopen, and clean shutdown passed.\n"
      : "Windows top-edge resize/cursors, native double click, sequence reset, paint/reload, titlebar drag/double click, controls, hide/reopen, and clean shutdown passed.\n",
  );
} catch (error) {
  process.stderr.write(output);
  throw error;
} finally {
  if (exitState === null) app.kill("SIGTERM");
  await withTimeout(exited, 5_000, "app exit").catch(() => {});
  await rm(fixtureRoot, {
    recursive: true,
    force: true,
    maxRetries: 20,
    retryDelay: 200,
  });
}

async function runProbe(mode, extraArgs = []) {
  const result = await execFileAsync(
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
      mode,
      ...extraArgs,
    ],
    { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  process.stdout.write(result.stdout);
}

async function waitForRendererChromeReady() {
  const webview = await connectTestWebView(debugPort);
  try {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (
        await webview.evaluate(
          `document.documentElement.dataset.metaworkWindowChrome === "ready"`,
        )
      )
        return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("Renderer window chrome did not become ready");
  } finally {
    webview.close();
  }
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
