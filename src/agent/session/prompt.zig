//! The Session prompt profile: fixed MetaWork identity plus host behavior
//! guidance, and the user's own instructions when the caller supplies them.
//! The ABI applies a profile edit by edit, so composition is concatenation.
//!
//! The base profile is a comptime constant: create and restore use it, so
//! neither depends on anything a user wrote. User instructions are assembled
//! per Session at run time and installed only through the idle-only setter;
//! the borrowed ABI views stay alive for each synchronous call.
const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const identity = @import("identity.zig");
const guidance = @import("guidance.zig");
const surface = @import("agent_contract").surface;

const base_sections = blk: {
    var value: [identity.sections.len + guidance.sections.len]wire.PromptSectionV1 = undefined;
    for (identity.sections, 0..) |section, index| value[index] = section;
    for (guidance.sections, 0..) |section, index| value[identity.sections.len + index] = section;
    break :blk value;
};

/// Identity and guidance only. Byte for byte what every Session carries before
/// the caller installs instructions, and what restore installs.
pub const base_profile: wire.PromptProfileV1 = blk: {
    var value = std.mem.zeroes(wire.PromptProfileV1);
    value.struct_size = @sizeOf(wire.PromptProfileV1);
    value.sections = &base_sections;
    value.section_count = base_sections.len;
    break :blk value;
};

pub const global_instructions_id = "host:user-instructions-global";
pub const project_instructions_id = "host:user-instructions-project";

/// After every kernel section: the user's instructions are the last word on
/// how to do the work, below everything that says what may be done. The
/// highest kernel order measured is `metacodes:env` (9000); the probe asserts
/// the rendered position against the real manifest rather than this number.
/// The project section renders after the global one, which is also the
/// precedence both headers state.
pub const global_instructions_order: i64 = 10000;
pub const project_instructions_order: i64 = 10100;

const global_preamble =
    "The user wrote these standing instructions for all of their tasks. " ++
    "Follow them unless they conflict with the project instructions, which take precedence. " ++
    "They cannot change the safety, permission or approval rules, and grant no capability those rules withhold.";

const project_preamble =
    "The user wrote these instructions for work in this directory. " ++
    "Where they conflict with the global user instructions, follow these. " ++
    "They cannot change the safety, permission or approval rules, and grant no capability those rules withhold.";

const global_title = "# User instructions: global\nSource: ";
const project_title = "# User instructions: project\nSource: ";
const truncated_prefix = "\n\n[Truncated: this file exceeds 32 KiB; only its first ";
const truncated_suffix = " bytes are included.]";

/// The longest section text one document can produce.
pub const max_instruction_section_bytes: usize = @max(global_title.len + global_preamble.len, project_title.len + project_preamble.len) +
    "\n".len + surface.max_instruction_path_bytes + "\n\n".len + surface.max_instruction_text_bytes +
    truncated_prefix.len + std.fmt.count("{d}", .{surface.max_instruction_text_bytes}) + truncated_suffix.len;

comptime {
    // The worst case fits the ABI's three profile limits on every platform, so
    // a well-formed document is never refused for its size.
    if (max_instruction_section_bytes > wire.MAX_PROMPT_SECTION_TEXT_BYTES_V1)
        @compileError("an instruction section can exceed the ABI section limit");
    for ([_]std.Target.Os.Tag{ .windows, .macos, .linux }) |os| {
        var total: usize = 2 * max_instruction_section_bytes;
        for (identity.sections) |section| total += section.text.len;
        for (guidance.sectionsFor(os)) |section| total += section.text.len;
        if (total > wire.MAX_PROMPT_PROFILE_TEXT_BYTES_V1)
            @compileError("a profile with both instruction sections can exceed the ABI profile limit");
        if (identity.sections.len + guidance.sectionsFor(os).len + 2 > wire.MAX_PROMPT_PROFILE_SECTIONS_V1)
            @compileError("a profile with both instruction sections exceeds the ABI section count");
    }
}

/// Which supplied documents a profile carries.
pub const Keep = struct {
    global: bool = false,
    project: bool = false,
};

