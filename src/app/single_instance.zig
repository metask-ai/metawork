//! Application-owned single-instance activation contract and pending queue.
//!
//! The platform compatibility seam transports these bounded frames. This
//! module validates application identity and owns the only product effect:
//! coalescing a compatible request into one main-window activation.

const std = @import("std");

pub const protocol_revision: u16 = 1;
pub const max_args: usize = 64;
pub const max_arg_bytes: usize = 4 * 1024;
pub const max_args_bytes: usize = 32 * 1024;
pub const max_cwd_bytes: usize = 4 * 1024;
pub const max_frame_bytes: usize = 64 * 1024;

const request_magic = "MWACTV01";
const response_magic = "MWACK001";
const digest_bytes = 32;
pub const request_header_bytes = payload_len_offset + @sizeOf(u32);
pub const response_frame_bytes = 12;

const revision_offset = request_magic.len;
const artifact_offset = revision_offset + @sizeOf(u16);
const root_offset = artifact_offset + digest_bytes;
const argc_offset = root_offset + digest_bytes;
const cwd_len_offset = argc_offset + @sizeOf(u16);
const payload_len_offset = cwd_len_offset + @sizeOf(u16);

pub const Identity = struct {
    artifact: [digest_bytes]u8,
    data_root: [digest_bytes]u8,

    pub fn init(artifact: []const u8, canonical_data_root: []const u8) Identity {
        var result: Identity = undefined;
        std.crypto.hash.sha2.Sha256.hash(artifact, &result.artifact, .{});
        std.crypto.hash.sha2.Sha256.hash(canonical_data_root, &result.data_root, .{});
        return result;
    }
};

pub const Status = enum(u8) {
    accepted = 1,
    stopping = 2,
    incompatible = 3,
    rejected = 4,
};

pub const EncodeError = error{
    TooManyArguments,
    ArgumentTooLarge,
    ArgumentsTooLarge,
    WorkingDirectoryTooLarge,
    InvalidArgument,
    InvalidWorkingDirectory,
    FrameTooLarge,
    BufferTooSmall,
};

pub const DecodeError = error{
    Malformed,
    UnsupportedRevision,
    IdentityMismatch,
    TooManyArguments,
    ArgumentTooLarge,
    ArgumentsTooLarge,
    WorkingDirectoryTooLarge,
    FrameTooLarge,
};

pub const DecodedRequest = struct {
    frame: []const u8,
    cwd: []const u8,
    argc: usize,
    arguments_offset: usize,

    pub fn argument(self: DecodedRequest, wanted: usize) ?[]const u8 {
        if (wanted >= self.argc) return null;
        var cursor = self.arguments_offset;
        for (0..self.argc) |index| {
            const length = readU32(self.frame[cursor..][0..4]);
            cursor += 4;
            const value = self.frame[cursor..][0..length];
            if (index == wanted) return value;
            cursor += length;
        }
        return null;
    }
};

pub fn encodeRequest(
    output: []u8,
    identity: Identity,
    cwd: []const u8,
    args: []const []const u8,
) EncodeError![]const u8 {
    if (args.len > max_args) return error.TooManyArguments;
    if (cwd.len > max_cwd_bytes) return error.WorkingDirectoryTooLarge;
    if (std.mem.indexOfScalar(u8, cwd, 0) != null)
        return error.InvalidWorkingDirectory;

    var args_bytes: usize = 0;
    var payload_bytes = cwd.len;
    for (args) |arg| {
        if (arg.len > max_arg_bytes) return error.ArgumentTooLarge;
        if (std.mem.indexOfScalar(u8, arg, 0) != null)
            return error.InvalidArgument;
        args_bytes = std.math.add(usize, args_bytes, arg.len) catch
            return error.ArgumentsTooLarge;
        if (args_bytes > max_args_bytes) return error.ArgumentsTooLarge;
        payload_bytes = std.math.add(usize, payload_bytes, 4 + arg.len) catch
            return error.FrameTooLarge;
    }
    const frame_bytes = std.math.add(
        usize,
        request_header_bytes,
        payload_bytes,
    ) catch return error.FrameTooLarge;
    if (frame_bytes > max_frame_bytes) return error.FrameTooLarge;
    if (output.len < frame_bytes) return error.BufferTooSmall;

    @memcpy(output[0..request_magic.len], request_magic);
    writeU16(output[revision_offset..][0..2], protocol_revision);
    @memcpy(output[artifact_offset..][0..digest_bytes], &identity.artifact);
    @memcpy(output[root_offset..][0..digest_bytes], &identity.data_root);
    writeU16(output[argc_offset..][0..2], @intCast(args.len));
    writeU16(output[cwd_len_offset..][0..2], @intCast(cwd.len));
    writeU32(output[payload_len_offset..][0..4], @intCast(payload_bytes));

    var cursor: usize = request_header_bytes;
    @memcpy(output[cursor..][0..cwd.len], cwd);
    cursor += cwd.len;
    for (args) |arg| {
        writeU32(output[cursor..][0..4], @intCast(arg.len));
        cursor += 4;
        @memcpy(output[cursor..][0..arg.len], arg);
        cursor += arg.len;
    }
    std.debug.assert(cursor == frame_bytes);
    return output[0..frame_bytes];
}

