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
        notifier: protocol.Notifier,
        interactive: bool,
    ) CoordinateError!Disposition {
        const identity = protocol.Identity.init(artifact_identity, canonical_data_root);
        var lease = switch (compat.tryAcquireLease(io, canonical_data_root) catch {
            return activationFailure(interactive, .startup_failed);
        }) {
            .acquired => |value| value,
            .occupied => switch (try forwardOrFail(
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
            .queue = protocol.ActivationQueue.init(io, identity, notifier),
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
    var queue = protocol.ActivationQueue.init(std.testing.io, identity, .{
        .context = null,
        .notify_fn = ignoreNotify,
    });
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