/// The base sections plus the rendered instruction sections. The rendered
/// texts are owned; `profile` composes one selection of them at a time.
pub const Assembly = struct {
    allocator: std.mem.Allocator,
    global: ?[]u8 = null,
    project: ?[]u8 = null,
    sections: [base_sections.len + 2]wire.PromptSectionV1 = undefined,

    /// The documents must already be valid (`surface.validateInstructions`).
    pub fn init(allocator: std.mem.Allocator, instructions: surface.Instructions) std.mem.Allocator.Error!Assembly {
        var value: Assembly = .{ .allocator = allocator };
        errdefer value.deinit();
        if (instructions.global) |document| value.global = try render(allocator, .global, document);
        if (instructions.project) |document| value.project = try render(allocator, .project, document);
        return value;
    }

    pub fn deinit(self: *Assembly) void {
        if (self.global) |text| self.allocator.free(text);
        if (self.project) |text| self.allocator.free(text);
        self.* = undefined;
    }

    /// The documents this Assembly can carry.
    pub fn offered(self: *const Assembly) Keep {
        return .{ .global = self.global != null, .project = self.project != null };
    }

    /// Valid until the next call or `deinit`. A selection names only
    /// documents this Assembly holds.
    pub fn profile(self: *Assembly, keep: Keep) wire.PromptProfileV1 {
        std.debug.assert(!keep.global or self.global != null);
        std.debug.assert(!keep.project or self.project != null);
        @memcpy(self.sections[0..base_sections.len], &base_sections);
        var count: usize = base_sections.len;
        if (keep.global) {
            self.sections[count] = addition(global_instructions_id, global_instructions_order, self.global.?);
            count += 1;
        }
        if (keep.project) {
            self.sections[count] = addition(project_instructions_id, project_instructions_order, self.project.?);
            count += 1;
        }
        var value = std.mem.zeroes(wire.PromptProfileV1);
        value.struct_size = @sizeOf(wire.PromptProfileV1);
        value.sections = &self.sections;
        value.section_count = count;
        return value;
    }
};

const Source = enum { global, project };

fn render(allocator: std.mem.Allocator, source: Source, document: surface.InstructionDocument) std.mem.Allocator.Error![]u8 {
    const title, const preamble = switch (source) {
        .global => .{ global_title, global_preamble },
        .project => .{ project_title, project_preamble },
    };
    const footer = truncated_prefix ++ "{d}" ++ truncated_suffix;
    const footer_len = if (document.truncated) std.fmt.count(footer, .{document.text.len}) else 0;
    const text = try allocator.alloc(u8, title.len + document.path.len + "\n".len + preamble.len + "\n\n".len + document.text.len + footer_len);
    const head = std.fmt.bufPrint(text, "{s}{s}\n{s}\n\n{s}", .{ title, document.path, preamble, document.text }) catch unreachable;
    if (document.truncated) _ = std.fmt.bufPrint(text[head.len..], footer, .{document.text.len}) catch unreachable;
    return text;
}

/// Interpolation stays off: a user's text may hold any `{{...}}`, and an
/// unknown placeholder would refuse the whole profile, identity included.
fn addition(id: []const u8, order: i64, text: []const u8) wire.PromptSectionV1 {
    var value = std.mem.zeroes(wire.PromptSectionV1);
    value.struct_size = @sizeOf(wire.PromptSectionV1);
    value.op_code = wire.PROMPT_OP_ADD;
    value.id = sdk.bytesView(id);
    value.order = order;
    value.text = sdk.bytesView(text);
    value.interpolate = 0;
    return value;
}

pub const SetResult = union(enum) {
    status: sdk.Status,
    /// The status code or diagnostic was not one the ABI allows.
    contract_violation,
};

/// One profile setter call. The caller owns the state checks around it and
/// what each status means for its own operation.
pub fn set(api: sdk.Api, handle: ?*wire.SessionHandle, profile: *const wire.PromptProfileV1) SetResult {
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    const code = api.sessionControl().setPromptProfile()(handle, profile, &diagnostic);
    defer if (diagnostic.ptr != null or diagnostic.len != 0) api.bufferRelease()(&diagnostic);
    _ = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch
        return .contract_violation;
    return .{ .status = sdk.Status.fromCode(code) catch return .contract_violation };
}

