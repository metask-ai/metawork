//! Product Account state machine.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");
const execution_contract = @import("metawork_product_execution_contract");

const AccountId = BoundedString(contract.Limits.account_id_bytes);
const DisplayName = BoundedString(contract.Limits.display_name_bytes);
const ApiKeyId = BoundedString(contract.Limits.api_key_id_bytes);
const ModelId = BoundedString(contract.Limits.model_id_bytes);
const SafeDiagnostic = BoundedString(contract.Limits.safe_diagnostic_bytes);

const SessionState = enum {
    restoring,
    signed_out,
    authorizing,
    authenticated,
    refreshing,
    shutting_down,
};

const SourceAuthority = enum {
    none,
    ready,
    recovery,
};

const OperationKind = enum {
    none,
    oauth_callback,
    token_exchange,
    loading_identity,
    loading_keys,
    selecting_key,
    loading_models,
    selecting_model,
    persisting,
    persisting_model,
    logging_out,
};

fn BoundedString(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn init(value: []const u8) contract.ValidationError!Self {
            var result: Self = .{};
            try result.set(value);
            return result;
        }

        fn set(self: *Self, value: []const u8) contract.ValidationError!void {
            if (value.len > capacity) return error.FieldTooLarge;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidEncoding;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn clear(self: *Self) void {
            self.len = 0;
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Effect = union(enum) {
    begin_oauth,
    refresh_token,
    load_identity,
    load_api_keys,
    load_models: ApiKeyId,
    prepare_source_candidate: ModelId,
    persist_source_preference: SourcePreference,
    persist_default_model: ModelId,
    cancel_attempt: u64,
    delete_credential,
    shutdown: ?u64,

    pub fn argument(self: *const Effect) ?[]const u8 {
        return switch (self.*) {
            .load_models => |*id| id.view(),
            .prepare_source_candidate, .persist_default_model => |*model| model.view(),
            .persist_source_preference => |*preference| preference.model.view(),
            else => null,
        };
    }
};

pub const SourcePreference = struct {
    model: ModelId,
    metask_source_generation: u64,
};

const AttemptKind = enum {
    none,
    login,
    refresh_token,
    catalog,
    catalog_refresh,
    activation,
    model_preference,
    logout,
};

const IdentityAttemptKind = enum { login, refresh_token };
const CatalogAttemptKind = enum { preference, refresh_only, activation };
const ModelPreferenceSource = enum { catalog, preference };
const PendingFacts = struct {
    api_key_id: ApiKeyId = .{},
    model: ModelId = .{},
    metask_source_generation: u64 = 0,
};
const CatalogAttempt = struct {
    attempt_id: u64,
    kind: CatalogAttemptKind = .preference,
    pending: PendingFacts = .{},
};

/// The single closed representation of an in-flight Account transaction.
/// Attempt ownership and operation phase cannot drift independently because
/// every legal combination is one union variant.
const Transaction = union(enum) {
    none,
    oauth_callback: u64,
    token_exchange: u64,
    loading_identity: struct {
        attempt_id: u64,
        kind: IdentityAttemptKind,
    },
    loading_keys: CatalogAttempt,
    selecting_key: CatalogAttempt,
    loading_models: CatalogAttempt,
    reloading_models: CatalogAttempt,
    selecting_model: CatalogAttempt,
    persisting_source: CatalogAttempt,
    persisting_model: struct {
        attempt_id: u64,
        source: ModelPreferenceSource,
        pending: PendingFacts,
    },
    logging_out: u64,

    fn operationKind(self: Transaction) OperationKind {
        return switch (self) {
            .none => .none,
            .oauth_callback => .oauth_callback,
            .token_exchange => .token_exchange,
            .loading_identity => .loading_identity,
            .loading_keys => .loading_keys,
            .selecting_key => .selecting_key,
            .loading_models => .loading_models,
            .reloading_models => .loading_models,
            .selecting_model => .selecting_model,
            .persisting_source => .persisting,
            .persisting_model => .persisting_model,
            .logging_out => .logging_out,
        };
    }

    fn attemptKind(self: Transaction) AttemptKind {
        return switch (self) {
            .none => .none,
            .oauth_callback => .login,
            .token_exchange => .refresh_token,
            .loading_identity => |value| switch (value.kind) {
                .login => .login,
                .refresh_token => .refresh_token,
            },
            .loading_keys,
            .selecting_key,
            .loading_models,
            .reloading_models,
            .selecting_model,
            .persisting_source,
            => |value| switch (value.kind) {
                .preference => .catalog,
                .refresh_only => .catalog_refresh,
                .activation => .activation,
            },
            .persisting_model => |value| switch (value.source) {
                .catalog => .catalog,
                .preference => .model_preference,
            },
            .logging_out => .logout,
        };
    }

    fn attemptId(self: Transaction) ?u64 {
        return switch (self) {
            .none => null,
            .loading_identity => |value| value.attempt_id,
            .persisting_model => |value| value.attempt_id,
            .loading_keys,
            .selecting_key,
            .loading_models,
            .reloading_models,
            .selecting_model,
            .persisting_source,
            => |value| value.attempt_id,
            .oauth_callback,
            .token_exchange,
            .logging_out,
            => |attempt_id| attempt_id,
        };
    }

    fn pending(self: *const Transaction) ?*const PendingFacts {
        return switch (self.*) {
            .loading_keys,
            .selecting_key,
            .loading_models,
            .reloading_models,
            .selecting_model,
            .persisting_source,
            => |*value| &value.pending,
            .persisting_model => |*value| &value.pending,
            else => null,
        };
    }

    fn pendingMut(self: *Transaction) ?*PendingFacts {
        return switch (self.*) {
            .loading_keys,
            .selecting_key,
            .loading_models,
            .reloading_models,
            .selecting_model,
            .persisting_source,
            => |*value| &value.pending,
            .persisting_model => |*value| &value.pending,
            else => null,
        };
    }
};

pub const EffectSink = struct {
    context: *anyopaque,
    submit_fn: *const fn (context: *anyopaque, attempt_id: ?u64, effect: Effect) bool,

    /// This is an enqueue-only call. A successful enqueue may publish a worker
    /// completion, but the App main loop cannot consume that completion until
    /// the current prepared transition has committed. On `false`, callers must
    /// discard the prepared transition without committing it.
    pub fn submit(self: EffectSink, attempt_id: ?u64, effect: Effect) bool {
        return self.submit_fn(self.context, attempt_id, effect);
    }
};

const CommittedState = struct {
    session_state: SessionState = .restoring,
    source_authority: SourceAuthority = .none,
    transaction: Transaction = .none,
    account_id: AccountId = .{},
    display_name: DisplayName = .{},
    selected_api_key_id: ApiKeyId = .{},
    selected_model: ModelId = .{},
    error_code: contract.ErrorCode = .none,
    safe_diagnostic: SafeDiagnostic = .{},
    catalog_generation: u64 = 0,
    metask_source_generation: u64 = 0,
    next_attempt_id: u64 = 1,

    fn operation(self: *const CommittedState) OperationKind {
        return self.transaction.operationKind();
    }

    fn attemptKind(self: *const CommittedState) AttemptKind {
        return self.transaction.attemptKind();
    }

    fn activeAttempt(self: *const CommittedState) ?u64 {
        return self.transaction.attemptId();
    }

    fn clearTransaction(self: *CommittedState) void {
        self.transaction = .none;
    }

    fn pendingApiKeyId(self: *const CommittedState) []const u8 {
        const pending = self.transaction.pending() orelse return "";
        return pending.api_key_id.view();
    }

    fn pendingModel(self: *const CommittedState) []const u8 {
        const pending = self.transaction.pending() orelse return "";
        return pending.model.view();
    }

    fn pendingSourceGeneration(self: *const CommittedState) u64 {
        const pending = self.transaction.pending() orelse return 0;
        return pending.metask_source_generation;
    }

    fn setPendingApiKeyId(
        self: *CommittedState,
        value: []const u8,
    ) contract.ValidationError!void {
        const pending = self.transaction.pendingMut() orelse
            return error.InconsistentState;
        try pending.api_key_id.set(value);
    }

    fn setPendingModel(
        self: *CommittedState,
        value: []const u8,
    ) contract.ValidationError!void {
        const pending = self.transaction.pendingMut() orelse
            return error.InconsistentState;
        try pending.model.set(value);
    }

    fn setPendingSourceGeneration(
        self: *CommittedState,
        value: u64,
    ) contract.ValidationError!void {
        if (value == 0) return error.InconsistentState;
        const pending = self.transaction.pendingMut() orelse
            return error.InconsistentState;
        pending.metask_source_generation = value;
    }

    fn clearPendingApiKeyId(self: *CommittedState) void {
        const pending = self.transaction.pendingMut() orelse return;
        pending.api_key_id.clear();
    }

    fn clearPendingModel(self: *CommittedState) void {
        const pending = self.transaction.pendingMut() orelse return;
        pending.model.clear();
        pending.metask_source_generation = 0;
    }

    fn markReloadingModels(self: *CommittedState) void {
        const value = switch (self.transaction) {
            .loading_models => |catalog| catalog,
            .reloading_models => |catalog| catalog,
            else => unreachable,
        };
        self.transaction = .{ .reloading_models = value };
    }

    fn reloadingModels(self: *const CommittedState) bool {
        return self.transaction == .reloading_models;
    }

    fn catalogAttempt(
        self: *const CommittedState,
        attempt_id: u64,
        kind: CatalogAttemptKind,
    ) CatalogAttempt {
        std.debug.assert(attempt_id != 0);
        const pending: PendingFacts = if (self.transaction.pending()) |value|
            value.*
        else
            .{};
        return .{
            .attempt_id = attempt_id,
            .kind = kind,
            .pending = pending,
        };
    }

    fn modelPreferenceAttempt(
        self: *const CommittedState,
        attempt_id: u64,
        source: ModelPreferenceSource,
    ) Transaction {
        std.debug.assert(attempt_id != 0);
        return .{ .persisting_model = .{
            .attempt_id = attempt_id,
            .source = source,
            .pending = if (self.transaction.pending()) |value| value.* else .{},
        } };
    }

    fn view(self: *const CommittedState) contract.AccountView {
        const state: contract.AccountState = switch (self.session_state) {
            .restoring => .checking,
            .signed_out, .shutting_down => .signed_out,
            .authorizing => .authorizing,
            .authenticated => .authenticated,
            .refreshing => if (self.account_id.len == 0)
                .checking
            else
                .authenticated,
        };
        const catalog_state: contract.CatalogState = if (state != .authenticated)
            .unavailable
        else switch (self.operation()) {
            .selecting_key, .selecting_model => .choosing,
            .loading_keys, .loading_models, .persisting, .persisting_model => .loading,
            .none, .token_exchange, .loading_identity => if (self.source_authority == .ready)
                .ready
            else if (self.error_code != .none)
                .failed
            else
                .loading,
            .oauth_callback, .logging_out => .unavailable,
        };
        const publish_account = state == .authenticated;
        return .{
            .state = state,
            .catalog_state = catalog_state,
            .can_cancel = self.canCancelOperation(),
            .account_id = if (publish_account) self.account_id.view() else "",
            .display_name = if (publish_account) self.display_name.view() else "",
            .selected_api_key_id = if (publish_account) self.selected_api_key_id.view() else "",
            .selected_model = if (publish_account) self.selected_model.view() else "",
            .candidate_api_key_id = if (publish_account) self.pendingApiKeyId() else "",
            .candidate_model = if (publish_account) self.pendingModel() else "",
            .model_catalog_api_key_id = "",
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
        };
    }

    fn clearError(self: *CommittedState) void {
        self.error_code = .none;
        self.safe_diagnostic.clear();
    }

    fn canCancelOperation(self: *const CommittedState) bool {
        if (self.activeAttempt() == null) return false;
        return switch (self.attemptKind()) {
            .login => self.session_state == .authorizing and
                self.operation() == .oauth_callback,
            .catalog, .catalog_refresh, .activation => self.session_state == .authenticated and switch (self.operation()) {
                .loading_keys, .selecting_key, .loading_models, .selecting_model => true,
                else => false,
            },
            .refresh_token, .model_preference, .logout, .none => false,
        };
    }
};

pub const Account = struct {
    state: CommittedState = .{},

    pub fn initRestoring() Account {
        return .{};
    }

    fn initSignedOutForTest() Account {
        return .{
            .state = .{ .session_state = .signed_out },
        };
    }

    pub fn view(self: *const Account) contract.AccountView {
        return self.state.view();
    }

    pub fn activeAttempt(self: *const Account) ?u64 {
        return self.state.activeAttempt();
    }

    pub fn refreshInFlight(self: *const Account) bool {
        return self.state.attemptKind() == .refresh_token;
    }

    pub fn catalogAttemptActive(self: *const Account) bool {
        return self.state.attemptKind() == .catalog or
            self.state.attemptKind() == .catalog_refresh or
            self.state.attemptKind() == .activation;
    }

    pub fn recoveryCatalogRefreshActive(self: *const Account) bool {
        return self.state.source_authority == .recovery and
            self.state.attemptKind() == .catalog_refresh;
    }

    /// True while a catalog attempt is loading models for a selected key.
    /// A failure here parks back in choosing with the loaded key list kept
    /// (see prepareFailure), so the owner must also keep the session that
    /// holds those keys' secrets — resetting it would make every re-pick
    /// dispatch a model load that cannot resolve its key.
    pub fn catalogModelsLoadInFlight(self: *const Account) bool {
        return (self.state.attemptKind() == .catalog or
            self.state.attemptKind() == .activation) and
            self.state.operation() == .loading_models;
    }

    pub fn credentialValidationInFlight(self: *const Account) bool {
        return self.state.attemptKind() == .login or
            self.state.attemptKind() == .refresh_token;
    }

    pub fn currentIdentity(self: *const Account) ?AccountIdentity {
        if (self.state.account_id.len == 0) return null;
        return .{
            .account_id = self.state.account_id,
            .display_name = self.state.display_name,
        };
    }

    pub fn prepareCommand(
        self: *const Account,
        command: contract.AccountCommand,
    ) PrepareResult {
        contract.validateCommand(command) catch
            return .{ .rejected = .invalid_command };
        if (self.state.session_state == .shutting_down)
            return .{ .rejected = .invalid_state };

        return switch (command) {
            .begin_login => self.prepareBeginLogin(),
            .cancel_operation => self.prepareCancel(),
            .refresh_catalog => self.prepareRefreshCatalog(),
            .select_api_key => |selection| self.prepareSelectApiKey(
                selection.selection_id,
            ),
            .select_model => |selection| self.prepareSelectModel(
                selection.selection_id,
            ),
            .resolve_metask_source => self.prepareResolveMetaskSource(),
            .logout => self.prepareLogout(),
        };
    }

    pub fn prepareRestore(
        self: *const Account,
        restore: *RestoreResult,
    ) PrepareResult {
        if (self.state.session_state != .restoring) {
            restore.deinit();
            return .{ .rejected = .invalid_state };
        }
        return switch (restore.*) {
            .signed_out => blk: {
                var next = self.state;
                next.session_state = .signed_out;
                next.clearError();
                break :blk transitionNoAttempt(next, .restored);
            },
            .refresh_only => blk: {
                var next = self.state;
                next.clearError();
                break :blk transitionNoAttempt(next, .restored);
            },
        };
    }

    pub fn prepareSignedOutRestoreFailure(
        self: *const Account,
        failure: WorkerFailure,
    ) PrepareResult {
        if (self.state.session_state != .restoring)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = .signed_out;
        next.error_code = if (failure.error_code == .none)
            .credential_store_read_failed
        else
            failure.error_code;
        next.safe_diagnostic = failure.safe_diagnostic;
        return transitionNoAttempt(next, .operation_failed);
    }

    pub fn pendingSourceGeneration(self: *const Account) u64 {
        return self.state.pendingSourceGeneration();
    }

    pub fn sourceGeneration(self: *const Account) u64 {
        return self.state.metask_source_generation;
    }

    /// The preference store was re-observed after an indeterminate execution
    /// preference write and contained neither the old nor candidate value.
    /// Preserve an existing execution as recovery-only; a first install has
    /// no safe authority to preserve and closes the Account fail-closed.
    pub fn prepareSourcePreferencePersistenceInvalid(
        self: *const Account,
    ) PrepareResult {
        if (self.state.attemptKind() != .catalog or
            self.state.operation() != .persisting or
            self.state.activeAttempt() == null or
            self.state.source_authority == .recovery)
            return .{ .rejected = .invalid_state };
        const attempt_id = self.state.activeAttempt().?;
        var next = self.state;
        if (next.source_authority == .ready) {
            next.source_authority = .recovery;
        } else {
            next.session_state = .shutting_down;
            next.source_authority = .none;
            next.selected_api_key_id.clear();
            next.selected_model.clear();
            next.metask_source_generation = 0;
        }
        next.clearTransaction();
        next.error_code = .recovery_state_invalid;
        next.safe_diagnostic.clear();
        var result = transitionNoEffect(
            next,
            .operation_failed,
            attempt_id,
        );
        result.transition.catalog_intent = if (next.session_state == .shutting_down)
            .clear_all
        else
            .discard_candidate;
        result.transition.preference_intent = .clear;
        return result;
    }

    /// The preference store was re-observed after an indeterminate write and
    /// contained neither the committed value nor the candidate value. Keep
    /// the last committed selection and in-process credential owner intact,
    /// but revoke new Task admission until a later transaction repairs it.
    pub fn prepareDefaultModelPersistenceInvalid(
        self: *const Account,
    ) PrepareResult {
        if (self.state.operation() != .persisting_model or
            (self.state.attemptKind() != .model_preference and
                self.state.attemptKind() != .catalog) or
            self.state.activeAttempt() == null)
            return .{ .rejected = .invalid_state };
        const attempt_id = self.state.activeAttempt().?;
        var next = self.state;
        next.source_authority = .recovery;
        next.clearTransaction();
        next.error_code = .recovery_state_invalid;
        next.safe_diagnostic.clear();
        var result = transitionNoEffect(next, .operation_failed, attempt_id);
        result.transition.catalog_intent = if (self.state.attemptKind() == .catalog)
            .discard_candidate
        else
            .committed;
        result.transition.preference_intent = .clear;
        return result;
    }

    pub fn prepareTokenRefresh(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.operation() != .none or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .refreshing;
        next.transaction = .{ .token_exchange = attempt.current };
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(
            next,
            .session_changed,
            attempt.current,
            .refresh_token,
        );
    }

    pub fn prepareRestoredTokenRefresh(self: *const Account) PrepareResult {
        if ((self.state.session_state != .restoring and
            self.state.session_state != .signed_out) or
            self.state.operation() != .none or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .refreshing;
        next.transaction = .{ .token_exchange = attempt.current };
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(
            next,
            .session_changed,
            attempt.current,
            .refresh_token,
        );
    }

    /// Consumes secret ownership in `completion` on stale, rejected, and
    /// execution-transfer paths. Callers may always call `deinit` afterwards.
    pub fn prepareCompletion(
        self: *const Account,
        completion: *WorkerCompletion,
    ) PrepareResult {
        if (self.state.activeAttempt() == null or
            self.state.activeAttempt().? != completion.attempt_id)
        {
            completion.deinit();
            return .ignored_stale;
        }

        const result = switch (completion.payload) {
            .identity_loaded => |identity| self.prepareIdentityLoaded(identity),
            .tokens_persisted => self.prepareTokensPersisted(),
            .api_keys_loaded => self.prepareApiKeysLoaded(),
            .models_loaded => self.prepareModelsLoaded(),
            .source_candidate_ready => self.prepareSourceCandidateReady(completion),
            .source_preference_persisted => self.prepareSourcePreferencePersisted(),
            .default_model_persisted => self.prepareDefaultModelPersisted(),
            .logged_out => self.prepareLoggedOut(),
            .failed => |failure| self.prepareFailure(failure),
        };
        return switch (result) {
            .rejected => |error_code| blk: {
                completion.deinit();
                break :blk self.prepareFailure(.fromCode(error_code));
            },
            else => result,
        };
    }

    pub fn prepareShutdown(self: *const Account) PreparedTransition {
        var next = self.state;
        next.session_state = .shutting_down;
        next.source_authority = .none;
        next.selected_api_key_id.clear();
        next.selected_model.clear();
        next.metask_source_generation = 0;
        next.clearError();
        const active_attempt = next.activeAttempt();
        next.clearTransaction();
        return .{
            .next = next,
            .fact_kind = .session_changed,
            .attempt_id = active_attempt,
            .effect = .{ .shutdown = active_attempt },
            .catalog_intent = .clear_all,
        };
    }

    /// Records failure to admit an automatic background continuation. This
    /// converts an otherwise invisible idle state into a retryable product
    /// state without inventing or replaying an external attempt.
    pub fn prepareIdleFailure(
        self: *const Account,
        error_code: contract.ErrorCode,
    ) PrepareResult {
        if (error_code == .none or
            self.state.session_state != .authenticated or
            self.state.source_authority != .none or
            self.state.operation() != .none or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.error_code = error_code;
        next.safe_diagnostic.clear();
        return transitionNoAttempt(next, .operation_failed);
    }

    fn prepareBeginLogin(self: *const Account) PrepareResult {
        if ((self.state.session_state != .signed_out and
            self.state.session_state != .authenticated) or
            self.state.operation() != .none)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .authorizing;
        next.transaction = .{ .oauth_callback = attempt.current };
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .begin_oauth);
    }

    fn prepareCancel(self: *const Account) PrepareResult {
        if (!self.state.canCancelOperation())
            return .{ .rejected = .invalid_state };
        const attempt = self.state.activeAttempt() orelse
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = switch (next.attemptKind()) {
            .login => if (next.account_id.len == 0) .signed_out else .authenticated,
            .refresh_token => .authenticated,
            .catalog, .catalog_refresh, .activation, .model_preference => .authenticated,
            .logout, .none => next.session_state,
        };
        next.clearTransaction();
        next.error_code = .user_cancelled;
        next.safe_diagnostic.clear();
        var result = transition(
            next,
            .operation_failed,
            attempt,
            .{ .cancel_attempt = attempt },
        );
        if (self.state.attemptKind() == .catalog or
            self.state.attemptKind() == .catalog_refresh or
            self.state.attemptKind() == .activation)
            result.transition.catalog_intent = .discard_candidate;
        return result;
    }

    fn prepareRefreshCatalog(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.operation() != .none)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        const recovery_refresh = self.state.source_authority == .recovery;
        next.transaction = .{ .loading_keys = next.catalogAttempt(
            attempt.current,
            if (recovery_refresh) .refresh_only else .preference,
        ) };
        if (recovery_refresh) {
            next.setPendingApiKeyId(next.selected_api_key_id.view()) catch
                return .{ .rejected = .invalid_command };
            next.setPendingModel(next.selected_model.view()) catch
                return .{ .rejected = .invalid_command };
        }
        next.next_attempt_id = attempt.next;
        if (!recovery_refresh) next.clearError();
        return transition(next, .session_changed, attempt.current, .load_api_keys);
    }

    fn prepareSelectApiKey(self: *const Account, id: []const u8) PrepareResult {
        if (self.state.session_state != .authenticated)
            return .{ .rejected = .invalid_state };
        if (self.state.operation() == .none and
            self.state.source_authority == .ready)
        {
            const attempt = nextAttempt(self.state.next_attempt_id) orelse
                return .{ .rejected = .generation_mismatch };
            var next = self.state;
            next.transaction = .{ .loading_keys = next.catalogAttempt(
                attempt.current,
                .preference,
            ) };
            next.setPendingApiKeyId(id) catch
                return .{ .rejected = .invalid_command };
            next.clearPendingModel();
            next.next_attempt_id = attempt.next;
            next.clearError();
            return transition(
                next,
                .session_changed,
                attempt.current,
                .load_api_keys,
            );
        }
        if (self.state.attemptKind() == .catalog and
            self.state.activeAttempt() != null and
            (self.state.operation() == .loading_models or
                self.state.operation() == .selecting_model))
        {
            // Automatic continuation is mid-flight (or parked on a model
            // choice). The user's explicit key choice supersedes it: queue
            // the key and reload its models at the next completion boundary
            // instead of discarding the click as invalid_state.
            var next = self.state;
            next.setPendingApiKeyId(id) catch
                return .{ .rejected = .invalid_command };
            next.clearPendingModel();
            next.clearError();
            if (self.state.operation() == .selecting_model) {
                // Parked: no worker in flight, reload immediately.
                next.transaction = .{ .loading_models = next.catalogAttempt(
                    next.activeAttempt().?,
                    .preference,
                ) };
                const effect_id = ApiKeyId.init(id) catch
                    return .{ .rejected = .invalid_command };
                var result = transition(
                    next,
                    .session_changed,
                    next.activeAttempt().?,
                    .{ .load_models = effect_id },
                );
                result.transition.catalog_intent = .candidate;
                return result;
            }
            next.markReloadingModels();
            var result = transitionNoEffect(
                next,
                .session_changed,
                next.activeAttempt().?,
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        if (self.state.operation() != .selecting_key or
            self.state.activeAttempt() == null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.setPendingApiKeyId(id) catch
            return .{ .rejected = .invalid_command };
        next.transaction = .{ .loading_models = next.catalogAttempt(
            next.activeAttempt().?,
            .preference,
        ) };
        next.clearError();
        const effect_id = ApiKeyId.init(id) catch
            return .{ .rejected = .invalid_command };
        var result = transition(
            next,
            .session_changed,
            next.activeAttempt().?,
            .{ .load_models = effect_id },
        );
        result.transition.catalog_intent = .candidate;
        return result;
    }

    fn prepareSelectModel(self: *const Account, model: []const u8) PrepareResult {
        if (self.state.session_state != .authenticated)
            return .{ .rejected = .invalid_state };
        if (self.state.attemptKind() == .activation) {
            if (self.state.operation() != .selecting_model or
                self.state.activeAttempt() == null or
                !std.mem.eql(u8, self.state.pendingApiKeyId(), self.state.selected_api_key_id.view()) or
                !std.mem.eql(u8, model, self.state.selected_model.view()))
                return .{ .rejected = .invalid_state };
            var next = self.state;
            next.setPendingModel(model) catch
                return .{ .rejected = .invalid_command };
            next.transaction = .{ .persisting_source = next.catalogAttempt(
                next.activeAttempt().?,
                .activation,
            ) };
            next.clearError();
            var result = transition(
                next,
                .execution_changed,
                next.activeAttempt().?,
                .{ .prepare_source_candidate = ModelId.init(model) catch
                    return .{ .rejected = .invalid_command } },
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        if (self.state.operation() == .none and
            self.state.source_authority == .ready)
        {
            if (std.mem.eql(u8, model, self.state.selected_model.view()))
                return transitionNoAttempt(self.state, .default_changed);
            const attempt = nextAttempt(self.state.next_attempt_id) orelse
                return .{ .rejected = .generation_mismatch };
            var next = self.state;
            next.transaction = next.modelPreferenceAttempt(
                attempt.current,
                .preference,
            );
            next.setPendingApiKeyId(next.selected_api_key_id.view()) catch
                return .{ .rejected = .invalid_command };
            next.setPendingModel(model) catch
                return .{ .rejected = .invalid_command };
            next.next_attempt_id = attempt.next;
            next.clearError();
            return transition(
                next,
                .session_changed,
                attempt.current,
                .{ .persist_default_model = tryModelId(model) orelse
                    return .{ .rejected = .invalid_command } },
            );
        }
        if (self.state.operation() != .selecting_model or
            self.state.activeAttempt() == null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        if (next.source_authority == .ready and
            std.mem.eql(
                u8,
                next.pendingApiKeyId(),
                next.selected_api_key_id.view(),
            ) and
            std.mem.eql(u8, model, next.selected_model.view()))
        {
            next.clearTransaction();
            next.clearError();
            var result = transitionNoEffect(
                next,
                .catalog_changed,
                self.state.activeAttempt().?,
            );
            result.transition.catalog_intent = .promote_candidate;
            return result;
        }
        // A model-only change updates the Account default for future Tasks.
        // It must not create a new credential execution generation or replace
        // the Workbench's live credential owner.
        if (next.source_authority == .ready and
            std.mem.eql(
                u8,
                next.pendingApiKeyId(),
                next.selected_api_key_id.view(),
            ))
        {
            next.setPendingModel(model) catch
                return .{ .rejected = .invalid_command };
            next.transaction = next.modelPreferenceAttempt(
                next.activeAttempt().?,
                .catalog,
            );
            next.clearError();
            var result = transition(
                next,
                .session_changed,
                self.state.activeAttempt().?,
                .{ .persist_default_model = tryModelId(model) orelse
                    return .{ .rejected = .invalid_command } },
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        next.setPendingModel(model) catch
            return .{ .rejected = .invalid_command };
        next.transaction = .{ .persisting_source = next.catalogAttempt(
            next.activeAttempt().?,
            .preference,
        ) };
        next.clearError();
        const effect_model = ModelId.init(model) catch
            return .{ .rejected = .invalid_command };
        var result = transition(
            next,
            .execution_changed,
            next.activeAttempt().?,
            .{ .prepare_source_candidate = effect_model },
        );
        result.transition.catalog_intent = .candidate;
        return result;
    }

    fn prepareResolveMetaskSource(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.operation() != .none or
            self.state.source_authority != .ready or
            self.state.selected_api_key_id.len == 0 or
            self.state.selected_model.len == 0 or
            self.state.metask_source_generation == 0)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.transaction = .{ .loading_keys = next.catalogAttempt(
            attempt.current,
            .activation,
        ) };
        next.setPendingApiKeyId(next.selected_api_key_id.view()) catch
            return .{ .rejected = .invalid_command };
        next.clearPendingModel();
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(
            next,
            .session_changed,
            attempt.current,
            .load_api_keys,
        );
    }

    fn prepareLogout(self: *const Account) PrepareResult {
        if (self.state.operation() != .none or
            self.state.session_state != .authenticated)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.transaction = .{ .logging_out = attempt.current };
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(
            next,
            .session_changed,
            attempt.current,
            .delete_credential,
        );
    }

    fn prepareIdentityLoaded(
        self: *const Account,
        identity: AccountIdentity,
    ) PrepareResult {
        if (self.state.operation() != .loading_identity or
            (self.state.attemptKind() != .login and
                self.state.attemptKind() != .refresh_token))
            return .{ .rejected = .invalid_state };
        if (self.state.attemptKind() == .refresh_token and
            self.state.account_id.len != 0 and !std.mem.eql(
            u8,
            identity.accountId(),
            self.state.account_id.view(),
        )) return .{ .rejected = .metask_unauthorized };
        var next = self.state;
        next.session_state = .authenticated;
        if (next.attemptKind() == .login) {
            next.source_authority = .none;
            next.selected_api_key_id.clear();
            next.selected_model.clear();
            next.metask_source_generation = 0;
        }
        next.clearTransaction();
        next.account_id = identity.account_id;
        next.display_name = identity.display_name;
        next.clearError();
        var result = transitionNoEffect(
            next,
            .session_changed,
            self.state.activeAttempt().?,
        );
        if (self.state.attemptKind() == .login) {
            result.transition.catalog_intent = .clear_all;
        }
        return result;
    }

    fn prepareTokensPersisted(self: *const Account) PrepareResult {
        if ((self.state.attemptKind() != .login or
            self.state.operation() != .oauth_callback) and
            (self.state.attemptKind() != .refresh_token or
                self.state.operation() != .token_exchange))
            return .{ .rejected = .invalid_state };
        var next = self.state;
        if (next.attemptKind() == .login or next.account_id.len == 0) {
            const attempt_kind = next.attemptKind();
            const attempt_id = next.activeAttempt().?;
            next.transaction = .{ .loading_identity = .{
                .attempt_id = attempt_id,
                .kind = if (attempt_kind == .login)
                    .login
                else
                    .refresh_token,
            } };
            next.clearError();
            return transition(
                next,
                .session_changed,
                self.state.activeAttempt().?,
                .load_identity,
            );
        }
        next.session_state = .authenticated;
        next.clearTransaction();
        next.clearError();
        return transitionNoEffect(
            next,
            .session_changed,
            self.state.activeAttempt().?,
        );
    }

    fn prepareApiKeysLoaded(self: *const Account) PrepareResult {
        if (self.state.operation() != .loading_keys or
            (self.state.attemptKind() != .catalog and
                self.state.attemptKind() != .catalog_refresh and
                self.state.attemptKind() != .activation))
            return .{ .rejected = .invalid_state };
        const attempt_kind = self.state.attemptKind();
        const generation = incrementGeneration(self.state.catalog_generation) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.catalog_generation = generation;
        if (next.pendingApiKeyId().len != 0) {
            next.transaction = .{ .loading_models = next.catalogAttempt(
                next.activeAttempt().?,
                switch (attempt_kind) {
                    .activation => .activation,
                    .catalog_refresh => .refresh_only,
                    else => .preference,
                },
            ) };
            if (attempt_kind != .catalog_refresh) next.clearError();
            const effect_id = ApiKeyId.init(next.pendingApiKeyId()) catch
                return .{ .rejected = .invalid_command };
            var result = transition(
                next,
                .catalog_changed,
                next.activeAttempt().?,
                .{ .load_models = effect_id },
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        next.transaction = .{ .selecting_key = next.catalogAttempt(
            next.activeAttempt().?,
            .preference,
        ) };
        next.clearError();
        var result = transitionNoEffect(next, .catalog_changed, next.activeAttempt().?);
        result.transition.catalog_intent = .candidate;
        return result;
    }

    fn prepareModelsLoaded(self: *const Account) PrepareResult {
        if (self.state.operation() != .loading_models or
            (self.state.attemptKind() != .catalog and
                self.state.attemptKind() != .catalog_refresh and
                self.state.attemptKind() != .activation))
            return .{ .rejected = .invalid_state };
        const attempt_kind = self.state.attemptKind();
        const generation = incrementGeneration(self.state.catalog_generation) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.catalog_generation = generation;
        if (attempt_kind == .catalog_refresh) {
            next.clearTransaction();
            var result = transitionNoEffect(
                next,
                .catalog_changed,
                self.state.activeAttempt().?,
            );
            result.transition.catalog_intent = .promote_candidate;
            return result;
        }
        if (next.reloadingModels()) {
            // The loaded models belong to a key the user superseded while the
            // load was in flight. Drop the stale result and reload for the
            // queued key.
            next.transaction = .{ .loading_models = next.catalogAttempt(
                next.activeAttempt().?,
                if (attempt_kind == .activation) .activation else .preference,
            ) };
            next.clearError();
            const effect_id = ApiKeyId.init(next.pendingApiKeyId()) catch
                return .{ .rejected = .invalid_command };
            var result = transition(
                next,
                .catalog_changed,
                next.activeAttempt().?,
                .{ .load_models = effect_id },
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        if (next.pendingModel().len != 0) {
            next.transaction = .{ .persisting_source = next.catalogAttempt(
                next.activeAttempt().?,
                if (attempt_kind == .activation) .activation else .preference,
            ) };
            next.clearError();
            const effect_model = ModelId.init(next.pendingModel()) catch
                return .{ .rejected = .invalid_command };
            var result = transition(
                next,
                .execution_changed,
                next.activeAttempt().?,
                .{ .prepare_source_candidate = effect_model },
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        next.transaction = .{ .selecting_model = next.catalogAttempt(
            next.activeAttempt().?,
            if (attempt_kind == .activation) .activation else .preference,
        ) };
        next.clearError();
        var result = transitionNoEffect(next, .catalog_changed, next.activeAttempt().?);
        result.transition.catalog_intent = .candidate;
        return result;
    }

    fn prepareSourceCandidateReady(
        self: *const Account,
        completion: *WorkerCompletion,
    ) PrepareResult {
        if (self.state.operation() != .persisting or
            (self.state.attemptKind() != .catalog and
                self.state.attemptKind() != .activation))
            return .{ .rejected = .invalid_state };
        var source_candidate = switch (completion.payload) {
            .source_candidate_ready => |*owned| owned.take(),
            else => unreachable,
        };
        const input = source_candidate.input();
        if (input.source_generation == 0 or
            !std.mem.eql(u8, input.target.model, self.state.pendingModel()) or
            self.state.pendingApiKeyId().len == 0)
        {
            source_candidate.deinit();
            completion.payload = dependencyFailure();
            return .{ .rejected = .generation_mismatch };
        }

        if (self.state.attemptKind() == .activation) {
            if (input.source_generation != self.state.metask_source_generation or
                !std.mem.eql(u8, self.state.pendingApiKeyId(), self.state.selected_api_key_id.view()) or
                !std.mem.eql(u8, self.state.pendingModel(), self.state.selected_model.view()))
            {
                source_candidate.deinit();
                completion.payload = dependencyFailure();
                return .{ .rejected = .generation_mismatch };
            }
            var next = self.state;
            next.clearTransaction();
            next.clearError();
            completion.payload = dependencyFailure();
            return .{ .transition = .{
                .next = next,
                .fact_kind = .catalog_changed,
                .attempt_id = completion.attempt_id,
                .source_candidate = source_candidate,
                .catalog_intent = .promote_candidate,
            } };
        }

        var next = self.state;
        next.setPendingSourceGeneration(input.source_generation) catch
            unreachable;
        next.clearError();
        completion.payload = dependencyFailure();
        return .{ .transition = .{
            .next = next,
            .fact_kind = .execution_changed,
            .attempt_id = completion.attempt_id,
            .effect = .{ .persist_source_preference = .{
                .model = ModelId.init(input.target.model) catch unreachable,
                .metask_source_generation = input.source_generation,
            } },
            .source_candidate = source_candidate,
            .catalog_intent = .candidate,
        } };
    }

    fn prepareSourcePreferencePersisted(self: *const Account) PrepareResult {
        if (self.state.operation() != .persisting or
            self.state.attemptKind() != .catalog or
            self.state.activeAttempt() == null or
            self.state.pendingApiKeyId().len == 0 or
            self.state.pendingModel().len == 0 or
            self.state.pendingSourceGeneration() == 0)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.source_authority = .ready;
        next.metask_source_generation = next.pendingSourceGeneration();
        next.selected_api_key_id.set(next.pendingApiKeyId()) catch unreachable;
        next.selected_model.set(next.pendingModel()) catch unreachable;
        next.clearTransaction();
        next.clearError();
        var result = transitionNoEffect(
            next,
            .execution_changed,
            self.state.activeAttempt().?,
        );
        result.transition.catalog_intent = .promote_candidate;
        result.transition.preference_intent = .commit_pending;
        return result;
    }

    fn prepareDefaultModelPersisted(self: *const Account) PrepareResult {
        if (self.state.operation() != .persisting_model or
            (self.state.attemptKind() != .model_preference and
                self.state.attemptKind() != .catalog) or
            self.state.activeAttempt() == null or
            self.state.pendingApiKeyId().len == 0 or
            self.state.pendingModel().len == 0 or
            !std.mem.eql(
                u8,
                self.state.pendingApiKeyId(),
                self.state.selected_api_key_id.view(),
            ))
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.selected_model.set(next.pendingModel()) catch unreachable;
        next.clearTransaction();
        next.clearError();
        var result = transitionNoEffect(
            next,
            .default_changed,
            self.state.activeAttempt().?,
        );
        result.transition.catalog_intent = if (self.state.attemptKind() == .catalog)
            .promote_candidate
        else
            .committed;
        result.transition.preference_intent = .commit_pending;
        return result;
    }

    fn prepareLoggedOut(self: *const Account) PrepareResult {
        if (self.state.operation() != .logging_out or
            self.state.attemptKind() != .logout)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = .signed_out;
        next.source_authority = .none;
        next.account_id.clear();
        next.display_name.clear();
        next.selected_api_key_id.clear();
        next.selected_model.clear();
        next.catalog_generation = 0;
        next.metask_source_generation = 0;
        next.clearTransaction();
        next.clearError();
        var result = transitionNoEffect(
            next,
            .signed_out,
            self.state.activeAttempt().?,
        );
        result.transition.catalog_intent = .clear_all;
        return result;
    }

    fn prepareFailure(
        self: *const Account,
        failure: WorkerFailure,
    ) PrepareResult {
        const normalized_failure = if (failure.error_code == .none)
            WorkerFailure.fromCode(.account_operation_failed)
        else
            failure;
        // A model-catalog failure — empty catalog, quota exhaustion, server
        // error — is a fact about the selected key, not about the catalog
        // transaction: the model request authenticates with the API Key
        // itself, so its failure never invalidates the session. Tearing the
        // transaction down would discard the successfully loaded key list,
        // and with automatic first-key selection every retry deterministically
        // re-selects the same broken key: a bricked account whose only exit
        // is logout. Park back in choosing instead, with the key list intact
        // and the error surfaced, so the user re-picks.
        if (self.state.attemptKind() == .catalog and
            self.state.operation() == .loading_models)
        {
            var parked = self.state;
            parked.clearPendingApiKeyId();
            parked.clearPendingModel();
            parked.transaction = .{ .selecting_key = parked.catalogAttempt(
                parked.activeAttempt().?,
                .preference,
            ) };
            parked.error_code = normalized_failure.error_code;
            parked.safe_diagnostic = normalized_failure.safe_diagnostic;
            var result = transitionNoEffect(
                parked,
                .catalog_changed,
                self.state.activeAttempt().?,
            );
            result.transition.catalog_intent = .candidate;
            return result;
        }
        if (self.state.attemptKind() == .catalog_refresh) {
            var next = self.state;
            next.clearTransaction();
            next.error_code = normalized_failure.error_code;
            next.safe_diagnostic = normalized_failure.safe_diagnostic;
            var result = transitionNoEffect(
                next,
                .operation_failed,
                self.state.activeAttempt().?,
            );
            result.transition.catalog_intent = .discard_candidate;
            return result;
        }
        const login_replaced = self.state.attemptKind() == .login and
            self.state.operation() == .loading_identity;
        var next = self.state;
        next.session_state = switch (next.attemptKind()) {
            .login => if (login_replaced or next.account_id.len == 0)
                .signed_out
            else
                .authenticated,
            .refresh_token => if (next.account_id.len == 0)
                .signed_out
            else
                .authenticated,
            .catalog, .catalog_refresh, .activation, .model_preference, .logout, .none => next.session_state,
        };
        const authentication_invalid = self.state.attemptKind() == .refresh_token and
            (normalized_failure.error_code == .metask_unauthorized or
                normalized_failure.error_code == .credential_store_delete_failed);
        if (authentication_invalid or login_replaced or
            (self.state.attemptKind() == .login and
                self.state.account_id.len == 0))
        {
            next.session_state = .signed_out;
            next.source_authority = .none;
            next.account_id.clear();
            next.display_name.clear();
            next.selected_api_key_id.clear();
            next.selected_model.clear();
            next.catalog_generation = 0;
            next.metask_source_generation = 0;
        }
        next.clearTransaction();
        next.error_code = normalized_failure.error_code;
        next.safe_diagnostic = normalized_failure.safe_diagnostic;
        var result = transitionNoEffect(
            next,
            .operation_failed,
            self.state.activeAttempt().?,
        );
        result.transition.catalog_intent = if (self.state.attemptKind() == .catalog or
            self.state.attemptKind() == .activation)
            .discard_candidate
        else if (next.session_state == .signed_out)
            .clear_all
        else
            .committed;
        return result;
    }
};

const AttemptAdvance = struct {
    current: u64,
    next: u64,
};

fn nextAttempt(current: u64) ?AttemptAdvance {
    if (current == 0 or current == std.math.maxInt(u64)) return null;
    return .{ .current = current, .next = current + 1 };
}

fn tryModelId(value: []const u8) ?ModelId {
    return ModelId.init(value) catch null;
}

fn incrementGeneration(current: u64) ?u64 {
    if (current == std.math.maxInt(u64)) return null;
    return current + 1;
}

fn dependencyFailure() WorkerCompletion.Payload {
    return .{ .failed = .{
        .error_code = .account_operation_failed,
    } };
}

fn transition(
    next: CommittedState,
    fact_kind: contract.AccountFactKind,
    attempt_id: u64,
    effect: Effect,
) PrepareResult {
    std.debug.assert(stateIsValid(&next));
    return .{ .transition = .{
        .next = next,
        .fact_kind = fact_kind,
        .attempt_id = attempt_id,
        .effect = effect,
    } };
}

fn transitionNoEffect(
    next: CommittedState,
    fact_kind: contract.AccountFactKind,
    attempt_id: u64,
) PrepareResult {
    std.debug.assert(stateIsValid(&next));
    return .{ .transition = .{
        .next = next,
        .fact_kind = fact_kind,
        .attempt_id = attempt_id,
    } };
}

fn transitionNoAttempt(
    next: CommittedState,
    fact_kind: contract.AccountFactKind,
) PrepareResult {
    std.debug.assert(stateIsValid(&next));
    return .{ .transition = .{
        .next = next,
        .fact_kind = fact_kind,
        .attempt_id = null,
    } };
}

fn stateIsValid(state: *const CommittedState) bool {
    if ((state.activeAttempt() == null) != (state.attemptKind() == .none))
        return false;
    if (state.activeAttempt() == null and state.operation() != .none)
        return false;
    if (state.activeAttempt() != null and state.operation() == .none)
        return false;
    if (state.pendingSourceGeneration() != 0 and
        (state.operation() != .persisting or state.attemptKind() != .catalog))
        return false;

    switch (state.session_state) {
        .restoring, .signed_out, .shutting_down => {
            if (state.operation() != .none) return false;
        },
        .authorizing => {
            if (state.operation() != .oauth_callback and
                state.operation() != .loading_identity)
                return false;
            if (state.attemptKind() != .login) return false;
        },
        .refreshing => {
            if ((state.operation() != .token_exchange and
                state.operation() != .loading_identity) or
                state.attemptKind() != .refresh_token)
                return false;
        },
        .authenticated => {},
    }

    switch (state.source_authority) {
        .none => {
            if (state.metask_source_generation != 0 or
                state.selected_api_key_id.len != 0 or
                state.selected_model.len != 0)
                return false;
        },
        .ready => {
            if (state.metask_source_generation == 0 or
                state.selected_api_key_id.len == 0 or
                state.selected_model.len == 0)
                return false;
        },
        .recovery => {
            if (state.metask_source_generation == 0 or
                state.selected_api_key_id.len == 0 or
                state.selected_model.len == 0)
                return false;
            switch (state.transaction) {
                .none, .oauth_callback, .token_exchange, .logging_out => {},
                .loading_identity => |value| if (value.kind != .refresh_token and
                    value.kind != .login)
                    return false,
                .loading_keys, .loading_models => |value| if (value.kind != .refresh_only)
                    return false,
                else => return false,
            }
        },
    }
    return true;
}

pub const PrepareResult = union(enum) {
    transition: PreparedTransition,
    rejected: contract.ErrorCode,
    ignored_stale,
};

pub const CatalogIntent = enum {
    committed,
    candidate,
    promote_candidate,
    discard_candidate,
    clear_all,
};

pub const PreferenceIntent = enum {
    unchanged,
    commit_pending,
    clear,
};

pub const PreparedTransition = struct {
    next: CommittedState,
    fact_kind: contract.AccountFactKind,
    attempt_id: ?u64,
    effect: ?Effect = null,
    source_candidate: ?execution_contract.OwnedSourceCandidate = null,
    catalog_intent: CatalogIntent = .committed,
    preference_intent: PreferenceIntent = .unchanged,
    committed: bool = false,

    pub fn view(self: *const PreparedTransition) contract.AccountView {
        return self.next.view();
    }

    pub fn sourceGeneration(self: *const PreparedTransition) u64 {
        return self.next.metask_source_generation;
    }

    pub fn sourceAuthorityReady(self: *const PreparedTransition) bool {
        return self.next.source_authority == .ready;
    }

    pub fn factKind(self: *const PreparedTransition) contract.AccountFactKind {
        return self.fact_kind;
    }

    pub fn catalogIntent(self: *const PreparedTransition) CatalogIntent {
        return self.catalog_intent;
    }

    pub fn preferenceIntent(self: *const PreparedTransition) PreferenceIntent {
        return self.preference_intent;
    }

    pub fn finishesAttempt(self: *const PreparedTransition) bool {
        return self.attempt_id != null and self.next.activeAttempt() == null;
    }

    pub fn takeSourceCandidate(
        self: *PreparedTransition,
    ) ?execution_contract.OwnedSourceCandidate {
        if (self.source_candidate) |*source_candidate| {
            const result = source_candidate.take();
            self.source_candidate = null;
            return result;
        }
        return null;
    }

    pub fn sourceCandidateTransfer(
        self: *PreparedTransition,
    ) ?execution_contract.OwnedSourceCandidateTransfer {
        if (self.source_candidate == null) return null;
        return .{
            .context = self,
            .take_fn = takeTransferredSourceCandidate,
        };
    }

    pub fn attachSourceCandidate(
        self: *PreparedTransition,
        source_candidate: execution_contract.OwnedSourceCandidate,
    ) void {
        std.debug.assert(!self.committed);
        std.debug.assert(self.source_candidate == null);
        self.source_candidate = source_candidate;
    }

    fn takeTransferredSourceCandidate(
        context: *anyopaque,
    ) execution_contract.OwnedSourceCandidate {
        const self: *PreparedTransition = @ptrCast(@alignCast(context));
        return self.takeSourceCandidate() orelse
            @panic("Account source candidate was already transferred");
    }

    pub fn takeEffect(self: *PreparedTransition) ?Effect {
        const effect = self.effect;
        self.effect = null;
        return effect;
    }

    pub fn commit(self: *PreparedTransition, account: *Account) void {
        std.debug.assert(!self.committed);
        std.debug.assert(stateIsValid(&self.next));
        account.state = self.next;
        self.committed = true;
    }

    pub fn deinit(self: *PreparedTransition) void {
        if (self.committed) std.debug.assert(self.effect == null);
        if (self.source_candidate) |*source_candidate| source_candidate.deinit();
        self.source_candidate = null;
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    pub fn prepareReady(
        account: *const Account,
        identity: AccountIdentity,
        api_key_id: []const u8,
        source_candidate_value: *execution_contract.OwnedSourceCandidate,
    ) !PreparedTransition {
        if (account.state.session_state != .restoring or api_key_id.len == 0)
            return error.InvalidState;
        var source_candidate = source_candidate_value.take();
        errdefer source_candidate.deinit();
        const input = source_candidate.input();
        if (input.source_generation == 0) return error.InvalidGeneration;
        var next = account.state;
        next.session_state = .authenticated;
        next.source_authority = .ready;
        next.account_id = identity.account_id;
        next.display_name = identity.display_name;
        next.selected_api_key_id = try ApiKeyId.init(api_key_id);
        try next.selected_model.set(input.target.model);
        next.metask_source_generation = input.source_generation;
        next.clearError();
        return .{
            .next = next,
            .fact_kind = .restored,
            .attempt_id = null,
            .source_candidate = source_candidate,
        };
    }

    pub fn installInitialExecutionPreparation(
        account: *Account,
        api_key_id: []const u8,
        model_id: []const u8,
    ) void {
        var next: CommittedState = .{
            .session_state = .authenticated,
            .source_authority = .none,
            .transaction = .{ .persisting_source = .{ .attempt_id = 1 } },
            .catalog_generation = 1,
            .next_attempt_id = 2,
        };
        next.account_id.set("account-1") catch unreachable;
        next.display_name.set("Metask User") catch unreachable;
        next.setPendingApiKeyId(api_key_id) catch unreachable;
        next.setPendingModel(model_id) catch unreachable;
        std.debug.assert(stateIsValid(&next));
        account.state = next;
    }

    pub fn enterPreferenceRecovery(account: *Account) void {
        std.debug.assert(account.state.source_authority == .ready);
        std.debug.assert(account.state.operation() == .none);
        account.state.source_authority = .recovery;
        account.state.error_code = .recovery_state_invalid;
        account.state.safe_diagnostic.clear();
        std.debug.assert(stateIsValid(&account.state));
    }
} else struct {};

pub const AccountIdentity = struct {
    account_id: AccountId,
    display_name: DisplayName,

    pub fn init(
        account_id: []const u8,
        display_name: []const u8,
    ) contract.ValidationError!AccountIdentity {
        if (account_id.len == 0) return error.FieldEmpty;
        return .{
            .account_id = try .init(account_id),
            .display_name = try .init(display_name),
        };
    }

    pub fn accountId(self: *const AccountIdentity) []const u8 {
        return self.account_id.view();
    }

    pub fn displayName(self: *const AccountIdentity) []const u8 {
        return self.display_name.view();
    }
};

pub const WorkerFailure = struct {
    error_code: contract.ErrorCode,
    safe_diagnostic: SafeDiagnostic = .{},

    pub fn init(
        error_code: contract.ErrorCode,
        safe_diagnostic: []const u8,
    ) contract.ValidationError!WorkerFailure {
        if (error_code == .none) return error.InconsistentState;
        return .{
            .error_code = error_code,
            .safe_diagnostic = try .init(safe_diagnostic),
        };
    }

    pub fn diagnostic(self: *const WorkerFailure) []const u8 {
        return self.safe_diagnostic.view();
    }

    pub fn fromCode(error_code: contract.ErrorCode) WorkerFailure {
        std.debug.assert(error_code != .none);
        return .{ .error_code = error_code };
    }
};

pub const WorkerCompletion = struct {
    attempt_id: u64,
    payload: Payload,

    pub const Payload = union(enum) {
        identity_loaded: AccountIdentity,
        tokens_persisted,
        api_keys_loaded,
        models_loaded,
        source_candidate_ready: execution_contract.OwnedSourceCandidate,
        source_preference_persisted,
        default_model_persisted,
        logged_out,
        failed: WorkerFailure,
    };

    pub fn deinit(self: *WorkerCompletion) void {
        switch (self.payload) {
            .source_candidate_ready => |*execution| execution.deinit(),
            else => {},
        }
        self.payload = dependencyFailure();
    }
};

pub const RestoreSignedOut = struct {};

pub const RestoreResult = union(enum) {
    signed_out: RestoreSignedOut,
    refresh_only: void,

    pub fn deinit(self: *RestoreResult) void {
        self.* = emptyRestore();
    }
};

fn emptyRestore() RestoreResult {
    return .{ .signed_out = .{} };
}

fn commitPrepared(account: *Account, prepared: *PreparedTransition) void {
    prepared.commit(account);
    prepared.deinit();
}

fn testSelection(selection_id: []const u8) contract.AccountSelectionCommand {
    return .{
        .selection_id = selection_id,
        .expected_catalog_generation = 0,
    };
}

test "command prepare does not mutate committed state before commit" {
    var account = Account.initSignedOutForTest();
    var prepared = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();

    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expectEqual(contract.AccountState.authorizing, prepared.view().state);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
    _ = prepared.takeEffect();
    prepared.commit(&account);
    try std.testing.expectEqual(contract.AccountState.authorizing, account.view().state);
    try std.testing.expectEqual(@as(?u64, 1), account.activeAttempt());
}

test "public Account state exposes one cancellable authorization flow" {
    var account = Account.initSignedOutForTest();
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        account.view().state,
    );

    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);
    try std.testing.expectEqual(
        contract.AccountState.authorizing,
        account.view().state,
    );
    try std.testing.expect(account.view().can_cancel);

    var cancel = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = cancel.takeEffect();
    commitPrepared(&account, &cancel);
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        account.view().state,
    );
    try std.testing.expect(!account.view().can_cancel);
}

test "matching malformed completion fails the attempt instead of wedging it" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);

    var malformed: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var failed = switch (account.prepareCompletion(&malformed)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);

    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        account.view().state,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.invalid_state,
        account.view().error_code,
    );
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
}

test "fake browser client and store observe only committed effects" {
    const FakeDependencies = struct {
        accept: bool = true,
        browser_calls: usize = 0,
        client_calls: usize = 0,
        store_calls: usize = 0,

        fn submit(raw: *anyopaque, _: ?u64, effect: Effect) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!self.accept) return false;
            switch (effect) {
                .begin_oauth => self.browser_calls += 1,
                .refresh_token, .load_identity => self.client_calls += 1,
                .load_api_keys, .load_models => self.client_calls += 1,
                .prepare_source_candidate,
                .persist_source_preference,
                .persist_default_model,
                .delete_credential,
                => self.store_calls += 1,
                .cancel_attempt, .shutdown => {},
            }
            return true;
        }
    };

    var dependencies: FakeDependencies = .{};
    const sink: EffectSink = .{
        .context = &dependencies,
        .submit_fn = FakeDependencies.submit,
    };
    var account = Account.initSignedOutForTest();
    var prepared = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), dependencies.browser_calls);
    const effect = prepared.takeEffect().?;
    try std.testing.expect(sink.submit(prepared.attempt_id, effect));
    prepared.commit(&account);
    try std.testing.expect(sink.submit(1, .load_api_keys));
    try std.testing.expect(sink.submit(1, .{
        .prepare_source_candidate = try .init("model-1"),
    }));
    try std.testing.expectEqual(@as(usize, 1), dependencies.browser_calls);
    try std.testing.expectEqual(@as(usize, 1), dependencies.client_calls);
    try std.testing.expectEqual(@as(usize, 1), dependencies.store_calls);

    dependencies.accept = false;
    var rejected_account = Account.initSignedOutForTest();
    var rejected = switch (rejected_account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer rejected.deinit();
    try std.testing.expect(!sink.submit(
        rejected.attempt_id,
        rejected.takeEffect().?,
    ));
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        rejected_account.view().state,
    );
}

test "explicit login persists tokens before publishing identity" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);

    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var load_identity = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(load_identity.takeEffect().? == .load_identity);
    commitPrepared(&account, &load_identity);
    try std.testing.expectEqual(contract.AccountState.authorizing, account.view().state);
    try std.testing.expectEqualStrings("", account.view().account_id);
    try std.testing.expect(!account.view().can_cancel);
    try std.testing.expectEqual(
        contract.ErrorCode.invalid_state,
        account.prepareCommand(.cancel_operation).rejected,
    );

    var identified: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-2", "Other User") },
    };
    var completed = switch (account.prepareCompletion(&identified)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &completed);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-2", account.view().account_id);
    try std.testing.expectEqualStrings("Other User", account.view().display_name);
    try std.testing.expectEqual(@as(u64, 0), account.sourceGeneration());
}

test "explicit login accepts the newly verified identity" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .account_id = try .init("account-1"),
        .display_name = try .init("Old User"),
    } };
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);
    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var identity_request = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = identity_request.takeEffect();
    commitPrepared(&account, &identity_request);
    var identified: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-2", "New User") },
    };
    var committed = switch (account.prepareCompletion(&identified)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &committed);
    try std.testing.expectEqualStrings("account-2", account.view().account_id);
    try std.testing.expectEqualStrings("New User", account.view().display_name);
}

