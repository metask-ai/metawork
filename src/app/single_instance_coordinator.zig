//! Application lifecycle owner for process-wide single-instance coordination.

const std = @import("std");
const protocol = @import("single_instance.zig");
const compat = @import("metawork_app_single_instance_compat");

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
    var response_storage: [compat.max_transport_response_bytes]u8 = undefined;
    const response_len = compat.forward(
        allocator,
        canonical_data_root,
        request,
        &response_storage,
    ) catch return activationFailure(interactive, .primary_unresponsive);
    const status = protocol.decodeResponse(response_storage[0..response_len]) catch
        return activationFailure(interactive, .incompatible);
    return switch (status) {
        .accepted => .secondary,
        .incompatible => activationFailure(interactive, .incompatible),
        .rejected => activationFailure(interactive, .rejected),
        .stopping => waitForPrimaryExit(io, canonical_data_root, interactive),
    };
}

fn waitForPrimaryExit(
    io: std.Io,
    canonical_data_root: []const u8,
    interactive: bool,
) CoordinateError!ExistingResult {
    for (0..60) |_| {
        io.sleep(.fromMilliseconds(50), .awake) catch
            return activationFailure(interactive, .primary_unresponsive);
        switch (compat.tryAcquireLease(io, canonical_data_root) catch continue) {
            .occupied => continue,
            .acquired => |lease| return .{ .acquired = lease },
        }
    }
    return activationFailure(interactive, .primary_unresponsive);
}

fn activationFailure(interactive: bool, failure: compat.Failure) CoordinateError {
    std.log.err("single-instance activation failed: {s}", .{@tagName(failure)});
    if (interactive) compat.reportFailure(failure);
    return error.ActivationFailed;
}
