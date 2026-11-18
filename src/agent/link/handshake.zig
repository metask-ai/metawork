//! The execution link's identity exchange.
//!
//! Both halves are the same executable, so in a healthy run the four fields
//! below are the same compile-time constants on both sides and the exchange is
//! a formality. It is not a formality in the two cases that actually happen:
//! an upgrade that leaves the previous exec still running while a new UI
//! starts, and two installs sharing one data directory. Either produces a
//! peer built from different sources, and a link that negotiated or degraded
//! would then run Product state against an Agent it was not built for.
//!
//! So each side states its identity and each side compares all four fields.
//! Any difference refuses the link; nothing here downgrades, picks a common
//! subset, or continues on an older revision. That is the same rule the
//! architecture already applies to consuming AgentCore itself.
//!
//! The build identity is supplied by the composition root, exactly as the
//! fault record's is, which keeps this module compilable and testable on its
//! own for both targets.

const std = @import("std");

pub const magic = "MWXL".*;

/// The execution link's own contract revision. It is not derived from the
/// product release version or from the AgentCore ABI revision, and changing it
/// is a contract change.
pub const revision: u16 = 1;

pub const Role = enum(u8) {
    ui = 1,
    exec = 2,

    pub fn peer(self: Role) Role {
        return switch (self) {
            .ui => .exec,
            .exec => .ui,
        };
    }
};

pub const version_bytes: usize = 32;
pub const digest_bytes: usize = 32;

pub const record_bytes: usize = 76;

pub const layout = struct {
    pub const magic_offset: usize = 0; // [4]u8
    pub const revision: usize = 4; // u16
    pub const role: usize = 6; // u8
    pub const reserved: usize = 7; // u8, must be zero
    pub const core_abi_revision: usize = 8; // u16
    pub const version_len: usize = 10; // u16
    pub const core_manifest_sha256: usize = 12; // [32]u8
    pub const version: usize = 44; // [32]u8, zero padded
};

comptime {
    std.debug.assert(layout.version + version_bytes == record_bytes);
    std.debug.assert(layout.core_manifest_sha256 + digest_bytes == layout.version);
}

/// Build identity, supplied by the composition root.
pub const Identity = struct {
    /// Product version string, which must fit `version_bytes`.
    version: []const u8,
    core_manifest_sha256: [digest_bytes]u8,
    core_abi_revision: u16,
};

pub const Record = struct {
    revision: u16,
    role: Role,
    core_abi_revision: u16,
    core_manifest_sha256: [digest_bytes]u8,
    version_storage: [version_bytes]u8,
    version_len: usize,

    pub fn version(self: *const Record) []const u8 {
        return self.version_storage[0..self.version_len];
    }
};

pub const EncodeError = error{VersionTooLong};

pub fn encode(
    output: *[record_bytes]u8,
    role: Role,
    identity: Identity,
) EncodeError!void {
    if (identity.version.len > version_bytes) return error.VersionTooLong;
    @memset(output, 0);
    @memcpy(output[layout.magic_offset..][0..magic.len], &magic);
    std.mem.writeInt(u16, output[layout.revision..][0..2], revision, .little);
    output[layout.role] = @intFromEnum(role);
    output[layout.reserved] = 0;
    std.mem.writeInt(u16, output[layout.core_abi_revision..][0..2], identity.core_abi_revision, .little);
    std.mem.writeInt(u16, output[layout.version_len..][0..2], @intCast(identity.version.len), .little);
    @memcpy(
        output[layout.core_manifest_sha256..][0..digest_bytes],
        &identity.core_manifest_sha256,
    );
    @memcpy(output[layout.version..][0..identity.version.len], identity.version);
}

pub const DecodeError = error{
    /// Not this protocol at all.
    NotALink,
    /// This protocol, but a field that must be zero was not, a role byte names
    /// nothing, or the version length exceeds the field.
    Malformed,
};

pub fn decode(bytes: *const [record_bytes]u8) DecodeError!Record {
    if (!std.mem.eql(u8, bytes[layout.magic_offset..][0..magic.len], &magic)) return error.NotALink;
    if (bytes[layout.reserved] != 0) return error.Malformed;
    const role = std.enums.fromInt(Role, bytes[layout.role]) orelse return error.Malformed;
    const version_len = std.mem.readInt(u16, bytes[layout.version_len..][0..2], .little);
    if (version_len > version_bytes) return error.Malformed;
    // Padding past the version must be zero, so one record has one encoding.
    for (bytes[layout.version + version_len ..][0 .. version_bytes - version_len]) |byte|
        if (byte != 0) return error.Malformed;
    var record: Record = .{
        .revision = std.mem.readInt(u16, bytes[layout.revision..][0..2], .little),
        .role = role,
        .core_abi_revision = std.mem.readInt(u16, bytes[layout.core_abi_revision..][0..2], .little),
        .core_manifest_sha256 = undefined,
        .version_storage = undefined,
        .version_len = version_len,
    };
    @memcpy(&record.core_manifest_sha256, bytes[layout.core_manifest_sha256..][0..digest_bytes]);
    @memcpy(&record.version_storage, bytes[layout.version..][0..version_bytes]);
    return record;
}

