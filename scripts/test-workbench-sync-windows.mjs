import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { buildAutomationDebugArtifact, nativeCli } from "./build.mjs";
import { allocateWebViewTestPort } from "./window-top-resize-paint.mjs";
import { probeWorkbenchSyncRecovery } from "./workbench-sync-vertical.mjs";
if (process.platform !== "win32")
  throw new Error("Workbench sync desktop probe requires Windows");
const root = resolve(import.meta.dirname, "..");
await buildAutomationDebugArtifact(root);
const fixture = await mkdtemp(join(tmpdir(), "metawork-sync-probe-"));
const home = join(fixture, "home");
await mkdir(home);
const work = join(fixture, "work");
await mkdir(work);
const port = await allocateWebViewTestPort();
const cwd = join(root, "zig-out", "bin");
const app = spawn(join(cwd, "metawork.exe"), [], {
  cwd,
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
  await probeWorkbenchSyncRecovery(
    port,
    join(root, ".zig-cache", "workbench-sync-evidence"),
  );
  await promisify(execFile)(
    process.execPath,
    [nativeCli, "automate", "tray-action", "2"],
    { cwd, timeout: 10000 },
  );
  const final = await exited;
  if (final.code !== 0) throw Error(JSON.stringify(final));
  console.log("Isolated sync probe passed; normal Host shutdown");
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
