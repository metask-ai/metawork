//! The execution link's payload codec.
//!
//! The port's argument and result types are already declared as plain data
//! (`surface.zig` says so in its first line), so the wire reads them
//! structurally instead of through fifty-odd hand-written encoders. Two
//! reasons, and the second is the important one: there is far less code, and a
//! type that gains a field gains it on the wire too, where a hand-written
//! encoder would silently keep sending the old shape.
//!
//! What it refuses is the point of the design. `requireStructural` is a
//! compile error for anything the wire cannot honestly carry -- a pointer to
//! an implementation handle, a function pointer, an allocator, an `anyopaque`,
//! a non-exhaustive enum. Those are exactly the places where a cross-process
//! call needs a decision rather than a serializer: a handle becomes an id a
//! table resolves, a byte sink becomes a descriptor the far side writes
//! itself. `classify` enumerates them so the decisions can be counted rather
//! than discovered one crash at a time.
//!
//! Decoding borrows. A `[]const u8` points into the payload buffer, which is
//! the reassembly buffer the reader owns for the length of the call; every
//! other slice is built in a caller-supplied arena. That matches the existing
//! rule for data crossing a boundary: valid for the call, deep-copied by
//! whoever wants to keep it.
//!
//! Decoding is strict in the Bridge sense. A bool that is not 0 or 1, an enum
//! tag this build does not declare, a length past the end of the payload, or
//! bytes left over at the end are all protocol violations, not values to
//! repair.

const std = @import("std");

pub const DecodeError = error{
    /// The payload ended in the middle of a value.
    Truncated,
    /// A byte pattern no declared value claims.
    Malformed,
    /// Bytes left over after a complete value.
    TrailingBytes,
} || std.mem.Allocator.Error;

/// Why a type cannot cross structurally. Each value names a decision the
/// cross-process call has to make instead.
pub const Obstruction = enum {
    /// A pointer into the implementation: becomes an id a handle table
    /// resolves on the far side.
    handle_pointer,
    /// A callback: the far side performs the effect itself and the wire
    /// carries a descriptor for it.
    callback,
    /// An allocator: ownership is the receiver's, so it never crosses.
    allocator,
    /// An untyped pointer, which says nothing about what it points at.
    untyped_pointer,
    /// A non-exhaustive enum or an error set: both would let an unknown value
    /// through, which the link refuses by design.
    open_value,
};

pub const Classification = union(enum) {
    structural,
    substituted: Obstruction,
};

/// Classifies a type without failing the build, so a registry can count the
/// decisions still owed.
pub fn classify(comptime T: type) Classification {
    @setEvalBranchQuota(100_000);
    return switch (@typeInfo(T)) {
        .void, .bool, .int, .float => .structural,
        .@"enum" => |info| if (info.is_exhaustive)
            .structural
        else
            .{ .substituted = .open_value },
        .error_set, .error_union => .{ .substituted = .open_value },
        .optional => |info| classify(info.child),
        .array => |info| classify(info.child),
        .vector => |info| classify(info.child),
        .@"struct" => |info| blk: {
            if (T == std.mem.Allocator) break :blk .{ .substituted = .allocator };
            inline for (info.fields) |field| switch (classify(field.type)) {
                .structural => {},
                .substituted => |why| break :blk .{ .substituted = why },
            };
            break :blk .structural;
        },
        .@"union" => |info| blk: {
            if (info.tag_type == null) break :blk .{ .substituted = .open_value };
            inline for (info.fields) |field| switch (classify(field.type)) {
                .structural => {},
                .substituted => |why| break :blk .{ .substituted = why },
            };
            break :blk .structural;
        },
        .pointer => |info| switch (info.size) {
            .slice => classify(info.child),
            .one, .many, .c => if (info.child == anyopaque)
                .{ .substituted = .untyped_pointer }
            else if (@typeInfo(info.child) == .@"fn")
                .{ .substituted = .callback }
            else
                .{ .substituted = .handle_pointer },
        },
        .@"fn" => .{ .substituted = .callback },
        .@"opaque" => .{ .substituted = .handle_pointer },
        else => .{ .substituted = .open_value },
    };
}

