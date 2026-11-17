//! The Session prompt profile: fixed MetaWork identity plus host behavior
//! guidance, composed as independent section edits. The ABI applies a profile
//! edit by edit, so composition is concatenation; the borrowed ABI views are
//! comptime constants and remain alive for each synchronous call.
const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const identity = @import("identity.zig");
const guidance = @import("guidance.zig");

const sections = blk: {
    var value: [identity.sections.len + guidance.sections.len]wire.PromptSectionV1 = undefined;
    for (identity.sections, 0..) |section, index| value[index] = section;
    for (guidance.sections, 0..) |section, index| value[identity.sections.len + index] = section;
    break :blk value;
};

pub const profile: wire.PromptProfileV1 = blk: {
    var value = std.mem.zeroes(wire.PromptProfileV1);
    value.struct_size = @sizeOf(wire.PromptProfileV1);
    value.sections = &sections;
    value.section_count = sections.len;
    break :blk value;
};

/// The candidate is unpublished and fenced by Runtime's restore reservation.
pub fn apply(api: sdk.Api, candidate: *wire.SessionHandle) error{ RestoreFailed, RestoreContractFailed }!void {
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    const code = api.sessionControl().setPromptProfile()(candidate, &profile, &diagnostic);
    defer if (diagnostic.ptr != null or diagnostic.len != 0) api.bufferRelease()(&diagnostic);
    _ = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch
        return error.RestoreContractFailed;
    const status = sdk.Status.fromCode(code) catch return error.RestoreContractFailed;
    switch (status) {
        .ok => {},
        .invalid_argument, .out_of_memory, .busy, .invalid_state, .core_error, .internal_error, .resource_limit, .checkpoint_budget_required => return error.RestoreFailed,
        else => return error.RestoreContractFailed,
    }
}

test "the profile keeps identity replacements and host additions as separate edits" {
    try std.testing.expectEqual(sections.len, profile.section_count);
    try std.testing.expectEqual(identity.sections.len + guidance.sections.len, sections.len);
    var replacements: usize = 0;
    var additions: usize = 0;
    for (sections) |section| {
        try std.testing.expectEqual(@as(u32, @sizeOf(wire.PromptSectionV1)), section.struct_size);
        const id = try sdk.borrowedBytes(section.id);
        const text = try sdk.borrowedBytes(section.text);
        try std.testing.expect(text.len != 0);
        switch (section.op_code) {
            wire.PROMPT_OP_REPLACE => {
                // Replacements take the kernel section's place, so order is zero.
                try std.testing.expect(std.mem.startsWith(u8, id, "metacodes:"));
                try std.testing.expectEqual(@as(i64, 0), section.order);
                replacements += 1;
            },
            wire.PROMPT_OP_ADD => {
                // Additions own their placement and never touch a kernel id.
                try std.testing.expect(std.mem.startsWith(u8, id, "host:"));
                try std.testing.expect(section.order != 0);
                additions += 1;
            },
            else => return error.UnexpectedPromptOp,
        }
    }
    try std.testing.expectEqual(identity.sections.len, replacements);
    try std.testing.expectEqual(guidance.sections.len, additions);
}
