//! Transient Product-owned file staging.
const std = @import("std");

pub const Format = enum { png, jpeg, webp };
pub const Kind = enum { file, image };
pub const State = enum { ready, borrowed };

pub const Limits = struct {
    max_files: usize,
    max_display_name_bytes: usize,
    max_file_bytes: usize,
    max_text_file_bytes: usize,
    max_staged_bytes: usize,
};

pub const Candidate = struct {
    display_name: []const u8,
    bytes: []const u8,
};

pub const ReceiveFile = struct { display_name: []const u8, size_bytes: usize };
const Receive = struct {
    id: u64,
    entries: []Entry,
    file_index: usize = 0,
    offset: usize = 0,
};

pub const Descriptor = struct {
    id: u64,
    kind: Kind,
    format: ?Format,
    display_name: []const u8,
    size_bytes: u64,
};

pub const BorrowedPart = union(enum) {
    image: struct {
        id: u64,
        format: Format,
        bytes: []const u8,
    },
    text: struct {
        id: u64,
        bytes: []const u8,
    },

    pub fn attachmentId(self: BorrowedPart) u64 {
        return switch (self) {
            inline else => |part| part.id,
        };
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidLimits,
    EmptyBatch,
    TooManyFiles,
    InvalidDisplayName,
    EmptyFile,
    FileTooLarge,
    TextFileTooLarge,
    UnsupportedType,
    StagingCapacity,
    IdentityExhausted,
    UnknownAttachment,
    AttachmentBusy,
    DuplicateAttachment,
    InvalidTransfer,
    StaleTransfer,
};

const Entry = struct {
    id: u64,
    state: State,
    format: ?Format,
    display_name: []u8,
    bytes: []u8,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    slots: []?Entry,
    used_bytes: usize = 0,
    next_id: u64 = 1,
    receiving: ?Receive = null,
    next_receive_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Runtime {
        if (limits.max_files == 0 or
            limits.max_display_name_bytes == 0 or
            limits.max_file_bytes == 0 or
            limits.max_text_file_bytes == 0 or
            limits.max_text_file_bytes > limits.max_file_bytes or
            limits.max_staged_bytes == 0)
            return error.InvalidLimits;
        const slots = try allocator.alloc(?Entry, limits.max_files);
        @memset(slots, null);
        return .{ .allocator = allocator, .limits = limits, .slots = slots };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.receiving) |receive| _ = self.cancelReceive(receive.id);
        for (self.slots) |*slot| if (slot.*) |*entry| self.destroyEntry(entry);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Reserve the same slots and byte budget used by ready attachments.
    pub fn beginReceive(self: *Runtime, files: []const ReceiveFile) Error!u64 {
        if (self.receiving != null) return error.StagingCapacity;
        if (files.len == 0) return error.EmptyBatch;
        if (files.len > self.limits.max_files) return error.TooManyFiles;
        if (self.freeSlotCount() < files.len) return error.StagingCapacity;
        if (self.next_receive_id == 0) return error.IdentityExhausted;
        var total: usize = 0;
        for (files) |file| {
            if (!validDisplayName(file.display_name, self.limits.max_display_name_bytes)) return error.InvalidDisplayName;
            if (file.size_bytes == 0) return error.EmptyFile;
            if (file.size_bytes > self.limits.max_file_bytes) return error.FileTooLarge;
            if (file.size_bytes > self.limits.max_staged_bytes - self.used_bytes - total) return error.StagingCapacity;
            total += file.size_bytes;
        }
        const entries = try self.allocator.alloc(Entry, files.len);
        var created: usize = 0;
        errdefer {
            for (entries[0..created]) |*entry| self.destroyEntry(entry);
            self.allocator.free(entries);
        }
        for (files, entries) |file, *entry| {
            const name = try self.allocator.dupe(u8, file.display_name);
            errdefer self.allocator.free(name);
            const bytes = try self.allocator.alloc(u8, file.size_bytes);
            @memset(bytes, 0);
            entry.* = .{ .id = 0, .state = .ready, .format = null, .display_name = name, .bytes = bytes };
            self.used_bytes += bytes.len;
            created += 1;
        }
        const id = self.next_receive_id;
        self.next_receive_id +%= 1;
        self.receiving = .{ .id = id, .entries = entries };
        return id;
    }

    pub fn appendReceive(self: *Runtime, id: u64, file_index: usize, offset: usize, bytes: []const u8) Error!void {
        const receive = if (self.receiving) |*value| value else return error.StaleTransfer;
        if (receive.id != id) return error.StaleTransfer;
        if (file_index != receive.file_index or offset != receive.offset or file_index >= receive.entries.len or bytes.len == 0)
            return error.InvalidTransfer;
        const target = receive.entries[file_index].bytes;
        if (bytes.len > target.len - offset) return error.InvalidTransfer;
        @memcpy(target[offset..][0..bytes.len], bytes);
        receive.offset += bytes.len;
        if (receive.offset == target.len) {
            receive.file_index += 1;
            receive.offset = 0;
        }
    }

    /// No allocation or raw-byte copy at the commit point.
    pub fn finishReceive(self: *Runtime, id: u64, output: []Descriptor) Error![]const Descriptor {
        const receive = self.receiving orelse return error.StaleTransfer;
        if (receive.id != id) return error.StaleTransfer;
        if (receive.file_index != receive.entries.len) return error.InvalidTransfer;
        if (output.len < receive.entries.len) return error.TooManyFiles;
        if (self.next_id == 0 or receive.entries.len - 1 > std.math.maxInt(u64) - self.next_id) return error.IdentityExhausted;
        for (receive.entries) |*entry| {
            entry.format = self.classify(.{
                .display_name = entry.display_name,
                .bytes = entry.bytes,
            }) catch |err| {
                _ = self.cancelReceive(id);
                return err;
            };
        }
        for (receive.entries, 0..) |entry, index| {
            const slot = self.emptyIndex().?;
            var ready = entry;
            ready.id = self.next_id;
            self.next_id +%= 1;
            self.slots[slot] = ready;
            output[index] = self.descriptor(ready);
        }
        const count = receive.entries.len;
        self.allocator.free(receive.entries);
        self.receiving = null;
        return output[0..count];
    }

    pub fn cancelReceive(self: *Runtime, id: u64) bool {
        const receive = self.receiving orelse return false;
        if (receive.id != id) return false;
        for (receive.entries) |*entry| self.destroyEntry(entry);
        self.allocator.free(receive.entries);
        self.receiving = null;
        return true;
    }

    pub fn stageBatch(
        self: *Runtime,
        candidates: []const Candidate,
        output: []Descriptor,
    ) Error![]const Descriptor {
        if (candidates.len == 0) return error.EmptyBatch;
        if (candidates.len > self.limits.max_files or output.len < candidates.len)
            return error.TooManyFiles;
        if (self.freeSlotCount() < candidates.len) return error.StagingCapacity;

        var created: usize = 0;
        errdefer while (created != 0) {
            created -= 1;
            _ = self.release(output[created].id);
        };
        for (candidates, 0..) |candidate, index| {
            const format = try self.classify(candidate);
            if (candidate.bytes.len > self.limits.max_staged_bytes - self.used_bytes)
                return error.StagingCapacity;
            if (self.next_id == 0) return error.IdentityExhausted;
            const slot_index = self.emptyIndex() orelse return error.StagingCapacity;
            const display_name = try self.allocator.dupe(u8, candidate.display_name);
            errdefer self.allocator.free(display_name);
            const bytes = try self.allocator.dupe(u8, candidate.bytes);
            errdefer {
                std.crypto.secureZero(u8, bytes);
                self.allocator.free(bytes);
            }
            const id = self.next_id;
            self.next_id +%= 1;
            self.slots[slot_index] = .{
                .id = id,
                .state = .ready,
                .format = format,
                .display_name = display_name,
                .bytes = bytes,
            };
            self.used_bytes += bytes.len;
            output[index] = self.descriptor(self.slots[slot_index].?);
            created += 1;
        }
        return output[0..candidates.len];
    }

    pub fn borrow(
        self: *Runtime,
        ids: []const u64,
        parts: []BorrowedPart,
        indices: []usize,
    ) Error!Borrow {
        if (ids.len == 0) return error.EmptyBatch;
        if (ids.len > self.limits.max_files or parts.len < ids.len or indices.len < ids.len)
            return error.TooManyFiles;
        for (ids, 0..) |id, index| {
            for (ids[0..index]) |previous| if (previous == id)
                return error.DuplicateAttachment;
            const slot_index = self.findIndex(id) orelse return error.UnknownAttachment;
            const entry = &self.slots[slot_index].?;
            if (entry.state != .ready) return error.AttachmentBusy;
            indices[index] = slot_index;
        }
        for (indices[0..ids.len], 0..) |slot_index, index| {
            const entry = &self.slots[slot_index].?;
            entry.state = .borrowed;
            parts[index] = if (entry.format) |format|
                .{ .image = .{ .id = entry.id, .format = format, .bytes = entry.bytes } }
            else
                .{ .text = .{ .id = entry.id, .bytes = entry.bytes } };
        }
        return .{ .runtime = self, .indices = indices[0..ids.len] };
    }

    pub fn release(self: *Runtime, id: u64) bool {
        const index = self.findIndex(id) orelse return false;
        const entry = &self.slots[index].?;
        if (entry.state != .ready) return false;
        self.destroyEntry(entry);
        self.slots[index] = null;
        return true;
    }

    pub fn descriptorFor(self: *const Runtime, id: u64) ?Descriptor {
        const index = self.findIndex(id) orelse return null;
        return self.descriptor(self.slots[index].?);
    }

    fn classify(self: *const Runtime, candidate: Candidate) Error!?Format {
        if (!validDisplayName(candidate.display_name, self.limits.max_display_name_bytes))
            return error.InvalidDisplayName;
        if (candidate.bytes.len == 0) return error.EmptyFile;
        if (candidate.bytes.len > self.limits.max_file_bytes) return error.FileTooLarge;
        if (detectFormat(candidate.bytes)) |format| return format;
        if (candidate.bytes.len > self.limits.max_text_file_bytes)
            return error.TextFileTooLarge;
        if (!std.unicode.utf8ValidateSlice(candidate.bytes) or
            std.mem.indexOfScalar(u8, candidate.bytes, 0) != null)
            return error.UnsupportedType;
        return null;
    }

    fn descriptor(_: *const Runtime, entry: Entry) Descriptor {
        return .{
            .id = entry.id,
            .kind = if (entry.format == null) .file else .image,
            .format = entry.format,
            .display_name = entry.display_name,
            .size_bytes = entry.bytes.len,
        };
    }

    fn destroyEntry(self: *Runtime, entry: *Entry) void {
        std.debug.assert(self.used_bytes >= entry.bytes.len);
        self.used_bytes -= entry.bytes.len;
        std.crypto.secureZero(u8, entry.bytes);
        std.crypto.secureZero(u8, entry.display_name);
        self.allocator.free(entry.bytes);
        self.allocator.free(entry.display_name);
        entry.* = undefined;
    }

    fn freeSlotCount(self: *const Runtime) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot == null) {
            count += 1;
        };
        return count - if (self.receiving) |receive| receive.entries.len else @as(usize, 0);
    }

    fn emptyIndex(self: *const Runtime) ?usize {
        for (self.slots, 0..) |slot, index| if (slot == null) return index;
        return null;
    }

    fn findIndex(self: *const Runtime, id: u64) ?usize {
        if (id == 0) return null;
        for (self.slots, 0..) |slot, index| if (slot) |entry|
            if (entry.id == id) return index;
        return null;
    }
};

