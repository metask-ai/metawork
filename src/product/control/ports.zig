//! Scoped Application capabilities exposed by the Product Control owner.
//! The opaque context deliberately makes the owner type unreachable to
//! coordinators; these values are callback-scoped and must not enter jobs.

const std = @import("std");
const agent = @import("metawork_agent");
const account = @import("metawork_account_contract");
const models_contract = @import("metawork_product_models_contract");
const models_ports = @import("product_models_ports");
const product_schedule = @import("metawork_product_schedule");
const product_task = @import("metawork_product_task");
const workspace = @import("metawork_product_workspace");
const mcp = @import("metawork_product_mcp");
const mcp_contract = mcp.contract;

/// One committed Account revision delivered to Product Control. Attempt
/// identity remains explicit for Account command lifecycle observation; model
/// availability is owned and delivered independently by Models.
pub const AccountCommit = struct {
    fact: account.AccountFact,
    attempt_id: ?u64,
    attempt_terminal: bool,

    pub fn assertValid(self: AccountCommit) void {
        account.validateFact(self.fact) catch
            @panic("Account commit sink received an invalid Account fact");
        std.debug.assert(!self.attempt_terminal or self.attempt_id != null);
    }
};

/// Narrow no-fail sink for a committed Account revision. No model catalog,
/// selection, source candidate, or credential crosses this identity boundary.
pub const AccountCommitSink = struct {
    context: *anyopaque,
    commit_fn: *const fn (*anyopaque, AccountCommit) void,

    pub fn commitNoFail(self: AccountCommitSink, commit: AccountCommit) void {
        commit.assertValid();
        self.commit_fn(self.context, commit);
    }
};

/// Application-facing capability for Models lifecycle and effects. Product
/// Control keeps registry/default-selection transactions behind these calls.
pub const ModelsManagement = struct {
    context: *anyopaque,
    prepare_image_candidate_fn: *const fn (*anyopaque, models_contract.ImagePreparationInput) models_contract.ImagePreparation,
    start_custom_providers_fn: *const fn (*anyopaque, []const u8, models_ports.CredentialVault) anyerror!void,
    start_custom_providers_unavailable_fn: *const fn (*anyopaque) void,
    stop_custom_providers_fn: *const fn (*anyopaque) void,
    reset_model_store_fn: *const fn (*anyopaque, u64) models_contract.CommandResult,
    create_custom_provider_fn: *const fn (*anyopaque, []const u8, models_contract.CustomProviderSpec) models_contract.CommandResult,
    create_builtin_provider_fn: *const fn (*anyopaque, []const u8, models_contract.BuiltinProviderId, []const u8) models_contract.CommandResult,
    update_builtin_provider_base_url_fn: *const fn (*anyopaque, models_contract.CustomProviderSelectionCommand, []const u8) models_contract.CommandResult,
    replace_custom_provider_credential_fn: *const fn (*anyopaque, []const u8, models_contract.CustomProviderSelectionCommand) models_contract.CommandResult,
    submit_custom_provider_fn: *const fn (*anyopaque, models_contract.CustomProviderCommand) models_contract.CommandResult,
    begin_custom_provider_probe_fn: *const fn (*anyopaque, models_contract.CustomModelTestCommand) models_contract.Preparation,
    complete_custom_model_test_fn: *const fn (*anyopaque, models_contract.CustomModelTestCommand, bool) models_contract.CommandResult,
    prepare_metask_catalog_refresh_fn: *const fn (*anyopaque, []const u8, u64) models_contract.CatalogRefreshPrepareResult,
    complete_metask_catalog_refresh_fn: *const fn (*anyopaque, u64, u64, *models_ports.OwnedCatalogCompletion) models_contract.ModelsError,
    fail_metask_catalog_refresh_fn: *const fn (*anyopaque, u64, u64, models_contract.ModelsError, []const u8) void,
    metask_authorization_unavailable_fn: *const fn (*anyopaque) void,
    pub fn prepareImageCandidate(self: ModelsManagement, input: models_contract.ImagePreparationInput) models_contract.ImagePreparation {
        return self.prepare_image_candidate_fn(self.context, input);
    }
    pub fn startCustomProviders(self: ModelsManagement, directory: []const u8, vault: models_ports.CredentialVault) anyerror!void {
        try self.start_custom_providers_fn(self.context, directory, vault);
    }
    pub fn startCustomProvidersUnavailable(self: ModelsManagement) void {
        self.start_custom_providers_unavailable_fn(self.context);
    }
    pub fn stopCustomProviders(self: ModelsManagement) void {
        self.stop_custom_providers_fn(self.context);
    }
    pub fn resetModelStore(self: ModelsManagement, expected_revision: u64) models_contract.CommandResult {
        return self.reset_model_store_fn(self.context, expected_revision);
    }
    pub fn createCustomProviderWithCredential(self: ModelsManagement, secret: []const u8, spec: models_contract.CustomProviderSpec) models_contract.CommandResult {
        return self.create_custom_provider_fn(self.context, secret, spec);
    }
    pub fn createBuiltinProviderWithCredential(self: ModelsManagement, secret: []const u8, provider_id: models_contract.BuiltinProviderId, base_url: []const u8) models_contract.CommandResult {
        return self.create_builtin_provider_fn(self.context, secret, provider_id, base_url);
    }
    pub fn updateBuiltinProviderBaseUrl(self: ModelsManagement, selection: models_contract.CustomProviderSelectionCommand, base_url: []const u8) models_contract.CommandResult {
        return self.update_builtin_provider_base_url_fn(self.context, selection, base_url);
    }
    pub fn replaceCustomProviderCredential(self: ModelsManagement, secret: []const u8, selection: models_contract.CustomProviderSelectionCommand) models_contract.CommandResult {
        return self.replace_custom_provider_credential_fn(self.context, secret, selection);
    }
    pub fn submitCustomProviderCommand(self: ModelsManagement, command: models_contract.CustomProviderCommand) models_contract.CommandResult {
        return self.submit_custom_provider_fn(self.context, command);
    }
    pub fn beginCustomProviderProbe(self: ModelsManagement, command: models_contract.CustomModelTestCommand) models_contract.Preparation {
        return self.begin_custom_provider_probe_fn(self.context, command);
    }
    pub fn completeCustomModelTest(self: ModelsManagement, command: models_contract.CustomModelTestCommand, succeeded: bool) models_contract.CommandResult {
        return self.complete_custom_model_test_fn(self.context, command, succeeded);
    }
    pub fn prepareMetaskCatalogRefresh(self: ModelsManagement, principal_ref: []const u8, authorization_generation: u64) models_contract.CatalogRefreshPrepareResult {
        return self.prepare_metask_catalog_refresh_fn(self.context, principal_ref, authorization_generation);
    }
    pub fn completeMetaskCatalogRefresh(self: ModelsManagement, attempt_id: u64, authorization_generation: u64, completion: *models_ports.OwnedCatalogCompletion) models_contract.ModelsError {
        return self.complete_metask_catalog_refresh_fn(self.context, attempt_id, authorization_generation, completion);
    }
    pub fn failMetaskCatalogRefresh(self: ModelsManagement, attempt_id: u64, authorization_generation: u64, error_code: models_contract.ModelsError, safe_diagnostic: []const u8) void {
        self.fail_metask_catalog_refresh_fn(self.context, attempt_id, authorization_generation, error_code, safe_diagnostic);
    }
    pub fn setMetaskAuthorizationUnavailable(self: ModelsManagement) void {
        self.metask_authorization_unavailable_fn(self.context);
    }
};

