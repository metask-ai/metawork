//! Explicit integer encodings shared by the two published wire pilots.
const std = @import("std");

pub const PositiveId = struct {
    value: u64,
    pub const wire_scalar = "positiveWireId";

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) std.Io.Writer.Error!void {
        std.debug.assert(self.value > 0);
        try json.print("\"{d}\"", .{self.value});
    }
};

pub const PositiveNumber = struct {
    value: usize,
    pub const wire_scalar = "positiveNumber";

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) std.Io.Writer.Error!void {
        std.debug.assert(self.value > 0 and self.value <= 9_007_199_254_740_991);
        try json.write(self.value);
    }
};

pub const U64 = struct {
    value: u64,
    pub const wire_scalar = "u64WireInteger";

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.print("\"{d}\"", .{self.value});
    }
};

pub const PositiveU64 = struct {
    value: u64,
    pub const wire_scalar = "positiveU64WireId";

    pub fn jsonStringify(self: @This(), json: *std.json.Stringify) std.Io.Writer.Error!void {
        try (PositiveId{ .value = self.value }).jsonStringify(json);
    }
};
