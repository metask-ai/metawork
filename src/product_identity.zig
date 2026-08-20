const app_manifest = @import("app_manifest_zon");

pub const bundle_id = app_manifest.id;
pub const version = app_manifest.version;
pub const macos_data_directory_name = "MetaWork Dev";
pub const mcp_credential_service = bundle_id ++ ".mcp";
pub const automation_runner_bundle_id = bundle_id ++ ".automation";

/// The shipping product always uses the manifest identity. Automation is a
/// compile-time-only artifact and gets its own Native SDK data/window/log
/// namespace even when it is launched outside the repository harness.
pub fn runnerBundleId(automation: bool) []const u8 {
    return if (automation) automation_runner_bundle_id else bundle_id;
}

test "MCP credentials use a product-owned service" {
    const std = @import("std");
    try std.testing.expect(std.mem.endsWith(u8, mcp_credential_service, ".mcp"));
}

test "automation runner identity is derived without changing the product identity" {
    const std = @import("std");
    try std.testing.expectEqualStrings(bundle_id, runnerBundleId(false));
    try std.testing.expectEqualStrings(
        "com.metask.metawork.dev.automation",
        runnerBundleId(true),
    );
    try std.testing.expectEqualStrings("com.metask.metawork.dev", bundle_id);
}