pub const Borrow = struct {
    runtime: *Runtime,
    indices: []const usize,
    active: bool = true,

    pub fn rollback(self: *Borrow) void {
        if (!self.active) return;
        for (self.indices) |index| {
            const entry = &self.runtime.slots[index].?;
            std.debug.assert(entry.state == .borrowed);
            entry.state = .ready;
        }
        self.active = false;
    }

    pub fn consume(self: *Borrow) void {
        if (!self.active) return;
        for (self.indices) |index| {
            const entry = &self.runtime.slots[index].?;
            std.debug.assert(entry.state == .borrowed);
            self.runtime.destroyEntry(entry);
            self.runtime.slots[index] = null;
        }
        self.active = false;
    }
};

fn validDisplayName(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))
        return false;
    for (value) |byte| if (byte == 0 or byte == '/' or byte == '\\' or byte < 0x20)
        return false;
    return true;
}

fn matches(format: Format, bytes: []const u8) bool {
    return switch (format) {
        .png => bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n"),
        .jpeg => bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff,
        .webp => bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and
            std.mem.eql(u8, bytes[8..12], "WEBP"),
    };
}

pub fn detectFormat(bytes: []const u8) ?Format {
    inline for (.{ Format.png, Format.jpeg, Format.webp }) |format| {
        if (matches(format, bytes)) return format;
    }
    return null;
}

