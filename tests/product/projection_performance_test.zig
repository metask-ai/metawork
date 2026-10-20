//! Isolated presentation measurement: fixture setup and invalidation are outside each timed read.
const std = @import("std");
const builtin = @import("builtin");
const control = @import("metawork_product_control");
const bridge = @import("metawork_bridge");

const samples = 100;
const Scenario = enum { index_cold, task_cold, history_cold, history_copy, history_confirmed, targeted_update };

const Transport = struct {
    fn emit(_: ?*anyopaque, _: u64, _: []const u8, _: []const u8) !void {}
    fn timer(_: ?*anyopaque, _: u64, _: u64, _: bool) !void {}
    fn cancel(_: ?*anyopaque, _: u64) !void {}
};
const delivery_transport: bridge.ProductDeliveryTransport = .{ .emit_fn = Transport.emit, .start_timer_fn = Transport.timer, .cancel_timer_fn = Transport.cancel };
const Read = struct {
    runtime: *control.Runtime,
    request: control.ViewRequest,
    fn begin(context: ?*anyopaque, output: []u8) !bridge.SnapshotStart {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const read = try self.runtime.writeSnapshot(output, self.request);
        return .{ .read_id = read.id, .bytes = read.bytes };
    }
    fn range(context: ?*anyopaque, id: u64, output: []u8, offset: usize, length: usize) !void {
        const runtime: *control.Runtime = @ptrCast(@alignCast(context.?));
        try runtime.writeSnapshotRange(id, output, offset, length);
    }
};

