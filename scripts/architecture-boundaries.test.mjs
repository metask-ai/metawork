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

test("MetaWork product and package manifests share one release version", () => {
  const appVersion = read("app.zon").match(/\.version = "([^"]+)"/)?.[1];
  const zigVersion = read("build.zig.zon").match(/\.version = "([^"]+)"/)?.[1];
  const rootPackage = JSON.parse(read("package.json"));
  const rendererPackage = JSON.parse(read("frontend/package.json"));
  const lock = JSON.parse(read("package-lock.json"));

  assert.match(appVersion ?? "", /^0\.\d+\.\d+$/);
  assert.equal(rootPackage.version, appVersion);
  assert.equal(rendererPackage.version, appVersion);
  assert.equal(zigVersion, appVersion);
  assert.equal(lock.version, appVersion);
  assert.equal(lock.packages[""].version, appVersion);
  assert.equal(lock.packages.frontend.version, appVersion);
});

test("module roots and Agent directory use product semantics", () => {
  for (const path of [
    "src/app.zig",
    "src/account.zig",
    "src/agent.zig",
    "src/workbench.zig",
    "src/bridge.zig",
  ]) {
    assert.equal(existsSync(new URL(path, root)), true, `${path} must exist`);
  }
  assert.equal(
    existsSync(new URL("src/account/contract.zig", root)),
    true,
    "the pure Account contract must have an explicit source root",
  );
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
  for (const file of [
    "src/account.zig",
    "src/agent.zig",
    "src/workbench.zig",
    "src/bridge.zig",
  ]) {
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
    "metawork_account",
  ]);
  assertNoImports(
    ["src/account/contract.zig"],
    [
      "native_sdk",
      "metawork_app",
      "metawork_account",
      "metawork_workbench",
      "metawork_bridge",
      "metawork_agent",
      "metask_agentcore",
    ],
  );
  assertNoImports(zigFiles("src/account/"), [
    "metawork_app",
    "metawork_workbench",
    "metawork_bridge",
    "metawork_agent",
    "metask_agentcore",
  ]);
  assertNoImports(
    zigFiles("src/account/").filter(
      (file) => file !== "src/account/platform.zig",
    ),
    ["native_sdk"],
  );
  assert.match(read("src/account/platform.zig"), /@import\("native_sdk"\)/);
});

