//! Release build automation boundary. This module deliberately exposes only
//! inert composition hooks and contains no fixture command, origin, payload,
//! worker, or diagnostic token.

const std = @import("std");
const native_sdk = @import("native_sdk");
const renderer_bridge = @import("metawork_bridge");
const account_contract = @import("metawork_account_contract");

pub const enabled = false;
pub const handler_count: usize = 0;

pub const Hooks = struct {
    context: ?*anyopaque = null,
    break_product_connection_fn: *const fn (?*anyopaque) void,
};

pub const ExecutionFixture = struct {
    provider: account_contract.ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Runtime = struct {
    pub fn init(_: std.mem.Allocator, _: *std.process.Environ.Map, _: std.Thread.Id) !Runtime {
        return .{};
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn bind(
        _: *Runtime,
        _: *renderer_bridge.CallbackGate,
        _: *renderer_bridge.ProductDelivery,
        _: Hooks,
    ) void {}

    pub fn start(_: *Runtime, _: *native_sdk.Runtime) void {}
    pub fn stop(_: *Runtime) void {}
    pub fn active(_: *const Runtime) bool {
        return false;
    }

    pub fn executionFixture(_: *const Runtime) ?ExecutionFixture {
        return null;
    }

    pub fn productPolicy(_: *Runtime, base: native_sdk.BridgePolicy) native_sdk.BridgePolicy {
        return base;
    }

    pub fn builtinPolicy(_: *Runtime, base: native_sdk.BridgePolicy) native_sdk.BridgePolicy {
        return base;
    }

    pub fn allowedOrigins(_: *const Runtime, base: []const []const u8) []const []const u8 {
        return base;
    }

    pub fn fillHandlers(_: *Runtime, output: []native_sdk.bridge.Handler) void {
        std.debug.assert(output.len == 0);
    }

    pub fn beforeConnect(_: *Runtime, _: u64) !void {}
    pub fn connectAt(_: *Runtime, _: u64) !void {}
    pub fn detach(_: *Runtime, _: u64, _: u64) !void {}
    pub fn onEffectsWake(_: *Runtime, _: native_sdk.platform.WindowId) !void {}
    pub fn onTimer(_: *Runtime, _: u64, _: u64) bool {
        return false;
    }
};

test "release automation boundary is inert" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var runtime = try Runtime.init(std.testing.allocator, &env, std.Thread.getCurrentId());
    defer runtime.deinit();
    try std.testing.expect(!runtime.active());
    try std.testing.expectEqual(@as(usize, 0), handler_count);
}
