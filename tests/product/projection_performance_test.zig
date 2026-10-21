//! Isolated presentation measurement: fixture setup and invalidation are outside each timed read.
const std = @import("std");
const builtin = @import("builtin");
const control = @import("metawork_product_control");
const bridge = @import("metawork_bridge");

// Diagnostic only. Wall-clock acceptance below remains unchanged, including
// descheduling; cycles help distinguish CPU work from an isolated wall stall.
const ThreadSample = struct { cycles: u64 = 0, core: u32 = 0 };
fn threadSample() ThreadSample {
    if (builtin.os.tag != .windows) return .{};
    const Windows = struct {
        extern "kernel32" fn QueryThreadCycleTime(std.os.windows.HANDLE, *u64) callconv(.winapi) i32;
        extern "kernel32" fn GetCurrentProcessorNumber() callconv(.winapi) u32;
    };
    var cycles: u64 = 0;
    _ = Windows.QueryThreadCycleTime(std.os.windows.GetCurrentThread(), &cycles);
    return .{ .cycles = cycles, .core = Windows.GetCurrentProcessorNumber() };
}
const WorstStep = struct {
    stage: []const u8 = "none",
    wall_ns: i96 = 0,
    cycles: u64 = 0,
    before_core: u32 = 0,
    after_core: u32 = 0,
    fn observe(self: *WorstStep, stage: []const u8, wall_ns: i96, before: ThreadSample) void {
        const after = threadSample();
        if (wall_ns <= self.wall_ns) return;
        self.* = .{ .stage = stage, .wall_ns = wall_ns, .cycles = after.cycles -| before.cycles, .before_core = before.core, .after_core = after.core };
    }
};

const samples = 100;
const Scenario = enum { index_cold, task_cold, history_cold, history_copy, history_confirmed, targeted_update, search_cold, skills_cold, mcp_cold, schedules_cold };
const Fixture = enum { escaped_history, tool_inputs, tool_results, concentrated_results };

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
        return .{ .read_id = read.id, .bytes = read.bytes, .scratch_bytes = read.scratch_bytes };
    }
    fn prepare(context: ?*anyopaque, id: u64, output: []u8) !bridge.SnapshotStart {
        const runtime: *control.Runtime = @ptrCast(@alignCast(context.?));
        const read = try runtime.continueSnapshot(id, output);
        return .{ .read_id = read.id, .bytes = read.bytes, .scratch_bytes = read.scratch_bytes };
    }
    fn range(context: ?*anyopaque, id: u64, output: []u8, offset: usize, length: usize) !void {
        const runtime: *control.Runtime = @ptrCast(@alignCast(context.?));
        try runtime.writeSnapshotRange(id, output, offset, length);
    }
};

fn initializeFixture(comptime fixture: Fixture, runtime: *control.Runtime) !void {
    runtime.* = switch (fixture) {
        .escaped_history => try control.TestSupport.maximumFixture(),
        .tool_inputs, .tool_results => try control.TestSupport.maximumToolFixture(),
        .concentrated_results => try control.TestSupport.maximumSmallFixture(),
    };
    errdefer runtime.deinit();
    if (fixture == .tool_results or fixture == .concentrated_results)
        try control.TestSupport.installResultFixture(runtime, fixture == .concentrated_results);
}

test "Product projection legal maximum performance escaped history" {
    try measureFixture(.escaped_history);
}
test "Product projection legal maximum performance tool inputs" {
    try measureFixture(.tool_inputs);
}
test "Product projection legal maximum performance tool results" {
    try measureFixture(.tool_results);
}
test "Product projection legal maximum performance concentrated results" {
    try measureFixture(.concentrated_results);
}

