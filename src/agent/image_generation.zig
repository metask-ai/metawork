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
        return self.prompt_bytes > 0 and self.prompt_bytes <= production_limits.prompt_bytes and
            self.response_bytes > 0 and self.response_bytes <= production_limits.response_bytes and
            self.image_bytes > 0 and self.image_bytes <= production_limits.image_bytes and self.image_bytes <= self.response_bytes and
            self.result_bytes >= min_result_bytes and self.result_bytes <= 4096 and
            self.sends_per_run > 0 and self.sends_per_run <= production_limits.sends_per_run and
            self.timeout_ms > 0 and self.timeout_ms <= production_limits.timeout_ms and
            self.memory_bytes <= production_limits.memory_bytes and self.memory_bytes >= self.workingBytes();
    }

    pub fn workingBytes(self: Limits) usize {
        // Request, response/JSON scratch, image, and the result allocated before effects.
        return self.prompt_bytes * 7 + 8192 + self.response_bytes * 5 + self.image_bytes + self.result_bytes + @sizeOf(ResultHeader);
    }
};

pub const production_limits: Limits = .{
    .response_bytes = 16 * 1024 * 1024,
    .image_bytes = 10 * 1024 * 1024,
    .memory_bytes = 256 * 1024 * 1024,
    .timeout_ms = 180_000,
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
    commit_fn: *const fn (*anyopaque, []const u8, *const http.Cancellation) OutputResult,
};

