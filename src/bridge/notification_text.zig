//! The system-notification text contract between the Renderer and the Host.
//!
//! The Host raises system notifications but does not know the application
//! language: localization lives entirely in the Renderer's message catalog.
//! So the Renderer registers one already-localized string per closed-vocabulary
//! slot and re-registers whenever the language changes; the Host only selects a
//! slot and injects the Task title, which Product already localized.
//!
//! The vocabulary is an enum, never a free-form key, so a notification the Host
//! can raise without a registered string is a compile error in `Registration`
//! below rather than a blank banner at notification time. A registration is
//! also all-or-nothing: a missing field is a decode error, so the Host never
//! holds a half-filled table.

const std = @import("std");
const platform = @import("native_sdk").platform;

/// Every string MetaWork can put in a system notification. One slot is one
/// string; `Registration` carries exactly one field per slot.
pub const Slot = enum {
    schedule_completed,
    schedule_failed,
    schedule_skipped,
    schedule_needs_attention,
    run_completed,
    run_failed,
    run_needs_approval,

    pub const count = @typeInfo(Slot).@"enum".fields.len;
};

/// Table width. Wide enough for one sentence in any catalog language — the
/// development pseudo-locale inflates every string, so the ceiling cannot sit
/// at the length of the English source — while keeping the whole table small
/// enough to live inline in Application state with no allocation.
pub const max_slot_bytes: usize = 256;

/// The SDK refuses a notification whose field exceeds its own limit, which
/// would lose the banner entirely. Hold each slot to the limit of the field it
/// feeds instead, so a registration that could not be shown is refused at
/// registration time. Every slot fills the notification body today — the
/// headline is the Task title, which is not ours to translate — but the switch
/// stays exhaustive so a slot aimed at a tighter field has to say so.
pub fn slotLimit(slot: Slot) usize {
    return @min(max_slot_bytes, switch (slot) {
        .schedule_completed,
        .schedule_failed,
        .schedule_skipped,
        .schedule_needs_attention,
        .run_completed,
        .run_failed,
        .run_needs_approval,
        => platform.max_notification_body_bytes,
    });
}

/// A complete, Renderer-registered table. Held by value in Application state:
/// bounded, copyable, and owning its bytes, so no Renderer buffer outlives the
/// registration call.
pub const Table = struct {
    bytes: [Slot.count][max_slot_bytes]u8,
    lengths: [Slot.count]u16,

    pub fn get(self: *const Table, slot: Slot) []const u8 {
        const index = @intFromEnum(slot);
        return self.bytes[index][0..self.lengths[index]];
    }
};

/// The wire record. One required field per `Slot`, named in the Bridge's
/// camelCase convention; the guard below proves the two stay in step, by
/// position as well as by name, so `decode` can index slots by field order.
pub const Registration = struct {
    scheduleCompleted: []const u8,
    scheduleFailed: []const u8,
    scheduleSkipped: []const u8,
    scheduleNeedsAttention: []const u8,
    runCompleted: []const u8,
    runFailed: []const u8,
    runNeedsApproval: []const u8,
};

comptime {
    const slots = @typeInfo(Slot).@"enum".fields;
    const fields = @typeInfo(Registration).@"struct".fields;
    if (slots.len != fields.len)
        @compileError("every notification text slot needs exactly one wire field");
    for (slots, fields) |slot, field| {
        if (!std.mem.eql(u8, camelCase(slot.name), field.name))
            @compileError("notification wire field '" ++ field.name ++
                "' does not name slot '" ++ slot.name ++ "'");
        if (field.type != []const u8 or field.default_value_ptr != null)
            @compileError("notification wire field '" ++ field.name ++
                "' must be a required string, so a missing slot fails to decode");
    }
}

fn camelCase(comptime snake: []const u8) []const u8 {
    comptime var camel: []const u8 = "";
    comptime var capitalize = false;
    inline for (snake) |byte| {
        if (byte == '_') {
            capitalize = true;
            continue;
        }
        camel = camel ++ [_]u8{if (capitalize) std.ascii.toUpper(byte) else byte};
        capitalize = false;
    }
    return camel;
}

/// Copies a registration into an owned table, or refuses it whole. A slot that
/// is empty, over its field's limit or not valid UTF-8 rejects the whole
/// registration rather than installing a table that would show a blank,
/// broken or unsendable banner.
pub fn decode(value: Registration) ?Table {
    var table: Table = .{ .bytes = undefined, .lengths = @splat(0) };
    inline for (@typeInfo(Registration).@"struct".fields, 0..) |field, index| {
        const text = @field(value, field.name);
        if (text.len == 0 or text.len > slotLimit(@enumFromInt(index))) return null;
        if (!std.unicode.utf8ValidateSlice(text)) return null;
        @memcpy(table.bytes[index][0..text.len], text);
        table.lengths[index] = @intCast(text.len);
    }
    return table;
}

test "a decoded table answers every slot with its registered string" {
    const table = decode(.{
        .scheduleCompleted = "定时任务已完成",
        .scheduleFailed = "定时任务失败",
        .scheduleSkipped = "上一次运行仍在进行，本次已跳过",
        .scheduleNeedsAttention = "定时任务需要处理",
        .runCompleted = "任务已完成",
        .runFailed = "任务失败",
        .runNeedsApproval = "任务等待你的确认",
    }).?;
    try std.testing.expectEqualStrings("定时任务已完成", table.get(.schedule_completed));
    try std.testing.expectEqualStrings("任务等待你的确认", table.get(.run_needs_approval));
    inline for (@typeInfo(Slot).@"enum".fields) |slot|
        try std.testing.expect(table.get(@field(Slot, slot.name)).len > 0);
}

test "a registration is refused whole rather than installed half-filled" {
    const complete: Registration = .{
        .scheduleCompleted = "a",
        .scheduleFailed = "b",
        .scheduleSkipped = "c",
        .scheduleNeedsAttention = "d",
        .runCompleted = "e",
        .runFailed = "f",
        .runNeedsApproval = "g",
    };
    try std.testing.expect(decode(complete) != null);
    inline for (@typeInfo(Registration).@"struct".fields, 0..) |field, index| {
        var empty = complete;
        @field(empty, field.name) = "";
        try std.testing.expectEqual(@as(?Table, null), decode(empty));
        var invalid = complete;
        @field(invalid, field.name) = "\xff";
        try std.testing.expectEqual(@as(?Table, null), decode(invalid));
        const limit = slotLimit(@enumFromInt(index));
        var at_limit = complete;
        @field(at_limit, field.name) = "x" ** max_slot_bytes;
        @field(at_limit, field.name) = @field(at_limit, field.name)[0..limit];
        try std.testing.expect(decode(at_limit) != null);
        var oversized = complete;
        oversized = at_limit;
        @field(oversized, field.name) = ("x" ** (max_slot_bytes + 1))[0 .. limit + 1];
        try std.testing.expectEqual(@as(?Table, null), decode(oversized));
    }
}

test "every slot is held to the limit of the notification body it fills" {
    inline for (@typeInfo(Slot).@"enum".fields) |slot|
        try std.testing.expectEqual(max_slot_bytes, slotLimit(@field(Slot, slot.name)));
    // The table's own width is the binding limit here, and it has to stay
    // inside the SDK field every slot feeds.
    try std.testing.expect(max_slot_bytes <= platform.max_notification_body_bytes);
}
