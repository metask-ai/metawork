//! Release build automation boundary. This module deliberately exposes only
//! inert authority hooks and contains no fixture origin or credential.

const std = @import("std");
const native_sdk = @import("native_sdk");
const models_contract = @import("metawork_product_models_contract");

pub const enabled = false;

pub const ExecutionFixture = struct {
    protocol: models_contract.Protocol,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Runtime = struct {
    pub fn init(_: *std.process.Environ.Map) Runtime {
        return .{};
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn active(_: *const Runtime) bool {
        return false;
    }

    pub fn customProviderReadinessActive(_: *const Runtime) bool {
        return false;
    }

    pub fn bridgeHarnessActive(_: *const Runtime) bool {
        return false;
    }

    pub fn executionFixture(_: *const Runtime) ?ExecutionFixture {
        return null;
    }

    pub fn workspaceRoot(_: *const Runtime) ?[]const u8 {
        return null;
    }

    pub fn attachmentPaths(_: *const Runtime) ?[]const u8 {
        return null;
    }

    pub fn canonicalUserHome(_: *const Runtime) ?[]const u8 {
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
};

test "release automation boundary is inert" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var runtime = Runtime.init(&env);
    defer runtime.deinit();
    try std.testing.expect(!runtime.active());
    try std.testing.expect(!runtime.customProviderReadinessActive());
    try std.testing.expect(!runtime.bridgeHarnessActive());
    try std.testing.expectEqual(@as(?[]const u8, null), runtime.workspaceRoot());
    try std.testing.expectEqual(@as(?[]const u8, null), runtime.attachmentPaths());
    try std.testing.expectEqual(@as(?[]const u8, null), runtime.canonicalUserHome());
}
