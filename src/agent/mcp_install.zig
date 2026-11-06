//! Fixed, effect-free MCP configuration proposal. Product Add remains the authority.
const std = @import("std");

pub const name = "ProposeMcpServer";
pub const description = "Prepare one MCP server configuration for the user to review in MetaWork. Use this instead of searching for or editing client configuration files. This submits a non-sensitive suggestion to MetaWork for a user review card: it does not save configuration, start processes, contact servers, authenticate, authorize tools, or add tools to this Task. The user must open the proposal and submit Add, then authenticate and choose tools on the MCP page; new Tasks can use the selected tools. Supply literal command and ordered arguments for STDIO, or a public endpoint for Streamable HTTP. Supply only environment/header names, never values. Never fetch keys using WebFetch or shell, or include credentials in arguments, URLs, or any other field. Credential-bearing URLs are unsupported: explain this limitation without fetching a key or guessing another endpoint. Use the existing MCP password form or OAuth for credentials. Do not retry to poll installation progress.";
pub const schema =
    \\{"type":"object","properties":{"displayName":{"type":"string"},"transport":{"type":"string","enum":["stdio","streamable_http"]},"command":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"cwd":{"type":"string"},"environmentNames":{"type":"array","items":{"type":"string"}},"endpoint":{"type":"string"},"authMode":{"type":"string","enum":["none","static","oauth"]},"headerNames":{"type":"array","items":{"type":"string"}}},"required":["displayName","transport","authMode"],"additionalProperties":false}
;
pub const max_bytes = 32 * 1024;
pub const result_bytes = 256;
pub const Result = union(enum) { proposal_submitted: u64, busy, invalid_arguments, unavailable, cancelled };
pub const OwnedDraft = struct {
    allocator: std.mem.Allocator,
    json: []u8,
    pub fn deinit(self: *OwnedDraft) void {
        std.crypto.secureZero(u8, self.json);
        self.allocator.free(self.json);
        self.* = undefined;
    }
};
/// Narrow frozen Run capability. Only the Session supplies the trusted Run id.
/// try_put transfers draft ownership only on proposal_submitted; wake is separate.
pub const Input = struct {
    context: *anyopaque,
    allocator: std.mem.Allocator,
    task_id: u64 = 0,
    try_put_fn: *const fn (*anyopaque, u64, u64, u64, OwnedDraft) Result,
    wake_fn: *const fn (*anyopaque) void,
};
pub const Draft = struct {
    displayName: []const u8,
    transport: []const u8,
    command: ?[]const u8 = null,
    arguments: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    environmentNames: []const []const u8 = &.{},
    endpoint: ?[]const u8 = null,
    authMode: []const u8,
    headerNames: []const []const u8 = &.{},
};

fn text(value: []const u8, max: usize, empty: bool) bool {
    if ((!empty and value.len == 0) or value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (std.ascii.isControl(byte)) return false;
    return true;
}
fn names(values: []const []const u8, environment: bool) bool {
    if (values.len > 128) return false;
    for (values, 0..) |value, index| {
        if (!text(value, 256, false)) return false;
        for (value, 0..) |byte, position| {
            if (environment) {
                if (!(std.ascii.isAlphabetic(byte) or byte == '_' or (position != 0 and std.ascii.isDigit(byte)))) return false;
            } else if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
        }
        for (values[0..index]) |previous| if (std.ascii.eqlIgnoreCase(previous, value)) return false;
    }
    return true;
}
pub fn proposal(allocator: std.mem.Allocator, bytes: []const u8) !OwnedDraft {
    if (bytes.len > max_bytes) return error.InvalidArguments;
    const parsed = std.json.parseFromSlice(Draft, allocator, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = 16384 }) catch |err| return if (err == error.OutOfMemory) err else error.InvalidArguments;
    defer parsed.deinit();
    const d = parsed.value;
    if (!text(d.displayName, 256, false) or !names(d.environmentNames, true) or !names(d.headerNames, false) or d.arguments.len > 128) return error.InvalidArguments;
    var argument_bytes: usize = 0;
    for (d.arguments) |argument| {
        if (!text(argument, 16384, true)) return error.InvalidArguments;
        argument_bytes += argument.len;
    }
    if (argument_bytes > 16384) return error.InvalidArguments;
    if (d.cwd) |cwd| if (!text(cwd, 4096, false)) return error.InvalidArguments;
    if (std.mem.eql(u8, d.transport, "stdio")) {
        if (d.endpoint != null or d.headerNames.len != 0 or (!std.mem.eql(u8, d.authMode, if (d.environmentNames.len == 0) "none" else "static")) or !text(d.command orelse return error.InvalidArguments, 4096, false)) return error.InvalidArguments;
        for (d.environmentNames) |value| if (if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(value, "PATH") or std.ascii.eqlIgnoreCase(value, "SystemRoot") else std.mem.eql(u8, value, "PATH")) return error.InvalidArguments;
    } else if (std.mem.eql(u8, d.transport, "streamable_http")) {
        if (d.command != null or d.arguments.len != 0 or d.cwd != null or d.environmentNames.len != 0) return error.InvalidArguments;
        const endpoint = d.endpoint orelse return error.InvalidArguments;
        if (!text(endpoint, 4096, false) or std.mem.indexOfAny(u8, endpoint, "?#\\") != null) return error.InvalidArguments;
        const uri = std.Uri.parse(endpoint) catch return error.InvalidArguments;
        if (uri.host == null or uri.user != null or uri.password != null) return error.InvalidArguments;
        if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidArguments;
        if (!std.mem.eql(u8, d.authMode, "none") and !std.mem.eql(u8, d.authMode, "static") and !std.mem.eql(u8, d.authMode, "oauth")) return error.InvalidArguments;
        if ((std.mem.eql(u8, d.authMode, "static")) != (d.headerNames.len != 0)) return error.InvalidArguments;
    } else return error.InvalidArguments;
    const encoded = if (std.mem.eql(u8, d.transport, "stdio"))
        try std.json.Stringify.valueAlloc(allocator, .{ .displayName = d.displayName, .transport = "stdio", .negotiation = "automatic", .timeoutMs = @as(u32, 30000), .command = d.command.?, .arguments = d.arguments, .cwd = d.cwd, .environmentNames = d.environmentNames }, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, .{ .displayName = d.displayName, .transport = "streamable_http", .negotiation = "automatic", .timeoutMs = @as(u32, 30000), .endpoint = d.endpoint.?, .authMode = d.authMode, .headerNames = d.headerNames, .registration = if (std.mem.eql(u8, d.authMode, "oauth")) @as(?struct { kind: []const u8 }, .{ .kind = "automatic" }) else null }, .{});
    if (encoded.len > max_bytes) {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
        return error.InvalidArguments;
    }
    return .{ .allocator = allocator, .json = encoded };
}

