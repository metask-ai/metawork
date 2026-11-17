//! How each port payload type crosses the execution link.
//!
//! This is the step that moves the Runtime, enumerated at compile time instead
//! of discovered one call at a time. `payload.zig` carries anything that is
//! plain data; everything else owes an explicit wire shape, and the obstruction
//! says which shape: a borrowed handle becomes an id a table resolves, a byte
//! callback becomes a descriptor the far side acts on itself, an owner's
//! allocator never crosses while its bytes do, and an embedded error set
//! becomes the number the error registry already assigns it.
//!
//! The table is checked against the compiler, not against a reviewer. A
//! recorded type whose shape changes fails the build with both the recorded
//! and the actual classification in the message, so the inventory cannot drift
//! while looking green -- the same discipline the method and error registries
//! use. Twenty-two of the thirty-eight types cross as they are, including the
//! two largest (a Run's multimodal input and a model binding), which is why
//! the move needs no hand-written encoder for the bulk of its payload.

const std = @import("std");
const contract = @import("agent_contract");
const payload = @import("payload.zig");
const shapes = @import("shapes.zig");

const Classification = payload.Classification;

/// What the wire does with one port payload type.
pub const Crossing = struct {
    name: []const u8,
    expected: Classification,
    /// What replaces the obstruction. Empty exactly when the type is
    /// structural.
    shape: []const u8,
    /// The mirror type in `shapes.zig` that implements `shape`, once it
    /// exists. Empty means the shape is decided but not yet built, which is
    /// what the move still owes.
    mirror: []const u8 = "",
};

pub fn describe(value: Classification) []const u8 {
    return switch (value) {
        .structural => "structural",
        .substituted => |why| @tagName(why),
    };
}

fn crossing(
    comptime T: type,
    comptime expected: Classification,
    comptime shape: []const u8,
) Crossing {
    return crossingWith(T, expected, shape, "");
}

/// The same, for a type whose mirror now exists. `Mirror` is checked to be
/// something the wire can carry, so a mirror cannot be recorded as done while
/// still holding an obstruction of its own.
fn shaped(
    comptime T: type,
    comptime expected: Classification,
    comptime shape: []const u8,
    comptime Mirror: type,
) Crossing {
    comptime {
        payload.requireStructural(Mirror);
        return crossingWith(T, expected, shape, @typeName(Mirror));
    }
}

fn crossingWith(
    comptime T: type,
    comptime expected: Classification,
    comptime shape: []const u8,
    comptime mirror: []const u8,
) Crossing {
    comptime {
        const actual = payload.classify(T);
        const same = switch (actual) {
            .structural => expected == .structural,
            .substituted => |why| expected == .substituted and why == expected.substituted,
        };
        if (!same) @compileError(
            "the execution link's record for " ++ @typeName(T) ++ " is stale: recorded " ++
                describe(expected) ++ ", found " ++ describe(actual),
        );
        if ((actual == .structural) != (shape.len == 0)) @compileError(
            "a structural type needs no wire shape and a substituted one needs a stated shape: " ++
                @typeName(T),
        );
        return .{ .name = @typeName(T), .expected = expected, .shape = shape, .mirror = mirror };
    }
}