/// Main-thread admission call only. The returned owned value contains no
/// mutable aggregate pointer; only the scoped effect owner is retained.
pub const ImageRunPreparation = struct {
    context: *anyopaque,
    prepare_fn: *const fn (*anyopaque, workspace.TaskAuthority) ?product_task.OwnedImageExecution,

    pub fn prepare(self: ImageRunPreparation, authority: workspace.TaskAuthority) ?product_task.OwnedImageExecution {
        return self.prepare_fn(self.context, authority);
    }
};

/// Main-thread preparation only; the result retains one frozen file effect.
pub const FileDeliveryPreparation = struct {
    context: *anyopaque,
    prepare_fn: *const fn (*anyopaque, workspace.TaskAuthority) ?product_task.OwnedFileDelivery,

    pub fn prepare(self: FileDeliveryPreparation, authority: workspace.TaskAuthority) ?product_task.OwnedFileDelivery {
        return self.prepare_fn(self.context, authority);
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
    validate_secret_capture_fn: *const fn (*anyopaque, u64, []const u8, mcp.McpSecretCaptureTarget) anyerror!void,
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
    pub fn validateMcpSecretCapture(self: McpManagementPort, generation: u64, server_id: []const u8, target: mcp.McpSecretCaptureTarget) anyerror!void {
        return self.validate_secret_capture_fn(self.context, generation, server_id, target);
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

    pub fn setScheduleBackgroundAvailableNoFail(self: ScheduleHost, available: bool) void {
        self.set_background_available_fn(self.context, available);
    }
};

pub const ScheduleNotificationKind = product_schedule.NotificationKind;
pub const ScheduleNotification = product_schedule.Notification;

/// Main-loop effect for a currently authorized, hash-verified Output only.
pub const OutputFileReveal = struct {
    context: *anyopaque,
    reveal_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
};

/// Callback-scoped source identity. The Application copies this and the picker
/// selection into an owned effect before returning; no Product pointer escapes.
pub const OutputFileSaveInput = struct {
    workspace_root: []const u8,
    relative_path: []const u8,
    size_bytes: u64,
    sha256: [32]u8,
};
pub const OutputFileSave = struct {
    context: *anyopaque,
    prepare_fn: *const fn (*anyopaque, OutputFileSaveInput) anyerror!?OwnedOutputSave,
};
/// Owned exception to the borrowed coordination ports above. Stage, publish
/// and discard run only on the worker; release runs after quiescence on main.
/// Stage/publish must close and discard resources on failure, or report cleanup.
pub const OwnedOutputSave = struct {
    context: *anyopaque,
    stage_fn: *const fn (*anyopaque, *const std.atomic.Value(bool)) anyerror!void,
    publish_fn: *const fn (*anyopaque) anyerror!void,
    discard_fn: *const fn (*anyopaque) anyerror!void,
    release_fn: *const fn (*anyopaque) void,
    pub fn deinit(self: *OwnedOutputSave) void {
        self.release_fn(self.context);
        self.* = undefined;
    }
};
