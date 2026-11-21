//! The Agent's contract surface: declarations, limits and codecs that cross
//! the Product boundary, with no path to the AgentCore ABI entry point.
//!
//! Everything reachable from here is pure data or a pure codec. None of it
//! calls `metask_agentcore_get_api`, so no compilation that stops at this
//! module needs the AgentCore static archive on its link line. The Session and
//! Runtime implementations that do reach the entry point live in
//! `agent_session` and import this module; a value decoded here therefore
//! keeps one type across both sides of that split.
//!
//! The file namespaces below exist so the implementation can keep naming these
//! declarations exactly as it did when they were its own files. Product-facing
//! flat re-exports stay in `src/agent.zig`.

pub const control = @import("session/control.zig");
pub const surface = @import("session/surface.zig");
pub const port = @import("session/port.zig");
pub const wire = @import("session/wire.zig");
pub const multimodal = @import("session/multimodal.zig");
pub const model_error = @import("session/model_error.zig");
pub const capabilities = @import("capabilities.zig");
pub const image_generation = @import("image_generation.zig");
pub const generate_image = @import("generate_image.zig");
pub const generate_video = @import("generate_video.zig");
pub const mcp_install = @import("mcp_install.zig");

// Namespaces the implementation keeps naming as its own files.
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const mcp_runtime = @import("agent_mcp_runtime");
const checkpoint = @import("agent_checkpoint");
const checkpoint_restore = @import("agent_checkpoint_restore");
const delivery = @import("agent_file_delivery");
const event_pump = @import("event_pump");
const model_binding = @import("agent_model_binding");
const image_http = @import("agent_http_transport");
const sdk = @import("metask_agentcore");
const core_identity = @import("agentcore_identity");
const agent_protocol = @import("agent_protocol");
const completion = @import("agent_completion");
const mcp_connector = @import("agent_mcp_connector");
const mcp_stdio = @import("agent_mcp_stdio");
const mcp_http = @import("agent_mcp_http");
const provider_probe = @import("agent_provider_probe");

// The ports. Everything that retains a live Runtime or Session crosses as one
// of these; `port.zig` states why.
pub const RuntimePort = port.RuntimePort;
pub const SessionPort = port.SessionPort;
pub const RunPort = port.RunPort;
pub const RunControl = port.RunControl;
pub const RunControlLease = port.RunControlLease;
pub const SessionRoute = port.SessionRoute;
pub const SessionRestoreRoute = port.SessionRestoreRoute;
pub const BeginRunOutcome = port.BeginRunOutcome;
pub const SessionRestoreInputs = port.SessionRestoreInputs;
pub const SkillRestoreInputs = port.SkillRestoreInputs;
pub const SkillRestoreBorrow = port.SkillRestoreBorrow;

