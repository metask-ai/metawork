import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { buildAutomationDebugArtifact, nativeCli } from "./build.mjs";
import { allocateWebViewTestPort } from "./window-top-resize-paint.mjs";
import { probeOfficeManagement } from "./office-management-vertical.mjs";

if (process.platform !== "win32")
  throw Error("Office desktop probe requires Windows");
const root = resolve(import.meta.dirname, "..");
await buildAutomationDebugArtifact(root);
const fixture = await mkdtemp(join(tmpdir(), "metawork-office-ui-"));
const home = join(fixture, "home"),
  work = join(fixture, "work");
await mkdir(home);
await mkdir(work);
const port = await allocateWebViewTestPort();
const cwd = join(root, "zig-out", "bin");
const app = spawn(join(cwd, "metawork.exe"), [], {
  cwd,
  windowsHide: true,
  env: {
    ...process.env,
    APPDATA: home,
    LOCALAPPDATA: home,
    METAWORK_AUTOMATION: "1",
    METAWORK_AUTOMATION_WORKSPACE: work,
    WEBVIEW2_USER_DATA_FOLDER: join(home, "webview"),
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1`,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let output = "";
app.stdout.on("data", (c) => (output += c));
app.stderr.on("data", (c) => (output += c));
const exited = new Promise((resolve, reject) => {
  app.once("exit", (code, signal) => resolve({ code, signal }));
  app.once("error", reject);
});
try {
  const result = await probeOfficeManagement(
    port,
    join(root, ".zig-cache", "office-management-evidence"),
  );
  await promisify(execFile)(
    process.execPath,
    [nativeCli, "automate", "tray-action", "2"],
    { cwd, timeout: 10000, windowsHide: true },
  );
  const final = await exited;
  if (final.code !== 0) throw Error(JSON.stringify(final));
  console.log(
    `Office management desktop probe passed: ${result.cases.length} viewport/theme cases; normal Host shutdown`,
  );
} catch (error) {
  console.error(output);
  throw error;
} finally {
  if (app.exitCode === null) {
    app.kill();
    await exited;
  }
  const target = resolve(fixture);
  if (!target.startsWith(resolve(tmpdir()) + "\\"))
    throw Error("fixture cleanup outside temp root");
  await rm(target, {
    recursive: true,
    force: true,
    maxRetries: 5,
    retryDelay: 100,
  });
}
