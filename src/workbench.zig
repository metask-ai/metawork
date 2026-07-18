//! Workbench-owned product orchestration and durable projection surface.

const projection_impl = @import("workbench_projection");
const executor_impl = @import("workbench_executor");

pub const Error = projection_impl.Error;
pub const Limits = projection_impl.Limits;
pub const Workbench = projection_impl.Workbench;
pub const RunRef = projection_impl.RunRef;
pub const ChangeNotifier = projection_impl.ChangeNotifier;
pub const snapshot_schema_version = projection_impl.snapshot_schema_version;
pub const Executor = executor_impl.Executor;
pub const ExecutorLimits = executor_impl.Limits;
