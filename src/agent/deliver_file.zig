//! Narrow Host delivery request/receipt codec. File effects and Product commit
//! are separate owners; a model-provided path never constitutes a receipt.
const std = @import("std");

pub const name = "DeliverFile";
pub const description = "Hand an existing file in the current workspace to the user as a result of this turn. The user gets a result card and opens the file from it. Call this for every file the user has to open to use what you produced, such as a document, web page, spreadsheet, presentation, PDF, image or video, including an existing document you edited. Do not call it when your reply already gives the result, for code, configuration or text edits the user reviews as file changes, or for process files such as scripts, drafts, temporary data and logs. Deliver only the final version, after your last change to the file in this turn; call once per file, the file that answers the request first. Supply a workspace-relative path using forward slashes. The Host reads the file and records its path, size and SHA-256 for this Task; it does not create, edit, convert, check, upload or send the file. The status delivered confirms that record, not the file's quality.";
pub const schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative path of the finished file, using forward slashes."}},"required":["path"],"additionalProperties":false}
;
pub const max_receipts_per_run = 8;
pub const result_bytes = 4096;
pub const max_active_calls = 2;

/// Frozen Workspace file capability. The Application owner stays alive until
/// Run callbacks and Product event drain are quiescent; no aggregate is borrowed.
pub const Input = struct {
    context: *anyopaque,
    inspect_fn: *const fn (*anyopaque, []const u8, *const std.atomic.Value(bool)) Inspection,
};
pub const Inspection = union(enum) {
    verified: struct { size_bytes: u64, sha256: [32]u8 },
    failed: Failure,
};

pub const Receipt = struct {
    pub const tool_name = name;
    pub const max_path_bytes = 512;
    id: [16]u8,
    path: [max_path_bytes]u8 = @splat(0),
    path_len: usize,
    size_bytes: u64,
    sha256: [32]u8,

    pub fn init(id: [16]u8, path: []const u8, size_bytes: u64, sha256: [32]u8) !Receipt {
        if (std.mem.allEqual(u8, &id, 0)) return error.InvalidReceipt;
        try validatePath(path);
        var value: Receipt = .{ .id = id, .path_len = path.len, .size_bytes = size_bytes, .sha256 = sha256 };
        @memcpy(value.path[0..path.len], path);
        return value;
    }

    pub fn pathView(self: *const Receipt) []const u8 {
        return self.path[0..self.path_len];
    }

    pub fn validate(self: *const Receipt) !void {
        if (std.mem.allEqual(u8, &self.id, 0) or self.path_len > self.path.len) return error.InvalidReceipt;
        try validatePath(self.pathView());
    }
};

pub const Failure = enum { unavailable, invalid_arguments, capacity, cancelled, missing, restricted, changed, too_large, read_failed };
pub const Outcome = union(enum) { verified: Receipt, failed: Failure };

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > Receipt.max_path_bytes or !std.unicode.utf8ValidateSlice(path)) return error.InvalidArguments;
    for (path) |byte| if (std.ascii.isControl(byte) or std.mem.indexOfScalar(u8, "\\:<>\"|?*", byte) != null) return error.InvalidArguments;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or part[part.len - 1] == '.' or part[part.len - 1] == ' ')
            return error.InvalidArguments;
    }
}

const PathText = struct {
    value: []const u8,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !PathText {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

pub fn pathArgument(allocator: std.mem.Allocator, arguments: []const u8) ![]u8 {
    if (arguments.len > Receipt.max_path_bytes * 6 + 64) return error.InvalidArguments;
    const parsed = std.json.parseFromSlice(struct { path: PathText }, allocator, arguments, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = Receipt.max_path_bytes,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidArguments;
    defer parsed.deinit();
    try validatePath(parsed.value.path.value);
    return allocator.dupe(u8, parsed.value.path.value);
}

pub fn result(buffer: []u8, outcome: Outcome) ![]const u8 {
    if (outcome == .verified) try outcome.verified.validate();
    var writer = std.Io.Writer.fixed(buffer);
    switch (outcome) {
        .failed => |code| try std.json.Stringify.value(.{ .status = @tagName(code) }, .{}, &writer),
        .verified => |*receipt| try std.json.Stringify.value(.{
            .status = "delivered",
            .delivery_id = &std.fmt.bytesToHex(receipt.id, .lower),
            .path = receipt.pathView(),
            .size_bytes = receipt.size_bytes,
            .sha256 = &std.fmt.bytesToHex(receipt.sha256, .lower),
        }, .{}, &writer),
    }
    return writer.buffered();
}

test "delivery arguments cannot supply authority, a receipt, absolute paths or aliases" {
    for ([_][]const u8{ "{}", "{\"path\":[97]}", "{\"path\":97}", "{\"path\":null}", "{\"path\":\"../x\"}", "{\"path\":\"C:/x\"}", "{\"path\":\"/x\"}", "{\"path\":\"a//b\"}", "{\"path\":\"a:stream\"}", "{\"path\":\"x\",\"sha256\":\"fake\"}", "{\"path\":\"a\",\"path\":\"b\"}" }) |value|
        try std.testing.expectError(error.InvalidArguments, pathArgument(std.testing.allocator, value));
    const path = try pathArgument(std.testing.allocator, "{\"path\":\"成果/final report.docx\"}");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("成果/final report.docx", path);
}

test "the delivery description states the result test, the final-version precondition and the effects" {
    for ([_][]const u8{
        "result of this turn",
        "has to open",
        "final version",
        "process files",
        "the file that answers the request first",
        "does not create, edit, convert, check, upload or send",
    }) |required| try std.testing.expect(std.mem.indexOf(u8, description, required) != null);
    for ([_][]const u8{ "explicit delivery", "after checking", "verified", "most important" }) |retired|
        try std.testing.expect(std.mem.indexOf(u8, description, retired) == null);
}

test "delivery receipts are bounded values and success records delivery rather than Product commit" {
    var path = [_]u8{'a'} ** Receipt.max_path_bytes;
    // A valid path of maximum byte size, not one overlong filesystem component.
    path[255] = '/';
    path[510] = '/';
    const receipt = try Receipt.init(@splat(1), &path, std.math.maxInt(u64), @splat(2));
    var storage: [result_bytes]u8 = undefined;
    const bytes = try result(&storage, .{ .verified = receipt });
    const parsed = try std.json.parseFromSlice(struct { status: []const u8 }, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("delivered", parsed.value.status);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "verified") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "18446744073709551615") != null);
    try std.testing.expectError(error.InvalidReceipt, Receipt.init(@splat(0), "file", 0, @splat(0)));
}

fn argumentAllocationCase(allocator: std.mem.Allocator) !void {
    const path = try pathArgument(allocator, "{\"path\":\"report.docx\"}");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("report.docx", path);
}

test "delivery argument allocation failures remain capacity failures and release partial state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, argumentAllocationCase, .{});
}