test "failed replacement before token commit preserves the current identity" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .account_id = try .init("account-1"),
        .display_name = try .init("Current User"),
    } };
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);
    var failure: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.oauth_exchange_failed) },
    };
    var failed = switch (account.prepareCompletion(&failure)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-1", account.view().account_id);
    try std.testing.expectEqualStrings("Current User", account.view().display_name);
}

test "cold refresh publishes only the verified current identity" {
    var account = Account.initRestoring();
    var restore: RestoreResult = .{ .refresh_only = {} };
    var restored = switch (account.prepareRestore(&restore)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &restored);

    var refresh = switch (account.prepareRestoredTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = refresh.takeEffect();
    commitPrepared(&account, &refresh);
    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var load_identity = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = load_identity.takeEffect();
    commitPrepared(&account, &load_identity);
    try std.testing.expectEqual(contract.AccountState.checking, account.view().state);

    var completion: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("22", "朱健") },
    };
    var completed = switch (account.prepareCompletion(&completion)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &completed);
    try std.testing.expectEqualStrings("22", account.view().account_id);
    try std.testing.expectEqualStrings("朱健", account.view().display_name);
}

test "refresh failure matrix distinguishes retryable and invalid credentials" {
    var cold = Account.initRestoring();
    var restored: RestoreResult = .{ .refresh_only = {} };
    var restore = switch (cold.prepareRestore(&restored)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&cold, &restore);
    var cold_refresh = switch (cold.prepareRestoredTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = cold_refresh.takeEffect();
    commitPrepared(&cold, &cold_refresh);
    var unavailable: WorkerCompletion = .{
        .attempt_id = cold.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.metask_service_unavailable) },
    };
    var retryable = switch (cold.prepareCompletion(&unavailable)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&cold, &retryable);
    try std.testing.expectEqual(contract.AccountState.signed_out, cold.view().state);
    try std.testing.expectEqual(
        contract.ErrorCode.metask_service_unavailable,
        cold.view().error_code,
    );
    var retry = switch (cold.prepareRestoredTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(retry.takeEffect().? == .refresh_token);
    retry.deinit();

    var active = Account{ .state = .{
        .session_state = .authenticated,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
    } };
    var active_refresh = switch (active.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = active_refresh.takeEffect();
    commitPrepared(&active, &active_refresh);
    var unauthorized: WorkerCompletion = .{
        .attempt_id = active.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.metask_unauthorized) },
    };
    var invalid = switch (active.prepareCompletion(&unauthorized)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&active, &invalid);
    try std.testing.expectEqual(contract.AccountState.signed_out, active.view().state);
    try std.testing.expectEqualStrings("", active.view().account_id);
}