/// Fails the build, naming the type and what has to replace it.
pub fn requireStructural(comptime T: type) void {
    comptime {
        switch (classify(T)) {
            .structural => {},
            .substituted => |why| @compileError(
                "the execution link cannot carry " ++ @typeName(T) ++ " structurally (" ++
                    @tagName(why) ++ "); give it an explicit wire shape instead of a serializer",
            ),
        }
    }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Slice lengths and union tags ride as `u32`, which bounds a single slice to
/// 4 GiB -- far above every message limit the link enforces.
const Length = u32;

fn intBytes(comptime T: type) usize {
    return @divExact((@typeInfo(T).int.bits + 7) & ~@as(u16, 7), 8);
}

/// The byte-aligned integer an int of `T`'s width travels as. A union tag can
/// be a `u1` and an enum tag a `u2`; both ride in whole bytes, and the value
/// is range-checked on the way back rather than truncated.
fn Wire(comptime T: type) type {
    return std.meta.Int(@typeInfo(T).int.signedness, intBytes(T) * 8);
}

/// How many bytes `value` encodes to.
pub fn encodedSize(comptime T: type, value: T) usize {
    requireStructural(T);
    return switch (@typeInfo(T)) {
        .void => 0,
        .bool => 1,
        .int => intBytes(T),
        .@"enum" => |info| intBytes(info.tag_type),
        .optional => |info| 1 + if (value) |inner| encodedSize(info.child, inner) else 0,
        .array => |info| blk: {
            var total: usize = 0;
            for (value) |element| total += encodedSize(info.child, element);
            break :blk total;
        },
        .@"struct" => |info| blk: {
            var total: usize = 0;
            inline for (info.fields) |field|
                total += encodedSize(field.type, @field(value, field.name));
            break :blk total;
        },
        .@"union" => |info| blk: {
            var total: usize = intBytes(@typeInfo(info.tag_type.?).@"enum".tag_type);
            switch (value) {
                inline else => |payload, tag| total += encodedSize(
                    @FieldType(T, @tagName(tag)),
                    payload,
                ),
            }
            break :blk total;
        },
        .pointer => |info| blk: {
            var total: usize = intBytes(Length);
            for (value) |element| total += encodedSize(info.child, element);
            break :blk total;
        },
        else => comptime unreachable,
    };
}

/// Writes `value` into `out`, which must be at least `encodedSize` long.
/// Returns how many bytes were written.
pub fn encode(comptime T: type, value: T, out: []u8) usize {
    requireStructural(T);
    switch (@typeInfo(T)) {
        .void => return 0,
        .bool => {
            out[0] = @intFromBool(value);
            return 1;
        },
        .int => {
            const width = comptime intBytes(T);
            var storage: [width]u8 = undefined;
            std.mem.writeInt(Wire(T), &storage, value, .little);
            @memcpy(out[0..width], &storage);
            return width;
        },
        .@"enum" => |info| return encode(info.tag_type, @intFromEnum(value), out),
        .optional => |info| {
            out[0] = @intFromBool(value != null);
            if (value) |inner| return 1 + encode(info.child, inner, out[1..]);
            return 1;
        },
        .array => |info| {
            var offset: usize = 0;
            for (value) |element| offset += encode(info.child, element, out[offset..]);
            return offset;
        },
        .@"struct" => |info| {
            var offset: usize = 0;
            inline for (info.fields) |field|
                offset += encode(field.type, @field(value, field.name), out[offset..]);
            return offset;
        },
        .@"union" => |info| {
            const Tag = @typeInfo(info.tag_type.?).@"enum".tag_type;
            var offset = encode(Tag, @intFromEnum(value), out);
            switch (value) {
                inline else => |payload, tag| offset += encode(
                    @FieldType(T, @tagName(tag)),
                    payload,
                    out[offset..],
                ),
            }
            return offset;
        },
        .pointer => |info| {
            var offset = encode(Length, @intCast(value.len), out);
            for (value) |element| offset += encode(info.child, element, out[offset..]);
            return offset;
        },
        else => comptime unreachable,
    }
}

pub fn Decoded(comptime T: type) type {
    return struct { value: T, consumed: usize };
}

/// Reads one `T` from `bytes`. `[]const u8` results borrow `bytes`; every
/// other slice is allocated in `arena`.
pub fn decode(
    comptime T: type,
    arena: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!Decoded(T) {
    requireStructural(T);
    switch (@typeInfo(T)) {
        .void => return .{ .value = {}, .consumed = 0 },
        .bool => {
            if (bytes.len < 1) return error.Truncated;
            // A bool is exactly two byte patterns. Anything else is a
            // different protocol, not a true value.
            return switch (bytes[0]) {
                0 => .{ .value = false, .consumed = 1 },
                1 => .{ .value = true, .consumed = 1 },
                else => error.Malformed,
            };
        },
        .int => {
            const width = comptime intBytes(T);
            if (bytes.len < width) return error.Truncated;
            var storage: [width]u8 = undefined;
            @memcpy(&storage, bytes[0..width]);
            const raw = std.mem.readInt(Wire(T), &storage, .little);
            // A narrow field rides in whole bytes, so the peer can put a
            // value in them that the field cannot hold. That is a protocol
            // violation, not a number to truncate.
            const value = std.math.cast(T, raw) orelse return error.Malformed;
            return .{ .value = value, .consumed = width };
        },
        .@"enum" => |info| {
            const tag = try decode(info.tag_type, arena, bytes);
            const value = std.enums.fromInt(T, tag.value) orelse return error.Malformed;
            return .{ .value = value, .consumed = tag.consumed };
        },
        .optional => |info| {
            if (bytes.len < 1) return error.Truncated;
            switch (bytes[0]) {
                0 => return .{ .value = null, .consumed = 1 },
                1 => {
                    const inner = try decode(info.child, arena, bytes[1..]);
                    return .{ .value = inner.value, .consumed = 1 + inner.consumed };
                },
                else => return error.Malformed,
            }
        },
        .array => |info| {
            var value: T = undefined;
            var offset: usize = 0;
            for (&value) |*slot| {
                const element = try decode(info.child, arena, bytes[offset..]);
                slot.* = element.value;
                offset += element.consumed;
            }
            return .{ .value = value, .consumed = offset };
        },
        .@"struct" => |info| {
            var value: T = undefined;
            var offset: usize = 0;
            inline for (info.fields) |field| {
                const decoded = try decode(field.type, arena, bytes[offset..]);
                @field(value, field.name) = decoded.value;
                offset += decoded.consumed;
            }
            return .{ .value = value, .consumed = offset };
        },
        .@"union" => |info| {
            const TagEnum = info.tag_type.?;
            const tag = try decode(TagEnum, arena, bytes);
            var offset = tag.consumed;
            inline for (info.fields) |field| {
                if (tag.value == @field(TagEnum, field.name)) {
                    const decoded = try decode(field.type, arena, bytes[offset..]);
                    offset += decoded.consumed;
                    return .{
                        .value = @unionInit(T, field.name, decoded.value),
                        .consumed = offset,
                    };
                }
            }
            return error.Malformed;
        },
        .pointer => |info| {
            const length = try decode(Length, arena, bytes);
            var offset = length.consumed;
            const count: usize = length.value;
            if (info.child == u8) {
                // Borrowed in place: the payload buffer outlives the call.
                if (bytes.len - offset < count) return error.Truncated;
                const borrowed = bytes[offset..][0..count];
                return .{ .value = borrowed, .consumed = offset + count };
            }
            const elements = try arena.alloc(ElementOf(T), count);
            for (elements) |*slot| {
                const decoded = try decode(info.child, arena, bytes[offset..]);
                slot.* = decoded.value;
                offset += decoded.consumed;
            }
            return .{ .value = elements, .consumed = offset };
        },
        else => comptime unreachable,
    }
}

fn ElementOf(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

/// Decodes a whole payload, refusing anything left over. Every request and
/// response body goes through this rather than `decode`, so a peer cannot
/// append bytes a later build might start reading.
pub fn decodeExact(
    comptime T: type,
    arena: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!T {
    const decoded = try decode(T, arena, bytes);
    if (decoded.consumed != bytes.len) return error.TrailingBytes;
    return decoded.value;
}

/// Encodes into a fresh arena allocation sized by `encodedSize`.
pub fn encodeAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: T,
) std.mem.Allocator.Error![]u8 {
    const buffer = try allocator.alloc(u8, encodedSize(T, value));
    const written = encode(T, value, buffer);
    std.debug.assert(written == buffer.len);
    return buffer;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(comptime T: type, value: T) !T {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try encodeAlloc(T, arena.allocator(), value);
    return try decodeExact(T, arena.allocator(), bytes);
}

test "scalars, enums and optionals round-trip" {
    try testing.expectEqual(@as(u64, 0), try roundTrip(u64, 0));
    try testing.expectEqual(std.math.maxInt(u64), try roundTrip(u64, std.math.maxInt(u64)));
    try testing.expectEqual(@as(u16, 513), try roundTrip(u16, 513));
    try testing.expectEqual(true, try roundTrip(bool, true));
    try testing.expectEqual(false, try roundTrip(bool, false));

    const Mode = enum(u8) { a, b, c };
    try testing.expectEqual(Mode.c, try roundTrip(Mode, .c));
    try testing.expectEqual(@as(?Mode, null), try roundTrip(?Mode, null));
    try testing.expectEqual(@as(?Mode, .b), try roundTrip(?Mode, .b));
    try testing.expectEqual(@as(?u32, 7), try roundTrip(?u32, 7));
}

test "a byte slice borrows the payload instead of copying it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text: []const u8 = "borrowed";
    const bytes = try encodeAlloc([]const u8, arena.allocator(), text);
    const decoded = try decodeExact([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings(text, decoded);
    // The result points into the payload, which is what makes a call free of
    // a copy and what makes it invalid after the call.
    try testing.expect(@intFromPtr(decoded.ptr) >= @intFromPtr(bytes.ptr));
    try testing.expect(@intFromPtr(decoded.ptr) + decoded.len <= @intFromPtr(bytes.ptr) + bytes.len);
}

test "nested structs, slices of structs and tagged unions round-trip" {
    const Inner = struct { id: u64, name: []const u8, flag: bool };
    const Shape = union(enum) { nothing, one: Inner, many: []const Inner };
    const Outer = struct {
        header: []const u8,
        items: []const Inner,
        shape: Shape,
        count: ?u32,
    };

    const items = [_]Inner{
        .{ .id = 1, .name = "first", .flag = true },
        .{ .id = 2, .name = "", .flag = false },
    };
    const value: Outer = .{
        .header = "h",
        .items = &items,
        .shape = .{ .many = &items },
        .count = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try encodeAlloc(Outer, arena.allocator(), value);
    const decoded = try decodeExact(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("h", decoded.header);
    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    try testing.expectEqual(@as(u64, 1), decoded.items[0].id);
    try testing.expectEqualStrings("first", decoded.items[0].name);
    try testing.expectEqual(true, decoded.items[0].flag);
    try testing.expectEqualStrings("", decoded.items[1].name);
    try testing.expectEqual(@as(usize, 2), decoded.shape.many.len);
    try testing.expectEqual(@as(?u32, null), decoded.count);

    // An empty slice is a length and nothing else.
    const empty: Outer = .{ .header = "", .items = &.{}, .shape = .nothing, .count = 0 };
    const empty_bytes = try encodeAlloc(Outer, arena.allocator(), empty);
    const empty_decoded = try decodeExact(Outer, arena.allocator(), empty_bytes);
    try testing.expectEqual(@as(usize, 0), empty_decoded.items.len);
    try testing.expectEqual(Shape.nothing, empty_decoded.shape);
}

test "the decoder refuses what the encoder cannot have produced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A bool is two patterns.
    try testing.expectError(error.Malformed, decodeExact(bool, arena.allocator(), &.{2}));
    try testing.expectError(error.Truncated, decodeExact(bool, arena.allocator(), &.{}));

    // An enum tag this build does not declare.
    const Mode = enum(u8) { a, b };
    try testing.expectError(error.Malformed, decodeExact(Mode, arena.allocator(), &.{9}));

    // An optional's presence byte is also two patterns.
    try testing.expectError(error.Malformed, decodeExact(?u8, arena.allocator(), &.{ 3, 0 }));

    // A length past the end of the payload.
    var truncated: [8]u8 = @splat(0);
    std.mem.writeInt(u32, truncated[0..4], 16, .little);
    try testing.expectError(
        error.Truncated,
        decodeExact([]const u8, arena.allocator(), truncated[0..5]),
    );

    // Bytes left over: a peer cannot append what a later build might read.
    const bytes = try encodeAlloc(u32, arena.allocator(), 1);
    const padded = try arena.allocator().alloc(u8, bytes.len + 1);
    @memcpy(padded[0..bytes.len], bytes);
    padded[bytes.len] = 0;
    try testing.expectError(error.TrailingBytes, decodeExact(u32, arena.allocator(), padded));

    // A union tag with no field.
    const Shape = union(enum) { a: u8, b: u16 };
    try testing.expectError(error.Malformed, decodeExact(Shape, arena.allocator(), &.{ 7, 0, 0 }));
}

test "classification names the decision a type owes instead of guessing" {
    const Opaque = opaque {};
    try testing.expectEqual(Classification.structural, classify(u32));
    try testing.expectEqual(Classification.structural, classify([]const u8));
    try testing.expectEqual(Classification.structural, classify(?[]const []const u8));
    try testing.expectEqual(
        Classification{ .substituted = .allocator },
        classify(std.mem.Allocator),
    );
    try testing.expectEqual(
        Classification{ .substituted = .handle_pointer },
        classify(*Opaque),
    );
    try testing.expectEqual(
        Classification{ .substituted = .untyped_pointer },
        classify(?*anyopaque),
    );
    try testing.expectEqual(
        Classification{ .substituted = .callback },
        classify(*const fn () void),
    );
    try testing.expectEqual(
        Classification{ .substituted = .open_value },
        classify(error{Nope}),
    );
    const Open = enum(u8) { a, _ };
    try testing.expectEqual(Classification{ .substituted = .open_value }, classify(Open));

    // A struct is only as structural as its worst field, and the reason
    // travels out so the message can name it.
    const Mixed = struct { id: u64, sink: *const fn () void };
    try testing.expectEqual(Classification{ .substituted = .callback }, classify(Mixed));
}
