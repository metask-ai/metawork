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
    "src/product/skill.zig",
    "src/product/task.zig",
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
  assert.equal(existsSync(new URL("src/product/control/runtime.zig", root)), true);
  assert.equal(existsSync(new URL("src/product/control/executor.zig", root)), true);
  assert.equal(existsSync(new URL("src/product/control/file_preview.zig", root)), true);
  assert.equal(existsSync(new URL("src/product/control/automatic_workspace.zig", root)), true);
  assert.equal(existsSync(new URL("src/product/control/schedule.zig", root)), true);
  assert.equal(existsSync(new URL("src/product/control/schedule/persistence.zig", root)), true);
  assert.equal(existsSync(new URL("tests/product/control_lifecycle_test.zig", root)), true);
  assert.equal(existsSync(new URL("src/workbench.zig", root)), false);
  assert.equal(existsSync(new URL("src/workbench/projection.zig", root)), false);
  assert.equal(existsSync(new URL("src/workbench/executor.zig", root)), false);
  assert.equal(existsSync(new URL("src/workbench/file_preview.zig", root)), false);
  assert.equal(existsSync(new URL("src/workbench/scheduled_tasks.zig", root)), false);
  assert.equal(existsSync(new URL("src/workbench/scheduled_task_persistence.zig", root)), false);
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
  assert.match(buildSource, /src\/product\/control\/schedule\.zig/);
  assert.match(buildSource, /src\/product\/control\/schedule\/persistence\.zig/);
  assert.match(buildSource, /src\/product\/control\/automatic_workspace\.zig/);
  assert.doesNotMatch(buildSource, /src\/account(?:\.zig|\/)/);
  assert.doesNotMatch(buildSource, /src\/workbench\/mcp_configuration\.zig/);
  assert.doesNotMatch(buildSource, /src\/workbench\/catalog_snapshot\.zig/);
  assert.doesNotMatch(buildSource, /workbench_scheduled_tasks|workbench_scheduled_task_persistence/);
  assert.doesNotMatch(buildSource, /workbench_automatic_workspace_allocator|src\/workbench\/automatic_workspace_allocator\.zig/);
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
  const executor = read("src/product/control/executor.zig");
  const filePreview = read("src/product/control/file_preview.zig");
  const source = [
    ...zigFiles("src/"),
    ...zigFiles("tests/"),
  ]
    .map(read)
    .join("\n");

  assert.match(build, /src\/product\/control\.zig/);
  assert.match(build, /src\/product\/control\/runtime\.zig/);
  assert.match(build, /src\/product\/control\/executor\.zig/);
  assert.match(build, /src\/product\/control\/file_preview\.zig/);
  assert.match(build, /src\/product\/control\/schedule\.zig/);
  assert.match(build, /src\/product\/control\/schedule\/persistence\.zig/);
  assert.match(build, /src\/product\/control\/automatic_workspace\.zig/);
  assert.match(build, /metawork_product_control/);
  assert.match(build, /product_control_executor/);
  assert.match(build, /product_control_file_preview/);
  assert.match(build, /product_control_schedule/);
  assert.match(build, /product_control_schedule_persistence/);
  assert.match(build, /product_control_automatic_workspace/);
  assert.match(control, /pub const Runtime = runtime_impl\.Runtime/);
  assert.match(runtime, /pub const Runtime = struct/);
  assert.doesNotMatch(runtime, /\bworkbench(?:\b|_)/);
  assert.doesNotMatch(build, /metawork_workbench|workbench_projection/);
  assert.doesNotMatch(source, /@import\("metawork_workbench"\)|@import\("workbench_projection"\)/);
  assert.doesNotMatch(source, /pub const Workbench\s*=|pub const Workbench = struct/);
  assert.doesNotMatch(build, /workbench_contract_fixture/);
  assert.doesNotMatch(build, /src\/workbench\/(?:executor|file_preview)\.zig|workbench_executor/);
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