test "manual key choice supersedes an in-flight automatic continuation" {
    const allocator = std.testing.allocator;
    var account = Account.initRestoring();
    var restored_execution = try execution_contract.OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "model-old"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
        "fixture-provider",
    );
    defer restored_execution.deinit();
    var restored = try TestSupport.prepareReady(
        &account,
        try .init("account-1", "Metask User"),
        "key-old",
        &restored_execution,
    );
    var installed = restored.takeSourceCandidate().?;
    installed.deinit();
    restored.commit(&account);
    restored.deinit();

    var refresh = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = refresh.takeEffect();
    commitPrepared(&account, &refresh);
    var keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_ready = switch (account.prepareCompletion(&keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &keys_ready);
    // Automatic continuation picks a key; its model load goes in flight.
    var auto_select = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-auto"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(auto_select.takeEffect() != null);
    commitPrepared(&account, &auto_select);

    // The user clicks a different key while that load is in flight. The
    // click must queue instead of bouncing as invalid_state.
    var manual = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-user"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(manual.takeEffect() == null);
    commitPrepared(&account, &manual);

    // The stale models result for key-auto is dropped and the load restarts
    // for the user's key inside the same attempt.
    var stale_models: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .models_loaded,
    };
    var reload = switch (account.prepareCompletion(&stale_models)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const effect = reload.takeEffect().?;
    try std.testing.expect(effect == .load_models);
    try std.testing.expectEqualStrings("key-user", effect.load_models.view());
    commitPrepared(&account, &reload);
    try std.testing.expectEqual(
        contract.CatalogState.loading,
        account.view().catalog_state,
    );
    try std.testing.expectEqualStrings(
        "key-user",
        account.view().candidate_api_key_id,
    );
}

