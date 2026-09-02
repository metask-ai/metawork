//! Scoped Application capabilities exposed by the Product Control owner.
//! The opaque context deliberately makes the owner type unreachable to
//! coordinators; these values are callback-scoped and must not enter jobs.

const std = @import("std");
const agent = @import("metawork_agent");
const account = @import("metawork_account_contract");
const execution_contract = @import("metawork_product_execution_contract");
const execution_ports = @import("product_execution_ports");
const product_schedule = @import("metawork_product_schedule");
const mcp = @import("metawork_product_mcp");
const mcp_contract = mcp.contract;

/// One committed Account revision delivered to Product Control. Attempt
/// identity is explicit so Product never infers operation lifetime from a
/// transient Account view such as `catalog_state`.
pub const AccountCommit = struct {
    fact: account.AccountFact,
    attempt_id: ?u64,
    attempt_terminal: bool,
    candidate: ?execution_contract.OwnedSourceCandidateTransfer = null,

    pub fn assertValid(self: AccountCommit) void {
        account.validateFact(self.fact) catch
            @panic("Account commit sink received an invalid Account fact");
        std.debug.assert(!self.attempt_terminal or self.attempt_id != null);
    }
};

/// Narrow no-fail sink for a committed Account revision and its optional
/// linear source candidate. Product Control owns every reconciliation decision
/// after this call; no result flows back into Account.
pub const AccountCommitSink = struct {
    context: *anyopaque,
    commit_fn: *const fn (*anyopaque, AccountCommit) void,

    pub fn commitNoFail(self: AccountCommitSink, commit: AccountCommit) void {
        commit.assertValid();
        self.commit_fn(self.context, commit);
    }
};

/// Application-facing capability for Execution lifecycle and effects. Product
/// Control keeps registry/default-selection transactions behind these calls.
pub const ExecutionManagement = struct {
    context: *anyopaque,
    start_model_connections_fn: *const fn (*anyopaque, []const u8, execution_ports.CredentialVault) anyerror!void,
    start_model_connections_unavailable_fn: *const fn (*anyopaque) void,
    stop_model_connections_fn: *const fn (*anyopaque) void,
    create_model_connection_fn: *const fn (*anyopaque, []const u8, execution_contract.ModelConnectionSpec, []const u8, []const u8) execution_contract.CommandResult,
    submit_model_connection_fn: *const fn (*anyopaque, execution_contract.ModelConnectionCommand) execution_contract.CommandResult,
    begin_model_connection_probe_fn: *const fn (*anyopaque, execution_contract.ModelConnectionTestCommand) execution_contract.Preparation,
    complete_model_connection_test_fn: *const fn (*anyopaque, execution_contract.ModelConnectionTestCommand, bool) execution_contract.CommandResult,
    pub fn startModelConnections(self: ExecutionManagement, directory: []const u8, vault: execution_ports.CredentialVault) anyerror!void {
        try self.start_model_connections_fn(self.context, directory, vault);
    }
    pub fn startModelConnectionsUnavailable(self: ExecutionManagement) void {
        self.start_model_connections_unavailable_fn(self.context);
    }
    pub fn stopModelConnections(self: ExecutionManagement) void {
        self.stop_model_connections_fn(self.context);
    }
    pub fn createModelConnectionWithCredential(self: ExecutionManagement, secret: []const u8, spec: execution_contract.ModelConnectionSpec, model_id: []const u8, display_name: []const u8) execution_contract.CommandResult {
        return self.create_model_connection_fn(self.context, secret, spec, model_id, display_name);
    }
    pub fn submitModelConnectionCommand(self: ExecutionManagement, command: execution_contract.ModelConnectionCommand) execution_contract.CommandResult {
        return self.submit_model_connection_fn(self.context, command);
    }
    pub fn beginModelConnectionProbe(self: ExecutionManagement, command: execution_contract.ModelConnectionTestCommand) execution_contract.Preparation {
        return self.begin_model_connection_probe_fn(self.context, command);
    }
    pub fn completeModelConnectionTest(self: ExecutionManagement, command: execution_contract.ModelConnectionTestCommand, succeeded: bool) execution_contract.CommandResult {
        return self.complete_model_connection_test_fn(self.context, command, succeeded);
    }
};