pub const crossings = [_]Crossing{
    // Plain data, carried by the structural codec. Nothing to decide.
    crossing(contract.ModelBinding, .structural, ""),
    crossing(contract.RunInput, .structural, ""),
    crossing(contract.InputPart, .structural, ""),
    crossing(contract.surface.SessionSnapshot, .structural, ""),
    crossing(contract.PermissionMode, .structural, ""),
    crossing(contract.CheckpointLimits, .structural, ""),
    crossing(contract.surface.OperationIdFloor, .structural, ""),
    crossing(contract.surface.WorkspaceInput, .structural, ""),
    crossing(contract.SkillPolicyInput, .structural, ""),
    crossing(contract.surface.PermissionModeUpdate, .structural, ""),
    crossing(contract.InputCounts, .structural, ""),
    crossing(contract.TerminationSignal, .structural, ""),
    crossing(contract.ExternalInterruption, .structural, ""),
    crossing(contract.SessionDisposition, .structural, ""),
    crossing(contract.McpServerAllowlist, .structural, ""),
    crossing(contract.CheckpointRestoreReport, .structural, ""),
    crossing(contract.ImageGenerationReceipt, .structural, ""),
    crossing(contract.FileDeliveryReceipt, .structural, ""),
    crossing(contract.McpInstallationResult, .structural, ""),
    crossing(contract.ModelError, .structural, ""),
    crossing(contract.TerminalReceipts, .structural, ""),
    crossing(contract.surface.McpActivationUnavailableReason, .structural, ""),

    // A borrowed lease, selection or activation lives in the execution half.
    crossing(
        contract.SessionOpenOptions,
        .{ .substituted = .handle_pointer },
        "skill lease id and MCP selection id",
    ),
    crossing(
        contract.SessionRestoreOptions,
        .{ .substituted = .handle_pointer },
        "the open options' ids plus a checkpoint source descriptor",
    ),
    crossing(
        contract.CatalogAcquisition,
        .{ .substituted = .handle_pointer },
        "lease id plus the projection below",
    ),
    crossing(
        contract.McpActivationOutcome,
        .{ .substituted = .handle_pointer },
        "activation id plus its projection",
    ),

    // An owner that holds its bytes through an allocator: the bytes cross, the
    // ownership stays where it was.
    shaped(
        contract.TerminalResult,
        .{ .substituted = .allocator },
        "diagnostic bytes inline, receipts as data",
        shapes.TerminalResult,
    ),
    shaped(
        contract.CompactTerminalResult,
        .{ .substituted = .allocator },
        "diagnostic bytes inline",
        shapes.CompactTerminalResult,
    ),
    shaped(
        contract.CheckpointOutcome,
        .{ .substituted = .allocator },
        "record fields inline; the blob never crosses",
        shapes.CheckpointOutcome,
    ),
    shaped(
        contract.PendingUiRequest,
        .{ .substituted = .allocator },
        "request JSON inline",
        shapes.PendingUiRequest,
    ),

    // A context pointer or a byte callback: the far side performs the effect,
    // and the wire carries only what it needs in order to.
    crossing(
        contract.CheckpointSink,
        .{ .substituted = .untyped_pointer },
        "destination descriptor; the execution half writes the file",
    ),
    crossing(
        contract.CatalogProjection,
        .{ .substituted = .untyped_pointer },
        "its fields without the owning arena pointer",
    ),
    crossing(
        contract.CatalogQuery,
        .{ .substituted = .untyped_pointer },
        "query fields without the borrowed source lifetime",
    ),
    crossing(
        contract.ImageGenerationRunInput,
        .{ .substituted = .untyped_pointer },
        "binding fields; the transport is composed in the execution half",
    ),
    crossing(
        contract.VideoGenerationRunInput,
        .{ .substituted = .untyped_pointer },
        "binding fields; the transport is composed in the execution half",
    ),
    crossing(
        contract.FileDeliveryInput,
        .{ .substituted = .untyped_pointer },
        "delivery root; the execution half holds the capability",
    ),

    // An embedded error set, which the error registry already numbers.
    shaped(
        contract.CloseOutcome,
        .{ .substituted = .open_value },
        "registered error code plus the disposition",
        shapes.CloseOutcome,
    ),
    shaped(
        contract.BeginRunFailure,
        .{ .substituted = .open_value },
        "registered error code plus the disposition",
        shapes.BeginRunFailure,
    ),
    // Found while building the mirrors rather than by reading the port: a
    // callback rejection is reached inside a terminal result and carries
    // `?anyerror`, which no registry can close.
    shaped(
        contract.control.CallbackRejection,
        .{ .substituted = .open_value },
        "registered error code, or recorded as present but unnamed",
        shapes.CallbackRejection,
    ),
};

/// Writes the inventory, one `how name shape` line each.
pub fn writeTable(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (crossings) |entry|
        try writer.print("{s} {s} {s}\n", .{ describe(entry.expected), entry.name, entry.shape });
}

/// How many types still owe a wire shape: substituted, and with no mirror
/// built yet. This is the number that should fall as the move proceeds, not a
/// count of lines.
pub fn owed() usize {
    var total: usize = 0;
    for (crossings) |entry| {
        if (entry.expected == .substituted and entry.mirror.len == 0) total += 1;
    }
    return total;
}

/// How many substituted types already have their mirror.
pub fn shapedCount() usize {
    var total: usize = 0;
    for (crossings) |entry| {
        if (entry.expected == .substituted and entry.mirror.len != 0) total += 1;
    }
    return total;
}

test "the inventory is still true, and says something about every entry" {
    // `crossing` fails the build on a stale record, so reaching here means
    // every classification above still holds against the compiler.
    var structural: usize = 0;
    for (crossings) |entry| switch (entry.expected) {
        .structural => {
            structural += 1;
            try std.testing.expectEqualStrings("", entry.shape);
        },
        .substituted => try std.testing.expect(entry.shape.len != 0),
    };
    try std.testing.expectEqual(@as(usize, 22), structural);
    try std.testing.expectEqual(@as(usize, 7), shapedCount());
    try std.testing.expectEqual(@as(usize, 10), owed());
    try std.testing.expectEqual(crossings.len, structural + shapedCount() + owed());
}

test "every obstruction the codec can report is represented, so none is unplanned" {
    // If a new obstruction class appears in `payload.zig`, something in the
    // port grew a shape nobody has decided about yet.
    inline for (comptime std.enums.values(payload.Obstruction)) |why| {
        var seen = false;
        for (crossings) |entry| {
            if (entry.expected == .substituted and entry.expected.substituted == why) seen = true;
        }
        // `callback` is reachable in the codec but no port payload type
        // reaches the link as a bare function pointer today: the two that
        // carry one arrive as a context pointer instead.
        if (why == .callback) {
            try std.testing.expect(!seen);
            continue;
        }
        try std.testing.expect(seen);
    }
}

test "the table prints with a shape for everything that owes one" {
    var storage: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeTable(&writer);
    const text = writer.buffered();
    try std.testing.expectEqual(crossings.len, std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "handle_pointer") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "the blob never crosses") != null);
}
