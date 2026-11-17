//! Host behavior guidance: platform-conditional constraints on the commands the
//! model writes. Added as `host:` sections, never replacing a kernel section, so
//! upstream wording stays upstream's to change. Borrowed ABI views are comptime
//! constants and outlive every synchronous call.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("metask_agentcore");
const wire = sdk.types;

pub const windows_downloads_id = "host:windows-downloads";

/// After `metacodes:using-tools` (kernel order 1000) and before
/// `metacodes:tone` (2000): a narrowing of the general tool rules must render
/// as a refinement of them, not ahead of them. The gap on both sides leaves
/// room for later host sections, and matching no kernel order keeps the
/// id tie-break out of play.
pub const windows_downloads_order: i64 = 1100;

/// PowerShell 5.1's web cmdlets parse responses through the legacy Internet
/// Explorer engine unless `-UseBasicParsing` is passed; local security software
/// intercepts that path with a modal prompt that blocks the command until
/// somebody clicks it. `curl` is a PowerShell alias for `Invoke-WebRequest`, so
/// the constraint has to name `curl.exe`.
const windows_downloads_text =
    "Windows network downloads: fetch bytes with `curl.exe`, present on Windows 10 and later. " ++
    "The `.exe` is required, because bare `curl` is a PowerShell alias for `Invoke-WebRequest`. " ++
    "Avoid `Invoke-WebRequest` and `Invoke-RestMethod`: their default parsing path can be intercepted " ++
    "by local security software, which blocks the command behind a modal prompt. " ++
    "If one of them is unavoidable, pass `-UseBasicParsing`. " ++
    "Fetch several files in one command rather than one command per file.";

const windows_sections = [_]wire.PromptSectionV1{
    addition(windows_downloads_id, windows_downloads_order, windows_downloads_text),
};

/// The host platform decides this, because the guidance is about the commands
/// the model writes for this host's shell. ABI interpolation substitutes
/// `{{platform}}` but cannot branch on it, so the selection happens here and
/// non-Windows Sessions carry no Windows-only advice at all.
pub fn sectionsFor(os: std.Target.Os.Tag) []const wire.PromptSectionV1 {
    return switch (os) {
        .windows => &windows_sections,
        else => &.{},
    };
}

pub const sections = sectionsFor(builtin.target.os.tag);

fn addition(id: []const u8, order: i64, text: []const u8) wire.PromptSectionV1 {
    var value = std.mem.zeroes(wire.PromptSectionV1);
    value.struct_size = @sizeOf(wire.PromptSectionV1);
    value.op_code = wire.PROMPT_OP_ADD;
    value.id = sdk.bytesView(id);
    value.order = order;
    value.text = sdk.bytesView(text);
    return value;
}

test "only Windows carries the download constraints, and they stay well-formed ADD sections" {
    const windows = sectionsFor(.windows);
    try std.testing.expectEqual(@as(usize, 1), windows.len);
    const section = windows[0];
    try std.testing.expectEqual(wire.PROMPT_OP_ADD, section.op_code);
    try std.testing.expectEqual(windows_downloads_order, section.order);
    try std.testing.expectEqual(@as(u32, 0), section.interpolate);
    const id = try sdk.borrowedBytes(section.id);
    try std.testing.expectEqualStrings(windows_downloads_id, id);
    try std.testing.expect(std.mem.startsWith(u8, id, "host:"));
    const text = try sdk.borrowedBytes(section.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(text.len <= wire.MAX_PROMPT_SECTION_TEXT_BYTES_V1);
    // The three constraints the Windows interception evidence asks for.
    try std.testing.expect(std.mem.indexOf(u8, text, "curl.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "-UseBasicParsing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "one command") != null);
    // WebFetch cannot write bytes to a path, so it is never offered here.
    try std.testing.expect(std.mem.indexOf(u8, text, "WebFetch") == null);

    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os|
        try std.testing.expectEqual(@as(usize, 0), sectionsFor(os).len);
}
