//! Exact Renderer Bridge command identities.

pub const contract_id = "metawork.renderer-bridge";
pub const contract_revision: u32 = 1;

pub const ping = "metawork.smoke.ping";
pub const ping_ack = "metawork.smoke.eventAck";
pub const connect = "metawork.events.connect";
pub const disconnect = "metawork.events.disconnect";
pub const window_chrome_connect = "metawork.host.windowChrome.connect";
pub const window_chrome_sync = "metawork.host.windowChrome.sync";
pub const window_chrome_begin_drag = "metawork.host.windowChrome.beginDrag";
pub const window_chrome_control = "metawork.host.windowChrome.control";
pub const window_chrome_disconnect = "metawork.host.windowChrome.disconnect";
pub const choose_workspace = "metawork.workspaces.choose";
pub const refresh_workspace_skill_catalog = "metawork.workspaces.refreshSkillCatalog";
pub const refresh_skill_catalog = "metawork.skills.refreshCatalog";
pub const choose_skill_import = "metawork.skills.chooseImport";
pub const install_skill = "metawork.skills.install";
pub const reimport_skill = "metawork.skills.reimport";
pub const uninstall_skill = "metawork.skills.uninstall";
pub const retry_skill = "metawork.skills.retry";
pub const export_skill = "metawork.skills.export";
pub const skill_detail = "metawork.skills.detail";
pub const mcp_create_stdio_server = "metawork.mcp.createStdioServer";
pub const mcp_create_http_server = "metawork.mcp.createHttpServer";
pub const mcp_update_stdio_connection = "metawork.mcp.updateStdioConnection";
pub const mcp_update_http_connection = "metawork.mcp.updateHttpConnection";
pub const mcp_rename_server = "metawork.mcp.renameServer";
pub const mcp_approve_connection = "metawork.mcp.approveConnection";
pub const mcp_capture_secret = "metawork.mcp.captureSecret";
pub const mcp_authorize_oauth = "metawork.mcp.authorizeOAuth";
pub const mcp_cancel_authorization = "metawork.mcp.cancelAuthorization";
pub const mcp_set_server_enabled = "metawork.mcp.setServerEnabled";
pub const mcp_set_allowed_tools = "metawork.mcp.setAllowedTools";
pub const mcp_remove_server = "metawork.mcp.removeServer";
pub const mcp_test_connection = "metawork.mcp.testConnection";
pub const mcp_refresh_catalog = "metawork.mcp.refreshCatalog";
pub const snapshot = "metawork.workbench.snapshot";
pub const snapshot_chunk = "metawork.workbench.snapshot.chunk";
pub const preview_file = "metawork.files.preview";
pub const account_begin_login = "metawork.account.beginLogin";
pub const account_cancel_operation = "metawork.account.cancelOperation";
pub const account_refresh_catalog = "metawork.account.refreshCatalog";
pub const account_select_api_key = "metawork.account.selectApiKey";
pub const account_select_model = "metawork.account.selectModel";
pub const account_logout = "metawork.account.logout";
pub const create_task = "metawork.tasks.create";
pub const run = "metawork.tasks.run";
pub const select_task_model = "metawork.tasks.selectModel";
pub const restore_task = "metawork.tasks.restore";
pub const compact = "metawork.tasks.compact";
pub const cancel_compact = "metawork.tasks.cancelCompact";
pub const refresh_task_skill_catalog = "metawork.tasks.refreshSkillCatalog";
pub const cancel = "metawork.tasks.cancel";
pub const respond_ui = "metawork.tasks.respondUi";
pub const close_task = "metawork.tasks.close";
pub const rename_task = "metawork.tasks.rename";
pub const archive_task = "metawork.tasks.archive";
pub const delete_task = "metawork.tasks.delete";
pub const create_scheduled_task = "metawork.scheduledTasks.create";
pub const update_scheduled_task = "metawork.scheduledTasks.update";
pub const set_scheduled_task_enabled = "metawork.scheduledTasks.setEnabled";
pub const run_scheduled_task_now = "metawork.scheduledTasks.runNow";
pub const delete_scheduled_task = "metawork.scheduledTasks.delete";

pub const product = [_][]const u8{
    ping,
    ping_ack,
    connect,
    disconnect,
    window_chrome_connect,
    window_chrome_sync,
    window_chrome_begin_drag,
    window_chrome_control,
    window_chrome_disconnect,
    choose_workspace,
    refresh_workspace_skill_catalog,
    refresh_skill_catalog,
    choose_skill_import,
    install_skill,
    reimport_skill,
    uninstall_skill,
    retry_skill,
    export_skill,
    skill_detail,
    mcp_create_stdio_server,
    mcp_create_http_server,
    mcp_update_stdio_connection,
    mcp_update_http_connection,
    mcp_rename_server,
    mcp_approve_connection,
    mcp_capture_secret,
    mcp_authorize_oauth,
    mcp_cancel_authorization,
    mcp_set_server_enabled,
    mcp_set_allowed_tools,
    mcp_remove_server,
    mcp_test_connection,
    mcp_refresh_catalog,
    snapshot,
    snapshot_chunk,
    preview_file,
    account_begin_login,
    account_cancel_operation,
    account_refresh_catalog,
    account_select_api_key,
    account_select_model,
    account_logout,
    create_task,
    run,
    select_task_model,
    restore_task,
    compact,
    cancel_compact,
    refresh_task_skill_catalog,
    cancel,
    respond_ui,
    close_task,
    rename_task,
    archive_task,
    delete_task,
    create_scheduled_task,
    update_scheduled_task,
    set_scheduled_task_enabled,
    run_scheduled_task_now,
    delete_scheduled_task,
};
