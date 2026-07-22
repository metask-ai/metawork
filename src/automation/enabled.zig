//! Automation-only Native composition. This file is injected by build.zig
//! only for `-Dautomation=true` and is absent from the release module graph.
//! Automation supplies controlled credentials, origins, and temporary
//! Workspace authority; product events still use the normal Bridge data plane.

const std = @import("std");
const native_sdk = @import("native_sdk");
const account_contract = @import("metawork_account_contract");

pub const enabled = true;

const activation_env = "METAWORK_AUTOMATION";
const workspace_env = "METAWORK_AUTOMATION_WORKSPACE";
const inline_origin = "zero://inline";
const allowed_origins = [_][]const u8{ "zero://app", inline_origin };
const agentcore_vertical_provider_base_url_env =
    "METAWORK_AGENTCORE_VERTICAL_PROVIDER_BASE_URL";
const agentcore_vertical_credential = "metawork-agentcore-vertical-fixture-key";
const agentcore_vertical_model = "metawork-agentcore-vertical-fixture-model";

pub const ExecutionFixture = struct {
    provider: account_contract.ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Runtime = struct {
    env_map: ?*std.process.Environ.Map = null,
    policy_commands: [32]native_sdk.bridge.CommandPolicy = undefined,
    builtin_commands: [16]native_sdk.bridge.CommandPolicy = undefined,

    pub fn init(env_map: *std.process.Environ.Map) Runtime {
        return .{ .env_map = env_map };
    }

    pub fn deinit(self: *Runtime) void {
        self.* = undefined;
    }

    pub fn active(self: *const Runtime) bool {
        const env_map = self.env_map orelse return false;
        const value = env_map.get(activation_env) orelse return false;
        return std.mem.eql(u8, value, "1");
    }

    pub fn executionFixture(self: *const Runtime) ?ExecutionFixture {
        if (!self.active()) return null;
        const env_map = self.env_map orelse return null;
        const base_url = env_map.get(
            agentcore_vertical_provider_base_url_env,
        ) orelse return null;
        return .{
            .provider = .anthropic,
            .credential = agentcore_vertical_credential,
            .model = agentcore_vertical_model,
            .base_url = base_url,
        };
    }

    /// Returns the temporary Workspace capability injected by the vertical
    /// harness. The Dispatcher consumes it through the ordinary
    /// `workspaces.choose` command; it is never a Task-create escape hatch.
    pub fn workspaceRoot(self: *const Runtime) ?[]const u8 {
        if (!self.active()) return null;
        const env_map = self.env_map orelse return null;
        const root = env_map.get(workspace_env) orelse return null;
        return if (root.len == 0) null else root;
    }

    pub fn productPolicy(self: *Runtime, base: native_sdk.BridgePolicy) native_sdk.BridgePolicy {
        if (!self.active()) return base;
        std.debug.assert(base.commands.len <= self.policy_commands.len);
        for (base.commands, 0..) |command, index| {
            self.policy_commands[index] = command;
            self.policy_commands[index].origins = &allowed_origins;
        }
        return .{
            .enabled = base.enabled,
            .permissions = base.permissions,
            .commands = self.policy_commands[0..base.commands.len],
        };
    }

    pub fn builtinPolicy(self: *Runtime, base: native_sdk.BridgePolicy) native_sdk.BridgePolicy {
        if (!self.active()) return base;
        std.debug.assert(base.commands.len <= self.builtin_commands.len);
        for (base.commands, 0..) |command, index| {
            self.builtin_commands[index] = command;
            self.builtin_commands[index].origins = &allowed_origins;
        }
        return .{
            .enabled = base.enabled,
            .permissions = base.permissions,
            .commands = self.builtin_commands[0..base.commands.len],
        };
    }

    pub fn allowedOrigins(self: *const Runtime, base: []const []const u8) []const []const u8 {
        return if (self.active()) &allowed_origins else base;
    }
};

test "automation policy changes authority without adding a data plane" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put(activation_env, "1");
    var runtime = Runtime.init(&env);
    defer runtime.deinit();

    try std.testing.expect(runtime.active());
    const base = @import("metawork_bridge").policy.product(.release);
    const policy = runtime.productPolicy(base);
    try std.testing.expectEqual(base.commands.len, policy.commands.len);
    try std.testing.expectEqualStrings(inline_origin, policy.commands[0].origins[1]);
}

test "automation workspace is an explicit activation-scoped capability" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var runtime = Runtime.init(&env);
    defer runtime.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), runtime.workspaceRoot());
    try env.put(activation_env, "1");
    try std.testing.expectEqual(@as(?[]const u8, null), runtime.workspaceRoot());
    try env.put(workspace_env, "");
    try std.testing.expectEqual(@as(?[]const u8, null), runtime.workspaceRoot());
    try env.put(workspace_env, "/tmp/metawork-automation");
    try std.testing.expectEqualStrings(
        "/tmp/metawork-automation",
        runtime.workspaceRoot().?,
    );
}
