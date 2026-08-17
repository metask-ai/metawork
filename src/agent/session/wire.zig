//! AgentCore wire decoding and bounded protocol mappings.
//!
//! This module is intentionally independent from Session and Runtime.  It
//! validates borrowed SDK payloads and produces typed values; lifecycle and
//! callback ownership stay in session.zig.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const control = @import("control.zig");

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
            .text_chunk => |text| std.unicode.utf8ValidateSlice(text),
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

pub const BuiltinToolProfile = enum {
    full,
    local,
    network,
};

pub const desktop_builtin_tools = [_][]const u8{
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
    "AskUserQuestion",
    "WebSearch",
    "WebFetch",
};
pub const local_builtin_tools = [_][]const u8{
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
    "AskUserQuestion",
};
pub const network_builtin_tools = [_][]const u8{ "WebSearch", "WebFetch" };

pub const registered_builtin_tools = desktop_builtin_tools;

pub fn builtinToolsForProfile(profile: BuiltinToolProfile) []const []const u8 {
    return switch (profile) {
        .full => &desktop_builtin_tools,
        .local => &local_builtin_tools,
        .network => &network_builtin_tools,
    };
}

pub fn providerKindCode(value: control.ProviderKind) u32 {
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

pub fn allSkillsEnabledSelection() wire.SkillSelectionV1 {
    return .{
        .struct_size = @sizeOf(wire.SkillSelectionV1),
        .default_state_code = wire.SKILL_SELECTION_ENABLED,
        .exception_skill_ids = null,
        .exception_skill_id_count = 0,
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

test "Desktop built-in profiles cover the verified name set without overlap" {
    const local = builtinToolsForProfile(.local);
    const network = builtinToolsForProfile(.network);
    try std.testing.expectEqual(desktop_builtin_tools.len, local.len + network.len);
    for (local) |name| {
        for (network) |other| try std.testing.expect(!std.mem.eql(u8, name, other));
    }
    for (desktop_builtin_tools) |name| {
        var found = false;
        for (local) |candidate| {
            if (std.mem.eql(u8, name, candidate)) found = true;
        }
        for (network) |candidate| {
            if (std.mem.eql(u8, name, candidate)) found = true;
        }
        try std.testing.expect(found);
    }
}
