//! Bounded Images Generation codec and injected effects. No service discovery.
const std = @import("std");
const http = @import("agent_http_transport");

pub const max_active_calls = 4;
// At most six JSON bytes per path byte, plus fixed fields and a usize decimal.
pub const min_result_bytes = Receipt.max_path_bytes * 6 + 128;
pub const ResultHeader = struct { allocation_len: usize };
pub const Limits = struct {
    prompt_bytes: usize = 16 * 1024,
    response_bytes: usize = 128 * 1024,
    image_bytes: usize = 64 * 1024,
    result_bytes: usize = min_result_bytes,
    memory_bytes: usize = 4 * 1024 * 1024,
    sends_per_run: usize = 4,
    timeout_ms: u32 = 10_000,

    pub fn validate(self: Limits) bool {
        return self.prompt_bytes > 0 and self.prompt_bytes <= 16 * 1024 and
            self.response_bytes > 0 and self.response_bytes <= 1024 * 1024 and
            self.image_bytes > 0 and self.image_bytes <= self.response_bytes and
            self.result_bytes >= min_result_bytes and self.result_bytes <= 4096 and
            self.sends_per_run > 0 and self.timeout_ms > 0 and self.memory_bytes >= self.workingBytes();
    }

    pub fn workingBytes(self: Limits) usize {
        // Request, response/JSON scratch, image, and the result allocated before effects.
        return self.prompt_bytes * 7 + 8192 + self.response_bytes * 5 + self.image_bytes + self.result_bytes + @sizeOf(ResultHeader);
    }
};

pub const Failure = enum {
    unavailable,
    invalid_arguments,
    capacity,
    cancelled,
    outcome_unknown,
    provider_rejected,
    invalid_response,
    unsupported_output,
    output_failed,
};

pub const Receipt = struct {
    pub const max_path_bytes = 512;
    path: [max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    size_bytes: usize,

    pub fn init(path: []const u8, size: usize) error{InvalidPath}!Receipt {
        if (path.len == 0 or path.len > max_path_bytes or path[0] == '/' or
            std.mem.indexOfAny(u8, path, "\\:\x00\r\n") != null or !std.unicode.utf8ValidateSlice(path))
            return error.InvalidPath;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
                return error.InvalidPath;
        }
        var result: Receipt = .{ .size_bytes = size };
        @memcpy(result.path[0..path.len], path);
        result.path_len = path.len;
        return result;
    }

    pub fn pathView(self: *const Receipt) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const Output = struct {
    context: *anyopaque,
    /// A receipt is a committed fact, even if cancellation raced with commit.
    commit_fn: *const fn (*anyopaque, []const u8, *const http.Cancellation) anyerror!Receipt,
};

pub const TestBinding = struct {
    endpoint: []const u8,
    model: []const u8,
    credential: []const u8,
    output: Output,
};

pub const OwnedBinding = struct {
    endpoint: []u8,
    model: []u8,
    credential: []u8,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, input: TestBinding) !OwnedBinding {
        try validateTestEndpoint(input.endpoint);
        if (input.model.len == 0 or input.model.len > 256 or !std.unicode.utf8ValidateSlice(input.model) or
            input.credential.len == 0 or input.credential.len > 4096 or
            std.mem.indexOfAny(u8, input.credential, "\r\n\x00") != null) return error.InvalidBinding;
        const endpoint = try allocator.dupe(u8, input.endpoint);
        errdefer allocator.free(endpoint);
        const model = try allocator.dupe(u8, input.model);
        errdefer allocator.free(model);
        const credential = try allocator.dupe(u8, input.credential);
        return .{ .endpoint = endpoint, .model = model, .credential = credential, .output = input.output };
    }

    pub fn deinit(self: *OwnedBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.endpoint);
        allocator.free(self.model);
        std.crypto.secureZero(u8, self.credential);
        allocator.free(self.credential);
        self.* = undefined;
    }
};