fn testLimits() Limits {
    return .{
        .max_files = 4,
        .max_display_name_bytes = 64,
        .max_file_bytes = 64,
        .max_text_file_bytes = 32,
        .max_staged_bytes = 160,
    };
}

test "receive reserves shared capacity and adopts buffers without a raw copy" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    const id = try runtime.beginReceive(&.{
        .{ .display_name = "a.txt", .size_bytes = 3 },
        .{ .display_name = "b.png", .size_bytes = 8 },
    });
    const original = runtime.receiving.?.entries[0].bytes.ptr;
    try std.testing.expectEqual(@as(usize, 11), runtime.used_bytes);
    var output: [4]Descriptor = undefined;
    try std.testing.expectError(error.StagingCapacity, runtime.stageBatch(&.{
        .{ .display_name = "1", .bytes = "x" },
        .{ .display_name = "2", .bytes = "x" },
        .{ .display_name = "3", .bytes = "x" },
    }, &output));
    try std.testing.expectError(error.InvalidTransfer, runtime.appendReceive(id, 1, 0, "x"));
    try runtime.appendReceive(id, 0, 0, "a");
    try std.testing.expectError(error.InvalidTransfer, runtime.appendReceive(id, 0, 0, "a"));
    try std.testing.expectError(error.InvalidTransfer, runtime.finishReceive(id, &output));
    try runtime.appendReceive(id, 0, 1, "bc");
    try runtime.appendReceive(id, 1, 0, "\x89PNG\r\n\x1a\n");
    const ready = try runtime.finishReceive(id, &output);
    try std.testing.expectEqual(Kind.file, ready[0].kind);
    try std.testing.expectEqual(Kind.image, ready[1].kind);
    try std.testing.expect(original == runtime.slots[runtime.findIndex(ready[0].id).?].?.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 11), runtime.used_bytes);
    try std.testing.expectError(error.StaleTransfer, runtime.finishReceive(id, &output));
    for (ready) |descriptor| try std.testing.expect(runtime.release(descriptor.id));
    try std.testing.expectEqual(@as(usize, 0), runtime.used_bytes);
}

