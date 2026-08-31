//! Pure Product Schedule snapshot derivation.
//!
//! Borrows Schedule state and a callback-scoped text projector. It owns no
//! state, credential material, timer, persistence capability or Task fact.

const std = @import("std");
const state = @import("product_schedule_state");

pub const Error = error{SnapshotTooLarge};

pub const TextProjection = struct {
    context: *const anyopaque,
    write_json_fn: *const fn (
        *const anyopaque,
        *std.Io.Writer,
        []const u8,
    ) Error!void,

    fn writeJson(
        self: TextProjection,
        writer: *std.Io.Writer,
        value: []const u8,
    ) Error!void {
        return self.write_json_fn(self.context, writer, value);
    }
};

pub fn writeProjection(
    writer: *std.Io.Writer,
    store: *const state.Store,
    text: TextProjection,
) Error!void {
    writer.writeByte('[') catch return error.SnapshotTooLarge;
    var count: usize = 0;
    for (store.items) |*entry| {
        const item = &(entry.* orelse continue);
        if (count != 0) writer.writeByte(',') catch
            return error.SnapshotTooLarge;
        count += 1;
        try writeItem(writer, item, text);
    }
    writer.writeByte(']') catch return error.SnapshotTooLarge;
}

fn writeItem(
    writer: *std.Io.Writer,
    item: *const state.Item,
    text: TextProjection,
) Error!void {
    writer.print(
        "{{\"id\":\"{d}\",\"epoch\":\"{d}\",\"title\":",
        .{ item.id, item.epoch },
    ) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, item.title);
    writer.print(
        ",\"titleRedacted\":{},\"enabled\":{},\"health\":\"{s}\",\"failureReason\":",
        .{ item.title_redacted, item.enabled, @tagName(item.health) },
    ) catch return error.SnapshotTooLarge;
    if (item.failure_reason) |reason|
        writer.print("\"{s}\"", .{@tagName(reason)}) catch
            return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.print(
        ",\"execution\":{{\"generation\":\"{d}\",\"provider\":\"{s}\",\"model\":",
        .{ item.execution_generation, @tagName(item.execution_provider) },
    ) catch return error.SnapshotTooLarge;
    try text.writeJson(writer, item.execution_model);
    writer.print("}},\"permissionProfile\":\"{s}\",\"input\":{{\"kind\":\"text\",\"text\":", .{
        @tagName(item.permission_profile),
    }) catch
        return error.SnapshotTooLarge;
    try text.writeJson(writer, item.input.borrowed());
    writer.print(",\"redacted\":{}}}", .{item.input.redacted}) catch
        return error.SnapshotTooLarge;
    writer.writeAll(",\"recurrence\":") catch return error.SnapshotTooLarge;
    switch (item.recurrence) {
        .once => |once| writer.print(
            "{{\"kind\":\"once\",\"atUnixSeconds\":\"{d}\"}}",
            .{once.at_unix_seconds},
        ) catch return error.SnapshotTooLarge,
        .interval => |interval| writer.print(
            "{{\"kind\":\"interval\",\"startAtUnixSeconds\":\"{d}\",\"everySeconds\":\"{d}\"}}",
            .{ interval.start_at_unix_seconds, interval.every_seconds },
        ) catch return error.SnapshotTooLarge,
    }
    writer.writeAll(",\"nextRunAtUnixSeconds\":") catch
        return error.SnapshotTooLarge;
    if (item.next_run_at_unix_seconds) |next|
        writer.print("\"{d}\"", .{next}) catch return error.SnapshotTooLarge
    else
        writer.writeAll("null") catch return error.SnapshotTooLarge;
    writer.writeAll(",\"occurrences\":[") catch return error.SnapshotTooLarge;
    for (item.occurrences(), 0..) |occurrence, index| {
        if (index != 0) writer.writeByte(',') catch
            return error.SnapshotTooLarge;
        writer.print(
            "{{\"plannedAtUnixSeconds\":\"{d}\",\"triggeredAtUnixSeconds\":\"{d}\",\"source\":\"{s}\",\"result\":\"{s}\",\"taskId\":",
            .{
                occurrence.planned_at_unix_seconds,
                occurrence.triggered_at_unix_seconds,
                @tagName(occurrence.source),
                @tagName(occurrence.result),
            },
        ) catch return error.SnapshotTooLarge;
        if (occurrence.task_id == 0)
            writer.writeAll("null") catch return error.SnapshotTooLarge
        else
            writer.print("\"{d}\"", .{occurrence.task_id}) catch
                return error.SnapshotTooLarge;
        writer.writeAll(",\"reason\":") catch return error.SnapshotTooLarge;
        if (occurrence.reason) |reason|
            writer.print("\"{s}\"", .{@tagName(reason)}) catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeAll(",\"taskOutcome\":") catch
            return error.SnapshotTooLarge;
        if (occurrence.task_outcome) |outcome|
            writer.print("\"{s}\"", .{@tagName(outcome)}) catch
                return error.SnapshotTooLarge
        else
            writer.writeAll("null") catch return error.SnapshotTooLarge;
        writer.writeByte('}') catch return error.SnapshotTooLarge;
    }
    writer.writeAll("]}") catch return error.SnapshotTooLarge;
}
