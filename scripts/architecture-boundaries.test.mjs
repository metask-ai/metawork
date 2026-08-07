import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

function filesWithExtensions(directory, extensions) {
  return readdirSync(new URL(directory, root), { withFileTypes: true }).flatMap(
    (entry) => {
      const path = join(directory, entry.name).replaceAll("\\", "/");
      if (entry.isDirectory())
        return filesWithExtensions(`${path}/`, extensions);
      return entry.isFile() &&
        extensions.some((value) => entry.name.endsWith(value))
        ? [path]
        : [];
    },
  );
}

const zigFiles = (directory) => filesWithExtensions(directory, [".zig"]);

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
  assert.equal(
    existsSync(new URL("src/account/runtime.zig", root)),
    true,
    "Account must have an explicit long-lived Runtime owner",
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
    [
      "agent_catalog",
      "agent_mcp_connector",
      "agent_mcp_catalog",
      "agent_mcp_runtime",
      "event_pump",
      "event_sink",
      "fixture",
      "session",
    ].sort(),
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
  assert.doesNotMatch(agentRoot, /pub const UiResponse/);
  const agentSession = read("src/agent/session.zig");
  assert.match(agentSession, /pub fn respondAnswers\(/);
  assert.match(agentSession, /pub fn respondPermission\(/);
  assert.doesNotMatch(agentSession, /pub fn respondUi\(/);
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
  assert.match(
    read("scripts/agentcore-bundle.mjs"),
    /manifest\.source\.dirty === false/,
    "candidate verification must reject dirty source provenance",
  );
  assert.match(
    read("build_support/agentcore_bundle.zig"),
    /lock\.source\.dirty/,
    "the formal build verifier must reject a dirty repository lock",
  );
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
    "account_runtime",
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

test("Account Runtime owns policy while App installs execution explicitly", () => {
  const app = read("src/app.zig");
  const accountRuntime = read("src/account/runtime.zig");
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
  assert.match(app, /prepared\.takeExecution\(\)/);
  assert.match(app, /prepared\.attemptId\(\)/);
  assert.doesNotMatch(app, /prepared\.transition/);
  assert.match(app, /workbench\.installExecutionNoFail/);
  assert.match(app, /runtime\.dispatchCommitted\(&prepared\)/);
  assert.match(
    accountRuntime,
    /credentials: credentials_impl\.CredentialOwner/,
  );
  assert.match(accountRuntime, /fn automaticApiSelection\(/);
  assert.match(accountRuntime, /fn automaticModelSelection\(/);
  assert.match(accountRuntime, /fn prepareAndPersistExecution\(/);
  assert.match(accountRuntime, /catalog_after_refresh:/);
  assert.doesNotMatch(
    app,
    /CredentialOwner|automaticApiSelection|automaticModelSelection|prepareAndPersistExecution|catalog_after_refresh|mailbox_mutex/,
  );
  assert.doesNotMatch(app, /account_api\.OAuth\.TokenSet/);

  const runtimeDeinit = accountRuntime.slice(
    accountRuntime.indexOf("pub fn deinit(self: *Runtime)"),
    accountRuntime.indexOf("pub fn prepareStart("),
  );
  assert.doesNotMatch(runtimeDeinit, /cancelRefreshTimer|platform\.deinit/);
  assert.ok(
    runtimeDeinit.indexOf("self.effects.deinit();") <
      runtimeDeinit.indexOf("self.credentials.deinit();"),
    "Account effects must quiesce before credentials are released",
  );

  const shutdownEffect = accountRuntime.slice(
    accountRuntime.indexOf(".shutdown => {"),
    accountRuntime.indexOf(".refresh_token => {"),
  );
  const cancelTimer = shutdownEffect.indexOf("self.cancelRefreshTimer();");
  const joinEffects = shutdownEffect.indexOf(
    "self.effects.cancelJoinAndDiscard();",
  );
  const releasePlatform = shutdownEffect.indexOf("platform.deinit();");
  assert.ok(
    cancelTimer >= 0 &&
      cancelTimer < joinEffects &&
      joinEffects < releasePlatform,
    "Account shutdown must cancel Native timers, join effects, then release its platform seam",
  );
});

test("cold Account restore preserves Task history without impersonating an identity switch", () => {
  const app = read("src/app.zig");
  assert.match(
    app,
    /const ExecutionReplacement = enum \{ none, startup, default, identity \}/,
  );
  assert.match(
    app,
    /prepareStart\(services\),\s*\.startup[\s\S]*prepareAutomationStart\(\),\s*\.startup[\s\S]*prepareStartUnavailable\(\),\s*\.startup/,
  );
  assert.match(
    app,
    /\.startup => self\.workbench\.beginDefaultExecutionReplacement\(\)/,
  );
});

test("macOS development identity and Account manifest hard cut have one code owner", () => {
  const appZon = read("app.zon");
  const build = read("build.zig");
  const identity = read("src/product_identity.zig");
  const app = read("src/app.zig");
  const store = read("src/account/credential_store.zig");
  const platform = read("src/account/platform.zig");
  assert.match(appZon, /\.id = "com\.metask\.metawork\.dev"/);
  assert.match(identity, /const app_manifest = @import\("app_manifest_zon"\)/);
  assert.match(identity, /pub const bundle_id = app_manifest\.id/);
  assert.doesNotMatch(identity, /com\.metask\.metawork\.dev/);
  assert.match(
    identity,
    /pub const macos_data_directory_name = "MetaWork Dev"/,
  );
  assert.match(
    identity,
    /pub const macos_account_keychain_service = bundle_id \+\+ "\.account"/,
  );
  assert.doesNotMatch(identity, /manifest_name|manifest_schema_version/);
  assert.match(build, /existingImport\(runner, "app_manifest_zon"\)/);
  assert.equal(
    (
      build.match(
        /addImport\("metawork_product_identity", product_identity\)/g,
      ) ?? []
    ).length,
    3,
  );
  assert.match(
    identity,
    /pub const mcp_credential_service = bundle_id \+\+ "\.mcp"/,
  );
  const mcpPlatform = read("src/app/mcp_platform.zig");
  assert.match(
    mcpPlatform,
    /pub const credential_service = product_identity\.mcp_credential_service/,
  );
  assert.match(app, /\.name = platformDataDirectoryName\(builtin\.os\.tag\)/);
  assert.match(app, /\.bundle_id = product_identity\.bundle_id/);
  assert.match(
    store,
    /pub const service = product_identity\.macos_account_keychain_service/,
  );
  assert.match(store, /pub const manifest_name = "manifest\.json"/);
  assert.match(store, /pub const manifest_schema_version: u8 = 1/);
  assert.match(store, /schema_version: u8 = manifest_schema_version/);
  assert.match(store, /self\.schema_version != manifest_schema_version/);
  assert.match(platform, /const manifest_name = store\.manifest_name/);
  assert.match(platform, /schema_version: u8/);
  assert.doesNotMatch(
    `${identity}\n${store}\n${platform}`,
    /dev\.metawork\.account\.v2|manifest\.v[0-9]+/,
  );
  assert.doesNotMatch(store, /persistence_revision/);
});

test("Windows Account persistence is refresh-only and unversioned", () => {
  const store = read("src/account/windows_store.zig");
  const app = read("src/app.zig");
  const accountRuntime = read("src/account/runtime.zig");
  assert.match(store, /pub const service = "dev\.metawork\.account"/);
  assert.match(
    store,
    /pub const refresh_token_account = "metask-refresh-token"/,
  );
  assert.match(store, /pub const public_state_name = "account\.json"/);
  assert.doesNotMatch(
    store,
    /manifest\.v[0-9]+|persistence_revision|CredentialStore|OwnedExecutionConfig|TokenSet/,
  );
  assert.match(app, /builtin\.os\.tag == \.windows/);
  assert.match(accountRuntime, /windows_store\.restore/);
  assert.doesNotMatch(app, /windows_store\.restore|WindowsStore\.restore/);
  assert.doesNotMatch(app, /dev\.metawork\.desktop/);
  assert.match(app, /const windows_data_directory_name = "MetaWork"/);
  assert.match(
    app,
    /test "product identity does not unify macOS and Windows Account storage"/,
  );
});

test("macOS Apple Development signing is explicit and isolated", () => {
  const packageJson = JSON.parse(read("package.json"));
  assert.equal(
    packageJson.scripts.dev,
    "npm run agentcore:verify-staged && node scripts/macos-local-signing.mjs dev",
  );
  assert.equal(
    packageJson.scripts["package:macos"],
    "node scripts/macos-local-signing.mjs package",
  );
  assert.equal(
    packageJson.scripts["setup:macos-signing"],
    "node scripts/setup-macos-local-signing.mjs setup",
  );
  assert.equal(
    packageJson.scripts["setup:macos-signing:clear"],
    "node scripts/setup-macos-local-signing.mjs clear",
  );
  assert.equal(
    packageJson.scripts["account:cleanup-legacy:macos"],
    "node scripts/cleanup-legacy-macos-account.mjs",
  );
  for (const script of ["check", "test", "build:debug", "build:release"]) {
    assert.doesNotMatch(
      packageJson.scripts[script],
      /codesign|macos-local-signing/u,
      `${script} must not depend on a developer's local certificate`,
    );
  }

  const signing = read("scripts/macos-local-signing.mjs");
  assert.match(
    signing,
    /readFileSync\(path\.join\(repositoryRoot, "app\.zon"\)/u,
  );
  assert.doesNotMatch(signing, /bundleId:\s*"/u);
  assert.match(signing, /Apple Development/u);
  assert.match(signing, /TeamIdentifier/u);
  assert.match(signing, /buildAppleDevelopmentRequirement/u);
  assert.match(signing, /buildCanonicalDesignatedRequirement/u);
  assert.match(signing, /validateCanonicalDesignatedRequirement/u);
  assert.match(signing, /"--requirements"/u);
  assert.match(signing, /`-R=\$\{policy\}`/u);
  assert.match(signing, /"--team-id",\s*identity\.teamId/u);
  assert.match(signing, /\.metawork-local-signing\.json/u);

  const setup = read("scripts/setup-macos-local-signing.mjs");
  assert.match(setup, /verifyPrivateKeyAccess/u);
  assert.match(setup, /add-certificates/u);
  assert.doesNotMatch(setup, /delete-generic-password|cleanup-legacy/u);

  const cleanup = read("scripts/cleanup-legacy-macos-account.mjs");
  assert.match(cleanup, /delete-generic-password/u);
  assert.match(cleanup, /dev\.metawork\.account\.v2/u);
  assert.match(cleanup, /manifest\.v2/u);
  for (const forbidden of ["openssl", "add-trusted-cert", "delete-identity"]) {
    assert.doesNotMatch(
      `${setup}\n${cleanup}`,
      new RegExp(forbidden, "u"),
      `local setup must not generate, override trust for, or delete a signing identity: ${forbidden}`,
    );
  }

  const verifier = read("scripts/verify-macos-package.mjs");
  assert.match(verifier, /localProductIdentity\.bundleId/u);
  assert.match(verifier, /verifyStableSignature/u);
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
    ["metawork-account-windows-store", "test_modules.account_windows_store"],
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
    ["metawork-account-runtime", "test_modules.account_runtime"],
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
    workbench.indexOf("const DurableTaskRecord = struct"),
    workbench.indexOf("fn FixedText"),
  );
  const durableTaskRecord = taskRecord.slice(
    taskRecord.indexOf("const DurableTaskRecord = struct"),
    taskRecord.indexOf("const RuntimeAttachment = struct"),
  );
  const runtimeAttachment = taskRecord.slice(
    taskRecord.indexOf("const RuntimeAttachment = struct"),
    taskRecord.indexOf("const TaskView = struct"),
  );
  assert.doesNotMatch(durableTaskRecord, /lifecycle: TaskLifecycle/);
  assert.doesNotMatch(
    durableTaskRecord,
    /continuation: ContinuationCapability/,
  );
  assert.match(runtimeAttachment, /lifecycle: TaskLifecycle/);
  assert.match(runtimeAttachment, /continuation: ContinuationCapability/);
  assert.match(taskRecord, /durable: DurableTaskRecord/);
  assert.match(taskRecord, /runtime: RuntimeAttachment/);
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
  assert.match(
    workbench,
    /fn copyRunInputRecord[\s\S]*\.text =>[\s\S]*copyProjected\(/,
  );
  assert.match(workbench, /const RunInputRecord = union\(enum\)/);
  assert.match(workbench, /const CatalogJob = struct/);
  assert.match(
    workbench,
    /executor\.enqueue\(\.\{[\s\S]*execute_fn = executeCatalogJob/,
  );
  assert.match(
    workbench,
    /commitCatalogJobsNoFail[\s\S]*workspace\.epoch == identity\.epoch[\s\S]*catalog_request_generation == identity\.request_generation/,
  );
  assert.match(
    workbench,
    /scheduleSkillCatalogQuery[\s\S]*\.target = \.\{ \.skills = generation \}[\s\S]*\.canonical_root = root[\s\S]*\.epoch_token = epoch_token/,
  );
  assert.match(
    workbench,
    /pub fn refreshSkillCatalog[\s\S]*scheduleSkillCatalogQuery\(\)/,
  );
  assert.doesNotMatch(
    workbench,
    /refreshSkillCatalog[\s\S]{0,500}session\.refreshSkillCatalog/,
  );
  assert.match(
    read("src/app.zig"),
    /resolveCanonicalUserHome[\s\S]*\.canonical_user_home = canonical_user_home/,
  );
  assert.doesNotMatch(read("src/bridge/dispatcher.zig"), /canonical_user_home/);
  assert.match(
    workbench,
    /pub fn renameTask[\s\S]*copyProjected\([\s\S]*execution\.input\(\)\.api_key[\s\S]*view\.durable\.title_redacted = projected\.redacted/,
  );
  assert.match(taskRecord, /execution: \?OwnedTaskExecution/);
  assert.match(workbench, /const OwnedTaskExecution = struct/);
  assert.match(workbench, /account_contract\.validateExecutionConfig\(input\)/);
  assert.match(workbench, /redaction_secret = execution\.api_key/);
  assert.match(workbench, /releaseQuiescentTaskExecutions/);
  assert.match(workbench, /fn releaseTaskExecutionNoFail/);
  const releaseTaskExecution = workbench.slice(
    workbench.indexOf("fn releaseTaskExecutionNoFail"),
    workbench.indexOf("fn upsertWorkspace"),
  );
  assert.match(
    releaseTaskExecution,
    /task\.durable\.runs[\s\S]*run\.redaction_secret = &\.\{\}/,
  );
  assert.match(
    releaseTaskExecution,
    /task\.durable\.compacts[\s\S]*compact\.redaction_secret = &\.\{\}/,
  );
  assert.doesNotMatch(workbench, /pub const RunRef|acquireRunRef/);

  const agent = read("src/agent/session.zig");
  assert.match(agent, /pub const SessionRoute = struct/);
  assert.match(agent, /pub const BeginRunOutcome = union\(enum\)/);
  assert.match(agent, /pub const CloseOutcome = union\(enum\)/);
});

test("Bridge owns ingress, Account owns validation, and App coordinates commits", () => {
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
  assert.doesNotMatch(dispatcher, /validateAccountSelection/);
  assert.doesNotMatch(dispatcher, /\.accountView\(\)/);

  const app = read("src/app.zig");
  const accountRuntime = read("src/account/runtime.zig");
  assert.match(
    accountRuntime,
    /expected_catalog_generation !=\s*account_view\.catalog_generation/,
  );
  assert.match(
    accountRuntime,
    /return \.\{ \.rejected = \.generation_mismatch \}/,
  );
  assert.doesNotMatch(app, /expected_catalog_generation|generation_mismatch/);
  assert.match(app, /workbench\.commitAccountFactNoFail\(fact\)/);
  assert.match(app, /runtime\.commit\(&prepared\)/);
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
    /"(metawork\.[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+)"/g;
  const catalog = (source) =>
    [
      ...new Set(
        [...source.matchAll(productCommand)]
          .map((match) => match[1])
          .filter((value) => value !== "metawork.renderer-bridge"),
      ),
    ].sort();
  assert.deepEqual(catalog(rendererCommands), catalog(zigCommands));
  assert.deepEqual(catalog(appManifest), catalog(zigCommands));
  assert.ok(catalog(zigCommands).includes("metawork.account.reopenLogin"));
  assert.deepEqual(
    catalog(zigCommands).filter((command) =>
      command.startsWith("metawork.host."),
    ),
    [
      "metawork.host.windowChrome.beginDrag",
      "metawork.host.windowChrome.connect",
      "metawork.host.windowChrome.control",
      "metawork.host.windowChrome.disconnect",
      "metawork.host.windowChrome.sync",
    ],
  );
  for (const source of [zigCommands, rendererCommands, appManifest])
    assert.doesNotMatch(
      source,
      /metawork\.window\.(?:beginDrag|control|state)|native-sdk\.window\./,
    );
  assert.match(zigCommands, /contract_id = "metawork\.renderer-bridge"/);
  assert.match(zigCommands, /contract_revision: u32 = 1/);
  assert.match(
    rendererCommands,
    /RENDERER_BRIDGE_CONTRACT_ID = "metawork\.renderer-bridge"/,
  );
  assert.match(rendererCommands, /RENDERER_BRIDGE_CONTRACT_REVISION = 1/);
  const agents = read("AGENTS.md");
  const bridgeContract = read("docs/renderer-bridge-contract.md");
  assert.match(agents, /任何合同类版本标识的变更都必须先得到用户显式同意/);
  assert.match(
    bridgeContract,
    /任何合同类版本标识的变更都必须先得到用户显式同意/,
  );
  assert.match(bridgeContract, /快速开发阶段固定 revision 为 `1`/);
  assert.match(
    bridgeContract,
    /`connect` 无法通过 revision 数字识别同 revision 的陈旧开发产物/,
  );
  assert.match(bridgeContract, /不能检测纯 wire 语义错配/);
  assert.match(bridgeContract, /不构成 runtime compatibility guarantee/);
  assert.doesNotMatch(zigCommands, /metawork\.workspace\.choose/);
  assert.doesNotMatch(rendererCommands, /metawork\.workspace\.choose/);

  const handlers = read("src/bridge/handlers.zig");
  assert.match(handlers, /expectedWorkspaceEpoch/);
  assert.match(handlers, /expectedExecutionGeneration/);
  assert.match(handlers, /expectedSkillCatalogRevision/);
  assert.match(handlers, /expectedBindingEpoch/);
  assert.match(handlers, /parseTaskRunInput/);
  assert.doesNotMatch(handlers, /\bprompt\s*:/);
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
  assert.match(projection, /\\"skillCatalog\\":/);
  assert.match(projection, /\\"input\\":/);
  assert.doesNotMatch(projection, /\\"user\\":/);
  assert.match(projection, /pub fn createTask/);
  assert.match(projection, /pub fn runTask/);
  assert.doesNotMatch(projection, /host_shutdown|\\"sessions\\":\[/);
  assert.doesNotMatch(
    projection,
    /const SessionView|pub fn submit|max_runs_per_session/,
  );
  assert.doesNotMatch(
    dispatcher,
    /runSkill|sessionRunSkill|skill_catalog_release/,
  );
  assert.match(
    dispatcher,
    /commands\.refresh_workspace_skill_catalog[\s\S]*commands\.refresh_task_skill_catalog/,
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

test("Renderer declares window chrome UI while Desktop Host owns native behavior", () => {
  const rendererFiles = filesWithExtensions("frontend/src/", [".ts", ".tsx"]);
  const chromeTransportOwners = rendererFiles.filter((file) =>
    read(file).includes("commands.windowChrome"),
  );
  assert.deepEqual(chromeTransportOwners, [
    "frontend/src/bridge/window-chrome.ts",
  ]);

  for (const retired of [
    "frontend/src/app/useWindowChrome.ts",
    "frontend/src/platform/window-chrome.ts",
  ])
    assert.equal(
      existsSync(new URL(retired, root)),
      false,
      `${retired} must stay deleted`,
    );

  for (const file of rendererFiles.filter(
    (path) => !path.startsWith("frontend/src/bridge/"),
  )) {
    const source = read(file);
    assert.doesNotMatch(
      source,
      /window\.zero|native-sdk\.window\./,
      `${file} reaches a native window API`,
    );
    assert.doesNotMatch(
      source,
      /beginWindowDrag|controlWindow|openWindowSystemMenu|windowState/,
      `${file} owns native window behavior`,
    );
  }

  const controls = read("frontend/src/components/ui/WindowControls.tsx");
  assert.match(controls, /data-metawork-window-control="minimize"/);
  assert.match(controls, /data-metawork-window-control="toggle_maximize"/);
  assert.match(controls, /data-metawork-window-control="close"/);
  assert.doesNotMatch(controls, /window\.zero|onClick|onPointer|onDoubleClick/);

  const titlebar = read("frontend/src/components/ui/WindowTitlebar.tsx");
  assert.match(titlebar, /data-metawork-window-drag=""/);
  assert.doesNotMatch(
    titlebar,
    /onPointer|onDoubleClick|onContextMenu|platform/,
  );

  const app = read("src/app.zig");
  const policy = read("src/bridge/policy.zig");
  const dispatcher = read("src/bridge/dispatcher.zig");
  const rendererChrome = read("frontend/src/bridge/window-chrome.ts");
  const manifest = read("app.zon");
  const seamPath = "src/native_sdk_compat/system_webview_drag_region.zig";
  const windowsPath =
    "src/native_sdk_compat/system_webview_drag_region/windows.zig";
  const macosPath =
    "src/native_sdk_compat/system_webview_drag_region/macos.zig";
  const controlsSeamPath =
    "src/native_sdk_compat/system_webview_window_controls.zig";
  const controlsWindowsPath =
    "src/native_sdk_compat/system_webview_window_controls/windows.zig";
  const startupWindowPath =
    "src/native_sdk_compat/system_webview_startup_window.zig";
  const startupWindowWindowsPath =
    "src/native_sdk_compat/system_webview_startup_window/windows.zig";
  const seam = read(seamPath);
  const windows = read(windowsPath);
  const macos = read(macosPath);
  const controlsSeam = read(controlsSeamPath);
  const controlsWindows = read(controlsWindowsPath);
  const startupWindow = read(startupWindowPath);
  const startupWindowWindows = read(startupWindowWindowsPath);
  const compatFiles = zigFiles("src/native_sdk_compat/");
  const compatSource = compatFiles.map(read).join("\n");
  assert.match(app, /\.js_window_api = false/);
  assert.match(app, /\.permissions = &\.\{\}/);
  assert.match(policy, /builtin_command_count: usize = 0/);
  assert.equal(existsSync(new URL("src/window_chrome.zig", root)), false);
  assert.equal(existsSync(new URL("src/windows_host.zig", root)), false);
  assert.doesNotMatch(
    compatSource,
    /\.(?:maximizeWindow|restoreWindow|closeWindow|showWindow|focusWindow|showMessageDialog|showOpenDialog|showNotification|startTimer|cancelTimer|quitApp)\(/,
  );
  assert.doesNotMatch(
    seam,
    /\bgeneration\s*:|\.generation\b|requireCurrent|installPlatformOrDisconnect/,
  );
  assert.match(
    dispatcher,
    /window_chrome_generation: u64[\s\S]*validateWindowChromeSession/,
  );
  assert.match(
    app,
    /startup_window_capture\.take\(main_window_id\)[\s\S]*captureStartupWindow\(startup_binding\)[\s\S]*bindRoot\(\)/,
  );
  assert.doesNotMatch(
    seam.match(/pub fn sync[\s\S]*?pub fn beginLivePointerDrag/)?.[0] ?? "",
    /bindRoot|deinit/,
  );
  assert.doesNotMatch(windows, /EnumChildWindows|bindDocument|installChild/);
  assert.match(rendererChrome, /bridge\.on\("resize", scheduleSync\)/);
  assert.doesNotMatch(
    rendererChrome.match(
      /function onPointerDown[\s\S]*?function onControlClick/,
    )?.[0] ?? "",
    /dragSynchronized = false/,
    "one rejected beginDrag must end only the current gesture",
  );
  assert.doesNotMatch(
    rendererChrome,
    /addEventListener\("resize"|\brefreshAgain\b|\brefresh\(/,
  );
  assert.match(manifest, /\.min_width = 320[\s\S]*\.min_height = 520/);
  assert.deepEqual(
    zigFiles("src/").filter((file) =>
      read(file).includes(
        '@import("native_sdk_compat/system_webview_drag_region.zig")',
      ),
    ),
    ["src/app.zig"],
  );
  assert.deepEqual(
    zigFiles("src/").filter((file) =>
      read(file).includes(
        '@import("native_sdk_compat/system_webview_window_controls.zig")',
      ),
    ),
    ["src/app.zig"],
  );
  assert.deepEqual(
    compatFiles.filter((file) =>
      read(file).includes('@import("system_webview_drag_region/windows.zig")'),
    ),
    [seamPath],
  );
  assert.deepEqual(
    compatFiles.filter((file) =>
      read(file).includes('@import("system_webview_drag_region/macos.zig")'),
    ),
    [seamPath],
  );
  assert.deepEqual(
    compatFiles.filter((file) =>
      read(file).includes(
        '@import("system_webview_window_controls/windows.zig")',
      ),
    ),
    [controlsSeamPath],
  );
  assert.doesNotMatch(
    zigFiles("src/").map(read).join("\n"),
    /(?:services|platform_services)\.context\b|native_sdk\.platform\.windows|GWLP_USERDATA|GetWindowLongPtrW/,
  );
  assert.doesNotMatch(compatSource, /\.context\b/);
  assert.deepEqual(
    compatFiles
      .filter((file) =>
        read(file).includes("native_sdk.platform.PlatformServices"),
      )
      .sort(),
    [seamPath, macosPath, windowsPath].sort(),
  );
  assert.match(
    startupWindowWindows,
    /SetWindowsHookExW[\s\S]*pub const Capture/,
  );
  assert.match(
    startupWindowWindows,
    /candidate_count != 1[\s\S]*GetAncestor[\s\S]*GetWindowThreadProcessId/,
  );
  assert.equal(
    compatFiles.filter((file) => read(file).includes("SetWindowsHookExW"))
      .length,
    1,
  );
  assert.doesNotMatch(
    windows,
    /MetaWorkSystemWebViewChrome|\boverlay\b|RegisterClassExW|SetWindowPos/,
    "the System WebView drag seam must not cover Renderer pixels with another HWND",
  );
  assert.doesNotMatch(
    seam + windows + macos,
    /renderer_controls|maximized|IsZoomed|ShowWindow|user_close/,
    "the drag-region seam must not own window-control capability",
  );
  assert.match(windows, /live_pointer_drag = true/);
  assert.match(
    windows,
    /GetAsyncKeyState[\s\S]*GetCursorPos[\s\S]*WindowFromPoint[\s\S]*GetAncestor[\s\S]*SendMessageW\(root, wm_nchittest[\s\S]*point_is_draggable[\s\S]*ReleaseCapture[\s\S]*PostMessageW/,
  );
  assert.match(macos, /try services\.startWindowDrag\(window_id\)/);
  assert.deepEqual(
    zigFiles("src/").filter((file) =>
      read(file).includes("services.startWindowDrag(window_id)"),
    ),
    [macosPath],
  );
  const allowedDragWindowsSymbols = [
    "GetAncestor",
    "GetAsyncKeyState",
    "GetCursorPos",
    "GetDpiForWindow",
    "GetSystemMetrics",
    "IsWindow",
    "PostMessageW",
    "ReleaseCapture",
    "ScreenToClient",
    "SendMessageW",
    "WindowFromPoint",
  ];
  assert.deepEqual(
    [...windows.matchAll(/extern "(?:user32|kernel32|comctl32)" fn (\w+)/g)]
      .map((match) => match[1])
      .sort(),
    allowedDragWindowsSymbols.sort(),
  );
  const allowedControlWindowsSymbols = [
    "IsZoomed",
    "PostMessageW",
    "ShowWindow",
  ];
  assert.deepEqual(
    [
      ...controlsWindows.matchAll(
        /extern "(?:user32|kernel32|comctl32)" fn (\w+)/g,
      ),
    ]
      .map((match) => match[1])
      .sort(),
    allowedControlWindowsSymbols.sort(),
  );
  const allowedStartupWindowSymbols = [
    "CallNextHookEx",
    "CreateWindowExW",
    "DestroyWindow",
    "GetAncestor",
    "GetCurrentProcessId",
    "GetCurrentThreadId",
    "GetWindow",
    "GetWindowThreadProcessId",
    "IsWindow",
    "SetWindowsHookExW",
    "UnhookWindowsHookEx",
  ];
  assert.deepEqual(
    [
      ...startupWindowWindows.matchAll(
        /extern "(?:user32|kernel32|comctl32)" fn (\w+)/g,
      ),
    ]
      .map((match) => match[1])
      .sort(),
    allowedStartupWindowSymbols.sort(),
  );
  assert.match(app, /native_runtime\.showMessageDialog\(/);
  assert.match(app, /native_runtime\.closeWindow\(main_window_id\)/);
  assert.match(app, /runtime\.minimizeWindow\(main_window_id\)/);
  assert.match(
    app,
    /\.toggle_maximize => try self\.window_controls_capability\.toggleMaximize\(\)/,
  );
  assert.match(
    app,
    /\.close => try self\.window_controls_capability\.userClose\(\)/,
  );
  assert.match(controlsWindows, /PostMessageW\(root, wm_close/);
  assert.match(controlsWindows, /IsZoomed[\s\S]*ShowWindow/);
  assert.match(controlsSeam, /pub fn toggleMaximize[\s\S]*pub fn userClose/);
  assert.doesNotMatch(controlsSeam, /pub const Action|pub fn control\(/);
  assert.match(controlsWindows, /pub fn toggleMaximize[\s\S]*pub fn userClose/);
  assert.doesNotMatch(controlsWindows, /pub fn control\(|switch \(action\)/);
  assert.match(app, /defer app\.drag_region_capability\.deinit\(\)/);
  assert.match(app, /defer app\.window_controls_capability\.deinit\(\)/);
  assert.match(app, /defer app\.startup_window_capture\.deinit\(\)/);
  assert.doesNotMatch(
    windows + controlsWindows,
    /SetWindowsHookExW|armed_capture/,
  );
  assert.match(
    startupWindow,
    /lifecycle plumbing, not a window capability[\s\S]*pub const Binding[\s\S]*pub const Capture/,
  );
  assert.doesNotMatch(app, /services\.closeWindow\(|windows_host/);
  assert.doesNotMatch(
    compatSource,
    /@import\("(?:bridge|workbench|account|agent)(?:\.zig|\/)|window\.zero|metawork\.host\./,
  );
  assert.equal(
    existsSync(new URL("scripts/test-window-chrome-windows.mjs", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("scripts/probe-windows-window-chrome.ps1", root)),
    true,
  );
  const windowsVertical = read("scripts/test-window-chrome-windows.mjs");
  const windowsProbe = read("scripts/probe-windows-window-chrome.ps1");
  assert.match(
    windowsVertical,
    /"-Mode",[\s\S]*"drag"[\s\S]*"-Mode",[\s\S]*"resize"[\s\S]*"-Mode",[\s\S]*"controls"[\s\S]*"-Mode",[\s\S]*"close"[\s\S]*"tray-action", "1"/,
  );
  assert.match(
    windowsProbe,
    /\$Mode -eq 'drag'[\s\S]*Renderer titlebar drag did not move[\s\S]*Dragging the maximized Renderer titlebar did not restore/,
  );
  assert.doesNotMatch(
    windowsProbe,
    /hit-test|ChildWindowFromPointEx|WM_NCHITTEST/,
  );
  assert.match(
    windowsProbe,
    /\$Mode -eq 'resize'[\s\S]*SetWindowPos[\s\S]*Native minimum size was not enforced/,
  );
  assert.match(
    windowsProbe,
    /\$Mode -eq 'controls'[\s\S]*IsIconic[\s\S]*IsZoomed[\s\S]*IsZoomed/,
  );
  assert.match(
    windowsProbe,
    /\$Mode -eq 'close'[\s\S]*HasExited[\s\S]*IsWindow[\s\S]*IsWindowVisible/,
  );
});

test("lifecycle tests are grouped by invariant", () => {
  const cases = [
    ["tests/agent/lifecycle_test.zig", 49],
    ["tests/agent/event_pump_test.zig", 5],
    ["tests/workbench/executor_lifecycle_test.zig", 22],
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