pub fn decodeRequest(
    frame: []const u8,
    expected: Identity,
) DecodeError!DecodedRequest {
    if (frame.len < request_header_bytes or frame.len > max_frame_bytes)
        return error.FrameTooLarge;
    if (!std.mem.eql(u8, frame[0..request_magic.len], request_magic))
        return error.Malformed;
    if (readU16(frame[revision_offset..][0..2]) != protocol_revision)
        return error.UnsupportedRevision;
    if (!std.mem.eql(
        u8,
        frame[artifact_offset..][0..digest_bytes],
        &expected.artifact,
    ) or !std.mem.eql(
        u8,
        frame[root_offset..][0..digest_bytes],
        &expected.data_root,
    )) return error.IdentityMismatch;

    const argc: usize = readU16(frame[argc_offset..][0..2]);
    const cwd_len: usize = readU16(frame[cwd_len_offset..][0..2]);
    const payload_len: usize = readU32(frame[payload_len_offset..][0..4]);
    if (argc > max_args) return error.TooManyArguments;
    if (cwd_len > max_cwd_bytes) return error.WorkingDirectoryTooLarge;
    if (payload_len != frame.len - request_header_bytes or cwd_len > payload_len)
        return error.Malformed;

    const cwd = frame[request_header_bytes..][0..cwd_len];
    if (std.mem.indexOfScalar(u8, cwd, 0) != null)
        return error.Malformed;
    var cursor = request_header_bytes + cwd_len;
    var args_bytes: usize = 0;
    for (0..argc) |_| {
        if (cursor + 4 > frame.len) return error.Malformed;
        const length: usize = readU32(frame[cursor..][0..4]);
        cursor += 4;
        if (length > max_arg_bytes) return error.ArgumentTooLarge;
        if (cursor + length > frame.len) return error.Malformed;
        if (std.mem.indexOfScalar(u8, frame[cursor..][0..length], 0) != null)
            return error.Malformed;
        args_bytes = std.math.add(usize, args_bytes, length) catch
            return error.ArgumentsTooLarge;
        if (args_bytes > max_args_bytes) return error.ArgumentsTooLarge;
        cursor += length;
    }
    if (cursor != frame.len) return error.Malformed;
    return .{
        .frame = frame,
        .cwd = cwd,
        .argc = argc,
        .arguments_offset = request_header_bytes + cwd_len,
    };
}

pub fn encodeResponse(output: *[response_frame_bytes]u8, status: Status) []const u8 {
    @memcpy(output[0..response_magic.len], response_magic);
    writeU16(output[response_magic.len..][0..2], protocol_revision);
    output[10] = @intFromEnum(status);
    output[11] = 0;
    return output;
}

pub fn decodeResponse(frame: []const u8) DecodeError!Status {
    if (frame.len != response_frame_bytes or
        !std.mem.eql(u8, frame[0..response_magic.len], response_magic))
        return error.Malformed;
    if (readU16(frame[response_magic.len..][0..2]) != protocol_revision)
        return error.UnsupportedRevision;
    return switch (frame[10]) {
        @intFromEnum(Status.accepted) => .accepted,
        @intFromEnum(Status.stopping) => .stopping,
        @intFromEnum(Status.incompatible) => .incompatible,
        @intFromEnum(Status.rejected) => .rejected,
        else => error.Malformed,
    };
}

pub const Notifier = struct {
    context: ?*anyopaque,
    notify_fn: *const fn (?*anyopaque) bool,

    fn notify(self: Notifier) void {
        _ = self.notify_fn(self.context);
    }
};

