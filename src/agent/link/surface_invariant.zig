//! `surface.zig`'s own stated invariant, checked.
//!
//! That file's header says "Everything here is plain data. A value that
//! retains a live Session or Runtime belongs in `port.zig`". It was not true,
//! and the plan's section 2 repeated it as a verified structural fact while
//! part of its reasoning rested on it. Four declarations hold a borrowed
//! lease, a borrowed selection, a transport or an allocator -- and the
//! structural codec had already classified all four before anyone checked the
//! sentence against them. The evidence was in hand and was not turned on the
//! belief it refuted.
//!
//! So the invariant is pinned rather than restated. Every public type
//! `surface.zig` declares must classify as structural, or appear below with
//! the reason it does not. A declaration that stops being plain data without
//! being listed fails the build; a listing that becomes plain data fails too,
//! so the exception table cannot outlive its reason.
//!
//! A false invariant is worse than no invariant, because a cut can be drawn in
//! reliance on it. That is not hypothetical here: it happened.

const std = @import("std");
const contract = @import("agent_contract");
const payload = @import("payload.zig");

const surface = contract.surface;

pub const Exception = struct {
    name: [:0]const u8,
    obstruction: payload.Obstruction,
    reason: []const u8,
};

/// What `surface.zig` declares that is not plain data, and why. Each one is
/// already recorded in `crossings.zig` with the wire shape it takes; this
/// table exists to keep the file's own claim honest about them.
pub const exceptions = [_]Exception{
    .{
        .name = "SessionOpenOptions",
        .obstruction = .handle_pointer,
        .reason = "holds a borrowed skill catalog lease and MCP selection, both live in the Agent",
    },
    .{
        .name = "SessionRestoreOptions",
        .obstruction = .handle_pointer,
        .reason = "carries the open options above, plus a checkpoint read callback",
    },
    .{
        .name = "ImageGenerationRunInput",
        .obstruction = .untyped_pointer,
        .reason = "holds an HTTP transport and an output commit, which are capabilities",
    },
    .{
        .name = "PendingUiRequest",
        .obstruction = .allocator,
        .reason = "owns its request JSON through an allocator",
    },
    .{
        .name = "Error",
        .obstruction = .open_value,
        .reason = "an error set, which the link numbers rather than carries",
    },
    .{
        .name = "CloseOutcome",
        .obstruction = .open_value,
        .reason = "embeds the error set above",
    },
    .{
        .name = "BeginRunFailure",
        .obstruction = .open_value,
        .reason = "embeds the error set above",
    },
    .{
        .name = "McpActivationOutcome",
        .obstruction = .handle_pointer,
        .reason = "hands out a live activation the Agent owns",
    },
    .{
        .name = "ImageGenerationTestOptions",
        .obstruction = .untyped_pointer,
        .reason = "a test-only injection point holding a transport",
    },
};

fn exceptionFor(comptime name: []const u8) ?Exception {
    comptime {
        for (exceptions) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
}

comptime {
    @setEvalBranchQuota(200_000);
    for (@typeInfo(surface).@"struct".decls) |decl| {
        const declared = @field(surface, decl.name);
        // Only type declarations are in scope: the file also declares limits
        // and budgets, which are values rather than shapes.
        if (@TypeOf(declared) != type) continue;
        const classification = payload.classify(declared);
        const listed = exceptionFor(decl.name);
        switch (classification) {
            .structural => if (listed != null) @compileError(
                "surface." ++ decl.name ++ " is listed as an exception in " ++
                    "src/agent/link/surface_invariant.zig but now crosses structurally; " ++
                    "remove the listing so the table cannot outlive its reason",
            ),
            .substituted => |why| {
                const entry = listed orelse @compileError(
                    "surface." ++ decl.name ++ " is not plain data (" ++ @tagName(why) ++
                        "), which contradicts that file's own header. Either make it plain " ++
                        "data, or list it in src/agent/link/surface_invariant.zig with the " ++
                        "reason -- a false invariant is worse than none, because a cut can " ++
                        "be drawn in reliance on it",
                );
                if (entry.obstruction != why) @compileError(
                    "surface." ++ decl.name ++ " is listed as " ++ @tagName(entry.obstruction) ++
                        " but classifies as " ++ @tagName(why),
                );
            },
        }
    }
}

const testing = std.testing;

test "every exception states a reason, and none is a duplicate" {
    for (exceptions, 0..) |entry, index| {
        try testing.expect(entry.reason.len > 16);
        for (exceptions[index + 1 ..]) |other|
            try testing.expect(!std.mem.eql(u8, entry.name, other.name));
    }
}

test "the exceptions are the shapes the inventory already records" {
    // The two tables describe the same four facts from different directions:
    // this one keeps `surface.zig`'s claim honest, the inventory says what the
    // wire does instead. They are allowed to disagree about coverage -- the
    // inventory also records types declared elsewhere -- but not about whether
    // a shared name is plain data, which the comptime block above enforces by
    // classifying rather than by comparing tables.
    var handle_pointers: usize = 0;
    var open_values: usize = 0;
    for (exceptions) |entry| switch (entry.obstruction) {
        .handle_pointer => handle_pointers += 1,
        .open_value => open_values += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 3), handle_pointers);
    try testing.expectEqual(@as(usize, 3), open_values);
}
