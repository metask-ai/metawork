//! Field-aware history credential handling, including opaque recovery payloads.
const std = @import("std");
const wire = @import("persistence.zig");

fn structural(comptime T: type, comptime name: []const u8) bool {
    const names: []const []const u8 = if (T == wire.StateWire) &.{ "default_permission_profile", "default_approval_mode" } else if (T == wire.WorkspaceWire) &.{"kind"} else if (T == wire.TaskWire) &.{ "permission_profile", "permission_interaction", "checkpoint_anchor", "checkpoint_attempt" } else if (T == wire.BindingWire) &.{"protocol"} else if (T == wire.OperationWire or T == wire.CheckpointTerminalWire or T == wire.RunInputWire) &.{"kind"} else if (T == wire.RunWire) &.{ "coverage", "execution_protocol", "permission_profile", "permission_interaction", "assistant_output_kind", "phase", "outcome", "cause", "file_change_observation", "event_projection_failure" } else if (T == wire.ToolWire or T == wire.AdditionalInputWire or T == wire.InputSubmissionWire) &.{"state"} else if (T == wire.CompactWire) &.{ "coverage", "phase", "cause" } else if (T == wire.ReviewWire) &.{ "outcome", "cause" } else if (T == wire.UiRecordWire) &.{ "kind", "state", "answered_by" } else if (T == wire.SubmissionWire) &.{"presentation_state"} else if (T == wire.PermissionSummaryWire) &.{ "tool_namespace", "decision", "source", "callback_outcome", "canonical_arguments_digest" } else if (T == wire.AttachmentWire) &.{ "kind", "format" } else if (T == wire.FileReferenceWire) &.{ "locator_kind", "presentation_state" } else if (T == wire.FileChangeWire) &.{ "kind", "status" } else if (T == wire.CheckpointBlobWire or T == wire.FileChangeArtifactWire) &.{"digest"} else if (T == wire.OutputWire) &.{ "id", "sha256" } else &.{};
    for (names) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn matches(value: []const u8, secret: []const u8) bool {
    return secret.len != 0 and std.mem.indexOf(u8, value, secret) != null;
}

pub fn redactBytes(value: []u8, secret: []const u8) bool {
    if (secret.len == 0) return false;
    const marker: u8 = if (std.mem.allEqual(u8, secret, '*')) '?' else '*';
    var changed = false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, value, start, secret)) |position| {
        @memset(value[position..][0..secret.len], marker);
        start = position + secret.len;
        changed = true;
    }
    return changed;
}

pub fn contains(allocator: std.mem.Allocator, value: anytype, secret: []const u8) !bool {
    if (secret.len == 0) return false;
    const T = @TypeOf(value);
    if (T == wire.ReadOnlyPayload) return (try payload(allocator, value.payload, secret, true, false)) != null;
    if (T == wire.RetainedRecord) return (try payload(allocator, value.payload, secret, false, false)) != null;
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) blk: {
            if (p.child == u8) break :blk matches(value, secret);
            for (value) |item| if (try contains(allocator, item, secret)) break :blk true;
            break :blk false;
        } else false,
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (comptime !structural(T, field.name)) {
                if (try contains(allocator, @field(value, field.name), secret)) break :blk true;
            };
            break :blk false;
        },
        .optional => if (value) |item| try contains(allocator, item, secret) else false,
        .@"union" => |info| if (info.tag_type != null) blk: {
            inline for (info.fields) |field| if (std.meta.activeTag(value) == @field(info.tag_type.?, field.name))
                break :blk try contains(allocator, @field(value, field.name), secret);
            unreachable;
        } else false,
        else => false,
    };
}