pub const AgentEventConsumer = struct {
    context: *anyopaque,
    drain_fn: *const fn (*anyopaque) anyerror!void,

    pub fn drainAgentEvents(self: AgentEventConsumer) anyerror!void {
        return self.drain_fn(self.context);
    }
};

pub const McpManagementPort = struct {
    context: *anyopaque,
    inspect_fn: *const fn (*anyopaque) ?mcp_contract.ManagementInspection,
    write_desired_fn: *const fn (*anyopaque, u64, []u8) anyerror![]const u8,
    begin_connection_test_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    complete_connection_test_fn: *const fn (*anyopaque, []const u8, mcp.McpConnectionTestOutcome, u32, u32) void,
    begin_apply_fn: *const fn (*anyopaque, u64) anyerror!void,
    complete_apply_fn: *const fn (*anyopaque, u64, *mcp_contract.Preparation, *mcp_contract.RuntimeManifest, ?*agent.McpActivation, ?*agent.McpSelection, bool) bool,
    fail_apply_fn: *const fn (*anyopaque, u64) void,
    authorization_operation_fn: *const fn (*anyopaque) ?mcp.McpAuthorizationOperationView,
    begin_authorization_fn: *const fn (*anyopaque, u64, []const u8) anyerror!?mcp.McpAuthorizationStart,
    advance_authorization_fn: *const fn (*anyopaque, []const u8, mcp.McpAuthorizationPhase) bool,
    finish_authorization_fn: *const fn (*anyopaque, []const u8) bool,
    write_approval_fn: *const fn (*anyopaque, u64, []const u8, []u8) anyerror![]const u8,
    approve_connection_fn: *const fn (*anyopaque, u64, mcp_contract.ApproveConnectionInput) anyerror!mcp_contract.ManagementOutcome,
    write_secret_prompt_fn: *const fn (*anyopaque, u64, []const u8, mcp.McpSecretCaptureTarget, []u8) anyerror![]const u8,
    capture_static_secret_fn: *const fn (*anyopaque, u64, mcp_contract.CaptureStaticSecretInput) anyerror!mcp_contract.ManagementOutcome,
    capture_oauth_client_secret_fn: *const fn (*anyopaque, u64, mcp_contract.CaptureOauthClientSecretInput) anyerror!mcp_contract.ManagementOutcome,
    begin_dynamic_registration_fn: *const fn (*anyopaque, mcp_contract.OauthConsentInput) anyerror!mcp.McpOauthOperationBeginOutcome,
    complete_dynamic_registration_fn: *const fn (*anyopaque, mcp_contract.CompleteDynamicRegistrationInput) anyerror!mcp_contract.ManagementOutcome,
    begin_code_exchange_fn: *const fn (*anyopaque, []const u8) anyerror!mcp.McpOauthCodeExchangeBeginOutcome,
    complete_code_exchange_fn: *const fn (*anyopaque, mcp_contract.CompleteCodeExchangeInput) anyerror!mcp_contract.ManagementOutcome,
    authorize_oauth_fn: *const fn (*anyopaque, mcp.McpOauthAuthorizationPlan) anyerror!mcp.McpOauthAuthorizationOutcome,
    clear_oauth_operation_fn: *const fn (*anyopaque, []const u8) anyerror!mcp_contract.ManagementOutcome,
    recover_oauth_operation_fn: *const fn (*anyopaque, []const u8) anyerror!mcp_contract.ManagementOutcome,

    pub fn inspectMcpDesiredConfiguration(self: McpManagementPort) ?mcp_contract.ManagementInspection {
        return self.inspect_fn(self.context);
    }
    pub fn writeMcpDesiredConfiguration(self: McpManagementPort, generation: u64, output: []u8) anyerror![]const u8 {
        return self.write_desired_fn(self.context, generation, output);
    }
    pub fn beginMcpConnectionTest(self: McpManagementPort, server_id: []const u8) anyerror!void {
        return self.begin_connection_test_fn(self.context, server_id);
    }
    pub fn completeMcpConnectionTest(self: McpManagementPort, server_id: []const u8, outcome: mcp.McpConnectionTestOutcome, tools: u32, issues: u32) void {
        self.complete_connection_test_fn(self.context, server_id, outcome, tools, issues);
    }
    pub fn beginMcpConfigurationApply(self: McpManagementPort, generation: u64) anyerror!void {
        return self.begin_apply_fn(self.context, generation);
    }
    pub fn completeMcpConfigurationApply(self: McpManagementPort, generation: u64, preparation: *mcp_contract.Preparation, manifest: *mcp_contract.RuntimeManifest, activation: ?*agent.McpActivation, selection: ?*agent.McpSelection, activation_failed: bool) bool {
        return self.complete_apply_fn(self.context, generation, preparation, manifest, activation, selection, activation_failed);
    }
    pub fn failMcpConfigurationApply(self: McpManagementPort, generation: u64) void {
        self.fail_apply_fn(self.context, generation);
    }
    pub fn mcpAuthorizationOperation(self: McpManagementPort) ?mcp.McpAuthorizationOperationView {
        return self.authorization_operation_fn(self.context);
    }
    pub fn beginMcpAuthorization(self: McpManagementPort, generation: u64, server_id: []const u8) anyerror!?mcp.McpAuthorizationStart {
        return self.begin_authorization_fn(self.context, generation, server_id);
    }
    pub fn advanceMcpAuthorization(self: McpManagementPort, operation_id: []const u8, phase: mcp.McpAuthorizationPhase) bool {
        return self.advance_authorization_fn(self.context, operation_id, phase);
    }
    pub fn finishMcpAuthorization(self: McpManagementPort, operation_id: []const u8) bool {
        return self.finish_authorization_fn(self.context, operation_id);
    }
    pub fn writeMcpConnectionApprovalDetails(self: McpManagementPort, generation: u64, server_id: []const u8, output: []u8) anyerror![]const u8 {
        return self.write_approval_fn(self.context, generation, server_id, output);
    }
    pub fn approveMcpConnection(self: McpManagementPort, generation: u64, input: mcp_contract.ApproveConnectionInput) anyerror!mcp_contract.ManagementOutcome {
        return self.approve_connection_fn(self.context, generation, input);
    }
    pub fn writeMcpSecretCapturePrompt(self: McpManagementPort, generation: u64, server_id: []const u8, target: mcp.McpSecretCaptureTarget, output: []u8) anyerror![]const u8 {
        return self.write_secret_prompt_fn(self.context, generation, server_id, target, output);
    }
    pub fn captureMcpStaticSecret(self: McpManagementPort, generation: u64, input: mcp_contract.CaptureStaticSecretInput) anyerror!mcp_contract.ManagementOutcome {
        return self.capture_static_secret_fn(self.context, generation, input);
    }
    pub fn captureMcpOauthClientSecret(self: McpManagementPort, generation: u64, input: mcp_contract.CaptureOauthClientSecretInput) anyerror!mcp_contract.ManagementOutcome {
        return self.capture_oauth_client_secret_fn(self.context, generation, input);
    }
    pub fn beginMcpOauthDynamicRegistration(self: McpManagementPort, input: mcp_contract.OauthConsentInput) anyerror!mcp.McpOauthOperationBeginOutcome {
        return self.begin_dynamic_registration_fn(self.context, input);
    }
    pub fn completeMcpOauthDynamicRegistration(self: McpManagementPort, input: mcp_contract.CompleteDynamicRegistrationInput) anyerror!mcp_contract.ManagementOutcome {
        return self.complete_dynamic_registration_fn(self.context, input);
    }
    pub fn beginMcpOauthCodeExchange(self: McpManagementPort, server_id: []const u8) anyerror!mcp.McpOauthCodeExchangeBeginOutcome {
        return self.begin_code_exchange_fn(self.context, server_id);
    }
    pub fn completeMcpOauthCodeExchange(self: McpManagementPort, input: mcp_contract.CompleteCodeExchangeInput) anyerror!mcp_contract.ManagementOutcome {
        return self.complete_code_exchange_fn(self.context, input);
    }
    pub fn authorizeMcpOauth(self: McpManagementPort, plan: mcp.McpOauthAuthorizationPlan) anyerror!mcp.McpOauthAuthorizationOutcome {
        return self.authorize_oauth_fn(self.context, plan);
    }
    pub fn clearMcpOauthOperation(self: McpManagementPort, operation_id: []const u8) anyerror!mcp_contract.ManagementOutcome {
        return self.clear_oauth_operation_fn(self.context, operation_id);
    }
    pub fn recoverMcpOauthOperation(self: McpManagementPort, operation_id: []const u8) anyerror!mcp_contract.ManagementOutcome {
        return self.recover_oauth_operation_fn(self.context, operation_id);
    }
};

