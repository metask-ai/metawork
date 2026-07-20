//! Workbench-owned product orchestration and durable projection surface.

const projection_impl = @import("workbench_projection");

pub const Error = projection_impl.Error;
pub const Limits = projection_impl.Limits;
pub const Provider = projection_impl.Provider;
pub const ExecutionIdentity = projection_impl.ExecutionIdentity;
pub const TaskWorkspaceTrust = projection_impl.TaskWorkspaceTrust;
pub const TaskCreateInput = projection_impl.TaskCreateInput;
pub const PermissionChoice = projection_impl.PermissionChoice;
pub const UiResponse = projection_impl.UiResponse;
pub const Configuration = projection_impl.Configuration;
pub const Workbench = projection_impl.Workbench;
pub const RunRef = projection_impl.RunRef;
pub const ChangeNotifier = projection_impl.ChangeNotifier;
pub const TransportFailureStage = projection_impl.TransportFailureStage;
pub const TransportFailureReport = projection_impl.TransportFailureReport;
pub const TransportFailureDecision = projection_impl.TransportFailureDecision;
pub const decideTransportFailure = projection_impl.decideTransportFailure;
pub const snapshot_schema_version = projection_impl.snapshot_schema_version;
