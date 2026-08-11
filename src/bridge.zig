//! Minimal Renderer Bridge transport surface. Product truth remains in Workbench.

const commands_impl = @import("bridge/commands.zig");
const callback_gate_impl = @import("bridge/callback_gate.zig");
const handlers_impl = @import("bridge/handlers.zig");
const policy_impl = @import("bridge/policy.zig");
const product_delivery_impl = @import("bridge/product_delivery.zig");
const revision_delivery_impl = @import("bridge/revision_delivery.zig");
const snapshot_delivery_impl = @import("bridge/snapshot_delivery.zig");
const workspace_grant_impl = @import("bridge/workspace_grant.zig");
const dispatcher_impl = @import("bridge/dispatcher.zig");

pub const CallbackGate = callback_gate_impl.State;
pub const Dispatcher = dispatcher_impl.Dispatcher;
pub const DispatcherPlatform = dispatcher_impl.Platform;
pub const DispatcherAutomationAuthority = dispatcher_impl.AutomationAuthority;
pub const McpManagementHost = dispatcher_impl.McpManagementHost;
pub const McpHostOutcome = dispatcher_impl.McpHostOutcome;
pub const McpAuthorizationStartOutcome = dispatcher_impl.McpAuthorizationStartOutcome;
pub const McpConnectionTestStartOutcome = dispatcher_impl.McpConnectionTestStartOutcome;
pub const McpSecretSlot = dispatcher_impl.McpSecretSlot;
pub const WindowChromeRegion = dispatcher_impl.WindowChromeRegion;
pub const WindowChromePlatformEnvironment = dispatcher_impl.WindowChromePlatformEnvironment;
pub const WindowChromeControlAction = dispatcher_impl.WindowChromeControlAction;

pub const ProductDelivery = product_delivery_impl.Delivery;
pub const ProductDeliveryTransport = product_delivery_impl.Transport;
pub const SnapshotWriter = product_delivery_impl.SnapshotWriter;
pub const ProductRevisionResult = product_delivery_impl.RevisionResult;
pub const product_retry_timer_id = product_delivery_impl.retry_timer_id;
pub const product_event_name = product_delivery_impl.event_name;
pub const snapshot_max_bytes = product_delivery_impl.snapshot_max_bytes;
pub const snapshot_chunk_bytes = product_delivery_impl.snapshot_chunk_bytes;

pub const commands = struct {
    pub const contract_id = commands_impl.contract_id;
    pub const contract_revision = commands_impl.contract_revision;
    pub const ping = commands_impl.ping;
    pub const ping_ack = commands_impl.ping_ack;
    pub const connect = commands_impl.connect;
    pub const disconnect = commands_impl.disconnect;
    pub const window_chrome_connect = commands_impl.window_chrome_connect;
    pub const window_chrome_sync = commands_impl.window_chrome_sync;
    pub const window_chrome_begin_drag = commands_impl.window_chrome_begin_drag;
    pub const window_chrome_control = commands_impl.window_chrome_control;
    pub const window_chrome_disconnect = commands_impl.window_chrome_disconnect;
    pub const choose_workspace = commands_impl.choose_workspace;
    pub const select_workspace = commands_impl.select_workspace;
    pub const remove_workspace = commands_impl.remove_workspace;
    pub const snapshot = commands_impl.snapshot;
    pub const snapshot_chunk = commands_impl.snapshot_chunk;
    pub const account_begin_login = commands_impl.account_begin_login;
    pub const account_cancel_operation = commands_impl.account_cancel_operation;
    pub const account_refresh_catalog = commands_impl.account_refresh_catalog;
    pub const account_select_api_key = commands_impl.account_select_api_key;
    pub const account_select_model = commands_impl.account_select_model;
    pub const account_logout = commands_impl.account_logout;
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
    pub const RendererBridgeConnect = handlers_impl.RendererBridgeConnect;
    pub const EventDisconnect = handlers_impl.EventDisconnect;
    pub const WindowDragStart = handlers_impl.WindowDragStart;
    pub const WorkbenchSnapshotChunk = handlers_impl.WorkbenchSnapshotChunk;
    pub const AccountSelection = handlers_impl.AccountSelection;
    pub const WorkspaceIdentity = handlers_impl.WorkspaceIdentity;
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
    pub const product_command_count = policy_impl.product_command_count;
    pub const builtin_command_count = policy_impl.builtin_command_count;
    pub const product = policy_impl.product;
    pub const builtin = policy_impl.builtin;
    pub const origins = policy_impl.origins;
};

pub const workspace_grant = struct {
    pub const max_path_bytes = workspace_grant_impl.max_path_bytes;
    pub const State = workspace_grant_impl.State;
};

test {
    const std = @import("std");
    std.testing.refAllDecls(callback_gate_impl);
    std.testing.refAllDecls(product_delivery_impl);
    std.testing.refAllDecls(revision_delivery_impl);
    std.testing.refAllDecls(snapshot_delivery_impl);
    std.testing.refAllDecls(dispatcher_impl);
}