pub const McpOauthPort = struct {
    context: *anyopaque,
    next_expiry_fn: *const fn (*anyopaque) ?mcp.McpOauthExpiry,
    begin_refresh_fn: *const fn (*anyopaque, []const u8) anyerror!mcp.McpOauthRefreshBeginOutcome,
    complete_refresh_fn: *const fn (*anyopaque, mcp_contract.CompleteRefreshInput, mcp.McpOauthRuntimeCommit) anyerror!mcp_contract.ManagementOutcome,
    block_admission_fn: *const fn (*anyopaque) void,
    require_reauthorization_fn: *const fn (*anyopaque, mcp.McpRuntimeAuthorizationFailure) anyerror!mcp.McpRuntimeAuthorizationFailureOutcome,
    clear_operation_fn: *const fn (*anyopaque, []const u8) anyerror!mcp_contract.ManagementOutcome,
    recover_operation_fn: *const fn (*anyopaque, []const u8) anyerror!mcp_contract.ManagementOutcome,

    pub fn nextMcpOauthExpiry(self: McpOauthPort) ?mcp.McpOauthExpiry {
        return self.next_expiry_fn(self.context);
    }
    pub fn beginMcpOauthRefresh(self: McpOauthPort, server_id: []const u8) anyerror!mcp.McpOauthRefreshBeginOutcome {
        return self.begin_refresh_fn(self.context, server_id);
    }
    pub fn completeMcpOauthRefresh(self: McpOauthPort, input: mcp_contract.CompleteRefreshInput, commit: mcp.McpOauthRuntimeCommit) anyerror!mcp_contract.ManagementOutcome {
        return self.complete_refresh_fn(self.context, input, commit);
    }
    pub fn blockMcpAdmissionAfterRuntimeAuthFailure(self: McpOauthPort) void {
        self.block_admission_fn(self.context);
    }
    pub fn requireMcpOauthReauthorization(self: McpOauthPort, failure: mcp.McpRuntimeAuthorizationFailure) anyerror!mcp.McpRuntimeAuthorizationFailureOutcome {
        return self.require_reauthorization_fn(self.context, failure);
    }
    pub fn clearMcpOauthOperation(self: McpOauthPort, operation_id: []const u8) anyerror!mcp_contract.ManagementOutcome {
        return self.clear_operation_fn(self.context, operation_id);
    }
    pub fn recoverMcpOauthOperation(self: McpOauthPort, operation_id: []const u8) anyerror!mcp_contract.ManagementOutcome {
        return self.recover_operation_fn(self.context, operation_id);
    }
};

pub const ScheduleHost = struct {
    context: *anyopaque,
    set_background_available_fn: *const fn (*anyopaque, bool) void,
    has_enabled_fn: *const fn (*anyopaque) bool,

    pub fn setScheduleBackgroundAvailableNoFail(self: ScheduleHost, available: bool) void {
        self.set_background_available_fn(self.context, available);
    }
    pub fn hasEnabledScheduledTasks(self: ScheduleHost) bool {
        return self.has_enabled_fn(self.context);
    }
};

pub const ScheduleNotificationKind = product_schedule.NotificationKind;
pub const ScheduleNotification = product_schedule.Notification;
