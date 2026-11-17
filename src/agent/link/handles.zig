//! What happens to each method Product calls on an Agent-owned opaque handle.
//!
//! Replacing the port's vtable is not the whole call surface. These handles
//! live in the Agent, the contract module re-exports them, and an opaque type
//! can carry methods -- so Product reaches into the execution half without
//! going through `port.zig` at all. The import guard does not catch it,
//! because the type it names is a contract export.
//!
//! Each method is sorted into one of three, and the boundary between the first
//! two is not "is it a read":
//!
//!   * `call` -- it changes state on the far side, or the answer can change
//!     after a projection is taken and a stale answer would look exactly like
//!     a correct one. Answering locally would invent a fact.
//!   * `projected` -- the answer is fixed once the handle exists, so it rides
//!     across with the handle and the near side answers from it. This is the
//!     same licence the event pump has: a buffer of what the far side sent,
//!     not a decision of its own.
//!   * `release` -- it hands ownership back, so it is a call whose order
//!     against its acquisition matters.
//!
//! The classification is closed against the compiler in both directions. Every
//! public declaration of every registered handle must appear here, and every
//! entry must name a declaration that still exists, so a method added to one
//! of these types fails the build instead of quietly reaching across a process
//! boundary. A hand-kept table would drift, and it would drift green.

const std = @import("std");
const mcp_catalog = @import("agent_mcp_catalog");
const catalog = @import("agent_catalog");
const port = @import("agent_contract").port;

pub const Disposition = enum {
    call,
    projected,
    release,
};

pub const Method = struct {
    name: [:0]const u8,
    disposition: Disposition,
    /// Why, in the terms above. Stated per method because the reason is what a
    /// later reader needs in order to not move it.
    reason: []const u8,
};

/// Which Agent module hands the handle out. Recorded rather than matched out
/// of `@typeName`, because the skill catalog and the MCP catalog both produce
/// type names beginning `catalog.` and a string match would confuse them.
pub const Owner = enum {
    mcp_catalog,
    skill_catalog,
    port,
};

pub const Handle = struct {
    name: []const u8,
    owner: Owner,
    methods: []const Method,
};

/// Every opaque type the Agent hands out that carries methods, with what
/// becomes of each one. `catalog.Lease` and `port.SkillRestoreInputs` are also
/// opaque and also held by the caller, but carry no methods at all, which is
/// why they need nothing here beyond the assertion below.
pub const handles = [_]Handle{
    describe(mcp_catalog.Activation, .mcp_catalog, &.{
        .{
            .name = "deinit",
            .disposition = .release,
            .reason = "frees the activation, its nested selection and its projection as one tree",
        },
        .{
            .name = "registryGeneration",
            .disposition = .projected,
            .reason = "set when the activation is built and never written again",
        },
        .{
            .name = "catalogGeneration",
            .disposition = .projected,
            .reason = "the projection's generation, immutable for that projection",
        },
        .{
            .name = "state",
            .disposition = .projected,
            .reason = "set when the activation is built and never written again",
        },
        .{
            .name = "serverHealth",
            .disposition = .projected,
            .reason = "published_servers, filled at build time",
        },
        .{
            .name = "selectedTools",
            .disposition = .projected,
            .reason = "published_tools, a separate field that takeSelection does not touch, " ++
                "so it stays true after the selection is taken",
        },
        .{
            .name = "catalogServers",
            .disposition = .projected,
            .reason = "the projection's servers, immutable for that projection",
        },
        .{
            .name = "catalogTools",
            .disposition = .projected,
            .reason = "the projection's tools, immutable for that projection",
        },
        .{
            .name = "catalogIssues",
            .disposition = .projected,
            .reason = "the projection's issues, immutable for that projection",
        },
        .{
            .name = "catalogAgeMs",
            .disposition = .call,
            .reason = "elapsed time against the clock now: a projected age is stale the " ++
                "instant it crosses and a stale age looks exactly like a fresh one. " ++
                "Projecting the observation stamp instead would need the two processes' " ++
                "awake clocks to be comparable, which is a separate claim and not assumed here",
        },
        .{
            .name = "takeSelection",
            .disposition = .call,
            .reason = "clears the activation's selection field and hands the handle out",
        },
    }),
    describe(mcp_catalog.Selection, .mcp_catalog, &.{
        .{
            .name = "deinit",
            .disposition = .release,
            .reason = "frees the selection's own arena",
        },
        .{
            .name = "selectedTools",
            .disposition = .projected,
            .reason = "selected_tools, filled when the selection is created",
        },
    }),
    describe(mcp_catalog.RestoreSelection, .mcp_catalog, &.{
        .{
            .name = "isEmpty",
            .disposition = .projected,
            .reason = "the tool count, fixed when the restore selection is captured",
        },
        .{
            .name = "deinit",
            .disposition = .release,
            .reason = "frees the captured selection",
        },
        .{
            .name = "clone",
            .disposition = .call,
            .reason = "allocates another handle on the far side",
        },
    }),
    describe(mcp_catalog.Projection, .mcp_catalog, &.{
        .{
            .name = "deinit",
            .disposition = .release,
            .reason = "frees the projection's arena",
        },
        .{
            .name = "catalogGeneration",
            .disposition = .projected,
            .reason = "immutable for that projection",
        },
        .{
            .name = "servers",
            .disposition = .projected,
            .reason = "immutable for that projection",
        },
        .{
            .name = "tools",
            .disposition = .projected,
            .reason = "immutable for that projection",
        },
        .{
            .name = "issues",
            .disposition = .projected,
            .reason = "immutable for that projection",
        },
    }),
};

