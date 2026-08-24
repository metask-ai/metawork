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
      if (entry.isDirectory() && entry.name.startsWith(".")) return [];
      if (entry.isDirectory())
        return filesWithExtensions(`${path}/`, extensions);
      return entry.isFile() && extensions.some((ext) => path.endsWith(ext))
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

function externSymbols(source, libraries) {
  const libraryPattern = libraries.join("|");
  return [
    ...source.matchAll(
      new RegExp(`extern "(?:${libraryPattern})" fn (\\w+)`, "g"),
    ),
  ]
    .map((match) => match[1])
    .sort();
}

test("release version has one manifest owner and exact package mirrors", () => {
  const appVersion = read("app.zon").match(/\.version = "([^"]+)"/)?.[1];
  const zigVersion = read("build.zig.zon").match(/\.version = "([^"]+)"/)?.[1];
  const rootPackage = JSON.parse(read("package.json"));
  const rendererPackage = JSON.parse(read("frontend/package.json"));
  const lock = JSON.parse(read("package-lock.json"));

  assert.match(appVersion ?? "", /^0\.\d+\.\d+$/);
  assert.equal(zigVersion, appVersion);
  assert.equal(rootPackage.version, appVersion);
  assert.equal(rendererPackage.version, appVersion);
  assert.equal(lock.version, appVersion);
  assert.equal(lock.packages[""].version, appVersion);
  assert.equal(lock.packages.frontend.version, appVersion);
});

test("automation derives a runner namespace without replacing the product identity", () => {
  const identity = read("src/product_identity.zig");
  const app = read("src/app.zig");

  assert.match(identity, /pub const bundle_id = app_manifest\.id;/);
  assert.match(
    identity,
    /automation_runner_bundle_id = bundle_id \+\+ "\.automation"/,
  );
  assert.match(
    identity,
    /return if \(automation\) automation_runner_bundle_id else bundle_id;/,
  );
  assert.match(
    app,
    /\.bundle_id = product_identity\.runnerBundleId\(build_options\.automation\)/,
  );
  assert.doesNotMatch(
    app,
    /\.bundle_id = product_identity\.automation_runner_bundle_id/,
  );
});

test("the root test entry discovers Node tests and reaches the Native graph", () => {
  const packageJson = JSON.parse(read("package.json"));
  const runner = read("scripts/run-tests.mjs");
  assert.equal(packageJson.scripts.test, "node scripts/run-tests.mjs");
  assert.doesNotMatch(JSON.stringify(packageJson.scripts), /\.test\.mjs/);
  assert.match(runner, /name\.endsWith\("\.test\.mjs"\)/);
  assert.match(runner, /nativeCli, "test", "\."/);
});