test "Metask activation rebuilds the committed execution without a preference write" {
    const allocator = std.testing.allocator;
    var account = Account.initRestoring();
    var restored_execution = try execution_contract.OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "model-1"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
        "fixture-provider",
    );
    var restored = try TestSupport.prepareReady(
        &account,
        try .init("account-1", "Metask User"),
        "key-1",
        &restored_execution,
    );
    var installed = restored.takeSourceCandidate().?;
    installed.deinit();
    commitPrepared(&account, &restored);

    var activation = switch (account.prepareCommand(.resolve_metask_source)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(activation.takeEffect().? == .load_api_keys);
    commitPrepared(&account, &activation);
    const attempt_id = account.activeAttempt().?;

    var keys_loaded: WorkerCompletion = .{
        .attempt_id = attempt_id,
        .payload = .api_keys_loaded,
    };
    var load_models = switch (account.prepareCompletion(&keys_loaded)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(load_models.takeEffect().? == .load_models);
    commitPrepared(&account, &load_models);

    var models_loaded: WorkerCompletion = .{
        .attempt_id = attempt_id,
        .payload = .models_loaded,
    };
    var select_model = switch (account.prepareCompletion(&models_loaded)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(select_model.takeEffect() == null);
    commitPrepared(&account, &select_model);

    var prepare_source_candidate = switch (account.prepareCommand(.{
        .select_model = testSelection("model-1"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(prepare_source_candidate.takeEffect().? == .prepare_source_candidate);
    commitPrepared(&account, &prepare_source_candidate);

    var candidate = try execution_contract.OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "model-1"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
        "fixture-provider",
    );
    var source_candidate_ready: WorkerCompletion = .{
        .attempt_id = attempt_id,
        .payload = .{ .source_candidate_ready = candidate.take() },
    };
    defer source_candidate_ready.deinit();
    var terminal = switch (account.prepareCompletion(&source_candidate_ready)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(terminal.takeEffect() == null);
    try std.testing.expectEqual(PreferenceIntent.unchanged, terminal.preferenceIntent());
    try std.testing.expect(terminal.finishesAttempt());
    var transferred = terminal.takeSourceCandidate().?;
    transferred.deinit();
    commitPrepared(&account, &terminal);
    try std.testing.expectEqualStrings("key-1", account.view().selected_api_key_id);
    try std.testing.expectEqualStrings("model-1", account.view().selected_model);
    try std.testing.expectEqual(@as(u64, 9), account.sourceGeneration());
}

test "empty model catalog parks back in choosing with the key list intact" {
    const allocator = std.testing.allocator;
    var account = Account.initRestoring();
    var restored_execution = try execution_contract.OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "model-old"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
        "fixture-provider",
    );
    defer restored_execution.deinit();
    var restored = try TestSupport.prepareReady(
        &account,
        try .init("account-1", "Metask User"),
        "key-old",
        &restored_execution,
    );
    var installed = restored.takeSourceCandidate().?;
    installed.deinit();
    restored.commit(&account);
    restored.deinit();

    var refresh = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = refresh.takeEffect();
    commitPrepared(&account, &refresh);
    var keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_ready = switch (account.prepareCompletion(&keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &keys_ready);
    var select_key = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-exhausted"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_key.takeEffect();
    commitPrepared(&account, &select_key);

    // The selected key answers with an empty model catalog (for example a
    // quota-exhausted key). The transaction must park back in choosing with
    // the attempt alive instead of tearing down into a retry loop that
    // deterministically re-selects the same key.
    var empty_models: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.no_models) },
    };
    var parked = switch (account.prepareCompletion(&empty_models)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(parked.takeEffect() == null);
    commitPrepared(&account, &parked);

    const view = account.view();
    try std.testing.expectEqual(contract.CatalogState.choosing, view.catalog_state);
    try std.testing.expectEqual(contract.ErrorCode.no_models, view.error_code);
    try std.testing.expect(account.activeAttempt() != null);
    try std.testing.expect(view.can_cancel);
    // The committed execution keeps working; nothing was torn down.
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-old", view.selected_model);
    try std.testing.expectEqual(@as(u64, 9), account.sourceGeneration());

    // Re-picking a key continues inside the same parked transaction.
    var reselect = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-good"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(reselect.takeEffect() != null);
    commitPrepared(&account, &reselect);
    try std.testing.expectEqual(
        contract.CatalogState.loading,
        account.view().catalog_state,
    );
}

test "model catalog service failure parks back in choosing the same way" {
    var account = Account.initSignedOutForTest();
    var login = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = login.takeEffect();
    commitPrepared(&account, &login);
    var authorized: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var tokens = switch (account.prepareCompletion(&authorized)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = tokens.takeEffect();
    commitPrepared(&account, &tokens);
    var identity: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init(
            "account-1",
            "Metask User",
        ) },
    };
    var identified = switch (account.prepareCompletion(&identity)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = identified.takeEffect();
    commitPrepared(&account, &identified);
    var begin_catalog = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin_catalog.takeEffect();
    commitPrepared(&account, &begin_catalog);
    var keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_ready = switch (account.prepareCompletion(&keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &keys_ready);
    var select_key = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-broken"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_key.takeEffect();
    commitPrepared(&account, &select_key);

    // First setup, automatic continuation: the first key's model catalog
    // answers with a server failure (quota-exhausted backend). The key list
    // must survive so the user can re-pick a healthy key; tearing down here
    // leaves an empty selector that rejects every selection.
    var failure: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.metask_service_unavailable) },
    };
    var parked = switch (account.prepareCompletion(&failure)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(parked.takeEffect() == null);
    commitPrepared(&account, &parked);

    const view = account.view();
    try std.testing.expectEqual(
        contract.CatalogState.choosing,
        view.catalog_state,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.metask_service_unavailable,
        view.error_code,
    );
    try std.testing.expect(account.activeAttempt() != null);

    // Re-picking a key continues inside the same parked transaction.
    var reselect = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-good"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(reselect.takeEffect() != null);
    commitPrepared(&account, &reselect);
    try std.testing.expectEqual(
        contract.CatalogState.loading,
        account.view().catalog_state,
    );
}

test "failed reconfiguration preserves the committed selection" {
    const allocator = std.testing.allocator;
    var account = Account.initRestoring();
    var restored_execution = try execution_contract.OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "model-old"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
        "fixture-provider",
    );
    defer restored_execution.deinit();
    var restored = try TestSupport.prepareReady(
        &account,
        try .init("account-1", "Metask User"),
        "key-old",
        &restored_execution,
    );
    var installed = restored.takeSourceCandidate().?;
    installed.deinit();
    restored.commit(&account);
    restored.deinit();

    var refresh = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = refresh.takeEffect();
    commitPrepared(&account, &refresh);
    var keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_ready = switch (account.prepareCompletion(&keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &keys_ready);
    var select_key = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_key.takeEffect();
    commitPrepared(&account, &select_key);
    var models: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .models_loaded,
    };
    var models_ready = switch (account.prepareCompletion(&models)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &models_ready);
    var select_model = switch (account.prepareCommand(.{
        .select_model = testSelection("model-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_model.takeEffect();
    commitPrepared(&account, &select_model);
    try std.testing.expectEqual(contract.CatalogState.loading, account.view().catalog_state);
    try std.testing.expectEqualStrings("model-old", account.view().selected_model);
    try std.testing.expectEqualStrings("key-old", account.view().selected_api_key_id);
    try std.testing.expectEqualStrings("key-new", account.view().candidate_api_key_id);
    try std.testing.expectEqualStrings("model-new", account.view().candidate_model);

    var failed_completion: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .failed = try .init(
            .credential_store_write_failed,
            "persist failed",
        ) },
    };
    var failed = switch (account.prepareCompletion(&failed_completion)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(contract.CatalogState.ready, account.view().catalog_state);
    try std.testing.expectEqualStrings("model-old", account.view().selected_model);
    try std.testing.expectEqualStrings("key-old", account.view().selected_api_key_id);
    try std.testing.expectEqualStrings("", account.view().candidate_api_key_id);
    try std.testing.expectEqualStrings("", account.view().candidate_model);
    try std.testing.expectEqual(@as(u64, 9), account.sourceGeneration());

    var logout = switch (account.prepareCommand(.logout)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(
        logout.takeEffect().? == .delete_credential,
    );
    commitPrepared(&account, &logout);
    try std.testing.expect(!account.view().can_cancel);
    switch (account.prepareCommand(.cancel_operation)) {
        .rejected => |error_code| try std.testing.expectEqual(
            contract.ErrorCode.invalid_state,
            error_code,
        ),
        else => return error.TestUnexpectedResult,
    }
    var logged_out: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .logged_out,
    };
    var logout_done = switch (account.prepareCompletion(&logged_out)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(logout_done.takeEffect() == null);
    commitPrepared(&account, &logout_done);
    try std.testing.expectEqual(@as(u64, 0), account.sourceGeneration());
}

test "ready execution model selection updates the default without reconfiguration" {
    var account: Account = .{ .state = .{
        .session_state = .authenticated,
        .source_authority = .ready,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-old"),
        .selected_model = try .init("model-old"),
        .catalog_generation = 4,
        .metask_source_generation = 9,
    } };

    var select_api = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(select_api.takeEffect().? == .load_api_keys);
    commitPrepared(&account, &select_api);

    var view = account.view();
    try std.testing.expectEqual(OperationKind.loading_keys, account.state.operation());
    try std.testing.expectEqual(contract.CatalogState.loading, view.catalog_state);
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-old", view.selected_model);
    try std.testing.expectEqualStrings("key-new", view.candidate_api_key_id);
    try std.testing.expectEqualStrings("", view.candidate_model);
    try std.testing.expectEqualStrings("", view.model_catalog_api_key_id);

    var cancel = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        CatalogIntent.discard_candidate,
        cancel.catalogIntent(),
    );
    _ = cancel.takeEffect();
    commitPrepared(&account, &cancel);

    var select_model = switch (account.prepareCommand(.{
        .select_model = testSelection("model-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(select_model.takeEffect().? == .persist_default_model);
    commitPrepared(&account, &select_model);
    view = account.view();
    try std.testing.expectEqual(OperationKind.persisting_model, account.state.operation());
    try std.testing.expectEqual(contract.CatalogState.loading, view.catalog_state);
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-old", view.selected_model);
    try std.testing.expectEqualStrings("model-new", view.candidate_model);
    try std.testing.expectEqual(@as(u64, 9), account.sourceGeneration());

    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .default_model_persisted,
    };
    var completed = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        PreferenceIntent.commit_pending,
        completed.preferenceIntent(),
    );
    commitPrepared(&account, &completed);
    view = account.view();
    try std.testing.expectEqual(OperationKind.none, account.state.operation());
    try std.testing.expectEqual(contract.CatalogState.ready, view.catalog_state);
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-new", view.selected_model);
    try std.testing.expectEqual(@as(u64, 9), account.sourceGeneration());
}

test "shutdown invalidates active attempt and requires effect consumption" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);

    var shutdown = account.prepareShutdown();
    const effect = shutdown.takeEffect().?;
    try std.testing.expectEqual(account.activeAttempt(), effect.shutdown);
    shutdown.commit(&account);
    shutdown.deinit();
    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
    try std.testing.expectEqual(
        contract.ErrorCode.invalid_state,
        account.prepareCommand(.begin_login).rejected,
    );
}

test "shutdown revokes ready execution before publishing the terminal view" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .source_authority = .ready,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-1"),
        .selected_model = try .init("model-1"),
        .metask_source_generation = 3,
    } };

    var shutdown = account.prepareShutdown();
    _ = shutdown.takeEffect();
    shutdown.commit(&account);
    shutdown.deinit();

    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        view.state,
    );
    try std.testing.expectEqual(contract.CatalogState.unavailable, view.catalog_state);
    try std.testing.expectEqualStrings("", view.selected_api_key_id);
    try std.testing.expectEqualStrings("", view.selected_model);
    try std.testing.expectEqual(@as(u64, 0), account.sourceGeneration());
}

test "restore failure returns to sign-in without restart semantics" {
    var account: Account = .{};
    var prepared = switch (account.prepareSignedOutRestoreFailure(
        WorkerFailure.fromCode(.credential_store_read_failed),
    )) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &prepared);
    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        view.state,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.credential_store_read_failed,
        view.error_code,
    );
}

