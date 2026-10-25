const std = @import("std");
const transport = @import("agent_http_transport");
const types = @import("types.zig");

pub const Error = error{
    OutOfMemory,
    ResourceLimit,
    MalformedResponse,
    UnsupportedResponse,
};

pub const max_headers: usize = 6;

pub const EncodedRequest = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    body: []u8,
    headers: [max_headers]transport.Header = undefined,
    owned_header_values: [max_headers][]u8 = undefined,
    header_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        url: []const u8,
        body: []u8,
    ) Error!EncodedRequest {
        errdefer allocator.free(body);
        if (body.len > types.max_request_bytes) return error.ResourceLimit;
        return .{
            .allocator = allocator,
            .url = try allocator.dupe(u8, url),
            .body = body,
        };
    }

    pub fn addHeader(
        self: *EncodedRequest,
        name: []const u8,
        value: []const u8,
        sensitive: bool,
    ) Error!void {
        if (self.header_count == max_headers) return error.ResourceLimit;
        const owned = try self.allocator.dupe(u8, value);
        self.owned_header_values[self.header_count] = owned;
        self.headers[self.header_count] = .{
            .name = name,
            .value = owned,
            .sensitive = sensitive,
        };
        self.header_count += 1;
    }

    pub fn view(self: *const EncodedRequest) transport.HttpRequest {
        return .{
            .url = self.url,
            .headers = self.headers[0..self.header_count],
            .body = self.body,
        };
    }

    pub fn deinit(self: *EncodedRequest) void {
        for (0..self.header_count) |index| {
            const value = self.owned_header_values[index];
            if (self.headers[index].sensitive)
                std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        }
        self.allocator.free(self.url);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn parseJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = types.max_response_bytes,
    }) catch return error.MalformedResponse;
}

pub fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return switch (value) {
        .object => |result| result,
        else => error.MalformedResponse,
    };
}

pub fn array(value: std.json.Value) Error!std.json.Array {
    return switch (value) {
        .array => |result| result,
        else => error.MalformedResponse,
    };
}

pub fn string(value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |result| result,
        else => error.MalformedResponse,
    };
}

pub fn optionalString(value: std.json.Value) Error!?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |result| result,
        else => error.MalformedResponse,
    };
}

pub fn boolean(value: std.json.Value) Error!bool {
    return switch (value) {
        .bool => |result| result,
        else => error.MalformedResponse,
    };
}

pub fn unsigned(value: std.json.Value) Error!u64 {
    return switch (value) {
        .integer => |result| if (result < 0)
            error.MalformedResponse
        else
            @intCast(result),
        else => error.MalformedResponse,
    };
}

pub fn usageField(
    object_map: std.json.ObjectMap,
    name: []const u8,
) Error!u64 {
    const value = object_map.get(name) orelse return 0;
    return unsigned(value);
}

pub fn appendText(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.MalformedResponse;
    const next_len = std.math.add(usize, output.items.len, text.len) catch
        return error.ResourceLimit;
    if (next_len > types.max_result_bytes) return error.ResourceLimit;
    output.appendSlice(allocator, text) catch return error.OutOfMemory;
}

pub fn finishResult(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    usage: types.Usage,
    stop_reason: types.StopReason,
) Error!types.Result {
    // Reasoning can exhaust the generation budget before any final text. Keep
    // that valid terminal fact for consumers to reject as incomplete; it is
    // different from an empty response claiming successful completion.
    if (output.items.len == 0 and stop_reason != .max_tokens) return error.MalformedResponse;
    return .{
        .allocator = allocator,
        .text = output.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .usage = usage,
        .stop_reason = stop_reason,
    };
}

test "Encoded request owns and marks sensitive headers" {
    var encoded = try EncodedRequest.init(
        std.testing.allocator,
        "https://example.test",
        try std.testing.allocator.dupe(u8, "{}"),
    );
    defer encoded.deinit();
    try encoded.addHeader("authorization", "Bearer secret", true);
    try std.testing.expect(encoded.view().headers[0].sensitive);
    try std.testing.expectEqualStrings("Bearer secret", encoded.view().headers[0].value);
}
