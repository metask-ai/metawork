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

function moduleImportEdges(buildSource) {
  return [
    ...buildSource.matchAll(
      /\b([A-Za-z_]\w*)\.addImport\(\s*"([^"]+)"\s*,\s*([A-Za-z_]\w*)\s*\)/g,
    ),
  ].map((match) => ({ owner: match[1], name: match[2], target: match[3] }));
}

function assertNoModuleTargets(buildSource, owners, forbiddenTargets) {
  for (const edge of moduleImportEdges(buildSource)) {
    if (!owners.includes(edge.owner) || !forbiddenTargets.includes(edge.target))
      continue;
    assert.fail(
      `${edge.owner} imports forbidden build module ${edge.target} as ${edge.name}`,
    );
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

test("permission reviewer is an isolated Completion consumer without approval authority", () => {
  const build = read("build.zig");
  const source = read("src/product/permission/review.zig");
  assert.deepEqual(
    moduleImportEdges(build).filter(
      (edge) => edge.owner === "product_permission_review",
    ),
    [
      {
        owner: "product_permission_review",
        name: "agent_completion",
        target: "agent_completion",
      },
    ],
  );
  assert.match(build, /src\/product\/permission\/review\.zig/);
  assert.match(
    build,
    /name = "metawork-product-permission-review", .root_module = test_modules\.product_permission_review/,
  );
  assert.match(build, /"test-permission-review"/);
  const imports = [...source.matchAll(/@import\("([^"]+)"\)/g)].map(
    (match) => match[1],
  );
  assert.deepEqual(imports, ["std", "agent_completion"]);
  assert.doesNotMatch(
    source,
    /respondPermission|WorkerLease|@import\(".*(?:task|control|app|metask_agentcore)/,
  );
  assert.equal(existsSync(new URL("src/product/permission.zig", root)), false);
});

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

  const viteConfig = read("frontend/vite.config.ts");
  const rendererIdentity = read("frontend/src/app/product-identity.ts");
  assert.match(
    viteConfig,
    /readNativePackageManifest\(repositoryRoot\)\.metadata/,
  );
  assert.match(
    viteConfig,
    /__METAWORK_PRODUCT_VERSION__:\s*JSON\.stringify\(productMetadata\.version\)/,
  );
  assert.match(
    rendererIdentity,
    /productVersion = __METAWORK_PRODUCT_VERSION__/,
  );
});

test("artifact identities preserve development and isolate automation namespaces", () => {
  const identity = read("src/product_identity.zig");
  const app = read("src/app.zig");
  const paths = read("src/app/paths.zig");
  const accountCredentials = read("src/product/account/credential_store.zig");
  const mcpPlatform = read("src/app/mcp_platform.zig");
  const build = read("build.zig");

  assert.match(identity, /pub const bundle_id = app_manifest\.id;/);
  assert.match(
    identity,
    /pub const ArtifactKind = enum \{[\s\S]*development,[\s\S]*release,[\s\S]*automation/,
  );
  assert.match(identity, /artifact_options\.kind/);
  assert.match(
    identity,
    /automation_runner_bundle_id = bundle_id \+\+ "\.automation"/,
  );
  assert.match(identity, /windows_data_directory_name = "MetaWork"/);
  assert.match(identity, /macos_data_directory_name = "MetaWork Dev"/);
  assert.match(
    identity,
    /automation_data_directory_name = "MetaWork Automation"/,
  );
  assert.match(
    identity,
    /development_account_credential_service = bundle_id \+\+ "\.account"/,
  );
  assert.match(
    identity,
    /automation_account_credential_service = bundle_id \+\+ "\.automation\.account"/,
  );
  assert.match(
    identity,
    /development_custom_provider_credential_service =[\s\S]*development_account_credential_service \+\+ "\.custom-providers"/,
  );
  assert.match(
    identity,
    /automation_custom_provider_credential_service =[\s\S]*automation_account_credential_service \+\+ "\.custom-providers"/,
  );
  assert.match(
    identity,
    /development_mcp_credential_service = bundle_id \+\+ "\.mcp"/,
  );
  assert.match(
    identity,
    /automation_mcp_credential_service = bundle_id \+\+ "\.automation\.mcp"/,
  );
  assert.match(
    identity,
    /\.release => @compileError\("MetaWork release identity is not configured"\)/,
  );
  assert.match(app, /\.bundle_id = product_identity\.runnerBundleId\(\)/);
  assert.doesNotMatch(
    app,
    /\.bundle_id = product_identity\.automation_runner_bundle_id/,
  );
  assert.match(paths, /product_identity\.dataDirectoryName\(os_tag\)/);
  assert.doesNotMatch(paths, /@import\("build_options"\)/);
  assert.match(
    accountCredentials,
    /product_identity\.accountCredentialService\(\)/,
  );
  assert.match(mcpPlatform, /product_identity\.mcpCredentialService\(\)/);
  assert.match(
    build,
    /const ArtifactOption = enum \{[\s\S]*development,[\s\S]*release,[\s\S]*automation/,
  );
  assert.match(build, /release identity is not configured/);
});

test("the root test entry discovers Node tests and reaches the Native graph", () => {
  const packageJson = JSON.parse(read("package.json"));
  const runner = read("scripts/run-tests.mjs");
  assert.equal(packageJson.scripts.test, "node scripts/run-tests.mjs");
  assert.doesNotMatch(JSON.stringify(packageJson.scripts), /\.test\.mjs/);
  assert.match(runner, /name\.endsWith\("\.test\.mjs"\)/);
  assert.match(runner, /nativeCli, "test", "\."/);
});

test("Product Models contract has one protocol axis and no ProviderKind", () => {
  const productProtocolOwners = [
    "src/product/models.zig",
    ...zigFiles("src/product/models/"),
    ...zigFiles("src/product/account/"),
    ...zigFiles("src/product/control/"),
    ...zigFiles("src/product/task/"),
    ...zigFiles("src/product/schedule/"),
    "src/product/agent_protocol_adapter.zig",
    "src/product/account.zig",
    "src/product/control.zig",
    "src/product/task.zig",
    "src/product/schedule.zig",
    "src/automation/enabled.zig",
    "src/automation/disabled.zig",
    "frontend/src/bridge/contracts.ts",
    "frontend/src/bridge/decode-contracts.ts",
  ];
  const retiredIdentifiers =
    /\bProviderKind\b|\bCustomProviderProtocol\b|\bprovider_kind\b|\bproviderKindForProtocol\b|\bprotocolForProviderKind\b/u;

  for (const file of productProtocolOwners) {
    assert.doesNotMatch(
      read(file),
      retiredIdentifiers,
      `${file} reintroduces a retired Product provider category`,
    );
  }

  const modelsContract = read("src/product/models/contract.zig");
  assert.match(
    modelsContract,
    /pub const Protocol = enum \{[\s\S]*openai_responses,[\s\S]*anthropic_messages,[\s\S]*openai_chat_completions,[\s\S]*gemini_native,[\s\S]*\};/u,
  );
  assert.doesNotMatch(
    read("src/product/account/contract.zig"),
    /pub const Protocol = enum/u,
  );
  assert.match(
    read("src/product/task/state.zig"),
    /pub const Protocol = models_contract\.Protocol;/u,
  );
  assert.match(
    read("src/product/schedule/state.zig"),
    /pub const Protocol = models_contract\.Protocol;/u,
  );
  assertNoImports(
    [...zigFiles("src/product/task/"), ...zigFiles("src/product/schedule/")],
    [
      "metawork_account_contract",
      "metawork_product_models",
      "product_models_runtime",
      "product_models_ports",
      "product_models_providers",
    ],
  );
  assert.doesNotMatch(
    read("src/product/task/state.zig"),
    /\bexecution_provider\b/u,
  );
  assert.doesNotMatch(
    read("src/product/schedule/state.zig"),
    /\bexecution_provider\b/u,
  );
});

test("Product maps admitted protocols to Agent at one exhaustive boundary", () => {
  const build = read("build.zig");
  const adapterPath = "src/product/agent_protocol_adapter.zig";
  const adapter = read(adapterPath);
  const consumers = [
    "src/app/models_coordinator.zig",
    "src/product/task/execution.zig",
    "src/product/task/recovery_job.zig",
    "src/product/task/runtime.zig",
  ];

  assert.match(build, /src\/product\/agent_protocol_adapter\.zig/);
  assert.match(build, /product_agent_protocol_adapter/);
  assert.match(adapter, /@import\("metawork_agent"\)/);
  assert.match(adapter, /@import\("metawork_product_models_contract"\)/);
  assert.match(
    adapter,
    /return switch \(protocol\) \{[\s\S]*\.openai_responses => \.openai_responses,[\s\S]*\.openai_chat_completions => \.openai_chat_completions,[\s\S]*\.anthropic_messages => \.anthropic_messages,[\s\S]*\.gemini_native => \.gemini_native,[\s\S]*\};/,
  );
  assert.doesNotMatch(
    adapter,
    /@tagName|stringToEnum|provider_id|base_url|normalized_base_url|\bmodel\b/,
  );
  for (const file of consumers) {
    const source = read(file);
    assert.match(source, /@import\("product_agent_protocol_adapter"\)/);
    assert.match(source, /agent_protocol\.toAgent\(/);
    assert.doesNotMatch(source, /\.protocol\s*=\s*switch\s*\(/);
  }
  const boundarySources = [
    adapterPath,
    ...zigFiles("src/product/"),
    ...zigFiles("src/app/"),
  ]
    .filter((file, index, files) => files.indexOf(file) === index)
    .map(read)
    .join("\n");
  assert.equal(
    [
      ...boundarySources.matchAll(
        /\.(?:openai_responses|openai_chat_completions|anthropic_messages|gemini_native)\s*=>\s*\.(?:openai_responses|openai_chat_completions|anthropic_messages|gemini_native)/g,
      ),
    ].length,
    4,
  );
  assertNoImports(
    ["src/agent.zig", ...zigFiles("src/agent/")],
    [
      "metawork_product_models",
      "metawork_product_models_contract",
      "product_agent_protocol_adapter",
    ],
  );
});

test("Product Models owns custom providers independently of Account", () => {
  const build = read("build.zig");
  const modelsRoot = read("src/product/models.zig");
  const modelsContract = read("src/product/models/contract.zig");
  const modelsRuntime = read("src/product/models/runtime.zig");
  const modelsRegistry = read("src/product/models/providers.zig");
  const accountContract = read("src/product/account/contract.zig");
  const accountRuntime = read("src/product/account/runtime.zig");
  const accountPorts = read("src/product/account/ports.zig");
  const accountBinding = read("src/app/account_platform_binding.zig");
  const modelsBinding = read("src/app/models_platform_binding.zig");
  const modelsCoordinator = read("src/app/models_coordinator.zig");
  const control = read("src/product/control/runtime.zig");
  const app = read("src/app.zig");
  const bridgeDispatcher = read("src/bridge/dispatcher.zig");
  const bridgeClient = read("frontend/src/bridge/client.ts");
  const settings = read("frontend/src/features/settings/SettingsPage.tsx");
  const windowsBringup = read("scripts/run-windows-bringup.mjs");
  const identity = read("src/product_identity.zig");

  assertNoImports(
    [
      "src/product/models.zig",
      "src/product/models/contract.zig",
      "src/product/models/providers.zig",
      "src/product/models/ports.zig",
      "src/product/models/runtime.zig",
      "src/product/models/metask.zig",
    ],
    [
      "metawork_account_contract",
      "metawork_account",
      "metawork_product_control",
      "metawork_product_task",
      "metawork_product_schedule",
      "metawork_app",
      "metawork_bridge",
      "metawork_agent",
    ],
  );
  assert.match(modelsRoot, /@import\("product_models_runtime"\)/);
  assert.doesNotMatch(
    modelsRoot,
    /@import\("(?:metawork_product_models_contract|product_models_ports)"\)/,
  );
  assertNoModuleTargets(
    build,
    ["product_control_ports", "product_control_runtime"],
    ["models_metask"],
  );
  assert.match(modelsContract, /pub const CustomProviderCommand = union/);
  assert.match(modelsRuntime, /registry: registry_impl\.Registry/);
  assert.doesNotMatch(
    modelsRuntime,
    /\bexecution_generation\b|resolve(?:Default|Probe)Execution|prepareExecution/,
  );
  assert.match(modelsRegistry, /store_file_name = "models\.json"/);
  assert.doesNotMatch(
    modelsRegistry,
    /legacy_(?:connection|preference)_store_file_name|decodeLegacy|migrateLegacyStores|archiveLegacy/,
  );
  assert.doesNotMatch(accountRuntime, /CustomProvider|custom_providers/);
  assert.doesNotMatch(
    accountPorts,
    /CustomProvider|CredentialVault|custom_provider/,
  );
  const accountView = accountContract.match(
    /pub const AccountView = struct \{([\s\S]*?)\n\};/,
  )?.[1];
  const accountCommand = accountContract.match(
    /pub const AccountCommand = enum \{([\s\S]*?)\n\};/,
  )?.[1];
  assert.ok(accountView, "AccountView must remain inspectable");
  assert.ok(accountCommand, "AccountCommand must remain inspectable");
  assert.doesNotMatch(accountView, /CustomProvider|custom_provider/);
  assert.doesNotMatch(accountCommand, /CustomProvider|custom_provider/);
  assertNoImports(
    ["src/product/account.zig", ...zigFiles("src/product/account/")],
    [
      "metawork_product_models",
      "metawork_product_models_contract",
      "product_models_ports",
      "product_models_runtime",
      "product_models_providers",
      "product_models_metask",
    ],
  );
  assertNoModuleTargets(
    build,
    [
      "account",
      "account_contract",
      "account_state",
      "account_runtime",
      "account_credentials_runtime",
      "account_network_attempt",
    ],
    [
      "models",
      "models_contract",
      "models_ports",
      "models_runtime",
      "models_providers",
      "models_metask",
    ],
  );
  assertNoModuleTargets(
    build,
    ["models", "models_runtime", "models_providers", "models_metask"],
    [
      "account",
      "account_contract",
      "account_runtime",
      "product_control",
      "product_task",
      "task_runtime",
      "product_schedule",
      "product_schedule_runtime",
      "agent",
      "bridge",
    ],
  );
  assert.throws(
    () =>
      assertNoModuleTargets(
        `${build}\nmodels_runtime.addImport("consumer", product_task);`,
        ["models", "models_runtime", "models_providers", "models_metask"],
        ["product_task"],
      ),
    /models_runtime imports forbidden build module product_task as consumer/,
  );
  assert.doesNotMatch(
    accountContract,
    /custom_provider_(?:invalid|not_found|capture_unavailable|persistence_unavailable|test_unavailable)/,
  );
  assert.doesNotMatch(
    accountBinding,
    /CredentialVault|custom_provider|executionPorts/,
  );
  assert.match(modelsBinding, /product_models_ports/);
  assert.match(modelsBinding, /customProviderCredentialService/);
  assert.doesNotMatch(app, /custom_provider_host|setCustomProviderHost/);
  assert.match(
    bridgeDispatcher,
    /control\.createCustomProviderWithCredential\(parsed\.value\.apiKey, spec\)/,
  );
  assert.match(
    bridgeDispatcher,
    /control\.replaceCustomProviderCredential\(parsed\.value\.apiKey/,
  );
  assert.match(bridgeClient, /apiKey: string/);
  assert.match(settings, /type="password"/);
  assert.doesNotMatch(settings, /settings-secure-credential-handoff/);
  assert.match(
    app,
    /\.management = custom_provider_capability_available,[\s\S]*\.secret_capture = custom_provider_capability_available,[\s\S]*\.model_test = custom_provider_capability_available/,
  );
  assert.doesNotMatch(settings, /CUSTOM_PROVIDER_SETTINGS_ENABLED/);
  assert.match(windowsBringup, /test-custom-provider-readiness-windows\.mjs/);
  assert.match(identity, /pub fn customProviderCredentialService/);
  const selectDefault = control.indexOf("pub fn selectModelsDefault(");
  const registryCommit = control.indexOf(
    "self.custom_providers.selectDefault(command)",
    selectDefault,
  );
  const reconcile = control.indexOf(
    "self.reconcileModelsDefaultNoFail(false, false)",
    registryCommit,
  );
  assert.ok(selectDefault >= 0 && registryCommit > selectDefault);
  assert.ok(
    reconcile > registryCommit,
    "Models desired state must commit before consumer reconciliation",
  );
  const reconcileOwner = control.indexOf("fn reconcileModelsDefaultNoFail(");
  const scrubPreparation = control.indexOf(
    "self.execution_state.prepareInstall(",
    reconcileOwner,
  );
  const activeInstall = control.indexOf(
    "self.execution_state.installMetaskNoFail(",
    scrubPreparation,
  );
  assert.ok(reconcileOwner >= 0 && scrubPreparation > reconcileOwner);
  assert.ok(activeInstall > scrubPreparation);
  assert.match(app, /models_platform_binding\.Adapter\.init/);
  assert.match(app, /models_management\.start\(/);
  assert.doesNotMatch(app, /startWithAccountUnavailable/);
  assert.match(modelsCoordinator, /control_ports\.ModelsManagement/);
  assert.doesNotMatch(
    modelsCoordinator,
    /AccountExecutionHandoff|OwnedSourceCandidate|ModelView|ModelMetadata/,
  );
});

test("named module roots exist and lower owners cannot import composition", () => {
  for (const path of [
    "src/app.zig",
    "src/product/account.zig",
    "src/product/models.zig",
    "src/product/mcp.zig",
    "src/product/skill.zig",
    "src/product/task.zig",
    "src/product/schedule.zig",
    "src/product/workspace.zig",
    "src/agent.zig",
    "src/product/control.zig",
    "src/bridge.zig",
    "src/storage.zig",
  ]) {
    assert.equal(existsSync(new URL(path, root)), true, `${path} must exist`);
  }
  assert.equal(existsSync(new URL("src/agentcore.zig", root)), false);
  assert.equal(existsSync(new URL("src/agentcore/", root)), false);
  assert.equal(existsSync(new URL("src/account.zig", root)), false);
  assert.equal(existsSync(new URL("src/account/", root)), false);
  assert.equal(existsSync(new URL("src/product/execution/", root)), false);
  assert.equal(
    existsSync(new URL("src/product/control/runtime.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/control/executor.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/control/file_preview.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/workspace/view.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/workspace/automatic_root.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/workspace/configuration.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/control/automatic_workspace.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/product/schedule/state.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/schedule/persistence.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/schedule/runtime.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/schedule/view.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/workspace/runtime.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/control/execution_state.zig", root)),
    true,
  );
  assert.equal(
    existsSync(new URL("src/product/control/schedule.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("tests/product/control_lifecycle_test.zig", root)),
    true,
  );
  assert.equal(existsSync(new URL("src/workbench.zig", root)), false);
  assert.equal(
    existsSync(new URL("src/workbench/projection.zig", root)),
    false,
  );
  assert.equal(existsSync(new URL("src/workbench/executor.zig", root)), false);
  assert.equal(
    existsSync(new URL("src/workbench/file_preview.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/workbench/scheduled_tasks.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/workbench/scheduled_task_persistence.zig", root)),
    false,
  );
  assert.equal(existsSync(new URL("src/workbench/", root)), false);
  assert.equal(
    existsSync(new URL("tests/workbench/executor_lifecycle_test.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/workbench/mcp_configuration.zig", root)),
    false,
  );
  assert.equal(existsSync(new URL("src/workbench/testdata/", root)), false);
  assert.equal(
    existsSync(new URL("src/workbench/catalog_snapshot.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/workbench/skill_package.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/workbench/skill_enablement.zig", root)),
    false,
  );
  assert.equal(
    existsSync(new URL("src/workbench/skill_management.zig", root)),
    false,
  );
  for (const path of [
    "src/workbench/task_persistence.zig",
    "src/workbench/checkpoint_record.zig",
    "src/workbench/checkpoint_store.zig",
    "src/workbench/owned_task_execution.zig",
    "src/workbench/task_runtime.zig",
    "src/workbench/task_deletion.zig",
    "src/workbench/task_recovery.zig",
    "src/workbench/task_recovery_job.zig",
  ]) {
    assert.equal(existsSync(new URL(path, root)), false, `${path} is obsolete`);
  }
  const buildSource = read("build.zig");
  assert.match(buildSource, /src\/product\/account\.zig/);
  assert.match(buildSource, /src\/product\/account\/contract\.zig/);
  assert.match(buildSource, /src\/product\/mcp\.zig/);
  assert.match(buildSource, /src\/product\/mcp\/configuration\.zig/);
  assert.match(buildSource, /src\/product\/mcp\/state\.zig/);
  assert.match(buildSource, /src\/product\/skill\.zig/);
  assert.match(buildSource, /src\/product\/skill\/catalog\.zig/);
  assert.match(buildSource, /src\/product\/task\.zig/);
  assert.match(buildSource, /src\/product\/task\/persistence\.zig/);
  assert.match(buildSource, /src\/product\/task\/runtime\.zig/);
  assert.match(buildSource, /src\/product\/schedule\.zig/);
  assert.match(buildSource, /src\/product\/schedule\/state\.zig/);
  assert.match(buildSource, /src\/product\/schedule\/runtime\.zig/);
  assert.match(buildSource, /src\/product\/schedule\/view\.zig/);
  assert.match(buildSource, /src\/product\/schedule\/persistence\.zig/);
  assert.match(buildSource, /src\/product\/workspace\/view\.zig/);
  assert.match(buildSource, /src\/product\/workspace\/automatic_root\.zig/);
  assert.doesNotMatch(
    buildSource,
    /src\/product\/control\/automatic_workspace\.zig|product_control_automatic_workspace/,
  );
  assert.doesNotMatch(buildSource, /src\/account(?:\.zig|\/)/);
  assert.doesNotMatch(buildSource, /src\/workbench\/mcp_configuration\.zig/);
  assert.doesNotMatch(buildSource, /src\/workbench\/catalog_snapshot\.zig/);
  assert.doesNotMatch(
    buildSource,
    /workbench_scheduled_tasks|workbench_scheduled_task_persistence/,
  );
  assert.doesNotMatch(
    buildSource,
    /workbench_automatic_workspace_allocator|src\/workbench\/automatic_workspace_allocator\.zig/,
  );
  assert.doesNotMatch(
    buildSource,
    /src\/workbench\/(?:task_persistence|checkpoint_record|checkpoint_store|owned_task_execution|task_runtime|task_deletion|task_recovery|task_recovery_job)\.zig/,
  );
  assert.match(buildSource, /addImport\("metawork_account", account\)/);
  assert.match(
    buildSource,
    /addImport\("metawork_account_contract", account_contract\)/,
  );

  const main = read("src/main.zig");
  assert.match(main, /@import\("metawork_app"\)/);
  assert.doesNotMatch(
    main,
    /@import\("(?:metawork_agent|metawork_product_control|metawork_bridge)"\)/,
  );

  const appSource = ["src/app.zig", ...zigFiles("src/app/")]
    .map(read)
    .join("\n");
  for (const name of [
    "metawork_agent",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_automation",
  ]) {
    assert.match(appSource, new RegExp(`@import\\(\\"${name}\\"\\)`));
  }

  assertNoImports(zigFiles("src/agent/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_account",
  ]);
  assertNoImports(zigFiles("src/product/account/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_agent",
    "metask_agentcore",
  ]);
  assertNoImports(zigFiles("src/product/mcp/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_account",
    "metask_agentcore",
    "native_sdk",
  ]);
  assertNoImports(zigFiles("src/product/skill/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_account",
    "metask_agentcore",
    "native_sdk",
  ]);
  assertNoImports(zigFiles("src/product/task/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_account",
    "metask_agentcore",
    "native_sdk",
  ]);
  assertNoImports(zigFiles("src/product/schedule/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_account",
    "metawork_agent",
    "metawork_product_task",
    "metawork_product_skill",
    "metawork_product_mcp",
    "metask_agentcore",
    "native_sdk",
  ]);
  assertNoImports(zigFiles("src/product/workspace/"), [
    "metawork_app",
    "metawork_product_control",
    "metawork_bridge",
    "metawork_account",
    "metawork_agent",
    "metawork_product_task",
    "metawork_product_skill",
    "metawork_product_mcp",
    "metawork_product_schedule",
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
    "src/product/control.zig",
    "src/bridge.zig",
  ]) {
    assert.doesNotMatch(
      read(file),
      /pub const \w+\s*=\s*@import\(/,
      `${file} exposes an implementation module`,
    );
  }
});

test("Product Control is the only composition owner identity", () => {
  const build = read("build.zig");
  const control = read("src/product/control.zig");
  const runtime = read("src/product/control/runtime.zig");
  const accountProjection = read("src/product/control/account_projection.zig");
  const executionState = read("src/product/control/execution_state.zig");
  const ports = read("src/product/control/ports.zig");
  const executor = read("src/product/control/executor.zig");
  const filePreview = read("src/product/control/file_preview.zig");
  const source = [...zigFiles("src/"), ...zigFiles("tests/")]
    .map(read)
    .join("\n");

  assert.match(build, /src\/product\/control\.zig/);
  assert.match(build, /src\/product\/control\/runtime\.zig/);
  assert.match(build, /src\/product\/control\/account_projection\.zig/);
  assert.match(build, /src\/product\/control\/execution_state\.zig/);
  assert.match(build, /src\/product\/models\.zig/);
  assert.match(build, /src\/product\/models\/contract\.zig/);
  assert.match(build, /src\/product\/models\/providers\.zig/);
  assert.match(build, /src\/product\/models\/runtime\.zig/);
  assert.match(build, /src\/product\/control\/executor\.zig/);
  assert.match(build, /src\/product\/control\/file_preview\.zig/);
  assert.match(build, /src\/product\/schedule\.zig/);
  assert.match(build, /src\/product\/schedule\/runtime\.zig/);
  assert.match(build, /src\/product\/schedule\/view\.zig/);
  assert.match(build, /metawork_product_control/);
  assert.match(build, /product_control_executor/);
  assert.match(build, /product_control_account_projection/);
  assert.match(build, /product_control_execution_state/);
  assert.match(build, /metawork_product_models_contract/);
  assert.match(build, /metawork_product_models/);
  assert.match(build, /product_models_runtime/);
  assert.match(build, /product_control_file_preview/);
  assert.match(build, /metawork_product_schedule/);
  assert.match(build, /product_schedule_runtime/);
  assert.match(control, /pub const Runtime = runtime_impl\.Runtime/);
  assert.match(runtime, /pub const Runtime = struct/);
  assert.match(runtime, /@import\("product_control_account_projection"\)/);
  assert.match(runtime, /@import\("product_control_execution_state"\)/);
  assert.match(runtime, /account_projection: account_projection\.Projection/);
  assert.match(runtime, /execution_state: execution_state\.State/);
  assert.match(accountProjection, /@import\("metawork_account_contract"\)/);
  assert.doesNotMatch(accountProjection, /metawork_product_models/);
  assert.match(accountProjection, /pub const Projection = struct/);
  assert.doesNotMatch(
    accountProjection,
    /authority_protocol|metask_source_generation|catalog_state|selected_model/,
  );
  assert.doesNotMatch(
    executionState,
    /metawork_account_contract|AccountProjection|AccountFact|AccountView|account_id|catalog_generation|selected_model/,
  );
  assert.match(executionState, /@import\("metawork_product_models_contract"\)/);
  assert.match(executionState, /pub const State = struct/);
  assert.match(executionState, /pub const ProjectionRedaction = struct/);
  assert.match(executionState, /const ActiveExecution = struct/);
  assert.match(executionState, /pub const testing = if \(builtin\.is_test\)/);
  assertNoImports(
    ["src/product/control/execution_state.zig"],
    [
      "metawork_product_control",
      "metawork_product_task",
      "metawork_product_skill",
      "metawork_product_mcp",
      "metawork_product_schedule",
      "metawork_product_workspace",
      "metawork_account_contract",
      "metawork_agent",
      "metawork_app",
      "metawork_bridge",
      "metask_agentcore",
      "native_sdk",
    ],
  );
  assertNoImports(
    ["src/product/control/account_projection.zig"],
    [
      "metawork_product_control",
      "metawork_product_task",
      "metawork_product_skill",
      "metawork_product_mcp",
      "metawork_product_schedule",
      "metawork_product_workspace",
      "metawork_agent",
      "metawork_app",
      "metawork_bridge",
      "metask_agentcore",
      "native_sdk",
    ],
  );
  assert.doesNotMatch(
    executionState,
    /std\.Thread|product_control_executor|rawState|rawExecution|\*Runtime|\*Control/,
  );
  assert.doesNotMatch(
    runtime,
    /const AccountProjection = struct|const ActiveExecution = struct|const ReplacementKind = enum|const RedactionPreparation = union|custom_execution_binding:|execution_replacement:|execution_redaction_preparation:/,
  );
  assert.match(
    runtime,
    /pub const PreparedCustomProviderBinding\s*=\s*[\s\S]*execution_state\.PreparedCustomProviderBinding/,
  );
  assert.doesNotMatch(
    ports,
    /PreparedCustomProviderBinding|execution_state\.State|AccountProjection|ActiveExecution/,
  );
  assert.doesNotMatch(
    control,
    /execution_state|AccountProjection|ActiveExecution/,
  );
  assert.doesNotMatch(runtime, /\bworkbench(?:\b|_)/);
  assert.doesNotMatch(build, /metawork_workbench|workbench_projection/);
  assert.doesNotMatch(
    source,
    /@import\("metawork_workbench"\)|@import\("workbench_projection"\)/,
  );
  assert.doesNotMatch(
    source,
    /pub const Workbench\s*=|pub const Workbench = struct/,
  );
  assert.doesNotMatch(build, /workbench_contract_fixture/);
  assert.doesNotMatch(
    build,
    /src\/workbench\/(?:executor|file_preview)\.zig|workbench_executor/,
  );
  assert.match(filePreview, /pub const Executor = struct/);
  assert.match(filePreview, /context: \*anyopaque/);
  assert.match(filePreview, /enqueue_fn:/);
  assert.doesNotMatch(
    filePreview,
    /@import\("product_control_executor"\)|\*Runtime|\*Control|std\.Thread/,
  );
  const job = executor.match(/pub const Job = struct \{([\s\S]*?)\n\};/)?.[1];
  assert.ok(job, "executor Job must remain inspectable");
  assert.doesNotMatch(job, /Runtime|Control|Application|App|Task|Skill|Mcp/);
  assert.doesNotMatch(
    executor,
    /@import\("(?:metawork_product_control|metawork_app)"\)|\*Runtime|\*Control/,
  );
});

test("Product Schedule owns its aggregate state and persistence", () => {
  const build = read("build.zig");
  const control = read("src/product/control.zig");
  const runtime = read("src/product/control/runtime.zig");
  const executionState = read("src/product/control/execution_state.zig");
  const scheduleRoot = read("src/product/schedule.zig");
  const scheduleRuntime = read("src/product/schedule/runtime.zig");
  const scheduleState = read("src/product/schedule/state.zig");
  const scheduleView = read("src/product/schedule/view.zig");
  const persistence = read("src/product/schedule/persistence.zig");
  const stores = read("src/app/stores.zig");
  const ports = read("src/product/control/ports.zig");
  const accountCoordinator = read("src/app/account_coordinator.zig");
  const taskRuntime = read("src/product/task/runtime.zig");

  assert.match(runtime, /@import\("metawork_product_schedule"\)/);
  assert.doesNotMatch(
    runtime,
    /product_schedule_(?:state|persistence|runtime)/,
  );
  assert.match(scheduleRoot, /pub const Runtime = runtime_impl\.Runtime/);
  assert.match(scheduleRuntime, /@import\("product_schedule_state"\)/);
  assert.match(scheduleRuntime, /@import\("product_schedule_persistence"\)/);
  assert.match(scheduleRuntime, /@import\("product_schedule_view"\)/);
  assert.match(scheduleView, /@import\("product_schedule_state"\)/);
  assert.match(persistence, /@import\("product_schedule_state"\)/);
  assert.match(persistence, /\.scheduled-tasks\.recovery\.\{s\}\.pending/);
  assert.match(persistence, /\.scheduled-tasks\.recovery\.\{s\}\.quarantine/);
  assert.match(persistence, /hasIncompleteRecoveryArtifact/);
  assert.match(persistence, /settleIncompleteRecoveries/);
  assert.match(
    persistence,
    /recoveryTransactionId\(entry\.name, "\.pending"\)/,
  );
  assert.match(
    persistence,
    /rename\(\s*file_name,\s*self\.dir,\s*quarantine_name,/,
  );
  assert.doesNotMatch(persistence, /deleteFile\(\s*self\.io,\s*file_name\s*\)/);
  assert.match(stores, /@import\("product_schedule_persistence"\)/);
  assert.doesNotMatch(
    control,
    /ScheduledTaskFileStore|scheduled_task_store_max_bytes|product_schedule_persistence/,
  );
  assert.doesNotMatch(
    `${scheduleRoot}\n${scheduleRuntime}\n${scheduleState}\n${scheduleView}\n${persistence}`,
    /@import\("(?:metawork_app|metawork_bridge|metawork_agent|metawork_product_task|metawork_product_skill|metawork_product_mcp)"\)|std\.Thread/,
  );
  assert.doesNotMatch(
    build,
    /workbench_scheduled_tasks|workbench_scheduled_task_persistence|metawork-scheduled-task-persistence/,
  );
  assert.doesNotMatch(runtime, /scheduled_tasks_impl|\.scheduled_tasks\b/);
  assert.doesNotMatch(
    runtime,
    /ItemView|forEachView|plannedAtUnixSeconds|nextRunAtUnixSeconds|titleRedacted|previousTaskId|beginOccurrence|finishSubmitted|finishRejectedNoFail|nextPendingCompletion|finishCompletionNoFail|dueNow|validateManual/,
  );
  assert.doesNotMatch(
    scheduleRoot,
    /ItemView|forEachView|OccurrenceSource|OccurrenceTaskOutcome|Claim|BeginOutcome|PendingCompletion|pub const Due/,
  );
  assert.match(scheduleRuntime, /pub const TaskEffects = struct/);
  assert.match(scheduleRuntime, /context: \*anyopaque/);
  assert.match(scheduleRuntime, /pub fn runNow/);
  assert.match(scheduleRuntime, /pub fn onTimer/);
  assert.match(scheduleRuntime, /pub fn reconcileNoFail/);
  assert.match(scheduleView, /pub const TextProjection = struct/);
  assert.match(scheduleView, /pub fn writeProjection/);
  assert.match(
    scheduleRuntime,
    /fn commitCandidate[\s\S]*?redactStore[\s\S]*?redaction\.contains/,
  );
  assert.match(runtime, /schedule\.prepareCredentialRedaction/);
  assert.match(runtime, /schedule\.runNow/);
  assert.match(runtime, /schedule\.onTimer/);
  assert.match(runtime, /schedule\.reconcileNoFail/);
  assert.match(runtime, /product_schedule\.TaskEffects/);
  assert.match(runtime, /schedule\.writeProjection/);
  assert.match(runtime, /execution_state\.prepareInstall/);
  assert.match(runtime, /execution_state\.prepareClear/);
  assert.match(executionState, /fn consumeInstallPreparation/);
  assert.match(executionState, /fn consumeClearPreparation/);
  assert.match(runtime, /redactWithExecutionCredentialsNoFail/);
  assert.match(taskRuntime, /pub fn redactWithExecutionCredentialsNoFail/);
  assert.match(ports, /pub const AccountCommitSink = struct/);
  assert.match(ports, /commit_fn:/);
  assert.doesNotMatch(
    ports,
    /prepareMetaskExecutionCandidate|prepareMetaskExecutionClear|finalizeMetaskStageNoFail|abortMetaskStageNoFail/,
  );
  assert.doesNotMatch(
    accountCoordinator,
    /prepareExecutionInstall|prepareExecutionClear/,
  );
});

test("Product Workspace owns the bounded registry without owning the shared commit", () => {
  const build = read("build.zig");
  const control = read("src/product/control/runtime.zig");
  const workspaceRoot = read("src/product/workspace.zig");
  const workspaceRuntime = read("src/product/workspace/runtime.zig");
  const workspaceView = read("src/product/workspace/view.zig");
  const automaticRoot = read("src/product/workspace/automatic_root.zig");
  const automaticRootConfiguration = read(
    "src/product/workspace/configuration.zig",
  );

  assert.match(build, /src\/product\/workspace\.zig/);
  assert.match(build, /src\/product\/workspace\/runtime\.zig/);
  assert.match(build, /src\/product\/workspace\/view\.zig/);
  assert.match(build, /src\/product\/workspace\/automatic_root\.zig/);
  assert.match(build, /src\/product\/workspace\/configuration\.zig/);
  assert.match(build, /metawork_product_workspace/);
  assert.match(build, /product_workspace_view/);
  assert.match(build, /product_workspace_automatic_root/);
  assert.match(build, /product_workspace_configuration/);
  assert.match(control, /@import\("metawork_product_workspace"\)/);
  assert.match(control, /workspace: product_workspace\.Runtime/);
  assert.match(workspaceRoot, /pub const Runtime = runtime_impl\.Runtime/);
  assert.match(workspaceRoot, /pub const Projection = view_impl\.Projection/);
  assert.match(
    workspaceRoot,
    /pub const AutomaticRoot = runtime_impl\.AutomaticRoot/,
  );
  assert.match(
    workspaceRoot,
    /pub const AutomaticRootConfiguration = configuration_impl\.Configuration/,
  );
  assert.match(
    workspaceRoot,
    /pub const PreparedAutomaticWorkspace = runtime_impl\.PreparedAutomaticWorkspace/,
  );
  assert.doesNotMatch(
    workspaceRoot,
    /AutomaticAllocator|AutomaticAllocation|AutomaticError|automatic_root_impl/,
  );
  assert.match(workspaceRuntime, /records: \[\]\?Record/);
  assert.match(workspaceRuntime, /pub fn prepareOpen/);
  assert.match(workspaceRuntime, /pub fn prepareRemoval/);
  assert.match(workspaceRuntime, /pub fn prepareOrder/);
  assert.match(workspaceRuntime, /pub fn taskCreateAuthority/);
  assert.match(workspaceRuntime, /pub fn taskRunAuthority/);
  assert.match(workspaceRuntime, /pub fn recoveryAuthority/);
  assert.match(workspaceRuntime, /pub fn filePreviewAuthorized/);
  assert.match(workspaceRuntime, /pub fn visibleManualBindingAt/);
  assert.match(
    workspaceRuntime,
    /automatic_allocator: \?automatic_root\.Allocator/,
  );
  assert.match(workspaceRuntime, /pub fn prepareAutomatic/);
  assert.match(workspaceRuntime, /pub fn completeAutomatic/);
  assert.match(workspaceRuntime, /pub fn rollbackPreparedAutomatic/);
  assert.match(workspaceRuntime, /pub fn abandonPreparedAutomatic/);
  assert.doesNotMatch(
    control,
    /@typeInfo[\s\S]{0,200}(?:allocateAutomatic|AutomaticAllocation)/,
  );
  const preparedTaskSource = control.slice(
    control.indexOf("fn prepareTaskInWorkspaceInternal("),
    control.indexOf("fn createAutomaticTask("),
  );
  const scheduledAdmissionSource = control.slice(
    control.indexOf("fn prepareScheduledAdmission("),
    control.indexOf("pub fn restoreTaskConversation("),
  );
  assert.doesNotMatch(preparedTaskSource, /syncLifecycle\(\)/);
  assert.doesNotMatch(scheduledAdmissionSource, /syncLifecycle\(\)/);
  assert.doesNotMatch(
    workspaceRuntime,
    /commitTaskState|TaskPersistence|FileStore|Executor|std\.Thread|@import\("(?:metawork_product_control|metawork_product_task|metawork_product_skill|metawork_product_mcp|metawork_product_schedule|metawork_agent|metawork_app|metawork_bridge|metawork_account)"\)/,
  );
  assert.match(workspaceView, /pub const Provider = struct/);
  assert.match(workspaceView, /context: \*const anyopaque/);
  assert.match(workspaceView, /pub fn copyProjections/);
  assert.match(workspaceView, /pub fn writeProjectionList/);
  assert.match(workspaceView, /skillCatalog/);
  assert.doesNotMatch(
    workspaceView,
    /@import\("(?:metawork_product_control|metawork_product_task|metawork_product_skill|metawork_product_mcp|metawork_product_schedule|metawork_agent|metawork_app|metawork_bridge|metawork_account)"\)|std\.Thread|FileStore|Executor|\*Runtime|\*Control/,
  );
  assert.match(automaticRoot, /pub const Root = struct/);
  assert.match(automaticRoot, /pub const Allocator = struct/);
  assert.doesNotMatch(
    automaticRoot,
    /@import\("(?:metawork_product_control|metawork_product_task|metawork_product_skill|metawork_product_mcp|metawork_product_schedule|metawork_agent|metawork_app|metawork_bridge|metawork_account)"\)|std\.Thread/,
  );
  assert.match(automaticRootConfiguration, /pub const Configuration = struct/);
  assert.match(automaticRootConfiguration, /pub const FileStore = struct/);
  assert.doesNotMatch(
    automaticRootConfiguration,
    /@import\("(?:metawork_product_control|metawork_product_task|metawork_product_skill|metawork_product_mcp|metawork_product_schedule|metawork_agent|metawork_app|metawork_bridge|metawork_account)"\)|std\.Thread/,
  );
  assert.doesNotMatch(
    control,
    /const WorkspaceView = struct|workspaces: \[\]\?Workspace|automatic_workspaces:|AutomaticAllocator|next_workspace_id:|next_workspace_recent_order:|fn upsertWorkspace\(|fn rollbackWorkspaceUpsert\(|fn finishWorkspaceUpsert\(|fn findWorkspace\(|fn findWorkspaceByRoot\(|fn writeWorkspace\(/,
  );
  assert.match(control, /commitTaskStateWithCheckpoint/);
  assert.match(control, /workspace\.prepareOpen/);
  assert.match(control, /workspace\.prepareRemoval/);
  assert.match(control, /workspace\.prepareOrder/);
  assert.match(control, /workspace\.taskCreateAuthority/);
  assert.match(control, /workspace\.taskRunAuthority/);
  assert.match(control, /workspace\.recoveryAuthority/);
  assert.match(control, /workspace\.filePreviewAuthorized/);
  assert.match(control, /workspace\.availableManualBindingAt/);
  assert.match(control, /product_workspace\.copyProjections/);
  assert.match(control, /product_workspace\.writeProjectionList/);
  assert.doesNotMatch(
    control,
    /product_workspace_(?:runtime|view|automatic_root)|automatic_workspace_allocator/,
  );
  const registryFields = workspaceRuntime.match(
    /pub const Runtime = struct \{([\s\S]*?)\n\s*pub fn init\(/,
  )?.[1];
  assert.ok(registryFields, "Workspace Runtime fields must remain inspectable");
  assert.doesNotMatch(
    registryFields,
    /Storage|OpenAuthority|TaskAuthority|RecoveryAuthority|Binding/,
  );
  const orderContext = control.match(
    /const TaskWorkspaceOrderContext = struct \{([\s\S]*?)\n\};/,
  )?.[1];
  assert.ok(orderContext, "Workspace order context must remain inspectable");
  assert.doesNotMatch(orderContext, /control:|\*Runtime|Task|Skill|Mcp/);
});

test("Application coordinators consume scoped Product Control capabilities", () => {
  const build = read("build.zig");
  const ports = read("src/product/control/ports.zig");
  const projection = read("src/product/control/runtime.zig");
  const accountCoordinator = read("src/app/account_coordinator.zig");
  const executionCoordinator = read("src/app/models_coordinator.zig");
  const agentEvents = read("src/app/agent_event_coordinator.zig");
  const mcpManagement = read("src/app/mcp_management_coordinator.zig");
  const mcpOauth = read("src/app/mcp_oauth_coordinator.zig");
  const window = read("src/app/window.zig");
  const platform = read("src/app/platform.zig");

  assert.match(build, /src\/product\/control\/ports\.zig/);
  assert.match(build, /metawork_product_control_ports/);
  for (const name of [
    "AccountCommitSink",
    "ModelsManagement",
    "AgentEventConsumer",
    "McpManagementPort",
    "McpOauthPort",
    "ScheduleHost",
  ]) {
    assert.match(ports, new RegExp(`pub const ${name} = struct`));
  }
  assert.match(ports, /context: \*anyopaque/);
  assert.doesNotMatch(
    ports,
    /Workbench|product_control\.Runtime|rawRuntime|rawOwner/,
  );
  assert.match(projection, /pub fn accountCommitSink/);
  assert.match(projection, /pub fn modelsManagement/);
  assert.match(projection, /pub fn agentEventConsumer/);
  assert.match(projection, /pub fn mcpManagementPort/);
  assert.match(projection, /pub fn mcpOauthPort/);
  assert.match(projection, /pub fn scheduleHost/);

  for (const source of [
    accountCoordinator,
    executionCoordinator,
    mcpManagement,
    mcpOauth,
  ]) {
    const coordinator = source.match(
      /pub const Coordinator = struct \{([\s\S]*?)\n    pub fn init/,
    )?.[1];
    assert.ok(coordinator, "coordinator state must be inspectable");
    assert.doesNotMatch(coordinator, /Workbench|workbench_owner|\*workbench/);
  }
  const accountState = accountCoordinator.match(
    /pub const Coordinator = struct \{([\s\S]*?)\n    pub fn init/,
  )?.[1];
  assert.doesNotMatch(
    accountState,
    /CompletionTransport|ProbeJob|ModelsManagement|CredentialVault/,
  );
  assert.doesNotMatch(
    accountCoordinator,
    /CustomProvider|custom_provider|startCustomProviders|stopCustomProviders/,
  );
  assert.doesNotMatch(
    agentEvents,
    /@import\("metawork_product_control"\)|\*workbench/,
  );
  assert.doesNotMatch(
    window,
    /@import\("metawork_product_control"\)|workbench_api|\*workbench/,
  );
  assert.doesNotMatch(
    platform,
    /@import\("metawork_product_control"\)|workbench_api|\*workbench/,
  );
});

test("Account authorization and Models provider state remain separate owners", () => {
  const ports = read("src/product/control/ports.zig");
  const control = read("src/product/control/runtime.zig");
  const accountCoordinator = read("src/app/account_coordinator.zig");
  const modelsCoordinator = read("src/app/models_coordinator.zig");
  const accountRuntime = read("src/product/account/runtime.zig");
  const accountState = read("src/product/account/state.zig");
  const accountContract = read("src/product/account/contract.zig");
  const modelsRuntime = read("src/product/models/runtime.zig");

  assert.match(ports, /pub const AccountCommitSink = struct/);
  assert.doesNotMatch(
    ports,
    /OwnedSourceCandidateTransfer|source_candidate|Account.*Models|Models.*Account/,
  );
  const commitStart = control.indexOf("pub fn commitAccountChangeNoFail");
  const nextMethod = control.indexOf("\n    pub fn ", commitStart + 1);
  const accountCommit = control.slice(commitStart, nextMethod);
  assert.match(accountCommit, /self\.commitAccountFactNoFail\(commit\.fact\)/);
  assert.doesNotMatch(accountCommit, /model|Model|source|Source|credential/);

  const accountCommitAt = accountCoordinator.indexOf(
    "self.runtime.commit(&prepared);",
  );
  const productCommitAt = accountCoordinator.indexOf(
    "self.control.commitNoFail",
  );
  assert.ok(accountCommitAt >= 0 && productCommitAt > accountCommitAt);
  const observerAt = accountCoordinator.indexOf("observer.notify();");
  assert.ok(observerAt > productCommitAt);
  assert.match(accountRuntime, /pub fn authorizationLease/);
  assert.match(modelsCoordinator, /self\.account\.authorizationLease\(\)/);
  assert.match(
    modelsCoordinator,
    /self\.management\.setMetaskAuthorizationUnavailable\(\)/,
  );
  assert.match(modelsRuntime, /pub fn setMetaskAuthorizationUnavailable/);
  assert.match(modelsRuntime, /clearMetaskRuntime\(\.needs_authentication/);
  assert.doesNotMatch(
    [accountContract, accountRuntime, accountState].join("\n"),
    /ModelView|ModelMetadata|CatalogState|source_resolution|selected_model|OwnedSourceCandidate|execution_generation/,
  );
});

test("Product Skill has one live owner behind narrow composition ports", () => {
  const build = read("build.zig");
  const productSkill = read("src/product/skill.zig");
  const catalog = read("src/product/skill/catalog.zig");
  const enablement = read("src/product/skill/enablement.zig");
  const packageKernel = read("src/product/skill/package.zig");
  const management = read("src/product/skill/management.zig");
  const managementRuntime = read("src/product/skill/management_runtime.zig");
  const policy = read("src/product/skill/policy.zig");
  const ports = read("src/product/skill/ports.zig");
  const runtime = read("src/product/skill/runtime.zig");
  const state = read("src/product/skill/state.zig");
  const view = read("src/product/skill/view.zig");
  const appStores = read("src/app/stores.zig");
  const bridgeDispatcher = read("src/bridge/dispatcher.zig");
  const workbenchRoot = read("src/product/control.zig");
  const projection = read("src/product/control/runtime.zig");
  const taskAttachment = read("src/product/task/attachment.zig");
  const recoveryJob = read("src/product/task/recovery_job.zig");

  assert.match(productSkill, /@import\("product_skill_catalog"\)/);
  assert.match(productSkill, /@import\("product_skill_enablement"\)/);
  assert.match(productSkill, /@import\("product_skill_management"\)/);
  assert.match(productSkill, /@import\("product_skill_ports"\)/);
  assert.match(productSkill, /@import\("product_skill_runtime"\)/);
  assert.doesNotMatch(
    productSkill,
    /@import\("product_skill_(?:package|policy|state|view|management_runtime)"\)/,
  );
  assert.match(catalog, /@import\("metawork_agent"\)/);
  assert.doesNotMatch(
    catalog,
    /Workbench|Task|Workspace|product_control_executor|std\.Thread|\*agent\.Runtime|\*agent\.Session/,
  );
  for (const source of [projection, taskAttachment]) {
    assert.match(source, /@import\("metawork_product_skill"\)\.catalog/);
    assert.doesNotMatch(source, /@import\("workbench_catalog_snapshot"\)/);
  }
  assert.doesNotMatch(
    recoveryJob,
    /metawork_product_skill|product_skill_catalog/,
  );
  assert.doesNotMatch(
    build,
    /task_recovery_job\.addImport\("metawork_product_skill"/,
  );
  assert.doesNotMatch(
    packageKernel,
    /Workbench|Workspace|Task|product_control_executor|std\.Thread|@import\("metawork_agent"\)/,
  );
  assert.doesNotMatch(
    enablement,
    /Workbench|product_control_executor|std\.Thread|@import\("metawork_agent"\)/,
  );
  assert.match(management, /@import\("product_skill_package"\)/);
  assert.doesNotMatch(
    management,
    /Workbench|product_control_executor|std\.Thread|@import\("metawork_agent"\)/,
  );
  assert.match(managementRuntime, /@import\("product_skill_management"\)/);
  assert.match(managementRuntime, /@import\("product_skill_package"\)/);
  assert.match(managementRuntime, /pub fn installDirectory/);
  assert.match(managementRuntime, /pub fn reimportDirectory/);
  assert.match(managementRuntime, /pub fn uninstall/);
  assert.match(managementRuntime, /pub fn retryVerification/);
  assert.match(managementRuntime, /pub fn recoverNoFail/);
  assert.match(managementRuntime, /pub fn reconcileNoFail/);
  assert.doesNotMatch(
    managementRuntime,
    /Workbench|WorkspaceView|TaskView|product_control_executor|std\.Thread|@import\("metawork_agent"\)|\*agent\.(?:Runtime|Session)/,
  );
  assert.match(state, /@import\("metawork_agent"\)/);
  assert.match(state, /@import\("product_skill_catalog"\)/);
  assert.match(state, /@import\("product_skill_enablement"\)/);
  assert.match(state, /@import\("product_skill_management"\)/);
  assert.doesNotMatch(
    state,
    /Workbench|product_control_executor|std\.Thread|CatalogJob|\*agent\.Runtime|\*agent\.Session/,
  );
  assert.match(state, /pub const State = struct/);
  assert.match(state, /pub const CatalogControl = struct/);
  assert.match(state, /pub const CatalogLeaseRelease = struct/);
  assert.match(policy, /@import\("metawork_agent"\)/);
  assert.match(policy, /@import\("product_skill_catalog"\)/);
  assert.match(policy, /@import\("product_skill_enablement"\)/);
  assert.match(policy, /@import\("product_skill_management"\)/);
  assert.match(policy, /@import\("product_skill_state"\)/);
  assert.match(policy, /pub fn compileCatalogSnapshot/);
  assert.match(policy, /pub fn recompileCatalogSnapshot/);
  assert.match(policy, /pub fn enablementPersistenceFailure/);
  assert.doesNotMatch(
    policy,
    /Workbench|WorkspaceView|TaskView|product_control_executor|std\.Thread|CatalogJob|\*agent\.Runtime|\*agent\.Session|FileStore|\.commit\(|bumpRevision|scheduleSkill/,
  );
  assert.match(ports, /@import\("metawork_agent"\)/);
  assert.match(ports, /pub const Ports = struct/);
  assert.doesNotMatch(
    ports,
    /@import\("(?:metawork_product_control|product_control_executor|metawork_app|native_sdk|metask_agentcore)"\)|\*agent\.(?:Runtime|Session)/,
  );
  assert.match(runtime, /const CatalogJob = struct/);
  assert.match(runtime, /workspaces: \[\]\?WorkspaceCatalog/);
  assert.match(runtime, /personal_job: \?\*CatalogJob/);
  assert.match(runtime, /pub fn registerWorkspaceOwned/);
  assert.match(runtime, /pub fn refreshPersonal/);
  assert.match(runtime, /pub fn refreshWorkspace/);
  assert.match(runtime, /pub fn setEnabled/);
  assert.match(runtime, /pub const CatalogAuthority = union\(enum\)/);
  assert.match(runtime, /pub fn workspaceCatalogAuthority/);
  assert.match(runtime, /pub fn ensureWorkspaceCatalog/);
  assert.match(runtime, /pub fn redactCatalogsNoFail/);
  assert.match(runtime, /fn commitEnablementCandidate/);
  assert.match(runtime, /pub fn identitySourceTrusted/);
  assert.match(runtime, /pub fn workspaceRetirementAllowed/);
  assert.match(runtime, /pub fn retireWorkspace/);
  assert.match(runtime, /pub fn resolveOwnerScope/);
  assert.match(runtime, /@import\("product_skill_management_runtime"\)/);
  assert.match(runtime, /@import\("product_skill_package"\)/);
  assert.match(runtime, /pub fn previewDirectory/);
  assert.match(runtime, /pub fn previewArchive/);
  assert.match(runtime, /pub fn readDefinition/);
  assert.match(runtime, /pub fn exportPackage/);
  assert.match(runtime, /pub fn beginShutdown/);
  assert.doesNotMatch(
    runtime,
    /@import\("(?:metawork_product_control|product_control_executor|metawork_app|native_sdk|metask_agentcore)"\)|\*agent\.(?:Runtime|Session)|std\.Thread/,
  );
  assert.doesNotMatch(
    runtime,
    /pub const Catalog(?:Slot|Control)|pub const Scope =|pub fn (?:personal|workspace)Control(?:Const)?|pub fn requestWorkspaceReschedule/,
  );
  assert.match(projection, /skill: skill_runtime\.Runtime/);
  assert.match(projection, /@import\("metawork_product_skill"\)\.ports/);
  assert.match(projection, /@import\("metawork_product_skill"\)\.runtime/);
  assert.doesNotMatch(
    projection,
    /@import\("metawork_product_skill"\)\.(?:enablement|management|package|policy|state|view)/,
  );
  assert.doesNotMatch(
    projection,
    /fn compileCatalogSnapshot|fn recompileCatalogSnapshot|fn inventoryHasInvocationInScope/,
  );
  assert.match(projection, /fn productSkillPorts/);
  assert.match(projection, /fn syncSkillCatalogsNoFail/);
  assert.match(
    projection,
    /pub fn previewSkillDirectory[\s\S]*?return self\.skill\.previewDirectory\(absolute_path\);[\s\S]*?pub fn previewSkillArchive[\s\S]*?return self\.skill\.previewArchive\(absolute_path\);/,
  );
  assert.match(
    projection,
    /pub fn readSkillDefinition[\s\S]*?requireSkillAssetAuthority\(try self\.skill\.assetScope\(install_id\)\)[\s\S]*?return self\.skill\.readDefinition\(install_id\);[\s\S]*?pub fn exportSkill[\s\S]*?requireSkillAssetAuthority\(try self\.skill\.assetScope\(install_id\)\)[\s\S]*?return self\.skill\.exportPackage\(install_id, absolute_destination\);/,
  );
  assert.doesNotMatch(
    projection,
    /fn openSkillRoot|skill_runtime\.CanonicalRoot|\.skill\.(?:definitionScope|exportScope|mutationScope)\(/,
  );
  assert.doesNotMatch(runtime, /pub const CanonicalRoot/);
  assert.doesNotMatch(
    projection,
    /const CatalogJob = struct|fn scheduleCatalogQuery|fn scheduleSkillCatalogQuery|fn commitCatalogJobsNoFail|fn commitSkillEnablementCandidate|fn noteSkillEnablementPersistenceFailure|fn installSkillSource|fn reimportSkillSource|fn scheduleSkillReconciliation|fn noteSkillPersistenceFailure|fn reconcileSkillCatalogResultNoFail|skill_package_impl\.(?:previewDirectory|inspectDirectory|inspectArchive|extractArchive|exportArchive)|\.skill\.state\.(?:transactions|staging_root)|\.skill\.state\.enablement_(?:store|health|file_store)/,
  );
  assert.match(projection, /fn requireSkillMutationAuthority/);
  assert.match(view, /@import\("product_skill_catalog"\)/);
  assert.match(view, /@import\("product_skill_management"\)/);
  assert.match(view, /@import\("product_skill_policy"\)/);
  assert.match(view, /@import\("product_skill_state"\)/);
  assert.doesNotMatch(view, /@import\("metawork_agent"\)/);
  assert.match(view, /pub const TextProjection = struct/);
  assert.match(view, /pub const WorkspaceCatalogs = struct/);
  assert.match(view, /pub fn writeCatalogProjection/);
  assert.match(view, /pub fn writeManagementProjection/);
  assert.doesNotMatch(
    view,
    /Workbench|WorkspaceView|TaskView|product_control_executor|std\.Thread|CatalogJob|Agent Runtime|Session|FileStore|credential|bumpRevision|projection_bytes/,
  );
  assert.match(projection, /fn skillWorkspaceCatalog/);
  assert.doesNotMatch(projection, /fn skillManagementInput|\.skill\.state/);
  assert.doesNotMatch(
    projection,
    /\.skill\.(?:personal|workspace)Control(?:Const)?\(|skill_runtime\.Catalog(?:Slot|Control)/,
  );
  assert.doesNotMatch(
    projection,
    /fn writeCatalogProjection|fn writeManagedSkillAsset|fn writeExternalSkillAsset|fn writeSkillAssetTail|fn writeSkillScope|fn catalogProjection|fn catalogContainsKnownCredential/,
  );
  assert.doesNotMatch(projection, /skill_catalog: skill_state\.CatalogControl/);
  assert.doesNotMatch(
    projection,
    /const SkillManagementHealth = enum|const SkillEnablementHealth = enum|const SkillReconciliation = struct|const CatalogSlot = union/,
  );
  assert.doesNotMatch(
    projection,
    /\n\s+skill_(?:inventory|transactions|management_health|enablement_file_store|enablement_health|staging_root|reconciliation|catalog_slot|catalog_request_generation):/,
  );
  assert.doesNotMatch(projection, /@import\("workbench_skill_enablement"\)/);
  assert.match(appStores, /@import\("metawork_product_skill"\)\.enablement/);
  assert.doesNotMatch(appStores, /workbench_api\.SkillEnablementFileStore/);
  assert.doesNotMatch(
    workbenchRoot,
    /SkillEnablementFileStore|skill_enablement_store_max_bytes|workbench_skill_enablement/,
  );
  assert.doesNotMatch(projection, /@import\("workbench_skill_management"\)/);
  assert.match(appStores, /@import\("metawork_product_skill"\)\.management/);
  assert.doesNotMatch(appStores, /workbench_api\.SkillManagementFileStore/);
  assert.match(
    bridgeDispatcher,
    /@import\("metawork_product_skill"\)\.management/,
  );
  assert.doesNotMatch(
    bridgeDispatcher,
    /workbench_api\.Skill(?:SourceKind|Scope|InstallId)/,
  );
  assert.doesNotMatch(
    workbenchRoot,
    /SkillManagementFileStore|skill_management_store_max_bytes|SkillSourceKind|SkillScope|SkillInstallId|workbench_skill_management/,
  );
  for (const source of [projection, workbenchRoot])
    assert.doesNotMatch(
      source,
      /@import\("metawork_product_skill"\)\.package|@import\("workbench_skill_package"\)/,
    );
  assert.match(build, /src\/product\/skill\/catalog\.zig/);
  assert.match(build, /src\/product\/skill\/enablement\.zig/);
  assert.match(build, /src\/product\/skill\/management\.zig/);
  assert.match(build, /src\/product\/skill\/management_runtime\.zig/);
  assert.match(build, /src\/product\/skill\/package\.zig/);
  assert.match(build, /src\/product\/skill\/policy\.zig/);
  assert.match(build, /src\/product\/skill\/ports\.zig/);
  assert.match(build, /src\/product\/skill\/runtime\.zig/);
  assert.match(build, /src\/product\/skill\/state\.zig/);
  assert.match(build, /src\/product\/skill\/view\.zig/);
  assert.match(
    build,
    /product_skill\.addImport\("product_skill_catalog", catalog_snapshot\)/,
  );
  assert.match(build, /addImport\("metawork_product_skill", product_skill\)/);
  assert.match(
    build,
    /product_skill\.addImport\("product_skill_enablement", skill_enablement\)/,
  );
  assert.match(
    build,
    /product_skill\.addImport\("product_skill_management", skill_management\)/,
  );
  assert.match(
    build,
    /product_skill\.addImport\("product_skill_ports", product_skill_ports\)/,
  );
  assert.match(
    build,
    /product_skill\.addImport\("product_skill_runtime", product_skill_runtime\)/,
  );
  assert.match(
    build,
    /product_skill_runtime\.addImport\("product_skill_enablement", skill_enablement\)/,
  );
  assert.match(
    build,
    /product_skill_runtime\.addImport\([\s\S]*?"product_skill_management_runtime"[\s\S]*?product_skill_management_runtime[\s\S]*?\)/,
  );
  assert.match(
    build,
    /product_skill_runtime\.addImport\("product_skill_package", skill_package\)/,
  );
  assert.doesNotMatch(
    build,
    /product_skill\.addImport\("product_skill_(?:package|policy|state|view)"/,
  );
  assert.match(build, /name = "metawork-product-skill-policy"/);
  assert.match(build, /name = "metawork-product-skill-runtime"/);
  assert.match(
    build,
    /product_skill_runtime\.addImport\("product_skill_view", product_skill_view\)/,
  );
  assert.match(build, /name = "metawork-product-skill-view"/);
  assert.match(build, /name = "metawork-product-skill-state"/);
  assert.doesNotMatch(
    build,
    /src\/workbench\/skill_(?:package|enablement|management)\.zig|workbench_skill_(?:package|enablement|management)|metawork-skill-(?:package|enablement|management)/,
  );
});

test("Control review jobs own their data without holding Task lifecycle leases", () => {
  const job = read("src/product/control/permission_job.zig");
  assert.doesNotMatch(
    job,
    /\*(?:const )?(?:Task|Run|Runtime)|WorkerLease|SessionAccess/,
  );
  assert.match(job, /thread\.join\(\)/);
  const task = read("src/product/task/runtime.zig");
  const preparation = task
    .split("pub const PreparedPermissionReview = struct {")[1]
    ?.split("pub fn deinit")[0];
  assert.ok(preparation);
  assert.doesNotMatch(
    preparation,
    /\*(?:const )?(?:Task|Run|Runtime)|WorkerLease|SessionAccess/,
  );
});

test("Product Task kernels have one physical home without taking the executor", () => {
  const build = read("build.zig");
  const productTask = read("src/product/task.zig");
  const taskPersistence = read("src/product/task/persistence.zig");
  const taskState = read("src/product/task/state.zig");
  const taskPolicy = read("src/product/task/policy.zig");
  const taskExecution = read("src/product/task/execution.zig");
  const taskView = read("src/product/task/view.zig");
  const taskAgentSession = read("src/product/task/agent_session.zig");
  const taskAttachment = read("src/product/task/attachment.zig");
  const taskRuntime = read("src/product/task/runtime.zig");
  const taskKernelFiles = zigFiles("src/product/task/");
  const projection = read("src/product/control/runtime.zig");
  const executor = read("src/product/control/executor.zig");
  const workbenchRoot = read("src/product/control.zig");
  const appStores = read("src/app/stores.zig");
  const recoveryJob = read("src/product/task/recovery_job.zig");

  assert.match(productTask, /pub const Runtime = runtime\.Runtime;/);
  assert.match(
    productTask,
    /pub const history = @import\("product_task_persistence"\)/,
  );
  assert.match(
    productTask,
    /pub const checkpoint_store = @import\("product_task_checkpoint_store"\)/,
  );
  assert.match(
    productTask,
    /pub const testing = if \(builtin\.is_test\) struct/,
  );
  assert.doesNotMatch(
    productTask,
    /pub const (?:state|policy|view|attachment|agent_session|execution|execution_binding|deletion|recovery|recovery_job|runtime) =/,
  );
  assert.match(projection, /@import\("metawork_product_task"\)/);
  assert.doesNotMatch(
    projection,
    /@import\("(?:workbench_task_|workbench_checkpoint_|workbench_owned_task_execution|product_task_(?:state|policy|view|attachment|agent_session|execution|execution_binding|deletion|recovery|recovery_job|runtime|persistence|checkpoint_record|checkpoint_store))/,
  );
  assert.doesNotMatch(
    workbenchRoot,
    /\b(?:TaskFileStore|CheckpointFileStore|CheckpointStoreHealth|CheckpointBlobIdentity|task_store_max_bytes)\b/,
  );
  assert.match(appStores, /@import\("metawork_product_task"\)/);
  assert.match(appStores, /product_task\.history\.FileStore/);
  assert.match(appStores, /product_task\.checkpoint_store\.FileStore/);
  assert.doesNotMatch(
    recoveryJob,
    /product_control_executor|@import\("metawork_product_control"\)/,
  );
  assert.match(build, /src\/product\/task\/recovery_job\.zig/);
  assert.match(build, /src\/product\/task\/agent_session\.zig/);
  assert.match(build, /src\/product\/task\/attachment\.zig/);
  assert.match(build, /src\/product\/task\/runtime\.zig/);
  assert.match(build, /src\/product\/task\/state\.zig/);
  assert.match(build, /src\/product\/task\/policy\.zig/);
  assert.match(build, /src\/product\/task\/execution\.zig/);
  assert.match(build, /src\/product\/task\/view\.zig/);
  assert.match(
    build,
    /task_persistence\.addImport\("product_task_state", task_state\)/,
  );
  assert.match(
    build,
    /product_control_runtime\.addImport\("metawork_product_task", product_task\)/,
  );
  assert.match(
    build,
    /app\.addImport\("metawork_product_task", product_task\)/,
  );

  const runRecord = taskState.match(
    /pub const RunRecord = struct \{[\s\S]*?\n\};/,
  )?.[0];
  const compactRecord = taskState.match(
    /pub const CompactRecord = struct \{[\s\S]*?\n\};/,
  )?.[0];
  assert.ok(runRecord, "Task state must own the concrete RunRecord");
  assert.ok(compactRecord, "Task state must own the concrete CompactRecord");
  for (const record of [runRecord, compactRecord]) {
    assert.doesNotMatch(record, /\b(?:workbench|task|session):\s*\*/);
  }
  assert.match(taskState, /pub const Task = struct/);
  assert.match(taskState, /pub fn applyEvent\(/);
  assert.match(taskState, /pub fn markTerminalRunsBeforeEventDrain\(/);
  assert.match(taskState, /pub fn finalizeMarkedTerminalRunsAfterEventDrain\(/);
  assert.match(taskState, /pub fn compactProjectionFacts\(/);
  for (const consumer of [taskPolicy, taskPersistence, taskView]) {
    assert.match(consumer, /task_state\.compactProjectionFacts\(/);
    assert.doesNotMatch(consumer, /task_state\.compactTerminalPayload\(/);
  }
  assert.match(taskState, /@import\("metawork_agent"\)/);
  assert.doesNotMatch(
    taskState,
    /Workbench|product_control_executor|std\.Thread|@import\("(?:metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  assert.doesNotMatch(projection, /const RunRecord = task_model\.RunRecord;/);
  assert.doesNotMatch(
    projection,
    /const CompactRecord = task_model\.CompactRecord;/,
  );
  assert.doesNotMatch(projection, /const RunRecord = struct/);
  assert.doesNotMatch(projection, /const CompactRecord = struct/);
  assert.doesNotMatch(build, /projection\.addImport\("product_task_/);
  assert.match(projection, /const task_testing = product_task\.testing;/);
  assert.match(
    projection,
    /if \(builtin\.is_test\) task_testing\.state_module else struct \{\}/,
  );
  assert.match(taskExecution, /pub const RunJob = struct/);
  assert.match(taskExecution, /pub const CompactJob = struct/);
  assert.match(taskExecution, /pub fn executeRun\(/);
  assert.match(taskExecution, /pub fn cancelRun\(/);
  assert.match(taskExecution, /pub fn executeCompact\(/);
  assert.match(taskExecution, /pub fn cancelCompact\(/);
  assert.match(
    taskExecution,
    /title_execution: \?execution_binding\.OwnedTaskExecution/,
  );
  assert.match(
    taskExecution,
    /if \(self\.title_execution\) \|\*execution\| execution\.deinit\(\)/,
  );
  const automaticTitle = taskState.match(
    /pub const AutomaticTitle = struct \{[\s\S]*?\n\};/,
  )?.[0];
  assert.ok(automaticTitle, "Task state must own AutomaticTitle facts");
  assert.doesNotMatch(
    automaticTitle,
    /OwnedTaskExecution|credential|secret|execution:/,
  );
  assert.doesNotMatch(
    taskExecution,
    /Workbench|TaskView|\*task_runtime\.|product_control_executor|@import\("(?:metawork_product_control|metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  assert.doesNotMatch(taskExecution, /\b(?:workbench|task|runtime):\s*\*/);
  assert.match(taskRuntime, /task_execution\.executeRun,/);
  assert.match(taskRuntime, /task_execution\.cancelRun,/);
  assert.match(taskRuntime, /task_execution\.executeCompact,/);
  assert.match(taskRuntime, /task_execution\.cancelCompact,/);
  assert.doesNotMatch(projection, /fn (?:execute|cancel)(?:Run|Compact)Job\(/);
  assert.match(projection, /fn drainAgentEventPass\(/);
  assert.match(projection, /agent_runtime\.takeEvent\(\)/);
  assert.match(projection, /task_runtime\.applyEvent\(/);
  assert.doesNotMatch(projection, /task_model\.applyEvent\(/);
  assert.doesNotMatch(projection, /fn taskEventProjection\(/);
  for (const policyFn of [
    "classifyAgentTerminal",
    "classifyCompactTerminal",
    "classifyBeginFailure",
    "decisionForSignal",
    "checkpointFailureAttempt",
    "hasActiveOperation",
    "checkpointMatchesCurrentHistory",
    "foldTerminalDisposition",
  ]) {
    assert.match(taskPolicy, new RegExp(`pub fn ${policyFn}\\(`));
    assert.doesNotMatch(projection, new RegExp(`fn ${policyFn}\\(`));
  }
  assert.match(taskPolicy, /@import\("product_task_state"\)/);
  assert.match(taskPolicy, /@import\("metawork_agent"\)/);
  assert.doesNotMatch(
    taskPolicy,
    /Workbench|product_control_executor|std\.Thread|commitTaskState|bumpRevision|agent_runtime\.takeEvent|@import\("(?:metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  for (const operation of [
    "openTask",
    "startRun",
    "startCompact",
    "cancelRun",
    "cancelCompact",
    "respondUi",
    "selectModel",
    "beginDetach",
    "applyEvent",
    "startRecovery",
    "writeProjectionList",
    "prepareShutdown",
  ]) {
    assert.match(taskRuntime, new RegExp(`pub fn ${operation}\\(`));
  }
  for (const persistenceType of [
    "Commit",
    "Capability",
    "Health",
    "TaskStateWireScratch",
    "RestoreProjection",
  ]) {
    assert.match(taskPersistence, new RegExp(`pub const ${persistenceType} =`));
  }
  for (const persistenceFn of ["projectTask", "restoreTask", "parseEnum"]) {
    assert.match(taskPersistence, new RegExp(`pub fn ${persistenceFn}\\(`));
  }
  for (const retiredProjectionFn of [
    "restoreTask",
    "restoreCheckpointRecord",
    "restoreRun",
    "restoreRunInput",
    "restoreTool",
    "restoreFileReference",
    "restoreCompact",
    "taskWireWithCheckpoint",
    "runWire",
    "restoreUiRecord",
    "parsePersistedEnum",
  ]) {
    assert.doesNotMatch(
      projection,
      new RegExp(`(?:^|\\n)\\s*fn ${retiredProjectionFn}\\(`),
    );
  }
  assert.match(taskRuntime, /task_persistence\.restoreTask\(/);
  assert.match(taskRuntime, /task_persistence\.projectTask\(/);
  assert.doesNotMatch(
    projection,
    /task_persistence\.(?:restoreTask|projectTask)\(/,
  );
  assert.match(projection, /fn taskRestoreProjection\(/);
  assert.match(projection, /fn buildTaskStateWireWithCheckpoint\(/);
  assert.match(projection, /fn commitTaskStateWithCheckpoint\(/);
  assert.doesNotMatch(
    taskPersistence,
    /Workbench|product_control_executor|std\.Thread|commitTaskState|bumpRevision|writeSnapshot|@import\("(?:metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  for (const viewFn of [
    "writeProjection",
    "writePendingUi",
    "catalogProjection",
  ]) {
    assert.match(taskView, new RegExp(`pub fn ${viewFn}\\(`));
  }
  assert.match(taskView, /pub const TextProjection = struct/);
  assert.match(taskView, /pub const CatalogProjection = struct/);
  assert.match(taskView, /pub const PendingUiProjection = struct/);
  assert.match(taskView, /task: \*const task_state\.Task/);
  assert.match(taskView, /@import\("product_task_state"\)/);
  assert.match(taskView, /@import\("product_task_policy"\)/);
  assert.match(taskView, /@import\("product_task_recovery"\)/);
  assert.match(taskView, /@import\("metawork_product_skill"\)/);
  assert.doesNotMatch(
    taskView,
    /\*Workbench|:\s*Workbench\b|product_control_executor|std\.Thread|\*agent\.Session|commitTaskState|bumpRevision|writeSnapshot|@import\("(?:metawork_product_control|metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  for (const retiredViewFn of [
    "writeCompact",
    "writeRun",
    "writeUiHistory",
    "writePendingUiProjection",
    "taskCatalogProjection",
  ]) {
    assert.doesNotMatch(
      projection,
      new RegExp(`(?:^|\\n)\\s*fn ${retiredViewFn}\\(`),
    );
  }
  assert.match(taskRuntime, /task_view\.writeProjection\(/);
  assert.match(taskRuntime, /task_view\.writePendingUi\(/);
  assert.match(taskRuntime, /access\.copyPendingUiRequest\(/);
  assert.match(taskAgentSession, /session: \?\*agent\.Session/);
  assert.match(taskAgentSession, /pub const Binding = struct/);
  assert.match(taskAgentSession, /pub const Access = struct/);
  assert.match(taskAgentSession, /session\.retainReference\(\)/);
  assert.match(taskAgentSession, /session\.releaseReference\(\)/);
  assert.match(taskAgentSession, /releaseClosedSession\(value\.session\)/);
  assert.doesNotMatch(taskAgentSession, /rawSession/);
  assert.doesNotMatch(
    projection,
    /\*(?:lifecycle|agent)\.Session|createSessionRoute|restoreSessionRoute|releaseClosedSession|SessionRestoreRoute|SessionRoute|\.session\.(?:prepareRun|prepareCompact|copyPendingUiRequest|respondPermission|setModel|refreshSkillCatalog|closeOutcome)/,
  );
  for (const file of taskKernelFiles) {
    if (file === "src/product/task/agent_session.zig") continue;
    const source = read(file);
    assert.doesNotMatch(
      source,
      /\*(?:agent|lifecycle)\.Session|(?:agent|lifecycle)\.SessionRoute|(?:agent|lifecycle)\.SessionRestoreRoute|createSessionRoute|restoreSessionRoute|releaseClosedSession/,
      `${file} must consume Binding, Access, or typed Session facts only`,
    );
  }
  assert.doesNotMatch(
    productTask,
    /\*(?:agent|lifecycle)\.Session|(?:agent|lifecycle)\.SessionRoute|(?:agent|lifecycle)\.SessionRestoreRoute/,
  );
  assert.match(taskAttachment, /binding: agent_session\.Binding/);
  assert.doesNotMatch(taskAttachment, /session: \*agent\.Session/);
  const liveAttachment = taskAttachment.match(
    /pub const LiveAttachment = struct \{[\s\S]*?\n\};/,
  )?.[0];
  assert.ok(liveAttachment, "Task LiveAttachment must remain explicit");
  assert.doesNotMatch(liveAttachment, /route_id: u64/);
  assert.match(
    taskAttachment,
    /pub const ClosingAttachment = struct \{[\s\S]*?route_id: u64,[\s\S]*?worker_binding: agent_session\.Binding,[\s\S]*?\n\};/,
  );
  assert.match(
    taskAttachment,
    /const worker_binding = value\.binding\.take\(\);/,
  );
  assert.match(taskAttachment, /\.closing => \|\*value\| value\.route_id/);
  assert.match(
    taskAttachment,
    /\.closing => \|value\| closing: \{[\s\S]*?std\.debug\.assert\(self\.close_thread == null\);[\s\S]*?\.owned, \.closed, \.fixture => closing_value\.live\.binding =[\s\S]*?closing_value\.worker_binding\.take\(\)/,
  );
  assert.match(taskRuntime, /pub const Runtime = struct/);
  assert.match(taskRuntime, /tasks: \[\]\?task_state\.Task/);
  assert.match(taskRuntime, /failures: std\.ArrayList\(FailureRecord\)/);
  assert.match(taskRuntime, /next_task_id: u64/);
  assert.match(taskRuntime, /next_restore_attempt_id: u64/);
  assert.match(taskRuntime, /late_terminal_event_count: u64/);
  assert.doesNotMatch(
    taskRuntime,
    /durable_mutation_state: DurableMutationState/,
  );
  assert.doesNotMatch(taskRuntime, /pub fn observeDurableCommit\(/);
  assert.doesNotMatch(
    taskRuntime,
    /Workbench|product_control_executor|@import\("(?:metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  assert.match(projection, /task_runtime: task_runtime\.Runtime/);
  assert.doesNotMatch(
    projection,
    /\n\s+(?:tasks|task_failures|next_task_id|next_task_recent_order|next_restore_attempt_id|late_terminal_event_count|recovery_poisoned|agent_runtime_shutdown_complete):/,
  );
  assert.match(recoveryJob, /pub const CommitAuthority = struct/);
  assert.match(recoveryJob, /pub fn commitAllowed\(/);
  assert.match(taskRuntime, /recovery_job\.commitAllowed\(/);
  assert.doesNotMatch(
    recoveryJob,
    /route: agent\.SessionRestoreRoute|candidate\.route/,
  );
  assert.match(projection, /pub fn writeSnapshot\(/);
  assert.match(
    projection,
    /test "Product Control snapshot serializer matches the Renderer contract fixture"/,
  );
  assert.doesNotMatch(
    workbenchRoot,
    /pub const TaskPersistence(?:Commit|Health)?\b/,
  );
  assert.match(appStores, /product_task\.history\.Commit/);
  assert.match(executor, /identity: \*anyopaque,[\s\S]*context: \*anyopaque,/);
  assert.match(executor, /if \(item\.identity != identity\) continue;/);
});

test("Product MCP kernels have one physical home and isolate refresh workers", () => {
  const build = read("build.zig");
  const productMcp = read("src/product/mcp.zig");
  const configuration = read("src/product/mcp/configuration.zig");
  const state = read("src/product/mcp/state.zig");
  const policy = read("src/product/mcp/policy.zig");
  const view = read("src/product/mcp/view.zig");
  const ports = read("src/product/mcp/ports.zig");
  const refreshJob = read("src/product/mcp/refresh_job.zig");
  const runtime = read("src/product/mcp/runtime.zig");
  const workbenchRoot = read("src/product/control.zig");
  const workbenchProjection = read("src/product/control/runtime.zig");

  assert.equal(
    existsSync(
      new URL("src/product/mcp/testdata/mcp-http-endpoints.json", root),
    ),
    true,
  );
  assert.match(
    productMcp,
    /pub const contract = @import\("product_mcp_configuration"\)/,
  );
  assert.match(productMcp, /@import\("product_mcp_ports"\)/);
  assert.match(productMcp, /@import\("product_mcp_runtime"\)/);
  assert.match(productMcp, /pub const Runtime = runtime_module\.Runtime/);
  assert.match(productMcp, /pub const Ports = ports_module\.Ports/);
  assert.match(productMcp, /pub const testing = runtime_module\.testing/);
  assert.doesNotMatch(
    productMcp,
    /product_mcp_(?:state|policy|view|refresh_job)|pub const (?:state|policy|view|refresh_job|runtime|ports)\b/,
  );
  assert.match(configuration, /@import\("agent_mcp_http_protocol"\)/);
  assert.doesNotMatch(configuration, /@import\("metawork_agent"\)/);
  // Product MCP state intentionally consumes MetaWork Agent's public
  // Activation/Selection surface; the AgentCore SDK remains forbidden here.
  assert.match(state, /@import\("metawork_agent"\)/);
  assert.match(state, /@import\("product_mcp_configuration"\)/);
  assert.doesNotMatch(
    state,
    /McpRefreshJob|product_control_executor|std\.Thread/,
  );
  for (const field of [
    "refresh_request_generation",
    "refresh_pending",
    "refresh_deadline_ms",
  ]) {
    assert.match(state, new RegExp(`\\b${field}\\b`));
  }
  assert.doesNotMatch(state, /\brefresh_pending_blocks_admission\b/);
  assert.doesNotMatch(runtime, /\bblocksNewTaskAdmission\b/);
  assert.match(state, /pub fn mcpRefreshDelayMs/);
  assert.match(state, /pub fn mcpRefreshDeadlineMs/);
  // Product MCP policy prepares Agent-owned allowlist values and returns
  // borrowed Selection facts, but never owns an Agent runtime or worker.
  assert.match(policy, /@import\("metawork_agent"\)/);
  assert.match(policy, /@import\("product_mcp_configuration"\)/);
  assert.match(policy, /@import\("product_mcp_state"\)/);
  assert.doesNotMatch(
    policy,
    /McpRefreshJob|product_control_executor|std\.Thread|pub const Workbench|createMcpAdmissionSelection|commitPrepared|bumpRevision|mcp_refresh_timer/,
  );
  for (const name of [
    "validAuthorizationTransition",
    "serverMutationBusy",
    "preparePendingReauthorization",
    "serverToolsForAdmission",
    "buildOauthRefreshBinding",
    "buildRefreshAllowlists",
    "replaceAdmission",
    "blockAdmissionForCurrentState",
    "nextOauthExpiry",
    "selectionForNewTask",
    "recoveryGeneration",
  ]) {
    assert.match(policy, new RegExp(`pub fn ${name}\\b`));
  }
  assert.match(view, /@import\("product_mcp_configuration"\)/);
  assert.match(view, /@import\("product_mcp_state"\)/);
  assert.doesNotMatch(view, /@import\("metawork_agent"\)/);
  assert.match(view, /pub fn writeProjection/);
  assert.match(view, /pub const TextProjection/);
  assert.match(view, /refresh_job_active: bool/);
  assert.doesNotMatch(view, /mcp_refresh_job/);
  assert.doesNotMatch(
    view,
    /McpRefreshJob|product_control_executor|std\.Thread|pub const McpProductState/,
  );
  assert.match(ports, /pub const Executor = struct/);
  assert.match(ports, /pub const Catalog = struct/);
  assert.match(ports, /pub const Timer = struct/);
  assert.match(ports, /pub const Notifier = struct/);
  assert.doesNotMatch(
    ports,
    /@import\("metawork_product_control"\)|@import\("product_control_executor"\)|std\.Thread|\*agent\.Runtime/,
  );
  assert.match(refreshJob, /pub const Job = struct/);
  assert.match(refreshJob, /pub fn execute/);
  assert.match(refreshJob, /pub fn cancel/);
  assert.match(refreshJob, /executorJob/);
  assert.doesNotMatch(
    refreshJob,
    /\b(?:workbench|runtime|state):\s*\*|@import\("product_control_executor"\)|std\.Thread/,
  );
  assert.match(runtime, /pub const Runtime = struct/);
  assert.match(runtime, /state: state_module\.McpProductState/);
  assert.match(runtime, /refresh_job: \?\*refresh_job\.Job/);
  assert.match(runtime, /pub const testing = if \(builtin\.is_test\) struct/);
  assert.match(runtime, /pub const State = state_module\.McpProductState/);
  assert.match(runtime, /pub const RefreshJob = refresh_job\.Job/);
  for (const name of [
    "requestRefresh",
    "syncRefreshJob",
    "beginConnectionTest",
    "beginConfigurationApply",
    "completeConfigurationApply",
    "rearmRefreshTimer",
    "beginShutdown",
    "finishShutdownAfterExecutorJoin",
    "requireOauthReauthorization",
    "beginAuthorization",
    "authorizeOauth",
    "beginOauthDynamicRegistration",
    "completeOauthCodeExchange",
    "beginOauthRefresh",
    "completeOauthRefresh",
    "clearOauthOperation",
    "recoverOauthOperation",
    "createHttpServer",
    "updateHttpConnection",
    "captureStaticSecret",
    "removeServer",
  ]) {
    assert.match(runtime, new RegExp(`pub fn ${name}\\b`));
  }
  assert.doesNotMatch(
    runtime,
    /@import\("metawork_product_control"\)|@import\("metawork_app"\)|@import\("metawork_bridge"\)|@import\("metawork_account"\)|native_sdk|std\.Thread|\bworkbench:\s*\*/,
  );
  assert.match(build, /addImport\("metawork_product_mcp", product_mcp\)/);
  assert.match(build, /src\/product\/mcp\/view\.zig/);
  assert.match(build, /src\/product\/mcp\/policy\.zig/);
  assert.match(
    build,
    /product_mcp_policy\.addImport\("metawork_agent", agent\)/,
  );
  assert.match(
    build,
    /product_mcp_policy\.addImport\("product_mcp_configuration", mcp_configuration\)/,
  );
  assert.match(
    build,
    /product_mcp_policy\.addImport\("product_mcp_state", product_mcp_state\)/,
  );
  assert.match(
    build,
    /product_mcp_view\.addImport\("product_mcp_configuration", mcp_configuration\)/,
  );
  assert.match(
    build,
    /product_mcp_view\.addImport\("product_mcp_state", product_mcp_state\)/,
  );
  assert.match(build, /"test-product-mcp-view"/);
  assert.match(build, /"test-product-mcp-policy"/);
  assert.match(build, /"test-product-mcp-refresh-job"/);
  assert.match(build, /"test-product-mcp-runtime"/);
  assert.match(
    build,
    /product_mcp_refresh_job\.addImport\("product_mcp_ports", product_mcp_ports\)/,
  );
  assert.match(
    build,
    /product_mcp_runtime\.addImport\("product_mcp_refresh_job", product_mcp_refresh_job\)/,
  );
  assert.match(
    build,
    /product_mcp_runtime\.addImport\("product_mcp_view", product_mcp_view\)/,
  );
  for (const internal of ["state", "policy", "view", "refresh_job"]) {
    assert.doesNotMatch(
      build,
      new RegExp(`product_mcp\\.addImport\\("product_mcp_${internal}",`),
    );
  }
  assert.match(
    build,
    /product_mcp\.addImport\("product_mcp_ports", product_mcp_ports\)/,
  );
  assert.match(
    build,
    /product_mcp\.addImport\("product_mcp_runtime", product_mcp_runtime\)/,
  );
  assert.match(build, /"Product Control snapshot serializer"/);
  assert.match(
    workbenchProjection,
    /const product_mcp = @import\("metawork_product_mcp"\)/,
  );
  assert.match(
    workbenchProjection,
    /const mcp_configuration = product_mcp\.contract/,
  );
  assert.match(workbenchProjection, /const mcp_ports = product_mcp/);
  assert.match(workbenchProjection, /const mcp_runtime = product_mcp/);
  assert.match(workbenchProjection, /const mcp_testing = product_mcp\.testing/);
  assert.doesNotMatch(
    workbenchProjection,
    /product_mcp\.(?:configuration|state|policy|view|ports|refresh_job|runtime)|\bMcpProductState\b|\bMcpRefreshJob\b|\bmcp_policy\b/,
  );
  assert.match(workbenchProjection, /mcp_runtime\.writeProjection/);
  for (const name of [
    "selectionForNewTask",
    "recoveryAuthority",
    "authorityStable",
    "recoveryGeneration",
    "writeConnectionApprovalDetails",
    "validateSecretCapture",
    "capabilities",
  ]) {
    assert.match(runtime, new RegExp(`pub fn ${name}\\b`));
  }
  assert.doesNotMatch(
    workbenchProjection,
    /fn mcpAvailability|fn mcpRuntimeServerStatus|fn mcpProjectionRedacted|fn mcpAuthorizationStatus|fn mcpNewTaskAccess/,
  );
  assert.doesNotMatch(
    workbenchProjection,
    /fn validMcpAuthorizationTransition|fn mcpServerMutationBusy|fn mcpPendingReauthorization|fn mcpScopeSetAddsRequirement|fn prepareMcpPendingReauthorization|fn installMcpPendingReauthorization|fn mcpServerToolsForAdmission|fn buildMcpOauthRefreshBinding|fn buildMcpRefreshAllowlists|fn mcpExpectedGenerationMatches|fn replaceMcpAdmission|fn blockMcpAdmissionForCurrentState|fn recoveryMcpGeneration/,
  );
  for (const name of [
    "rearmMcpRefreshTimerNoFail",
    "commitMcpRefreshJobNoFail",
  ]) {
    assert.match(workbenchProjection, new RegExp(`fn ${name}\\b`));
  }
  assert.doesNotMatch(
    workbenchProjection,
    /fn commitMcpMutation|fn mcpAdmissionForTarget|\.prepare(?:Create|Update|Remove|Approve|Capture|Oauth|Begin|Complete|Clear|Require)[A-Z]|\.commitPrepared(?:Mutation|OauthOperationState)/,
  );
  assert.doesNotMatch(
    workbenchProjection,
    /fn executeMcpRefreshJob|fn cancelMcpRefreshJob/,
  );
  assert.doesNotMatch(
    workbenchProjection,
    /fn requestMcpCatalogRefresh|fn startPendingMcpCatalogRefresh/,
  );
  assert.doesNotMatch(
    workbenchProjection,
    /agent_runtime\.createMcpAdmissionSelection/,
  );
  assert.doesNotMatch(workbenchRoot, /workbench_mcp_configuration/);
  assert.doesNotMatch(workbenchRoot, /pub const McpConfigurationFileStore/);
  assert.doesNotMatch(workbenchRoot, /pub const McpManagementOutcome/);
  assert.doesNotMatch(workbenchRoot, /pub const McpRefreshTimer/);
  assert.doesNotMatch(workbenchRoot, /pub const McpOauthRefreshBinding/);
  assert.match(workbenchProjection, /mcp: \?mcp_runtime\.Runtime/);
  assert.doesNotMatch(
    workbenchProjection,
    /mcp_refresh_job: \?\*McpRefreshJob/,
  );
  assert.doesNotMatch(
    workbenchProjection,
    /^\s*mcp_refresh_timer: McpRefreshTimer,/m,
  );
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
  assert.match(app, /account_http\.accountTransport\(\)/);
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
  assert.doesNotMatch(ports, /ModelCredentialVault|model_credentials/);
  assert.match(runtime, /@import\("account_ports"\)/);
  assert.doesNotMatch(
    runtime,
    /account_path|account_dir|AccountDirectoryUnavailable/,
  );
  assert.match(binding, /native_sdk\.platform\.PlatformServices/);
  assert.match(binding, /pub fn ports\(self: \*Adapter\) ports_api\.Platform/);
  assert.doesNotMatch(
    binding,
    /account_path|account_dir|createDirPathOpen|AccountDirectoryUnavailable/,
  );
  assert.doesNotMatch(binding, /preference|Preference|model|Model/);
  assert.match(binding, /\.set_refresh_token_fn = setRefreshToken/);
  assert.match(binding, /\.get_refresh_token_fn = getRefreshToken/);
  assert.match(binding, /\.delete_refresh_token_fn = deleteRefreshToken/);
  assert.match(app, /account_platform_binding\.Adapter\.init/);
  assert.match(app, /models_management\.start\(\s*self\.account_path,/);
  assert.match(
    app,
    /coordinator\.shutdown\(\);[\s\S]*coordinator\.drain\(\);[\s\S]*binding\.deinit\(\)/,
  );
});

test("OAuth mechanics are neutral while callers own policy and Application owns sockets", () => {
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
  const oauthMechanics = read("src/oauth/mechanics.zig");
  const oauthLoopback = read("src/oauth/loopback.zig");
  const build = read("build.zig");

  assert.doesNotMatch(
    accountSource,
    /std\.Io\.net\.Server|\.listen\(|\.accept\(|std\.http\.Server/,
  );
  assert.match(policy, /pub const RequestSink = mechanics\.RequestSink/);
  assert.match(policy, /pub const CallbackPolicy = struct/);
  assert.match(policy, /oauth\.parseCallbackTargetValidated/);
  assert.match(transport, /listener: std\.Io\.net\.Server/);
  assert.match(transport, /pub const Adapter = struct/);
  assert.match(transport, /sink\.handle/);
  assert.match(
    transport,
    /var read_buffer:[\s\S]*?defer std\.crypto\.secureZero\(u8, &read_buffer\);/,
  );
  assert.match(loginAttempt, /loopback_endpoint: loopback\.Endpoint/);
  assert.match(mcpOauth, /oauth_loopback_transport\.Server/);
  assert.match(oauthMechanics, /pub const AttemptMaterial = struct/);
  assert.match(oauthMechanics, /std\.crypto\.timing_safe\.eql/);
  assert.match(oauthLoopback, /pub const RequestSink = struct/);
  assert.match(mcpOauth, /const CallbackPolicy = struct/);
  assert.match(mcpOauth, /const callback_path = "\/auth\/callback"/);
  assert.doesNotMatch(
    [mcpOauth, transport].join("\n"),
    /@import\("account_(?:oauth|loopback)"\)/,
  );
  assert.doesNotMatch(
    build,
    /mcp_oauth\.addImport\("account_(?:oauth|loopback)"/,
  );
  assert.match(build, /mcp_oauth\.addImport\("oauth_mechanics"/);
  assert.match(build, /mcp_oauth\.addImport\("oauth_loopback"/);
});

test("Product history schema consumes only the unique Storage SQL contract", () => {
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
    "metawork_product_control",
    "metawork_bridge",
    "metask_agentcore",
    "native_sdk",
  ]);
  assert.doesNotMatch(storageContract, /@cImport|sqlite3|storage\/sqlite\.zig/);
  assert.deepEqual(
    storageFiles.filter((file) => /@cImport|sqlite3/.test(read(file))),
    [
      "src/storage/sqlite/connection.zig",
      "src/storage/sqlite/migrations.zig",
      "src/storage/sqlite.zig",
    ],
  );
  for (const file of nonStorageFiles) {
    assert.doesNotMatch(
      read(file),
      /@import\("(?:metawork[_-]storage|storage\/sqlite\.zig)"\)|@cInclude\("sqlite3\.h"\)|\bsqlite3_/,
      `${file} bypasses the Storage SQL contract`,
    );
  }
  const schemaFile = "src/product/control/persistence/schema.zig";
  assert.deepEqual(
    nonStorageFiles.filter((file) =>
      /@import\("metawork_storage_sql"\)/.test(read(file)),
    ),
    [schemaFile],
  );
  assertNoImports(
    [schemaFile],
    [
      "storage",
      "metawork_storage",
      "metawork_app",
      "metawork_agent",
      "metawork_product_control",
      "native_sdk",
    ],
  );
  assert.doesNotMatch(
    read(schemaFile),
    /@cImport|sqlite3|Database\.create|\.mutate\(|\.query\(/,
  );
  assert.match(read(schemaFile), /sql\.validMigrations\(migrations\)/);
  assert.match(
    read(schemaFile),
    /@embedFile\("migrations\/0001_task_history\.sql"\)/,
  );
  const contractTargets = [
    ...build.matchAll(
      /\b([A-Za-z_]\w*)\.addImport\("([^"]+)",\s*(?:test_modules\.)?storage_sql\)/g,
    ),
  ];
  assert.deepEqual(
    contractTargets.map((match) => [match[1], match[2]]).sort(),
    [
      ["history_schema_fixture_module", "metawork_storage_sql"],
      ["history_schema_tests_module", "metawork_storage_sql"],
      ["product_control_history_schema", "metawork_storage_sql"],
      ["storage", "metawork_storage_sql"],
    ],
  );
  const contractReceivers = [
    ...build.matchAll(
      /\b([A-Za-z_]\w*)\.addImport\("metawork_storage_sql",\s*([^)]*)\)/g,
    ),
  ];
  assert.deepEqual(contractReceivers.map((match) => match[1]).sort(), [
    "history_schema_fixture_module",
    "history_schema_tests_module",
    "product_control_history_schema",
    "storage",
  ]);
  assert.ok(
    contractReceivers.every((match) =>
      /^(?:test_modules\.)?storage_sql$/.test(match[2].trim()),
    ),
  );
  assert.equal(
    (
      build.match(
        /\.root_source_file = b\.path\("src\/storage\/sql\.zig"\)/g,
      ) ?? []
    ).length,
    1,
  );
  for (const file of storageFiles) {
    assert.doesNotMatch(
      read(file),
      /@import\("(?:storage\/|\.\.\/)?sql\.zig"\)/,
    );
  }
  assert.deepEqual(
    [
      ...build.matchAll(
        /\b([A-Za-z_]\w*)\.addImport\("product_control_history_schema",/g,
      ),
    ].map((match) => match[1]),
    ["history_schema_tests_module"],
  );
  assert.match(build, /"test-product-history-schema"/);
  assert.match(
    build,
    /artifacts\.tests\.step\.dependOn\(&history_schema_tests_run\.step\)/,
  );

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
  const bundleVerifier = read("build_support/agentcore_bundle.zig");
  const bundlePolicy = read("scripts/agentcore-bundle.mjs");
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
      "agent_mcp_connector",
      "agent_mcp_catalog",
      "agent_mcp_runtime",
      "event_pump",
      "event_sink",
      "fixture",
      "session",
    ].sort(),
  );
  const buildManifest = read("build.zig.zon");
  for (const target of [
    "aarch64-macos",
    "x86_64-macos",
    "aarch64-windows-gnu",
    "x86_64-windows-gnu",
  ]) {
    assert.match(buildManifest, new RegExp(`\\.agentcore/bundles/${target}`));
  }
  assert.match(build, /\.agentcore\/bundles/);
  assert.doesNotMatch(build, /\.agentcore\/bundle(?:["/])/);
  for (const file of filesWithExtensions("scripts/", [".mjs"]).filter(
    (path) => !path.endsWith(".test.mjs"),
  )) {
    assert.doesNotMatch(
      read(file),
      /\.agentcore(?:\/|["'],\s*["'])bundle(?:\/|["'])/u,
      `${file} references the retired single-bundle path`,
    );
  }
  assert.doesNotMatch(build, /\.addObjectFile\(/);
  for (const [target, lock] of [
    ["aarch64-windows-gnu", "agentcore-bundle.windows-aarch64.lock.json"],
    ["x86_64-windows-gnu", "agentcore-bundle.windows-x86_64.lock.json"],
    ["aarch64-macos", "agentcore-bundle.macos-aarch64.lock.json"],
    ["x86_64-macos", "agentcore-bundle.macos-x86_64.lock.json"],
  ]) {
    assert.ok(bundleVerifier.includes(target));
    assert.ok(bundleVerifier.includes(lock));
    assert.ok(bundlePolicy.includes(target));
    assert.ok(bundlePolicy.includes(lock));
  }
});

test("MetaWork Agent capability shaping stays private to Agent", () => {
  const agentRoot = read("src/agent.zig");
  const sessionApi = read("src/agent/session.zig");
  const capabilities = read("src/agent/capabilities.zig");
  const agentSource = ["src/agent.zig", ...zigFiles("src/agent/")]
    .map(read)
    .join("\n");
  const applicationAndProduct = [
    "src/app.zig",
    ...zigFiles("src/app/"),
    "src/product/control.zig",
  ]
    .map(read)
    .join("\n");

  assert.match(capabilities, /pub const Builtin = enum/);
  assert.match(capabilities, /\.ask_question => false/);
  assert.doesNotMatch(agentRoot, /capabilities|builtins|allowed_tools/);
  assert.doesNotMatch(
    agentSource,
    /\b(?:[Ww]orkbench(?:\b|_)|Product Control|Product layer|Product owners?|Renderer transport|Application Transport)\b/,
  );
  assert.doesNotMatch(sessionApi, /allowed_tools|respondAnswers/);
  assert.doesNotMatch(
    applicationAndProduct,
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
  const completionRoot = read("src/agent/completion.zig");
  for (const path of inlineAgentTests) {
    if (build.includes(`"${path}"`)) continue;
    if (path.startsWith("src/agent/completion/")) {
      const relative = path.slice("src/agent/completion/".length, -4);
      assert.match(
        completionRoot,
        new RegExp(`@import\\("completion/${relative}\\.zig"\\)`),
        `${path} is not aggregated by completion.zig`,
      );
      continue;
    }
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
  assert.doesNotMatch(
    compatSource + read("src/app/window.zig"),
    /system_webview_drag_region|startWindowDrag/,
  );
  const window = read("src/app/window.zig");
  const controlsPath =
    "src/native_sdk_compat/system_webview_window_controls.zig";
  const controlsWindowsPath =
    "src/native_sdk_compat/system_webview_window_controls/windows.zig";
  const resizePath = "src/native_sdk_compat/system_webview_resize.zig";
  const resizeWindowsPath =
    "src/native_sdk_compat/system_webview_resize/windows.zig";
  const startupWindowsPath =
    "src/native_sdk_compat/system_webview_startup_window/windows.zig";
  const instancePath = "src/native_sdk_compat/app_single_instance.zig";
  const instanceWindowsPath =
    "src/native_sdk_compat/app_single_instance/windows.zig";
  const instanceMacosPath =
    "src/native_sdk_compat/app_single_instance/macos.zig";

  for (const seamPath of [controlsPath, resizePath]) {
    assert.deepEqual(
      zigFiles("src/").filter((file) =>
        read(file).includes(`native_sdk_compat/${seamPath.split("/").at(-1)}`),
      ),
      ["src/app/window.zig"],
    );
  }
  assert.deepEqual(
    zigFiles("src/").filter((file) =>
      read(file).includes('@import("metawork_app_single_instance_compat")'),
    ),
    ["src/app/single_instance_coordinator.zig"],
  );
  assert.match(
    read("build.zig"),
    new RegExp(instancePath.replaceAll("/", "\\/")),
  );
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
    [],
  );

  assert.deepEqual(
    externSymbols(read(resizeWindowsPath), ["user32", "kernel32", "comctl32"]),
    [
      "CreateWindowExW",
      "DefSubclassProc",
      "DefWindowProcW",
      "DestroyWindow",
      "GetClientRect",
      "GetCurrentThreadId",
      "GetDpiForWindow",
      "GetModuleHandleW",
      "GetSystemMetricsForDpi",
      "GetWindow",
      "GetWindowLongPtrW",
      "GetWindowThreadProcessId",
      "IsIconic",
      "IsWindow",
      "IsWindowEnabled",
      "IsZoomed",
      "LoadCursorW",
      "PostMessageW",
      "RegisterClassExW",
      "RegisterWindowMessageW",
      "ReleaseCapture",
      "RemoveWindowSubclass",
      "ScreenToClient",
      "SetCursor",
      "SetWindowLongPtrW",
      "SetWindowPos",
      "SetWindowSubclass",
    ].sort(),
  );
  assert.doesNotMatch(
    read(resizeWindowsPath),
    /EnumChildWindows|SetWindowsHookEx|GetForegroundWindow|FindWindow|SetParent/,
  );
  assert.doesNotMatch(
    read("build.zig"),
    /window-chrome-probe|window_chrome_probe/,
  );
  assert.doesNotMatch(read("src/app.zig"), /runWindowChromeProbe/);
  assert.deepEqual(
    externSymbols(read(controlsWindowsPath), [
      "user32",
      "kernel32",
      "comctl32",
    ]),
    ["IsZoomed", "PostMessageW", "ShowWindow"].sort(),
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
    externSymbols(read(instanceWindowsPath), [
      "advapi32",
      "kernel32",
      "user32",
    ]),
    [
      "AllowSetForegroundWindow",
      "CancelSynchronousIo",
      "CloseHandle",
      "ConnectNamedPipe",
      "ConvertSidToStringSidW",
      "ConvertStringSecurityDescriptorToSecurityDescriptorW",
      "CreateFileW",
      "CreateNamedPipeW",
      "DisconnectNamedPipe",
      "FlushFileBuffers",
      "GetCurrentProcess",
      "GetLastError",
      "GetLengthSid",
      "GetNamedPipeServerProcessId",
      "GetTickCount64",
      "GetTokenInformation",
      "LocalFree",
      "MessageBoxW",
      "OpenProcessToken",
      "ReadFile",
      "SetNamedPipeHandleState",
      "Sleep",
      "WriteFile",
    ].sort(),
  );
  assert.deepEqual(
    externSymbols(read(instanceMacosPath), ["c", "CoreFoundation"]),
    [
      "CFRelease",
      "CFStringCreateWithCString",
      "CFUserNotificationDisplayNotice",
      "accept",
      "bind",
      "chmod",
      "close",
      "confstr",
      "connect",
      "getpeereid",
      "getuid",
      "listen",
      "read",
      "setsockopt",
      "shutdown",
      "socket",
      "unlink",
      "write",
    ].sort(),
  );
});

test("Run local timezone has one Application consumer and exact read-only OS symbols", () => {
  const seam = "src/native_sdk_compat/run_local_timezone.zig";
  assert.deepEqual(
    zigFiles("src/").filter((file) =>
      read(file).includes("native_sdk_compat/run_local_timezone.zig"),
    ),
    ["src/app/run_time_context.zig"],
  );
  assert.match(
    read("src/app/run_time_context.zig"),
    /native_sdk\.runtime\.nowMs\(\)/,
  );
  assert.match(read("docs/architecture.md"), /`run_local_timezone`/);
  assert.doesNotMatch(read(seam), /@import\("(?:native_sdk|metawork_agent)"\)/);
  assert.deepEqual(
    externSymbols(read("src/native_sdk_compat/run_local_timezone/macos.zig"), [
      "CoreFoundation",
    ]),
    [
      "CFRelease",
      "CFStringCreateWithCString",
      "CFStringGetCString",
      "CFTimeZoneCopySystem",
      "CFTimeZoneCreateWithName",
      "CFTimeZoneGetName",
      "CFTimeZoneGetSecondsFromGMT",
      "CFTimeZoneResetSystem",
    ].sort(),
  );
  assert.deepEqual(
    externSymbols(
      read("src/native_sdk_compat/run_local_timezone/windows.zig"),
      ["kernel32"],
    ),
    [
      "FileTimeToSystemTime",
      "GetDynamicTimeZoneInformation",
      "SystemTimeToFileTime",
      "SystemTimeToTzSpecificLocalTimeEx",
    ].sort(),
  );
  assert.doesNotMatch(
    read("src/native_sdk_compat/run_local_timezone/macos.zig") +
      read("src/native_sdk_compat/run_local_timezone/windows.zig"),
    /CFTimeZoneSetDefault|SetDynamicTimeZoneInformation|SetTimeZoneInformation|SetLocalTime|GetLocalTime/,
  );
});

test("Application arbitrates single-instance ownership before business owners", () => {
  const app = read("src/app.zig");
  const platform = read("src/app/platform.zig");
  const arbitration = app.indexOf("single_instance_state.init(");
  const frontend = app.indexOf("frontend.resolveAssetRoot(");
  const stores = app.indexOf("stores_state.init(");
  assert.ok(arbitration >= 0);
  assert.ok(frontend > arbitration);
  assert.ok(stores > arbitration);
  assert.match(
    app.slice(arbitration, frontend),
    /if \(disposition == \.secondary\) return;/u,
  );

  const stop = app.match(/fn stop\([\s\S]*?fn event\(/u)?.[0];
  assert.ok(stop, "Application stop lifecycle must remain explicit");
  assert.ok(stop.indexOf("coordinator.stopIngress();") >= 0);
  assert.ok(
    stop.indexOf("coordinator.stopIngress();") <
      stop.indexOf("dispatcher.stopIngress();"),
  );
  assert.match(
    app,
    /\.effects_wake => \{[\s\S]*?coordinator\.drain\(\)[\s\S]*?platform\.activateMainWindow\(\)/u,
  );
  assert.match(
    platform,
    /pub fn activateMainWindow\([\s\S]*?window\.showMainWindow\(runtime_value\);/u,
  );

  const explicitQuit = app.match(
    /if \(result == \.quit_requested\) \{[\s\S]*?\n\s*\}/u,
  )?.[0];
  assert.ok(explicitQuit, "explicit quit lifecycle must remain explicit");
  assert.ok(explicitQuit.indexOf("coordinator.stopIngress();") >= 0);
  assert.ok(explicitQuit.indexOf("platform.requestExplicitQuit();") >= 0);
  assert.ok(
    explicitQuit.indexOf("coordinator.stopIngress();") <
      explicitQuit.indexOf("platform.requestExplicitQuit();"),
  );
  assert.match(
    platform,
    /app_window\.tray_quit_id => \.quit_requested,[\s\S]*?pub fn requestExplicitQuit/u,
  );
});

test("ordinary build and test entries stay isolated from macOS signing", () => {
  const packageJson = JSON.parse(read("package.json"));
  for (const script of ["check", "test", "build:debug", "build:release"]) {
    assert.doesNotMatch(
      packageJson.scripts[script],
      /codesign|package-macos|macos-distribution|scripts\/dev\.mjs/u,
    );
  }
  for (const entry of ["scripts/build.mjs", "scripts/run-tests.mjs"]) {
    assert.doesNotMatch(
      read(entry),
      /codesign|package-macos|macos-distribution|scripts\/dev\.mjs/u,
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