test "third execution preference observation preserves old recovery identity" {
    const allocator = std.testing.allocator;
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .source_authority = .ready,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-old"),
        .selected_model = try .init("model-old"),
        .metask_source_generation = 1,
    } };
    var refresh = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = refresh.takeEffect();
    commitPrepared(&account, &refresh);
    var keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_ready = switch (account.prepareCompletion(&keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &keys_ready);
    var select_key = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_key.takeEffect();
    commitPrepared(&account, &select_key);
    var models: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .models_loaded,
    };
    var models_ready = switch (account.prepareCompletion(&models)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &models_ready);
    var select_model = switch (account.prepareCommand(.{
        .select_model = testSelection("model-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_model.takeEffect();
    commitPrepared(&account, &select_model);
    var execution = try execution_contract.OwnedSourceCandidate.initOwned(
        allocator,
        .metask,
        .anthropic_messages,
        try allocator.dupe(u8, "model-new"),
        try allocator.dupe(u8, "https://example.invalid/v1/messages"),
        7,
        try allocator.dupe(u8, "secret"),
        "fixture-provider",
    );
    var completion: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .source_candidate_ready = execution.take() },
    };
    defer completion.deinit();
    var staged = switch (account.prepareCompletion(&completion)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = staged.takeEffect();
    var staged_execution = staged.takeSourceCandidate().?;
    staged_execution.deinit();
    commitPrepared(&account, &staged);
    var unknown = switch (account.prepareSourcePreferencePersistenceInvalid()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &unknown);

    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountState.authenticated,
        view.state,
    );
    try std.testing.expectEqual(
        contract.CatalogState.failed,
        view.catalog_state,
    );
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-old", view.selected_model);

    switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-old"),
    })) {
        .rejected => |code| try std.testing.expectEqual(
            contract.ErrorCode.invalid_state,
            code,
        ),
        else => return error.TestUnexpectedResult,
    }
    switch (account.prepareCommand(.{
        .select_model = testSelection("model-old"),
    })) {
        .rejected => |code| try std.testing.expectEqual(
            contract.ErrorCode.invalid_state,
            code,
        ),
        else => return error.TestUnexpectedResult,
    }
    switch (account.prepareCommand(.resolve_metask_source)) {
        .rejected => |code| try std.testing.expectEqual(
            contract.ErrorCode.invalid_state,
            code,
        ),
        else => return error.TestUnexpectedResult,
    }

    var token_account = account;
    var token_refresh = switch (token_account.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(token_refresh.takeEffect().? == .refresh_token);
    commitPrepared(&token_account, &token_refresh);

    var logout_account = account;
    var logout = switch (logout_account.prepareCommand(.logout)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(logout.takeEffect().? == .delete_credential);
    commitPrepared(&logout_account, &logout);

    var recovery_refresh = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(recovery_refresh.takeEffect().? == .load_api_keys);
    commitPrepared(&account, &recovery_refresh);
    var recovered_keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var load_recovery_models = switch (account.prepareCompletion(&recovered_keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(load_recovery_models.takeEffect().? == .load_models);
    commitPrepared(&account, &load_recovery_models);
    var recovered_models: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .models_loaded,
    };
    var recovery_done = switch (account.prepareCompletion(&recovered_models)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        CatalogIntent.promote_candidate,
        recovery_done.catalogIntent(),
    );
    try std.testing.expect(recovery_done.takeEffect() == null);
    try std.testing.expect(recovery_done.takeSourceCandidate() == null);
    commitPrepared(&account, &recovery_done);
    try std.testing.expectEqual(
        contract.ErrorCode.recovery_state_invalid,
        account.view().error_code,
    );
}

test "preference recovery permits an explicit relogin" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .source_authority = .recovery,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-1"),
        .selected_model = try .init("model-1"),
        .metask_source_generation = 1,
        .error_code = .recovery_state_invalid,
    } };

    var login = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer login.deinit();
    try std.testing.expect(login.takeEffect().? == .begin_oauth);
    login.commit(&account);
    try std.testing.expectEqual(contract.AccountState.authorizing, account.view().state);
}

