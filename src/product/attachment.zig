//! Transient Product-owned image/PDF staging.
const std = @import("std");

pub const Format = enum { png, jpeg, webp, pdf };
pub const Kind = enum { image, pdf };
pub const State = enum { ready, borrowed };

pub const Limits = struct {
    max_files: usize,
    max_display_name_bytes: usize,
    max_image_bytes: usize,
    max_pdf_bytes: usize,
    max_staged_bytes: usize,
};

pub const Candidate = struct {
    display_name: []const u8,
    format: Format,
    bytes: []const u8,
};

pub const Descriptor = struct {
    id: u64,
    kind: Kind,
    format: Format,
    display_name: []const u8,
    size_bytes: u64,
};

pub const BorrowedPart = struct {
    id: u64,
    format: Format,
    bytes: []const u8,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidLimits,
    EmptyBatch,
    TooManyFiles,
    InvalidDisplayName,
    EmptyFile,
    FileTooLarge,
    UnsupportedType,
    StagingCapacity,
    IdentityExhausted,
    UnknownAttachment,
    AttachmentBusy,
    DuplicateAttachment,
};

const Entry = struct {
    id: u64,
    state: State,
    format: Format,
    display_name: []u8,
    bytes: []u8,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    slots: []?Entry,
    used_bytes: usize = 0,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Runtime {
        if (limits.max_files == 0 or
            limits.max_display_name_bytes == 0 or
            limits.max_image_bytes == 0 or
            limits.max_pdf_bytes == 0 or
            limits.max_staged_bytes == 0)
            return error.InvalidLimits;
        const slots = try allocator.alloc(?Entry, limits.max_files);
        @memset(slots, null);
        return .{ .allocator = allocator, .limits = limits, .slots = slots };
    }

    pub fn deinit(self: *Runtime) void {
        for (self.slots) |*slot| if (slot.*) |*entry| self.destroyEntry(entry);
        self.allocator.free(self.slots);
        self.* = undefined;
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
            try self.validate(candidate);
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
                .format = candidate.format,
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
            parts[index] = .{ .id = entry.id, .format = entry.format, .bytes = entry.bytes };
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

    fn validate(self: *const Runtime, candidate: Candidate) Error!void {
        if (!validDisplayName(candidate.display_name, self.limits.max_display_name_bytes))
            return error.InvalidDisplayName;
        if (candidate.bytes.len == 0) return error.EmptyFile;
        const max_bytes = switch (candidate.format) {
            .png, .jpeg, .webp => self.limits.max_image_bytes,
            .pdf => self.limits.max_pdf_bytes,
        };
        if (candidate.bytes.len > max_bytes) return error.FileTooLarge;
        if (!matches(candidate.format, candidate.bytes)) return error.UnsupportedType;
    }

    fn descriptor(_: *const Runtime, entry: Entry) Descriptor {
        return .{
            .id = entry.id,
            .kind = if (entry.format == .pdf) .pdf else .image,
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
        return count;
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
        .pdf => bytes.len >= 5 and std.mem.eql(u8, bytes[0..5], "%PDF-"),
    };
}

fn testLimits() Limits {
    return .{
        .max_files = 4,
        .max_display_name_bytes = 64,
        .max_image_bytes = 64,
        .max_pdf_bytes = 128,
        .max_staged_bytes = 160,
    };
}

test "staging validates signatures and rolls back a failed batch atomically" {
    var runtime = try Runtime.init(std.testing.allocator, testLimits());
    defer runtime.deinit();
    const candidates = [_]Candidate{
        .{ .display_name = "ok.png", .format = .png, .bytes = "\x89PNG\r\n\x1a\npayload" },
        .{ .display_name = "bad.pdf", .format = .pdf, .bytes = "not a pdf" },
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
        .{ .display_name = "a.webp", .format = .webp, .bytes = "RIFFxxxxWEBPdata" },
        .{ .display_name = "b.pdf", .format = .pdf, .bytes = "%PDF-1.7" },
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
        .format = .jpeg,
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
