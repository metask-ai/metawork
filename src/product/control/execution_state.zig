//! Product Control execution generation allocation; owns no execution or credential.
const std = @import("std");

pub const AdmissionReason = enum { none, shutting_down, workspace_unavailable };
pub const NewTaskAdmissionView = struct { available: bool, reason: AdmissionReason };

pub const Generations = struct {
    last: u64 = 0,
    pub fn next(self: *Generations, minimum: u64) error{InvalidExecutionGeneration}!u64 {
        const value = std.math.add(u64, @max(self.last, minimum), 1) catch return error.InvalidExecutionGeneration;
        self.last = value;
        return value;
    }
};

test "execution generations advance beyond both live and historical consumers" {
    var values: Generations = .{};
    try std.testing.expectEqual(@as(u64, 1), try values.next(0));
    try std.testing.expectEqual(@as(u64, 2), try values.next(0));
    try std.testing.expectEqual(@as(u64, 11), try values.next(10));
    try std.testing.expectEqual(@as(u64, 12), try values.next(1));
    try std.testing.expectError(error.InvalidExecutionGeneration, values.next(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 12), values.last);
}
