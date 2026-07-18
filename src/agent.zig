//! MetaWork's Agent execution boundary over the external AgentCore SDK.
//! Product projection and Renderer transport do not belong here.

const session_impl = @import("agent_session");

pub const OwnedCoreEvent = session_impl.OwnedCoreEvent;
pub const Status = session_impl.Status;
pub const StopReason = session_impl.StopReason;
pub const UiRequest = session_impl.UiRequest;
pub const UiResponse = session_impl.UiResponse;
pub const PermissionChoice = session_impl.PermissionChoice;
pub const ParsedUiRequest = session_impl.ParsedUiRequest;
pub const decodeUiRequest = session_impl.decodeUiRequest;
pub const decodeCoreEvent = session_impl.decodeCoreEvent;
pub const SessionState = session_impl.SessionState;
pub const ExternalInterruption = session_impl.ExternalInterruption;
pub const CallbackFailure = session_impl.CallbackFailure;
pub const EventPumpFailure = session_impl.EventPumpFailure;
pub const EventConsumerNotificationFailure = session_impl.EventConsumerNotificationFailure;
pub const TerminationSignal = session_impl.TerminationSignal;
pub const TerminalFailure = session_impl.TerminalFailure;
pub const SessionDisposition = session_impl.SessionDisposition;
pub const TerminalResult = session_impl.TerminalResult;
pub const TerminationRequestResult = session_impl.TerminationRequestResult;
pub const RunControl = session_impl.RunControl;
pub const RunControlLease = session_impl.RunControlLease;
pub const Run = session_impl.Run;
pub const WorkspaceTrust = session_impl.WorkspaceTrust;
pub const WorkspaceInput = session_impl.WorkspaceInput;
pub const ProviderKind = session_impl.ProviderKind;
pub const PermissionMode = session_impl.PermissionMode;
pub const ShellPolicy = session_impl.ShellPolicy;
pub const EventReadyNotification = session_impl.EventReadyNotification;
pub const EventReadyNotifier = session_impl.EventReadyNotifier;
pub const SessionOpenOptions = session_impl.SessionOpenOptions;
pub const Limits = session_impl.Limits;
pub const SessionSnapshot = session_impl.SessionSnapshot;
pub const PendingUiRequest = session_impl.PendingUiRequest;
pub const Error = session_impl.Error;
pub const Runtime = session_impl.Runtime;
pub const Session = session_impl.Session;
