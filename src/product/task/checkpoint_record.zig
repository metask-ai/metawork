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
    approval: u64,

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
            .approval => {},
        }
    }

    pub fn adoptBindingEpoch(
        self: *Record,
        expected: u64,
        next: u64,
    ) error{InvalidRecord}!void {
        if (expected == 0 or next == 0 or
            self.anchor.binding_epoch != expected or
            expected == std.math.maxInt(u64) or
            next != expected + 1)
            return error.InvalidRecord;
        self.anchor.binding_epoch = next;
    }
};

/// The epoch a binding installed from this attempt will be under.
///
/// One function for both the open and the adoption, because they are the same
/// number and were being computed in two places that disagreed. The adoption
/// moved the Task to `current + 1` when the attempt advances the binding,
/// while the Session was opened carrying `current` -- so every Session
/// installed through an advancing recovery was one epoch behind its Task for
/// its whole life, and a record it staged was indistinguishable from one
/// staged by the Session it replaced. Telling those two apart is the only
/// thing the field is for.
///
/// Opening under the epoch it will be installed at inverts which case is
/// wrong, and inverts it onto the restricting side: in the window before
/// adoption -- including an adoption that never happens -- the Session is one
/// *ahead* of its Task, so a record staged there names an epoch the Task
/// never reached and acceptance refuses it. That is the right answer for a
/// candidate nobody accepted, and it is an answer rather than a collision.
///
/// It fails rather than wrapping, next to the validator that enforces the
/// same arithmetic from the other direction: `adoptBindingEpoch` refuses
/// `maxInt` as `expected` and refuses any `next` that is not `expected + 1`,
/// so the two cannot drift apart without one of them refusing.
pub fn installedBindingEpoch(
    current: u64,
    advances_binding: bool,
) error{BindingEpochExhausted}!u64 {
    if (!advances_binding) return current;
    if (current == std.math.maxInt(u64)) return error.BindingEpochExhausted;
    return current + 1;
}

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
    try record.adoptBindingEpoch(3, 4);
    try record.validateBinding(9, 4);
    try std.testing.expectError(error.InvalidRecord, record.adoptBindingEpoch(3, 4));
}

test "the epoch a Session is opened under is the one the adoption installs" {
    // No advance: the binding is the same one, so the epoch does not move.
    try std.testing.expectEqual(@as(u64, 3), try installedBindingEpoch(3, false));

    // An advance: the Session is opened under 4 and the adoption installs 4.
    // It used to be opened under 3, which is the epoch of the Session being
    // replaced -- so a record staged afterwards named the wrong binding and
    // named it the same way the replaced Session would have.
    try std.testing.expectEqual(@as(u64, 4), try installedBindingEpoch(3, true));

    // And the validator on the other side accepts exactly that step, so the
    // two cannot be changed apart: a record made under `previous` migrates to
    // what this function returns.
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
    try record.adoptBindingEpoch(3, try installedBindingEpoch(3, true));
    try record.validateBinding(9, 4);
}

test "an exhausted epoch refuses the advance instead of wrapping" {
    const last = std.math.maxInt(u64);
    // Not advancing is still fine at the end of the range: nothing moves.
    try std.testing.expectEqual(last, try installedBindingEpoch(last, false));
    try std.testing.expectError(
        error.BindingEpochExhausted,
        installedBindingEpoch(last, true),
    );
}
