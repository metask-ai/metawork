//! Model-facing GenerateVideo contract. The Run supplies the execution effect.
const std = @import("std");
const delivery = @import("agent_file_delivery");
const http = @import("agent_http_transport");
const images = @import("image_generation.zig");

pub const name = "GenerateVideo";
pub const description = "Generate one new MP4 video from a prompt and save it in the current workspace. The video appears in the conversation after a successful save. Call DeliverFile for this video only if the user explicitly requests a separate file delivery. After submission, the remote job may complete and be charged even if the local call fails or stops. Do not automatically submit another generation after a failure.";
pub const schema =
    \\{"type":"object","properties":{"prompt":{"type":"string","description":"Describe the requested video."}},"required":["prompt"],"additionalProperties":false}
;

pub const max_prompt_bytes = 16 * 1024;
pub const max_arguments_bytes = max_prompt_bytes * 6 + 64;
pub const result_bytes = delivery.Receipt.max_path_bytes * 6 + 128;
pub const max_file_bytes = 64 * 1024 * 1024;
pub const timeout_ns = 11 * 60 * std.time.ns_per_s;
/// DNS, TCP and TLS share at most 15 s of each request's budget.
const connect_timeout_ms: u32 = 15_000;

/// The Run owner retains the immutable strings and effect contexts through
/// callback quiescence. Credentials are copied into one request at a time.
pub const Input = struct {
    endpoint: []const u8,
    /// Models execution source; isolates connection reuse only.
    source: []const u8,
    model: []const u8,
    credential: images.CredentialReader,
    transport: http.Transport,
    output: Output,

    pub fn validate(self: Input) !void {
        try images.validateEndpoint(self.endpoint);
        if (!std.mem.endsWith(u8, self.endpoint, "/v1/videos") or self.model.len == 0 or self.model.len > 512 or
            !std.unicode.utf8ValidateSlice(self.model)) return error.InvalidBinding;
    }
};

pub const Output = struct {
    context: *anyopaque,
    commit_fn: *const fn (*anyopaque, *std.Io.Reader, ?u64, *const http.Cancellation) Outcome,
};

pub const Receipt = struct {
    path: [delivery.Receipt.max_path_bytes]u8 = @splat(0),
    path_len: usize,
    size_bytes: u64,

    pub fn init(path: []const u8, size_bytes: u64) !Receipt {
        try validateFile(path, size_bytes);
        var receipt: Receipt = .{ .path_len = path.len, .size_bytes = size_bytes };
        @memcpy(receipt.path[0..path.len], path);
        return receipt;
    }

    fn validate(self: *const Receipt) !void {
        if (self.path_len > self.path.len) return error.InvalidReceipt;
        try validateFile(self.path[0..self.path_len], self.size_bytes);
    }

    pub fn pathView(self: *const Receipt) []const u8 {
        return self.path[0..self.path_len];
    }

    fn validateFile(path: []const u8, size_bytes: u64) !void {
        if (size_bytes == 0 or size_bytes > max_file_bytes or !std.mem.endsWith(u8, path, ".mp4")) return error.InvalidReceipt;
        delivery.validatePath(path) catch return error.InvalidReceipt;
    }
};

pub const Failure = enum { invalid_arguments, unavailable, capacity, cancelled, outcome_unknown, provider_rejected, invalid_response, download_failed, output_failed, cleanup_incomplete };
pub const Outcome = union(enum) { saved: Receipt, failed: Failure };

