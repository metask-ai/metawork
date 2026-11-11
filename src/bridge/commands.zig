//! Exact Renderer Bridge command identities.

pub const contract_id = "metawork.renderer-bridge";
pub const contract_revision: u32 = 1;

pub const ping = "metawork.smoke.ping";
pub const ping_ack = "metawork.smoke.eventAck";
pub const connect = "metawork.events.connect";
pub const disconnect = "metawork.events.disconnect";
pub const window_chrome_connect = "metawork.host.windowChrome.connect";
pub const window_chrome_refresh = "metawork.host.windowChrome.refresh";
pub const window_chrome_control = "metawork.host.windowChrome.control";
pub const window_chrome_disconnect = "metawork.host.windowChrome.disconnect";
pub const open_external_link = "metawork.host.links.openExternal";
pub const updates_check = "metawork.updates.check";
pub const updates_open_download = "metawork.updates.openDownload";
pub const updates_open_website = "metawork.updates.openWebsite";
pub const choose_workspace = "metawork.workspaces.choose";
pub const open_workspace = "metawork.workspaces.open";
pub const remove_workspace = "metawork.workspaces.remove";
pub const remove_project = "metawork.workspaces.removeProject";
pub const choose_automatic_workspace_root = "metawork.workspaces.chooseAutomaticRoot";
pub const reset_automatic_workspace_root = "metawork.workspaces.resetAutomaticRoot";
pub const retry_automatic_workspace_root = "metawork.workspaces.retryAutomaticRoot";
pub const refresh_workspace_skill_catalog = "metawork.workspaces.refreshSkillCatalog";
pub const refresh_skill_catalog = "metawork.skills.refreshCatalog";
pub const set_skill_enabled = "metawork.skills.setEnabled";
pub const choose_skill_import = "metawork.skills.chooseImport";
pub const prepare_skill_import = "metawork.skills.prepareImport";
pub const install_skill = "metawork.skills.install";
pub const reimport_skill = "metawork.skills.reimport";
pub const uninstall_skill = "metawork.skills.uninstall";
pub const retry_skill = "metawork.skills.retry";
pub const export_skill = "metawork.skills.export";
pub const skill_detail = "metawork.skills.detail";
pub const mcp_cancel_installation = "metawork.mcp.cancelInstallation";
pub const mcp_create_stdio_server = "metawork.mcp.createStdioServer";
pub const mcp_create_http_server = "metawork.mcp.createHttpServer";
pub const mcp_probe_http_draft = "metawork.mcp.probeHttpDraft";
pub const mcp_verify_add_http_draft = "metawork.mcp.verifyAndAddHttpDraft";
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
pub const output_action = "metawork.outputs.action";
pub const output_action_cancel = "metawork.outputs.cancel";
pub const preview_file = "metawork.files.preview";
pub const list_directory = "metawork.files.listDirectory";
pub const preview_workspace_file = "metawork.files.previewWorkspace";
pub const read_preview_image = "metawork.files.preview.readImageChunk";
pub const read_preview_video = "metawork.files.preview.readVideoChunk";
pub const release_preview = "metawork.files.preview.release";
pub const diff_file = "metawork.files.diff";
pub const begin_attachment_add = "metawork.attachments.beginAdd";
pub const append_attachment_add = "metawork.attachments.appendAdd";
pub const finish_attachment_add = "metawork.attachments.finishAdd";
pub const cancel_attachment_add = "metawork.attachments.cancelAdd";
pub const choose_attachments = "metawork.attachments.choose";
pub const add_dropped_attachments = "metawork.attachments.addDropped";
pub const begin_attachment_receive = "metawork.attachments.beginReceive";
pub const append_attachment_receive = "metawork.attachments.appendReceive";
pub const finish_attachment_receive = "metawork.attachments.finishReceive";
pub const cancel_attachment_receive = "metawork.attachments.cancelReceive";
pub const release_attachment = "metawork.attachments.release";
pub const preview_attachment = "metawork.attachments.preview";
pub const preview_run_input_attachment = "metawork.attachments.previewRunInput";
pub const account_begin_login = "metawork.account.beginLogin";
pub const account_cancel_operation = "metawork.account.cancelOperation";
pub const account_retry_refresh = "metawork.account.retryRefresh";
pub const account_refresh_summary = "metawork.account.refreshSummary";
pub const account_open_recharge = "metawork.account.openRecharge";
pub const models_refresh_catalog = "metawork.models.refreshCatalog";
pub const models_reset_store = "metawork.models.resetStore";
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
pub const create_task = "metawork.tasks.create";
pub const run = "metawork.tasks.run";
pub const send_input = "metawork.tasks.sendInput";
pub const stop = "metawork.tasks.stop";
pub const set_approval_mode = "metawork.tasks.setApprovalMode";
pub const select_task_model = "metawork.tasks.selectModel";
pub const restore_task = "metawork.tasks.restore";
pub const compact = "metawork.tasks.compact";
pub const cancel_compact = "metawork.tasks.cancelCompact";
pub const refresh_task_skill_catalog = "metawork.tasks.refreshSkillCatalog";
pub const cancel = "metawork.tasks.cancel";
pub const respond_ui = "metawork.tasks.respondUi";
pub const rename_task = "metawork.tasks.rename";
pub const archive_task = "metawork.tasks.archive";
pub const mark_task_completion_seen = "metawork.tasks.markCompletionSeen";
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
    window_chrome_refresh,
    window_chrome_control,
    window_chrome_disconnect,
    open_external_link,
    updates_check,
    updates_open_download,
    updates_open_website,
    choose_workspace,
    open_workspace,
    remove_workspace,
    remove_project,
    choose_automatic_workspace_root,
    reset_automatic_workspace_root,
    retry_automatic_workspace_root,
    refresh_workspace_skill_catalog,
    refresh_skill_catalog,
    set_skill_enabled,
    choose_skill_import,
    prepare_skill_import,
    install_skill,
    reimport_skill,
    uninstall_skill,
    retry_skill,
    export_skill,
    skill_detail,
    mcp_create_stdio_server,
    mcp_create_http_server,
    mcp_probe_http_draft,
    mcp_verify_add_http_draft,
    mcp_cancel_installation,
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
    output_action,
    output_action_cancel,
    preview_file,
    list_directory,
    preview_workspace_file,
    read_preview_image,
    read_preview_video,
    release_preview,
    diff_file,
    begin_attachment_add,
    append_attachment_add,
    finish_attachment_add,
    cancel_attachment_add,
    choose_attachments,
    add_dropped_attachments,
    begin_attachment_receive,
    append_attachment_receive,
    finish_attachment_receive,
    cancel_attachment_receive,
    release_attachment,
    preview_attachment,
    preview_run_input_attachment,
    account_begin_login,
    account_cancel_operation,
    account_retry_refresh,
    account_refresh_summary,
    account_open_recharge,
    models_refresh_catalog,
    models_reset_store,
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
    create_task,
    run,
    send_input,
    stop,
    set_approval_mode,
    select_task_model,
    restore_task,
    compact,
    cancel_compact,
    refresh_task_skill_catalog,
    cancel,
    respond_ui,
    rename_task,
    archive_task,
    mark_task_completion_seen,
    delete_task,
    recover_task_history,
    create_scheduled_task,
    update_scheduled_task,
    set_scheduled_task_enabled,
    run_scheduled_task_now,
    delete_scheduled_task,
    recover_scheduled_task_store,
};
