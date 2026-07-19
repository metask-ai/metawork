//! Exact Renderer Bridge command identities.

pub const ping = "metawork.smoke.ping";
pub const ping_ack = "metawork.smoke.eventAck";
pub const connect = "metawork.events.connect";
pub const disconnect = "metawork.events.disconnect";
pub const choose_workspace = "metawork.workspace.choose";
pub const snapshot = "metawork.workbench.snapshot";
pub const snapshot_chunk = "metawork.workbench.snapshot.chunk";
pub const create_task = "metawork.tasks.create";
pub const run = "metawork.tasks.run";
pub const cancel = "metawork.tasks.cancel";
pub const respond_ui = "metawork.tasks.respondUi";
pub const close_task = "metawork.tasks.close";
pub const rename_task = "metawork.tasks.rename";
pub const archive_task = "metawork.tasks.archive";
pub const delete_task = "metawork.tasks.delete";

pub const product = [_][]const u8{
    ping,
    ping_ack,
    connect,
    disconnect,
    choose_workspace,
    snapshot,
    snapshot_chunk,
    create_task,
    run,
    cancel,
    respond_ui,
    close_task,
    rename_task,
    archive_task,
    delete_task,
};
