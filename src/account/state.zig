const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");

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

const ExecutionState = enum {
    none,
    preparing,
    ready,
    reconfiguring,
    invalid,
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
    prepare_execution: ModelId,
    cancel_attempt: u64,
    delete_credential,
    shutdown: ?u64,

    pub fn argument(self: *const Effect) ?[]const u8 {
        return switch (self.*) {
            .load_models => |*id| id.view(),
            .prepare_execution => |*model| model.view(),
            else => null,
        };
    }
};

const AttemptKind = enum {
    none,
    login,
    refresh_token,
    catalog,
    logout,
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
    execution_state: ExecutionState = .none,
    operation: OperationKind = .none,
    account_id: AccountId = .{},
    display_name: DisplayName = .{},
    selected_api_key_id: ApiKeyId = .{},
    selected_model: ModelId = .{},
    pending_api_key_id: ApiKeyId = .{},
    pending_model: ModelId = .{},
    error_code: contract.ErrorCode = .none,
    safe_diagnostic: SafeDiagnostic = .{},
    catalog_generation: u64 = 0,
    execution_generation: u64 = 0,
    active_attempt_id: ?u64 = null,
    attempt_kind: AttemptKind = .none,
    next_attempt_id: u64 = 1,

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
        else switch (self.operation) {
            .selecting_key, .selecting_model => .choosing,
            .loading_keys, .loading_models, .persisting => .loading,
            .none, .token_exchange, .loading_identity => if (self.execution_state == .ready)
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
            .candidate_api_key_id = if (publish_account) self.pending_api_key_id.view() else "",
            .candidate_model = if (publish_account) self.pending_model.view() else "",
            .model_catalog_api_key_id = if (!publish_account) "" else switch (self.operation) {
                .selecting_model, .persisting => self.pending_api_key_id.view(),
                .loading_models => self.pending_api_key_id.view(),
                .loading_keys => if (self.execution_state == .ready)
                    self.selected_api_key_id.view()
                else
                    "",
                .selecting_key => "",
                .logging_out => "",
                else => self.selected_api_key_id.view(),
            },
            .can_create_task = state == .authenticated and
                catalog_state == .ready and self.execution_state == .ready and
                self.attempt_kind != .catalog and
                self.operation != .logging_out,
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
            .execution_generation = if (publish_account) self.execution_generation else 0,
        };
    }

    fn clearError(self: *CommittedState) void {
        self.error_code = .none;
        self.safe_diagnostic.clear();
    }

    fn canCancelOperation(self: *const CommittedState) bool {
        if (self.active_attempt_id == null) return false;
        return switch (self.attempt_kind) {
            .login => self.session_state == .authorizing and
                self.operation == .oauth_callback,
            .catalog => self.session_state == .authenticated and switch (self.operation) {
                .loading_keys, .selecting_key, .loading_models, .selecting_model => true,
                else => false,
            },
            .refresh_token, .logout, .none => false,
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
        return self.state.active_attempt_id;
    }

    pub fn refreshInFlight(self: *const Account) bool {
        return self.state.attempt_kind == .refresh_token;
    }

    pub fn catalogAttemptActive(self: *const Account) bool {
        return self.state.attempt_kind == .catalog;
    }

    pub fn credentialValidationInFlight(self: *const Account) bool {
        return self.state.attempt_kind == .login or
            self.state.attempt_kind == .refresh_token;
    }

    pub fn currentIdentity(self: *const Account) ?AccountIdentity {
        if (self.state.account_id.len == 0) return null;
        return .{
            .account_id = self.state.account_id,
            .display_name = self.state.display_name,
        };
    }

    pub fn candidateCatalogActive(self: *const Account) bool {
        return switch (self.state.operation) {
            .selecting_key, .loading_models, .selecting_model, .persisting => true,
            else => false,
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

    /// A preference rename whose outcome cannot be observed invalidates the
    /// in-process default execution until the next startup.
    pub fn prepareExecutionPersistenceUnknown(
        self: *const Account,
    ) PrepareResult {
        if (self.state.attempt_kind != .catalog or
            self.state.operation != .persisting or
            self.state.active_attempt_id == null or
            (self.state.execution_state != .preparing and
                self.state.execution_state != .reconfiguring))
            return .{ .rejected = .invalid_state };
        const attempt_id = self.state.active_attempt_id.?;
        var next = self.state;
        next.session_state = .shutting_down;
        next.execution_state = .none;
        next.operation = .none;
        next.selected_api_key_id.clear();
        next.selected_model.clear();
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.execution_generation = 0;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.error_code = .recovery_state_invalid;
        next.safe_diagnostic.clear();
        return transitionNoEffect(
            next,
            .operation_failed,
            attempt_id,
        );
    }

    pub fn prepareTokenRefresh(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.operation != .none or
            self.state.active_attempt_id != null)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .refreshing;
        next.operation = .token_exchange;
        next.active_attempt_id = attempt.current;
        next.attempt_kind = .refresh_token;
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
            self.state.operation != .none or
            self.state.active_attempt_id != null)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .refreshing;
        next.operation = .token_exchange;
        next.active_attempt_id = attempt.current;
        next.attempt_kind = .refresh_token;
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
        if (self.state.active_attempt_id == null or
            self.state.active_attempt_id.? != completion.attempt_id)
        {
            completion.deinit();
            return .ignored_stale;
        }

        const result = switch (completion.payload) {
            .identity_loaded => |identity| self.prepareIdentityLoaded(identity),
            .tokens_persisted => self.prepareTokensPersisted(),
            .api_keys_loaded => self.prepareApiKeysLoaded(),
            .models_loaded => self.prepareModelsLoaded(),
            .execution_ready => self.prepareExecutionReady(completion),
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
        next.execution_state = .none;
        next.operation = .none;
        next.selected_api_key_id.clear();
        next.selected_model.clear();
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.execution_generation = 0;
        next.clearError();
        const active_attempt = next.active_attempt_id;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        return .{
            .next = next,
            .fact_kind = .session_changed,
            .attempt_id = active_attempt,
            .effect = .{ .shutdown = active_attempt },
            .identity_replacement_boundary = switch (self.state.attempt_kind) {
                .login, .logout => .clear_default,
                else => .none,
            },
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
            self.state.execution_state != .none or
            self.state.operation != .none or
            self.state.active_attempt_id != null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.error_code = error_code;
        next.safe_diagnostic.clear();
        return transitionNoAttempt(next, .operation_failed);
    }

    fn prepareBeginLogin(self: *const Account) PrepareResult {
        if ((self.state.session_state != .signed_out and
            self.state.session_state != .authenticated) or
            self.state.operation != .none)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .authorizing;
        next.operation = .oauth_callback;
        next.active_attempt_id = attempt.current;
        next.attempt_kind = .login;
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .begin_oauth);
    }

    fn prepareCancel(self: *const Account) PrepareResult {
        if (!self.state.canCancelOperation())
            return .{ .rejected = .invalid_state };
        const attempt = self.state.active_attempt_id orelse
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = switch (next.attempt_kind) {
            .login => if (next.account_id.len == 0) .signed_out else .authenticated,
            .refresh_token => .authenticated,
            .catalog => .authenticated,
            .logout, .none => next.session_state,
        };
        if (next.execution_state == .preparing)
            next.execution_state = .none;
        if (next.execution_state == .reconfiguring)
            next.execution_state = .ready;
        next.operation = .none;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.error_code = .user_cancelled;
        next.safe_diagnostic.clear();
        var result = transition(
            next,
            .operation_failed,
            attempt,
            .{ .cancel_attempt = attempt },
        );
        result.transition.identity_replacement_boundary =
            switch (self.state.attempt_kind) {
                .login, .logout => .preserve_default,
                else => .none,
            };
        return result;
    }

    fn prepareRefreshCatalog(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.operation != .none)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.operation = .loading_keys;
        next.active_attempt_id = attempt.current;
        next.attempt_kind = .catalog;
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .load_api_keys);
    }

    fn prepareSelectApiKey(self: *const Account, id: []const u8) PrepareResult {
        if (self.state.session_state != .authenticated)
            return .{ .rejected = .invalid_state };
        if (self.state.operation == .none and
            self.state.execution_state == .ready)
        {
            const attempt = nextAttempt(self.state.next_attempt_id) orelse
                return .{ .rejected = .generation_mismatch };
            var next = self.state;
            next.pending_api_key_id.set(id) catch
                return .{ .rejected = .invalid_command };
            next.pending_model.clear();
            next.operation = .loading_keys;
            next.active_attempt_id = attempt.current;
            next.attempt_kind = .catalog;
            next.next_attempt_id = attempt.next;
            next.clearError();
            return transition(
                next,
                .session_changed,
                attempt.current,
                .load_api_keys,
            );
        }
        if (self.state.operation != .selecting_key or
            self.state.active_attempt_id == null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.pending_api_key_id.set(id) catch
            return .{ .rejected = .invalid_command };
        next.operation = .loading_models;
        next.clearError();
        const effect_id = ApiKeyId.init(id) catch
            return .{ .rejected = .invalid_command };
        return transition(
            next,
            .session_changed,
            next.active_attempt_id.?,
            .{ .load_models = effect_id },
        );
    }

    fn prepareSelectModel(self: *const Account, model: []const u8) PrepareResult {
        if (self.state.session_state != .authenticated)
            return .{ .rejected = .invalid_state };
        if (self.state.operation == .none and
            self.state.execution_state == .ready)
        {
            const attempt = nextAttempt(self.state.next_attempt_id) orelse
                return .{ .rejected = .generation_mismatch };
            var next = self.state;
            next.pending_api_key_id = next.selected_api_key_id;
            next.pending_model.set(model) catch
                return .{ .rejected = .invalid_command };
            next.operation = .loading_keys;
            next.active_attempt_id = attempt.current;
            next.attempt_kind = .catalog;
            next.next_attempt_id = attempt.next;
            next.clearError();
            return transition(
                next,
                .session_changed,
                attempt.current,
                .load_api_keys,
            );
        }
        if (self.state.operation != .selecting_model or
            self.state.active_attempt_id == null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        if (next.execution_state == .ready and
            std.mem.eql(
                u8,
                next.pending_api_key_id.view(),
                next.selected_api_key_id.view(),
            ) and
            std.mem.eql(u8, model, next.selected_model.view()))
        {
            next.operation = .none;
            next.active_attempt_id = null;
            next.attempt_kind = .none;
            next.pending_api_key_id.clear();
            next.pending_model.clear();
            next.clearError();
            return transitionNoEffect(
                next,
                .catalog_changed,
                self.state.active_attempt_id.?,
            );
        }
        next.pending_model.set(model) catch
            return .{ .rejected = .invalid_command };
        next.execution_state = if (next.execution_state == .ready)
            .reconfiguring
        else
            .preparing;
        next.operation = .persisting;
        next.clearError();
        const effect_model = ModelId.init(model) catch
            return .{ .rejected = .invalid_command };
        return transition(
            next,
            .execution_changed,
            next.active_attempt_id.?,
            .{ .prepare_execution = effect_model },
        );
    }

    fn prepareLogout(self: *const Account) PrepareResult {
        if (self.state.operation != .none or
            self.state.session_state != .authenticated)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.operation = .logging_out;
        next.active_attempt_id = attempt.current;
        next.attempt_kind = .logout;
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
        if (self.state.operation != .loading_identity or
            (self.state.attempt_kind != .login and
                self.state.attempt_kind != .refresh_token))
            return .{ .rejected = .invalid_state };
        if (self.state.attempt_kind == .refresh_token and
            self.state.account_id.len != 0 and !std.mem.eql(
            u8,
            identity.accountId(),
            self.state.account_id.view(),
        )) return .{ .rejected = .metask_unauthorized };
        var next = self.state;
        next.session_state = .authenticated;
        if (next.attempt_kind == .login) {
            next.execution_state = .none;
            next.selected_api_key_id.clear();
            next.selected_model.clear();
            next.execution_generation = 0;
        }
        next.operation = .none;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.account_id = identity.account_id;
        next.display_name = identity.display_name;
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.clearError();
        var result = transitionNoEffect(
            next,
            .session_changed,
            self.state.active_attempt_id.?,
        );
        if (self.state.attempt_kind == .login)
            result.transition.identity_replacement_boundary = .clear_default;
        return result;
    }

    fn prepareTokensPersisted(self: *const Account) PrepareResult {
        if ((self.state.attempt_kind != .login or
            self.state.operation != .oauth_callback) and
            (self.state.attempt_kind != .refresh_token or
                self.state.operation != .token_exchange))
            return .{ .rejected = .invalid_state };
        var next = self.state;
        if (next.attempt_kind == .login or next.account_id.len == 0) {
            next.operation = .loading_identity;
            next.clearError();
            return transition(
                next,
                .session_changed,
                self.state.active_attempt_id.?,
                .load_identity,
            );
        }
        next.session_state = .authenticated;
        next.operation = .none;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.clearError();
        return transitionNoEffect(
            next,
            .session_changed,
            self.state.active_attempt_id.?,
        );
    }

    fn prepareApiKeysLoaded(self: *const Account) PrepareResult {
        if (self.state.operation != .loading_keys or
            self.state.attempt_kind != .catalog)
            return .{ .rejected = .invalid_state };
        const generation = incrementGeneration(self.state.catalog_generation) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.catalog_generation = generation;
        if (next.pending_api_key_id.len != 0) {
            next.operation = .loading_models;
            next.clearError();
            const effect_id = ApiKeyId.init(next.pending_api_key_id.view()) catch
                return .{ .rejected = .invalid_command };
            return transition(
                next,
                .catalog_changed,
                next.active_attempt_id.?,
                .{ .load_models = effect_id },
            );
        }
        next.operation = .selecting_key;
        next.clearError();
        return transitionNoEffect(next, .catalog_changed, next.active_attempt_id.?);
    }

    fn prepareModelsLoaded(self: *const Account) PrepareResult {
        if (self.state.operation != .loading_models or
            self.state.attempt_kind != .catalog)
            return .{ .rejected = .invalid_state };
        const generation = incrementGeneration(self.state.catalog_generation) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.catalog_generation = generation;
        if (next.pending_model.len != 0) {
            next.execution_state = if (next.execution_generation == 0)
                .preparing
            else
                .reconfiguring;
            next.operation = .persisting;
            next.clearError();
            const effect_model = ModelId.init(next.pending_model.view()) catch
                return .{ .rejected = .invalid_command };
            return transition(
                next,
                .execution_changed,
                next.active_attempt_id.?,
                .{ .prepare_execution = effect_model },
            );
        }
        next.operation = .selecting_model;
        next.clearError();
        return transitionNoEffect(next, .catalog_changed, next.active_attempt_id.?);
    }

    fn prepareExecutionReady(
        self: *const Account,
        completion: *WorkerCompletion,
    ) PrepareResult {
        if (self.state.operation != .persisting or
            self.state.attempt_kind != .catalog)
            return .{ .rejected = .invalid_state };
        var execution = switch (completion.payload) {
            .execution_ready => |*owned| owned.take(),
            else => unreachable,
        };
        const input = execution.input();
        if (input.execution_generation == 0 or
            !std.mem.eql(u8, input.target.model, self.state.pending_model.view()) or
            self.state.pending_api_key_id.len == 0)
        {
            execution.deinit();
            completion.payload = dependencyFailure();
            return .{ .rejected = .generation_mismatch };
        }

        var next = self.state;
        next.execution_state = .ready;
        next.operation = .none;
        next.execution_generation = input.execution_generation;
        next.selected_api_key_id = next.pending_api_key_id;
        next.selected_model = next.pending_model;
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.clearError();
        completion.payload = dependencyFailure();
        return .{ .transition = .{
            .next = next,
            .fact_kind = .execution_changed,
            .attempt_id = completion.attempt_id,
            .execution = execution,
        } };
    }

    fn prepareLoggedOut(self: *const Account) PrepareResult {
        if (self.state.operation != .logging_out or
            self.state.attempt_kind != .logout)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = .signed_out;
        next.execution_state = .none;
        next.operation = .none;
        next.account_id.clear();
        next.display_name.clear();
        next.selected_api_key_id.clear();
        next.selected_model.clear();
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.catalog_generation = 0;
        next.execution_generation = 0;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.clearError();
        var result = transitionNoEffect(
            next,
            .signed_out,
            self.state.active_attempt_id.?,
        );
        result.transition.identity_replacement_boundary = .clear_default;
        return result;
    }

    fn prepareFailure(
        self: *const Account,
        failure: WorkerFailure,
    ) PrepareResult {
        const normalized_failure = if (failure.error_code == .none)
            WorkerFailure.fromCode(.dependency_contract_invalid)
        else
            failure;
        const login_replaced = self.state.attempt_kind == .login and
            self.state.operation == .loading_identity;
        var next = self.state;
        next.session_state = switch (next.attempt_kind) {
            .login => if (login_replaced or next.account_id.len == 0)
                .signed_out
            else
                .authenticated,
            .refresh_token => if (next.account_id.len == 0)
                .signed_out
            else
                .authenticated,
            .catalog, .logout, .none => next.session_state,
        };
        const authentication_invalid = self.state.attempt_kind == .refresh_token and
            (normalized_failure.error_code == .metask_unauthorized or
                normalized_failure.error_code == .credential_store_delete_failed);
        if (authentication_invalid or login_replaced or
            (self.state.attempt_kind == .login and
                self.state.account_id.len == 0))
        {
            next.session_state = .signed_out;
            next.execution_state = .none;
            next.account_id.clear();
            next.display_name.clear();
            next.selected_api_key_id.clear();
            next.selected_model.clear();
            next.catalog_generation = 0;
            next.execution_generation = 0;
        }
        if (next.execution_state == .preparing)
            next.execution_state = .none;
        if (next.execution_state == .reconfiguring)
            next.execution_state = .ready;
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.operation = .none;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.error_code = normalized_failure.error_code;
        next.safe_diagnostic = normalized_failure.safe_diagnostic;
        var result = transitionNoEffect(
            next,
            .operation_failed,
            self.state.active_attempt_id.?,
        );
        result.transition.identity_replacement_boundary =
            switch (self.state.attempt_kind) {
                .login => if (login_replaced)
                    .clear_default
                else
                    .preserve_default,
                .logout => .preserve_default,
                else => .none,
            };
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

fn incrementGeneration(current: u64) ?u64 {
    if (current == std.math.maxInt(u64)) return null;
    return current + 1;
}

fn dependencyFailure() WorkerCompletion.Payload {
    return .{ .failed = .{
        .error_code = .dependency_contract_invalid,
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
    if ((state.active_attempt_id == null) != (state.attempt_kind == .none))
        return false;
    if (state.active_attempt_id == null and state.operation != .none)
        return false;
    if (state.active_attempt_id != null and state.operation == .none)
        return false;

    switch (state.session_state) {
        .restoring, .signed_out, .shutting_down => {
            if (state.operation != .none) return false;
        },
        .authorizing => {
            if (state.operation != .oauth_callback and
                state.operation != .loading_identity)
                return false;
            if (state.attempt_kind != .login) return false;
        },
        .refreshing => {
            if ((state.operation != .token_exchange and
                state.operation != .loading_identity) or
                state.attempt_kind != .refresh_token)
                return false;
        },
        .authenticated => {},
    }

    switch (state.execution_state) {
        .none => {
            if (state.execution_generation != 0 or
                state.selected_api_key_id.len != 0 or
                state.selected_model.len != 0)
                return false;
        },
        .preparing => {
            if (state.operation != .persisting) return false;
            if (state.pending_api_key_id.len == 0 or
                state.pending_model.len == 0)
                return false;
            if (state.execution_generation != 0) return false;
        },
        .reconfiguring => {
            if (state.operation != .persisting) return false;
            if (state.pending_api_key_id.len == 0 or
                state.pending_model.len == 0)
                return false;
            if (state.execution_generation == 0 or
                state.selected_api_key_id.len == 0 or
                state.selected_model.len == 0)
                return false;
        },
        .ready => {
            if (state.execution_generation == 0 or
                state.selected_api_key_id.len == 0 or
                state.selected_model.len == 0)
                return false;
        },
        .invalid => {
            if (state.operation != .none) return false;
        },
    }
    return true;
}

pub const PrepareResult = union(enum) {
    transition: PreparedTransition,
    rejected: contract.ErrorCode,
    ignored_stale,
};

pub const PreparedTransition = struct {
    next: CommittedState,
    fact_kind: contract.AccountFactKind,
    attempt_id: ?u64,
    effect: ?Effect = null,
    execution: ?contract.OwnedExecutionConfig = null,
    identity_replacement_boundary: IdentityReplacementBoundary = .none,
    committed: bool = false,

    pub fn fact(self: *const PreparedTransition) contract.AccountFact {
        return .{
            .kind = self.fact_kind,
            .view = self.next.view(),
        };
    }

    pub fn candidateCatalogActive(self: *const PreparedTransition) bool {
        return switch (self.next.operation) {
            .selecting_key, .loading_models, .selecting_model, .persisting => true,
            else => false,
        };
    }

    pub fn operationComplete(self: *const PreparedTransition) bool {
        return self.next.operation == .none;
    }

    pub fn identityReplacementBoundary(
        self: *const PreparedTransition,
    ) IdentityReplacementBoundary {
        return self.identity_replacement_boundary;
    }

    pub fn clearsDefaultExecution(self: *const PreparedTransition) bool {
        return self.next.operation == .none and self.next.execution_state == .none;
    }

    pub fn takeExecution(
        self: *PreparedTransition,
    ) ?contract.OwnedExecutionConfig {
        if (self.execution) |*execution| {
            const result = execution.take();
            self.execution = null;
            return result;
        }
        return null;
    }

    pub fn takeEffect(self: *PreparedTransition) ?Effect {
        const effect = self.effect;
        self.effect = null;
        return effect;
    }

    pub fn commit(self: *PreparedTransition, account: *Account) void {
        std.debug.assert(!self.committed);
        std.debug.assert(self.execution == null);
        std.debug.assert(stateIsValid(&self.next));
        account.state = self.next;
        self.committed = true;
    }

    pub fn deinit(self: *PreparedTransition) void {
        if (self.committed) std.debug.assert(self.effect == null);
        if (self.execution) |*execution| execution.deinit();
        self.execution = null;
    }
};

pub const IdentityReplacementBoundary = enum {
    none,
    preserve_default,
    clear_default,
};

pub const TestSupport = if (builtin.is_test) struct {
    pub fn prepareReady(
        account: *const Account,
        identity: AccountIdentity,
        api_key_id: []const u8,
        execution_value: *contract.OwnedExecutionConfig,
    ) !PreparedTransition {
        if (account.state.session_state != .restoring or api_key_id.len == 0)
            return error.InvalidState;
        var execution = execution_value.take();
        errdefer execution.deinit();
        const input = execution.input();
        if (input.execution_generation == 0) return error.InvalidGeneration;
        var next = account.state;
        next.session_state = .authenticated;
        next.execution_state = .ready;
        next.account_id = identity.account_id;
        next.display_name = identity.display_name;
        next.selected_api_key_id = try ApiKeyId.init(api_key_id);
        try next.selected_model.set(input.target.model);
        next.execution_generation = input.execution_generation;
        next.clearError();
        return .{
            .next = next,
            .fact_kind = .restored,
            .attempt_id = null,
            .execution = execution,
        };
    }

    pub fn installInitialExecutionPreparation(
        account: *Account,
        api_key_id: []const u8,
        model_id: []const u8,
    ) void {
        var next: CommittedState = .{
            .session_state = .authenticated,
            .execution_state = .preparing,
            .operation = .persisting,
            .catalog_generation = 1,
            .active_attempt_id = 1,
            .attempt_kind = .catalog,
            .next_attempt_id = 2,
        };
        next.account_id.set("account-1") catch unreachable;
        next.display_name.set("Metask User") catch unreachable;
        next.pending_api_key_id.set(api_key_id) catch unreachable;
        next.pending_model.set(model_id) catch unreachable;
        std.debug.assert(stateIsValid(&next));
        account.state = next;
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
        execution_ready: contract.OwnedExecutionConfig,
        logged_out,
        failed: WorkerFailure,
    };

    pub fn deinit(self: *WorkerCompletion) void {
        switch (self.payload) {
            .execution_ready => |*execution| execution.deinit(),
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
        .expected_execution_generation = 0,
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
    try std.testing.expectEqual(contract.AccountState.authorizing, prepared.fact().view.state);
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
                .prepare_execution,
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
        .prepare_execution = try .init("model-1"),
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
    try std.testing.expectEqual(
        IdentityReplacementBoundary.clear_default,
        completed.identityReplacementBoundary(),
    );
    commitPrepared(&account, &completed);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-2", account.view().account_id);
    try std.testing.expectEqualStrings("Other User", account.view().display_name);
    try std.testing.expectEqual(@as(u64, 0), account.view().execution_generation);
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
    try std.testing.expectEqual(
        IdentityReplacementBoundary.preserve_default,
        failed.identityReplacementBoundary(),
    );
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

test "failed reconfiguration preserves the committed selection" {
    const allocator = std.testing.allocator;
    var account = Account.initRestoring();
    var restored_execution = try contract.OwnedExecutionConfig.initOwned(
        allocator,
        .anthropic,
        try allocator.dupe(u8, "model-old"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
    );
    defer restored_execution.deinit();
    var restored = try TestSupport.prepareReady(
        &account,
        try .init("account-1", "Metask User"),
        "key-old",
        &restored_execution,
    );
    var installed = restored.takeExecution().?;
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
    try std.testing.expectEqual(@as(u64, 9), account.view().execution_generation);

    var logout = switch (account.prepareCommand(.logout)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(
        logout.takeEffect().? == .delete_credential,
    );
    commitPrepared(&account, &logout);
    try std.testing.expect(!account.view().can_create_task);
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
    try std.testing.expectEqual(@as(u64, 0), account.view().execution_generation);
}

test "ready execution reloads authenticated catalog before reconfiguration" {
    var account: Account = .{ .state = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .operation = .none,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-old"),
        .selected_model = try .init("model-old"),
        .catalog_generation = 4,
        .execution_generation = 9,
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
    try std.testing.expectEqual(OperationKind.loading_keys, account.state.operation);
    try std.testing.expectEqual(contract.CatalogState.loading, view.catalog_state);
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-old", view.selected_model);
    try std.testing.expectEqualStrings("key-new", view.candidate_api_key_id);
    try std.testing.expectEqualStrings("", view.candidate_model);
    try std.testing.expectEqualStrings("key-old", view.model_catalog_api_key_id);
    try std.testing.expect(!view.can_create_task);

    var cancel = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = cancel.takeEffect();
    commitPrepared(&account, &cancel);

    var select_model = switch (account.prepareCommand(.{
        .select_model = testSelection("model-new"),
    })) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(select_model.takeEffect().? == .load_api_keys);
    commitPrepared(&account, &select_model);
    view = account.view();
    try std.testing.expectEqualStrings("key-old", view.candidate_api_key_id);
    try std.testing.expectEqualStrings("model-new", view.candidate_model);

    var keys_loaded: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .api_keys_loaded,
    };
    var keys_ready = switch (account.prepareCompletion(&keys_loaded)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const models_effect = keys_ready.takeEffect();
    try std.testing.expectEqualStrings(
        "key-old",
        models_effect.?.load_models.view(),
    );
    commitPrepared(&account, &keys_ready);

    var models_loaded: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .models_loaded,
    };
    var models_ready = switch (account.prepareCompletion(&models_loaded)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const model_effect = models_ready.takeEffect();
    try std.testing.expectEqualStrings(
        "model-new",
        model_effect.?.prepare_execution.view(),
    );
    commitPrepared(&account, &models_ready);

    view = account.view();
    try std.testing.expectEqual(OperationKind.persisting, account.state.operation);
    try std.testing.expectEqual(contract.CatalogState.loading, view.catalog_state);
    try std.testing.expectEqualStrings("key-old", view.selected_api_key_id);
    try std.testing.expectEqualStrings("model-old", view.selected_model);
    try std.testing.expectEqualStrings("key-old", view.candidate_api_key_id);
    try std.testing.expectEqualStrings("model-new", view.candidate_model);
    try std.testing.expectEqualStrings("key-old", view.model_catalog_api_key_id);
    try std.testing.expect(!view.can_create_task);
    try std.testing.expect(!view.can_cancel);
    switch (account.prepareCommand(.cancel_operation)) {
        .rejected => |error_code| try std.testing.expectEqual(
            contract.ErrorCode.invalid_state,
            error_code,
        ),
        else => return error.TestUnexpectedResult,
    }
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
        .execution_state = .ready,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-1"),
        .selected_model = try .init("model-1"),
        .execution_generation = 3,
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
    try std.testing.expectEqual(@as(u64, 0), view.execution_generation);
    try std.testing.expect(!view.can_create_task);
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

test "unknown execution persistence outcome clears old runtime identity" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .account_id = try .init("account-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-old"),
        .selected_model = try .init("model-old"),
        .execution_generation = 1,
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
    var unknown = switch (account.prepareExecutionPersistenceUnknown()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &unknown);

    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountState.signed_out,
        view.state,
    );
    try std.testing.expectEqual(
        contract.CatalogState.unavailable,
        view.catalog_state,
    );
    try std.testing.expectEqualStrings("", view.selected_api_key_id);
    try std.testing.expectEqualStrings("", view.selected_model);
    try std.testing.expect(!view.can_create_task);
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
    try std.testing.expectEqual(OperationKind.none, account.state.operation);
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
        .payload = .{ .execution_ready = try .initOwned(
            allocator,
            .anthropic,
            model,
            base_url,
            0x9e37_79b9_7f4a_7c15,
            secret,
        ) },
    };
    var ready_transition = switch (account.prepareCompletion(&ready)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var execution = ready_transition.takeExecution().?;
    defer execution.deinit();
    ready_transition.commit(&account);
    ready_transition.deinit();

    const view = account.view();
    try std.testing.expectEqual(contract.AccountState.authenticated, view.state);
    try std.testing.expectEqual(contract.CatalogState.ready, view.catalog_state);
    try std.testing.expectEqual(@as(u64, 2), view.catalog_generation);
    try std.testing.expectEqual(
        @as(u64, 0x9e37_79b9_7f4a_7c15),
        view.execution_generation,
    );
    try std.testing.expectEqualStrings("model-1", view.selected_model);
    try std.testing.expect(view.can_create_task);
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
        .payload = .{ .execution_ready = try .initOwned(
            allocator,
            .anthropic,
            model,
            base_url,
            1,
            secret,
        ) },
    };
    switch (account.prepareCompletion(&stale)) {
        .ignored_stale => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(observing.saw_secret_free);
    try std.testing.expect(observing.secret_was_zero);
}
