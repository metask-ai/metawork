const std = @import("std");
const native_sdk = @import("native_sdk");

pub const max_path_bytes: usize = 16 * 1024;
pub const max_invocation_name_bytes: usize = 128;
pub const max_description_bytes: usize = 4096;
pub const lifetime_nanoseconds: u64 = 5 * 60 * std.time.ns_per_s;

pub const SourceKind = enum {
    local_package,
    local_directory,
};

pub const PreviewInput = struct {
    source_kind: SourceKind,
    selected_path: []const u8,
    invocation_name: []const u8,
    description: []const u8,
    file_count: usize,
    total_bytes: u64,
    content_hash: [32]u8,
};

pub const Consumed = struct {
    source_kind: SourceKind,
    selected_path: [max_path_bytes]u8,
    path_len: usize,
    invocation_name: [max_invocation_name_bytes]u8,
    invocation_name_len: usize,
    content_hash: [32]u8,

    pub fn path(self: *const Consumed) []const u8 {
        return self.selected_path[0..self.path_len];
    }

    pub fn invocationName(self: *const Consumed) []const u8 {
        return self.invocation_name[0..self.invocation_name_len];
    }
};

const Grant = struct {
    token: u64,
    generation: u64,
    window_id: native_sdk.platform.WindowId,
    expires_at_monotonic_ns: u64,
    source_kind: SourceKind,
    path: [max_path_bytes]u8,
    path_len: usize,
    invocation_name: [max_invocation_name_bytes]u8,
    invocation_name_len: usize,
    description: [max_description_bytes]u8,
    description_len: usize,
    file_count: usize,
    total_bytes: u64,
    content_hash: [32]u8,
};

pub const Issued = struct {
    token: u64,
    invocation_name: []const u8,
    description: []const u8,
    file_count: usize,
    total_bytes: u64,
};

/// Owns one outstanding import preview. The capability is short-lived,
/// connection/window-bound, and invalidated by every consume attempt.
pub const State = struct {
    next_token: u64 = 1,
    grant: ?Grant = null,

    pub fn invalidate(self: *State) void {
        self.grant = null;
    }

    pub fn issue(
        self: *State,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        now_monotonic_ns: u64,
        input: PreviewInput,
    ) error{InvalidPreview}!Issued {
        if (generation == 0 or window_id == 0 or input.selected_path.len == 0 or
            input.selected_path.len > max_path_bytes or
            input.invocation_name.len == 0 or
            input.invocation_name.len > max_invocation_name_bytes or
            input.description.len > max_description_bytes or
            input.file_count == 0 or input.total_bytes == 0 or
            now_monotonic_ns > std.math.maxInt(u64) - lifetime_nanoseconds)
            return error.InvalidPreview;
        const token = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        var grant: Grant = .{
            .token = token,
            .generation = generation,
            .window_id = window_id,
            .expires_at_monotonic_ns = now_monotonic_ns + lifetime_nanoseconds,
            .source_kind = input.source_kind,
            .path = undefined,
            .path_len = input.selected_path.len,
            .invocation_name = undefined,
            .invocation_name_len = input.invocation_name.len,
            .description = undefined,
            .description_len = input.description.len,
            .file_count = input.file_count,
            .total_bytes = input.total_bytes,
            .content_hash = input.content_hash,
        };
        @memcpy(grant.path[0..input.selected_path.len], input.selected_path);
        @memcpy(
            grant.invocation_name[0..input.invocation_name.len],
            input.invocation_name,
        );
        @memcpy(grant.description[0..input.description.len], input.description);
        self.grant = grant;
        const stored = &self.grant.?;
        return .{
            .token = token,
            .invocation_name = stored.invocation_name[0..stored.invocation_name_len],
            .description = stored.description[0..stored.description_len],
            .file_count = stored.file_count,
            .total_bytes = stored.total_bytes,
        };
    }

    pub fn consume(
        self: *State,
        token: u64,
        window_id: native_sdk.platform.WindowId,
        generation: u64,
        now_monotonic_ns: u64,
    ) error{SkillPreviewNotTrusted}!Consumed {
        const grant = self.grant orelse return error.SkillPreviewNotTrusted;
        self.grant = null;
        if (grant.token != token or grant.window_id != window_id or
            grant.generation != generation or
            now_monotonic_ns > grant.expires_at_monotonic_ns)
            return error.SkillPreviewNotTrusted;
        var consumed: Consumed = .{
            .source_kind = grant.source_kind,
            .selected_path = undefined,
            .path_len = grant.path_len,
            .invocation_name = undefined,
            .invocation_name_len = grant.invocation_name_len,
            .content_hash = grant.content_hash,
        };
        @memcpy(consumed.selected_path[0..grant.path_len], grant.path[0..grant.path_len]);
        @memcpy(
            consumed.invocation_name[0..grant.invocation_name_len],
            grant.invocation_name[0..grant.invocation_name_len],
        );
        return consumed;
    }
};

test "Skill preview capability is one-shot, bounded, and connection-bound" {
    var state: State = .{};
    const issued = try state.issue(3, 7, 100, .{
        .source_kind = .local_directory,
        .selected_path = "/tmp/release-check",
        .invocation_name = "release-check",
        .description = "Check a release.",
        .file_count = 2,
        .total_bytes = 42,
        .content_hash = [_]u8{9} ** 32,
    });
    const consumed = try state.consume(issued.token, 7, 3, 100 + lifetime_nanoseconds);
    try std.testing.expectEqualStrings("/tmp/release-check", consumed.path());
    try std.testing.expectEqualStrings("release-check", consumed.invocationName());
    try std.testing.expectError(
        error.SkillPreviewNotTrusted,
        state.consume(issued.token, 7, 3, 100 + lifetime_nanoseconds),
    );

    const stale = try state.issue(3, 7, 100, .{
        .source_kind = .local_package,
        .selected_path = "/tmp/release-check.skill",
        .invocation_name = "release-check",
        .description = "",
        .file_count = 1,
        .total_bytes = 1,
        .content_hash = [_]u8{3} ** 32,
    });
    try std.testing.expectError(
        error.SkillPreviewNotTrusted,
        state.consume(stale.token, 7, 4, 101),
    );
}