const JsonText = struct {
    value: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !JsonText {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

pub fn prompt(allocator: std.mem.Allocator, arguments: []const u8) ![]u8 {
    if (arguments.len > max_arguments_bytes) return error.InvalidArguments;
    const parsed = std.json.parseFromSlice(struct { prompt: JsonText }, allocator, arguments, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = max_prompt_bytes,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidArguments;
    defer parsed.deinit();
    const value = parsed.value.prompt.value;
    if (value.len > max_prompt_bytes or std.mem.trim(u8, value, " \r\n\t").len == 0 or
        !std.unicode.utf8ValidateSlice(value)) return error.InvalidArguments;
    return allocator.dupe(u8, value);
}

pub fn result(buffer: []u8, outcome: Outcome) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    switch (outcome) {
        .saved => |*receipt| {
            try receipt.validate();
            try std.json.Stringify.value(.{
                .status = "saved",
                .path = receipt.path[0..receipt.path_len],
                .media_type = "video/mp4",
                .size_bytes = receipt.size_bytes,
            }, .{}, &writer);
        },
        .failed => |failure| try std.json.Stringify.value(.{ .status = @tagName(failure) }, .{}, &writer),
    }
    return writer.buffered();
}

const max_id_bytes = 256;
const max_json_bytes = 64 * 1024;
const poll_interval_ns = 5 * std.time.ns_per_s;
const max_poll_backoff_ns = 30 * std.time.ns_per_s;
const TaskState = enum { pending, complete, failed };
const Task = struct {
    id: [max_id_bytes]u8 = undefined,
    id_len: usize,
    state: TaskState,

    fn decode(allocator: std.mem.Allocator, body: []const u8) !Task {
        const parsed = try std.json.parseFromSlice(struct { id: ?JsonText = null, task_id: ?JsonText = null, status: JsonText }, allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const value = parsed.value;
        const explicit_id = if (value.task_id) |task_id| task_id.value else "";
        const id = if (explicit_id.len > 0) explicit_id else (value.id orelse return error.InvalidTask).value;
        if (id.len == 0 or id.len > max_id_bytes) return error.InvalidTask;
        for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidTask;
        const state = std.StaticStringMap(TaskState).initComptime(.{
            .{ "queued", .pending },     .{ "in_progress", .pending }, .{ "pending", .pending }, .{ "running", .pending },
            .{ "completed", .complete }, .{ "succeeded", .complete },  .{ "failed", .failed },   .{ "cancelled", .failed },
            .{ "canceled", .failed },    .{ "error", .failed },        .{ "expired", .failed },
        }).get(value.status.value) orelse return error.InvalidTask;
        var task: Task = .{ .id_len = id.len, .state = state };
        @memcpy(task.id[0..id.len], id);
        return task;
    }

    fn idView(self: *const Task) []const u8 {
        return self.id[0..self.id_len];
    }
};

fn request(input: Input, call: *images.Call, endpoint: []const u8, body: []const u8, buffer: []u8, stream: ?http.ResponseStream) !http.Response {
    if (call.cancellation.isRequested()) return error.Cancelled;
    var auth: [7 + 4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &auth);
    const len = input.credential.read_fn(input.credential.context, auth[7..]) orelse return error.CredentialUnavailable;
    if (len == 0 or len > auth.len - 7 or std.mem.indexOfAny(u8, auth[7..][0..len], "\r\n\x00") != null)
        return error.CredentialUnavailable;
    @memcpy(auth[0..7], "Bearer ");
    if (call.cancellation.isRequested()) return error.Cancelled;
    if (body.len != 0) call.sent = true;
    return input.transport.perform(.{
        .url = endpoint,
        .method = if (body.len == 0) .get else .post,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = if (stream == null) "application/json" else "video/mp4" },
            .{ .name = "Accept-Encoding", .value = "identity" },
            .{ .name = "Authorization", .value = auth[0 .. 7 + len], .sensitive = true },
        },
        .body = body,
        .stream = stream,
        .connect_timeout_ms = connect_timeout_ms,
        .source = input.source,
    }, &call.cancellation, buffer);
}

fn waitForPoll(call: *images.Call, interval_ns: i96) bool {
    const end = std.Io.Timestamp.now(call.io, .awake).nanoseconds + interval_ns;
    while (!call.cancellation.isRequested()) {
        const now = std.Io.Timestamp.now(call.io, .awake).nanoseconds;
        if (now >= call.deadline_ns) return false;
        const remaining = @min(end, call.deadline_ns) - now;
        if (remaining <= 0) return true;
        std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromNanoseconds(@min(remaining, 50 * std.time.ns_per_ms)), .clock = .awake } }, call.io) catch return false;
    }
    return false;
}

