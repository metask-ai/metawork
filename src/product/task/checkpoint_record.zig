//! Durable Product Task metadata for one immutable Agent checkpoint blob.
//! The record owns product facts only; it has no file, Agent handle, or UI
//! projection responsibilities.

const std = @import("std");
const checkpoint_store = @import("product_task_checkpoint_store");

pub const SessionBinding = struct {
    logical_session_id: []u8,
    last_run_id: u64,
    last_compact_id: u64,
    model: []u8,
};

pub const Terminal = union(enum) {
    run: u64,
    compact: u64,

    pub fn id(self: Terminal) u64 {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

pub const CommitAnchor = struct {
    terminal: Terminal,
    binding_epoch: u64,
};

pub const Record = struct {
    blob: checkpoint_store.Identity,
    session: SessionBinding,
    anchor: CommitAnchor,

    pub fn clone(self: Record, allocator: std.mem.Allocator) !Record {
        const logical_session_id = try allocator.dupe(u8, self.session.logical_session_id);
        errdefer allocator.free(logical_session_id);
        const model = try allocator.dupe(u8, self.session.model);
        return .{
            .blob = self.blob,
            .session = .{
                .logical_session_id = logical_session_id,
                .last_run_id = self.session.last_run_id,
                .last_compact_id = self.session.last_compact_id,
                .model = model,
            },
            .anchor = self.anchor,
        };
    }

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        allocator.free(self.session.logical_session_id);
        allocator.free(self.session.model);
        self.* = undefined;
    }

    pub fn validateBinding(
        self: Record,
        task_id: u64,
        binding_epoch: u64,
    ) error{InvalidRecord}!void {
        if (self.blob.task_id != task_id or
            self.blob.byte_size == 0 or
            self.session.logical_session_id.len == 0 or
            self.session.model.len == 0 or
            self.anchor.binding_epoch == 0 or
            self.anchor.binding_epoch != binding_epoch or
            self.anchor.terminal.id() == 0)
            return error.InvalidRecord;
        switch (self.anchor.terminal) {
            .run => |id| if (self.session.last_run_id != id) return error.InvalidRecord,
            .compact => |id| if (self.session.last_compact_id != id) return error.InvalidRecord,
        }
    }
};

test "record owns exactly blob, session binding, and commit anchor facts" {
    const allocator = std.testing.allocator;
    var record = Record{
        .blob = .{
            .task_id = 9,
            .generation = 4,
            .digest = [_]u8{0x5a} ** checkpoint_store.digest_bytes,
            .byte_size = 123,
        },
        .session = .{
            .logical_session_id = try allocator.dupe(u8, "logical-session"),
            .last_run_id = 7,
            .last_compact_id = 2,
            .model = try allocator.dupe(u8, "model-id"),
        },
        .anchor = .{ .terminal = .{ .run = 7 }, .binding_epoch = 3 },
    };
    defer record.deinit(allocator);
    try record.validateBinding(9, 3);
}