/// Records one handle's methods and checks the record against the type.
fn describe(comptime T: type, comptime owner: Owner, comptime methods: []const Method) Handle {
    comptime {
        const decls = @typeInfo(T).@"opaque".decls;
        for (decls) |decl| {
            var found = false;
            for (methods) |method| {
                if (!std.mem.eql(u8, method.name, decl.name)) continue;
                if (found) @compileError(
                    "duplicate handle record for " ++ @typeName(T) ++ "." ++ decl.name,
                );
                found = true;
            }
            if (!found) @compileError(
                @typeName(T) ++ "." ++ decl.name ++ " is a method on a handle the caller " ++
                    "holds, and nothing says what the execution split does with it. " ++
                    "Record it in src/agent/link/handles.zig as call, projected or release.",
            );
        }
        for (methods) |method| {
            if (!@hasDecl(T, method.name)) @compileError(
                "the handle record names " ++ @typeName(T) ++ "." ++ method.name ++
                    ", which the type no longer declares",
            );
            if (method.reason.len == 0) @compileError(
                "every handle method states why: " ++ @typeName(T) ++ "." ++ method.name,
            );
        }
        return .{ .name = @typeName(T), .owner = owner, .methods = methods };
    }
}

comptime {
    // The two handles that carry nothing. If either grows a method, it joins
    // the table above rather than quietly crossing a process boundary.
    if (@typeInfo(catalog.Lease).@"opaque".decls.len != 0) @compileError(
        "catalog.Lease has grown a method; record it in src/agent/link/handles.zig",
    );
    if (@typeInfo(port.SkillRestoreInputs).@"opaque".decls.len != 0) @compileError(
        "port.SkillRestoreInputs has grown a method; record it in src/agent/link/handles.zig",
    );
}

pub fn count(disposition: Disposition) usize {
    var total: usize = 0;
    for (handles) |handle| {
        for (handle.methods) |method| {
            if (method.disposition == disposition) total += 1;
        }
    }
    return total;
}

/// Writes the classification, one `disposition handle.method` line each.
pub fn writeTable(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (handles) |handle| {
        for (handle.methods) |method|
            try writer.print("{s} {s}.{s}\n", .{
                @tagName(method.disposition),
                handle.name,
                method.name,
            });
    }
}

const testing = std.testing;

test "every handle method is classified, and the counts are what the move plans for" {
    // `describe` fails the build on an unrecorded or stale method, so reaching
    // here means the table still matches the types.
    try testing.expectEqual(@as(usize, 4), handles.len);
    try testing.expectEqual(@as(usize, 3), count(.call));
    try testing.expectEqual(@as(usize, 14), count(.projected));
    try testing.expectEqual(@as(usize, 4), count(.release));

    var total: usize = 0;
    for (handles) |handle| total += handle.methods.len;
    try testing.expectEqual(total, count(.call) + count(.projected) + count(.release));
}

test "every handle that carries methods belongs to the MCP catalog" {
    // This is what confines the correction to the MCP step: the other opaque
    // types the caller holds carry nothing, which the comptime block above
    // pins. If a handle from another owner ever appears here, the step that
    // owns it changes and the plan has to say so.
    for (handles) |handle| try testing.expectEqual(Owner.mcp_catalog, handle.owner);
}

test "each release is paired with a handle that something acquires" {
    // A release with no acquisition would be a leak by construction, and an
    // acquisition with no release would be the other one.
    for (handles) |handle| {
        var releases: usize = 0;
        for (handle.methods) |method| {
            if (method.disposition == .release) releases += 1;
        }
        try testing.expectEqual(@as(usize, 1), releases);
    }
}

test "the table prints a reason for every method" {
    var storage: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeTable(&writer);
    const text = writer.buffered();
    var total: usize = 0;
    for (handles) |handle| total += handle.methods.len;
    try testing.expectEqual(total, std.mem.count(u8, text, "\n"));
    for (handles) |handle| {
        for (handle.methods) |method| try testing.expect(method.reason.len > 16);
    }
}