pub const ActivationQueue = struct {
    io: std.Io,
    identity: Identity,
    notifier: Notifier,
    mutex: std.Io.Mutex = .init,
    pending: bool = false,
    stopping: bool = false,

    pub fn init(io: std.Io, identity: Identity, notifier: Notifier) ActivationQueue {
        return .{ .io = io, .identity = identity, .notifier = notifier };
    }

    pub fn accept(self: *ActivationQueue, frame: []const u8) Status {
        _ = decodeRequest(frame, self.identity) catch |err| return switch (err) {
            error.UnsupportedRevision, error.IdentityMismatch => .incompatible,
            else => .rejected,
        };
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.mutex.unlock(self.io);
            return .stopping;
        }
        self.pending = true;
        self.mutex.unlock(self.io);
        self.notifier.notify();
        return .accepted;
    }

    pub fn drain(self: *ActivationQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.pending;
        self.pending = false;
        return result;
    }

    pub fn stop(self: *ActivationQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stopping = true;
        self.pending = false;
    }
};

fn writeU16(output: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, output, value, .little);
}

fn writeU32(output: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, output, value, .little);
}

fn readU16(input: *const [2]u8) u16 {
    return std.mem.readInt(u16, input, .little);
}

fn readU32(input: *const [4]u8) u32 {
    return std.mem.readInt(u32, input, .little);
}

fn ignoreNotify(_: ?*anyopaque) bool {
    return true;
}

test "activation request round trips bounded argv and cwd" {
    const identity = Identity.init("com.metask.metawork.dev", "C:/Data/MetaWork");
    var storage: [max_frame_bytes]u8 = undefined;
    const frame = try encodeRequest(
        &storage,
        identity,
        "C:/workspace",
        &.{ "metawork.exe", "--example", "value" },
    );
    const decoded = try decodeRequest(frame, identity);
    try std.testing.expectEqualStrings("C:/workspace", decoded.cwd);
    try std.testing.expectEqual(@as(usize, 3), decoded.argc);
    try std.testing.expectEqualStrings("metawork.exe", decoded.argument(0).?);
    try std.testing.expectEqualStrings("--example", decoded.argument(1).?);
    try std.testing.expectEqualStrings("value", decoded.argument(2).?);
    try std.testing.expect(decoded.argument(3) == null);
}

test "activation request header has no implicit padding" {
    try std.testing.expectEqual(@as(usize, 82), request_header_bytes);
    try std.testing.expectEqual(
        payload_len_offset + @sizeOf(u32),
        request_header_bytes,
    );
    const identity = Identity.init("development", "C:/Data/MetaWork");
    var storage = [_]u8{0xa5} ** max_frame_bytes;
    const frame = try encodeRequest(&storage, identity, "C:/", &.{"metawork"});
    try std.testing.expectEqual(
        request_header_bytes + "C:/".len + @sizeOf(u32) + "metawork".len,
        frame.len,
    );
}

test "activation request rejects revision identity and malformed payload" {
    const identity = Identity.init("development", "C:/Data/MetaWork");
    var storage: [max_frame_bytes]u8 = undefined;
    const frame = try encodeRequest(&storage, identity, "C:/", &.{"metawork"});

    var wrong_revision = storage;
    writeU16(wrong_revision[revision_offset..][0..2], protocol_revision + 1);
    try std.testing.expectError(
        error.UnsupportedRevision,
        decodeRequest(wrong_revision[0..frame.len], identity),
    );
    try std.testing.expectError(
        error.IdentityMismatch,
        decodeRequest(frame, Identity.init("automation", "C:/Data/MetaWork")),
    );
    try std.testing.expectError(
        error.Malformed,
        decodeRequest(frame[0 .. frame.len - 1], identity),
    );
}

test "activation queue acknowledges only compatible requests and coalesces" {
    const identity = Identity.init("development", "C:/Data/MetaWork");
    var queue = ActivationQueue.init(std.testing.io, identity, .{
        .context = null,
        .notify_fn = ignoreNotify,
    });
    var storage: [max_frame_bytes]u8 = undefined;
    const frame = try encodeRequest(&storage, identity, "C:/", &.{"metawork"});
    try std.testing.expectEqual(Status.accepted, queue.accept(frame));
    try std.testing.expectEqual(Status.accepted, queue.accept(frame));
    try std.testing.expect(queue.drain());
    try std.testing.expect(!queue.drain());

    queue.stop();
    try std.testing.expectEqual(Status.stopping, queue.accept(frame));
    try std.testing.expectEqual(
        Status.incompatible,
        queue.accept(try encodeRequest(
            &storage,
            Identity.init("automation", "C:/Data/MetaWork"),
            "C:/",
            &.{"metawork"},
        )),
    );
}

test "activation response round trips exact status" {
    inline for (std.meta.tags(Status)) |status| {
        var storage: [response_frame_bytes]u8 = undefined;
        try std.testing.expectEqual(status, try decodeResponse(encodeResponse(&storage, status)));
    }
}
