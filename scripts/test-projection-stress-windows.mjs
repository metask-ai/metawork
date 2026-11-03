import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { buildAutomationDebugArtifact, nativeCli } from "./build.mjs";
import {
  allocateWebViewTestPort,
  connectTestWebView,
} from "./window-top-resize-paint.mjs";
import { invokeWebViewBridge } from "./webview-bridge-probe.mjs";
import { fetchWorkbenchSnapshot } from "../frontend/src/bridge/snapshot/snapshot-client.ts";
import { initialViewScope } from "../frontend/src/bridge/contracts.ts";
import { protocolTextSse } from "../tests/fixtures/provider_protocol.mjs";

// Real Windows WebView -> Bridge -> Product -> canonical staged AgentCore.
// Only the loopback Provider is scripted. No persisted state is fabricated.
if (process.platform !== "win32")
  throw new Error("Projection stress requires Windows");
const root = resolve(import.meta.dirname, "..");
const appSource = await readFile(join(root, "src", "app.zig"), "utf8");
const configuredConcurrency = Number(
  appSource.match(/const host_worker_count = (\d+);/)?.[1],
);
assert.ok(
  Number.isSafeInteger(configuredConcurrency) && configuredConcurrency > 0,
);
// Keep the original aggregate text rate while exercising every production worker.
// The observed concurrent Provider streams below, rather than this source read,
// prove that the real execution path reached the configured limit.
const liveChunkRepetitions = Math.max(
  1,
  Math.floor(16 / configuredConcurrency),
);
const historicalRuns = configuredConcurrency + 5;
await buildAutomationDebugArtifact(root);
const fixture = await mkdtemp(join(tmpdir(), "metawork-projection-stress-"));
const home = join(fixture, "home");
const work = join(fixture, "work");
await mkdir(home);
await mkdir(work);
const evidenceDir = join(root, ".zig-cache", "projection-stress-evidence");
await mkdir(evidenceDir, { recursive: true });
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const streams = [];
let finishLive = false;
let liveActive = 0;
let peakLive = 0;
let providerError;
const provider = createServer(async (request, response) => {
  let tracked;
  try {
    assert.equal(request.url, "/v1/messages");
    const parts = [];
    let bytes = 0;
    for await (const part of request) {
      bytes += part.length;
      assert.ok(bytes <= 2 * 1024 * 1024);
      parts.push(part);
    }
    const body = JSON.parse(Buffer.concat(parts).toString("utf8"));
    assert.equal(body.model, "claude-sonnet-4-20250514");
    if (body.stream !== true) {
      response.writeHead(200, {
        "content-type": "application/json",
        connection: "close",
      });
      response.end(
        JSON.stringify({
          type: "message",
          content: [{ type: "text", text: "Projection stress" }],
          stop_reason: "end_turn",
          usage: { input_tokens: 1, output_tokens: 1 },
        }),
      );
      return;
    }
    assert.ok(
      request.headers.authorization ===
        "Bearer metawork-agentcore-vertical-fixture-key",
      "Provider fixture credential mismatch",
    );
    const input = JSON.stringify(body.messages.at(-1).content);
    const marker = input.match(/PROJECTION_(HISTORY|LIVE)_\d+_\d+/)?.[0];
    assert.ok(marker, "Provider received an unexpected Run");
    const live = marker.includes("_LIVE_");
    tracked = { marker, live, text: "", terminalSent: false, closed: false };
    streams.push(tracked);
    if (live) peakLive = Math.max(peakLive, ++liveActive);
    response.on("close", () => {
      tracked.closed = true;
    });
    response.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "close",
    });
    response.flushHeaders();
    response.socket?.setNoDelay(true);
    const frames = protocolTextSse("anthropic", "placeholder")
      .split("\n\n")
      .filter(Boolean);
    for (const frame of frames.slice(0, 2)) response.write(frame + "\n\n");
    const chunk = live
      ? "streaming-output ".repeat(liveChunkRepetitions)
      : "retained-history ".repeat(128);
    const count = live ? 800 : 6;
    for (let index = 0; index < count && !response.destroyed; index++) {
      tracked.text += chunk;
      response.write(
        `event: content_block_delta\ndata: ${JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: chunk } })}\n\n`,
      );
      if (live) {
        if (finishLive) break;
        await delay(10);
      }
    }
    while (live && !finishLive && !response.destroyed) {
      response.write(": retained live stream\n\n");
      await delay(40);
    }
    if (!response.destroyed) {
      for (const frame of frames.slice(3)) response.write(frame + "\n\n");
      tracked.terminalSent = true;
      response.end();
    }
  } catch (error) {
    providerError ??= error;
    if (!response.headersSent) response.writeHead(400);
    response.end("invalid projection stress request");
  } finally {
    if (tracked?.live) liveActive--;
  }
});
await new Promise((resolve, reject) => {
  provider.once("error", reject);
  provider.listen(0, "127.0.0.1", resolve);
});
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
    METAWORK_AGENTCORE_VERTICAL_PROVIDER_BASE_URL: `http://127.0.0.1:${provider.address().port}/v1/messages`,
    WEBVIEW2_USER_DATA_FOLDER: join(home, "webview"),
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1`,
  },
  stdio: ["ignore", "pipe", "pipe"],
  windowsHide: true,
});
let output = "";
app.stdout.on("data", (data) => {
  output += data;
});
app.stderr.on("data", (data) => {
  output += data;
});
let exitState;
const exited = new Promise((resolve, reject) => {
  app.once("error", reject);
  app.once("exit", (code, signal) => {
    exitState = { code, signal };
    resolve(exitState);
  });
});
let webview;
let failureRead;
async function until(operation, label, timeout = 30000) {
  const deadline = Date.now() + timeout;
  let lastError;
  do {
    if (providerError) throw providerError;
    if (exitState)
      throw new Error(
        `App exited during ${label}: ${JSON.stringify(exitState)}`,
      );
    try {
      const result = await operation();
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await delay(40);
  } while (Date.now() < deadline);
  throw new Error(`Projection stress timed out: ${label}`, {
    cause: lastError,
  });
}
const tasks = [];
let probeReadRetries = 0;
try {
  webview = await connectTestWebView(port, { requestTimeoutMs: 15000 });
  const invoke = (command, payload) =>
    invokeWebViewBridge(webview, command, payload);
  // Typed probes are restricted to setup and settled observations. During the
  // pressure interval only the mounted Renderer reads the Product data plane.
  const read = async (scope = initialViewScope) => {
    const deadline = Date.now() + 30_000;
    for (;;) {
      try {
        return await fetchWorkbenchSnapshot(invoke, scope);
      } catch (error) {
        if (
          error.bridgeResponseError?.code !== "handler_failed" ||
          error.bridgeResponseError?.message !== "StaleSnapshot" ||
          Date.now() >= deadline
        )
          throw error;
        // Read-only setup/settled probes can race the mounted Renderer.
        // A replacement invalidates the whole read; never retry product commands.
        probeReadRetries += 1;
        await delay(40);
      }
    }
  };
  failureRead = read;
  const current = await until(async () => {
    const view = await read();
    return view.newTaskAdmission.available ? view : null;
  }, "initial execution admission");
  await webview.send("Page.bringToFront");
  await webview.send("Emulation.setFocusEmulationEnabled", { enabled: true });
  const chosen = await invoke("metawork.workspaces.choose", {});
  assert.equal(chosen.selected, true);
  const workspace = await until(
    async () =>
      (await read()).workspaces.find((item) => item.id === chosen.workspaceId),
    "authorized Workspace",
  );
  for (let index = 0; index < configuredConcurrency; index++) {
    const modelSnapshot = await read();
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId: workspace.id,
        expectedWorkspaceEpoch: workspace.epoch,
      },

      modelSelection: fixtureModelSelection(modelSnapshot),
      expectedSkillCatalogRevision: null,
      expectedSkillSelectionRevision: null,
      approvalMode: "manual",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    tasks.push(created.taskId);
    await invoke("metawork.tasks.rename", {
      taskId: created.taskId,
      title: `Projection stress ${index + 1}`,
    });
  }
  async function selectTask(index) {
    const id = tasks[index];
    await until(
      () =>
        webview.evaluate(
          `(() => { const row=[...document.querySelectorAll('.task-list-item')].find(item=>item.dataset.taskId===${JSON.stringify(id)}); if(!row) return false; if(row.getAttribute('aria-current')!=='page') {row.click();return false;} return document.querySelector('.composer-input')!==null || document.querySelector('[contenteditable="true"]')!==null || document.querySelector('textarea')!==null; })()`,
        ),
      `Task ${index + 1} selected`,
    );
  }
  async function start(index, number, live) {
    const marker = `PROJECTION_${live ? "LIVE" : "HISTORY"}_${index}_${number}`;
    const result = await invoke("metawork.tasks.sendInput", {
      operationId: marker,
      taskId: tasks[index],
      input: { kind: "text", text: marker },
    });
    assert.equal(result.outcome, "accepted", JSON.stringify(result));
    return marker;
  }
  // Six prior Runs make the current page load older history; each other Task
  // retains one. Reserve headroom for Host-owned buffer capacities, live
  // provisional/final output and text duplication; final UTF-8 size alone is
  // not the shared projection allocation budget.
  for (let index = 0; index < configuredConcurrency; index++) {
    await selectTask(index);
    for (let number = 0; number < (index === 0 ? 6 : 1); number++) {
      const marker = await start(index, number, false);
      await until(async () => {
        const view = await read({ ...initialViewScope, taskId: tasks[index] });
        const task = view.tasks[0];
        const run = task?.runs.find(
          (run) => run.submission?.operationId === marker,
        );
        if (!run?.terminal || task.activeOperation !== null) return null;
        assert.equal(run.terminal.outcome, "completed");
        assert.equal(
          run.output.response,
          streams.find((stream) => stream.marker === marker).text,
        );
        return true;
      }, `historical Run ${marker}`);
    }
  }
  console.log(
    `Projection stress: ${historicalRuns} real historical Runs retained.`,
  );
  await webview.evaluate(`(() => {
    const state=window.__projectionPressure={reads:[],preparations:0,frames:[],longTasks:[],running:true};
    const transport=window.chrome.webview; const post=transport.postMessage;
    state.post=post;
    transport.postMessage=function(message) {
      const envelope=typeof message==='string'?JSON.parse(message):message;
      if(envelope.command==='metawork.workbench.snapshot') {if ('preparingSnapshotId' in envelope.payload) state.preparations++; else state.reads.push({taskId:envelope.payload.taskId,beforeRunId:envelope.payload.beforeRunId,management:envelope.payload.management,at:performance.now()});}
      return post.call(this,message);
    };
    state.observer=new PerformanceObserver(list=>{for(const item of list.getEntries()) if(state.longTasks.length<2000) state.longTasks.push(item.duration);});
    state.observer.observe({type:'longtask',buffered:false});
    let previous=performance.now(); const frame=now=>{if(!state.running)return;if(state.frames.length<10000) state.frames.push(now-previous);previous=now;requestAnimationFrame(frame);};requestAnimationFrame(frame);
  })()`);
  const liveMarkers = [];
  for (let index = 0; index < configuredConcurrency; index++)
    liveMarkers.push(await start(index, 10, true));
  await until(
    () => liveActive === configuredConcurrency,
    `${configuredConcurrency} simultaneous real Provider streams`,
  );
  await selectTask(0);
  await until(
    () =>
      webview.evaluate(
        `(() => {const viewport=document.querySelector('.ai-conversation-viewport');if(!viewport||document.querySelector('.conversation-history-loading'))return false;viewport.scrollTop=0;viewport.dispatchEvent(new WheelEvent('wheel',{deltaY:-120,bubbles:true}));return true;})()`,
      ),
    "load earlier history at the configured concurrency limit",
  );
  await until(
    () =>
      webview.evaluate(
        `document.querySelectorAll('[data-run-id]').length >= 7`,
      ),
    "all seven selected Task Runs are rendered",
  );
  for (let index = 1; index < configuredConcurrency; index++)
    await selectTask(index);
  await selectTask(0);
  await until(
    () =>
      webview.evaluate(
        `!!document.querySelector('.composer-stop:not(:disabled)')`,
      ),
    "Stop control ready during output",
  );
  const stopAt = performance.now();
  await webview.evaluate(
    `document.querySelector('.composer-stop:not(:disabled)').click()`,
  );
  await until(
    () => streams.find((item) => item.marker === liveMarkers[0])?.closed,
    "Stop closes the selected stream",
  );
  const stopMs = performance.now() - stopAt;
  async function openManagement(pattern, ready, label) {
    await webview.evaluate(
      `(() => {const button=[...document.querySelectorAll('.sidebar-capability')].find(item=>${pattern}.test(item.textContent));if(!button)throw Error('missing management button');button.click();})()`,
    );
    await until(() => webview.evaluate(ready), label);
    assert.equal(
      liveActive,
      configuredConcurrency - 1,
      "unselected Runs must remain active during management",
    );
  }
  await openManagement(
    "/Skills|技能/",
    `!!document.querySelector('.skill-header-actions button:not(:disabled)')`,
    "Skills mounted",
  );
  await webview.evaluate(
    `document.querySelector('.skill-header-actions button:not(:disabled)').click()`,
  );
  await until(
    () =>
      webview.evaluate(
        `!!document.querySelector('.skill-header-actions button:not(:disabled)')`,
      ),
    "asynchronous Skills refresh completed",
  );
  await openManagement(
    "/MCP/",
    `!!document.querySelector('.mcp-page #mcp-title')`,
    "MCP mounted",
  );
  await openManagement(
    "/Skills|技能/",
    `!!document.querySelector('.skill-header-actions button:not(:disabled)')`,
    "Skills remounted",
  );
  const connected = await invoke("metawork.events.connect", {
    contractId: "metawork.renderer-bridge",
    contractRevision: 1,
  });
  assert.equal(connected.accepted, true);
  assert.equal(
    (
      await invoke("metawork.events.disconnect", {
        generation: connected.generation,
      })
    ).detached,
    true,
  );
  await until(
    () =>
      webview.evaluate(`(() => {
      if (document.querySelector('.commandbar-alert:not([data-recovering="true"])')) return true;
      const refresh = document.querySelector('.skill-header-actions button:not(:disabled)');
      if (!refresh) return false;
      refresh.click();
      return true;
    })()`),
    "withdrawal observed or one explicit refresh demand submitted",
  );
  await until(
    () =>
      webview.evaluate(
        `!!document.querySelector('.commandbar-alert:not([data-recovering="true"])')`,
      ),
    "real Host withdrawal observed while Runs execute",
  );
  await webview.evaluate(
    `(() => {const notice=document.querySelector('.commandbar-alert');notice.open=true;notice.querySelector('.commandbar-alert-content button').click();})()`,
  );
  await until(
    () =>
      webview.evaluate(
        `!document.querySelector('.commandbar-alert') && !!document.querySelector('.skill-header-actions button:not(:disabled)')`,
      ),
    "connection recovered during execution",
  );
  assert.equal(liveActive, configuredConcurrency - 1);
  finishLive = true;
  await until(
    () => liveActive === 0,
    "all remaining Provider streams complete",
  );
  const final = [];
  for (let index = 0; index < configuredConcurrency; index++) {
    const task = await until(
      async () => {
        const task = (await read({ ...initialViewScope, taskId: tasks[index] }))
          .tasks[0];
        return task?.activeOperation === null && task.runs.at(-1)?.terminal
          ? task
          : null;
      },
      `final Task ${index + 1} terminal`,
    );
    const run = task.runs.at(-1);
    assert.equal(run.terminal.outcome, index === 0 ? "cancelled" : "completed");
    if (index !== 0)
      assert.equal(
        run.output.response,
        streams.find((item) => item.marker === liveMarkers[index]).text,
      );
    final.push({
      taskId: task.id,
      terminal: run.terminal.outcome,
      bytes: Buffer.byteLength(run.output.response),
    });
  }
  const browser = await webview.evaluate(
    `(() => {const s=window.__projectionPressure;s.running=false;s.observer.disconnect();window.chrome.webview.postMessage=s.post;return {reads:s.reads,preparations:s.preparations,frames:s.frames,longTasks:s.longTasks};})()`,
  );
  assert.ok(browser.reads.some((read) => read.beforeRunId !== null));
  assert.ok(browser.reads.some((read) => read.management === "skills"));
  assert.ok(browser.reads.some((read) => read.management === "mcp"));
  assert.equal(peakLive, configuredConcurrency);
  assert.ok(
    !output.includes("EventQueueTimeout") &&
      !output.includes("EventPumpOverflow"),
    "event pump failed under pressure",
  );
  const evidence = {
    configuredConcurrency,
    peakLive,
    historicalRuns,
    probeReadRetries,
    stopMs,
    final,
    browser,
    stagedSourceGeneration:
      fixtureModelSelection(current).expectedSourceGeneration,
  };
  await writeFile(
    join(evidenceDir, "projection-stress.json"),
    JSON.stringify(evidence, null, 2),
  );
  await promisify(execFile)(
    process.execPath,
    [nativeCli, "automate", "tray-action", "2"],
    { cwd, timeout: 10000 },
  );
  const result = await Promise.race([
    exited,
    delay(15000).then(() => {
      throw Error("Host shutdown timed out");
    }),
  ]);
  assert.equal(result.code, 0);
  console.log(
    `Projection stress passed: concurrency=${peakLive}, historicalRuns=${historicalRuns}, stopMs=${stopMs.toFixed(1)}, scopedReads=${browser.reads.length}`,
  );
} catch (error) {
  await writeFile(join(evidenceDir, "host.log"), output);
  const state = {
    liveActive,
    streams: streams.map(({ marker, live, terminalSent, closed, text }) => ({
      marker,
      live,
      terminalSent,
      closed,
      bytes: text.length,
    })),
    tasks: [],
  };
  if (failureRead)
    for (const id of tasks) {
      try {
        const task = (await failureRead({ ...initialViewScope, taskId: id }))
          .tasks[0];
        state.tasks.push({
          id,
          activeOperation: task?.activeOperation,
          runs: task?.runs.map((run) => ({
            id: run.id,
            phase: run.phase,
            terminal: run.terminal,
            bytes: run.output.response.length,
            provisionalBytes: run.output.provisional.length,
          })),
        });
      } catch (error) {
        state.tasks.push({ id, error: String(error) });
      }
    }
  await writeFile(
    join(evidenceDir, "failure-state.json"),
    JSON.stringify(state, null, 2),
  );
  if (webview)
    await writeFile(
      join(evidenceDir, "failure-dom.txt"),
      String(
        await webview
          .evaluate("document.body.innerText")
          .catch(() => "unavailable"),
      ),
    );
  throw error;
} finally {
  finishLive = true;
  webview?.close();
  provider.closeAllConnections();
  await new Promise((resolve) => provider.close(resolve));
  if (app.exitCode === null) {
    app.kill();
    await exited;
  }
  const target = resolve(fixture);
  assert.ok(
    target.startsWith(resolve(tmpdir()) + "\\") &&
      target.includes("metawork-projection-stress-"),
  );
  await rm(target, {
    recursive: true,
    force: true,
    maxRetries: 5,
    retryDelay: 100,
  });
}