pub const OutputFailure = struct {
    pub const Code = enum { unavailable, cancelled, write_failed, cleanup_incomplete };
    code: Code,
    attempted_path: [Receipt.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn init(code: Code, path: []const u8) error{InvalidPath}!OutputFailure {
        const validated = try Receipt.init(path, 0);
        return .{ .code = code, .attempted_path = validated.path, .path_len = validated.path_len };
    }

    pub fn pathView(self: *const OutputFailure) ?[]const u8 {
        return if (self.path_len == 0) null else self.attempted_path[0..self.path_len];
    }
};

pub const OutputResult = union(enum) { saved: Receipt, failed: OutputFailure };

pub const BindingInput = struct {
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

    pub fn init(allocator: std.mem.Allocator, input: BindingInput) !OwnedBinding {
        try validateEndpoint(input.endpoint);
        return copy(allocator, input);
    }

    pub fn initForTesting(allocator: std.mem.Allocator, input: BindingInput) !OwnedBinding {
        try validateTestEndpoint(input.endpoint);
        return copy(allocator, input);
    }

    fn copy(allocator: std.mem.Allocator, input: BindingInput) !OwnedBinding {
        if (input.model.len == 0 or input.model.len > 256 or !std.unicode.utf8ValidateSlice(input.model) or
            input.credential.len == 0 or input.credential.len > 4096 or
            std.mem.indexOfAny(u8, input.credential, "\r\n\x00") != null) return error.InvalidBinding;
        for (input.model) |byte| if (std.ascii.isControl(byte)) return error.InvalidBinding;
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

pub fn validateEndpoint(value: []const u8) error{InvalidBinding}!void {
    if (value.len == 0 or value.len > 2048 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidBinding;
    for (value) |byte| if (std.ascii.isControl(byte) or byte == ' ' or byte == '\\') return error.InvalidBinding;
    const uri = std.Uri.parse(value) catch return error.InvalidBinding;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or uri.port == 0)
        return error.InvalidBinding;
    const host = uri.host orelse return error.InvalidBinding;
    const host_bytes = switch (host) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    if (host_bytes.len == 0 or std.mem.indexOfScalar(u8, host_bytes, '%') != null) return error.InvalidBinding;
    const path = switch (uri.path) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    if (path.len == 0 or path[0] != '/') return error.InvalidBinding;
}

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

pub const Outcome = union(enum) { saved: Receipt, failed: Failure, output_failure: OutputFailure };

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
    return switch (binding.output.commit_fn(binding.output.context, decoded, &call.cancellation)) {
        .saved => |receipt| .{ .saved = receipt },
        .failed => |failure| if (failure.code != .cleanup_incomplete and
            (failure.code == .cancelled or call.cancellation.isRequested()))
            .{ .failed = .outcome_unknown }
        else
            .{ .output_failure = failure },
    };
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

test "production image limits bound every input and allow two maximum working reservations" {
    try std.testing.expect(production_limits.validate());
    try std.testing.expect((Limits{}).validate());
    inline for (.{ "prompt_bytes", "response_bytes", "image_bytes", "memory_bytes", "sends_per_run", "timeout_ms" }) |field| {
        var oversized = production_limits;
        @field(oversized, field) += 1;
        try std.testing.expect(!oversized.validate());
    }
    var budget: Budget = .{ .limit = production_limits.memory_bytes };
    const working = production_limits.workingBytes();
    try std.testing.expect(budget.acquire(working));
    try std.testing.expect(budget.acquire(working));
    try std.testing.expect(!budget.acquire(working));
    budget.release(working);
    try std.testing.expect(budget.acquire(working));
    budget.release(working);
    budget.release(working);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.acquire));
}

test "production target structure and isolated fixture admission remain separate" {
    const Fixture = struct {
        fn output(_: *anyopaque, _: []const u8, _: *const http.Cancellation) OutputResult {
            return .{ .failed = .{ .code = .write_failed } };
        }
    };
    var context: u8 = 0;
    var input: BindingInput = .{
        .endpoint = "https://images.example.test/v1/images/generations",
        .model = "fixture-model",
        .credential = "synthetic-secret",
        .output = .{ .context = &context, .commit_fn = Fixture.output },
    };
    var binding = try OwnedBinding.init(std.testing.allocator, input);
    defer binding.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(input.endpoint, binding.endpoint);
    try std.testing.expectError(error.InvalidBinding, OwnedBinding.initForTesting(std.testing.allocator, input));
    for ([_][]const u8{
        "http://127.0.0.1:1/v1/images/generations",
        "https://user:secret@images.example.test/v1/images/generations",
        "https://images.example.test/v1/images/generations?token=secret",
        "https://images.example.test/v1/images/generations#fragment",
        "https://images.example.test:0/v1/images/generations",
        "https://images.example.test",
        "https://images.example.test\\@other.test/v1/images/generations",
        "https://images%2eexample.test/v1/images/generations",
        "https://images.example.test/\r\n",
    }) |endpoint| try std.testing.expectError(error.InvalidBinding, validateEndpoint(endpoint));
    input.credential = "secret\r\nInjected: yes";
    try std.testing.expectError(error.InvalidBinding, OwnedBinding.init(std.testing.allocator, input));
    input.credential = "synthetic-secret";
    input.model = "model\n";
    try std.testing.expectError(error.InvalidBinding, OwnedBinding.init(std.testing.allocator, input));
}

test "production image codec delivers a PNG beyond fixture byte limits through a fake transport" {
    const allocator = std.testing.allocator;
    const small_png = @embedFile("testdata/generated.png");
    // A legal ancillary text chunk grows a real PNG without storing a large
    // binary fixture or relying on a native decoder. Pixel data stays intact.
    const text_len = 2 * 1024 * 1024;
    const offset = 33;
    const png = try allocator.alloc(u8, small_png.len + text_len + 12);
    defer allocator.free(png);
    @memcpy(png[0..offset], small_png[0..offset]);
    std.mem.writeInt(u32, png[offset..][0..4], text_len, .big);
    @memcpy(png[offset + 4 ..][0..4], "tEXt");
    @memset(png[offset + 8 ..][0..text_len], 'x');
    @memcpy(png[offset + 8 ..][0..8], "Fixture\x00");
    std.mem.writeInt(u32, png[offset + 8 + text_len ..][0..4], std.hash.Crc32.hash(png[offset + 4 ..][0 .. text_len + 4]), .big);
    @memcpy(png[offset + text_len + 12 ..], small_png[offset..]);
    try validatePng(png);
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, png);
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .data = .{.{ .b64_json = encoded }} }, .{});
    defer allocator.free(body);
    try std.testing.expect(body.len > 1024 * 1024);
    try std.testing.expectError(error.InvalidResponse, decode(allocator, body, .{}));
    const Fixture = struct {
        png: []const u8,
        body: []const u8,
        requests: usize = 0,
        writes: usize = 0,
        fn fetch(context: ?*anyopaque, request: http.HttpRequest, _: *const http.Cancellation, buffer: []u8) http.Error!http.Response {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.requests += 1;
            if (!std.mem.eql(u8, request.url, "https://images.example.test/v1/images/generations")) return error.Unexpected;
            var has_auth = false;
            for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                if (!header.sensitive or !std.mem.eql(u8, header.value, "Bearer synthetic-secret")) return error.Unexpected;
                has_auth = true;
            };
            if (!has_auth) return error.Unexpected;
            const parsed = std.json.parseFromSlice(struct { model: []const u8, prompt: []const u8, n: u8, response_format: []const u8 }, std.testing.allocator, request.body, .{}) catch return error.InvalidHttp;
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.model, "fixture-model") or !std.mem.eql(u8, parsed.value.prompt, "a detailed scene") or
                parsed.value.n != 1 or !std.mem.eql(u8, parsed.value.response_format, "b64_json")) return error.Unexpected;
            if (buffer.len < self.body.len) return error.ResponseTooLarge;
            @memcpy(buffer[0..self.body.len], self.body);
            return .{ .status = 200, .body = buffer[0..self.body.len] };
        }
        fn output(context: *anyopaque, bytes: []const u8, _: *const http.Cancellation) OutputResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.writes += 1;
            std.testing.expectEqualSlices(u8, self.png, bytes) catch return .{ .failed = .{ .code = .write_failed } };
            return .{ .saved = Receipt.init("generated-images/fixture.png", bytes.len) catch unreachable };
        }
    };
    var fixture: Fixture = .{ .png = png, .body = body };
    const transport: http.Transport = .{ .context = &fixture, .perform_fn = Fixture.fetch };
    var binding = try OwnedBinding.init(allocator, .{
        .endpoint = "https://images.example.test/v1/images/generations",
        .model = "fixture-model",
        .credential = "synthetic-secret",
        .output = .{ .context = &fixture, .commit_fn = Fixture.output },
    });
    defer binding.deinit(allocator);
    var call: Call = .{ .cancellation = http.Cancellation.init(transport), .deadline_ns = 0, .io = std.testing.io };
    const outcome = perform(allocator, transport, &binding, "a detailed scene", production_limits, &call);
    try std.testing.expectEqual(png.len, outcome.saved.size_bytes);
    try std.testing.expectEqualStrings("generated-images/fixture.png", outcome.saved.pathView());
    try std.testing.expectEqual(@as(usize, 1), fixture.requests);
    try std.testing.expectEqual(@as(usize, 1), fixture.writes);
    try std.testing.expect(call.sent);
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

