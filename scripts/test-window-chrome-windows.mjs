import { execFile, spawn } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

if (process.platform !== "win32") {
  throw new Error("test-window-chrome-windows requires Windows");
}

const execFileAsync = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appCwd = path.join(root, "zig-out", "bin");
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
  await waitForOutput(/metawork\.smoke\.event_ack sequence=1/);
  await waitForRendererChromeReady();
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
  const connected = await invokeBridge(
    "window-chrome-connect",
    "metawork.host.windowChrome.connect",
    {},
  );
  if (
    !/^[1-9][0-9]*$/.test(connected.generation) ||
    !Number.isFinite(connected.insets?.top) ||
    connected.insets.top <= 0 ||
    !Number.isFinite(connected.buttons?.width) ||
    connected.buttons.width <= 0
  ) {
    throw new Error(
      `window chrome returned invalid native geometry: ${JSON.stringify(connected)}`,
    );
  }
  const dragHeight = Math.min(connected.insets.top, 30);
  const dragWidth = Math.min(600, connected.buttons.x);
  if (dragHeight <= 0 || dragWidth < 300)
    throw new Error(
      `window chrome cannot host the probe regions: ${JSON.stringify(connected)}`,
    );
  const synced = await invokeBridge(
    "window-chrome-sync",
    "metawork.host.windowChrome.sync",
    {
      generation: connected.generation,
      viewportWidth: Math.max(
        800,
        connected.buttons.x + connected.buttons.width,
      ),
      viewportHeight: 600,
      regions: [
        {
          x: 0,
          y: 0,
          width: dragWidth,
          height: dragHeight,
          exclusion: false,
        },
        {
          x: 20,
          y: 0,
          width: 80,
          height: dragHeight,
          exclusion: true,
        },
      ],
    },
  );
  if (synced.generation !== connected.generation)
    throw new Error(
      `window chrome sync changed generation: ${synced.generation}`,
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
      "hit-test",
      "-DragX",
      "300",
      "-DragY",
      String(Math.max(1, Math.floor(dragHeight / 2))),
      "-ExcludedX",
      "40",
      "-ExcludedY",
      String(Math.max(1, Math.floor(dragHeight / 2))),
    ],
    { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  await invokeBridge(
    "window-chrome-disconnect",
    "metawork.host.windowChrome.disconnect",
    { generation: connected.generation },
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
      "hit-test-cleared",
      "-DragX",
      "300",
      "-DragY",
      String(Math.max(1, Math.floor(dragHeight / 2))),
      "-ExcludedX",
      "40",
      "-ExcludedY",
      String(Math.max(1, Math.floor(dragHeight / 2))),
    ],
    { timeout: timeoutMs, maxBuffer: 1024 * 1024 },
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
    "Windows Renderer controls, close-policy hide/reopen, drag-region binding, and clean Runtime shutdown passed.\n",
  );
} catch (error) {
  process.stderr.write(output);
  throw error;
} finally {
  if (exitState === null) app.kill("SIGTERM");
  await withTimeout(exited, 5_000, "app exit").catch(() => {});
  await rm(fixtureRoot, { recursive: true, force: true });
}

async function invokeBridge(id, command, payload) {
  const request = JSON.stringify({ id, command, payload });
  const { stdout } = await execFileAsync(
    process.execPath,
    [native, "automate", "bridge", request],
    { cwd: appCwd, timeout: timeoutMs, maxBuffer: 1024 * 1024 },
  );
  const response = stdout
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
    .find((value) => value?.id === id);
  if (!response) throw new Error(`${command} returned no response`);
  if (!response.ok)
    throw new Error(`${command} failed: ${JSON.stringify(response.error)}`);
  return response.result;
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
