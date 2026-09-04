//! Public surface of the Product Control-held Workspace aggregate.

const runtime_impl = @import("product_workspace_runtime");
const view_impl = @import("product_workspace_view");

pub const Runtime = runtime_impl.Runtime;
pub const Kind = runtime_impl.Kind;
pub const Authorization = runtime_impl.Authorization;
pub const RemovalFailure = runtime_impl.RemovalFailure;
pub const RemovalState = runtime_impl.RemovalState;
pub const Signals = runtime_impl.Signals;
pub const Facts = runtime_impl.Facts;
pub const Binding = runtime_impl.Binding;
pub const TaskAuthority = runtime_impl.TaskAuthority;
pub const RecoveryAuthority = runtime_impl.RecoveryAuthority;
pub const HistoryFact = runtime_impl.HistoryFact;
pub const RestoreFact = runtime_impl.RestoreFact;
pub const TrustInput = runtime_impl.TrustInput;
pub const TrustFact = runtime_impl.TrustFact;
pub const Storage = runtime_impl.Storage;
pub const StorageError = runtime_impl.StorageError;
pub const ProjectedText = runtime_impl.ProjectedText;
pub const OpenAuthority = runtime_impl.OpenAuthority;
pub const OpenPreparation = runtime_impl.OpenPreparation;
pub const RemovalPreparation = runtime_impl.RemovalPreparation;
pub const OrderPreparation = runtime_impl.OrderPreparation;
pub const RemovedAutomatic = runtime_impl.RemovedAutomatic;
pub const AutomaticAllocation = runtime_impl.AutomaticAllocation;
pub const Projection = view_impl.Projection;
pub const ViewProvider = view_impl.Provider;
pub const ViewError = view_impl.Error;
pub const copyProjections = view_impl.copyProjections;
pub const writeProjectionList = view_impl.writeProjectionList;
pub const AutomaticRoot = runtime_impl.AutomaticRoot;
pub const testing = runtime_impl.testing;