pub fn validateTestEndpoint(value: []const u8) !void {
    // Only the isolated initializer consumes this target. Product init has no override.
    if (value.len > 512) return error.InvalidBinding;
    const prefix = "http://127.0.0.1:";
    const suffix = "/v1/images/generations";
    if (!std.mem.startsWith(u8, value, prefix) or !std.mem.endsWith(u8, value, suffix))
        return error.InvalidBinding;
    const port_text = value[prefix.len .. value.len - suffix.len];
    if (port_text.len == 0) return error.InvalidBinding;
    for (port_text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidBinding;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidBinding;
    if (port == 0) return error.InvalidBinding;
}

pub const Budget = struct {
    limit: usize,
    used: std.atomic.Value(usize) = .init(0),

    pub fn acquire(self: *Budget, amount: usize) bool {
        var old = self.used.load(.acquire);
        while (old <= self.limit and amount <= self.limit - old) {
            old = self.used.cmpxchgWeak(old, old + amount, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    pub fn release(self: *Budget, amount: usize) void {
        std.debug.assert(self.used.fetchSub(amount, .acq_rel) >= amount);
    }
};

pub const Call = struct {
    cancellation: http.Cancellation,
    finished: std.atomic.Value(bool) = .init(false),
    deadline_ns: i96,
    io: std.Io,
    sent: bool = false,

    pub fn watchdog(self: *Call) void {
        while (std.Io.Timestamp.now(self.io, .awake).nanoseconds < self.deadline_ns) {
            if (self.finished.load(.acquire) or self.cancellation.isRequested()) return;
            std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, self.io) catch break;
        }
        if (!self.finished.load(.acquire)) self.cancellation.request();
    }
};

pub const Outcome = union(enum) { saved: Receipt, failed: Failure };

pub fn perform(allocator: std.mem.Allocator, network: http.Transport, binding: *const OwnedBinding, prompt: []const u8, limits: Limits, call: *Call) Outcome {
    if (call.cancellation.isRequested()) return .{ .failed = .cancelled };
    const request = std.json.Stringify.valueAlloc(allocator, .{
        .model = binding.model,
        .prompt = prompt,
        .n = @as(u8, 1),
        .response_format = "b64_json",
    }, .{}) catch return .{ .failed = .capacity };
    defer allocator.free(request);
    const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{binding.credential}) catch return .{ .failed = .capacity };
    defer {
        std.crypto.secureZero(u8, bearer);
        allocator.free(bearer);
    }
    const buffer = allocator.alloc(u8, limits.response_bytes) catch return .{ .failed = .capacity };
    defer {
        std.crypto.secureZero(u8, buffer);
        allocator.free(buffer);
    }
    if (call.cancellation.isRequested()) return .{ .failed = .cancelled };
    call.sent = true;
    const response = network.perform(.{
        .url = binding.endpoint,
        .headers = &.{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "Authorization", .value = bearer, .sensitive = true } },
        .body = request,
    }, &call.cancellation, buffer) catch return .{ .failed = .outcome_unknown };
    if (call.cancellation.isRequested()) return .{ .failed = .outcome_unknown };
    if (response.status < 200 or response.status >= 300) return .{ .failed = .provider_rejected };
    const decoded = decode(allocator, response.body, limits) catch |err| return .{ .failed = if (call.cancellation.isRequested()) .outcome_unknown else switch (err) {
        error.UnsupportedOutput => .unsupported_output,
        else => .invalid_response,
    } };
    defer allocator.free(decoded);
    if (call.cancellation.isRequested()) return .{ .failed = .outcome_unknown };
    const receipt = binding.output.commit_fn(binding.output.context, decoded, &call.cancellation) catch |err|
        return .{ .failed = if (err == error.Cancelled or err == error.Canceled or call.cancellation.isRequested()) .outcome_unknown else .output_failed };
    return .{ .saved = receipt };
}

pub fn decode(allocator: std.mem.Allocator, body: []const u8, limits: Limits) ![]u8 {
    if (body.len > limits.response_bytes) return error.InvalidResponse;
    const scratch = try allocator.alloc(u8, limits.response_bytes * 4);
    defer allocator.free(scratch);
    var arena = std.heap.FixedBufferAllocator.init(scratch);
    const Wire = struct { data: []const struct { b64_json: ?[]const u8 = null, url: ?[]const u8 = null } };
    const wire = try std.json.parseFromSliceLeaky(Wire, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.response_bytes,
    });
    if (wire.data.len != 1) return error.InvalidResponse;
    const item = wire.data[0];
    if (item.url != null) return error.UnsupportedOutput;
    const encoded = item.b64_json orelse return error.InvalidResponse;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    if (size == 0 or size > limits.image_bytes) return error.InvalidResponse;
    const image = try allocator.alloc(u8, size);
    errdefer allocator.free(image);
    try std.base64.standard.Decoder.decode(image, encoded);
    try validatePng(image);
    return image;
}

fn validatePng(bytes: []const u8) !void {
    if (bytes.len < 45 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidResponse;
    var offset: usize = 8;
    var saw_data = false;
    while (bytes.len - offset >= 12) {
        const len: usize = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (len > bytes.len - offset - 12) return error.InvalidResponse;
        const kind = bytes[offset + 4 ..][0..4];
        const payload = bytes[offset + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. len + 4]) != crc) return error.InvalidResponse;
        if (offset == 8) {
            if (!std.mem.eql(u8, kind, "IHDR") or len != 13) return error.InvalidResponse;
            const w = std.mem.readInt(u32, payload[0..4], .big);
            const h = std.mem.readInt(u32, payload[4..8], .big);
            if (w == 0 or h == 0 or @as(u64, w) * h > 16_000_000) return error.InvalidResponse;
        } else if (std.mem.eql(u8, kind, "IHDR")) return error.InvalidResponse;
        if (std.mem.eql(u8, kind, "IDAT")) saw_data = true;
        offset += len + 12;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (len != 0 or !saw_data or offset != bytes.len) return error.InvalidResponse;
            return;
        }
    }
    return error.InvalidResponse;
}

