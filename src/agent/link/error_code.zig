//! The execution link's error domain.
//!
//! `surface.Error` is part of the Agent contract, so a cross-process call has
//! to carry it exactly: the caller maps these values onto admission
//! results, retry states and Run terminals, and collapsing them into one
//! generic failure would let a link problem be recorded as an Agent terminal
//! cause. Every member therefore gets a stable number of its own, assigned
//! here and never reused.
//!
//! The mapping is closed in both directions at compile time. `comptime`
//! blocks below assert that every member of the error set has a code and that
//! every code names a member, so adding an error to `surface.Error` without
//! adding it here does not compile. An unregistered code arriving from the
//! peer is a protocol violation, not a value to approximate.

const std = @import("std");
const contract = @import("agent_contract");

const Error = contract.surface.Error;

/// `OutOfMemory` is not in `surface.Error`, but `Allocating` adds it to most
/// of the port's methods, so the wire needs it too. It sits above the
/// contract block rather than inside it.
pub const out_of_memory_code: u16 = 1000;

pub const Entry = struct {
    name: [:0]const u8,
    code: u16,
};

/// Stable wire numbers. Order here is the declaration order of
/// `surface.Error`; the numbers are what matter and must never be reassigned.
pub const entries = [_]Entry{
    .{ .name = "InvalidLimits", .code = 1 },
    .{ .name = "InvalidWorkspace", .code = 2 },
    .{ .name = "WorkspaceNotTrusted", .code = 3 },
    .{ .name = "InvalidCatalogQuery", .code = 4 },
    .{ .name = "InvalidCatalogDescriptor", .code = 5 },
    .{ .name = "DuplicateCatalogIdentity", .code = 6 },
    .{ .name = "SkillCatalogInvalid", .code = 7 },
    .{ .name = "SkillCatalogIncomplete", .code = 8 },
    .{ .name = "CatalogResourceLimit", .code = 9 },
    .{ .name = "CatalogReleaseFailed", .code = 10 },
    .{ .name = "CatalogLeasesOutstanding", .code = 11 },
    .{ .name = "CatalogBindingMismatch", .code = 12 },
    .{ .name = "InvalidSkillPolicy", .code = 13 },
    .{ .name = "CatalogRefreshFailed", .code = 14 },
    .{ .name = "McpRefreshFailed", .code = 15 },
    .{ .name = "McpRefreshRejected", .code = 16 },
    .{ .name = "InvalidMcpCatalogDescriptor", .code = 17 },
    .{ .name = "McpCatalogResourceLimit", .code = 18 },
    .{ .name = "McpCatalogGenerationMismatch", .code = 19 },
    .{ .name = "McpCatalogBindingMismatch", .code = 20 },
    .{ .name = "InvalidMcpSelection", .code = 21 },
    .{ .name = "StaleMcpSelection", .code = 22 },
    .{ .name = "McpRestoreSourceChanged", .code = 23 },
    .{ .name = "McpRefreshInProgress", .code = 24 },
    .{ .name = "McpConfigurationApplyFailed", .code = 25 },
    .{ .name = "McpConfigurationApplyUncertain", .code = 26 },
    .{ .name = "McpConfigurationApplyLimit", .code = 27 },
    .{ .name = "McpNotRefreshed", .code = 28 },
    .{ .name = "McpCheckpointBudgetRequired", .code = 29 },
    .{ .name = "McpSelectionUpdateFailed", .code = 30 },
    .{ .name = "McpRuntimeIdentityExhausted", .code = 31 },
    .{ .name = "RuntimeShuttingDown", .code = 32 },
    .{ .name = "SessionCapacity", .code = 33 },
    .{ .name = "UnknownSession", .code = 34 },
    .{ .name = "SessionNotClosed", .code = 35 },
    .{ .name = "CoreCallFailed", .code = 36 },
    .{ .name = "PermissionModeUpdateFailed", .code = 37 },
    .{ .name = "PermissionModeBudgetRequired", .code = 38 },
    .{ .name = "QueueFull", .code = 39 },
    .{ .name = "SessionNotIdle", .code = 40 },
    .{ .name = "SessionPoisoned", .code = 41 },
    .{ .name = "SessionClosing", .code = 42 },
    .{ .name = "InvalidRunInput", .code = 43 },
    .{ .name = "InvalidCredential", .code = 44 },
    .{ .name = "CredentialUpdateFailed", .code = 45 },
    .{ .name = "CredentialUpdateResourceLimit", .code = 46 },
    .{ .name = "CredentialUpdateContract", .code = 47 },
    .{ .name = "RunInputTooLarge", .code = 48 },
    .{ .name = "RunInputBudgetExceeded", .code = 49 },
    .{ .name = "RunIdExhausted", .code = 50 },
    .{ .name = "RunGenerationExhausted", .code = 51 },
    .{ .name = "CompactIdExhausted", .code = 52 },
    .{ .name = "SessionIdExhausted", .code = 53 },
    .{ .name = "NoSuchRun", .code = 54 },
    .{ .name = "NoSuchCompact", .code = 55 },
    .{ .name = "NoPendingUiRequest", .code = 56 },
    .{ .name = "StaleUiResponse", .code = 57 },
    .{ .name = "InvalidUiResponse", .code = 58 },
    .{ .name = "StateNotReached", .code = 59 },
    .{ .name = "SessionDestroyFailed", .code = 60 },
    .{ .name = "RuntimeDestroyFailed", .code = 61 },
    .{ .name = "RestoreInvalid", .code = 62 },
    .{ .name = "RestoreBusy", .code = 63 },
    .{ .name = "RestoreFailed", .code = 64 },
    .{ .name = "RestoreCancelled", .code = 65 },
    .{ .name = "RestoreIoFailed", .code = 66 },
    .{ .name = "RestoreContractFailed", .code = 67 },
    .{ .name = "CheckpointCorrupt", .code = 68 },
    .{ .name = "CheckpointUnsupported", .code = 69 },
    .{ .name = "CheckpointIncompatible", .code = 70 },
    .{ .name = "LogicalSessionConflict", .code = 71 },
};