fn measureFixture(comptime fixture: Fixture) !void {
    var over_budget = false;
    {
        const runtime = try std.testing.allocator.create(control.Runtime);
        defer std.testing.allocator.destroy(runtime);
        const sparse = fixture == .concentrated_results;
        switch (fixture) {
            inline else => |kind| try initializeFixture(kind, runtime),
        }
        defer runtime.deinit();
        try control.TestSupport.validatePersistedFixture(runtime);
        const output = try std.testing.allocator.alloc(u8, runtime.limits.max_snapshot_bytes);
        defer std.testing.allocator.free(output);
        // The fixture has 50 Tasks x 16 Runs, 16 Manual Workspaces and 34 owned
        // Automatic Workspaces. All text allocations share the real 1.5 MiB budget.
        try std.testing.expectEqual(@as(usize, if (sparse) 1 else 50), runtime.task_runtime.tasks.len);
        try std.testing.expectEqual(runtime.limits.max_projection_bytes, runtime.projection_bytes);
        var delivery = try bridge.ProductDelivery.init(std.testing.allocator);
        defer delivery.deinitOwnedBuffers();
        _ = try delivery.connect(1, delivery_transport);
        defer delivery.breakConnection(delivery_transport);
        const response = try std.testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bridge.snapshot_chunk_bytes) + 256);
        defer std.testing.allocator.free(response);
        inline for (std.meta.fields(Scenario)) |scenario| {
            var request: control.ViewRequest = .{};
            const kind: Scenario = @enumFromInt(scenario.value);
            switch (kind) {
                .index_cold => {},
                .task_cold => request.task_id = 1,
                .history_cold, .history_copy, .history_confirmed, .targeted_update => {
                    request.task_id = 1;
                    request.before_run_id = if (sparse) 1 else 5;
                },
                .search_cold => request.search = true,
                .skills_cold => request.management = .skills,
                .mcp_cold => request.management = .mcp,
                .schedules_cold => request.management = .schedules,
            }
            const cold = kind != .history_copy and kind != .history_confirmed and kind != .targeted_update;
            runtime.encoded_views.clear(std.testing.allocator);
            const initial = try runtime.writeViewFixture(output, request);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, initial, .{});
            defer parsed.deinit();
            if (kind == .history_confirmed or kind == .targeted_update) {
                request.known_epoch = runtime.projectionSecurityEpoch();
                inline for (std.meta.fields(@TypeOf(request.known_versions))) |field| @field(request.known_versions, field.name) = try std.fmt.parseInt(u64, parsed.value.object.get("blockVersions").?.object.get(field.name).?.string, 10);
            }
            var worst: WorstStep = .{};
            var durations: [samples]i96 = undefined;
            var max_bytes: usize = 0;
            var capture_times: [samples]i96 = undefined;
            var prepare_times: [samples]i96 = @splat(0);
            var encode_times: [samples]i96 = @splat(0);
            var cache_times: [samples]i96 = @splat(0);
            var transport_times: [samples]i96 = @splat(0);
            for (&durations, 0..) |*duration, sample_index| {
                if (cold) runtime.encoded_views.clear(std.testing.allocator);
                if (scenario.value == @intFromEnum(Scenario.targeted_update)) {
                    const run = &runtime.task_runtime.tasks[0].?.durable.runs[if (sparse) 0 else 15].?;
                    run.input.text.value[0] = if (run.input.text.value[0] == 'a') 'b' else 'a';
                    run.projection_content_version += 1;
                    runtime.encoded_views.invalidateEvent(1, run.id);
                }
                const capture_thread = threadSample();
                const start = std.Io.Timestamp.now(std.testing.io, .awake);
                var read = Read{ .runtime = runtime, .request = request };
                var view = try delivery.publishSnapshot(1, runtime.projectionSecurityEpoch(), .{ .context = &read, .write_fn = Read.begin });
                duration.* = start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
                capture_times[sample_index] = duration.*;
                worst.observe("capture", duration.*, capture_thread);
                while (view.bytes == 0) {
                    const step_thread = threadSample();
                    const step_start = std.Io.Timestamp.now(std.testing.io, .awake);
                    view = try delivery.prepareSnapshot(1, runtime.projectionSecurityEpoch(), view.id, .{ .context = runtime, .prepare_fn = Read.prepare });
                    const elapsed = step_start.durationTo(std.Io.Timestamp.now(std.testing.io, .awake)).nanoseconds;
                    duration.* = @max(duration.*, elapsed);
                    worst.observe("prepare", elapsed, step_thread);
                    prepare_times[sample_index] = @max(prepare_times[sample_index], elapsed);
                }
                max_bytes = @max(max_bytes, view.bytes);
                var offset: usize = 0;
                while (offset < view.bytes) : (offset += bridge.snapshot_chunk_bytes) {
                    const step_thread = threadSample();
                    const step_start = std.Io.Timestamp.now(std.testing.io, .awake);
                    const chunk = try delivery.snapshotChunk(1, runtime.projectionSecurityEpoch(), view.id, offset, .{ .context = runtime, .write_fn = Read.range });
                    const transport_start = std.Io.Timestamp.now(std.testing.io, .awake);
                    var writer = std.Io.Writer.fixed(response);
                    try writer.print("{{\"snapshotId\":\"{d}\",\"offset\":{d},\"bytes\":{d},\"data\":\"", .{ view.id, offset, chunk.len });
                    try std.base64.standard.Encoder.encodeWriter(&writer, chunk);
                    try writer.writeAll("\"}");
                    std.mem.doNotOptimizeAway(writer.buffered());
                    const end = std.Io.Timestamp.now(std.testing.io, .awake);
                    const elapsed = step_start.durationTo(end).nanoseconds;
                    duration.* = @max(duration.*, elapsed);
                    worst.observe("chunk", elapsed, step_thread);
                    encode_times[sample_index] = @max(encode_times[sample_index], runtime.view_step_timing.encode_ns);
                    cache_times[sample_index] = @max(cache_times[sample_index], runtime.view_step_timing.cache_copy_ns);
                    transport_times[sample_index] = @max(transport_times[sample_index], transport_start.durationTo(end).nanoseconds);
                }
                // Outside the timed steps: prove legal JSON exercised the real
                // structured-result path rather than its unavailable fallback.
                if (sample_index == 0 and kind == .task_cold and (fixture == .tool_results or fixture == .concentrated_results)) {
                    var projected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, delivery.snapshot.storage[0..view.bytes], .{});
                    defer projected.deinit();
                    const run = projected.value.object.get("taskPage").?.object.get("task").?.object.get("runs").?.array.items[0];
                    const bash = run.object.get("tools").?.array.items[0].object.get("bash").?.object;
                    if (sparse) try std.testing.expectEqual(@as(usize, 65_000), bash.get("command").?.string.len);
                    const result = bash.get("result").?;
                    try std.testing.expect(result == .object);
                    try std.testing.expectEqual(@as(usize, if (sparse) 65_000 else 640), result.object.get("stdout").?.string.len);
                }
            }
            std.debug.print("PROJECTION_WORST fixture={s} scenario={s} stage={s} wall_ns={d} thread_cycles={d} core_before={d} core_after={d}\n", .{ @tagName(fixture), scenario.name, worst.stage, worst.wall_ns, worst.cycles, worst.before_core, worst.after_core });
            std.mem.sort(i96, &durations, {}, std.sort.asc(i96));
            std.mem.sort(i96, &capture_times, {}, std.sort.asc(i96));
            std.mem.sort(i96, &prepare_times, {}, std.sort.asc(i96));
            std.debug.print("PROJECTION_PREPARE fixture={s} scenario={s} p99_ns={d} max_ns={d}\n", .{ @tagName(fixture), scenario.name, prepare_times[98], prepare_times[99] });
            std.mem.sort(i96, &encode_times, {}, std.sort.asc(i96));
            std.mem.sort(i96, &cache_times, {}, std.sort.asc(i96));
            std.mem.sort(i96, &transport_times, {}, std.sort.asc(i96));
            std.debug.print("PROJECTION_STAGES fixture={s} scenario={s} capture_p99_ns={d} capture_max_ns={d} encode_p99_ns={d} encode_max_ns={d} cache_copy_p99_ns={d} cache_copy_max_ns={d} transport_p99_ns={d} transport_max_ns={d}\n", .{ @tagName(fixture), scenario.name, capture_times[98], capture_times[99], encode_times[98], encode_times[99], cache_times[98], cache_times[99], transport_times[98], transport_times[99] });
            const p99 = durations[98];
            const maximum = durations[99];
            const debug = builtin.mode == .Debug;
            const p99_limit = (if (debug) @as(i96, 16) else 8) * std.time.ns_per_ms;
            const max_limit = (if (debug) @as(i96, 32) else 16) * std.time.ns_per_ms;
            const passed = p99 <= p99_limit and maximum <= max_limit;
            over_budget = over_budget or !passed;
            std.debug.print("PROJECTION_PERFORMANCE {{\"mode\":\"{s}\",\"fixture\":\"{s}\",\"scenario\":\"{s}\",\"samples\":{d},\"bytes\":{d},\"p99_ns\":{d},\"max_ns\":{d},\"passed\":{}}}\n", .{ @tagName(builtin.mode), @tagName(fixture), scenario.name, samples, max_bytes, p99, maximum, passed });
        }
    }
    try std.testing.expect(!over_budget);
}
