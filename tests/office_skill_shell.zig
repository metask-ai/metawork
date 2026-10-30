//! Public canonical ABI qualification of materialized built-in Skill resources.
const std = @import("std");
const core = @import("lifecycle_fixture").sdk;
const wire = core.types;

fn require(status: u32, diagnostic: wire.OwnedBytesV1) !void {
    if (status == wire.STATUS_OK) return;
    std.debug.print("Core status={d}: {s}\n", .{ status, core.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "unreadable" });
    return error.CoreCallFailed;
}
fn event(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
    return wire.EVENT_CONTINUE;
}

const PermissionProbe = struct {
    deny: bool,
    requests: usize = 0,

    fn answer(ctx: ?*anyopaque, _: ?*const wire.RunContextV1, encoded: wire.BytesViewV1, response: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *PermissionProbe = @ptrCast(@alignCast(ctx orelse return wire.UI_FATAL));
        const out = response orelse return wire.UI_FATAL;
        var request = core.decodeUiRequest(std.heap.c_allocator, core.borrowedBytes(encoded) catch return wire.UI_FATAL) catch return wire.UI_FATAL;
        defer request.deinit();
        if (request.value != .permission) return wire.UI_FATAL;
        const permission = request.value.permission;
        const bytes = core.encodeUiResponse(std.heap.c_allocator, request.value, .{ .permission = .{
            .permission = if (self.deny) .deny_once else .allow_once,
            .request_id = permission.request_id,
            .policy_generation = permission.policy_generation,
        } }) catch return wire.UI_FATAL;
        out.* = .{ .ptr = bytes.ptr, .len = bytes.len };
        self.requests += 1;
        return wire.UI_ANSWERED;
    }

    fn release(_: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const value = response orelse return;
        if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..@intCast(value.len)]);
        value.* = .{ .ptr = null, .len = 0 };
    }
};

pub fn main(init: std.process.Init) !void {
    const api = try core.Api.discover();
    const workspace = init.environ_map.get("METAWORK_OFFICE_CORE_WORKSPACE") orelse return error.MissingFixtureWorkspace;
    const root = init.environ_map.get("METAWORK_OFFICE_CORE_SKILLS") orelse return error.MissingFixtureSkills;
    const name = init.environ_map.get("METAWORK_OFFICE_CORE_SKILL") orelse return error.MissingFixtureSkill;
    const home = init.environ_map.get("METAWORK_OFFICE_CORE_HOME") orelse workspace;
    const permission_case = init.environ_map.get("METAWORK_OFFICE_CORE_PERMISSION_CASE");
    if (permission_case) |case| {
        if (!std.mem.eql(u8, case, "deny") and !std.mem.eql(u8, case, "allow") and !std.mem.eql(u8, case, "full")) return error.InvalidPermissionProbe;
    }
    const default_permission = if (permission_case) |case| !std.mem.eql(u8, case, "full") else false;
    var permission_probe = PermissionProbe{ .deny = if (permission_case) |case| std.mem.eql(u8, case, "deny") else false };
    const read_report = std.mem.eql(u8, init.environ_map.get("METAWORK_OFFICE_CORE_READ_REPORT") orelse "0", "1");
    if (read_report and (!std.mem.eql(u8, name, "xlsx") or permission_case != null))
        return error.InvalidFixtureMode;
    const tool_storage = [_]wire.BytesViewV1{ core.bytesView("Bash"), core.bytesView("Read") };
    const tools = tool_storage[0..@as(usize, if (read_report) 2 else 1)];
    var diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = tools.ptr;
    config.builtin_tool_count = tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try require(api.runtime().create()(&config, null, &runtime, &diagnostic), diagnostic);
    defer _ = api.runtime().destroy()(runtime.?, null);
    var source = std.mem.zeroes(wire.SkillSourceV1);
    source.struct_size = @sizeOf(wire.SkillSourceV1);
    source.scope_code = wire.SKILL_SOURCE_USER;
    source.root = core.bytesView(root);
    source.source_instance_id = core.bytesView("builtin-office");
    var query = std.mem.zeroes(wire.SkillCatalogQueryV1);
    query.struct_size = @sizeOf(wire.SkillCatalogQueryV1);
    query.workspace_root = core.bytesView(workspace);
    query.workspace_home = core.bytesView(home);
    query.workspace_epoch = core.bytesView("1");
    query.additional_sources = @ptrCast(&source);
    query.additional_source_count = 1;
    var catalog: ?*wire.SkillCatalogHandle = null;
    var descriptor: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&descriptor);
    try require(api.skill().resolveCatalog()(runtime.?, &query, &catalog, &descriptor, &diagnostic), diagnostic);
    defer _ = api.skill().releaseCatalog()(catalog.?, null);
    var parsed = try core.decodeSkillCatalog(std.heap.c_allocator, try core.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len }));
    defer parsed.deinit();
    if (parsed.value.skills.len != 3) return error.IncompleteBuiltinCatalog;
    var selected: ?[]const u8 = null;
    var ids: [3]wire.BytesViewV1 = undefined;
    for (parsed.value.skills, &ids) |skill, *id| {
        id.* = core.bytesView(skill.skill_id);
        if (std.mem.eql(u8, name, skill.invocation_name)) selected = skill.skill_id;
    }
    var policy = std.mem.zeroes(wire.SkillPolicyV1);
    policy.struct_size = @sizeOf(wire.SkillPolicyV1);
    policy.granted_skill_ids = &ids;
    policy.granted_skill_id_count = ids.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = if (default_permission) wire.PERMISSION_DEFAULT else wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_UNRESTRICTED;
    host.api_key = core.bytesView("office-local-fixture");
    host.base_url = core.bytesView(init.environ_map.get("METAWORK_OFFICE_CORE_URL") orelse return error.MissingFixtureUrl);
    host.workspace_root = core.bytesView(workspace);
    host.workspace_home = core.bytesView(home);
    host.allowed_tools = tools.ptr;
    host.allowed_tool_count = tools.len;
    host.skill_catalog = catalog;
    host.skill_policy = &policy;
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = event;
    if (permission_case != null) {
        callbacks.ctx = &permission_probe;
        callbacks.on_ui_request = PermissionProbe.answer;
        callbacks.release_response = PermissionProbe.release;
    }
    var session_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    session_config.host = &host;
    session_config.model = core.bytesView("office-fixture-model");
    var session: ?*wire.SessionHandle = null;
    try require(api.session().create()(runtime.?, &session_config, &callbacks, &session, &diagnostic), diagnostic);
    defer _ = api.session().destroy()(session.?, null);
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    // The report-read fixture has three declared provider turns: author/edit
    // via Bash, inspect via Read, then the final response. Other modes retain
    // their original two-turn input and Bash-only tool selection.
    options.max_turns = if (read_report) 3 else 2;
    var result = std.mem.zeroes(wire.RunResultV1);
    const arguments = try core.encodeSkillArguments(std.heap.c_allocator, &.{});
    defer std.heap.c_allocator.free(arguments);
    try require(api.session().runSkill(session.?, 1, core.bytesView(selected orelse return error.MissingBuiltinSkill), core.bytesView(parsed.value.catalog_revision), core.bytesView(arguments), &options, &result, &diagnostic), diagnostic);
    if (result.stop_reason_code != wire.STOP_END_TURN) return error.IncompleteOfficeRun;
    if (permission_case != null) {
        const expected: usize = if (default_permission) 1 else 0;
        if (permission_probe.requests != expected) return error.UnexpectedPermissionCallbacks;
        std.debug.print("Office permission callbacks: {d}\n", .{permission_probe.requests});
    }
}
