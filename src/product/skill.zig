//! Public surface of the live Product Skill aggregate.
//! Internal policy, state, view, package, and management-runtime modules are
//! composed behind Runtime rather than published for Workbench assembly.

pub const catalog = @import("product_skill_catalog");
pub const enablement = @import("product_skill_enablement");
pub const management = @import("product_skill_management");
pub const sources = @import("product_skill_sources");
pub const ports = @import("product_skill_ports");
pub const runtime = @import("product_skill_runtime");
