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
pub const set_skill_enabled = "metawork.skills.setEnabled";
pub const set_skill_source_enabled = "metawork.skills.setSourceEnabled";
pub const recover_skill_source_settings = "metawork.skills.recoverSourceSettings";
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
pub const mcp_apply_configuration = "metawork.mcp.applyConfiguration";
pub const mcp_refresh_catalog = "metawork.mcp.refreshCatalog";
pub const snapshot = "metawork.workbench.snapshot";
pub const snapshot_chunk = "metawork.workbench.snapshot.chunk";
pub const preview_file = "metawork.files.preview";
pub const diff_file = "metawork.files.diff";
pub const choose_attachments = "metawork.attachments.choose";
pub const add_dropped_attachments = "metawork.attachments.addDropped";
pub const begin_attachment_receive = "metawork.attachments.beginReceive";
pub const append_attachment_receive = "metawork.attachments.appendReceive";
pub const finish_attachment_receive = "metawork.attachments.finishReceive";
pub const cancel_attachment_receive = "metawork.attachments.cancelReceive";
pub const release_attachment = "metawork.attachments.release";
pub const account_begin_login = "metawork.account.beginLogin";
pub const account_cancel_operation = "metawork.account.cancelOperation";
pub const account_retry_refresh = "metawork.account.retryRefresh";
pub const models_refresh_catalog = "metawork.models.refreshCatalog";
pub const models_reset_store = "metawork.models.resetStore";
pub const models_select_metask_api_key = "metawork.models.selectMetaskApiKey";
pub const models_configure_metask_selection = "metawork.models.configureMetaskSelection";
pub const models_select_default = "metawork.models.selectDefault";
pub const custom_provider_create = "metawork.models.customProviders.create";
pub const builtin_provider_create = "metawork.models.builtinProviders.create";
pub const builtin_provider_update_base_url = "metawork.models.builtinProviders.updateBaseUrl";
pub const custom_provider_update = "metawork.models.customProviders.update";
pub const custom_provider_replace_credential = "metawork.models.customProviders.replaceCredential";
pub const custom_provider_remove = "metawork.models.customProviders.remove";
pub const custom_model_test = "metawork.models.customModels.test";
pub const custom_model_add = "metawork.models.customModels.add";
pub const custom_model_replace = "metawork.models.customModels.replace";
pub const custom_model_remove = "metawork.models.customModels.remove";
pub const account_logout = "metawork.account.logout";
pub const set_default_permission_profile = "metawork.permissions.setDefaultProfile";
pub const create_task = "metawork.tasks.create";
pub const run = "metawork.tasks.run";
pub const select_task_model = "metawork.tasks.selectModel";
pub const restore_task = "metawork.tasks.restore";
pub const compact = "metawork.tasks.compact";
pub const cancel_compact = "metawork.tasks.cancelCompact";
pub const refresh_task_skill_catalog = "metawork.tasks.refreshSkillCatalog";
pub const cancel = "metawork.tasks.cancel";
pub const respond_ui = "metawork.tasks.respondUi";
pub const rename_task = "metawork.tasks.rename";
pub const archive_task = "metawork.tasks.archive";
pub const delete_task = "metawork.tasks.delete";
pub const recover_task_history = "metawork.tasks.recoverHistory";
pub const create_scheduled_task = "metawork.scheduledTasks.create";
pub const update_scheduled_task = "metawork.scheduledTasks.update";
pub const set_scheduled_task_enabled = "metawork.scheduledTasks.setEnabled";
pub const run_scheduled_task_now = "metawork.scheduledTasks.runNow";
pub const delete_scheduled_task = "metawork.scheduledTasks.delete";
pub const recover_scheduled_task_store = "metawork.scheduledTasks.recoverStore";

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
    set_skill_enabled,
    set_skill_source_enabled,
    recover_skill_source_settings,
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
    mcp_apply_configuration,
    mcp_refresh_catalog,
    snapshot,
    snapshot_chunk,
    preview_file,
    diff_file,
    choose_attachments,
    add_dropped_attachments,
    begin_attachment_receive,
    append_attachment_receive,
    finish_attachment_receive,
    cancel_attachment_receive,
    release_attachment,
    account_begin_login,
    account_cancel_operation,
    account_retry_refresh,
    models_refresh_catalog,
    models_reset_store,
    models_select_metask_api_key,
    models_configure_metask_selection,
    models_select_default,
    custom_provider_create,
    builtin_provider_create,
    builtin_provider_update_base_url,
    custom_provider_update,
    custom_provider_replace_credential,
    custom_provider_remove,
    custom_model_test,
    custom_model_add,
    custom_model_replace,
    custom_model_remove,
    account_logout,
    set_default_permission_profile,
    create_task,
    run,
    select_task_model,
    restore_task,
    compact,
    cancel_compact,
    refresh_task_skill_catalog,
    cancel,
    respond_ui,
    rename_task,
    archive_task,
    delete_task,
    recover_task_history,
    create_scheduled_task,
    update_scheduled_task,
    set_scheduled_task_enabled,
    run_scheduled_task_now,
    delete_scheduled_task,
    recover_scheduled_task_store,
};
