import { execFile, spawn } from "node:child_process";
import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const native = `${root}node_modules/.bin/native`;
const binary = `${root}zig-out/bin/metawork`;
const automationDir = `${root}.zig-cache/native-sdk-automation`;
const timeoutMs = 20_000;

await rm(automationDir, { recursive: true, force: true });

let output = "";
let exitState = null;
const app = spawn(binary, [], {
  cwd: root,
  env: {
    ...process.env,
    METAWORK_GATE0_AUTOMATION: "1",
    METAWORK_GATE5_FIXTURE: "1",
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
  await waitForOutput([
    /metawork\.gate5\.worker_wake off_main_thread=true/,
    /metawork\.gate5\.emit generation=1 items=2 .*main_thread=true/,
    /metawork\.gate5\.ack generation=1 session=1 run=1 sequence=1 main_thread=true/,
    /metawork\.gate5\.fetch generation=1 session=1 run=1 object=1 main_thread=true/,
    /metawork\.gate5\.ack generation=1 session=1 run=1 sequence=2 main_thread=true/,
  ]);

  const beforeReload = await automate("snapshot");
  assertSnapshot(beforeReload.stdout);
  await automate("reload");

  await waitForOutput([
    /metawork\.gate5\.emit generation=2 items=2 .*main_thread=true/,
    /metawork\.gate5\.ack generation=2 session=1 run=1 sequence=3 main_thread=true/,
    /metawork\.gate5\.fetch generation=2 session=1 run=1 object=2 main_thread=true/,
    /metawork\.gate5\.ack generation=2 session=1 run=1 sequence=4 main_thread=true/,
  ]);

  const afterReload = await automate("snapshot");
  assertSnapshot(afterReload.stdout);
  const closeRequest = JSON.stringify({
    id: "gate5-close",
    command: "native-sdk.window.close",
    payload: { label: "main" },
  });
  const close = await automate("bridge", closeRequest);
  if (!close.stdout.includes('"ok":true'))
    throw new Error(`main window close failed: ${close.stdout}`);

  const final = await withTimeout(exited, timeoutMs, "app stop");
  if (final.code !== 0 || final.signal !== null)
    throw new Error(`app exited abnormally: ${JSON.stringify(final)}`);
  if (!/runtime\.event.*event="stop"/.test(output))
    throw new Error("normal runtime stop was not observed");

  process.stdout.write(
    "Gate 5 macOS automation passed: worker wake, main-thread emit/fetch/ack, reload generation, clean stop.\n",
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
}

async function automate(...args) {
  return execFileAsync(native, ["automate", ...args], {
    cwd: root,
    timeout: timeoutMs,
    maxBuffer: 1024 * 1024,
  });
}

async function waitForOutput(patterns) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const missing = patterns.filter((pattern) => !pattern.test(output));
    if (missing.length === 0) return;
    if (exitState !== null)
      throw new Error(
        `app exited before evidence arrived; missing: ${missing.join(", ")}`,
      );
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const missing = patterns.filter((pattern) => !pattern.test(output));
  throw new Error(`timed out waiting for: ${missing.join(", ")}`);
}

function assertSnapshot(snapshot) {
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