test "login commits account-only before a separate catalog generation" {
    const allocator = std.testing.allocator;
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);

    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var identity_request = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = identity_request.takeEffect();
    commitPrepared(&account, &identity_request);
    var identified: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init(
            "account-1",
            "Metask User",
        ) },
    };
    var auth_transition = switch (account.prepareCompletion(&identified)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &auth_transition);
    try std.testing.expectEqual(OperationKind.none, account.state.operation());
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());

    var begin_catalog = switch (account.prepareCommand(.refresh_catalog)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin_catalog.takeEffect();
    commitPrepared(&account, &begin_catalog);

    var keys: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_transition = switch (account.prepareCompletion(&keys)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &keys_transition);

    var select_key = switch (account.prepareCommand(.{
        .select_api_key = testSelection("key-1"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_key.takeEffect();
    commitPrepared(&account, &select_key);

    var models: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .models_loaded,
    };
    var models_transition = switch (account.prepareCompletion(&models)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &models_transition);

    var select_model = switch (account.prepareCommand(.{
        .select_model = testSelection("model-1"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = select_model.takeEffect();
    commitPrepared(&account, &select_model);

    const model = try allocator.dupe(u8, "model-1");
    const base_url = try allocator.dupe(
        u8,
        contract.metask_anthropic_messages_url,
    );
    const secret = try allocator.dupe(u8, "secret");
    var ready: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .source_candidate_ready = try .initOwned(
            allocator,
            .metask,
            .anthropic_messages,
            model,
            base_url,
            0x9e37_79b9_7f4a_7c15,
            secret,
            "key-1",
        ) },
    };
    var ready_transition = switch (account.prepareCompletion(&ready)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var execution = ready_transition.takeSourceCandidate().?;
    defer execution.deinit();
    _ = ready_transition.takeEffect();
    ready_transition.commit(&account);
    ready_transition.deinit();

    var source_preference_persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .source_preference_persisted,
    };
    var persisted_transition = switch (account.prepareCompletion(&source_preference_persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    persisted_transition.commit(&account);
    persisted_transition.deinit();

    const view = account.view();
    try std.testing.expectEqual(contract.AccountState.authenticated, view.state);
    try std.testing.expectEqual(contract.CatalogState.ready, view.catalog_state);
    try std.testing.expectEqual(@as(u64, 2), view.catalog_generation);
    try std.testing.expectEqual(
        @as(u64, 0x9e37_79b9_7f4a_7c15),
        account.sourceGeneration(),
    );
    try std.testing.expectEqualStrings("model-1", view.selected_model);
}

test "cancel invalidates attempt and stale secret completion is destroyed" {
    const ObservingAllocator = struct {
        backing: std.mem.Allocator,
        secret_ptr: ?[*]u8 = null,
        secret_len: usize = 0,
        saw_secret_free: bool = false,
        secret_was_zero: bool = false,

        const Self = @This();
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn alloc(
            raw: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(
            raw: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(
            raw: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(
            raw: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.secret_ptr) |secret_ptr| {
                if (memory.ptr == secret_ptr and memory.len == self.secret_len) {
                    self.saw_secret_free = true;
                    self.secret_was_zero = true;
                    for (memory) |byte| {
                        if (byte != 0) self.secret_was_zero = false;
                    }
                }
            }
            self.backing.rawFree(memory, alignment, ret_addr);
        }
    };

    var observing: ObservingAllocator = .{
        .backing = std.testing.allocator,
    };
    const allocator = observing.allocator();
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);
    const stale_attempt = account.activeAttempt().?;

    var cancel = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = cancel.takeEffect();
    commitPrepared(&account, &cancel);

    const model = try allocator.dupe(u8, "model");
    const base_url = try allocator.dupe(
        u8,
        contract.metask_anthropic_messages_url,
    );
    const secret = try allocator.dupe(u8, "secret-that-must-be-zero");
    observing.secret_ptr = secret.ptr;
    observing.secret_len = secret.len;
    var stale: WorkerCompletion = .{
        .attempt_id = stale_attempt,
        .payload = .{ .source_candidate_ready = try .initOwned(
            allocator,
            .metask,
            .anthropic_messages,
            model,
            base_url,
            1,
            secret,
            "key-1",
        ) },
    };
    switch (account.prepareCompletion(&stale)) {
        .ignored_stale => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
}
