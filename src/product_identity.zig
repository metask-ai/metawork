const std = @import("std");
const app_manifest = @import("app_manifest_zon");
const artifact_options = @import("metawork_artifact_options");

pub const ArtifactKind = enum {
    development,
    release,
    automation,
};

pub const artifact_kind = std.meta.stringToEnum(
    ArtifactKind,
    artifact_options.kind,
) orelse @compileError("invalid MetaWork artifact kind");

pub const bundle_id = app_manifest.id;
pub const version = app_manifest.version;
pub const macos_data_directory_name = "MetaWork Dev";
pub const windows_data_directory_name = "MetaWork";
pub const automation_data_directory_name = "MetaWork Automation";
pub const automation_runner_bundle_id = bundle_id ++ ".automation";
pub const development_account_credential_service = bundle_id ++ ".account";
pub const automation_account_credential_service = bundle_id ++ ".automation.account";
pub const development_mcp_credential_service = bundle_id ++ ".mcp";
pub const automation_mcp_credential_service = bundle_id ++ ".automation.mcp";

pub fn runnerBundleId() []const u8 {
    return switch (artifact_kind) {
        .development => bundle_id,
        .automation => automation_runner_bundle_id,
        .release => @compileError("MetaWork release identity is not configured"),
    };
}

pub fn dataDirectoryName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (artifact_kind) {
        .development => if (os_tag == .macos)
            macos_data_directory_name
        else
            windows_data_directory_name,
        .automation => automation_data_directory_name,
        .release => @compileError("MetaWork release data directory is not configured"),
    };
}

pub fn accountCredentialService() []const u8 {
    return switch (artifact_kind) {
        .development => development_account_credential_service,
        .automation => automation_account_credential_service,
        .release => @compileError("MetaWork release Account credential service is not configured"),
    };
}

pub fn mcpCredentialService() []const u8 {
    return switch (artifact_kind) {
        .development => development_mcp_credential_service,
        .automation => automation_mcp_credential_service,
        .release => @compileError("MetaWork release MCP credential service is not configured"),
    };
}

test "MCP credentials use a product-owned service" {
    try std.testing.expect(std.mem.endsWith(u8, mcpCredentialService(), ".mcp"));
}

test "artifact namespaces preserve development and isolate automation" {
    try std.testing.expectEqualStrings("com.metask.metawork.dev", bundle_id);
    switch (artifact_kind) {
        .development => {
            try std.testing.expectEqualStrings(bundle_id, runnerBundleId());
            try std.testing.expectEqualStrings("MetaWork", dataDirectoryName(.windows));
            try std.testing.expectEqualStrings("MetaWork Dev", dataDirectoryName(.macos));
            try std.testing.expectEqualStrings(
                "com.metask.metawork.dev.account",
                accountCredentialService(),
            );
            try std.testing.expectEqualStrings(
                "com.metask.metawork.dev.mcp",
                mcpCredentialService(),
            );
        },
        .automation => {
            try std.testing.expectEqualStrings(
                "com.metask.metawork.dev.automation",
                runnerBundleId(),
            );
            try std.testing.expectEqualStrings(
                "MetaWork Automation",
                dataDirectoryName(.windows),
            );
            try std.testing.expectEqualStrings(
                "com.metask.metawork.dev.automation.account",
                accountCredentialService(),
            );
            try std.testing.expectEqualStrings(
                "com.metask.metawork.dev.automation.mcp",
                mcpCredentialService(),
            );
        },
        .release => unreachable,
    }
}
