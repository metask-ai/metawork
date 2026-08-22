//! Product Account module entrypoint.
const std = @import("std");
const state_impl = @import("account_state");
const oauth_impl = @import("account_oauth");
const metask_client_impl = @import("metask_client");
const credential_store_impl = @import("account_credential_store");
const ports_impl = @import("account_ports");
const loopback_impl = @import("account_loopback");
const login_attempt_impl = @import("account_login_attempt");
const catalog_impl = @import("account_catalog");
const credentials_impl = @import("account_credentials_runtime");
const network_attempt_impl = @import("account_network_attempt");
const runtime_impl = @import("account_runtime");

pub const Runtime = runtime_impl.Runtime;
pub const Prepared = runtime_impl.Prepared;
pub const PlatformPorts = ports_impl.Platform;
pub const TestSupport = runtime_impl.TestSupport;
pub const Transport = metask_client_impl.Transport;
pub const TransportRequest = metask_client_impl.Request;
pub const TransportResponse = metask_client_impl.Response;
pub const TransportError = metask_client_impl.TransportError;

test {
    _ = state_impl;
    _ = oauth_impl;
    _ = metask_client_impl;
    _ = credential_store_impl;
    _ = ports_impl;
    _ = loopback_impl;
    _ = login_attempt_impl;
    _ = catalog_impl;
    _ = credentials_impl;
    _ = network_attempt_impl;
    _ = runtime_impl;
}
