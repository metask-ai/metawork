//! Application lifecycle owner for process-wide single-instance coordination.

const std = @import("std");
const protocol = @import("single_instance.zig");
const compat = @import("metawork_app_single_instance_compat");

const handoff_attempts = 60;
const handoff_retry_interval_ms = 50;

pub const Disposition = enum { primary, secondary };

pub const CoordinateError = error{
    ActivationFailed,
    ArgumentsUnavailable,
    DevelopmentInstanceAlreadyRunning,
} || protocol.EncodeError || std.mem.Allocator.Error ||
    std.process.CurrentPathError || std.process.Args.Iterator.InitError;

/// `init` must run on the final stable address because the listener retains a
/// pointer to the Application-owned activation queue.
pub const Coordinator = struct {
    queue: protocol.ActivationQueue,
    lease: compat.Lease,
    server: compat.Server,
    started: bool = false,

    pub fn init(
        self: *Coordinator,
        io: std.Io,
        allocator: std.mem.Allocator,
        args: std.process.Args,
        canonical_data_root: []const u8,
        artifact_identity: []const u8,
        interactive: bool,
        require_primary: bool,
    ) CoordinateError!Disposition {
        const identity = protocol.Identity.init(artifact_identity, canonical_data_root);
        var lease = switch (compat.tryAcquireLease(io, canonical_data_root) catch {
            return activationFailure(interactive, .startup_failed);
        }) {
            .acquired => |value| value,
            .occupied => if (require_primary) return error.DevelopmentInstanceAlreadyRunning else switch (try forwardOrFail(
                io,
                allocator,
                args,
                canonical_data_root,
                identity,
                interactive,
            )) {
                .secondary => return .secondary,
                .acquired => |value| value,
            },
        };
        errdefer lease.deinit();

        self.* = .{
            .queue = protocol.ActivationQueue.init(io, identity),
            .lease = lease,
            .server = undefined,
        };
        self.server = compat.Server.init(allocator, canonical_data_root, .{
            .state = &self.queue,
            .handle_fn = handleActivation,
        }) catch return activationFailure(interactive, .startup_failed);
        self.started = true;
        return .primary;
    }

    pub fn bindWakeAndDrain(self: *Coordinator, notifier: protocol.Notifier) bool {
        if (!self.started) return false;
        return self.queue.bindWakeAndDrain(notifier);
    }

    pub fn drain(self: *Coordinator) bool {
        if (!self.started) return false;
        return self.queue.drain();
    }

    pub fn stopIngress(self: *Coordinator) void {
        if (!self.started) return;
        self.queue.stop();
        self.server.stop();
    }

    pub fn deinit(self: *Coordinator) void {
        if (!self.started) return;
        self.stopIngress();
        self.server.deinit();
        self.lease.deinit();
        self.started = false;
    }
};

fn handleActivation(state: *anyopaque, request: []const u8, response: []u8) usize {
    const queue: *protocol.ActivationQueue = @ptrCast(@alignCast(state));
    if (response.len < protocol.response_frame_bytes) return 0;
    const output: *[protocol.response_frame_bytes]u8 =
        response[0..protocol.response_frame_bytes];
    return protocol.encodeResponse(output, queue.accept(request)).len;
}

const ExistingResult = union(enum) {
    secondary,
    acquired: compat.Lease,
};

fn forwardOrFail(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: std.process.Args,
    canonical_data_root: []const u8,
    identity: protocol.Identity,
    interactive: bool,
) CoordinateError!ExistingResult {
    var iterator = try args.iterateAllocator(allocator);
    defer iterator.deinit();
    var argument_storage: [protocol.max_args][]const u8 = undefined;
    var argument_count: usize = 0;
    while (iterator.next()) |argument| {
        if (argument_count == argument_storage.len) return error.TooManyArguments;
        argument_storage[argument_count] = argument;
        argument_count += 1;
    }
    var cwd_storage: [protocol.max_cwd_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_storage) catch
        return error.ArgumentsUnavailable;
    var request_storage: [protocol.max_frame_bytes]u8 = undefined;
    const request = try protocol.encodeRequest(
        &request_storage,
        identity,
        cwd_storage[0..cwd_len],
        argument_storage[0..argument_count],
    );
    return competeForOwnership(
        io,
        allocator,
        canonical_data_root,
        request,
        interactive,
    );
}

