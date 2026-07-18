//! Minimal Renderer Bridge transport surface. Product truth remains in Workbench.

const delivery_impl = @import("bridge/delivery.zig");
const commands_impl = @import("bridge/commands.zig");
const handlers_impl = @import("bridge/handlers.zig");
const policy_impl = @import("bridge/policy.zig");
const revision_delivery_impl = @import("bridge/revision_delivery.zig");
const snapshot_delivery_impl = @import("bridge/snapshot_delivery.zig");
const workspace_grant_impl = @import("bridge/workspace_grant.zig");

pub const delivery = struct {
    pub const Limits = delivery_impl.Limits;
    pub const Error = delivery_impl.Error;
    pub const InputEvent = delivery_impl.InputEvent;
    pub const OwnedBatch = delivery_impl.OwnedBatch;
    pub const ExpiredRoute = delivery_impl.ExpiredRoute;
    pub const RouteIdentity = delivery_impl.RouteIdentity;
    pub const Stats = delivery_impl.Stats;
    pub const Delivery = delivery_impl.Delivery;
};

pub const commands = struct {
    pub const ping = commands_impl.ping;
    pub const ping_ack = commands_impl.ping_ack;
    pub const connect = commands_impl.connect;
    pub const disconnect = commands_impl.disconnect;
    pub const fixture_ack = commands_impl.fixture_ack;
    pub const fixture_fetch = commands_impl.fixture_fetch;
    pub const fixture_emit = commands_impl.fixture_emit;
    pub const choose_workspace = commands_impl.choose_workspace;
    pub const snapshot = commands_impl.snapshot;
    pub const snapshot_chunk = commands_impl.snapshot_chunk;
    pub const create_task = commands_impl.create_task;
    pub const run = commands_impl.run;
    pub const cancel = commands_impl.cancel;
    pub const respond_ui = commands_impl.respond_ui;
    pub const close_task = commands_impl.close_task;
    pub const rename_task = commands_impl.rename_task;
    pub const archive_task = commands_impl.archive_task;
    pub const delete_task = commands_impl.delete_task;
};

pub const handlers = struct {
    pub const EventDisconnect = handlers_impl.EventDisconnect;
    pub const EventAck = handlers_impl.EventAck;
    pub const EventFetch = handlers_impl.EventFetch;
    pub const WorkbenchSnapshotChunk = handlers_impl.WorkbenchSnapshotChunk;
    pub const TaskCreate = handlers_impl.TaskCreate;
    pub const TaskRun = handlers_impl.TaskRun;
    pub const TaskIdentity = handlers_impl.TaskIdentity;
    pub const TaskClose = handlers_impl.TaskClose;
    pub const TaskRename = handlers_impl.TaskRename;
    pub const TaskArchive = handlers_impl.TaskArchive;
    pub const TaskDelete = handlers_impl.TaskDelete;
    pub const UiResponseRequest = handlers_impl.UiResponseRequest;
    pub const PermissionChoice = handlers_impl.PermissionChoice;
    pub const parsePayload = handlers_impl.parsePayload;
    pub const parsePayloadWithLimit = handlers_impl.parsePayloadWithLimit;
    pub const parseWireId = handlers_impl.parseWireId;
    pub const acknowledgementSequence = handlers_impl.acknowledgementSequence;
    pub const permissionChoice = handlers_impl.permissionChoice;
};

pub const policy = struct {
    pub const Mode = policy_impl.Mode;
    pub const window_permissions = policy_impl.window_permissions;
    pub const product = policy_impl.product;
    pub const builtin = policy_impl.builtin;
    pub const origins = policy_impl.origins;
};

pub const revision_delivery = struct {
    pub const retry_timer_id = revision_delivery_impl.retry_timer_id;
    pub const retry_interval_ns = revision_delivery_impl.retry_interval_ns;
    pub const event_name = revision_delivery_impl.event_name;
    pub const State = revision_delivery_impl.State;
};

pub const snapshot_delivery = struct {
    pub const max_bytes = snapshot_delivery_impl.max_bytes;
    pub const chunk_bytes = snapshot_delivery_impl.chunk_bytes;
    pub const Error = snapshot_delivery_impl.Error;
    pub const State = snapshot_delivery_impl.State;
};

pub const workspace_grant = struct {
    pub const max_path_bytes = workspace_grant_impl.max_path_bytes;
    pub const State = workspace_grant_impl.State;
};
