const std = @import("std");
const state_impl = @import("account_state");
const oauth_impl = @import("account_oauth");
const metask_client_impl = @import("metask_client");
const credential_store_impl = @import("account_credential_store");
const windows_store_impl = @import("account_windows_store");
const platform_impl = @import("account_platform");
const loopback_impl = @import("account_loopback");
const login_attempt_impl = @import("account_login_attempt");
const catalog_impl = @import("account_catalog");
const credentials_impl = @import("account_credentials_runtime");
const network_attempt_impl = @import("account_network_attempt");
const runtime_impl = @import("account_runtime");

pub const Runtime = runtime_impl.Runtime;
pub const Prepared = runtime_impl.Prepared;
pub const PlatformServices = platform_impl.Services;
pub const TestSupport = runtime_impl.TestSupport;

test {
    _ = state_impl;
    _ = oauth_impl;
    _ = metask_client_impl;
    _ = credential_store_impl;
    _ = windows_store_impl;
    _ = platform_impl;
    _ = loopback_impl;
    _ = login_attempt_impl;
    _ = catalog_impl;
    _ = credentials_impl;
    _ = network_attempt_impl;
    _ = runtime_impl;
}