/// A provisional result may borrow untouched input. Its caller keeps input
/// alive until it has copied the result into its own record or Prepared.
pub fn redact(allocator: std.mem.Allocator, value: anytype, secret: []const u8) !@TypeOf(value) {
    const T = @TypeOf(value);
    if (secret.len == 0) return value;
    if (T == wire.ReadOnlyPayload or T == wire.RetainedRecord) {
        var result = value;
        result.payload = (try payload(allocator, value.payload, secret, T == wire.ReadOnlyPayload, true)) orelse value.payload;
        return result;
    }
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) blk: {
            if (p.child == u8) {
                if (!matches(value, secret)) break :blk value;
                const bytes = try allocator.dupe(u8, value);
                _ = redactBytes(bytes, secret);
                break :blk bytes;
            }
            const items = try allocator.dupe(p.child, value);
            for (items) |*item| item.* = try redact(allocator, item.*, secret);
            break :blk items;
        } else value,
        .@"struct" => |info| blk: {
            var result = value;
            inline for (info.fields) |field| if (comptime !structural(T, field.name)) {
                @field(result, field.name) = try redact(allocator, @field(value, field.name), secret);
            };
            if (comptime T == wire.ModelErrorWire)
                result.host_redacted = value.host_redacted or try contains(allocator, value, secret);
            break :blk result;
        },
        .optional => if (value) |item| try redact(allocator, item, secret) else null,
        .@"union" => |info| if (info.tag_type != null) blk: {
            inline for (info.fields) |field| if (std.meta.activeTag(value) == @field(info.tag_type.?, field.name))
                break :blk @unionInit(T, field.name, try redact(allocator, @field(value, field.name), secret));
            unreachable;
        } else value,
        else => value,
    };
}

fn jsonStrings(allocator: std.mem.Allocator, value: *std.json.Value, secret: []const u8, editing: bool, depth: usize) anyerror!bool {
    if (depth > 128) return error.TaskStoreCorrupt;
    return switch (value.*) {
        .string => |bytes| blk: {
            if (!matches(bytes, secret)) break :blk false;
            if (editing) _ = redactBytes(@constCast(bytes), secret);
            break :blk true;
        },
        .array => |*items| blk: {
            var changed = false;
            for (items.items) |*item| changed = (try jsonStrings(allocator, item, secret, editing, depth + 1)) or changed;
            break :blk changed;
        },
        .object => |*object| blk: {
            var changed = false;
            var replacement: std.json.ObjectMap = .{};
            var it = object.iterator();
            while (it.next()) |entry| {
                const key_changed = matches(entry.key_ptr.*, secret);
                changed = (try jsonStrings(allocator, entry.value_ptr, secret, editing, depth + 1)) or key_changed or changed;
                if (editing) {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    if (key_changed) _ = redactBytes(key, secret);
                    const result = try replacement.getOrPut(allocator, key);
                    if (result.found_existing) return error.TaskStoreCorrupt;
                    result.value_ptr.* = entry.value_ptr.*;
                }
            }
            if (editing) object.* = replacement;
            break :blk changed;
        },
        else => false,
    };
}

fn typedJson(comptime T: type, allocator: std.mem.Allocator, value: *std.json.Value, secret: []const u8, editing: bool, depth: usize) anyerror!bool {
    if (depth > 128) return error.TaskStoreCorrupt;
    return switch (@typeInfo(T)) {
        .optional => |o| if (value.* == .null) false else try typedJson(o.child, allocator, value, secret, editing, depth + 1),
        .pointer => |p| if (p.size == .slice and p.child != u8 and value.* == .array) blk: {
            var changed = false;
            for (value.array.items) |*item| changed = (try typedJson(p.child, allocator, item, secret, editing, depth + 1)) or changed;
            break :blk changed;
        } else try jsonStrings(allocator, value, secret, editing, depth + 1),
        .@"struct" => |info| if (value.* == .object) blk: {
            var changed = false;
            var replacement: std.json.ObjectMap = .{};
            var it = value.object.iterator();
            while (it.next()) |entry| {
                var known = false;
                inline for (info.fields) |field| if (std.mem.eql(u8, entry.key_ptr.*, field.name)) {
                    known = true;
                    if (comptime !structural(T, field.name)) changed = (try typedJson(field.type, allocator, entry.value_ptr, secret, editing, depth + 1)) or changed;
                };
                if (!known) changed = (try jsonStrings(allocator, entry.value_ptr, secret, editing, depth + 1)) or changed;
                const key_changed = !known and matches(entry.key_ptr.*, secret);
                changed = changed or key_changed;
                if (editing) {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    if (key_changed) _ = redactBytes(key, secret);
                    const result = try replacement.getOrPut(allocator, key);
                    if (result.found_existing) return error.TaskStoreCorrupt;
                    result.value_ptr.* = entry.value_ptr.*;
                }
            }
            if (editing) {
                value.object = replacement;
                if (comptime T == wire.ModelErrorWire) {
                    if (changed) try value.object.put(allocator, "host_redacted", .{ .bool = true });
                }
            }
            break :blk changed;
        } else try jsonStrings(allocator, value, secret, editing, depth + 1),
        else => false,
    };
}

