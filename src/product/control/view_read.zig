//! One in-flight Product snapshot, including its frozen text source and cache transfers.
const std = @import("std");
const builtin = @import("builtin");
const product_task = @import("metawork_product_task");
const credential_match = @import("product_credential_match");
const view_plan = @import("view_plan.zig");
const view_cache = @import("view_cache.zig");
const ViewRequest = @import("view_request.zig").Request;
const Error = view_plan.Error || view_cache.Error || product_task.ProjectionError;

pub const Credentials = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Credentials, value: []const u8) std.mem.Allocator.Error!void {
        if (value.len == 0) return;
        for (self.values.items) |known| if (std.mem.eql(u8, known, value)) return;
        const owned = try self.allocator.dupe(u8, value);
        errdefer {
            std.crypto.secureZero(u8, owned);
            self.allocator.free(owned);
        }
        try self.values.append(self.allocator, owned);
    }

    pub fn visit(context: *anyopaque, value: []const u8) std.mem.Allocator.Error!void {
        const self: *Credentials = @ptrCast(@alignCast(context));
        try self.add(value);
    }

    pub fn deinit(self: *Credentials) void {
        for (self.values.items) |value| {
            std.crypto.secureZero(u8, @constCast(value));
            self.allocator.free(value);
        }
        self.values.deinit(self.allocator);
    }
};

const Preparation = struct {
    const Block = struct { key: view_cache.Key, start: usize, end: usize, known: u64, version: u64 = 0, current: bool = true };
    const Tool = struct { source: ?product_task.OwnedToolProjection, child: *view_plan.Plan, state: product_task.OwnedToolProjection.State = .{} };
    credentials: ?Credentials = null,
    tools: std.ArrayList(Tool) = .empty,
    raw_bytes: usize = 0,
    search_query: [product_task.search_query_bytes]u8 = @splat(0),
    tool_limit: usize = 0,
    next_tool: usize = 0,
    blocks: [7]Block = undefined,
    next_block: usize = 0,
    versions: view_cache.Versions = .{},
    reused: [7]bool = @splat(false),
    known_epoch: u64 = 0,
    scratch_bytes: usize = 0,
    tail: view_plan.Plan = .{},
    ready: bool = false,

    fn clear(self: *Preparation, allocator: std.mem.Allocator) void {
        for (self.tools.items) |*tool| if (tool.source) |*source| source.deinit(allocator);
        self.tools.deinit(allocator);
        std.crypto.secureZero(u8, &self.search_query);
        if (self.credentials) |*credentials| credentials.deinit();
        self.tail.clear(allocator);
        self.* = .{};
    }
};

pub const Status = struct { id: u64, bytes: usize, scratch_bytes: usize = 0 };

pub const Storage = struct {
    allocator: std.mem.Allocator,
    max_bytes: usize,
    cache: *view_cache.Cache,
};