test("named module roots exist and lower owners cannot import composition", () => {
  for (const path of [
    "src/app.zig",
    "src/product/account.zig",
    "src/product/mcp.zig",
    "src/agent.zig",
    "src/workbench.zig",
    "src/bridge.zig",
    "src/storage.zig",
  ]) {
    assert.equal(existsSync(new URL(path, root)), true, `${path} must exist`);
  }
  assert.equal(existsSync(new URL("src/agentcore.zig", root)), false);
  assert.equal(existsSync(new URL("src/agentcore/", root)), false);
  assert.equal(existsSync(new URL("src/account.zig", root)), false);
  assert.equal(existsSync(new URL("src/account/", root)), false);
  assert.equal(
    existsSync(new URL("src/workbench/mcp_configuration.zig", root)),
    false,
  );
  assert.equal(existsSync(new URL("src/workbench/testdata/", root)), false);
  const buildSource = read("build.zig");
  assert.match(buildSource, /src\/product\/account\.zig/);
  assert.match(buildSource, /src\/product\/account\/contract\.zig/);
  assert.match(buildSource, /src\/product\/mcp\.zig/);
  assert.match(buildSource, /src\/product\/mcp\/configuration\.zig/);
  assert.doesNotMatch(buildSource, /src\/account(?:\.zig|\/)/);
  assert.doesNotMatch(buildSource, /src\/workbench\/mcp_configuration\.zig/);
  assert.match(buildSource, /addImport\("metawork_account", account\)/);
  assert.match(
    buildSource,
    /addImport\("metawork_account_contract", account_contract\)/,
  );

  const main = read("src/main.zig");
  assert.match(main, /@import\("metawork_app"\)/);
  assert.doesNotMatch(
    main,
    /@import\("(?:metawork_agent|metawork_workbench|metawork_bridge)"\)/,
  );

  const appSource = ["src/app.zig", ...zigFiles("src/app/")]
    .map(read)
    .join("\n");
  for (const name of [
    "metawork_agent",
    "metawork_workbench",
    "metawork_bridge",
    "metawork_automation",
  ]) {
    assert.match(appSource, new RegExp(`@import\\(\\"${name}\\"\\)`));
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
  assertNoImports(zigFiles("src/product/account/"), [
    "metawork_app",
    "metawork_workbench",
    "metawork_bridge",
    "metawork_agent",
    "metask_agentcore",
  ]);
  assertNoImports(zigFiles("src/product/mcp/"), [
    "metawork_app",
    "metawork_workbench",
    "metawork_bridge",
    "metawork_account",
    "metask_agentcore",
    "native_sdk",
  ]);
  assertNoImports(zigFiles("src/bridge/"), [
    "metawork_app",
    "metask_agentcore",
  ]);

  for (const file of [
    "src/product/account.zig",
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

test("Product MCP configuration has one physical module and remains Workbench-held", () => {
  const build = read("build.zig");
  const productMcp = read("src/product/mcp.zig");
  const configuration = read("src/product/mcp/configuration.zig");
  const workbenchRoot = read("src/workbench.zig");
  const workbenchProjection = read("src/workbench/projection.zig");

  assert.equal(
    existsSync(
      new URL("src/product/mcp/testdata/mcp-http-endpoints.json", root),
    ),
    true,
  );
  assert.match(productMcp, /@import\("product_mcp_configuration"\)/);
  assert.match(configuration, /@import\("agent_mcp_http_protocol"\)/);
  assert.doesNotMatch(configuration, /@import\("metawork_agent"\)/);
  assert.match(build, /addImport\("metawork_product_mcp", product_mcp\)/);
  assert.match(
    workbenchProjection,
    /@import\("metawork_product_mcp"\)\.configuration/,
  );
  assert.doesNotMatch(workbenchRoot, /workbench_mcp_configuration/);
  assert.doesNotMatch(workbenchRoot, /pub const McpConfigurationFileStore/);
  assert.doesNotMatch(workbenchRoot, /pub const McpManagementOutcome/);
});

test("Product Account owns Metask protocol without a concrete HTTP client", () => {
  const accountSource = [
    "src/product/account.zig",
    ...zigFiles("src/product/account/"),
  ]
    .map(read)
    .join("\n");
  const adapter = read("src/app/metask_http_transport.zig");
  const app = read("src/app.zig");

  assert.doesNotMatch(accountSource, /std\.http\.Client|StdHttpTransport/);
  assert.match(adapter, /std\.http\.Client/);
  assert.match(adapter, /pub const Adapter = struct/);
  assert.match(app, /account_http\.transport\(\)/);
});

test("Account owns platform ports while Application binds Native SDK effects", () => {
  const accountSource = [
    "src/product/account.zig",
    ...zigFiles("src/product/account/"),
  ]
    .map(read)
    .join("\n");
  const ports = read("src/product/account/ports.zig");
  const runtime = read("src/product/account/runtime.zig");
  const binding = read("src/app/account_platform_binding.zig");
  const app = read("src/app.zig");

  assert.doesNotMatch(
    accountSource,
    /@import\("native_sdk"\)|PlatformServices/,
  );
  assert.doesNotMatch(accountSource, /account_platform_binding|src\/app\//);
  assert.match(ports, /pub const Platform = struct/);
  assert.match(ports, /credentials: credential_store\.Backend/);
  assert.match(ports, /authorization_url: AuthorizationUrl/);
  assert.match(ports, /timer: Timer/);
  assert.match(ports, /model_credentials: ModelCredentialVault/);
  assert.match(runtime, /@import\("account_ports"\)/);
  assert.match(binding, /native_sdk\.platform\.PlatformServices/);
  assert.match(binding, /pub fn ports\(self: \*Adapter\) ports_api\.Platform/);
  assert.match(binding, /\.load_preference_fn = loadPreference/);
  assert.match(binding, /\.commit_preference_fn = commitPreference/);
  assert.match(binding, /\.delete_preference_fn = deletePreference/);
  assert.match(app, /account_platform_binding\.Adapter\.init/);
  assert.match(
    app,
    /coordinator\.shutdown\(\);[\s\S]*coordinator\.drain\(\);[\s\S]*binding\.deinit\(\)/,
  );
});

test("Account owns OAuth callback policy while Application owns loopback sockets", () => {
  const accountSource = [
    "src/product/account.zig",
    ...zigFiles("src/product/account/"),
  ]
    .map(read)
    .join("\n");
  const policy = read("src/product/account/loopback.zig");
  const transport = read("src/app/oauth_loopback_transport.zig");
  const loginAttempt = read("src/product/account/login_attempt.zig");
  const mcpOauth = read("src/app/mcp_oauth.zig");

  assert.doesNotMatch(
    accountSource,
    /std\.Io\.net\.Server|\.listen\(|\.accept\(|std\.http\.Server/,
  );
  assert.match(policy, /pub const RequestSink = struct/);
  assert.match(policy, /pub const CallbackPolicy = struct/);
  assert.match(policy, /oauth\.parseCallbackTargetValidated/);
  assert.match(transport, /listener: std\.Io\.net\.Server/);
  assert.match(transport, /pub const Adapter = struct/);
  assert.match(transport, /sink\.handle/);
  assert.match(loginAttempt, /loopback_endpoint: loopback\.Endpoint/);
  assert.match(mcpOauth, /oauth_loopback_transport\.Server/);
});

test("Storage owns SQLite without entering the Product or Application graph", () => {
  const storageFiles = ["src/storage.zig", ...zigFiles("src/storage/")];
  const storageContract = read("src/storage/sql.zig");
  const build = read("build.zig");
  const packageManifest = read("build.zig.zon");
  const appManifest = read("app.zon");
  const nonStorageFiles = zigFiles("src/").filter(
    (file) => file !== "src/storage.zig" && !file.startsWith("src/storage/"),
  );

  assertNoImports(storageFiles, [
    "metawork_app",
    "metawork_account",
    "metawork_agent",
    "metawork_workbench",
    "metawork_bridge",
    "metask_agentcore",
    "native_sdk",
  ]);
  assert.doesNotMatch(storageContract, /@cImport|sqlite3|storage\/sqlite\.zig/);
  assert.deepEqual(
    storageFiles.filter((file) => /@cImport|sqlite3/.test(read(file))),
    ["src/storage/sqlite.zig"],
  );
  for (const file of nonStorageFiles) {
    assert.doesNotMatch(
      read(file),
      /@import\("(?:metawork[_-]storage|storage\/sqlite\.zig)"\)|@cInclude\("sqlite3\.h"\)|\bsqlite3_/,
      `${file} bypasses the Storage SQL contract`,
    );
  }

  assert.match(build, /const sqlite = b\.dependency\("sqlite", \.\{\}\);/);
  assert.match(build, /storage\.addIncludePath\(sqlite\.path\("\."\)\);/);
  assert.match(build, /storage\.addCSourceFile\(/);
  assert.doesNotMatch(
    build,
    /(?:app|account|agent|workbench|bridge)\.add(?:IncludePath|CSourceFile)\([\s\S]{0,120}sqlite/,
  );
  assert.doesNotMatch(build, /\.addImport\(\s*"metawork[_-]storage"/);
  assert.match(build, /"test-storage"/);
  assert.match(
    packageManifest,
    /\.sqlite = \.\{[\s\S]*?\.url = "https:\/\/www\.sqlite\.org\/\d{4}\/sqlite-amalgamation-\d+\.zip",[\s\S]*?\.hash = "[^"]+",[\s\S]*?\}/,
  );
  assert.doesNotMatch(packageManifest, /latest/i);
  assert.doesNotMatch(appManifest, /"sqlite"/);
});

test("AgentCore SDK access is restricted to Agent modules and the test fixture", () => {
  const nonAgentFiles = zigFiles("src/").filter(
    (file) => file !== "src/agent.zig" && !file.startsWith("src/agent/"),
  );
  assertNoImports(nonAgentFiles, ["metask_agentcore"]);

  const build = read("build.zig");
  const receivers = [
    ...build.matchAll(
      /\b([A-Za-z_]\w*)\s*\.\s*addImport\s*\(\s*"metask_agentcore"\s*,/g,
    ),
  ]
    .map((match) => match[1])
    .sort();
  assert.deepEqual(
    receivers,
    [
      "agent_catalog",
      "agent_checkpoint",
      "agent_checkpoint_restore",
      "agent_completion",
      "agent_mcp_connector",
      "agent_mcp_catalog",
      "agent_mcp_runtime",
      "agent_provider",
      "event_pump",
      "event_sink",
      "fixture",
      "session",
    ].sort(),
  );
  assert.match(read("build.zig.zon"), /\.agentcore\/bundle\/bindings\/zig/);
  assert.doesNotMatch(build, /\.addObjectFile\(/);
});

test("MetaWork Agent capability shaping stays private to Agent", () => {
  const agentRoot = read("src/agent.zig");
  const sessionApi = read("src/agent/session.zig");
  const capabilities = read("src/agent/capabilities.zig");
  const applicationAndWorkbench = [
    "src/app.zig",
    ...zigFiles("src/app/"),
    "src/workbench.zig",
    ...zigFiles("src/workbench/"),
  ]
    .map(read)
    .join("\n");

  assert.match(capabilities, /pub const Builtin = enum/);
  assert.match(capabilities, /\.ask_question => false/);
  assert.doesNotMatch(agentRoot, /capabilities|builtins|allowed_tools/);
  assert.doesNotMatch(sessionApi, /allowed_tools|respondAnswers/);
  assert.doesNotMatch(
    applicationAndWorkbench,
    /BuiltinToolProfile|builtin_tool_profile|builtinToolsForProfile|AskUserQuestion/,
  );
});

test("all active test roots are connected without test-count assertions", () => {
  const build = read("build.zig");
  const externalTests = zigFiles("tests/").filter(
    (path) => !path.startsWith("tests/support/"),
  );
  for (const path of externalTests) {
    assert.ok(build.includes(`"${path}"`), `${path} is absent from build.zig`);
  }

  const inlineAgentTests = zigFiles("src/agent/").filter((path) =>
    /^\s*test(?:\s+"|\s*\{)/m.test(read(path)),
  );
  const sessionRoot = read("src/agent/session.zig");
  for (const path of inlineAgentTests) {
    if (build.includes(`"${path}"`)) continue;
    const relative = path.slice("src/agent/session/".length, -4);
    assert.match(
      sessionRoot,
      new RegExp(`_ = session_${relative}\\s*;`),
      `${path} is not aggregated by session.zig`,
    );
  }
  assert.match(
    build,
    /artifacts\.tests\.step\.dependOn\(&b\.addRunArtifact\(tests\)\.step\)/,
  );
  assert.match(build, /addLifecycleTests\([\s\S]*&artifacts\.tests\.step/);
  assert.match(build, /default_step\.dependOn\(&run\.step\)/);
});

test("Renderer Bridge catalogs and contract identity are exact mirrors", () => {
  const zigCommands = read("src/bridge/commands.zig");
  const rendererCommands = read("frontend/src/bridge/commands.ts");
  const appManifest = read("app.zon");
  const commandPattern =
    /"(metawork\.[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+)"/g;
  const catalog = (source) =>
    [
      ...new Set(
        [...source.matchAll(commandPattern)]
          .map((match) => match[1])
          .filter((name) => name !== "metawork.renderer-bridge"),
      ),
    ].sort();

  assert.deepEqual(catalog(rendererCommands), catalog(zigCommands));
  assert.deepEqual(catalog(appManifest), catalog(zigCommands));
  assert.match(zigCommands, /contract_id = "metawork\.renderer-bridge"/);
  assert.match(zigCommands, /contract_revision: u32 = 1/);
  assert.match(
    rendererCommands,
    /RENDERER_BRIDGE_CONTRACT_ID = "metawork\.renderer-bridge"/,
  );
  assert.match(rendererCommands, /RENDERER_BRIDGE_CONTRACT_REVISION = 1/);
  assert.doesNotMatch(zigCommands + rendererCommands, /metawork\.sessions\./);
});

test("Native compatibility seams have exact owners and symbol allowlists", () => {
  const compatFiles = zigFiles("src/native_sdk_compat/");
  const compatSource = compatFiles.map(read).join("\n");
  const window = read("src/app/window.zig");
  const dragPath = "src/native_sdk_compat/system_webview_drag_region.zig";
  const dragWindowsPath =
    "src/native_sdk_compat/system_webview_drag_region/windows.zig";
  const dragMacosPath =
    "src/native_sdk_compat/system_webview_drag_region/macos.zig";
  const controlsPath =
    "src/native_sdk_compat/system_webview_window_controls.zig";
  const controlsWindowsPath =
    "src/native_sdk_compat/system_webview_window_controls/windows.zig";
  const startupWindowsPath =
    "src/native_sdk_compat/system_webview_startup_window/windows.zig";
  const securePath = "src/native_sdk_compat/secure_input.zig";
  const secureWindowsPath = "src/native_sdk_compat/secure_input/windows.zig";
  const secureMacosPath = "src/native_sdk_compat/secure_input/macos.zig";

  for (const seamPath of [dragPath, controlsPath, securePath]) {
    assert.deepEqual(
      zigFiles("src/").filter((file) =>
        read(file).includes(`native_sdk_compat/${seamPath.split("/").at(-1)}`),
      ),
      ["src/app/window.zig"],
    );
  }
  assert.doesNotMatch(
    compatSource,
    /@import\("(?:bridge|workbench|account|agent)(?:\.zig|\/)|\.context\b/,
  );
  assert.doesNotMatch(
    zigFiles("src/").map(read).join("\n"),
    /(?:services|platform_services)\.context\b|native_sdk\.platform\.windows/,
  );
  assert.deepEqual(
    compatFiles
      .filter((file) =>
        read(file).includes("native_sdk.platform.PlatformServices"),
      )
      .sort(),
    [dragPath, dragMacosPath, dragWindowsPath].sort(),
  );

  assert.deepEqual(
    externSymbols(read(dragWindowsPath), ["user32", "kernel32", "comctl32"]),
    [
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
    ].sort(),
  );
  assert.deepEqual(
    externSymbols(read(controlsWindowsPath), [
      "user32",
      "kernel32",
      "comctl32",
    ]),
    ["IsZoomed", "PostMessageW", "ShowWindow"].sort(),
  );
  assert.deepEqual(
    externSymbols(read(secureWindowsPath), ["user32", "kernel32", "gdi32"]),
    [
      "AdjustWindowRectEx",
      "CreateWindowExW",
      "DefWindowProcW",
      "DestroyWindow",
      "DispatchMessageW",
      "EnableWindow",
      "GetDpiForWindow",
      "GetLastError",
      "GetMessageW",
      "GetModuleHandleW",
      "GetStockObject",
      "GetWindowRect",
      "GetWindowTextLengthW",
      "GetWindowTextW",
      "IsDialogMessageW",
      "IsWindow",
      "IsWindowEnabled",
      "LoadCursorW",
      "PostQuitMessage",
      "RegisterClassExW",
      "SendMessageW",
      "SetActiveWindow",
      "SetFocus",
      "SetLastError",
      "SetWindowTextW",
      "ShowWindow",
      "TranslateMessage",
      "UpdateWindow",
      "WideCharToMultiByte",
    ].sort(),
  );
  assert.deepEqual(
    externSymbols(read(startupWindowsPath), ["user32", "kernel32", "comctl32"]),
    [
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
    ].sort(),
  );
  assert.deepEqual(
    externSymbols(read(secureMacosPath), ["objc"]),
    ["objc_getClass", "objc_msgSend", "sel_registerName"].sort(),
  );
  assert.match(window, /runtime\.showMessageDialog\(/);
});

test("ordinary build and test entries stay isolated from macOS signing", () => {
  const packageJson = JSON.parse(read("package.json"));
  for (const script of ["check", "test", "build:debug", "build:release"]) {
    assert.doesNotMatch(
      packageJson.scripts[script],
      /codesign|package-macos|macos-local-development|scripts\/dev\.mjs/u,
    );
  }
  for (const entry of ["scripts/build.mjs", "scripts/run-tests.mjs"]) {
    assert.doesNotMatch(
      read(entry),
      /codesign|package-macos|macos-local-development|scripts\/dev\.mjs/u,
    );
  }
});

test("development and macOS distribution signing owners stay isolated", () => {
  const development = read("scripts/dev.mjs");
  const setup = read("scripts/setup-macos-local-signing.mjs");
  const distribution = read("scripts/package-macos.mjs");

  assert.match(setup, /from "\.\/dev\.mjs"/u);
  assert.doesNotMatch(setup, /package-macos\.mjs/u);
  assert.doesNotMatch(
    development,
    /package-macos\.mjs|Developer ID Application|notarytool|hdiutil|distributionDiskImage/u,
  );
  assert.doesNotMatch(
    distribution,
    /from "\.\/dev\.mjs"|setup-macos-local-signing|Apple Development|\.metawork-local-signing|runDevelopment|signWithStableRequirement/u,
  );
});