/// Why a peer's identity was refused. Each value is a reason the link must not
/// run, never a reason to retry on different terms.
pub const Refusal = enum {
    link_revision,
    role,
    product_version,
    core_manifest,
    core_abi_revision,
};

/// Compares a decoded peer record against this build. `expected_role` is the
/// peer's role, not our own.
pub fn accept(
    record: *const Record,
    expected_role: Role,
    identity: Identity,
) ?Refusal {
    if (record.revision != revision) return .link_revision;
    if (record.role != expected_role) return .role;
    if (record.core_abi_revision != identity.core_abi_revision) return .core_abi_revision;
    if (!std.mem.eql(u8, &record.core_manifest_sha256, &identity.core_manifest_sha256))
        return .core_manifest;
    if (!std.mem.eql(u8, record.version(), identity.version)) return .product_version;
    return null;
}

const test_identity: Identity = .{
    .version = "0.2.14",
    .core_manifest_sha256 = @splat(0xAB),
    .core_abi_revision = 28,
};

test "a record round-trips and the matching peer is accepted" {
    var bytes: [record_bytes]u8 = undefined;
    try encode(&bytes, .exec, test_identity);
    const record = try decode(&bytes);
    try std.testing.expectEqual(revision, record.revision);
    try std.testing.expectEqual(Role.exec, record.role);
    try std.testing.expectEqual(@as(u16, 28), record.core_abi_revision);
    try std.testing.expectEqualStrings("0.2.14", record.version());
    try std.testing.expectEqual(@as(?Refusal, null), accept(&record, .exec, test_identity));
}

test "an empty version is legal and still compares" {
    var bytes: [record_bytes]u8 = undefined;
    const identity: Identity = .{
        .version = "",
        .core_manifest_sha256 = @splat(0),
        .core_abi_revision = 0,
    };
    try encode(&bytes, .ui, identity);
    const record = try decode(&bytes);
    try std.testing.expectEqualStrings("", record.version());
    try std.testing.expectEqual(@as(?Refusal, null), accept(&record, .ui, identity));
    // An empty version is still compared, not treated as "any version".
    var named = identity;
    named.version = "0.2.14";
    try std.testing.expectEqual(@as(?Refusal, .product_version), accept(&record, .ui, named));
}

test "a version that does not fit the field fails rather than truncating" {
    var bytes: [record_bytes]u8 = undefined;
    try std.testing.expectError(error.VersionTooLong, encode(&bytes, .ui, .{
        .version = "0" ** (version_bytes + 1),
        .core_manifest_sha256 = @splat(0),
        .core_abi_revision = 1,
    }));
    // Exactly the field width is still legal.
    try encode(&bytes, .ui, .{
        .version = "0" ** version_bytes,
        .core_manifest_sha256 = @splat(0),
        .core_abi_revision = 1,
    });
    const record = try decode(&bytes);
    try std.testing.expectEqual(version_bytes, record.version().len);
}

test "each field on its own refuses the link" {
    var bytes: [record_bytes]u8 = undefined;
    try encode(&bytes, .exec, test_identity);

    {
        var record = try decode(&bytes);
        record.revision = revision + 1;
        try std.testing.expectEqual(@as(?Refusal, .link_revision), accept(&record, .exec, test_identity));
    }
    {
        const record = try decode(&bytes);
        try std.testing.expectEqual(@as(?Refusal, .role), accept(&record, .ui, test_identity));
    }
    {
        var record = try decode(&bytes);
        record.core_abi_revision = 29;
        try std.testing.expectEqual(@as(?Refusal, .core_abi_revision), accept(&record, .exec, test_identity));
    }
    {
        var record = try decode(&bytes);
        record.core_manifest_sha256[0] = 0;
        try std.testing.expectEqual(@as(?Refusal, .core_manifest), accept(&record, .exec, test_identity));
    }
    {
        var record = try decode(&bytes);
        record.version_storage[0] = 'x';
        try std.testing.expectEqual(@as(?Refusal, .product_version), accept(&record, .exec, test_identity));
    }
}

test "a foreign or malformed record never becomes a usable identity" {
    var bytes: [record_bytes]u8 = undefined;
    try encode(&bytes, .exec, test_identity);

    var foreign = bytes;
    foreign[0] = 'X';
    try std.testing.expectError(error.NotALink, decode(&foreign));

    var reserved = bytes;
    reserved[layout.reserved] = 1;
    try std.testing.expectError(error.Malformed, decode(&reserved));

    var role = bytes;
    role[layout.role] = 9;
    try std.testing.expectError(error.Malformed, decode(&role));

    var long = bytes;
    std.mem.writeInt(u16, long[layout.version_len..][0..2], version_bytes + 1, .little);
    try std.testing.expectError(error.Malformed, decode(&long));

    // Bytes past the stated version length must be zero: one record, one
    // encoding, so a peer cannot smuggle data through the padding.
    var padded = bytes;
    padded[layout.version + test_identity.version.len] = 'x';
    try std.testing.expectError(error.Malformed, decode(&padded));
}
