import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

function zigFiles(directory) {
  return readdirSync(new URL(directory, root), { withFileTypes: true }).flatMap(
    (entry) => {
      const path = join(directory, entry.name).replaceAll("\\", "/");
      if (entry.isDirectory()) return zigFiles(`${path}/`);
      return entry.isFile() && entry.name.endsWith(".zig") ? [path] : [];
    },
  );
}

function assertNoImports(files, forbidden) {
  for (const file of files) {
    const source = read(file);
    for (const name of forbidden) {
      assert.doesNotMatch(
        source,
        new RegExp(`@import\\(\\"${name}\\"\\)`),
        `${file} imports forbidden module ${name}`,
      );
    }
  }
}

test("module roots and Agent directory use product semantics", () => {
  for (const path of [
    "src/app.zig",
    "src/agent.zig",
    "src/workbench.zig",
    "src/bridge.zig",
  ]) {
    assert.equal(existsSync(new URL(path, root)), true, `${path} must exist`);
  }
  assert.equal(existsSync(new URL("src/agentcore.zig", root)), false);
  assert.equal(existsSync(new URL("src/agentcore/", root)), false);
});

test("main only enters the named App module", () => {
  const source = read("src/main.zig");
  assert.match(source, /@import\("metawork_app"\)/);
  assert.doesNotMatch(
    source,
    /@import\("(?:metawork_agent|metawork_workbench|metawork_bridge)"\)/,
  );
});