pub fn result(buffer: []u8, outcome: Result) ![]const u8 {
    return switch (outcome) {
        .proposal_submitted => |id| std.fmt.bufPrint(buffer, "{{\"status\":\"proposal_submitted\",\"proposalId\":\"{d}\",\"message\":\"Suggestion accepted. The user must review and add it in MetaWork.\"}}", .{id}),
        else => std.fmt.bufPrint(buffer, "{{\"status\":\"{s}\"}}", .{@tagName(outcome)}),
    };
}

test "MCP proposal stays public strict bounded and preserves literal arguments" {
    var draft = try proposal(std.testing.allocator, "{\"displayName\":\"Files\",\"transport\":\"stdio\",\"command\":\"node\",\"authMode\":\"static\",\"environmentNames\":[\"TOKEN\"],\"arguments\":[\"--filter=$HOME\",\"\"]}");
    defer draft.deinit();
    try std.testing.expect(std.mem.indexOf(u8, draft.json, "--filter=$HOME") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.json, "draft_ready") == null);
    try std.testing.expectError(error.InvalidArguments, proposal(std.testing.allocator, "{\"displayName\":\"Files\",\"transport\":\"stdio\",\"command\":\"node\",\"secret\":\"key\"}"));
}

test "MCP proposal rejects secrets identity extensions oversized input and malformed transport" {
    const cases = [_][]const u8{
        "{}",
        "{\"displayName\":\"X\",\"displayName\":\"Y\",\"transport\":\"stdio\",\"command\":\"node\",\"authMode\":\"none\"}",
        "{\"displayName\":\"X\",\"transport\":\"stdio\",\"command\":\"node\",\"authMode\":\"none\",\"taskId\":42}",
        "{\"displayName\":\"X\",\"transport\":\"stdio\",\"command\":\"node\",\"authMode\":\"static\",\"environmentNames\":[\"TOKEN\"],\"env\":{\"TOKEN\":\"synthetic\"}}",
        "{\"displayName\":\"X\",\"transport\":\"streamable_http\",\"endpoint\":\"https://example.test/mcp?key=synthetic\",\"authMode\":\"none\"}",
        "{\"displayName\":\"X\",\"transport\":\"streamable_http\",\"endpoint\":\"https://example.test/mcp\",\"authMode\":\"none\",\"headerNames\":[\"Authorization\"]}",
    };
    for (cases) |bytes| try std.testing.expectError(error.InvalidArguments, proposal(std.testing.allocator, bytes));
    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.InvalidArguments, proposal(std.testing.allocator, oversized));
    var buffer: [result_bytes]u8 = undefined;
    const accepted = try result(&buffer, .{ .proposal_submitted = std.math.maxInt(u64) });
    try std.testing.expect(std.mem.indexOf(u8, accepted, "proposalId") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "draft") == null);
}
