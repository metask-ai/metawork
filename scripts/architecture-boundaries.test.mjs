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
const applicationFiles = () => ["src/app.zig", ...zigFiles("src/app/")];
const applicationSource = () => applicationFiles().map(read).join("\n");
// Production portion only: this repo appends test declarations at the end of
// a file, so everything before the first top-level `test` is product code.
// Inline test harnesses legitimately construct Bridge-shaped commands and
// must not trip production-source invariants.
const applicationProductionSource = () =>
  applicationFiles()
    .map((file) => read(file).split(/^test[ ("]/m)[0])
    .join("\n");
const boundaryDocs = [
  "README.md",
  "AGENTS.md",
  ...filesWithExtensions("docs/", [".md"]),
];

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

function assertNoApplicationImplementationImports(files) {
  for (const file of files) {
    assert.doesNotMatch(
      read(file),
      /@import\("(?:[^\"]*\/)?app(?:\/[^\"]+\.zig|\.zig)"\)/,
      `${file} imports an Application implementation module`,
    );
  }
}

function sliceBetween(source, startMarker, endMarker, label) {
  const start = source.indexOf(startMarker);
  assert.ok(start >= 0, `${label} start marker must exist`);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `${label} end marker must follow its start marker`);
  return source.slice(start, end);
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

test("package.json stays a thin entry surface instead of an internal call graph", () => {
  // Built from parts so this guard cannot match its own source text.
  const chainedNpmScript = new RegExp(String.raw`\bnpm\s+run\b`);
  const packageJson = JSON.parse(read("package.json"));

  assert.deepEqual(Object.keys(packageJson.scripts).sort(), [
    "build:debug",
    "build:release",
    "check",
    "dev",
    "format",
    "format:check",
    "package:macos",
    "test",
  ]);

  for (const [name, command] of Object.entries(packageJson.scripts)) {
    assert.doesNotMatch(
      command,
      chainedNpmScript,
      `${name} chains another root script instead of invoking its implementation`,
    );
  }

  for (const file of filesWithExtensions("scripts/", [".mjs"])) {
    assert.doesNotMatch(
      read(file),
      chainedNpmScript,
      `${file} depends on a package.json script name at run time`,
    );
  }

  // Test files are discovered from scripts/, never registered, so no manifest
  // can silently drift out of date.
  assert.doesNotMatch(
    JSON.stringify(packageJson.scripts),
    /\.test\.mjs/,
    "package.json must not enumerate individual test files",
  );
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

test("Application consumes named public module roots", () => {
  const source = applicationSource();
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

test("Application root delegates named implementation responsibilities", () => {
  const app = read("src/app.zig");
  for (const implementation of [
    "account_coordinator",
    "agent_event_coordinator",
    "app_automation",
    "frontend",
    "mcp_startup",
    "app_paths",
    "app_platform",
    "app_stores",
    "app_window",
  ]) {
    assert.match(app, new RegExp(`const ${implementation} = @import\\(`));
  }

  assert.deepEqual(
    [...app.matchAll(/^(?:pub )?fn ([A-Za-z_]\w*)\(/gm)]
      .map((match) => match[1])
      .sort(),
    ["createAgentRuntime", "run"],
  );
  const appType = app.match(/const App = struct \{([\s\S]*?)^\};/m)?.[1] ?? "";
  assert.deepEqual(
    [...appType.matchAll(/^    fn ([A-Za-z_]\w*)\(/gm)]
      .map((match) => match[1])
      .sort(),
    ["app", "bridge", "drainAgentEvents", "event", "source", "start", "stop"],
  );

  const mcpStartup = read("src/app/mcp_startup.zig");
  assert.match(mcpStartup, /decodeMcpRegistry/);
  assert.match(mcpStartup, /recoverPendingCredentialTransaction/);

  const platform = read("src/app/platform.zig");
  assert.doesNotMatch(platform, /@import\("automation\.zig"\)|app_automation/);
});

test("active documentation names the current architecture boundaries", () => {
  const architecture = read("docs/architecture.md");
  for (const file of boundaryDocs) {
    const source = read(file);
    assert.equal(
      (source.match(/Desktop Host/g) ?? []).length,
      file === "docs/architecture.md" ? 1 : 0,
      `${file} reintroduces the retired Desktop Host boundary`,
    );
    assert.doesNotMatch(
      source,
      /Product coordinator/,
      `${file} reintroduces coordination inside Product`,
    );
  }

  const compat = zigFiles("src/native_sdk_compat/").map(read).join("\n");
  assert.doesNotMatch(compat, /Desktop Host|Product coordinator/);
  assert.match(architecture, /不再另设 Desktop Host 或 Host infrastructure/);
  assert.match(architecture, /Bridge 是 Renderer 与 MetaWork 本地边界之间/);
  assert.match(
    architecture,
    /产品命令面把 typed 产品命令直接 dispatch 给 Product[\s\S]*不经过 Application 代理/,
  );

  const readme = read("README.md");
  const metawork = sliceBetween(
    readme,
    'subgraph METAWORK["MetaWork"]',
    "    end",
    "README MetaWork boundary",
  );
  assert.match(metawork, /APPLICATION\["Application"\]/);
  assert.match(metawork, /PRODUCT\["Product<br\/>Account \+ Workbench"\]/);
  assert.match(metawork, /AGENT\["Agent"\]/);
  assert.match(
    metawork,
    /NATIVE_COMPAT\["Application-owned<br\/>Native Compat"\]/,
  );
  assert.doesNotMatch(metawork, /AGENTCORE|NATIVE_RUNTIME/);
  assert.match(
    readme.slice(readme.indexOf("    end")),
    /AGENTCORE[\s\S]*NATIVE_RUNTIME/,
  );
});

test("Agent is a peer execution boundary managed by Application", () => {
  const architecture = read("docs/architecture.md");
  assert.match(
    architecture,
    /AGENT\["Agent<br\/>Runtime、Session、Conversation 与 event pump"\]/,
  );
  assert.match(
    architecture,
    /APPLICATION -\. "compose \/ lifecycle" \.-> AGENT/,
  );
  assert.match(
    architecture,
    /PRODUCT -->\|"Workbench execution calls"\| AGENT/,
  );
  assert.match(architecture, /AGENT -->\|"typed bundle ABI"\| AGENTCORE/);
  assert.match(
    architecture,
    /Product 包含 `account` 与 `workbench` 两个产品 owner/,
  );
  assert.doesNotMatch(
    architecture,
    /Product 包含 `account`、`workbench` 与 `agent`|Account、Workbench、Agent/,
  );

  const product = read("docs/product-architecture.md");
  assert.match(product, /Product 内部由两个 named product owners 组成/);
  assert.match(product, /Agent 是 Product 之外的 MetaWork-owned 执行边界/);

  const integration = read("docs/agentcore-integration.md");
  assert.match(integration, /Agent 与 Product 并列/);
  assert.doesNotMatch(
    integration,
    /Desktop Host composition role|Product coordinator/,
  );

  const agents = read("AGENTS.md");
  assert.match(agents, /Product owner、事务、并发、恢复及其与 Agent 的协作/);
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
  for (const importSource of [
    '@import("app/paths.zig")',
    '@import("../app.zig")',
    '@import("../../src/app/paths.zig")',
  ]) {
    assert.match(
      importSource,
      /@import\("(?:[^"]*\/)?app(?:\/[^"]+\.zig|\.zig)"\)/,
    );
  }

  assertNoImports(zigFiles("src/agent/"), [
    "metawork_app",
    "metawork_workbench",
    "metawork_bridge",
    "metawork_account",
  ]);
  assertNoImports(zigFiles("src/workbench/"), [
    "metawork_app",
    "metawork_bridge",
    "metawork_account",
    "metask_agentcore",
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
  const lowerLayerFiles = [
    "src/agent.zig",
    "src/workbench.zig",
    "src/account.zig",
    "src/bridge.zig",
    "src/automation.zig",
    ...zigFiles("src/agent/"),
    ...zigFiles("src/workbench/"),
    ...zigFiles("src/account/"),
    ...zigFiles("src/bridge/"),
    ...zigFiles("src/automation/"),
    ...zigFiles("src/native_sdk_compat/"),
  ];
  assertNoImports(lowerLayerFiles, ["metawork_app"]);
  assertNoApplicationImplementationImports(lowerLayerFiles);
});

test("Agent and Workbench preserve execution owner boundaries", () => {
  const agentFiles = ["src/agent.zig", ...zigFiles("src/agent/")];
  const workbenchFiles = [
    "src/workbench.zig",
    ...zigFiles("src/workbench/"),
  ];

  assertNoImports(agentFiles, ["metawork_account"]);
  assertNoImports(workbenchFiles, ["metask_agentcore"]);
});

test("Session leaf modules stay independent from lifecycle owners", () => {
  for (const file of [
    "src/agent/session/wire.zig",
    "src/agent/session/control.zig",
  ]) {
    const source = read(file);
    assert.doesNotMatch(
      source,
      /@import\(\s*["'][^"']*session\.zig["']\s*\)/,
      `${file} must not import the Session lifecycle root`,
    );
    assert.doesNotMatch(
      source,
      /SessionControlBlock|RunControlLease|agent_runtime/,
      `${file} must not own Session-bound lifecycle handles`,
    );
  }
});

test("Agent inline tests are connected to the formal test graph", () => {
  const build = read("build.zig");
  // Resolve roots that actually have TEST TARGETS, not merely module
  // definitions: test spec entry -> test_modules key -> module variable in
  // the final return block -> that variable's createModule root path.
  const returnBlock = build.slice(
    build.indexOf('root_module.addImport("metawork_app", app);'),
  );
  const directAgentRoots = new Set();
  for (const spec of build.matchAll(/\.root_module = test_modules\.(\w+)/g)) {
    const assignment = returnBlock.match(
      new RegExp(`\\.${spec[1]} = (\\w+),`),
    );
    if (!assignment) continue;
    const module = build.match(
      new RegExp(
        `const ${assignment[1]} = b\\.createModule\\(\\.\\{\\s*` +
          `\\.root_source_file = b\\.path\\("(src/agent/[^"]+\\.zig)"\\)`,
      ),
    );
    if (module) directAgentRoots.add(module[1]);
  }
  const sessionRoot = read("src/agent/session.zig");
  const agentTestFiles = zigFiles("src/agent/").filter((file) =>
    /^\s*test(?:\s+"|\s*\{)/m.test(read(file)),
  );

  assert.ok(
    directAgentRoots.has("src/agent/catalog.zig"),
    "Agent catalog must have a direct test target",
  );
  assert.ok(
    directAgentRoots.has("src/agent/checkpoint.zig"),
    "Agent checkpoint must have a direct test target",
  );
  assert.ok(
    directAgentRoots.has("src/agent/session.zig"),
    "Agent Session must have a direct test target",
  );

  for (const file of agentTestFiles) {
    if (directAgentRoots.has(file)) continue;
    const relative = file.slice("src/agent/session/".length);
    assert.ok(
      file.startsWith("src/agent/session/") && relative.endsWith(".zig"),
      `${file} must be a direct Agent test root or have an explicit aggregate`,
    );
    const symbol = `session_${relative.slice(0, -4)}`;
    assert.match(
      sessionRoot,
      new RegExp(`_ = ${symbol}\\s*;`),
      `${file} must be referenced by session.zig test aggregation`,
    );
  }
});

test("Workbench receives IO independently from the Agent Runtime", () => {
  const workbench = read("src/workbench/projection.zig");
  const configuration = sliceBetween(
    workbench,
    "pub const Configuration = struct {",
    "pub const McpStartupConfiguration = struct {",
    "Workbench Configuration",
  );
  assert.doesNotMatch(configuration, /\bio:\s*std\.Io\b/);

  const workbenchFields = sliceBetween(
    workbench,
    "pub const Workbench = struct {",
    "    pub fn init(",
    "Workbench fields",
  );
  assert.equal((workbenchFields.match(/^    io: std\.Io,$/gm) ?? []).length, 1);

  const workbenchInit = sliceBetween(
    workbench,
    "    pub fn init(",
    "    pub fn setScheduleBackgroundAvailableNoFail(",
    "Workbench.init",
  );
  assert.match(
    workbenchInit,
    /allocator: std\.mem\.Allocator,\s*io: std\.Io,\s*agent_runtime: \*lifecycle\.Runtime/,
  );
  assert.match(workbenchInit, /Executor\.create\(io, allocator,/);
  assert.match(workbenchInit, /\.io = io,/);

  const production = workbench.slice(
    0,
    workbench.indexOf("var test_agent_runtime:"),
  );
  assert.doesNotMatch(production, /\b(?:self\.)?agent_runtime\.io\b/);
  assert.doesNotMatch(
    read("src/app/account_coordinator.zig"),
    /agent_runtime\.io\s*=/,
  );
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
      "agent_checkpoint",
      "agent_checkpoint_restore",
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
    "build_support/agentcore-bundle.windows.lock.json",
    "build_support/agentcore-bundle.macos.lock.json",
  ]) {
    assert.equal(existsSync(new URL(lock, root)), true);
  }
  const probeRunner = read("scripts/run-agentcore-probe.mjs");
  assert.match(probeRunner, /bundle\/bindings\/zig/);
  assert.match(probeRunner, /agentcore-restore-probe\.zig/);
  assert.match(probeRunner, /addRunArtifact/);
  assert.match(probeRunner, /source-free AgentCore Zig package consumer/);
  const restoreProbe = read("scripts/probes/agentcore-restore-probe.zig");
  assert.match(restoreProbe, /agentcore\.Api\.discover\(\)/);
  assert.match(restoreProbe, /sessionRestore\(\)/);
  assert.match(restoreProbe, /short_read_limit/);
  assert.match(restoreProbe, /eof_calls/);
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

test("Account Runtime owns policy while Application installs execution explicitly", () => {
  const app = applicationSource();
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
  assert.match(accountRuntime, /fn startLoadIdentity\(/);
  assert.doesNotMatch(
    app,
    /CredentialOwner|automaticApiSelection|automaticModelSelection|prepareAndPersistExecution|startLoadIdentity|mailbox_mutex/,
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
  const app = read("src/app/account_coordinator.zig");
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
    /\.startup, \.default => \{[\s\S]*?self\.workbench\.beginDefaultExecutionReplacement\(\)/,
  );
  assert.match(
    app,
    /\.identity => \{[\s\S]*?self\.workbench\.beginExecutionReplacement\(\)/,
  );
  const workbench = read("src/workbench/projection.zig");
  assert.match(
    workbench,
    /const ExecutionReplacementKind = enum \{ none, default, identity \}/,
  );
  assert.doesNotMatch(app, /active_replacement:/);
});

test("Account persistence has one refresh-only cross-platform owner", () => {
  const appZon = read("app.zon");
  const build = read("build.zig");
  const identity = read("src/product_identity.zig");
  const app = read("src/app.zig");
  const paths = read("src/app/paths.zig");
  const store = read("src/account/credential_store.zig");
  const platform = read("src/account/platform.zig");
  const accountRuntime = read("src/account/runtime.zig");
  const accountState = read("src/account/state.zig");
  const workbench = read("src/workbench/projection.zig");
  assert.match(appZon, /\.id = "com\.metask\.metawork\.dev"/);
  assert.match(identity, /const app_manifest = @import\("app_manifest_zon"\)/);
  assert.match(identity, /pub const bundle_id = app_manifest\.id/);
  assert.doesNotMatch(identity, /com\.metask\.metawork\.dev/);
  assert.match(
    identity,
    /pub const macos_data_directory_name = "MetaWork Dev"/,
  );
  assert.doesNotMatch(identity, /account_keychain_service|manifest_name/);
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
  assert.match(paths, /\.name = dataDirectoryName\(builtin\.os\.tag\)/);
  assert.match(app, /\.bundle_id = product_identity\.bundle_id/);
  assert.match(
    store,
    /product_identity\.bundle_id \+\+ "\.automation\.account"/,
  );
  assert.match(store, /product_identity\.bundle_id \+\+ "\.account"/);
  assert.match(
    store,
    /pub const refresh_token_account = "metask-refresh-token"/,
  );
  assert.match(store, /pub const preference_name = "preferences\.json"/);
  assert.match(store, /selection_owner_account_id/);
  assert.match(store, /execution_generation: u64/);
  assert.match(accountRuntime, /std\.Io\.randomSecure\(io, &bytes\)/);
  assert.match(accountRuntime, /fn savedExecutionGenerationFor\(/);
  assert.match(platform, /pub const NativeBackend = struct/);
  assert.equal(
    existsSync(new URL("../src/account/windows_store.zig", import.meta.url)),
    false,
  );
  assert.match(platform, /\.service = store\.service/);
  assert.match(platform, /\.account = store\.refresh_token_account/);
  assert.match(platform, /ignore_unknown_fields = false/);
  assert.match(
    paths,
    /const automation_data_directory_name = "MetaWork Automation"/,
  );
  assert.match(paths, /if \(build_options\.automation\)/);
  assert.doesNotMatch(
    `${store}\n${platform}`,
    /manifest|active_slot|execution_slot|account\.json|access_token|display_name/,
  );
  assert.doesNotMatch(
    `${store}\n${platform}\n${accountRuntime}\n${accountState}\n${workbench}`,
    /execution[_-]watermark|ExecutionGenerationFloor|execution_generation_floor|execution_high_watermark|scheduledExecutionGenerationFloor/,
  );
  assert.doesNotMatch(`${store}\n${platform}`, /dev\.metawork\.account/);
  assert.equal(
    existsSync(
      new URL("../scripts/cleanup-legacy-macos-account.mjs", import.meta.url),
    ),
    false,
  );
  assert.equal(
    existsSync(
      new URL("../scripts/macos-account-cleanup.test.mjs", import.meta.url),
    ),
    false,
  );
  assert.equal(
    JSON.parse(read("package.json")).scripts["account:cleanup-legacy:macos"],
    undefined,
  );
  assert.match(accountRuntime, /credential_store\.restore/);
  assert.doesNotMatch(
    accountRuntime,
    /windows_store|prepareWindowsRestore|prepareMacosRestore/,
  );
});

test("Account commits OAuth rotation before strict current-user identity", () => {
  const login = read("src/account/login_attempt.zig");
  const client = read("src/account/metask_client.zig");
  const runtime = read("src/account/runtime.zig");
  const state = read("src/account/state.zig");
  const store = read("src/account/credential_store.zig");
  assert.match(login, /exchangeAuthorizationCode/);
  assert.doesNotMatch(login, /fetchIdentity|exchangeAndIdentify/);
  const authorizationCommit = runtime.slice(
    runtime.indexOf("fn prepareAuthorizedLogin("),
    runtime.indexOf("fn prepareRefreshedTokens("),
  );
  assert.ok(
    authorizationCommit.indexOf("credential_store.commitRefresh(") <
      authorizationCommit.indexOf("self.credentials.replace(tokens)"),
  );
  assert.match(authorizationCommit, /\.payload = \.tokens_persisted/);
  assert.match(state, /\.tokens_persisted => self\.prepareTokensPersisted\(\)/);
  assert.match(state, /\.load_identity/);
  assert.match(
    client,
    /if \(response\.status != 200\)\s*return classifyStatus/,
  );
  assert.match(
    runtime,
    /error_code == \.metask_unauthorized[\s\S]*self\.deleteInvalidCredential\(\)/,
  );
  assert.match(
    runtime,
    /state == \.signed_out[\s\S]*self\.credentials\.refreshAvailable\(\)/,
  );
  assert.doesNotMatch(
    `${client}\n${state}`,
    /accountOnlyIdentity|exchangeAndIdentify|account_only|reauth_required/,
  );
  assert.match(store, /backend\.deletePreference\(\) catch \{\}/);
});

test("macOS development and Developer ID distribution signing are explicit and isolated", () => {
  const packageJson = JSON.parse(read("package.json"));
  // The invariant is which entries reach the signing script, not how each one
  // spells its command line. One-time identity selection is a documented script
  // invocation and must not reappear as an entry.
  assert.deepEqual(
    Object.entries(packageJson.scripts)
      .filter(([, command]) => command.includes("macos-local-signing"))
      .map(([name]) => name)
      .sort(),
    ["dev", "package:macos"],
  );
  for (const script of ["check", "test", "build:debug", "build:release"]) {
    assert.doesNotMatch(
      packageJson.scripts[script],
      /codesign|macos-local-signing/u,
      `${script} must not depend on a developer's local certificate`,
    );
  }
  // Those entries now delegate to scripts, so the isolation has to hold one
  // level down as well.
  for (const entry of ["scripts/build.mjs", "scripts/run-tests.mjs"]) {
    assert.doesNotMatch(
      read(entry),
      /codesign|macos-local-signing/u,
      `${entry} must not reach local signing on the ordinary build or test path`,
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
  assert.match(signing, /Developer ID Application/u);
  assert.match(signing, /resolveDistributionIdentity/u);
  assert.match(signing, /buildDeveloperIdRequirement/u);
  assert.match(signing, /verifyDeveloperIdSignature/u);
  assert.match(signing, /"--options",\s*"runtime"/u);
  assert.match(signing, /"--timestamp"/u);
  assert.match(signing, /notarytool/u);
  assert.match(signing, /"metawork-notary"/u);
  assert.match(signing, /"Accepted"/u);
  assert.match(signing, /stapler/u);
  assert.match(signing, /spctl/u);
  assert.match(signing, /--sequesterRsrc/u);
  assert.match(signing, /--keepParent/u);
  assert.match(signing, /validateCanonicalDesignatedRequirement/u);
  assert.match(signing, /"--requirements"/u);
  assert.match(signing, /`-R=\$\{policy\}`/u);
  assert.match(signing, /"--team-id",\s*identity\.teamId/u);
  assert.match(signing, /\.metawork-local-signing\.json/u);

  const setup = read("scripts/setup-macos-local-signing.mjs");
  assert.match(setup, /verifyPrivateKeyAccess/u);
  assert.match(setup, /add-certificates/u);
  assert.doesNotMatch(setup, /delete-generic-password|cleanup-legacy/u);

  for (const forbidden of ["openssl", "add-trusted-cert", "delete-identity"]) {
    assert.doesNotMatch(
      setup,
      new RegExp(forbidden, "u"),
      `local setup must not generate, override trust for, or delete a signing identity: ${forbidden}`,
    );
  }

  const verifier = read("scripts/verify-macos-package.mjs");
  assert.match(verifier, /localProductIdentity\.bundleId/u);
  assert.match(verifier, /resolveDistributionIdentity/u);
  assert.match(verifier, /verifyDeveloperIdSignature/u);
  assert.doesNotMatch(verifier, /verifyStableSignature/u);
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
  const eventCoordinator = read("src/app/agent_event_coordinator.zig");
  const workbench = read("src/workbench/projection.zig");
  assert.doesNotMatch(applicationSource(), /bridge_pipeline_failure/);
  assert.match(eventCoordinator, /wake_pending\.swap\(true, \.acq_rel\)/);
  const coordinatorDrain = sliceBetween(
    eventCoordinator,
    "    pub fn drain(",
    "\n};",
    "Coordinator.drain",
  );
  const clearWake = coordinatorDrain.indexOf(
    "self.wake_pending.store(false, .release);",
  );
  const drainEvents = coordinatorDrain.indexOf(
    "workbench.drainAgentEvents() catch {};",
  );
  assert.ok(clearWake >= 0 && clearWake < drainEvents);
  assert.doesNotMatch(
    eventCoordinator,
    /takeEvent|applyEvent|markTerminalRunsBeforeEventDrain|finalizeMarkedTerminalRunsAfterEventDrain|recordEventProjectionFailure|requestRunTermination/,
  );

  const workbenchDrain = sliceBetween(
    workbench,
    "    pub fn drainAgentEvents(",
    "    fn drainAgentEventPass(",
    "Workbench.drainAgentEvents",
  );
  const firstDrain = workbenchDrain.indexOf(
    "self.drainAgentEventPass(&first_projection_error);",
  );
  const markTerminal = workbenchDrain.indexOf(
    "self.markTerminalRunsBeforeEventDrain();",
  );
  const secondDrain = workbenchDrain.indexOf(
    "self.drainAgentEventPass(&first_projection_error);",
    firstDrain + 1,
  );
  const finalizeTerminal = workbenchDrain.indexOf(
    "self.finalizeMarkedTerminalRunsAfterEventDrain();",
  );
  const returnProjectionError = workbenchDrain.indexOf(
    "if (first_projection_error) |err| return err;",
  );
  assert.ok(
    firstDrain >= 0 &&
      firstDrain < markTerminal &&
      markTerminal < secondDrain &&
      secondDrain < finalizeTerminal &&
      finalizeTerminal < returnProjectionError,
  );
  assert.match(
    workbench,
    /main-loop-thread only\.[\s\S]{0,200}after Executor and Agent Runtime shutdown,[\s\S]{0,200}pub fn drainAgentEvents/,
  );

  const drainPass = sliceBetween(
    workbench,
    "    fn drainAgentEventPass(",
    "    pub fn applyEvent(",
    "Workbench.drainAgentEventPass",
  );
  const applyFailure = drainPass.indexOf(
    "self.applyEvent(&envelope) catch |err| {",
  );
  const retainFailure = drainPass.indexOf("first_projection_error.* = err;");
  const recordFailure = drainPass.indexOf("self.recordEventProjectionFailure(");
  const requestTermination = drainPass.indexOf(
    "self.agent_runtime.requestRunTermination(",
  );
  assert.ok(
    applyFailure >= 0 &&
      applyFailure < retainFailure &&
      retainFailure < recordFailure &&
      recordFailure < requestTermination,
  );

  const appStop = sliceBetween(
    app,
    "    fn stop(",
    "    fn event(",
    "App.stop",
  );
  const stopIngress = appStop.indexOf("dispatcher.stopIngress();");
  const quiesceCallbacks = appStop.indexOf("dispatcher.assertQuiescent();");
  const detachWorkbench = appStop.indexOf("dispatcher.detachWorkbench();");
  assert.ok(stopIngress >= 0 && stopIngress < quiesceCallbacks);
  assert.ok(quiesceCallbacks < detachWorkbench);
  const shutdownRuntime = appStop.indexOf("try agent_runtime.shutdown();");
  const drainAfterShutdown = appStop.indexOf("self.drainAgentEvents();");
  const syncLifecycle = appStop.indexOf("workbench.syncLifecycle();");
  assert.ok(
    shutdownRuntime >= 0 &&
      shutdownRuntime < drainAfterShutdown &&
      drainAfterShutdown < syncLifecycle,
  );
  const allSource = zigFiles("src/").map(read).join("\n");
  assert.equal(
    (allSource.match(/workbench\.drainAgentEvents\(\)/g) ?? []).length,
    1,
    "Application coordinator must be the only production Workbench event-drain caller",
  );
  const workbenchProduction = workbench.slice(
    0,
    workbench.indexOf("var test_agent_runtime:"),
  );
  assert.doesNotMatch(
    workbenchProduction,
    /self\.drainAgentEvents\(\)/,
    "Workbench workers must not invoke the main-loop-only event drain",
  );

  const lifecycleFixture = read("tests/support/lifecycle_fixture.zig");
  const waitWorkbenchSnapshot = sliceBetween(
    lifecycleFixture,
    "pub fn waitWorkbenchSnapshot(",
    "pub fn closeOnThread(",
    "waitWorkbenchSnapshot",
  );
  assert.match(waitWorkbenchSnapshot, /try workbench\.drainAgentEvents\(\);/);
  assert.doesNotMatch(waitWorkbenchSnapshot, /runtime: \*lifecycle\.Runtime/);

  const executorLifecycle = read("tests/workbench/executor_lifecycle_test.zig");
  const waitTaskSnapshot = sliceBetween(
    executorLifecycle,
    "fn waitTaskSnapshot(",
    "fn waitCatalogUnavailable(",
    "waitTaskSnapshot",
  );
  assert.match(waitTaskSnapshot, /try workbench\.drainAgentEvents\(\);/);
  assert.doesNotMatch(waitTaskSnapshot, /runtime: \*lifecycle\.Runtime/);

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
  const application = applicationSource();
  assert.match(app, /dispatcher: \?\*bridge_api\.Dispatcher/);
  assert.match(app, /automation: app_automation\.Adapter/);
  assert.doesNotMatch(
    application,
    /event_window_id|bridge_callbacks_active|revision_delivery:\s|snapshot_delivery:\s/,
  );
  assert.doesNotMatch(
    application,
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

test("AgentCore vertical owns an isolated platform data root", () => {
  const vertical = read("scripts/test-agentcore-vertical-macos.mjs");
  assert.match(
    vertical,
    /mkdtemp\(join\(tmpdir\(\), "metawork-agentcore-vertical-"\)\)/,
  );
  assert.match(
    vertical,
    /const platformHome = join\(canonicalWorkspace, "platform-home"\)/,
  );
  assert.match(
    vertical,
    /\{ APPDATA: platformHome, LOCALAPPDATA: platformHome \}/,
  );
  assert.match(vertical, /path\.relative\(canonicalWorkspace, dataRoot\)/);
  assert.match(vertical, /vertical data root escaped its fixture/);
  assert.match(vertical, /await automate\("tray-action", "2"\)/);
  assert.doesNotMatch(vertical, /native-sdk\.window\.close/);
  assert.match(
    vertical,
    /const automationDataDirectoryName = "MetaWork Automation"/,
  );
  assert.doesNotMatch(
    vertical,
    /join\(platformHome, "MetaWork", "Data"\)|"MetaWork Dev"/,
  );
  assert.match(
    vertical,
    /env:\s*\{[\s\S]*?\.\.\.process\.env,[\s\S]*?\.\.\.isolatedPlatformEnv,/,
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

test("checkpoint persistence stays behind the Agent and Workbench owners", () => {
  const prohibited = [
    "src/bridge.zig",
    ...zigFiles("src/bridge/"),
    "src/account.zig",
    ...zigFiles("src/account/"),
    ...filesWithExtensions("frontend/src/", [".ts", ".tsx"]),
  ];
  for (const file of prohibited) {
    const source = read(file).replaceAll("checkpoint_unavailable", "");
    assert.doesNotMatch(
      source,
      /checkpoint/i,
      `${file} must not gain checkpoint product or persistence surface`,
    );
  }

  const agent = read("src/agent/session.zig");
  assert.equal(
    [...agent.matchAll(/durable_budget\s*=\s*null/g)].length,
    2,
    "create and restore must both leave the AgentCore-owned durable budget unset",
  );
  const productionCheckpointCallers = zigFiles("src/").filter((file) =>
    /\.exportCheckpoint\(/.test(read(file)),
  );
  assert.deepEqual(productionCheckpointCallers, [
    "src/workbench/projection.zig",
  ]);

  const workbench = read("src/workbench/projection.zig");
  const workerPostprocess = sliceBetween(
    workbench,
    "fn postprocessCheckpoint(",
    "fn publishCheckpointFailure(",
    "checkpoint worker postprocess",
  );
  const blobCommit = workerPostprocess.indexOf("writer.commit(");
  const candidatePublication = workerPostprocess.indexOf(
    "postprocess.state.store(.candidate_ready",
  );
  assert.ok(blobCommit >= 0 && blobCommit < candidatePublication);

  const mainCommit = sliceBetween(
    workbench,
    "fn commitCheckpointPostprocessNoFail(",
    "pub fn drainAgentEvents(",
    "checkpoint main-thread commit",
  );
  const candidateConsumption = mainCommit.indexOf(".candidate_ready =>");
  const descriptorCommit = mainCommit.indexOf(
    "self.commitTaskStateWithCheckpoint(",
  );
  const descriptorInstall = mainCommit.indexOf(
    "task.durable.checkpoint = candidate.record",
  );
  assert.ok(
    candidateConsumption >= 0 &&
      candidateConsumption < descriptorCommit &&
      descriptorCommit < descriptorInstall,
  );

  const executeRun = sliceBetween(
    workbench,
    "fn executeRunJob(",
    "fn executeCompactJob(",
    "Run executor job",
  );
  const executeCompact = sliceBetween(
    workbench,
    "fn executeCompactJob(",
    "const CheckpointSinkContext",
    "compact executor job",
  );
  for (const [name, worker] of [
    ["Run", executeRun],
    ["compact", executeCompact],
  ]) {
    assert.match(worker, /checkpoint_export_context/);
    assert.doesNotMatch(
      worker,
      /latestCompactId\(|lastFinalizedRunId\(|\.task\.durable/,
      `${name} worker must consume admission-captured checkpoint facts instead of traversing Task durable state`,
    );
  }
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
  const drainPass = sliceBetween(
    workbench,
    "    fn drainAgentEventPass(",
    "    pub fn applyEvent(",
    "Workbench.drainAgentEventPass",
  );
  assert.match(
    drainPass,
    /applyEvent\(&envelope\) catch[\s\S]*recordEventProjectionFailure/,
  );
  assert.doesNotMatch(workbench, /snapshot\.last_outcome|snapshot\.cause/);
});

test("Workbench owns Task lifecycle, continuation, and canonical redaction", () => {
  const workbench = read("src/workbench/projection.zig");
  const taskRuntime = read("src/workbench/task_runtime.zig");
  const taskRecord = workbench.slice(
    workbench.indexOf("const DurableTaskRecord = struct"),
    workbench.indexOf("fn FixedText"),
  );
  const durableTaskRecord = taskRecord.slice(
    taskRecord.indexOf("const DurableTaskRecord = struct"),
    taskRecord.indexOf("const CheckpointHealth = enum"),
  );
  assert.doesNotMatch(durableTaskRecord, /lifecycle: TaskLifecycle/);
  assert.doesNotMatch(
    durableTaskRecord,
    /continuation: ContinuationCapability/,
  );
  assert.match(taskRuntime, /pub const Attachment = union\(enum\)/);
  assert.match(taskRuntime, /pub const ActiveOperation = union\(enum\)/);
  assert.match(workbench, /fn taskLifecycle[\s\S]*task\.durable\.closed/);
  assert.match(workbench, /fn taskRecoveryProjection/);
  assert.match(taskRecord, /durable: DurableTaskRecord/);
  assert.match(taskRecord, /runtime: RuntimeAttachment/);
  assert.doesNotMatch(
    durableTaskRecord,
    /account_id|account_name|api_key|selection_id|display_name/,
  );
  assert.match(
    durableTaskRecord,
    /execution_generation:[\s\S]*execution_provider:[\s\S]*execution_model:/,
  );
  const taskPersistence = read("src/workbench/task_persistence.zig");
  const bindingWire = taskPersistence.slice(
    taskPersistence.indexOf("pub const BindingWire = struct"),
    taskPersistence.indexOf("pub const OperationWire = struct"),
  );
  assert.doesNotMatch(bindingWire, /account|api_key|selection|display_name/);
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
  assert.match(read("src/app/paths.zig"), /resolveCanonicalUserHome/);
  assert.match(
    read("src/app.zig"),
    /\.canonical_user_home = paths_state\.canonical_user_home/,
  );
  assert.doesNotMatch(read("src/bridge/dispatcher.zig"), /canonical_user_home/);
  assert.match(
    workbench,
    /pub fn renameTask[\s\S]*copyProjected\([\s\S]*execution\.input\(\)\.api_key[\s\S]*view\.durable\.title_redacted = projected\.redacted/,
  );
  assert.match(taskRuntime, /execution: owned_execution\.OwnedTaskExecution/);
  assert.match(
    workbench,
    /const OwnedTaskExecution = owned_task_execution\.OwnedTaskExecution/,
  );
  assert.match(
    read("src/workbench/owned_task_execution.zig"),
    /pub const OwnedTaskExecution = struct/,
  );
  assert.match(workbench, /account_contract\.validateExecutionConfig\(input\)/);
  assert.match(workbench, /redaction_secret = execution\.api_key/);
  assert.match(workbench, /fn releaseExecutionValueNoFail/);
  const releaseTaskExecution = workbench.slice(
    workbench.indexOf("fn releaseExecutionValueNoFail"),
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

test("Bridge owns ingress, Account owns validation, and Application coordinates commits", () => {
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
  const application = applicationSource();
  const accountCoordinator = read("src/app/account_coordinator.zig");
  const accountRuntime = read("src/account/runtime.zig");
  assert.match(
    accountRuntime,
    /expected_catalog_generation !=\s*account_view\.catalog_generation/,
  );
  assert.match(
    accountRuntime,
    /return \.\{ \.rejected = \.generation_mismatch \}/,
  );
  assert.doesNotMatch(
    applicationProductionSource(),
    /expected_catalog_generation|generation_mismatch/,
  );
  assert.match(
    accountCoordinator,
    /workbench\.commitAccountFactNoFail\(fact\)/,
  );
  assert.match(accountCoordinator, /runtime\.commit\(&prepared\)/);
  assert.match(app, /bridge_api\.Dispatcher\.init/);
  assert.match(app, /\.register\(/);
  assert.doesNotMatch(
    application,
    /fn (?:createTask|runTask|cancelTask|respondUi|closeTask|renameTask|archiveTask|deleteTask)\(/,
  );
  assert.doesNotMatch(application, /parsePayload|parseWireId|workspaceGrant/);
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
  assert.ok(catalog(zigCommands).includes("metawork.account.beginLogin"));
  assert.ok(!catalog(zigCommands).includes("metawork.account.reopenLogin"));
  assert.ok(!catalog(zigCommands).includes("metawork.account.reauthenticate"));
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
  assert.deepEqual(
    catalog(zigCommands).filter((command) =>
      command.startsWith("metawork.mcp."),
    ),
    [
      "metawork.mcp.approveConnection",
      "metawork.mcp.authorizeOAuth",
      "metawork.mcp.cancelAuthorization",
      "metawork.mcp.captureSecret",
      "metawork.mcp.createHttpServer",
      "metawork.mcp.createStdioServer",
      "metawork.mcp.refreshCatalog",
      "metawork.mcp.removeServer",
      "metawork.mcp.renameServer",
      "metawork.mcp.setAllowedTools",
      "metawork.mcp.setServerEnabled",
      "metawork.mcp.testConnection",
      "metawork.mcp.updateHttpConnection",
      "metawork.mcp.updateStdioConnection",
    ],
  );
  assert.doesNotMatch(zigCommands, /mcp\.(?:upsert|configure|setCredential)/i);
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
  assert.match(handlers, /expectedDesiredGeneration/);
  assert.match(handlers, /toolNames/);
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
  const mcpProjection = projection.slice(
    projection.indexOf("fn writeMcpSecretSlots"),
    projection.indexOf("fn finalizeMarkedTerminalRunsAfterEventDrain"),
  );
  assert.match(
    mcpProjection,
    /server\.transport\.command[\s\S]*server\.transport\.arguments[\s\S]*server\.transport\.cwd[\s\S]*server\.transport\.url/,
  );
  assert.doesNotMatch(
    mcpProjection,
    /\\"(?:credentialLocator|credentialRef|clientSecret|accessToken|refreshToken|authorizationCode|pkce|fingerprint)\\"|catalogIssues|schema body|AgentCore/,
  );
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
  assert.match(contracts, /state: AccountState/);
  assert.match(contracts, /catalogState: CatalogState/);
  assert.doesNotMatch(contracts, /AccountReadiness|AccountPrimaryAction/);
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

test("Renderer declares window chrome UI while Application owns native behavior", () => {
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
  const window = read("src/app/window.zig");
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
    window,
    /startup_window_capture\.take\(main_window_id\)[\s\S]*drag_region_capability\.captureStartupWindow\(startup_binding\)[\s\S]*window_controls_capability\.captureStartupWindow\(startup_binding\)[\s\S]*bindRoot\(\)/,
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
      read(file).includes('native_sdk_compat/system_webview_drag_region.zig")'),
    ),
    ["src/app/window.zig"],
  );
  assert.deepEqual(
    zigFiles("src/").filter((file) =>
      read(file).includes(
        'native_sdk_compat/system_webview_window_controls.zig")',
      ),
    ),
    ["src/app/window.zig"],
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
  assert.match(window, /runtime\.showMessageDialog\(/);
  assert.match(window, /runtime\.closeWindow\(main_window_id\)/);
  assert.match(window, /runtime\.minimizeWindow\(main_window_id\)/);
  assert.match(
    window,
    /\.toggle_maximize => try self\.window_controls_capability\.toggleMaximize\(\)/,
  );
  assert.match(
    window,
    /\.close => try self\.window_controls_capability\.userClose\(\)/,
  );
  assert.match(controlsWindows, /PostMessageW\(root, wm_close/);
  assert.match(controlsWindows, /IsZoomed[\s\S]*ShowWindow/);
  assert.match(controlsSeam, /pub fn toggleMaximize[\s\S]*pub fn userClose/);
  assert.doesNotMatch(controlsSeam, /pub const Action|pub fn control\(/);
  assert.match(controlsWindows, /pub fn toggleMaximize[\s\S]*pub fn userClose/);
  assert.doesNotMatch(controlsWindows, /pub fn control\(|switch \(action\)/);
  assert.match(app, /defer app\.platform\.deinit\(\)/);
  assert.match(window, /self\.startup_window_capture\.deinit\(\)/);
  assert.match(window, /self\.drag_region_capability\.deinit\(\)/);
  assert.match(window, /self\.window_controls_capability\.deinit\(\)/);
  assert.doesNotMatch(
    windows + controlsWindows,
    /SetWindowsHookExW|armed_capture/,
  );
  assert.match(
    startupWindow,
    /lifecycle plumbing, not a window capability[\s\S]*pub const Binding[\s\S]*pub const Capture/,
  );
  assert.doesNotMatch(
    applicationSource(),
    /services\.closeWindow\(|windows_host/,
  );
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
    ["tests/agent/lifecycle_test.zig", 61],
    ["tests/agent/event_pump_test.zig", 5],
    ["tests/workbench/executor_lifecycle_test.zig", 32],
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

  const runner = read("scripts/run-lifecycle-tests.mjs");
  assert.match(runner, /"test-lifecycle"/);
  assert.match(runner, /cwd: repositoryRoot/);
  assert.doesNotMatch(runner, /host-lifecycle|HOST_LIFECYCLE_TEST_FILTER/);
});