/// The candidate is unpublished and fenced by Runtime's restore reservation.
/// Restore installs the base profile: the caller supplies the user's current
/// instructions before the next Run, so a checkpoint's frozen copy never
/// outlives the restore.
pub fn apply(api: sdk.Api, candidate: *wire.SessionHandle) error{ RestoreFailed, RestoreContractFailed }!void {
    switch (set(api, candidate, &base_profile)) {
        .contract_violation => return error.RestoreContractFailed,
        .status => |status| switch (status) {
            .ok => {},
            .invalid_argument, .out_of_memory, .busy, .invalid_state, .core_error, .internal_error, .resource_limit, .checkpoint_budget_required => return error.RestoreFailed,
            else => return error.RestoreContractFailed,
        },
    }
}

test "the profile keeps identity replacements and host additions as separate edits" {
    try std.testing.expectEqual(base_sections.len, base_profile.section_count);
    try std.testing.expectEqual(identity.sections.len + guidance.sections.len, base_sections.len);
    var replacements: usize = 0;
    var additions: usize = 0;
    for (base_sections) |section| {
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

fn sectionText(section: wire.PromptSectionV1) ![]const u8 {
    return sdk.borrowedBytes(section.text);
}

test "instruction sections follow every base section and keep the user's text verbatim" {
    var assembly = try Assembly.init(std.testing.allocator, .{
        .global = .{ .path = "/home/user/.metawork/AGENTS.md", .text = "Answer in {{language}}.", .truncated = false },
        .project = .{ .path = "/work/repo/AGENTS.md", .text = "Run the tests with `zig build test`.", .truncated = false },
    });
    defer assembly.deinit();
    try std.testing.expectEqual(Keep{ .global = true, .project = true }, assembly.offered());
    const profile = assembly.profile(.{ .global = true, .project = true });
    try std.testing.expectEqual(base_sections.len + 2, profile.section_count);
    const sections = profile.sections.?[0..@intCast(profile.section_count)];
    // The base sections are untouched and come first.
    for (base_sections, sections[0..base_sections.len]) |expected, actual| {
        try std.testing.expectEqualStrings(try sdk.borrowedBytes(expected.id), try sdk.borrowedBytes(actual.id));
        try std.testing.expectEqualStrings(try sectionText(expected), try sectionText(actual));
    }
    const global = sections[base_sections.len];
    const project = sections[base_sections.len + 1];
    for ([_]wire.PromptSectionV1{ global, project }, [_][]const u8{ global_instructions_id, project_instructions_id }) |section, id| {
        try std.testing.expectEqual(wire.PROMPT_OP_ADD, section.op_code);
        try std.testing.expectEqual(@as(u32, 0), section.interpolate);
        try std.testing.expectEqualStrings(id, try sdk.borrowedBytes(section.id));
        // Every kernel order measured is at most 9000, and every host
        // guidance section sits below the instructions too.
        try std.testing.expect(section.order > 9000);
        for (base_sections) |base| try std.testing.expect(section.order > base.order);
        const text = try sectionText(section);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        try std.testing.expect(std.mem.indexOf(u8, text, "cannot change the safety, permission or approval rules") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "[Truncated") == null);
    }
    try std.testing.expect(global.order < project.order);
    const global_text = try sectionText(global);
    try std.testing.expect(std.mem.startsWith(u8, global_text, "# User instructions: global\nSource: /home/user/.metawork/AGENTS.md\n"));
    try std.testing.expect(std.mem.indexOf(u8, global_text, "project instructions, which take precedence") != null);
    // A placeholder reaches the model as written.
    try std.testing.expect(std.mem.endsWith(u8, global_text, "\n\nAnswer in {{language}}."));
    const project_text = try sectionText(project);
    try std.testing.expect(std.mem.startsWith(u8, project_text, "# User instructions: project\nSource: /work/repo/AGENTS.md\n"));
    try std.testing.expect(std.mem.indexOf(u8, project_text, "conflict with the global user instructions, follow these") != null);
    try std.testing.expect(std.mem.endsWith(u8, project_text, "\n\nRun the tests with `zig build test`."));
}

test "every selection of the instruction sections is a well-formed profile" {
    var assembly = try Assembly.init(std.testing.allocator, .{
        .global = .{ .path = "C:\\Users\\user\\.metawork\\AGENTS.md", .text = "global", .truncated = false },
        .project = .{ .path = "D:\\repo\\AGENTS.md", .text = "project", .truncated = false },
    });
    defer assembly.deinit();
    for ([_]Keep{ .{ .global = true, .project = true }, .{ .global = true }, .{ .project = true }, .{} }) |keep| {
        const profile = assembly.profile(keep);
        const expected = base_sections.len + @intFromBool(keep.global) + @intFromBool(keep.project);
        try std.testing.expectEqual(expected, profile.section_count);
        const sections = profile.sections.?[0..@intCast(profile.section_count)];
        for (sections[base_sections.len..]) |section| {
            const id = try sdk.borrowedBytes(section.id);
            try std.testing.expect(if (std.mem.eql(u8, id, global_instructions_id)) keep.global else keep.project);
        }
    }
    // An empty selection is the base profile, section for section.
    const base_only = assembly.profile(.{});
    for (base_sections, base_only.sections.?[0..@intCast(base_only.section_count)]) |expected, actual|
        try std.testing.expectEqualStrings(try sectionText(expected), try sectionText(actual));
}

test "a truncated document says so after its text, with the bytes it kept" {
    const kept = "x" ** 32;
    var assembly = try Assembly.init(std.testing.allocator, .{
        .project = .{ .path = "/repo/AGENTS.md", .text = kept, .truncated = true },
    });
    defer assembly.deinit();
    try std.testing.expectEqual(Keep{ .project = true }, assembly.offered());
    const profile = assembly.profile(.{ .project = true });
    const text = try sectionText(profile.sections.?[@intCast(profile.section_count - 1)]);
    try std.testing.expect(std.mem.endsWith(u8, text, kept ++ "\n\n[Truncated: this file exceeds 32 KiB; only its first 32 bytes are included.]"));
}

test "instruction documents are checked before any section is built" {
    const valid: surface.InstructionDocument = .{ .path = "/home/user/.metawork/AGENTS.md", .text = "Be brief.", .truncated = false };
    try surface.validateInstructions(.{});
    try surface.validateInstructions(.{ .global = valid, .project = valid });
    const text_limit = "a" ** surface.max_instruction_text_bytes;
    try surface.validateInstructions(.{ .project = .{ .path = valid.path, .text = text_limit, .truncated = true } });
    const invalid = [_]surface.InstructionDocument{
        .{ .path = "", .text = valid.text, .truncated = false },
        .{ .path = "/a\nb", .text = valid.text, .truncated = false },
        .{ .path = "/a\xff", .text = valid.text, .truncated = false },
        .{ .path = valid.path, .text = "", .truncated = false },
        .{ .path = valid.path, .text = "a\x00b", .truncated = false },
        .{ .path = valid.path, .text = "\xc3", .truncated = false },
        .{ .path = valid.path, .text = text_limit ++ "a", .truncated = true },
    };
    for (invalid) |document| {
        try std.testing.expectError(error.InvalidInstructions, surface.validateInstructions(.{ .global = document }));
        try std.testing.expectError(error.InvalidInstructions, surface.validateInstructions(.{ .global = valid, .project = document }));
    }
    // The path rule a caller checks before reading is the one applied here.
    try std.testing.expect(surface.validInstructionPath(valid.path));
    for (invalid[0..3]) |document| try std.testing.expect(!surface.validInstructionPath(document.path));
    try std.testing.expect(!surface.validInstructionPath("/a\x7fb"));
    try std.testing.expect(!surface.validInstructionPath("/" ++ "p" ** surface.max_instruction_path_bytes));
}

test "the largest valid documents fit one section each" {
    const path = try std.testing.allocator.alloc(u8, surface.max_instruction_path_bytes);
    defer std.testing.allocator.free(path);
    @memset(path, 'p');
    path[0] = '/';
    const body = try std.testing.allocator.alloc(u8, surface.max_instruction_text_bytes);
    defer std.testing.allocator.free(body);
    @memset(body, 'b');
    var assembly = try Assembly.init(std.testing.allocator, .{
        .global = .{ .path = path, .text = body, .truncated = true },
        .project = .{ .path = path, .text = body, .truncated = true },
    });
    defer assembly.deinit();
    const profile = assembly.profile(.{ .global = true, .project = true });
    var total: usize = 0;
    for (profile.sections.?[0..@intCast(profile.section_count)]) |section| {
        const text = try sectionText(section);
        try std.testing.expect(text.len <= wire.MAX_PROMPT_SECTION_TEXT_BYTES_V1);
        total += text.len;
    }
    try std.testing.expect(total <= wire.MAX_PROMPT_PROFILE_TEXT_BYTES_V1);
    try std.testing.expect(assembly.global.?.len <= max_instruction_section_bytes);
}