test "fixture targets cannot escape the loopback image endpoint" {
    try validateTestEndpoint("http://127.0.0.1:12345/v1/images/generations");
    for ([_][]const u8{ "https://app.metask-ai.com/v1/images/generations", "http://127.0.0.1:0/v1/images/generations", "http://127.0.0.1:10/elsewhere", "http://127.0.0.1:10@evil/v1/images/generations" }) |value|
        try std.testing.expectError(error.InvalidBinding, validateTestEndpoint(value));
}

test "image receipts cannot choose a different workspace" {
    for ([_][]const u8{ "../other.png", "/absolute.png", "C:\\image.png", "a//image.png", "./image.png" }) |path|
        try std.testing.expectError(error.InvalidPath, Receipt.init(path, 1));
    _ = try Receipt.init("generated/images/a.png", 12);
}

test "image response decoding preserves PNG bytes and rejects malformed or redirected output" {
    const allocator = std.testing.allocator;
    const png = @embedFile("testdata/generated.png");
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, png);
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .data = .{.{ .b64_json = encoded }} }, .{});
    defer allocator.free(body);
    const decoded = try decode(allocator, body, .{});
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, png, decoded);
    try std.testing.expectError(error.UnsupportedOutput, decode(allocator, "{\"data\":[{\"url\":\"https://other.test/image.png\"}]}", .{}));
    try std.testing.expectError(error.InvalidResponse, decode(allocator, "{\"data\":[]}", .{}));
    var broken = try allocator.dupe(u8, png);
    defer allocator.free(broken);
    broken[20] ^= 1;
    try std.testing.expectError(error.InvalidResponse, validatePng(broken));
    try std.testing.expectError(error.InvalidResponse, validatePng(png[0 .. png.len - 1]));
}

test "cancellation before send is cancelled and every post-send cancellation is outcome unknown" {
    const Fixture = struct {
        const Phase = enum { before_send, response, decoded, output };
        body: []const u8,
        phase: Phase,
        decode_token: ?*http.Cancellation = null,
        requests: usize = 0,
        writes: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const bytes = std.testing.allocator.rawAlloc(len, alignment, ra);
            if (len == @embedFile("testdata/generated.png").len) if (self.decode_token) |token| {
                self.decode_token = null;
                token.request();
            };
            return bytes;
        }
        fn resize(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
            return std.testing.allocator.rawResize(bytes, alignment, len, ra);
        }
        fn remap(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawRemap(bytes, alignment, len, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
        fn fetch(context: ?*anyopaque, _: http.HttpRequest, token: *const http.Cancellation, buffer: []u8) http.Error!http.Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.requests += 1;
            if (self.phase == .response) @constCast(token).request();
            if (self.phase == .decoded) self.decode_token = @constCast(token);
            @memcpy(buffer[0..self.body.len], self.body);
            return .{ .status = 200, .body = buffer[0..self.body.len] };
        }
        fn output(context: *anyopaque, _: []const u8, token: *const http.Cancellation) !Receipt {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.writes += 1;
            @constCast(token).request();
            return error.Cancelled;
        }
    };
    const png = @embedFile("testdata/generated.png");
    var encoded: [std.base64.standard.Encoder.calcSize(png.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, png);
    const body = try std.json.Stringify.valueAlloc(std.testing.allocator, .{ .data = .{.{ .b64_json = &encoded }} }, .{});
    defer std.testing.allocator.free(body);
    for (std.enums.values(Fixture.Phase)) |phase| {
        var fixture: Fixture = .{ .phase = phase, .body = body };
        const transport: http.Transport = .{ .context = &fixture, .perform_fn = Fixture.fetch };
        var binding = try OwnedBinding.init(std.testing.allocator, .{ .endpoint = "http://127.0.0.1:1/v1/images/generations", .model = "fixture-image", .credential = "synthetic-image-key", .output = .{ .context = &fixture, .commit_fn = Fixture.output } });
        defer binding.deinit(std.testing.allocator);
        var call: Call = .{ .cancellation = http.Cancellation.init(transport), .deadline_ns = 0, .io = std.testing.io };
        if (phase == .before_send) call.cancellation.request();
        const outcome = perform(fixture.allocator(), transport, &binding, "red pixel", .{}, &call);
        try std.testing.expectEqual(if (phase == .before_send) Failure.cancelled else Failure.outcome_unknown, outcome.failed);
        try std.testing.expectEqual(@as(usize, if (phase == .before_send) 0 else 1), fixture.requests);
        try std.testing.expectEqual(@as(usize, if (phase == .output) 1 else 0), fixture.writes);
    }
}
