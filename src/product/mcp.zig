//! Public surface of the live Product MCP aggregate.
//! State, policy, view derivation, and refresh-job mechanics are composed
//! behind Runtime rather than published for Workbench assembly.

const ports_module = @import("product_mcp_ports");
const runtime_module = @import("product_mcp_runtime");

/// Data-only configuration and persistence contract consumed by Application
/// adapters, Bridge DTO handling, and the Product MCP aggregate.
pub const contract = @import("product_mcp_configuration");

pub const Runtime = runtime_module.Runtime;
pub const Startup = runtime_module.Startup;
pub const Error = runtime_module.Error;
pub const Capabilities = runtime_module.Capabilities;
pub const ViewError = runtime_module.ViewError;
pub const TextProjection = runtime_module.TextProjection;
pub const writeProjection = runtime_module.writeProjection;

pub const Ports = ports_module.Ports;
pub const Job = ports_module.Job;
pub const Executor = ports_module.Executor;
pub const Catalog = ports_module.Catalog;
pub const CatalogError = ports_module.CatalogError;
pub const Timer = ports_module.Timer;
pub const Notifier = ports_module.Notifier;

pub const McpHostCapabilities = runtime_module.McpHostCapabilities;
pub const McpStartupConfiguration = runtime_module.McpStartupConfiguration;
pub const McpAdmissionBlockReason = runtime_module.McpAdmissionBlockReason;
pub const McpAdmissionReady = runtime_module.McpAdmissionReady;
pub const McpAdmissionAuthority = runtime_module.McpAdmissionAuthority;
pub const RecoveryMcpAuthority = runtime_module.RecoveryMcpAuthority;
pub const McpOauthRefreshBinding = runtime_module.McpOauthRefreshBinding;
pub const McpOauthRefreshBeginOutcome = runtime_module.McpOauthRefreshBeginOutcome;
pub const McpOauthAuthorizationPlan = runtime_module.McpOauthAuthorizationPlan;
pub const McpOauthAuthorizationBinding = runtime_module.McpOauthAuthorizationBinding;
pub const McpOauthAuthorizationOutcome = runtime_module.McpOauthAuthorizationOutcome;
pub const McpOauthOperationHandle = runtime_module.McpOauthOperationHandle;
pub const McpOauthCodeExchangeBinding = runtime_module.McpOauthCodeExchangeBinding;
pub const McpOauthOperationBeginOutcome = runtime_module.McpOauthOperationBeginOutcome;
pub const McpOauthCodeExchangeBeginOutcome = runtime_module.McpOauthCodeExchangeBeginOutcome;
pub const McpOauthExpiry = runtime_module.McpOauthExpiry;
pub const McpRuntimeAuthorizationFailure = runtime_module.McpRuntimeAuthorizationFailure;
pub const McpRuntimeAuthorizationFailureOutcome = runtime_module.McpRuntimeAuthorizationFailureOutcome;
pub const McpAuthorizationPhase = runtime_module.McpAuthorizationPhase;
pub const McpConnectionTestOutcome = runtime_module.McpConnectionTestOutcome;
pub const McpConfigurationApplyState = runtime_module.McpConfigurationApplyState;
pub const McpAuthorizationOperationView = runtime_module.McpAuthorizationOperationView;
pub const McpAuthorizationStart = runtime_module.McpAuthorizationStart;
pub const McpSecretCaptureTarget = runtime_module.McpSecretCaptureTarget;
pub const McpOauthRuntimeCommit = runtime_module.McpOauthRuntimeCommit;
pub const McpRefreshTimer = runtime_module.McpRefreshTimer;

/// Test-only kernel seam. Production consumers cannot obtain MCP state or a
/// refresh-job implementation through the Product root.
pub const testing = runtime_module.testing;