test("App consumes named public module roots", () => {
  const source = read("src/app.zig");
  for (const name of [
    "metawork_agent",
    "metawork_workbench",
    "metawork_bridge",
  ]) {
    assert.match(source, new RegExp(`@import\\(\\"${name}\\"\\)`));
  }
  assert.doesNotMatch(source, /@import\("(?:agent|workbench|bridge)\//);
  assert.doesNotMatch(source, /@import\("bridge\.zig"\)/);
});

test("public module roots do not re-export implementation modules wholesale", () => {
  for (const file of ["src/agent.zig", "src/workbench.zig", "src/bridge.zig"]) {
    assert.doesNotMatch(
      read(file),
      /pub const \w+\s*=\s*@import\(/,
      `${file} exposes an implementation module`,
    );
  }
});

test("lower layers cannot reach composition or transport internals", () => {
  assertNoImports(zigFiles("src/agent/"), [
    "metawork_app",
    "metawork_workbench",
    "metawork_bridge",
  ]);
  assertNoImports(zigFiles("src/workbench/"), [
    "metawork_app",
    "metawork_bridge",
  ]);
});

test("only Agent implementation imports the AgentCore SDK", () => {
  const forbidden = zigFiles("src/").filter(
    (file) => file !== "src/agent.zig" && !file.startsWith("src/agent/"),
  );
  assertNoImports(forbidden, ["metacodes_agentcore"]);

  const build = read("build.zig");
  assert.equal(
    [...build.matchAll(/\.addImport\("metacodes_agentcore", sdk\)/g)].length,
    3,
    "only event_sink, event_pump, and session may receive the SDK module",
  );

  const agentRoot = read("src/agent.zig");
  assert.match(agentRoot, /pub const OwnedCoreEvent/);
  assert.doesNotMatch(agentRoot, /EventEnvelope/);
  const workbench = read("src/workbench/projection.zig");
  assert.match(workbench, /lifecycle\.OwnedCoreEvent/);
  const bridgeHandlers = read("src/bridge/handlers.zig");
  assert.match(bridgeHandlers, /pub const PermissionChoice = enum/);
});

test("build graph registers the four named module boundaries", () => {
  const source = read("build.zig");
  for (const name of [
    "metawork_app",
    "metawork_agent",
    "metawork_workbench",
    "metawork_bridge",
  ]) {
    assert.match(source, new RegExp(`addImport\\(\\"${name}\\"`));
  }
  assert.doesNotMatch(source, /src\/agentcore(?:\/|\.zig)/);
});

test("canonical notification and Renderer transport failures stay isolated", () => {
  const agent = read("src/agent/session.zig");
  assert.match(agent, /pub const EventReadyNotification = enum/);
  for (const outcome of ["scheduled", "already_pending", "unavailable"]) {
    assert.match(agent, new RegExp(`\\b${outcome}\\b`));
  }
  assert.match(agent, /pub fn notifyWithRetry/);
  assert.match(agent, /event_ready_retry_interval/);
  assert.match(agent, /event_ready_timeout/);
  assert.doesNotMatch(
    agent,
    /bridge_pipeline_failure|notifyMainLoop|metawork_bridge/,
  );

  const app = read("src/app.zig");
  assert.doesNotMatch(app, /bridge_pipeline_failure/);
  assert.match(app, /decideTransportFailure/);
  assert.match(app, /agent_event_wake_pending\.swap\(true, \.acq_rel\)/);
  const clearWake = app.indexOf(
    "self.agent_event_wake_pending.store(false, .release);",
  );
  const drainEvents = app.indexOf("while (agent_runtime.takeEvent())");
  assert.ok(clearWake >= 0 && clearWake < drainEvents);
  const stopIngress = app.indexOf("self.stopBridgeIngress();");
  const quiesceCallbacks = app.indexOf("self.quiesceBridgeCallbacks();");
  const detachWorkbench = app.indexOf("self.detachWorkbench();");
  assert.ok(stopIngress >= 0 && stopIngress < quiesceCallbacks);
  assert.ok(quiesceCallbacks < detachWorkbench);

  const delivery = read("src/bridge/delivery.zig");
  assert.match(delivery, /pub fn deinitOwnedBuffers/);
});

test("Workbench owns queue and worker lifecycle", () => {
  const agent = read("src/agent/session.zig");
  assert.doesNotMatch(
    agent,
    /pub const (?:Scheduler|ScheduledRun)|enqueue_fn|shutdown_fn|deinit_fn|\.scheduler/,
  );

  const executor = read("src/workbench/executor.zig");
  assert.doesNotMatch(executor, /@import\("metawork_agent"\)/);
  assert.doesNotMatch(executor, /HostShuttingDown/);
  assert.match(executor, /pub fn enqueue/);
  assert.match(executor, /pub fn shutdown/);

  const workbench = read("src/workbench/projection.zig");
  assert.match(workbench, /@import\("workbench_executor"\)/);
  assert.match(workbench, /self\.executor\.enqueue/);
  assert.match(workbench, /pub fn shutdownExecutor/);

  const app = read("src/app.zig");
  const stopExecutor = app.indexOf("workbench.shutdownExecutor();");
  const stopAgent = app.indexOf("agent_runtime.shutdown();");
  assert.ok(stopExecutor >= 0 && stopExecutor < stopAgent);
});

test("Workbench hands running cancellation through generation-checked control", () => {
  const agent = read("src/agent/session.zig");
  assert.match(agent, /const SessionControlBlock = struct/);
  assert.match(agent, /pub const RunControlLease = struct/);
  assert.match(agent, /pub fn beginRun/);
  assert.match(agent, /pub fn requestTermination/);

  const workbench = read("src/workbench/projection.zig");
  assert.match(workbench, /AgentHandoffState/);
  assert.match(workbench, /\.beginRun\(/);
  assert.match(workbench, /\.tryAcquireLease\(/);
  assert.doesNotMatch(workbench, /\.executePreparedRun\(/);
  assert.doesNotMatch(workbench, /\.requestCancel\(/);
  assert.doesNotMatch(workbench, /_ = lease\.requestTermination\(/);

  const cancel = workbench.slice(
    workbench.indexOf("pub fn cancel("),
    workbench.indexOf("pub fn respondUi("),
  );
  const terminalNoOp = cancel.indexOf(
    "if (terminalPayload(run) != null) return;",
  );
  const stoppingWrite = cancel.indexOf("setActivePhase(run, .stopping);");
  assert.ok(terminalNoOp >= 0 && terminalNoOp < stoppingWrite);
});

test("Agent terminal facts have one immutable handoff and no legacy history latch", () => {
  const agent = read("src/agent/session.zig");
  assert.match(agent, /pub const TerminationSignal = union\(enum\)/);
  assert.match(agent, /pub const TerminalResult = struct/);
  assert.match(agent, /pub fn execute\(self: \*Run\) TerminalResult/);
  assert.doesNotMatch(
    agent,
    /HostCause|RunOutcome|executePreparedRun|last_outcome|last_status|last_abort_status|last_stop_reason_code/,
  );

  const workbench = read("src/workbench/projection.zig");
  assert.match(workbench, /commitAgentTerminal\(run, &terminal\)/);
  assert.doesNotMatch(workbench, /snapshot\.last_outcome|snapshot\.cause/);
});
