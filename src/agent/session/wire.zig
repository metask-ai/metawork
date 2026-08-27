//! AgentCore wire decoding and bounded protocol mappings.
//!
//! This module is intentionally independent from Session and Runtime.  It
//! validates borrowed SDK payloads and produces typed values; lifecycle and
//! callback ownership stay in session.zig.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const control = @import("control.zig");
const provider = @import("agent_provider");

pub fn decodeUiRequest(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) sdk.DecodeError!sdk.ParsedUiRequest {
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.MalformedJson;
    var parsed = try sdk.decodeUiRequest(allocator, encoded);
    errdefer parsed.deinit();
    if (!uiRequestTextValid(parsed.value)) return error.InvalidPayload;
    return parsed;
}

pub const ParsedPermissionRequest = struct {
    parsed: sdk.ParsedUiRequest,

    pub fn value(self: *const ParsedPermissionRequest) sdk.PermissionRequest {
        return switch (self.parsed.value) {
            .permission => |permission| permission,
            .ask_question => unreachable,
        };
    }

    pub fn deinit(self: *ParsedPermissionRequest) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn decodePermissionRequest(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) (sdk.DecodeError || error{UnsupportedUiRequest})!ParsedPermissionRequest {
    var parsed = try decodeUiRequest(allocator, encoded);
    errdefer parsed.deinit();
    switch (parsed.value) {
        .permission => return .{ .parsed = parsed },
        .ask_question => return error.UnsupportedUiRequest,
    }
}

pub fn decodeCoreEvent(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) sdk.DecodeError!sdk.ParsedCoreEvent {
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.MalformedJson;
    var parsed = try sdk.decodeCoreEvent(allocator, encoded);
    errdefer parsed.deinit();
    if (!coreEventTextValid(parsed.value)) return error.InvalidPayload;
    return parsed;
}

fn coreEventTextValid(event: sdk.DecodedCoreEvent) bool {
    return switch (event) {
        .unknown => |unknown| validUtf8(&.{ unknown.tag, unknown.payload_json }),
        .known => |known| switch (known) {
            .text_chunk, .thinking_chunk => |text| std.unicode.utf8ValidateSlice(text),
            .tool_start => |tool| validUtf8(&.{ tool.id, tool.name, tool.input }),
            .tool_progress => |progress| validUtf8(&.{ progress.id, progress.text }),
            .progress => |progress| validUtf8(&.{ progress.tool_name, progress.tool_input }),
            .tool_result => |result| {
                if (!validUtf8(&.{ result.id, result.name, result.input, result.content })) return false;
                if (comptime @hasField(@TypeOf(result), "file_refs")) {
                    if (result.file_refs) |refs| {
                        for (refs) |reference| {
                            if (!std.unicode.utf8ValidateSlice(reference.title) or
                                !std.unicode.utf8ValidateSlice(reference.kind)) return false;
                            switch (reference.locator) {
                                .workspace_path => |path| if (!std.unicode.utf8ValidateSlice(path)) return false,
                                .absolute_path => |path| if (!std.unicode.utf8ValidateSlice(path)) return false,
                                .uri => |uri| if (!std.unicode.utf8ValidateSlice(uri)) return false,
                            }
                        }
                    }
                }
                return true;
            },
            .usage, .retry_notice, .stream_done => true,
            .run_state => |state| {
                if (state.run_id == 0) return false;
                for (state.in_flight_tools) |tool|
                    if (!validUtf8(&.{ tool.tool_call_id, tool.name })) return false;
                return true;
            },
            .context_warning => |warning| std.unicode.utf8ValidateSlice(warning.level),
            .auto_compact => |compact| std.unicode.utf8ValidateSlice(compact.cause),
            .permission_provenance => |value| validUtf8(&.{
                value.matched_rule_id orelse "",
                value.session_id,
                value.tool_call_id,
                value.request_id orelse "",
                value.tool.name,
                value.tool.binding,
                value.canonical_arguments_digest,
            }),
        },
    };
}

fn uiRequestTextValid(request: sdk.UiRequest) bool {
    return switch (request) {
        .ask_question => |questions| questions: {
            for (questions) |question| {
                if (!validUtf8(&.{ question.question, question.header })) break :questions false;
                for (question.options) |option|
                    if (!validUtf8(&.{ option.label, option.description, option.preview }))
                        break :questions false;
            }
            break :questions true;
        },
        .permission => |permission| validUtf8(&.{
            permission.type,
            permission.request_id,
            permission.session_id,
            permission.tool_call_id,
            permission.tool.name,
            permission.tool.binding,
            permission.canonical_arguments_digest,
            permission.arguments_json,
            if (permission.candidate) |candidate| candidate.rule_id else "",
        }),
    };
}

fn validUtf8(values: []const []const u8) bool {
    for (values) |value|
        if (!std.unicode.utf8ValidateSlice(value)) return false;
    return true;
}

pub fn providerKindCode(value: provider.ProviderKind) u32 {
    return switch (value) {
        .anthropic => wire.PROVIDER_ANTHROPIC,
        .openai => wire.PROVIDER_OPENAI,
        .gemini => wire.PROVIDER_GEMINI,
    };
}

pub fn permissionModeCode(value: control.PermissionMode) u32 {
    return switch (value) {
        .default => wire.PERMISSION_DEFAULT,
        .accept_edits => wire.PERMISSION_ACCEPT_EDITS,
        .auto => wire.PERMISSION_AUTO,
        .dont_ask => wire.PERMISSION_DONT_ASK,
        .full_access => wire.PERMISSION_FULL_ACCESS,
    };
}

pub fn shellPolicyCode(value: control.ShellPolicy) u32 {
    return switch (value) {
        .disabled => wire.SHELL_DISABLED,
        .sandboxed => wire.SHELL_SANDBOXED,
        .unrestricted => wire.SHELL_UNRESTRICTED,
    };
}

pub fn skillPolicy(
    granted_skill_ids: []const []const u8,
    views: []wire.BytesViewV1,
) error{InvalidSkillPolicy}!wire.SkillPolicyV1 {
    if (views.len != granted_skill_ids.len) return error.InvalidSkillPolicy;
    for (granted_skill_ids, 0..) |skill_id, index| {
        if (skill_id.len == 0 or !std.unicode.utf8ValidateSlice(skill_id))
            return error.InvalidSkillPolicy;
        for (granted_skill_ids[0..index]) |prior|
            if (std.mem.eql(u8, prior, skill_id)) return error.InvalidSkillPolicy;
        views[index] = sdk.bytesView(skill_id);
    }
    return .{
        .struct_size = @sizeOf(wire.SkillPolicyV1),
        .reserved0 = 0,
        .granted_skill_ids = if (views.len == 0) null else views.ptr,
        .granted_skill_id_count = views.len,
        .reserved = [_]u64{0} ** 4,
    };
}

test "AgentCore JSON callbacks reject invalid UTF-8 at the ownership boundary" {
    const invalid_event =
        "{\"tool_result\":{\"id\":\"tool-1\",\"name\":\"Bash\",\"input\":\"{}\",\"content\":[203],\"is_error\":false,\"elapsed_ms\":1}}";
    try std.testing.expectError(
        error.InvalidPayload,
        decodeCoreEvent(std.testing.allocator, invalid_event),
    );

    const invalid_ui =
        "{\"ask_question\":[{\"question\":[203],\"header\":\"Choice\",\"multi\":false,\"options\":[]}]}";
    try std.testing.expectError(
        error.InvalidPayload,
        decodeUiRequest(std.testing.allocator, invalid_ui),
    );
}
