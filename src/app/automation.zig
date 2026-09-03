const std = @import("std");
const native_sdk = @import("native_sdk");
const bridge_api = @import("metawork_bridge");
const automation_api = @import("metawork_automation");

pub const Adapter = struct {
    runtime: automation_api.Runtime,

    pub fn init(env_map: *std.process.Environ.Map) Adapter {
        return .{ .runtime = automation_api.Runtime.init(env_map) };
    }

    pub fn deinit(self: *Adapter) void {
        self.runtime.deinit();
    }

    pub fn active(self: *const Adapter) bool {
        return self.runtime.active();
    }

    pub fn bridgeHarnessActive(self: *const Adapter) bool {
        return self.runtime.bridgeHarnessActive();
    }

    pub fn productDeliveryTraceEnabled(self: *const Adapter) bool {
        return self.active();
    }

    pub fn executionFixture(self: *const Adapter) ?automation_api.ExecutionFixture {
        return self.runtime.executionFixture();
    }

    pub fn workspaceRoot(self: *const Adapter) ?[]const u8 {
        return self.runtime.workspaceRoot();
    }

    pub fn attachmentPaths(self: *const Adapter) ?[]const u8 {
        return self.runtime.attachmentPaths();
    }

    pub fn canonicalUserHome(self: *const Adapter) ?[]const u8 {
        return self.runtime.canonicalUserHome();
    }

    pub fn productPolicy(
        self: *Adapter,
        base: native_sdk.BridgePolicy,
    ) native_sdk.BridgePolicy {
        return self.runtime.productPolicy(base);
    }

    pub fn builtinPolicy(
        self: *Adapter,
        base: native_sdk.BridgePolicy,
    ) native_sdk.BridgePolicy {
        return self.runtime.builtinPolicy(base);
    }

    pub fn allowedOrigins(
        self: *const Adapter,
        base: []const []const u8,
    ) []const []const u8 {
        return self.runtime.allowedOrigins(base);
    }

    pub fn dispatcherAuthority(self: *Adapter) bridge_api.DispatcherAutomationAuthority {
        return .{
            .context = self,
            .active_fn = activeCallback,
            .workspace_root_fn = workspaceRootCallback,
            .attachment_paths_fn = attachmentPathsCallback,
        };
    }

    fn activeCallback(context: ?*anyopaque) bool {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.bridgeHarnessActive();
    }

    fn workspaceRootCallback(context: ?*anyopaque) ?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.workspaceRoot();
    }

    fn attachmentPathsCallback(context: ?*anyopaque) ?[]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(context.?));
        return self.attachmentPaths();
    }
};