test "post-send cancellation reports unknown and preserves incomplete cleanup facts" {
    const Fixture = struct {
        const Phase = enum { before_send, response, decoded, output, cleanup };
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
        fn output(context: *anyopaque, _: []const u8, token: *const http.Cancellation) OutputResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.writes += 1;
            @constCast(token).request();
            if (self.phase == .cleanup) return .{ .failed = OutputFailure.init(.cleanup_incomplete, "generated-images/attempted.png") catch unreachable };
            return .{ .failed = .{ .code = .cancelled } };
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
        var binding = try OwnedBinding.initForTesting(std.testing.allocator, .{ .endpoint = "http://127.0.0.1:1/v1/images/generations", .model = "fixture-image", .credential = "synthetic-image-key", .output = .{ .context = &fixture, .commit_fn = Fixture.output } });
        defer binding.deinit(std.testing.allocator);
        var call: Call = .{ .cancellation = http.Cancellation.init(transport), .deadline_ns = 0, .io = std.testing.io };
        if (phase == .before_send) call.cancellation.request();
        const outcome = perform(fixture.allocator(), transport, &binding, "red pixel", .{}, &call);
        if (phase == .cleanup) {
            try std.testing.expectEqual(OutputFailure.Code.cleanup_incomplete, outcome.output_failure.code);
            try std.testing.expectEqualStrings("generated-images/attempted.png", outcome.output_failure.pathView().?);
        } else try std.testing.expectEqual(if (phase == .before_send) Failure.cancelled else Failure.outcome_unknown, outcome.failed);
        try std.testing.expectEqual(@as(usize, if (phase == .before_send) 0 else 1), fixture.requests);
        try std.testing.expectEqual(@as(usize, if (phase == .output or phase == .cleanup) 1 else 0), fixture.writes);
    }
}
