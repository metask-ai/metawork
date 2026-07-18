//! MetaWork's Agent execution boundary over the external AgentCore SDK.
//! Product projection and Renderer transport do not belong here.

const session_impl = @import("agent_session");

pub const EventEnvelope = session_impl.EventEnvelope;
pub const SessionState = session_impl.SessionState;
pub const HostCause = session_impl.HostCause;
pub const RunOutcome = session_impl.RunOutcome;
pub const WorkspaceTrust = session_impl.WorkspaceTrust;
pub const WorkspaceInput = session_impl.WorkspaceInput;
pub const EventReadyNotification = session_impl.EventReadyNotification;
pub const EventReadyNotifier = session_impl.EventReadyNotifier;
pub const SessionOpenOptions = session_impl.SessionOpenOptions;
pub const Limits = session_impl.Limits;
pub const SessionSnapshot = session_impl.SessionSnapshot;
pub const PendingUiRequest = session_impl.PendingUiRequest;
pub const Error = session_impl.Error;
pub const Runtime = session_impl.Runtime;
pub const Session = session_impl.Session;
