//! Host-owned product orchestration and exact Renderer projection surface.

const projection_impl = @import("workbench_projection");
const executor_impl = @import("workbench_executor");

pub const projection = projection_impl;
pub const executor = executor_impl;
pub const Error = projection_impl.Error;
pub const Limits = projection_impl.Limits;
pub const Workbench = projection_impl.Workbench;
pub const snapshot_schema_version = projection_impl.snapshot_schema_version;