pub fn perform(allocator: std.mem.Allocator, input: Input, value: []const u8, call: *images.Call) Outcome {
    const body = std.json.Stringify.valueAlloc(allocator, .{
        .model = input.model,
        .input = .{ .prompt = value },
        .parameters = .{ .duration = @as(u8, 5), .resolution = "720P", .ratio = "16:9", .audio = true },
    }, .{}) catch return .{ .failed = .capacity };
    defer allocator.free(body);
    const buffer = allocator.alloc(u8, max_json_bytes) catch return .{ .failed = .capacity };
    defer {
        std.crypto.secureZero(u8, buffer);
        allocator.free(buffer);
    }
    const created = request(input, call, input.endpoint, body, buffer, null) catch |err| return .{ .failed = if (call.sent) .outcome_unknown else if (err == error.Cancelled) .cancelled else .unavailable };
    switch (created.status) {
        200...299 => {},
        400, 401, 403, 404, 422, 429 => return .{ .failed = .provider_rejected },
        else => return .{ .failed = .outcome_unknown },
    }
    const initial = Task.decode(allocator, created.body) catch return .{ .failed = .outcome_unknown };
    var url_buffer: [2048 + 1 + max_id_bytes + "/content".len]u8 = undefined;
    const query_url = std.fmt.bufPrint(&url_buffer, "{s}/{s}", .{ input.endpoint, initial.idView() }) catch unreachable;
    var state = initial.state;
    var interval_ns: i96 = poll_interval_ns;
    while (state == .pending) {
        if (!waitForPoll(call, interval_ns)) return .{ .failed = .outcome_unknown };
        const queried = request(input, call, query_url, &.{}, buffer, null) catch |err| switch (err) {
            error.DnsFailed, error.ConnectFailed, error.TlsFailed, error.WriteFailed, error.ReadFailed => {
                interval_ns = @min(interval_ns * 2, max_poll_backoff_ns);
                continue;
            },
            else => return .{ .failed = .outcome_unknown },
        };
        if (queried.status == 429 or (queried.status >= 500 and queried.status <= 599)) {
            interval_ns = @min(interval_ns * 2, max_poll_backoff_ns);
            continue;
        }
        if (queried.status != 200) return .{ .failed = .outcome_unknown };
        const task = Task.decode(allocator, queried.body) catch return .{ .failed = .outcome_unknown };
        if (!std.mem.eql(u8, initial.idView(), task.idView())) return .{ .failed = .outcome_unknown };
        state = task.state;
        interval_ns = poll_interval_ns;
    }
    if (state == .failed) return .{ .failed = .provider_rejected };
    @memcpy(url_buffer[query_url.len..][0.."/content".len], "/content");
    var download: Download = .{ .output = input.output, .cancellation = &call.cancellation };
    // A cancellation can arrive after the output effect has published the file.
    _ = request(input, call, url_buffer[0 .. query_url.len + "/content".len], &.{}, &.{}, .{ .context = &download, .receive_fn = Download.receive }) catch |err| {
        if (err == error.Cancelled and download.outcome == .failed and download.outcome.failed == .download_failed)
            return .{ .failed = .cancelled };
    };
    return download.outcome;
}

const Download = struct {
    output: Output,
    cancellation: *const http.Cancellation,
    outcome: Outcome = .{ .failed = .download_failed },

    fn receive(context: *anyopaque, content_type: ?[]const u8, length: ?u64, reader: *std.Io.Reader) void {
        const self: *Download = @ptrCast(@alignCast(context));
        if (self.cancellation.isRequested()) return;
        const mime = content_type orelse {
            self.outcome = .{ .failed = .invalid_response };
            return;
        };
        const base = std.mem.trim(u8, mime[0 .. std.mem.indexOfScalar(u8, mime, ';') orelse mime.len], " \t");
        if ((!std.ascii.eqlIgnoreCase(base, "video/mp4") and !std.ascii.eqlIgnoreCase(base, "application/octet-stream")) or
            (length != null and (length.? < 16 or length.? > max_file_bytes)))
        {
            self.outcome = .{ .failed = .invalid_response };
            return;
        }
        const header = reader.peek(12) catch return;
        const box_bytes = std.mem.readInt(u32, header[0..4], .big);
        if (!std.mem.eql(u8, header[4..8], "ftyp") or box_bytes < 16 or (length != null and box_bytes > length.?)) {
            self.outcome = .{ .failed = .invalid_response };
            return;
        }
        self.outcome = self.output.commit_fn(self.output.context, reader, length, self.cancellation);
    }
};