pub const Read = struct {
    plan: view_plan.Plan = .{},
    preparation: Preparation = .{},
    next_id: u64 = 0,
    blocks: [7]?struct { key: view_cache.Key, version: u64, start: usize, end: usize, encoding: ?[]u8 = null } = @splat(null),
    cached_blocks: [7]?struct { key: view_cache.Key, version: u64, child: *view_plan.Plan } = @splat(null),
    step_timing: if (builtin.is_test) struct { encode_ns: i96 = 0, cache_copy_ns: i96 = 0 } else void = if (builtin.is_test) .{} else {},

    pub fn begin(self: *Read, allocator: std.mem.Allocator, request_input: ViewRequest, security_epoch: u64, max_tools_per_run: usize) error{ViewVersionExhausted}!ViewRequest {
        if (builtin.is_test) self.step_timing = .{};
        var request = request_input;
        @memcpy(self.preparation.search_query[0..request.search_query.len], request.search_query);
        request.search_query = self.preparation.search_query[0..request.search_query.len];
        self.next_id = std.math.add(u64, self.next_id, 1) catch return error.ViewVersionExhausted;
        self.plan.id = self.next_id;
        self.plan.security_epoch = security_epoch;
        self.preparation.credentials = .{ .allocator = allocator };
        self.preparation.known_epoch = request.known_epoch;
        self.preparation.tool_limit = max_tools_per_run * request.run_limit * @as(usize, if (request.before_run_id == null) 1 else 2);
        return request;
    }

    fn frozenText(self: *Read, storage: Storage, plan: *view_plan.Plan, capture_tools: bool) Text {
        return .{
            .allocator = storage.allocator,
            .source = .{ .frozen = .{
                .plan = plan,
                .credentials = self.preparation.credentials.?.values.items,
                .max_bytes = storage.max_bytes,
                .capture_tools = if (capture_tools) self else null,
            } },
        };
    }

    pub fn rootText(self: *Read, storage: Storage) Text {
        return self.frozenText(storage, &self.plan, true);
    }

    pub fn credentialCollector(self: *Read) *Credentials {
        return &self.preparation.credentials.?;
    }

    pub fn tailText(self: *Read, storage: Storage) Text {
        self.preparation.tail.id = self.plan.id;
        self.preparation.tail.security_epoch = self.plan.security_epoch;
        return self.frozenText(storage, &self.preparation.tail, false);
    }

    pub fn captureBlocks(
        self: *Read,
        storage: Storage,
        writer: *std.Io.Writer,
        request: ViewRequest,
        text: *const Text,
        context: anytype,
        comptime compose: anytype,
    ) !void {
        inline for (std.meta.fields(view_cache.Kind)) |field| {
            const kind: view_cache.Kind = @enumFromInt(field.value);
            const key = keyFor(request, kind);
            writer.writeAll(",\"" ++ field.name ++ "\":") catch return error.SnapshotTooLarge;
            const start = writer.end;
            var version: u64 = 0;
            if (storage.cache.get(key)) |entry| {
                version = entry.version;
                if (request.known_epoch == self.plan.security_epoch and @field(request.known_versions, field.name) == version) {
                    writer.writeAll("null") catch return error.SnapshotTooLarge;
                    self.preparation.reused[field.value] = true;
                } else {
                    const child = try self.plan.appendChild(storage.allocator, writer);
                    try self.takeCachedViewBlock(storage, field.value, key, version, child);
                }
            } else try compose(context, writer, request, kind, text);
            self.preparation.blocks[field.value] = .{ .key = key, .start = start, .end = writer.end, .known = @field(request.known_versions, field.name), .version = version };
            @field(self.preparation.versions, field.name) = version;
        }
        try self.plan.capture(storage.allocator, writer.buffered());
        self.preparation.scratch_bytes = writer.end;
    }

    pub fn sealTail(self: *Read, storage: Storage, bytes: []const u8) Error!void {
        try self.preparation.tail.seal(storage.allocator, storage.max_bytes, bytes);
        // Pure cache hits can return the ready handle in the first call.
        const all_cached = for (self.preparation.blocks) |block| {
            if (block.version == 0) break false;
        } else true;
        if (all_cached) try self.finishSnapshotPreparation(storage);
    }

    pub fn markChanged(self: *Read) void {
        if (self.plan.id != 0) for (&self.preparation.blocks) |*block| {
            block.current = false;
        };
    }

    pub fn markEvent(self: *Read, task_id: u64, run_id: u64) void {
        if (!self.preparation.ready and self.plan.id != 0) for (&self.preparation.blocks) |*block| {
            switch (block.key.kind) {
                .workspaces, .taskIndex => block.current = false,
                .taskPage => if (block.key.task_id == task_id) {
                    block.current = false;
                },
                .historyPage => if (block.key.task_id == task_id and run_id < block.key.cursor) {
                    block.current = false;
                },
                else => {},
            }
        };
    }

    pub fn status(self: *const Read) Status {
        return .{ .id = self.plan.id, .bytes = if (self.preparation.ready) self.plan.total else 0, .scratch_bytes = self.preparation.scratch_bytes };
    }

    /// Each continuation performs bounded formatter stages, one block comparison,
    /// or final metadata assembly. It never advances execution or samples new facts.
    pub fn prepareNext(self: *Read, storage: Storage, security_epoch: u64, read_id: u64, output: []u8) Error!Status {
        if (read_id == 0 or read_id != self.plan.id or self.plan.security_epoch != security_epoch or @intFromPtr(output.ptr) != self.plan.storage_identity) return error.StaleSnapshot;
        if (self.preparation.ready) return self.status();
        errdefer self.cancel(storage);
        if (self.preparation.next_tool < self.preparation.tools.items.len) {
            var stages: usize = 0;
            var charged: usize = 0;
            var finished: usize = 0;
            while (self.preparation.next_tool < self.preparation.tools.items.len and finished < 4) {
                const work = &self.preparation.tools.items[self.preparation.next_tool];
                const text = self.frozenText(storage, work.child, false);
                const size = work.source.?.ownedBytes();
                if (stages != 0 and size > 32 * 1024 -| charged) break;
                const first_string = work.child.strings.items.len;
                var writer = std.Io.Writer.fixed(output);
                try work.source.?.writeStage(&writer, text.task(), &work.state);
                for (work.child.strings.items[first_string..]) |*item| item.at += work.child.skeleton.len;
                try work.child.appendSkeleton(storage.allocator, storage.max_bytes, writer.buffered());
                self.preparation.scratch_bytes = @max(self.preparation.scratch_bytes, writer.end);
                if (work.state.stage == .done) {
                    try work.child.finalize(storage.max_bytes);
                    work.source.?.deinit(storage.allocator);
                    work.source = null;
                    self.preparation.raw_bytes -= size;
                    self.preparation.next_tool += 1;
                    finished += 1;
                }
                stages += 1;
                charged += size;
            }
            return self.status();
        }
        // Cached metadata is already frozen. Skip these constant-size slots;
        // each invoke is reserved for actual preparation rather than empty turns.
        while (self.preparation.next_block < self.preparation.blocks.len and self.preparation.blocks[self.preparation.next_block].version != 0) self.preparation.next_block += 1;
        if (self.preparation.next_block < self.preparation.blocks.len) {
            const index = self.preparation.next_block;
            const block = &self.preparation.blocks[index];
            if (block.version == 0) {
                if ((try self.plan.encodedPosition(block.end)) - (try self.plan.encodedPosition(block.start)) > view_cache.blockByteLimit(block.key.kind)) return error.SnapshotTooLarge;
                const source = try self.plan.sourceRange(storage.allocator, storage.max_bytes, block.start, block.end);
                block.version = try storage.cache.frozenSource(storage.allocator, storage.max_bytes, block.key, source, block.current);
                var replacement: ?[]const u8 = null;
                var cached = false;
                if (self.preparation.known_epoch == security_epoch and block.known == block.version) {
                    replacement = "null";
                    self.preparation.reused[index] = true;
                } else if (storage.cache.get(block.key)) |entry| {
                    if (entry.version == block.version) {
                        replacement = "[]";
                        cached = true;
                    }
                }
                if (replacement) |value| {
                    const delta = try self.plan.replaceSpan(storage.allocator, storage.max_bytes, block.start, block.end, value);
                    block.end = block.start + value.len;
                    if (cached) {
                        const child = try self.plan.insertChild(storage.allocator, block.start);
                        try self.takeCachedViewBlock(storage, index, block.key, block.version, child);
                    }
                    for (self.preparation.blocks[index + 1 ..]) |*later| {
                        later.start = @intCast(@as(isize, @intCast(later.start)) + delta);
                        later.end = @intCast(@as(isize, @intCast(later.end)) + delta);
                    }
                } else if (block.current) {
                    self.blocks[index] = .{ .key = block.key, .version = block.version, .start = try self.plan.encodedPosition(block.start), .end = try self.plan.encodedPosition(block.end) };
                }
            }
            inline for (std.meta.fields(view_cache.Kind)) |field| if (index == field.value) {
                @field(self.preparation.versions, field.name) = block.version;
            };
            self.preparation.next_block += 1;
            return self.status();
        }
        try self.finishSnapshotPreparation(storage);
        return self.status();
    }

    fn finishSnapshotPreparation(self: *Read, storage: Storage) Error!void {
        var metadata: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&metadata);
        writer.writeAll(",\"blockVersions\":{") catch return error.SnapshotTooLarge;
        inline for (std.meta.fields(view_cache.Versions), 0..) |field, index| {
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.print("\"" ++ field.name ++ "\":\"{d}\"", .{@field(self.preparation.versions, field.name)}) catch return error.SnapshotTooLarge;
        }
        writer.writeAll("},\"reusedBlocks\":[") catch return error.SnapshotTooLarge;
        var first = true;
        inline for (std.meta.fields(view_cache.Kind)) |field| if (self.preparation.reused[field.value]) {
            if (!first) writer.writeByte(',') catch return error.SnapshotTooLarge;
            writer.writeAll("\"" ++ field.name ++ "\"") catch return error.SnapshotTooLarge;
            first = false;
        };
        writer.writeByte(']') catch return error.SnapshotTooLarge;
        const child = try self.plan.appendChild(storage.allocator, &writer);
        self.plan.strings.items[self.plan.strings.items.len - 1].at += self.plan.skeleton.len;
        child.* = self.preparation.tail;
        self.preparation.tail = .{};
        try self.plan.appendSkeleton(storage.allocator, storage.max_bytes, writer.buffered());
        try self.plan.finalize(storage.max_bytes);
        var block_bytes: usize = 0;
        for (self.preparation.blocks) |block| {
            const bytes = (try self.plan.encodedPosition(block.end)) - (try self.plan.encodedPosition(block.start));
            if (bytes > view_cache.blockByteLimit(block.key.kind)) return error.SnapshotTooLarge;
            block_bytes += bytes;
        }
        if (self.plan.total - block_bytes > 768 * 1024) return error.SnapshotTooLarge;
        if (self.preparation.credentials) |*credentials| credentials.deinit();
        self.preparation.credentials = null;
        self.preparation.tools.deinit(storage.allocator);
        self.preparation.tools = .empty;
        self.preparation.ready = true;
    }

    fn captureTool(self: *Read, allocator: std.mem.Allocator, max_bytes: usize, writer: *std.Io.Writer, tool: *const product_task.ToolProjection) product_task.ProjectionError!void {
        if (self.preparation.tools.items.len >= self.preparation.tool_limit) return error.SnapshotTooLarge;
        const owned = self.plan.ownedBytes() + self.preparation.raw_bytes;
        var source = try product_task.OwnedToolProjection.capture(allocator, tool, max_bytes -| owned);
        errdefer source.deinit(allocator);
        const child = self.plan.appendChild(allocator, writer) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SnapshotTooLarge,
        };
        const size = source.ownedBytes();
        try self.preparation.tools.append(allocator, .{ .source = source, .child = child });
        self.preparation.raw_bytes += size;
    }

    fn takeCachedViewBlock(self: *Read, storage: Storage, index: usize, key: view_cache.Key, version: u64, child: *view_plan.Plan) Error!void {
        const owned = storage.cache.takeEncoded(key, version) orelse return error.StaleSnapshot;
        child.adoptEncoded(owned);
        self.cached_blocks[index] = .{ .key = key, .version = version, .child = child };
    }

    fn returnCachedViewBlocks(self: *Read, storage: Storage) void {
        for (&self.cached_blocks) |*slot| if (slot.*) |block| {
            const owned = block.child.takeEncoded();
            slot.* = null;
            storage.cache.returnEncoded(storage.allocator, storage.max_bytes, block.key, block.version, owned);
        };
    }

    pub fn cancelId(self: *Read, storage: Storage, read_id: u64) void {
        if (read_id != 0 and self.plan.id == read_id) self.cancel(storage);
    }

    pub fn cancel(self: *Read, storage: Storage) void {
        self.returnCachedViewBlocks(storage);
        self.preparation.clear(storage.allocator);
        self.plan.clear(storage.allocator);
        for (&self.blocks) |*slot| if (slot.*) |block| {
            if (block.encoding) |owned| {
                std.crypto.secureZero(u8, owned);
                storage.allocator.free(owned);
            }
            slot.* = null;
        };
    }

    pub fn writeRange(self: *Read, storage: Storage, io: std.Io, security_epoch: u64, read_id: u64, output: []u8, offset: usize, length: usize) Error!void {
        if (read_id == 0 or read_id != self.plan.id or self.plan.security_epoch != security_epoch or @intFromPtr(output.ptr) != self.plan.storage_identity) return error.StaleSnapshot;
        if (!self.preparation.ready or length == 0 or length > view_plan.max_step_bytes or offset > self.plan.produced or offset > self.plan.total or length > self.plan.total - offset or output.len < self.plan.total) return error.InvalidOffset;
        errdefer self.cancel(storage);
        const encode_start = if (builtin.is_test) std.Io.Timestamp.now(io, .awake) else {};
        const before = self.plan.produced;
        const end = offset + length;
        if (end > self.plan.produced) _ = try self.plan.writeNext(output[self.plan.produced..end]);
        const cache_start = if (builtin.is_test) std.Io.Timestamp.now(io, .awake) else {};
        if (builtin.is_test) self.step_timing.encode_ns = encode_start.durationTo(cache_start).nanoseconds;
        for (&self.blocks) |*maybe| if (maybe.*) |*block| {
            if (!storage.cache.needsEncoded(storage.max_bytes, block.key, block.version, block.end - block.start)) {
                if (block.encoding) |owned| {
                    std.crypto.secureZero(u8, owned);
                    storage.allocator.free(owned);
                }
                maybe.* = null;
                continue;
            }
            const first = @max(before, block.start);
            const last = @min(self.plan.produced, block.end);
            if (last <= first) continue;
            if (block.encoding == null) block.encoding = try storage.allocator.alloc(u8, block.end - block.start);
            // The disjoint block intersections total at most this encoding
            // quantum. Partial bytes are owned by this read, never cache hits.
            @memcpy(block.encoding.?[first - block.start .. last - block.start], output[first..last]);
            if (last == block.end) {
                const owned = block.encoding.?;
                block.encoding = null;
                try storage.cache.installOwnedEncoded(storage.allocator, storage.max_bytes, block.key, block.version, owned);
                maybe.* = null;
            }
        };
        if (self.plan.produced == self.plan.total and self.plan.skeleton.len != 0) {
            self.returnCachedViewBlocks(storage);
            self.plan.releasePayload(storage.allocator);
        }
        if (builtin.is_test) self.step_timing.cache_copy_ns = cache_start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    }

    pub fn keyFor(request: ViewRequest, kind: view_cache.Kind) view_cache.Key {
        return switch (kind) {
            .taskPage => .{ .kind = kind, .task_id = request.task_id orelse 0, .limit = request.run_limit },
            .historyPage => .{ .kind = kind, .task_id = request.task_id orelse 0, .cursor = request.before_run_id orelse 0, .limit = request.run_limit },
            .management => .{ .kind = kind, .management = @intFromEnum(request.management) },
            .searchIndex => key: {
                var key: view_cache.Key = .{ .kind = kind, .limit = @intFromBool(request.search), .search_query = request.search_query };
                if (request.search_cursor) |cursor| key.search_cursor = .{ cursor.revision, cursor.security_epoch, cursor.task, cursor.run, cursor.part, cursor.offset };
                break :key key;
            },
            else => .{ .kind = kind },
        };
    }
};

