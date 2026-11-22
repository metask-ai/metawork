//! Host behavior guidance: constraints on the commands the model writes and on
//! the results it hands over. Added as `host:` sections, never replacing a
//! kernel section, so upstream wording stays upstream's to change. Only some
//! sections are platform-conditional. Borrowed ABI views are comptime constants
//! and outlive every synchronous call.
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

pub const outputs_id = "host:outputs";

/// It refines when a Host tool is used, so it follows `metacodes:using-tools`
/// (1000) and the Windows download constraints (1100) and stays before
/// `metacodes:tone` (2000). It is kept away from `metacodes:validation` (300):
/// handing a file over must not read as a step of checking the work.
pub const outputs_order: i64 = 1200;

/// The user opens a turn's result files from result cards, so the test is
/// whether the user has to open the file to use the result, whatever made it.
/// Delivery only hands the final version over; checks stay with whoever asks
/// for them.
const outputs_text =
    "Results for the user: hand over with DeliverFile every file the user has to open to use this turn's result; " ++
    "the product shows each one as a result card. Judge every file by that test alone, however it was made: " ++
    "written directly, produced by a script or a Skill, generated with GenerateImage or GenerateVideo, or edited in place.\n" ++
    "- Deliver files the user will read, view, play, present or pass on, for example a new web page, report, spreadsheet, " ++
    "presentation, PDF, chart image or video, and a Word, Excel or PowerPoint file you edited.\n" ++
    "- Do not deliver anything when your reply already gives the result: answers, analysis, plans, explanations of code.\n" ++
    "- Do not deliver edits the user only needs to review as changes: changed code, configuration and text files " ++
    "appear in the file changes the user reviews.\n" ++
    "- Do not deliver process files, even ones created in this turn: scripts that produce the result, " ++
    "intermediate drafts, temporary data, logs.\n" ++
    "- Code files are not results unless the user asks for the file to be delivered. " ++
    "A web page meant to be opened in a browser is a result.\n" ++
    "- A generated image, video or other file is a result only when the user wanted it for itself. " ++
    "When it is material for another file, such as a picture placed in a presentation, deliver that other file instead.\n" ++
    "Deliver the final version, after your last change to the file in this turn. " ++
    "Delivering only hands the file over: it neither requires nor implies a quality check, " ++
    "and checks a Skill asks for stay separate. " ++
    "When several files make up the result, deliver all of them once they are final.";

const common_sections = [_]wire.PromptSectionV1{
    addition(outputs_id, outputs_order, outputs_text),
};

const windows_sections = [_]wire.PromptSectionV1{
    addition(windows_downloads_id, windows_downloads_order, windows_downloads_text),
} ++ common_sections;

/// The host platform decides the command guidance, because it is about the
/// commands the model writes for this host's shell. ABI interpolation
/// substitutes `{{platform}}` but cannot branch on it, so the selection happens
/// here and non-Windows Sessions carry no Windows-only advice at all. The
/// result guidance holds on every platform.
pub fn sectionsFor(os: std.Target.Os.Tag) []const wire.PromptSectionV1 {
    return switch (os) {
        .windows => &windows_sections,
        else => &common_sections,
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

fn expectWellFormed(section: wire.PromptSectionV1, id: []const u8, order: i64) ![]const u8 {
    try std.testing.expectEqual(wire.PROMPT_OP_ADD, section.op_code);
    try std.testing.expectEqual(order, section.order);
    try std.testing.expectEqual(@as(u32, 0), section.interpolate);
    const actual_id = try sdk.borrowedBytes(section.id);
    try std.testing.expectEqualStrings(id, actual_id);
    try std.testing.expect(std.mem.startsWith(u8, actual_id, "host:"));
    const text = try sdk.borrowedBytes(section.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(text.len <= wire.MAX_PROMPT_SECTION_TEXT_BYTES_V1);
    // A placeholder would make the whole profile depend on interpolation.
    try std.testing.expect(std.mem.indexOf(u8, text, "{{") == null);
    return text;
}

test "only Windows carries the download constraints, and they stay well-formed ADD sections" {
    const windows = sectionsFor(.windows);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    const text = try expectWellFormed(windows[0], windows_downloads_id, windows_downloads_order);
    // The three constraints the Windows interception evidence asks for.
    try std.testing.expect(std.mem.indexOf(u8, text, "curl.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "-UseBasicParsing") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "one command") != null);
    // WebFetch cannot write bytes to a path, so it is never offered here.
    try std.testing.expect(std.mem.indexOf(u8, text, "WebFetch") == null);

    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| {
        for (sectionsFor(os)) |section|
            try std.testing.expect(!std.mem.eql(u8, try sdk.borrowedBytes(section.id), windows_downloads_id));
    }
}

test "every platform carries the result guidance after the download constraints" {
    for ([_]std.Target.Os.Tag{ .windows, .macos, .linux }) |os| {
        const list = sectionsFor(os);
        try std.testing.expectEqual(@as(usize, if (os == .windows) 2 else 1), list.len);
        // Windows renders the download constraints first; outputs is always last.
        const text = try expectWellFormed(list[list.len - 1], outputs_id, outputs_order);
        for ([_][]const u8{
            "DeliverFile",
            "has to open",
            "final version",
            "process files",
            "neither requires nor implies a quality check",
            "material for another file",
            "deliver all of them once they are final",
        }) |required| try std.testing.expect(std.mem.indexOf(u8, text, required) != null);
        // No delivery order: a model delivers in creation order whatever the wording asks.
        for ([_][]const u8{ "most important", "answers the request", " first", " order" }) |retired|
            try std.testing.expect(std.mem.indexOf(u8, text, retired) == null);
    }
}