test("Product Control Schedule owns its state and persistence leaves", () => {
  const build = read("build.zig");
  const control = read("src/product/control.zig");
  const runtime = read("src/product/control/runtime.zig");
  const schedule = read("src/product/control/schedule.zig");
  const persistence = read("src/product/control/schedule/persistence.zig");
  const stores = read("src/app/stores.zig");

  assert.match(runtime, /@import\("product_control_schedule"\)/);
  assert.match(runtime, /@import\("product_control_schedule_persistence"\)/);
  assert.match(persistence, /@import\("product_control_schedule"\)/);
  assert.match(stores, /@import\("product_control_schedule_persistence"\)/);
  assert.doesNotMatch(control, /ScheduledTaskFileStore|scheduled_task_store_max_bytes|product_control_schedule_persistence/);
  assert.doesNotMatch(`${schedule}\n${persistence}`, /@import\("(?:metawork_app|metawork_bridge|metawork_agent|metawork_product_task|metawork_product_skill|metawork_product_mcp)"\)|std\.Thread/);
  assert.doesNotMatch(build, /workbench_scheduled_tasks|workbench_scheduled_task_persistence|metawork-scheduled-task-persistence/);
});

test("Application coordinators consume scoped Product Control capabilities", () => {
  const build = read("build.zig");
  const ports = read("src/product/control/ports.zig");
  const projection = read("src/product/control/runtime.zig");
  const accountCoordinator = read("src/app/account_coordinator.zig");
  const agentEvents = read("src/app/agent_event_coordinator.zig");
  const mcpManagement = read("src/app/mcp_management_coordinator.zig");
  const mcpOauth = read("src/app/mcp_oauth_coordinator.zig");
  const window = read("src/app/window.zig");
  const platform = read("src/app/platform.zig");

  assert.match(build, /src\/product\/control\/ports\.zig/);
  assert.match(build, /metawork_product_control_ports/);
  for (const name of [
    "ExecutionHandoff",
    "AgentEventConsumer",
    "McpManagementPort",
    "McpOauthPort",
    "ScheduleHost",
  ]) {
    assert.match(ports, new RegExp(`pub const ${name} = struct`));
  }
  assert.match(ports, /context: \*anyopaque/);
  assert.doesNotMatch(ports, /Workbench|product_control\.Runtime|rawRuntime|rawOwner/);
  assert.match(projection, /pub fn executionHandoff/);
  assert.match(projection, /pub fn agentEventConsumer/);
  assert.match(projection, /pub fn mcpManagementPort/);
  assert.match(projection, /pub fn mcpOauthPort/);
  assert.match(projection, /pub fn scheduleHost/);

  for (const source of [accountCoordinator, mcpManagement, mcpOauth]) {
    const coordinator = source.match(
      /pub const Coordinator = struct \{([\s\S]*?)\n    pub fn init/,
    )?.[1];
    assert.ok(coordinator, "coordinator state must be inspectable");
    assert.doesNotMatch(coordinator, /Workbench|workbench_owner|\*workbench/);
  }
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
  assert.doesNotMatch(recoveryJob, /metawork_product_skill|product_skill_catalog/);
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
  assert.match(runtime, /pub fn reconcileEnablementNoFail/);
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
  assert.match(productTask, /pub const history = @import\("product_task_persistence"\)/);
  assert.match(productTask, /pub const checkpoint_store = @import\("product_task_checkpoint_store"\)/);
  assert.match(productTask, /pub const testing = if \(builtin\.is_test\) struct/);
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
  assert.match(taskState, /@import\("metawork_agent"\)/);
  assert.doesNotMatch(
    taskState,
    /Workbench|product_control_executor|std\.Thread|@import\("(?:metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  assert.doesNotMatch(projection, /const RunRecord = task_model\.RunRecord;/);
  assert.doesNotMatch(projection, /const CompactRecord = task_model\.CompactRecord;/);
  assert.doesNotMatch(projection, /const RunRecord = struct/);
  assert.doesNotMatch(projection, /const CompactRecord = struct/);
  assert.doesNotMatch(build, /projection\.addImport\("product_task_/);
  assert.match(projection, /const task_testing = product_task\.testing;/);
  assert.match(projection, /if \(builtin\.is_test\) task_testing\.state_module else struct \{\}/);
  assert.match(taskExecution, /pub const RunJob = struct/);
  assert.match(taskExecution, /pub const CompactJob = struct/);
  assert.match(taskExecution, /pub fn executeRun\(/);
  assert.match(taskExecution, /pub fn cancelRun\(/);
  assert.match(taskExecution, /pub fn executeCompact\(/);
  assert.match(taskExecution, /pub fn cancelCompact\(/);
  assert.match(taskExecution, /title_execution: \?execution_binding\.OwnedTaskExecution/);
  assert.match(taskExecution, /if \(self\.title_execution\) \|\*execution\| execution\.deinit\(\)/);
  const automaticTitle = taskState.match(
    /pub const AutomaticTitle = struct \{[\s\S]*?\n\};/,
  )?.[0];
  assert.ok(automaticTitle, "Task state must own AutomaticTitle facts");
  assert.doesNotMatch(automaticTitle, /OwnedTaskExecution|credential|secret|execution:/);
  assert.doesNotMatch(
    taskExecution,
    /Workbench|TaskView|\*task_runtime\.|product_control_executor|@import\("(?:metawork_product_control|metawork_app|metawork_bridge|native_sdk|metask_agentcore)"\)/,
  );
  assert.doesNotMatch(
    taskExecution,
    /\b(?:workbench|task|runtime):\s*\*/,
  );
  assert.match(taskRuntime, /task_execution\.executeRun,/);
  assert.match(taskRuntime, /task_execution\.cancelRun,/);
  assert.match(taskRuntime, /task_execution\.executeCompact,/);
  assert.match(taskRuntime, /task_execution\.cancelCompact,/);
  assert.doesNotMatch(
    projection,
    /fn (?:execute|cancel)(?:Run|Compact)Job\(/,
  );
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
  assert.doesNotMatch(projection, /task_persistence\.(?:restoreTask|projectTask)\(/);
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
  assert.match(taskAttachment, /const worker_binding = value\.binding\.take\(\);/);
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
  assert.match(taskRuntime, /durable_mutation_state: DurableMutationState/);
  assert.match(taskRuntime, /pub fn observeDurableCommit\(/);
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
  assert.match(productMcp, /pub const contract = @import\("product_mcp_configuration"\)/);
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
  assert.doesNotMatch(state, /McpRefreshJob|product_control_executor|std\.Thread/);
  for (const field of [
    "refresh_request_generation",
    "refresh_pending",
    "refresh_pending_blocks_admission",
    "refresh_deadline_ms",
  ]) {
    assert.match(state, new RegExp(`\\b${field}\\b`));
  }
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
      new RegExp(
        `product_mcp\\.addImport\\("product_mcp_${internal}",`,
      ),
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
  assert.match(workbenchProjection, /const mcp_configuration = product_mcp\.contract/);
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
    "writeSecretCapturePrompt",
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
  for (const name of ["rearmMcpRefreshTimerNoFail", "commitMcpRefreshJobNoFail"]) {
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
  assert.doesNotMatch(workbenchProjection, /mcp_refresh_job: \?\*McpRefreshJob/);
  assert.doesNotMatch(workbenchProjection, /^\s*mcp_refresh_timer: McpRefreshTimer,/m);
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
    "metawork_product_control",
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
    ["x86_64-windows-gnu", "agentcore-bundle.windows.lock.json"],
    ["aarch64-macos", "agentcore-bundle.macos.lock.json"],
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
