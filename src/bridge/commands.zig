//! Exact Renderer Bridge command identities.

pub const ping = "metawork.smoke.ping";
pub const ping_ack = "metawork.smoke.eventAck";
pub const connect = "metawork.events.connect";
pub const disconnect = "metawork.events.disconnect";
pub const fixture_ack = "metawork.events.ack";
pub const fixture_fetch = "metawork.events.fetch";
pub const fixture_emit = "metawork.gate5.emitFixture";
pub const choose_workspace = "metawork.workspace.choose";
pub const snapshot = "metawork.workbench.snapshot";
pub const snapshot_chunk = "metawork.workbench.snapshot.chunk";
pub const create_session = "metawork.sessions.create";
pub const run = "metawork.sessions.run";
pub const cancel = "metawork.sessions.cancel";
pub const respond_ui = "metawork.sessions.respondUi";
pub const close_session = "metawork.sessions.close";
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
    create_session,
    run,
    cancel,
    respond_ui,
    close_session,
    rename_task,
    archive_task,
    delete_task,
};

pub const automation = product ++ [_][]const u8{ fixture_ack, fixture_fetch, fixture_emit };
