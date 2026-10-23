//! Isolated public-ABI consumer for the Windows Office/Core Shell qualification.
//! The controller supplies exactly one fixture tool call, then either requests
//! cooperative abort over stdin or hard-kills this process without destructors.
const std = @import("std");
const core = @import("lifecycle_fixture").sdk;
const office = @import("office_process");
const wire = core.types;

const Run = struct {
    api: core.Api,
    session: *wire.SessionHandle,
    status: u32 = std.math.maxInt(u32),
    stop: u32 = std.math.maxInt(u32),

    fn execute(self: *Run) void {
        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 2;
        var result = std.mem.zeroes(wire.RunResultV1);
        var diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 };
        defer self.api.bufferRelease()(&diagnostic);
        self.status = self.api.session().runText(self.session, 1, core.bytesView("Office process lifetime fixture"), &options, &result, &diagnostic);
        self.stop = result.stop_reason_code;
        if (self.status != wire.STATUS_OK) std.debug.print("run diagnostic: {s}\n", .{core.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "unreadable"});
    }
};

fn event(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
    return wire.EVENT_CONTINUE;
}

fn require(status: u32, diagnostic: wire.OwnedBytesV1) !void {
    if (status == wire.STATUS_OK) return;
    std.debug.print("core status={d}: {s}\n", .{ status, core.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "unreadable" });
    return error.CoreCallFailed;
}

pub fn main(init: std.process.Init) !void {
    const identity_text = init.environ_map.get("METAWORK_OFFICE_CORE_INSTALL_ID") orelse return error.MissingFixtureIdentity;
    if (identity_text.len != 32) return error.InvalidFixtureIdentity;
    var identity: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&identity, identity_text);
    var version = try office.ResourceScope.initVersion(identity);
    defer version.deinit();
    const scope = try office.hostScope();
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "host.scope", .data = &scope });
    const api = try core.Api.discover();
    const tools = [_]wire.BytesViewV1{core.bytesView("Bash")};
    var diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &tools;
    runtime_config.builtin_tool_count = tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try require(api.runtime().create()(&runtime_config, null, &runtime, &diagnostic), diagnostic);
    defer _ = api.runtime().destroy()(runtime.?, null);
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_UNRESTRICTED;
    host.api_key = core.bytesView("office-qualification-fixture");
    host.base_url = core.bytesView(init.environ_map.get("METAWORK_OFFICE_CORE_URL") orelse return error.MissingFixtureUrl);
    const workspace = init.environ_map.get("METAWORK_OFFICE_CORE_WORKSPACE") orelse return error.MissingFixtureWorkspace;
    host.workspace_root = core.bytesView(workspace);
    host.workspace_home = core.bytesView(workspace);
    host.allowed_tools = &tools;
    host.allowed_tool_count = tools.len;
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = event;
    var session_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    session_config.host = &host;
    session_config.model = core.bytesView("office-qualification-model");
    var session: ?*wire.SessionHandle = null;
    try require(api.session().create()(runtime.?, &session_config, &callbacks, &session, &diagnostic), diagnostic);
    defer _ = api.session().destroy()(session.?, null);
    var command: [1]u8 = undefined;
    var reader_buffer: [32]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &reader_buffer);
    try input.interface.readSliceAll(&command);
    if (command[0] != 's') return error.InvalidQualificationCommand;
    var run: Run = .{ .api = api, .session = session.? };
    const thread = try std.Thread.spawn(.{}, Run.execute, .{&run});
    var joined = false;
    defer if (!joined) {
        _ = api.session().abort()(session.?, 1, wire.ABORT_USER_REQUEST, null);
        thread.join();
    };
    try input.interface.readSliceAll(&command);
    if (command[0] == 'q') {
        try version.settle(init.io);
        thread.join();
        joined = true;
        if (run.status != wire.STATUS_OK) return error.OfficeRunFailed;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "version.sealed", .data = "quiet" });
        try input.interface.readSliceAll(&command);
        if (command[0] != 'x') return error.InvalidQualificationCommand;
        return;
    }
    if (command[0] != 'a') return error.InvalidQualificationCommand;
    // An abort call can overlap run_input under the public ABI. Join before any
    // later Session call, including destroy, as the contract requires.
    const abort_status = api.session().abort()(session.?, 1, wire.ABORT_USER_REQUEST, &diagnostic);
    thread.join();
    joined = true;
    try require(abort_status, diagnostic);
    if (run.status != wire.STATUS_OK or run.stop != wire.STOP_ABORTED) return error.OfficeRunNotAborted;
    std.debug.print("Office Core Shell abort joined\n", .{});
}
