const app_manifest = @import("app_manifest_zon");

pub const bundle_id = app_manifest.id;
pub const version = app_manifest.version;
pub const macos_data_directory_name = "MetaWork Dev";
pub const macos_account_keychain_service = bundle_id ++ ".account";
pub const mcp_credential_service = bundle_id ++ ".mcp";

test "MCP credentials use a product-owned service separate from Account" {
    const std = @import("std");
    try std.testing.expect(!std.mem.eql(
        u8,
        macos_account_keychain_service,
        mcp_credential_service,
    ));
    try std.testing.expect(std.mem.endsWith(u8, mcp_credential_service, ".mcp"));
}