/// Text projection borrows its explicit source for one synchronous formatting call.
pub const Text = struct {
    allocator: std.mem.Allocator,
    source: union(enum) {
        live: struct {
            context: *const anyopaque,
            contains_fn: *const fn (*const anyopaque, []const u8) bool,
            match_end_fn: *const fn (*const anyopaque, []const u8, usize) ?usize,
        },
        frozen: struct {
            plan: *view_plan.Plan,
            credentials: []const []const u8,
            max_bytes: usize,
            capture_tools: ?*Read = null,
        },
    },

    pub fn contains(self: *const Text, value: []const u8) bool {
        switch (self.source) {
            .live => |live| return live.contains_fn(live.context, value),
            .frozen => |frozen| {
                for (frozen.credentials) |known| if (std.mem.indexOf(u8, value, known) != null) return true;
                return false;
            },
        }
    }

    fn matchEnd(self: *const Text, value: []const u8, start: usize) ?usize {
        switch (self.source) {
            .live => |live| return live.match_end_fn(live.context, value, start),
            .frozen => |frozen| {
                var end: usize = 0;
                for (frozen.credentials) |known| {
                    end = @max(end, credential_match.matchEnd(value, start, known) orelse 0);
                }
                return if (end == 0) null else end;
            },
        }
    }

    pub fn writeJson(self: *const Text, writer: *std.Io.Writer, value: []const u8) Error!void {
        switch (self.source) {
            .live => try self.writeLiveJson(writer, value),
            .frozen => |frozen| {
                const plan = frozen.plan;
                const start = plan.text.items.len;
                if (self.contains(value)) {
                    var index: usize = 0;
                    var copied: usize = 0;
                    while (index < value.len) {
                        if (self.matchEnd(value, index)) |end| {
                            try plan.appendText(self.allocator, frozen.max_bytes, value[copied..index]);
                            try plan.appendText(self.allocator, frozen.max_bytes, "***"[0..@min(end - index, 3)]);
                            index = end;
                            copied = end;
                        } else index += credential_match.codepointLen(value, index);
                    }
                    try plan.appendText(self.allocator, frozen.max_bytes, value[copied..]);
                } else try plan.appendText(self.allocator, frozen.max_bytes, value);
                try plan.commitString(self.allocator, writer, start);
            },
        }
    }

    fn writeLiveJson(self: *const Text, writer: *std.Io.Writer, value: []const u8) Error!void {
        const hex = "0123456789abcdef";
        writer.writeByte('"') catch return error.SnapshotTooLarge;
        var index: usize = 0;
        while (index < value.len) {
            if (self.matchEnd(value, index)) |redaction_end| {
                _ = writer.splatByte('*', @min(redaction_end - index, 3)) catch
                    return error.SnapshotTooLarge;
                index = redaction_end;
                continue;
            }
            const byte = value[index];
            switch (byte) {
                '"' => writer.writeAll("\\\"") catch return error.SnapshotTooLarge,
                '\\' => writer.writeAll("\\\\") catch return error.SnapshotTooLarge,
                0x08 => writer.writeAll("\\b") catch return error.SnapshotTooLarge,
                0x0c => writer.writeAll("\\f") catch return error.SnapshotTooLarge,
                '\n' => writer.writeAll("\\n") catch return error.SnapshotTooLarge,
                '\r' => writer.writeAll("\\r") catch return error.SnapshotTooLarge,
                '\t' => writer.writeAll("\\t") catch return error.SnapshotTooLarge,
                0x00...0x07, 0x0b, 0x0e...0x1f => {
                    writer.writeAll("\\u00") catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte >> 4]) catch return error.SnapshotTooLarge;
                    writer.writeByte(hex[byte & 0x0f]) catch return error.SnapshotTooLarge;
                },
                else => writer.writeByte(byte) catch return error.SnapshotTooLarge,
            }
            index += 1;
        }
        writer.writeByte('"') catch return error.SnapshotTooLarge;
    }

    pub fn containsCallback(context: *const anyopaque, value: []const u8) bool {
        const self: *const Text = @ptrCast(@alignCast(context));
        return self.contains(value);
    }

    pub fn writeCallback(context: *const anyopaque, writer: *std.Io.Writer, value: []const u8) error{SnapshotTooLarge}!void {
        const self: *const Text = @ptrCast(@alignCast(context));
        self.writeJson(writer, value) catch return error.SnapshotTooLarge;
    }

    fn captureToolCallback(context: *const anyopaque, writer: *std.Io.Writer, tool: *const product_task.ToolProjection) product_task.ProjectionError!void {
        const self: *const Text = @ptrCast(@alignCast(context));
        const frozen = self.source.frozen;
        return frozen.capture_tools.?.captureTool(self.allocator, frozen.max_bytes, writer, tool);
    }

    pub fn task(self: *const Text) product_task.ProjectionText {
        return .{
            .context = self,
            .contains_sensitive_fn = containsCallback,
            .write_json_fn = writeCallback,
            .write_json_output_fn = writeTaskViewJsonOutput,
            .write_json_parts_fn = writeTaskViewJsonParts,
            .capture_tool_fn = if (self.source == .frozen and self.source.frozen.capture_tools != null) captureToolCallback else null,
        };
    }

    fn writeTaskViewJsonParts(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        first: []const u8,
        second: []const u8,
    ) product_task.ProjectionError!bool {
        const self: *const Text = @ptrCast(@alignCast(context));
        const total = std.math.add(usize, first.len, second.len) catch
            return error.SnapshotTooLarge;
        const joined = self.allocator.alloc(u8, total) catch
            return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, joined);
            self.allocator.free(joined);
        }
        @memcpy(joined[0..first.len], first);
        @memcpy(joined[first.len..], second);
        const redacted = self.contains(joined);
        self.writeJson(writer, joined) catch
            return error.SnapshotTooLarge;
        return redacted;
    }

    fn writeTaskViewJsonOutput(
        context: *const anyopaque,
        writer: *std.Io.Writer,
        value: []const u8,
        commentary_ends: []const u64,
    ) product_task.ProjectionError!bool {
        const self: *const Text = @ptrCast(@alignCast(context));
        // A clean output already is the sanitized source. Preserve its segment
        // boundaries directly instead of allocating and copying the whole Run.
        if (!self.contains(value)) {
            writer.writeByte('[') catch return error.SnapshotTooLarge;
            var previous: usize = 0;
            for (commentary_ends, 0..) |raw, index| {
                const boundary = std.math.cast(usize, raw) orelse return error.SnapshotTooLarge;
                if (boundary < previous or boundary > value.len or (boundary < value.len and (value[boundary] & 0xc0) == 0x80)) return error.SnapshotTooLarge;
                if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
                self.writeJson(writer, value[previous..boundary]) catch return error.SnapshotTooLarge;
                previous = boundary;
            }
            writer.writeAll("],\"response\":") catch return error.SnapshotTooLarge;
            self.writeJson(writer, value[previous..]) catch return error.SnapshotTooLarge;
            return false;
        }
        const projected = self.allocator.alloc(u8, value.len) catch
            return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, projected);
            self.allocator.free(projected);
        }
        const projected_ends = self.allocator.alloc(usize, commentary_ends.len) catch
            return error.OutOfMemory;
        defer self.allocator.free(projected_ends);
        var read: usize = 0;
        var write: usize = 0;
        var boundary_index: usize = 0;
        var redacted = false;
        while (read < value.len) {
            while (boundary_index < commentary_ends.len) {
                const boundary = std.math.cast(usize, commentary_ends[boundary_index]) orelse
                    return error.SnapshotTooLarge;
                if (boundary != read) break;
                projected_ends[boundary_index] = write;
                boundary_index += 1;
            }
            if (self.matchEnd(value, read)) |redaction_end| {
                const marker_len = @min(redaction_end - read, 3);
                @memset(projected[write..][0..marker_len], '*');
                write += marker_len;
                while (boundary_index < commentary_ends.len) {
                    const boundary = std.math.cast(usize, commentary_ends[boundary_index]) orelse
                        return error.SnapshotTooLarge;
                    if (boundary > redaction_end) break;
                    if (boundary <= read) return error.SnapshotTooLarge;
                    projected_ends[boundary_index] = write;
                    boundary_index += 1;
                }
                read = redaction_end;
                redacted = true;
                continue;
            }
            const codepoint_len = credential_match.codepointLen(value, read);
            @memcpy(
                projected[write..][0..codepoint_len],
                value[read..][0..codepoint_len],
            );
            write += codepoint_len;
            read += codepoint_len;
        }
        while (boundary_index < commentary_ends.len) {
            const boundary = std.math.cast(usize, commentary_ends[boundary_index]) orelse
                return error.SnapshotTooLarge;
            if (boundary != read) return error.SnapshotTooLarge;
            projected_ends[boundary_index] = write;
            boundary_index += 1;
        }
        writer.writeByte('[') catch return error.SnapshotTooLarge;
        var previous: usize = 0;
        for (projected_ends, 0..) |boundary, index| {
            if (boundary < previous or boundary > write)
                return error.SnapshotTooLarge;
            if (index != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
            self.writeJson(
                writer,
                projected[previous..boundary],
            ) catch return error.SnapshotTooLarge;
            previous = boundary;
        }
        writer.writeAll("],\"response\":") catch return error.SnapshotTooLarge;
        self.writeJson(
            writer,
            projected[previous..write],
        ) catch return error.SnapshotTooLarge;
        return redacted;
    }
};
