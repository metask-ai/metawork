//! Strict payload records and parsing shared by Bridge handlers.

const std = @import("std");

pub const PermissionChoice = enum {
    allow_once,
    allow_always,
    deny_once,
    deny_tool_session,
};

pub const EventDisconnect = struct { generation: []const u8 };
pub const WorkbenchSnapshotChunk = struct { snapshotId: []const u8, offset: []const u8 };
pub const TaskCreate = struct {
    workspaceGrant: ?[]const u8 = null,
    workspaceRoot: ?[]const u8 = null,
};
pub const TaskRun = struct { taskId: []const u8, prompt: []const u8 };
pub const TaskIdentity = struct { taskId: []const u8, runId: []const u8 };
pub const TaskClose = struct { taskId: []const u8 };
pub const TaskRename = struct { taskId: []const u8, title: []const u8 };
pub const TaskArchive = struct { taskId: []const u8, archived: bool };
pub const TaskDelete = struct { taskId: []const u8 };
pub const UiResponseRequest = struct {
    taskId: []const u8,
    runId: []const u8,
    requestId: []const u8,
    kind: []const u8,
    answers: ?[]const []const u8 = null,
    permission: ?[]const u8 = null,
};

pub fn parsePayload(comptime T: type, payload: []const u8) !std.json.Parsed(T) {
    return parsePayloadWithLimit(T, payload, 4096);
}

pub fn parsePayloadWithLimit(comptime T: type, payload: []const u8, limit: usize) !std.json.Parsed(T) {
    if (payload.len > limit) return error.InvalidBridgePayload;
    return std.json.parseFromSlice(T, std.heap.c_allocator, payload, .{
        .ignore_unknown_fields = false,
    }) catch error.InvalidBridgePayload;
}

pub fn parseWireId(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidBridgeId;
    for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidBridgeId;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidBridgeId;
}

pub fn acknowledgementSequence(payload: []const u8) !u64 {
    const prefix = "{\"sequence\":";
    if (!std.mem.startsWith(u8, payload, prefix) or !std.mem.endsWith(u8, payload, "}"))
        return error.InvalidAcknowledgement;
    const digits = payload[prefix.len .. payload.len - 1];
    return parseWireId(digits) catch error.InvalidAcknowledgement;
}

pub fn permissionChoice(value: []const u8) ?PermissionChoice {
    if (std.mem.eql(u8, value, "allow_once")) return .allow_once;
    if (std.mem.eql(u8, value, "allow_always")) return .allow_always;
    if (std.mem.eql(u8, value, "deny_once")) return .deny_once;
    if (std.mem.eql(u8, value, "deny_tool_session")) return .deny_tool_session;
    return null;
}
