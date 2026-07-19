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
    "metawork_automation",
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

test("Phase 0A keeps the raw ABI probe distinct from the typed Agent adapter", () => {
  const probe = read("spikes/agentcore-contract/main.zig");
  const formalStart = probe.indexOf("fn verifyFormalHost(");
  const formalEnd = probe.indexOf("fn verifyUiOutcome(");
  assert.ok(formalStart >= 0 && formalEnd > formalStart);

  const rawProbe = probe.slice(0, formalStart);
  const formalHost = probe.slice(formalStart, formalEnd);
  for (const field of [
    "provider_kind_code",
    "permission_mode_code",
    "shell_policy_code",
  ]) {
    assert.match(
      rawProbe,
      new RegExp(`session_config\\.${field}`),
      `raw ABI coverage must retain ${field}`,
    );
    assert.doesNotMatch(
      formalHost,
      new RegExp(`\\.${field}\\s*=`),
      `typed Agent adapter must not use raw ${field}`,
    );
  }
  assert.match(formalHost, /lifecycle\.Runtime\.initWithApi\(/);
  assert.doesNotMatch(formalHost, /lifecycle\.Runtime\.init\(/);
  assert.match(formalHost, /\.provider = \.anthropic/);
  assert.match(formalHost, /\.permission_mode = \.default/);
  assert.match(formalHost, /\.shell_policy = \.unrestricted/);
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

test("formal Native test graph runs every product module test root", () => {
  const source = read("build.zig");
  for (const [name, rootModule] of [
    ["metawork-app", "test_modules.app"],
    ["metawork-bridge", "test_modules.bridge"],
    ["metawork-workbench", "test_modules.workbench_projection"],
    ["metawork-workbench-executor", "test_modules.workbench_executor"],
  ]) {
    assert.match(
      source,
      new RegExp(
        `\\.name = \\"${name}\\", \\.root_module = ${rootModule.replaceAll(".", "\\.")}`,
      ),
      `${name} must be an explicit Native test artifact`,
    );
  }
  assert.match(source, /for \(module_tests\) \|spec\|/);
  assert.match(
    source,
    /artifacts\.tests\.step\.dependOn\(&b\.addRunArtifact\(tests\)\.step\)/,
  );
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
  assert.match(app, /agent_event_wake_pending\.swap\(true, \.acq_rel\)/);
  const clearWake = app.indexOf(
    "self.agent_event_wake_pending.store(false, .release);",
  );
  const drainEvents = app.indexOf("while (agent_runtime.takeEvent())");
  assert.ok(clearWake >= 0 && clearWake < drainEvents);
  const drainFunction = app.slice(
    app.indexOf("fn drainAgentEvents("),
    app.indexOf("fn drainAgentEventPass("),
  );
  const firstDrain = drainFunction.indexOf(
    "self.drainAgentEventPass(agent_runtime);",
  );
  const markTerminal = drainFunction.indexOf(
    "workbench.markTerminalRunsBeforeEventDrain();",
  );
  const secondDrain = drainFunction.indexOf(
    "self.drainAgentEventPass(agent_runtime);",
    firstDrain + 1,
  );
  const finalizeTerminal = drainFunction.indexOf(
    "workbench.finalizeMarkedTerminalRunsAfterEventDrain();",
  );
  assert.ok(
    firstDrain >= 0 &&
      firstDrain < markTerminal &&
      markTerminal < secondDrain &&
      secondDrain < finalizeTerminal,
  );
  const stopIngress = app.indexOf("dispatcher.stopIngress();");
  const quiesceCallbacks = app.indexOf("dispatcher.assertQuiescent();");
  const detachWorkbench = app.indexOf("dispatcher.detachWorkbench();");
  assert.ok(stopIngress >= 0 && stopIngress < quiesceCallbacks);
  assert.ok(quiesceCallbacks < detachWorkbench);

  const dispatcher = read("src/bridge/dispatcher.zig");
  assert.match(dispatcher, /decideTransportFailure/);
  const delivery = read("src/automation/delivery.zig");
  assert.match(delivery, /pub fn deinitOwnedBuffers/);
});

test("Bridge owns product delivery state while automation transport stays explicit", () => {
  const bridgeRoot = read("src/bridge.zig");
  assert.match(bridgeRoot, /pub const ProductDelivery =/);
  assert.match(bridgeRoot, /pub const ProductDeliveryTransport =/);
  assert.doesNotMatch(
    bridgeRoot,
    /pub const (?:revision_delivery|snapshot_delivery) =/,
  );

  const productDelivery = read("src/bridge/product_delivery.zig");
  assert.match(productDelivery, /pub const Delivery = struct/);
  for (const owned of ["generation", "window_id", "revision", "snapshot"]) {
    assert.match(productDelivery, new RegExp(`\\b${owned}:`));
  }
  assert.match(productDelivery, /initOwned\(allocator\)/);
  assert.match(productDelivery, /RevisionRetryExhausted/);
  assert.doesNotMatch(
    productDelivery,
    /@import\("(?:metawork_app|metawork_workbench|native_sdk)"\)/,
  );

  const app = read("src/app.zig");
  assert.match(app, /dispatcher: \?\*bridge_api\.Dispatcher/);
  assert.match(app, /automation: automation_api\.Runtime/);
  assert.doesNotMatch(
    app,
    /event_window_id|bridge_callbacks_active|revision_delivery:\s|snapshot_delivery:\s/,
  );
  assert.doesNotMatch(
    app,
    /renderer_bridge\.(?:revision_delivery|snapshot_delivery)/,
  );

  const dispatcher = read("src/bridge/dispatcher.zig");
  assert.match(dispatcher, /delivery: product_delivery\.Delivery/);
  assert.match(dispatcher, /callbacks: callback_gate\.State/);
  assert.match(dispatcher, /grants: workspace_grant\.State/);
  assert.match(dispatcher, /workbench: \?\*workbench_api\.Workbench/);

  const automationDelivery = read("src/automation/delivery.zig");
  assert.match(automationDelivery, /Automation-only raw Agent event transport/);
  assert.match(automationDelivery, /pub fn connectAt/);
});

test("automation code is compile-time selected and absent from product modules", () => {
  const build = read("build.zig");
  const selector = read("src/automation.zig");
  assert.match(selector, /build_options\.automation/);
  assert.match(selector, /automation_enabled/);
  assert.match(selector, /automation_disabled/);
  assert.match(build, /src\/automation\/enabled\.zig/);
  assert.match(build, /src\/automation\/disabled\.zig/);
  assert.match(build, /automation_enabled\.addImport\("automation_delivery"/);

  const productSources = [
    "src/app.zig",
    "src/bridge.zig",
    ...zigFiles("src/bridge/"),
    "src/automation/disabled.zig",
  ]
    .map(read)
    .join("\n");
  for (const token of [
    "zero://inline",
    "metawork:agent-events",
    "metawork.events.ack",
    "metawork.events.fetch",
    "metawork.gate5.emitFixture",
  ]) {
    assert.equal(
      productSources.includes(token),
      false,
      `product source contains ${token}`,
    );
  }

  const commands = read("src/bridge/commands.zig");
  assert.doesNotMatch(
    commands,
    /fixture|automation|metawork\.events\.(?:ack|fetch)/,
  );
  assert.equal(existsSync(new URL("frontend/src/host/", root)), false);
  assert.equal(
    existsSync(new URL("frontend/src/bridge/client.ts", root)),
    true,
  );
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
  assert.match(workbench, /\.beginRunOutcome\(/);
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
    /\bHostCause\b|pub const RunOutcome|executePreparedRun|last_outcome|last_status|last_abort_status|last_stop_reason_code/,
  );

  const workbench = read("src/workbench/projection.zig");
  assert.match(workbench, /commitAgentTerminal\(run, &terminal\)/);
  assert.match(
    workbench,
    /fn productTerminalPayload[\s\S]*if \(!run\.event_stream_finalized\) return null;/,
  );
  assert.match(
    workbench,
    /fn productTerminalFacts[\s\S]*productTerminalPayload\(run\)/,
  );
  assert.match(workbench, /fn runPhase[\s\S]*productTerminalFacts\(run\)/);
  assert.match(
    workbench,
    /fn writeRun[\s\S]*const terminal = productTerminalFacts\(run\)/,
  );
  assert.match(workbench, /event_projection_failure: \?EventProjectionFailure/);
  const app = read("src/app.zig");
  assert.match(
    app,
    /applyEvent\(&envelope\) catch[\s\S]*recordEventProjectionFailure/,
  );
  assert.doesNotMatch(workbench, /snapshot\.last_outcome|snapshot\.cause/);
});

test("Workbench owns Task lifecycle, continuation, and canonical redaction", () => {
  const workbench = read("src/workbench/projection.zig");
  const taskRecord = workbench.slice(
    workbench.indexOf("const TaskView = struct"),
    workbench.indexOf("pub const RunRef = struct"),
  );
  assert.match(taskRecord, /lifecycle: TaskLifecycle/);
  assert.match(taskRecord, /continuation: ContinuationCapability/);
  assert.doesNotMatch(taskRecord, /SessionState/);
  assert.doesNotMatch(workbench, /session\.snapshot\(/);
  assert.match(workbench, /session_disposition_at_completion/);
  assert.match(workbench, /foldTerminalDisposition/);
  const closeWorker = workbench.slice(
    workbench.indexOf("fn closeWorker("),
    workbench.indexOf("fn executeRunJob("),
  );
  assert.match(closeWorker, /notifier\.notify\(\)/);
  assert.doesNotMatch(closeWorker, /requestWake\(\)/);
  assert.match(workbench, /sanitizeInto\(\s*run\.terminal_diagnostic/);
  assert.match(workbench, /copyProjected\(prompt/);
  assert.match(workbench, /replaceTrackedProjected\(\s*&view\.title/);

  const agent = read("src/agent/session.zig");
  assert.match(agent, /pub const SessionRoute = struct/);
  assert.match(agent, /pub const BeginRunOutcome = union\(enum\)/);
  assert.match(agent, /pub const CloseOutcome = union\(enum\)/);
});

test("Bridge Dispatcher owns product command decisions and App only composes it", () => {
  const build = read("build.zig");
  assert.match(build, /bridge\.addImport\("metawork_workbench", workbench\)/);

  const dispatcher = read("src/bridge/dispatcher.zig");
  for (const boundary of [
    "callback_gate.State",
    "product_delivery.Delivery",
    "workspace_grant.State",
    "parsePayload",
    "parseWireId",
    "requireWorkbench",
  ]) {
    assert.match(dispatcher, new RegExp(boundary));
  }
  assert.match(dispatcher, /registered_handlers:/);
  assert.match(dispatcher, /self\.requireWorkbench/);

  const app = read("src/app.zig");
  assert.match(app, /bridge_api\.Dispatcher\.init/);
  assert.match(app, /\.register\(/);
  assert.doesNotMatch(
    app,
    /fn (?:createTask|runTask|cancelTask|respondUi|closeTask|renameTask|archiveTask|deleteTask)\(/,
  );
  assert.doesNotMatch(app, /parsePayload|parseWireId|workspaceGrant/);
});

test("product wire contract is atomically on Task schema v5", () => {
  const zigCommands = read("src/bridge/commands.zig");
  const rendererCommands = read("frontend/src/bridge/commands.ts");
  const appManifest = read("app.zon");
  for (const command of [
    "create",
    "run",
    "cancel",
    "respondUi",
    "close",
    "rename",
    "archive",
    "delete",
  ]) {
    const wireName = `metawork.tasks.${command}`;
    assert.ok(zigCommands.includes(wireName));
    assert.ok(rendererCommands.includes(wireName));
    assert.ok(appManifest.includes(wireName));
  }
  assert.doesNotMatch(zigCommands, /metawork\.sessions\./);
  assert.doesNotMatch(rendererCommands, /metawork\.sessions\./);
  assert.doesNotMatch(appManifest, /metawork\.sessions\./);

  const projection = read("src/workbench/projection.zig");
  assert.match(projection, /snapshot_schema_version: u32 = 5/);
  assert.match(projection, /\\"tasks\\":\[/);
  assert.match(projection, /pub fn createTask/);
  assert.match(projection, /pub fn runTask/);
  assert.doesNotMatch(projection, /host_shutdown|\\"sessions\\":\[/);
  assert.doesNotMatch(
    projection,
    /const SessionView|pub fn submit|max_runs_per_session/,
  );

  const contracts = read("frontend/src/bridge/contracts.ts");
  assert.match(contracts, /WORKBENCH_SCHEMA_VERSION = 5/);
  assert.match(contracts, /tasks: TaskView\[\]/);
  assert.match(contracts, /"app_shutdown"/);
  assert.doesNotMatch(contracts, /host_shutdown|sessions: SessionView/);

  assert.equal(
    existsSync(
      new URL(
        "frontend/src/bridge/__fixtures__/workbench-snapshot-v5.fixture",
        root,
      ),
    ),
    true,
  );
  assert.equal(
    existsSync(
      new URL(
        "frontend/src/bridge/__fixtures__/workbench-snapshot-v4.fixture",
        root,
      ),
    ),
    false,
  );
});

test("lifecycle tests are grouped by invariant instead of a mixed spike", () => {
  for (const legacy of [
    "spikes/host-lifecycle/build.zig",
    "spikes/host-lifecycle/lifecycle_test.zig",
  ]) {
    assert.equal(existsSync(new URL(legacy, root)), false);
  }

  const cases = [
    ["tests/agent/lifecycle_test.zig", 27],
    ["tests/agent/event_pump_test.zig", 5],
    ["tests/workbench/executor_lifecycle_test.zig", 7],
    ["tests/bridge/automation_delivery_test.zig", 6],
    ["tests/integration/lifecycle/lifecycle_test.zig", 5],
  ];
  for (const [path, expectedCount] of cases) {
    assert.equal(existsSync(new URL(path, root)), true, `${path} must exist`);
    assert.equal(
      [...read(path).matchAll(/^test "/gm)].length,
      expectedCount,
      `${path} must retain its invariant coverage`,
    );
  }

  assert.doesNotMatch(
    read("tests/bridge/automation_delivery_test.zig"),
    /fixture\.event_pump/,
  );

  assert.equal(
    existsSync(new URL("tests/support/lifecycle_fixture.zig", root)),
    true,
  );
  const build = read("tests/build.zig");
  for (const [path] of cases) assert.ok(build.includes(`"${path.slice(6)}"`));
  for (const filter of [
    "terminal publication",
    "Workbench outcomes",
    "Agent terminal facts",
  ]) {
    assert.ok(build.includes(`"${filter}"`));
  }

  const packageManifest = read("package.json");
  assert.match(
    packageManifest,
    /"test:lifecycle": "node scripts\/run-lifecycle-tests\.mjs"/,
  );
  assert.doesNotMatch(packageManifest, /test:host-lifecycle/);
  const runner = read("scripts/run-lifecycle-tests.mjs");
  assert.match(runner, /path\.join\(repositoryRoot, "tests"\)/);
  assert.doesNotMatch(runner, /host-lifecycle|HOST_LIFECYCLE_TEST_FILTER/);
});