fn competeForOwnership(
    io: std.Io,
    allocator: std.mem.Allocator,
    canonical_data_root: []const u8,
    request: []const u8,
    interactive: bool,
) CoordinateError!ExistingResult {
    var response_storage: [compat.max_transport_response_bytes]u8 = undefined;
    competition: for (0..handoff_attempts) |attempt| {
        switch (compat.tryAcquireLease(io, canonical_data_root) catch {
            return activationFailure(interactive, .startup_failed);
        }) {
            .occupied => {},
            .acquired => |lease| return .{ .acquired = lease },
        }

        const response_len = compat.forward(
            allocator,
            canonical_data_root,
            request,
            &response_storage,
        ) catch |err| switch (err) {
            error.EndpointUnavailable => {
                if (attempt + 1 == handoff_attempts) break :competition;
                io.sleep(.fromMilliseconds(handoff_retry_interval_ms), .awake) catch
                    return activationFailure(interactive, .primary_unresponsive);
                continue :competition;
            },
            else => return activationFailure(interactive, .primary_unresponsive),
        };
        const status = protocol.decodeResponse(response_storage[0..response_len]) catch
            return activationFailure(interactive, .incompatible);
        switch (status) {
            .accepted => return .secondary,
            .incompatible => return activationFailure(interactive, .incompatible),
            .rejected => return activationFailure(interactive, .rejected),
            .stopping => {
                if (attempt + 1 == handoff_attempts) break :competition;
                io.sleep(.fromMilliseconds(handoff_retry_interval_ms), .awake) catch
                    return activationFailure(interactive, .primary_unresponsive);
            },
        }
    }
    return activationFailure(interactive, .primary_unresponsive);
}

const DelayedLeaseRelease = struct {
    io: std.Io,
    lease: *compat.Lease,

    fn run(self: *@This()) void {
        self.io.sleep(.fromMilliseconds(100), .awake) catch return;
        self.lease.deinit();
    }
};

fn ignoreNotify(_: ?*anyopaque) bool {
    return true;
}

const DelayedEndpoint = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    queue: *protocol.ActivationQueue,
    server: ?compat.Server = null,

    fn run(self: *@This()) void {
        self.io.sleep(.fromMilliseconds(100), .awake) catch return;
        self.server = compat.Server.init(self.allocator, self.root, .{
            .state = self.queue,
            .handle_fn = handleActivation,
        }) catch null;
    }
};

test "single-instance coordinator reacquires a lease after ingress closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var held = switch (try compat.tryAcquireLease(std.testing.io, root)) {
        .acquired => |lease| lease,
        .occupied => return error.UnexpectedOccupiedLease,
    };
    var delayed = DelayedLeaseRelease{ .io = std.testing.io, .lease = &held };
    const thread = try std.Thread.spawn(.{}, DelayedLeaseRelease.run, .{&delayed});
    defer thread.join();

    const identity = protocol.Identity.init("development", root);
    var request_storage: [protocol.max_frame_bytes]u8 = undefined;
    const request = try protocol.encodeRequest(
        &request_storage,
        identity,
        root,
        &.{"metawork"},
    );
    var acquired = switch (try competeForOwnership(
        std.testing.io,
        std.testing.allocator,
        root,
        request,
        false,
    )) {
        .acquired => |lease| lease,
        .secondary => return error.UnexpectedSecondary,
    };
    acquired.deinit();
}

test "single-instance coordinator development startup rejects an existing owner without activation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var held = switch (try compat.tryAcquireLease(std.testing.io, root)) {
        .acquired => |lease| lease,
        .occupied => return error.UnexpectedOccupiedLease,
    };
    defer held.deinit();
    var coordinator: Coordinator = undefined;
    try std.testing.expectError(error.DevelopmentInstanceAlreadyRunning, coordinator.init(
        std.testing.io,
        std.testing.allocator,
        .{ .vector = &.{} },
        root,
        "development",
        false,
        true,
    ));
}

test "single-instance coordinator forwards after a cold-start endpoint appears" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var held = switch (try compat.tryAcquireLease(std.testing.io, root)) {
        .acquired => |lease| lease,
        .occupied => return error.UnexpectedOccupiedLease,
    };
    defer held.deinit();
    const identity = protocol.Identity.init("development", root);
    var queue = protocol.ActivationQueue.init(std.testing.io, identity);
    try std.testing.expect(!queue.bindWakeAndDrain(.{
        .context = null,
        .notify_fn = ignoreNotify,
    }));
    var delayed = DelayedEndpoint{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .root = root,
        .queue = &queue,
    };
    const thread = try std.Thread.spawn(.{}, DelayedEndpoint.run, .{&delayed});
    defer {
        thread.join();
        if (delayed.server) |*server| server.deinit();
    }

    var request_storage: [protocol.max_frame_bytes]u8 = undefined;
    const request = try protocol.encodeRequest(
        &request_storage,
        identity,
        root,
        &.{"metawork"},
    );
    try std.testing.expect((try competeForOwnership(
        std.testing.io,
        std.testing.allocator,
        root,
        request,
        false,
    )) == .secondary);
}

test "single-instance coordinator fails closed while an owner stays unreachable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);
    var held = switch (try compat.tryAcquireLease(std.testing.io, root)) {
        .acquired => |lease| lease,
        .occupied => return error.UnexpectedOccupiedLease,
    };
    defer held.deinit();
    const identity = protocol.Identity.init("development", root);
    var request_storage: [protocol.max_frame_bytes]u8 = undefined;
    const request = try protocol.encodeRequest(
        &request_storage,
        identity,
        root,
        &.{"metawork"},
    );
    try std.testing.expectError(
        error.ActivationFailed,
        competeForOwnership(
            std.testing.io,
            std.testing.allocator,
            root,
            request,
            false,
        ),
    );
}

