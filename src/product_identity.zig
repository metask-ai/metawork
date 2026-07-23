const app_manifest = @import("app_manifest_zon");

pub const bundle_id = app_manifest.id;
pub const macos_data_directory_name = "MetaWork Dev";
pub const macos_account_keychain_service = bundle_id ++ ".account";