/// The error set every link call can produce: the contract set plus the
/// allocation failure the port's `Allocating` alias adds.
pub const LinkError = Error || std.mem.Allocator.Error;

comptime {
    @setEvalBranchQuota(entries.len * entries.len * 8);
    // Every member of the contract set has exactly one code.
    const set = @typeInfo(Error).error_set.?;
    if (set.len != entries.len) @compileError(
        "surface.Error has " ++ std.fmt.comptimePrint("{d}", .{set.len}) ++
            " members but the link registers " ++
            std.fmt.comptimePrint("{d}", .{entries.len}),
    );
    for (set) |member| {
        var found = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.name, member.name)) {
                if (found) @compileError("duplicate link code for " ++ member.name);
                found = true;
            }
        }
        if (!found) @compileError(
            "surface.Error." ++ member.name ++ " has no execution link code; " ++
                "add one in src/agent/link/error_code.zig and never reuse a number",
        );
    }
    // Every registered code names a member, and no number repeats.
    for (entries, 0..) |entry, index| {
        if (entry.code == 0 or entry.code == out_of_memory_code) @compileError(
            "link code for " ++ entry.name ++ " collides with a reserved number",
        );
        for (entries[index + 1 ..]) |other| {
            if (entry.code == other.code) @compileError(
                "link code " ++ std.fmt.comptimePrint("{d}", .{entry.code}) ++
                    " is used by both " ++ entry.name ++ " and " ++ other.name,
            );
            if (std.mem.eql(u8, entry.name, other.name)) @compileError(
                "duplicate link entry for " ++ entry.name,
            );
        }
        var known = false;
        for (set) |member| {
            if (std.mem.eql(u8, entry.name, member.name)) known = true;
        }
        if (!known) @compileError(
            "the link registers " ++ entry.name ++ ", which surface.Error no longer declares",
        );
    }
}

/// The wire number for an error. Total by construction.
pub fn encode(err: LinkError) u16 {
    @setEvalBranchQuota(entries.len * 64);
    if (err == error.OutOfMemory) return out_of_memory_code;
    inline for (entries) |entry| {
        if (err == @field(anyerror, entry.name)) return entry.code;
    }
    unreachable;
}

/// `null` means the number is not registered in this build. The peer is our
/// own binary, so an unregistered number means the link is talking to
/// something else, and the caller fails closed rather than approximating.
pub fn decode(code: u16) ?LinkError {
    @setEvalBranchQuota(entries.len * 64);
    if (code == out_of_memory_code) return error.OutOfMemory;
    inline for (entries) |entry| {
        if (code == entry.code) return @field(anyerror, entry.name);
    }
    return null;
}

/// The same decode narrowed to `surface.Error`. A port result that declares
/// the contract set cannot hold `OutOfMemory`, so a peer sending that number
/// where a contract error belongs is a protocol violation, not an allocation
/// failure to pass along.
pub fn decodeContract(code: u16) ?Error {
    @setEvalBranchQuota(entries.len * 64);
    inline for (entries) |entry| {
        if (code == entry.code) return @field(Error, entry.name);
    }
    return null;
}

/// Writes the registered mapping, one `code name` pair per line. The
/// cross-process port review reads this instead of a table kept by hand.
pub fn writeTable(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (entries) |entry| try writer.print("{d} {s}" ++ newline, .{ entry.code, entry.name });
    try writer.print("{d} OutOfMemory" ++ newline, .{out_of_memory_code});
}

const newline = "\n";

test "every contract error round-trips through its wire number" {
    @setEvalBranchQuota(entries.len * 64);
    inline for (entries) |entry| {
        const err = @field(anyerror, entry.name);
        try std.testing.expectEqual(entry.code, encode(err));
        try std.testing.expectEqual(err, decode(entry.code).?);
    }
    try std.testing.expectEqual(out_of_memory_code, encode(error.OutOfMemory));
    try std.testing.expectEqual(error.OutOfMemory, decode(out_of_memory_code).?);
}

test "an unregistered number fails closed instead of approximating" {
    try std.testing.expect(decode(0) == null);
    try std.testing.expect(decode(@intCast(entries.len + 1)) == null);
    try std.testing.expect(decode(std.math.maxInt(u16)) == null);
}

test "the registered mapping covers the whole contract set" {
    @setEvalBranchQuota(entries.len * 64);
    var storage: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeTable(&writer);
    const table = writer.buffered();
    const set = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(set.len + 1, std.mem.count(u8, table, newline));
    inline for (set) |member| {
        try std.testing.expect(std.mem.indexOf(u8, table, " " ++ member.name ++ newline) != null);
    }
}