test "Product projection legal maximum performance" {
    var over_budget = false;
    for ([_]bool{ false, true }) |tool_inputs| {
        const runtime = try std.testing.allocator.create(control.Runtime);
        defer std.testing.allocator.destroy(runtime);
        runtime.* = if (tool_inputs) try control.TestSupport.maximumToolFixture() else try control.TestSupport.maximumFixture();
        defer runtime.deinit();
        const output = try std.testing.allocator.alloc(u8, runtime.limits.max_snapshot_bytes);
        defer std.testing.allocator.free(output);
        // The fixture has 50 Tasks x 16 Runs, 16 Manual Workspaces and 34 owned
        // Automatic Workspaces. All text allocations share the real 1.5 MiB budget.
        try std.testing.expectEqual(@as(usize, 50), runtime.task_runtime.tasks.len);
        try std.testing.expectEqual(runtime.limits.max_projection_bytes, runtime.projection_bytes);
        var delivery = try bridge.ProductDelivery.init(std.testing.allocator);
        defer delivery.deinitOwnedBuffers();
        _ = try delivery.connect(1, delivery_transport);
        defer delivery.breakConnection(delivery_transport);
        const response = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bridge.snapshot_chunk_bytes) + 256);
        defer std.testing.allocator.free(response);
        inline for (std.meta.fields(Scenario)) |scenario| {
            var request: control.ViewRequest = .{};
            if (scenario.value != @intFromEnum(Scenario.index_cold)) request.task_id = 1;
            if (scenario.value >= @intFromEnum(Scenario.history_cold)) request.before_run_id = 5;
            runtime.encoded_views.clear(std.testing.allocator);
            const initial = try runtime.writeViewFixture(output, request);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initial, .{});
            defer parsed.deinit();
            if (scenario.value >= @intFromEnum(Scenario.history_confirmed)) {
                request.known_epoch = runtime.projectionSecurityEpoch();
                inline for (std.meta.fields(@TypeOf(request.known_versions))) |field| @field(request.known_versions, field.name) = try std.fmt.parseInt(u64, parsed.value.object.get("blockVersions").?.object.get(field.name).?.string, 10);
            }
            var durations: [samples]i96 = undefined;
            var max_bytes: usize = 0;
            var capture_times: [samples]i96 = undefined;
            var encode_times: [samples]i96 = @splat(0);
            var cache_times: [samples]i96 = @splat(0);
            var transport_times: [samples]i96 = @splat(0);
            for (&durations, 0..) |*duration, sample_index| {
                if (scenario.value <= @intFromEnum(Scenario.history_cold)) runtime.encoded_views.clear(std.testing.allocator);
                if (scenario.value == @intFromEnum(Scenario.targeted_update)) {
                    const run = &runtime.task_runtime.tasks[0].?.durable.runs[15].?;
                    run.input.text.value[0] = if (run.input.text.value[0] == 'a') 'b' else 'a';
                    run.projection_content_version += 1;
                    runtime.encoded_views.invalidateEvent(1, 16);
                }
                const start = std.Io.Timestamp.now(std.testing.io, .awake);
                var read = Read{ .runtime = runtime, .request = request };
                const view = try delivery.publishSnapshot(1, runtime.projectionSecurityEpoch(), .{ .context = &read, .write_fn = Read.begin });
                duration.* = start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
                capture_times[sample_index] = duration.*;
                max_bytes = @max(max_bytes, view.bytes);
                var offset: usize = 0;
                while (offset < view.bytes) : (offset += bridge.snapshot_chunk_bytes) {
                    const step_start = std.Io.Timestamp.now(std.testing.io, .awake);
                    const chunk = try delivery.snapshotChunk(1, runtime.projectionSecurityEpoch(), view.id, offset, .{ .context = runtime, .write_fn = Read.range });
                    const transport_start = std.Io.Timestamp.now(std.testing.io, .awake);
                    var writer = std.Io.Writer.fixed(response);
                    try writer.print("{{\"snapshotId\":\"{d}\",\"offset\":{d},\"bytes\":{d},\"data\":\"", .{ view.id, offset, chunk.len });
                    try std.base64.standard.Encoder.encodeWriter(&writer, chunk);
                    try writer.writeAll("\"}");
                    std.mem.doNotOptimizeAway(writer.buffered());
                    const end = std.Io.Timestamp.now(std.testing.io, .awake);
                    duration.* = @max(duration.*, step_start.durationTo(end).nanoseconds);
                    encode_times[sample_index] = @max(encode_times[sample_index], runtime.view_step_timing.encode_ns);
                    cache_times[sample_index] = @max(cache_times[sample_index], runtime.view_step_timing.cache_copy_ns);
                    transport_times[sample_index] = @max(transport_times[sample_index], transport_start.durationTo(end).nanoseconds);
                }
            }
            std.mem.sort(i96, &durations, {}, std.sort.asc(i96));
            std.mem.sort(i96, &capture_times, {}, std.sort.asc(i96));
            std.mem.sort(i96, &encode_times, {}, std.sort.asc(i96));
            std.mem.sort(i96, &cache_times, {}, std.sort.asc(i96));
            std.mem.sort(i96, &transport_times, {}, std.sort.asc(i96));
            std.debug.print("PROJECTION_STAGES fixture={s} scenario={s} capture_p99_ns={d} capture_max_ns={d} encode_p99_ns={d} encode_max_ns={d} cache_copy_p99_ns={d} cache_copy_max_ns={d} transport_p99_ns={d} transport_max_ns={d}\n", .{ if (tool_inputs) "tool_inputs" else "escaped_history", scenario.name, capture_times[98], capture_times[99], encode_times[98], encode_times[99], cache_times[98], cache_times[99], transport_times[98], transport_times[99] });
            const p99 = durations[98];
            const maximum = durations[99];
            const debug = builtin.mode == .Debug;
            const p99_limit = (if (debug) @as(i96, 16) else 8) * std.time.ns_per_ms;
            const max_limit = (if (debug) @as(i96, 32) else 16) * std.time.ns_per_ms;
            const passed = p99 <= p99_limit and maximum <= max_limit;
            over_budget = over_budget or !passed;
            std.debug.print("PROJECTION_PERFORMANCE {{\"mode\":\"{s}\",\"fixture\":\"{s}\",\"scenario\":\"{s}\",\"samples\":{d},\"bytes\":{d},\"p99_ns\":{d},\"max_ns\":{d},\"passed\":{}}}\n", .{ @tagName(builtin.mode), if (tool_inputs) "tool_inputs" else "escaped_history", scenario.name, samples, max_bytes, p99, maximum, passed });
        }
    }
    try std.testing.expect(!over_budget);
}