test "receive cancellation and allocation failures return all reservations" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var runtime = try Runtime.init(allocator, testLimits());
            defer runtime.deinit();
            const id = try runtime.beginReceive(&.{
                .{ .display_name = "a", .size_bytes = 60 },
                .{ .display_name = "b", .size_bytes = 60 },
            });
            var output: [1]Descriptor = undefined;
            try std.testing.expectError(error.TextFileTooLarge, runtime.stageBatch(&.{.{ .display_name = "c", .bytes = "x" ** 50 }}, &output));
            try std.testing.expect(!runtime.cancelReceive(id + 1));
            try std.testing.expect(runtime.cancelReceive(id));
            try std.testing.expect(!runtime.cancelReceive(id));
            try std.testing.expectEqual(@as(usize, 0), runtime.used_bytes);
            try std.testing.expectEqual(@as(usize, 4), runtime.freeSlotCount());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "staging validates signatures and rolls back a failed batch atomically" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    const candidates = [_]Candidate{
        .{ .display_name = "ok.png", .bytes = "\x89PNG\r\n\x1a\npayload" },
        .{ .display_name = "bad.jpg", .bytes = "\xffnot an image" },
    };
    var output: [2]Descriptor = undefined;
    try std.testing.expectError(error.UnsupportedType, runtime.stageBatch(&candidates, &output));
    try std.testing.expectEqual(@as(usize, 0), runtime.used_bytes);
    for (runtime.slots) |slot| try std.testing.expect(slot == null);
}

