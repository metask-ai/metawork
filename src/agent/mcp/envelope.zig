//! Bounded transport routing only. Result/error/schema semantics remain Core's.
const std = @import("std");
const Hash = std.crypto.hash.sha2.Sha256;
pub const Error = error{InvalidEnvelope};

pub const Id = struct {
    value: union(enum) { number: i128, string: [32]u8 },
    raw: []const u8,

    fn eql(self: Id, other: Id) bool {
        return switch (self.value) {
            .number => |number| switch (other.value) {
                .number => |value| number == value,
                else => false,
            },
            .string => |digest| switch (other.value) {
                .string => |value| std.mem.eql(u8, &digest, &value),
                else => false,
            },
        };
    }
};

pub const Message = union(enum) { response, notification, ping: Id };

const Text = struct {
    digest: [32]u8,
    fn eql(self: Text, value: []const u8) bool {
        var digest: [32]u8 = undefined;
        Hash.hash(value, &digest, .{});
        return std.mem.eql(u8, &self.digest, &digest);
    }
};

const Parsed = struct { id: ?Id = null, method: ?Text = null };

pub fn requestId(bytes: []const u8) Error!Id {
    const value = try parse(bytes);
    if (value.method == null) return error.InvalidEnvelope;
    return value.id orelse error.InvalidEnvelope;
}

pub fn classify(bytes: []const u8, expected: Id) Error!Message {
    const value = try parse(bytes);
    if (value.method) |method| {
        const id = value.id orelse return .notification;
        if (method.eql("ping")) return .{ .ping = id };
        return error.InvalidEnvelope;
    }
    const id = value.id orelse return error.InvalidEnvelope;
    if (!id.eql(expected)) return error.InvalidEnvelope;
    return .response;
}

fn parse(bytes: []const u8) Error!Parsed {
    // Scanner stack and decoded fragments never scale with result contents.
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    if ((scanner.next() catch return error.InvalidEnvelope) != .object_begin) return error.InvalidEnvelope;
    var result = Parsed{};
    var version_seen = false;
    var id_seen = false;
    while ((scanner.peekNextTokenType() catch return error.InvalidEnvelope) != .object_end) {
        const key = try text(&scanner);
        if (key.eql("id")) {
            if (id_seen) return error.InvalidEnvelope;
            id_seen = true;
            const start = scanner.cursor;
            switch (scanner.peekNextTokenType() catch return error.InvalidEnvelope) {
                .string => {
                    const value = try text(&scanner);
                    result.id = .{ .value = .{ .string = value.digest }, .raw = literal(bytes[start..scanner.cursor]) };
                },
                .number => {
                    try skip(&scanner);
                    const raw = literal(bytes[start..scanner.cursor]);
                    result.id = .{ .value = .{ .number = std.fmt.parseInt(i128, raw, 10) catch return error.InvalidEnvelope }, .raw = raw };
                },
                else => return error.InvalidEnvelope,
            }
        } else if (key.eql("method")) {
            if (result.method != null) return error.InvalidEnvelope;
            result.method = try text(&scanner);
        } else if (key.eql("jsonrpc")) {
            if (version_seen or !(try text(&scanner)).eql("2.0")) return error.InvalidEnvelope;
            version_seen = true;
        } else try skip(&scanner);
    }
    _ = scanner.next() catch return error.InvalidEnvelope;
    if (!version_seen or (scanner.next() catch return error.InvalidEnvelope) != .end_of_document) return error.InvalidEnvelope;
    return result;
}

fn literal(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n:");
}

fn text(scanner: *std.json.Scanner) Error!Text {
    if ((scanner.peekNextTokenType() catch return error.InvalidEnvelope) != .string) return error.InvalidEnvelope;
    var hash = Hash.init(.{});
    while (true) {
        switch (scanner.next() catch return error.InvalidEnvelope) {
            .string => |value| {
                hash.update(value);
                break;
            },
            .partial_string => |value| hash.update(value),
            .partial_string_escaped_1 => |value| hash.update(&value),
            .partial_string_escaped_2 => |value| hash.update(&value),
            .partial_string_escaped_3 => |value| hash.update(&value),
            .partial_string_escaped_4 => |value| hash.update(&value),
            else => return error.InvalidEnvelope,
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .digest = digest };
}

fn skip(scanner: *std.json.Scanner) Error!void {
    const depth = scanner.stackHeight();
    var nested = false;
    while (true) {
        const token = scanner.next() catch return error.InvalidEnvelope;
        if (scanner.stackHeight() > 1024) return error.InvalidEnvelope;
        switch (token) {
            .object_begin, .array_begin => nested = true,
            .object_end, .array_end => if (nested and scanner.stackHeight() == depth) return else if (!nested) return error.InvalidEnvelope,
            .partial_number, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
            .end_of_document => return error.InvalidEnvelope,
            else => if (!nested) return,
        }
    }
}

pub const Budget = struct {
    io: std.Io,
    deadline_ns: i96,
    discarded_messages: usize = 0,
    discarded_bytes: usize = 0,
    max_discarded_bytes: usize,

    pub fn init(io: std.Io, timeout_ms: u32, max_bytes: usize) Budget {
        return .{ .io = io, .deadline_ns = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms, .max_discarded_bytes = max_bytes };
    }
    pub fn remainingMs(self: Budget) ?u32 {
        const remaining = self.deadline_ns - std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        if (remaining <= 0) return null;
        return @intCast(@min(std.math.maxInt(u32), @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }
    pub fn discard(self: *Budget, bytes: usize) bool {
        if (self.discarded_messages == 128 or bytes > self.max_discarded_bytes - self.discarded_bytes) return false;
        self.discarded_messages += 1;
        self.discarded_bytes += bytes;
        return true;
    }
};

test "envelope routes exact ids and ping without decoding result semantics" {
    const id = try requestId("{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"id\":1}");
    try std.testing.expect((try classify("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"id\":99}}", id)) == .notification);
    try std.testing.expect((try classify("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"nested\":[1,true,null]}}", id)) == .response);
    try std.testing.expectError(error.InvalidEnvelope, classify("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}", id));
    try std.testing.expectError(error.InvalidEnvelope, classify("{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":1}", id));
    const ping = try classify("{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":\"p\\u0069ng\"}", id);
    try std.testing.expectEqualStrings("\"p\\u0069ng\"", ping.ping.raw);
    const string_id = try requestId("{\"jsonrpc\":\"2.0\",\"id\":\"p\\u0069ng\",\"method\":\"tools/list\"}");
    try std.testing.expect((try classify("{\"jsonrpc\":\"2.0\",\"id\":\"ping\",\"result\":{}}", string_id)) == .response);
}

test "notification count bytes and absolute deadline are bounded" {
    var budget = Budget.init(std.testing.io, 1000, 128);
    for (0..128) |_| try std.testing.expect(budget.discard(1));
    try std.testing.expect(!budget.discard(1));
    var short = Budget.init(std.testing.io, 1000, 1);
    try std.testing.expect(!short.discard(2));
    const expired = Budget.init(std.testing.io, 0, 1);
    try std.testing.expect(expired.remainingMs() == null);
}

test "envelope rejects ambiguous routing and bounded scanner nesting" {
    const expected = try requestId("{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":1}");
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"method\":\"other\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":null}",
        "{\"jsonrpc\":\"2.0\",\"id\":1}{}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":" ++ ("[" ** 1025) ++ "0" ++ ("]" ** 1025) ++ "}",
    }) |bytes| try std.testing.expectError(error.InvalidEnvelope, classify(bytes, expected));
}