fn payload(allocator: std.mem.Allocator, bytes: []const u8, secret: []const u8, readonly: bool, editing: bool) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (readonly) return error.TaskStoreCorrupt;
            if (!matches(bytes, secret)) return null;
            if (!editing) return bytes;
            const output = try allocator.dupe(u8, bytes);
            _ = redactBytes(output, secret);
            return output;
        },
    };
    const changed = if (readonly) try typedJson(wire.TaskWire, a, &parsed.value, secret, editing, 0) else try jsonStrings(a, &parsed.value, secret, editing, 0);
    if (!changed) return null;
    if (!editing) return bytes;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

test "history security preserves structural tags and handles readonly unknown strings without u64 loss" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const original = "{\"id\":18446744073709551615,\"checkpoint_anchor\":\"none\",\"title\":\"none\",\"future\":{\"content\":\"n\\u006fne\",\"n\":18446744073709551615}}";
    const record = wire.ReadOnlyPayload{ .task_id = 1, .recent_order = 1, .payload = original };
    try std.testing.expect(try contains(aa, record, "none"));
    const cleaned = try redact(aa, record, "none");
    try std.testing.expect(!try contains(aa, cleaned, "none"));
    try std.testing.expect(std.mem.indexOf(u8, cleaned.payload, "\"checkpoint_anchor\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.payload, "18446744073709551615") != null);
    const untouched = try redact(aa, record, "absent");
    try std.testing.expectEqualSlices(u8, original, untouched.payload);
    const retained = wire.RetainedRecord{ .kind = .task, .id = 93, .order = 1, .payload = original };
    const scrubbed = try redact(aa, retained, "none");
    try std.testing.expect(!try contains(aa, scrubbed, "none"));
    try std.testing.expectEqual(retained.id, scrubbed.id);
}

test "history security preserves namespace and submission tags but still cleans matching free text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "builtin", "host", "mcp" }) |namespace| {
        var summary: wire.PermissionSummaryWire = .{
            .request_id = "request",
            .matched_rule_id = "rule",
            .tool_namespace = namespace,
            .tool_name = "tool",
            .tool_binding = "binding",
            .decision = "allow",
            .source = "policy",
            .policy_generation = 1,
            .used_session_rule = false,
            .callback_outcome = null,
        };
        try std.testing.expect(!try contains(a, summary, namespace));
        summary.tool_name = namespace;
        try std.testing.expect(try contains(a, summary, namespace));
        const cleaned = try redact(a, summary, namespace);
        try std.testing.expectEqualStrings(namespace, cleaned.tool_namespace);
        try std.testing.expect(!try contains(a, cleaned, namespace));
    }
    for ([_][]const u8{ "anchored", "legacy" }) |state| {
        var submission: wire.SubmissionWire = .{ .presentation_state = state, .operation_id = "operation" };
        try std.testing.expect(!try contains(a, submission, state));
        submission.operation_id = state;
        const cleaned = try redact(a, submission, state);
        try std.testing.expectEqualStrings(state, cleaned.presentation_state.?);
        try std.testing.expect(!try contains(a, cleaned, state));
    }
    const readonly: wire.ReadOnlyPayload = .{ .task_id = 1, .recent_order = 1, .payload = "{\"ui_history\":[{\"permission\":{\"tool_namespace\":\"host\",\"tool_name\":\"tool\"}}],\"runs\":[{\"submission\":{\"presentation_state\":\"anchored\",\"operation_id\":\"operation\"}}]}" };
    for ([_][]const u8{ "host", "anchored" }) |secret| {
        try std.testing.expect(!try contains(a, readonly, secret));
        try std.testing.expectEqualStrings(readonly.payload, (try redact(a, readonly, secret)).payload);
    }
}
