//! Test-only history bindings and observation. Never imported by Product code.
const std = @import("std");
const sql = @import("metawork_storage_sql");
pub const wire = @import("product_task_persistence");

pub const limits: wire.Limits = .{
    .max_workspaces = 16,
    .max_tasks = 50,
    .max_runs_per_task = 16,
    .max_compacts_per_task = 16,
    .max_tools_per_run = 32,
    .max_commentary_segments_per_run = 256,
    .max_file_refs_per_tool = 32,
    .max_file_changes_per_run = 256,
    .max_ui_history_per_task = 8,
    .max_workspace_bytes = 16 * 1024,
    .max_task_title_bytes = 512,
    .max_user_message_bytes = 64 * 1024,
    .max_assistant_message_bytes = 256 * 1024,
    .max_tool_field_bytes = 256 * 1024,
    .max_file_ref_field_bytes = 8192,
    .max_execution_model_bytes = 512,
    .max_terminal_diagnostic_bytes = 512,
};

pub fn fixture(allocator: std.mem.Allocator) !wire.StateWire {
    const state = try std.json.parseFromSliceLeaky(wire.StateWire, allocator, @embedFile("history_schema_full.json"), .{ .allocate = .alloc_always });
    if (wire.validateCandidate(&state, limits) != null) return error.InvalidFixture;
    return state;
}

pub fn parameterBytes(items: []const sql.Mutation) usize {
    var bytes: usize = 0;
    for (items) |mutation| for (mutation.statement.params) |value| {
        bytes += switch (value) {
            .blob, .text => |data| data.len,
            else => 0,
        };
    };
    return bytes;
}