test "borrow rollback preserves ready entries and consume releases the batch" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    const candidates = [_]Candidate{
        .{ .display_name = "a.webp", .bytes = "RIFFxxxxWEBPdata" },
        .{ .display_name = "b.png", .bytes = "\x89PNG\r\n\x1a\ndata" },
    };
    var output: [2]Descriptor = undefined;
    const staged = try runtime.stageBatch(&candidates, &output);
    const ids = [_]u64{ staged[0].id, staged[1].id };
    var parts: [2]BorrowedPart = undefined;
    var indices: [2]usize = undefined;
    var first = try runtime.borrow(&ids, &parts, &indices);
    try std.testing.expect(!runtime.release(ids[0]));
    first.rollback();
    try std.testing.expect(runtime.descriptorFor(ids[0]) != null);
    var second = try runtime.borrow(&ids, &parts, &indices);
    second.consume();
    try std.testing.expectEqual(@as(usize, 0), runtime.used_bytes);
    try std.testing.expect(runtime.descriptorFor(ids[0]) == null);
}

test "duplicate and stale identities fail before changing any state" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    const candidate = [_]Candidate{.{
        .display_name = "photo.jpg",
        .bytes = "\xff\xd8\xffpayload",
    }};
    var output: [1]Descriptor = undefined;
    const staged = try runtime.stageBatch(&candidate, &output);
    const duplicate = [_]u64{ staged[0].id, staged[0].id };
    var parts: [2]BorrowedPart = undefined;
    var indices: [2]usize = undefined;
    try std.testing.expectError(
        error.DuplicateAttachment,
        runtime.borrow(&duplicate, &parts, &indices),
    );
    try std.testing.expectError(
        error.UnknownAttachment,
        runtime.borrow(&[_]u64{9999}, &parts, &indices),
    );
    try std.testing.expect(runtime.release(staged[0].id));
}

test "validated text files stage and borrow as text input" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    const candidates = [_]Candidate{.{
        .display_name = "notes.txt",
        .bytes = "plain text",
    }};
    var output: [1]Descriptor = undefined;
    const staged = try runtime.stageBatch(&candidates, &output);
    try std.testing.expectEqual(Kind.file, staged[0].kind);
    try std.testing.expectEqual(@as(?Format, null), staged[0].format);
    const ids = [_]u64{staged[0].id};
    var parts: [1]BorrowedPart = undefined;
    var indices: [1]usize = undefined;
    var borrow = try runtime.borrow(&ids, &parts, &indices);
    try std.testing.expectEqualStrings("plain text", parts[0].text.bytes);
    borrow.rollback();
    try std.testing.expect(runtime.release(staged[0].id));
}

test "text classification enforces UTF-8 NUL and the dedicated size limit" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    var output: [1]Descriptor = undefined;
    try std.testing.expectError(error.UnsupportedType, runtime.stageBatch(&.{.{
        .display_name = "invalid.txt",
        .bytes = "\xff",
    }}, &output));
    try std.testing.expectError(error.UnsupportedType, runtime.stageBatch(&.{.{
        .display_name = "nul.txt",
        .bytes = "a\x00b",
    }}, &output));
    try std.testing.expectError(error.TextFileTooLarge, runtime.stageBatch(&.{.{
        .display_name = "large.txt",
        .bytes = "x" ** 33,
    }}, &output));
    const image = try runtime.stageBatch(&.{.{
        .display_name = "large.png",
        .bytes = "\x89PNG\r\n\x1a\n" ++ "x" ** 40,
    }}, &output);
    try std.testing.expectEqual(Kind.image, image[0].kind);
    try std.testing.expect(runtime.release(image[0].id));

    const receive_id = try runtime.beginReceive(&.{.{
        .display_name = "received.txt",
        .size_bytes = 1,
    }});
    try runtime.appendReceive(receive_id, 0, 0, "\xff");
    try std.testing.expectError(error.UnsupportedType, runtime.finishReceive(receive_id, &output));
    try std.testing.expectEqual(@as(usize, 0), runtime.used_bytes);
    try std.testing.expect(runtime.receiving == null);
}