test("only Agent implementation imports the AgentCore SDK", () => {
  const forbidden = zigFiles("src/").filter(
    (file) => file !== "src/agent.zig" && !file.startsWith("src/agent/"),
  );
  assertNoImports(forbidden, ["metask_agentcore"]);

  const build = read("build.zig");
  const sdkImportReceivers = [
    ...build.matchAll(
      /\b([A-Za-z_]\w*)\s*\.\s*addImport\s*\(\s*"metask_agentcore"\s*,/g,
    ),
  ]
    .map((match) => match[1])
    .sort();
  assert.deepEqual(
    sdkImportReceivers,
    ["event_pump", "event_sink", "fixture", "session"].sort(),
    "only the Agent runtime modules and lifecycle fixture may receive the SDK module",
  );
  assert.match(
    build,
    /b\.dependency\("agentcore",[\s\S]*?\.module\("metask_agentcore"\)/,
  );
  assert.doesNotMatch(build, /\.addObjectFile\(/);
  assert.match(
    read("build.zig.zon"),
    /\.agentcore\/bundle\/bindings\/zig/,
    "the formal build must consume the staged official Zig package",
  );

  const agentRoot = read("src/agent.zig");
  assert.match(agentRoot, /pub const OwnedCoreEvent/);
  assert.doesNotMatch(agentRoot, /EventEnvelope/);
  const workbench = read("src/workbench/projection.zig");
  assert.match(workbench, /lifecycle\.OwnedCoreEvent/);
  const bridgeHandlers = read("src/bridge/handlers.zig");
  assert.match(bridgeHandlers, /pub const PermissionChoice = enum/);
});

test("candidate validation keeps only repository locks and the official SDK consumer", () => {
  for (const lock of [
    "build_support/agentcore-bundle.macos.lock.json",
    "build_support/agentcore-bundle.windows.lock.json",
  ]) {
    assert.equal(existsSync(new URL(lock, root)), true);
  }
  const probeRunner = read("scripts/run-agentcore-probe.mjs");
  assert.match(probeRunner, /bundle\/bindings\/zig/);
  assert.match(probeRunner, /agentcore\.Api\.discover\(\)/);
  assert.match(probeRunner, /addRunArtifact/);
  assert.match(probeRunner, /source-free AgentCore Zig package consumer/);
});

test("build graph registers Account product and pure contract modules", () => {
  const source = read("build.zig");
  for (const name of [
    "metawork_app",
    "metawork_agent",
    "metawork_workbench",
    "metawork_bridge",
    "metawork_account",
  ]) {
    assert.match(source, new RegExp(`addImport\\(\\"${name}\\"`));
  }
  assert.match(
    source,
    /root_source_file = b\.path\("src\/account\/contract\.zig"\)/,
  );
  assert.match(source, /account_contract: \*std\.Build\.Module/);
  for (const moduleName of [
    "account_oauth",
    "metask_client",
    "account_credential_store",
    "account_platform",
    "account_loopback",
    "account_login_attempt",
  ]) {
    assert.match(
      source,
      new RegExp(`${moduleName}: \\*std\\.Build\\.Module`),
      `${moduleName} must be a named build module`,
    );
  }
  assert.match(source, /account: \*std\.Build\.Module/);
  assert.match(
    source,
    /app\.addImport\("metawork_account_contract", account_contract\)/,
  );
  assert.match(
    source,
    /bridge\.addImport\("metawork_account_contract", account_contract\)/,
  );
  const dispatcher = read("src/bridge/dispatcher.zig");
  assert.match(dispatcher, /@import\("metawork_account_contract"\)/);
  assert.doesNotMatch(dispatcher, /@import\("metawork_account"\)/);
  assert.match(dispatcher, /account_contract\.AccountCommandSink/);
  assert.doesNotMatch(source, /src\/agentcore(?:\/|\.zig)/);
});

test("Account execution is installed explicitly without process defaults", () => {
  const app = read("src/app.zig");
  const workbench = read("src/workbench/projection.zig");
  for (const variable of [
    "METAWORK_PROVIDER_API_KEY",
    "METAWORK_PROVIDER_MODEL",
    "METAWORK_PROVIDER_KIND",
    "METAWORK_PROVIDER_BASE_URL",
  ]) {
    assert.doesNotMatch(
      app,
      new RegExp(variable),
      `${variable} must not configure production execution`,
    );
  }
  assert.match(workbench, /@import\("metawork_account_contract"\)/);
  assert.doesNotMatch(workbench, /@import\("metawork_account"\)/);
  assert.match(
    workbench,
    /pub const Configuration = struct \{\s*change_notifier:/,
  );
  assert.doesNotMatch(workbench, /ExecutionDefaults/);
  assert.match(app, /effect_commit_hook\.dispatch\(\)/);
  assert.match(app, /commitAccountOnly\(/);
  assert.match(app, /account_api\.CredentialOwner/);
  assert.doesNotMatch(app, /account_api\.OAuth\.TokenSet/);
});

test("Account persistence revision has one code owner", () => {
  const store = read("src/account/credential_store.zig");
  const platform = read("src/account/platform.zig");
  assert.match(store, /pub const persistence_revision: u8 = 2/);
  assert.match(store, /"dev\.metawork\.account\.v\{d\}"/);
  assert.match(store, /"manifest\.v\{d\}"/);
  assert.equal([...store.matchAll(/\.\{persistence_revision\}/g)].length, 2);
  assert.match(store, /version: u8 = persistence_revision/);
  assert.match(store, /self\.version != persistence_revision/);
  assert.match(platform, /const manifest_name = store\.manifest_name/);
  assert.doesNotMatch(platform, /"manifest\.v[0-9]+"/);
});

test("formal Native test graph runs every product module test root", () => {
  const source = read("build.zig");
  for (const [name, rootModule] of [
    ["metawork-account-contract", "test_modules.account_contract"],
    ["metawork-account-oauth", "test_modules.account_oauth"],
    ["metawork-metask-client", "test_modules.metask_client"],
    [
      "metawork-account-credential-store",
      "test_modules.account_credential_store",
    ],
    ["metawork-account-platform", "test_modules.account_platform"],
    ["metawork-account-loopback", "test_modules.account_loopback"],
    ["metawork-account-login-attempt", "test_modules.account_login_attempt"],
    [
      "metawork-account-credentials-runtime",
      "test_modules.account_credentials_runtime",
    ],
    [
      "metawork-account-network-attempt",
      "test_modules.account_network_attempt",
    ],
    ["metawork-account-state", "test_modules.account_state"],
    ["metawork-account", "test_modules.account"],
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
});

test("Bridge owns the only Renderer product delivery state", () => {
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

  assert.equal(existsSync(new URL("src/automation/delivery.zig", root)), false);
});

test("automation code is compile-time selected and absent from product modules", () => {
  const build = read("build.zig");
  const selector = read("src/automation.zig");
  assert.match(selector, /build_options\.automation/);
  assert.match(selector, /automation_enabled/);
  assert.match(selector, /automation_disabled/);
  assert.match(build, /src\/automation\/enabled\.zig/);
  assert.match(build, /src\/automation\/disabled\.zig/);
  assert.doesNotMatch(build, /automation_delivery/);

  const productSources = [
    "src/app.zig",
    "src/bridge.zig",
    ...zigFiles("src/bridge/"),
    "src/automation/disabled.zig",
    "src/automation/enabled.zig",
  ]
    .map(read)
    .join("\n");
  for (const token of [
    "metawork:agent-events",
    "metawork.events.ack",
    "metawork.events.fetch",
    "metawork.event_delivery.emit_fixture",
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
  assert.match(workbench, /copyProjected\(\s*prompt/);
  assert.match(workbench, /replaceTrackedProjected\(\s*&view\.title/);
  assert.match(
    taskRecord,
    /execution: \?account_contract\.OwnedExecutionConfig/,
  );
  assert.match(workbench, /redaction_secret = execution\.api_key/);
  assert.match(workbench, /releaseQuiescentTaskExecutions/);

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

test("Renderer Bridge fixed revision 1 owns the exact product wire catalog", () => {
  const zigCommands = read("src/bridge/commands.zig");
  const rendererCommands = read("frontend/src/bridge/commands.ts");
  const appManifest = read("app.zon");
  const productCommand =
    /"(metawork\.(?:smoke|events|workspaces|workbench|account|tasks)\.[A-Za-z.]+)"/g;
  const catalog = (source) =>
    [
      ...new Set([...source.matchAll(productCommand)].map((match) => match[1])),
    ].sort();
  assert.deepEqual(catalog(rendererCommands), catalog(zigCommands));
  assert.deepEqual(catalog(appManifest), catalog(zigCommands));
  assert.ok(catalog(zigCommands).includes("metawork.account.reopenLogin"));
  assert.match(zigCommands, /contract_id = "metawork\.renderer-bridge"/);
  assert.match(zigCommands, /contract_revision: u32 = 1/);
  assert.match(
    rendererCommands,
    /RENDERER_BRIDGE_CONTRACT_ID = "metawork\.renderer-bridge"/,
  );
  assert.match(rendererCommands, /RENDERER_BRIDGE_CONTRACT_REVISION = 1/);
  const agents = read("AGENTS.md");
  const architecture = read("docs/architecture.md");
  assert.match(agents, /任何合同类版本标识的变更都必须先得到用户显式同意/);
  assert.match(
    architecture,
    /任何合同类版本标识的变更都必须先得到用户显式同意/,
  );
  assert.match(architecture, /快速开发阶段固定 revision 为 `1`/);
  assert.match(
    architecture,
    /`connect` 无法通过 revision 数字识别同 revision 的陈旧开发产物/,
  );
  assert.match(architecture, /不能检测纯 wire 语义错配/);
  assert.match(architecture, /不构成 runtime compatibility guarantee/);
  assert.doesNotMatch(zigCommands, /metawork\.workspace\.choose/);
  assert.doesNotMatch(rendererCommands, /metawork\.workspace\.choose/);

  const handlers = read("src/bridge/handlers.zig");
  assert.match(handlers, /expectedWorkspaceEpoch/);
  assert.match(handlers, /expectedExecutionGeneration/);
  assert.match(handlers, /expectedBindingEpoch/);
  assert.doesNotMatch(
    handlers,
    /workspaceGrant|workspaceRoot|apiKeyId|modelId/,
  );

  const dispatcher = read("src/bridge/dispatcher.zig");
  assert.match(dispatcher, /handlers\.RendererBridgeConnect/);
  assert.match(dispatcher, /identity_mismatch/);
  assert.match(dispatcher, /revision_mismatch/);
  assert.doesNotMatch(zigCommands, /metawork\.sessions\./);
  assert.doesNotMatch(rendererCommands, /metawork\.sessions\./);
  assert.doesNotMatch(appManifest, /metawork\.sessions\./);

  const projection = read("src/workbench/projection.zig");
  assert.doesNotMatch(projection, /schemaVersion|snapshot_schema_version/);
  assert.match(projection, /\\"account\\":/);
  assert.match(projection, /\\"workspaces\\":\[/);
  assert.match(projection, /\\"tasks\\":\[/);
  assert.match(projection, /pub fn createTask/);
  assert.match(projection, /pub fn runTask/);
  assert.doesNotMatch(projection, /host_shutdown|\\"sessions\\":\[/);
  assert.doesNotMatch(
    projection,
    /const SessionView|pub fn submit|max_runs_per_session/,
  );

  const contracts = read("frontend/src/bridge/contracts.ts");
  assert.doesNotMatch(contracts, /schemaVersion|WORKBENCH_SCHEMA_VERSION/);
  assert.match(contracts, /readiness: AccountReadiness/);
  assert.match(contracts, /primaryAction: AccountPrimaryAction/);
  assert.match(contracts, /account: AccountView/);
  assert.match(contracts, /workspaces: WorkspaceView\[\]/);
  assert.match(contracts, /tasks: TaskView\[\]/);
  assert.match(contracts, /"app_shutdown"/);
  assert.doesNotMatch(contracts, /host_shutdown|sessions: SessionView/);
  assert.doesNotMatch(contracts, /workspaceGrant|workspaceRoot/);

  assert.equal(
    existsSync(
      new URL(
        "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
        root,
      ),
    ),
    true,
  );
  assert.deepEqual(
    readdirSync(new URL("frontend/src/bridge/__fixtures__/", root)),
    ["workbench-snapshot.fixture"],
  );
});

test("lifecycle tests are grouped by invariant", () => {
  const cases = [
    ["tests/agent/lifecycle_test.zig", 31],
    ["tests/agent/event_pump_test.zig", 5],
    ["tests/workbench/executor_lifecycle_test.zig", 9],
    ["tests/integration/lifecycle/lifecycle_test.zig", 4],
  ];
  for (const [path, expectedCount] of cases) {
    assert.equal(existsSync(new URL(path, root)), true, `${path} must exist`);
    assert.equal(
      [...read(path).matchAll(/^test "/gm)].length,
      expectedCount,
      `${path} must retain its invariant coverage`,
    );
  }

  assert.equal(
    existsSync(new URL("tests/support/lifecycle_fixture.zig", root)),
    true,
  );
  const build = read("build.zig");
  for (const [path] of cases) assert.ok(build.includes(`"${path}"`));
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
  assert.match(runner, /"test-lifecycle"/);
  assert.match(runner, /cwd: repositoryRoot/);
  assert.doesNotMatch(runner, /host-lifecycle|HOST_LIFECYCLE_TEST_FILTER/);
});