fn activationFailure(interactive: bool, failure: compat.Failure) CoordinateError {
    std.log.warn("single-instance activation failed: {s}", .{@tagName(failure)});
    if (interactive) compat.reportFailure(failure);
    return error.ActivationFailed;
}

const WakeTransportTest = struct {
    var calls: std.atomic.Value(usize) = .init(0);
    var fail: std.atomic.Value(bool) = .init(true);
    var hold: std.atomic.Value(bool) = .init(false);
    var entered: std.atomic.Value(bool) = .init(false);

    fn wake(_: ?*anyopaque) anyerror!void {
        _ = calls.fetchAdd(1, .monotonic);
        entered.store(true, .release);
        while (hold.load(.acquire)) std.Thread.yield() catch {};
        if (fail.load(.acquire)) return error.InjectedWakeFailure;
    }

    fn forward(root: []const u8, request: []const u8) !protocol.Status {
        var response: [compat.max_transport_response_bytes]u8 = undefined;
        const length = try compat.forward(std.heap.c_allocator, root, request, &response);
        return protocol.decodeResponse(response[0..length]);
    }

    const Forward = struct {
        root: []const u8,
        request: []const u8,
        result: anyerror!protocol.Status = error.NotRun,
        fn run(self: *@This()) void {
            self.result = forward(self.root, self.request);
        }
    };
    const Stop = struct {
        coordinator: *Coordinator,
        completed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.coordinator.stopIngress();
            self.completed.store(true, .release);
        }
    };
};

test "single-instance coordinator reports SDK wake failure over real transport and joins before teardown" {
    const T = WakeTransportTest;
    const native_sdk = @import("native_sdk");
    const platform = @import("platform.zig");
    T.calls.store(0, .monotonic);
    T.fail.store(true, .release);
    T.hold.store(false, .release);
    T.entered.store(false, .release);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.runtime.options.platform.services.wake_fn = T.wake;
    var adapter = platform.Adapter.init(std.testing.io, std.Thread.getCurrentId());
    defer adapter.deinit();
    var coordinator: Coordinator = undefined;
    try std.testing.expectEqual(Disposition.primary, try coordinator.init(std.testing.io, std.testing.allocator, .{ .vector = &.{} }, root, "wake-test", false, false));
    // Declare platform cleanup first: ingress must join before services clear.
    defer adapter.stop(&harness.runtime);
    defer coordinator.deinit();
    const identity = protocol.Identity.init("wake-test", root);
    var storage: [protocol.max_frame_bytes]u8 = undefined;
    const request = try protocol.encodeRequest(&storage, identity, root, &.{"metawork"});
    try std.testing.expectEqual(protocol.Status.accepted, try T.forward(root, request));
    try std.testing.expectEqual(@as(usize, 0), T.calls.load(.monotonic));
    try adapter.start(&harness.runtime);
    try std.testing.expect(coordinator.bindWakeAndDrain(.{ .context = &adapter, .notify_fn = platform.Adapter.notifyMainLoop }));
    try std.testing.expect(!coordinator.drain());
    try std.testing.expectEqual(protocol.Status.rejected, try T.forward(root, request));
    try std.testing.expectEqual(@as(usize, 1), T.calls.load(.monotonic));
    try std.testing.expect(!coordinator.drain());
    T.fail.store(false, .release);
    try std.testing.expectEqual(protocol.Status.accepted, try T.forward(root, request));
    try std.testing.expect(coordinator.drain());
    try std.testing.expect(!coordinator.drain());

    T.fail.store(true, .release);
    T.hold.store(true, .release);
    T.entered.store(false, .release);
    var forward: T.Forward = .{ .root = root, .request = request };
    {
        const forward_thread = try std.Thread.spawn(.{}, T.Forward.run, .{&forward});
        defer forward_thread.join();
        defer T.hold.store(false, .release);
        while (!T.entered.load(.acquire)) std.Thread.yield() catch {};
        var stop: T.Stop = .{ .coordinator = &coordinator };
        {
            const stop_thread = try std.Thread.spawn(.{}, T.Stop.run, .{&stop});
            defer stop_thread.join();
            defer T.hold.store(false, .release);
            while (true) {
                coordinator.queue.mutex.lockUncancelable(std.testing.io);
                const stopping = coordinator.queue.stopping;
                coordinator.queue.mutex.unlock(std.testing.io);
                if (stopping) break;
                std.Thread.yield() catch {};
            }
            try std.testing.expect(!stop.completed.load(.acquire));
            try std.testing.expect(adapter.services() != null);
        }
    }
    // stopIngress has joined the callback; the transport response is now fixed.
    try std.testing.expectEqual(protocol.Status.stopping, try forward.result);
    try std.testing.expect(!coordinator.drain());
}
