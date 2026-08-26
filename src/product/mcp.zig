//! Workbench-held Product MCP submodule.
//! Physical Product placement does not create an independent owner.

pub const configuration = @import("product_mcp_configuration");
pub const state = @import("product_mcp_state");
pub const policy = @import("product_mcp_policy");
pub const view = @import("product_mcp_view");
pub const ports = @import("product_mcp_ports");
pub const refresh_job = @import("product_mcp_refresh_job");
pub const runtime = @import("product_mcp_runtime");
