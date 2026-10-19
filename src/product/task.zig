//! Live Product Task aggregate and its externally required storage leaves.

const builtin = @import("builtin");
const agent_session = @import("product_task_agent_session");
const runtime = @import("product_task_runtime");
const state = @import("product_task_state");
const policy = @import("product_task_policy");
const execution = @import("product_task_execution");
const attachment = @import("product_task_attachment");
const deletion = @import("product_task_deletion");
const view = @import("product_task_view");
const execution_binding = @import("product_task_execution_binding");

pub const Runtime = runtime.Runtime;
pub const CreateTaskInput = runtime.CreateTaskInput;
pub const PreparedCreate = runtime.PreparedCreate;
pub const PreparedModelIntent = runtime.PreparedModelIntent;
pub const ModelIntentError = runtime.ModelIntentError;
pub const PreparedRun = runtime.PreparedRun;
pub const PreparedCompact = runtime.PreparedCompact;
pub const PreparedUiResponse = runtime.PreparedUiResponse;
pub const PreparedPermissionReview = runtime.PreparedPermissionReview;
pub const PermissionReviewIdentity = runtime.PermissionReviewIdentity;
pub const PermissionReviewEffects = runtime.PermissionReviewEffects;
pub const PermissionReviewOutcome = runtime.PermissionReviewOutcome;
pub const TerminalSummary = runtime.TerminalSummary;
pub const RunInput = runtime.RunInput;
pub const OwnedImageExecution = state.OwnedImageExecution;
pub const RunError = runtime.RunError;
pub const MultimodalAttachment = runtime.MultimodalAttachment;
pub const PermissionChoice = runtime.PermissionChoice;
pub const UiResponse = runtime.UiResponse;
pub const FailureRecord = runtime.FailureRecord;
pub const FileReference = runtime.FileReference;
pub const FileChangeDiffAdmission = runtime.FileChangeDiffAdmission;
pub const ProjectionAuthorityQuery = runtime.ProjectionAuthorityQuery;
pub const ProjectionAuthority = runtime.ProjectionAuthority;
pub const ProjectionEffects = runtime.ProjectionEffects;
pub const RecoveryAdmissionEffects = runtime.RecoveryAdmissionEffects;
pub const RecoveryWorkspaceTrust = runtime.RecoveryWorkspaceTrust;
pub const ProjectedText = runtime.ProjectedText;
pub const TextProjection = runtime.TextProjection;
pub const DurableCommit = runtime.DurableCommit;
pub const CheckpointEffects = runtime.CheckpointEffects;
pub const SessionReleaseOutcome = runtime.SessionReleaseOutcome;
pub const DeletionEffects = runtime.DeletionEffects;
pub const OperationEffects = runtime.OperationEffects;
pub const WorkspaceOrderEffect = runtime.WorkspaceOrderEffect;
pub const RunClock = runtime.RunClock;
pub const ReleaseEffects = runtime.ReleaseEffects;
pub const RecoveryAuthorityQuery = runtime.RecoveryAuthorityQuery;
pub const RestoreCapabilities = runtime.RestoreCapabilities;
pub const ModelIntentAuthority = runtime.ModelIntentAuthority;
pub const RecoveryExternalAuthority = runtime.RecoveryExternalAuthority;
pub const RecoveryEffects = runtime.RecoveryEffects;
pub const LifecycleEffects = runtime.LifecycleEffects;

pub const Protocol = state.Protocol;
pub const PermissionProfile = state.PermissionProfile;
pub const ApprovalMode = state.ApprovalMode;
pub const approval_capacity = runtime.approval_job.max_operations;
pub const ApprovalExecutor = runtime.ExecutorPort;
pub const ApprovalNotifier = @FieldType(runtime.WorkerResources, "notifier");
pub const ApprovalFailureReason = state.ApprovalFailureReason;
pub const PermissionInteraction = state.PermissionInteraction;
pub const McpAuthorityAtCreation = attachment.McpAuthorityAtCreation;
pub const RunOutcome = state.RunOutcome;
pub const FileReferencePosition = state.FileReferencePositionView;
pub const FileReferenceRange = state.FileReferenceRangeView;
pub const ProjectionError = view.Error;
pub const ProjectionText = view.TextProjection;
pub const writeInput = view.writeInput;
pub const writeSendInputResult = view.writeSendInputResult;
pub const ModelSelectionAvailability = view.ModelSelectionAvailability;
pub const history = @import("product_task_persistence");
pub const checkpoint_store = @import("product_task_checkpoint_store");
pub const file_change_store = @import("product_task_file_change_store");

/// Test-only lifecycle seam. Production consumers cannot obtain Task's
/// Session Binding implementation through the Product root.
pub const testing = if (builtin.is_test) struct {
    pub const SessionBinding = agent_session.Binding;
    pub const SessionBindingState = agent_session.BindingState;
    pub const agent_session_module = agent_session;
    pub const state_module = state;
    pub const policy_module = policy;
    pub const execution_module = execution;
    pub const execution_binding_module = execution_binding;
    pub const attachment_module = attachment;
    pub const deletion_module = deletion;
    pub const view_module = view;
} else struct {};

pub const SendInputResult = runtime.SendInputResult;
pub const SendInputReason = runtime.SendInputReason;