// The declarations the Product names, each from the file that owns it.
pub const BeginRunFailure = surface.BeginRunFailure;
pub const CatalogAcquisition = catalog.Acquisition;
pub const CatalogHealth = catalog.Health;
pub const CatalogIssue = catalog.Issue;
pub const CatalogIssueCode = catalog.IssueCode;
pub const CatalogIssueKind = catalog.IssueKind;
pub const CatalogLease = catalog.Lease;
pub const CatalogProjection = catalog.Projection;
pub const CatalogQuery = catalog.Query;
pub const CatalogQueryTarget = catalog.QueryTarget;
pub const CatalogResourceReason = catalog.ResourceReason;
pub const CatalogSkill = catalog.Skill;
pub const CatalogSource = catalog.Source;
pub const CatalogSourceLifetime = catalog.SourceLifetime;
pub const CatalogSourceScope = catalog.SourceScope;
pub const CheckpointFailure = checkpoint.Failure;
pub const CheckpointLimits = checkpoint.Limits;
pub const CheckpointOutcome = checkpoint.Outcome;
pub const CheckpointRestoreReport = checkpoint_restore.Report;
pub const CheckpointSink = checkpoint.Sink;
pub const CheckpointSinkWriteResult = checkpoint.SinkWriteResult;
pub const CheckpointSourceReadResult = checkpoint_restore.SourceReadResult;
pub const CheckpointSuccess = checkpoint.Success;
pub const CloseOutcome = surface.CloseOutcome;
pub const CompactTerminalResult = control.CompactTerminalResult;
pub const Completion = completion.Completion;
pub const CompletionCancellation = completion.Cancellation;
pub const CompletionMessage = completion.Message;
pub const CompletionTransport = completion.Transport;
pub const ConversationBounds = surface.ConversationBounds;
pub const CoreEventKind = control.CoreEventKind;
pub const Error = surface.Error;
pub const ExternalInterruption = control.ExternalInterruption;
pub const FileDeliveryInput = delivery.Input;
pub const FileDeliveryInspection = delivery.Inspection;
pub const FileDeliveryFailure = delivery.Failure;
pub const FileDeliveryReceipt = delivery.Receipt;
pub const ImageGenerationCredentialReader = image_generation.CredentialReader;
pub const ImageGenerationOutput = image_generation.Output;
pub const ImageGenerationReceipt = image_generation.Receipt;
pub const ImageGenerationRunInput = surface.ImageGenerationRunInput;
pub const InputCounts = control.InputCounts;
pub const InputPart = multimodal.InputPart;
/// The MCP owners the execution link stands in for across a process
/// boundary, named here so the link, which imports only this module, reaches
/// them without the AgentCore archive.
pub const mcp = struct {
    pub const catalog = mcp_catalog;
    pub const runtime = mcp_runtime;
    pub const connector = mcp_connector;
};
pub const McpActivation = mcp_catalog.Activation;
pub const McpActivationOutcome = surface.McpActivationOutcome;
pub const McpActivationTool = mcp_catalog.ActivationTool;
pub const McpActivationUnavailableReason = surface.McpActivationUnavailableReason;
pub const McpCatalogServer = mcp_catalog.Server;
pub const McpConfigurationApplyOutcome = surface.McpConfigurationApplyOutcome;
pub const McpInstallRequest = mcp_install.InstallRequest;
pub const McpInstallationInput = mcp_install.Input;
pub const McpInstallationRequest = mcp_install.OwnedRequest;
pub const McpInstallationResult = mcp_install.Result;
pub const McpRestoreSelection = mcp_catalog.RestoreSelection;
pub const McpRuntimeInput = mcp_runtime.Input;
pub const McpSelection = mcp_catalog.Selection;
pub const McpServerAllowlist = mcp_catalog.ServerAllowlist;
pub const ModelBinding = model_binding.ModelBinding;
pub const ModelError = control.ModelError;
pub const ModelImageCapability = model_binding.ModelImageCapability;
pub const OwnedCoreEvent = event_pump.OwnedCoreEvent;
pub const PendingUiRequest = surface.PendingUiRequest;
pub const PermissionCallbackOutcome = sdk.protocol.PermissionCallbackOutcome;
pub const PermissionChoice = sdk.protocol.PermissionChoice;
pub const PermissionDecision = sdk.protocol.PermissionDecision;
pub const PermissionDecisionSource = sdk.protocol.PermissionDecisionSource;
pub const PermissionInteraction = surface.PermissionInteraction;
pub const PermissionMode = control.PermissionMode;
pub const PermissionModeUpdate = surface.PermissionModeUpdate;
pub const PermissionProvenance = sdk.protocol.PermissionProvenance;
pub const PermissionRequest = sdk.PermissionRequest;
pub const PermissionToolNamespace = sdk.protocol.PermissionToolNamespace;
pub const Protocol = agent_protocol.Protocol;
pub const RewindOutcome = surface.RewindOutcome;
pub const RewindRefusal = surface.RewindRefusal;
pub const RunInput = surface.RunInput;
pub const RunStatePhase = sdk.protocol.RunStatePhase;
pub const SessionDisposition = control.SessionDisposition;
pub const SessionOpenOptions = surface.SessionOpenOptions;
pub const SessionRestoreOptions = surface.SessionRestoreOptions;
pub const SessionState = control.SessionState;
pub const ShellPolicy = control.ShellPolicy;
pub const SkillPolicyInput = surface.SkillPolicyInput;
pub const Status = sdk.Status;
pub const StopReason = sdk.StopReason;
pub const TerminalReceipts = control.TerminalReceipts;
pub const TerminalResult = control.TerminalResult;
pub const TerminationSignal = control.TerminationSignal;
pub const TerminationRequestResult = control.TerminationRequestResult;
pub const VideoGenerationOutput = generate_video.Output;
pub const VideoGenerationRunInput = generate_video.Input;
pub const core_manifest_sha256 = core_identity.manifest_sha256;
pub const decodeCoreEvent = wire.decodeCoreEvent;
pub const decodePermissionRequest = wire.decodePermissionRequest;
pub const image_generation_limits = image_generation.production_limits;
pub const max_file_deliveries_per_run = delivery.max_receipts_per_run;
pub const max_generated_video_bytes = generate_video.max_file_bytes;
pub const max_submitted_input_bytes = surface.max_submitted_input_bytes;
pub const max_submitted_inputs = surface.max_submitted_inputs;
pub const multimodal_input_limits = multimodal.input_limits;
pub const parseMcpInstallRequest = mcp_install.parseInstallRequest;
pub const toolRouteDigest = control.toolRouteDigest;
pub const tool_route_digest_bytes = control.tool_route_digest_bytes;
pub const hostToolPermissionContext = capabilities.hostToolPermissionContext;

test {
    _ = control;
    _ = surface;
    _ = port;
    _ = wire;
    _ = multimodal;
    _ = model_error;
    _ = capabilities;
    _ = image_generation;
    _ = generate_image;
    _ = generate_video;
    _ = mcp_install;
}
