const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");

const AccountId = BoundedString(contract.Limits.account_id_bytes);
const ProfileId = BoundedString(contract.Limits.profile_id_bytes);
const DisplayName = BoundedString(contract.Limits.display_name_bytes);
const ApiKeyId = BoundedString(contract.Limits.api_key_id_bytes);
const ModelId = BoundedString(contract.Limits.model_id_bytes);
const SafeDiagnostic = BoundedString(contract.Limits.safe_diagnostic_bytes);

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
    reopen_oauth,
    refresh_token,
    load_api_keys,
    load_models: ApiKeyId,
    prepare_execution: ModelId,
    cancel_attempt: u64,
    persist_signed_out_tombstone,
    delete_retired_credentials,
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
    reauthenticate,
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
    session_state: contract.AccountSessionState = .restoring,
    execution_state: contract.ExecutionState = .none,
    operation: contract.OperationKind = .none,
    account_id: AccountId = .{},
    profile_id: ProfileId = .{},
    display_name: DisplayName = .{},
    selected_api_key_id: ApiKeyId = .{},
    selected_model: ModelId = .{},
    pending_api_key_id: ApiKeyId = .{},
    pending_model: ModelId = .{},
    error_code: contract.ErrorCode = .none,
    safe_diagnostic: SafeDiagnostic = .{},
    catalog_generation: u64 = 0,
    execution_generation: u64 = 0,
    execution_high_watermark: u64 = 0,
    active_attempt_id: ?u64 = null,
    attempt_kind: AttemptKind = .none,
    next_attempt_id: u64 = 1,

    fn view(self: *const CommittedState) contract.AccountView {
        return .{
            .session_state = self.session_state,
            .execution_state = self.execution_state,
            .operation = self.operation,
            .readiness = self.readiness(),
            .primary_action = self.primaryAction(),
            .can_cancel = self.operation != .none and
                self.operation != .logging_out and
                self.operation != .persisting,
            .account_id = self.account_id.view(),
            .profile_id = self.profile_id.view(),
            .display_name = self.display_name.view(),
            .selected_api_key_id = self.selected_api_key_id.view(),
            .selected_model = self.selected_model.view(),
            .candidate_api_key_id = self.pending_api_key_id.view(),
            .candidate_model = self.pending_model.view(),
            .model_catalog_api_key_id = switch (self.operation) {
                .selecting_model, .persisting => self.pending_api_key_id.view(),
                .loading_models => self.pending_api_key_id.view(),
                .loading_keys => if (self.execution_state == .ready)
                    self.selected_api_key_id.view()
                else
                    "",
                .selecting_key => "",
                else => self.selected_api_key_id.view(),
            },
            .can_create_task = self.execution_state == .ready and
                self.attempt_kind != .catalog and
                self.operation != .logging_out,
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
            .execution_generation = self.execution_generation,
        };
    }

    fn readiness(self: *const CommittedState) contract.AccountReadiness {
        if (self.session_state == .shutting_down) return .restart_required;
        if (self.execution_state == .ready) return .ready;
        if (self.session_state == .restoring) return .checking;
        if (self.session_state == .signed_out) return .sign_in_required;
        if (self.session_state == .reauth_required) return .needs_attention;
        return switch (self.operation) {
            .selecting_key, .selecting_model => .choice_required,
            .none => .needs_attention,
            else => .preparing,
        };
    }

    fn primaryAction(
        self: *const CommittedState,
    ) contract.AccountPrimaryAction {
        return switch (self.readiness()) {
            .checking, .ready => .none,
            .sign_in_required => .sign_in,
            .restart_required => .restart,
            .preparing => if (self.session_state == .authorizing and
                self.operation == .oauth_callback)
                .reopen_login
            else
                .none,
            .choice_required => switch (self.operation) {
                .selecting_key => .choose_api_key,
                .selecting_model => .choose_model,
                else => unreachable,
            },
            .needs_attention => if (self.session_state == .reauth_required)
                .reauthenticate
            else
                .retry_catalog,
        };
    }

    fn clearError(self: *CommittedState) void {
        self.error_code = .none;
        self.safe_diagnostic.clear();
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

    pub fn currentIdentity(self: *const Account) ?AccountIdentity {
        if (self.state.account_id.len == 0 or
            self.state.profile_id.len == 0)
            return null;
        return .{
            .account_id = self.state.account_id,
            .profile_id = self.state.profile_id,
            .display_name = self.state.display_name,
        };
    }

    pub fn executionHighWatermark(self: *const Account) u64 {
        return self.state.execution_high_watermark;
    }

    pub fn prepareCommand(
        self: *const Account,
        command: contract.AccountCommand,
    ) PrepareResult {
        contract.validateCommand(command) catch
            return .{ .rejected = .invalid_command };
        if (self.state.session_state == .shutting_down)
            return .{ .rejected = .shutting_down };

        return switch (command) {
            .begin_login => self.prepareBeginLogin(),
            .reopen_login => self.prepareReopenLogin(),
            .reauthenticate => self.prepareReauthenticate(),
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
            .signed_out => |signed_out| blk: {
                var next = self.state;
                next.session_state = .signed_out;
                next.execution_high_watermark =
                    signed_out.execution_high_watermark;
                next.clearError();
                break :blk transitionNoAttempt(next, .restored);
            },
            .account_only => |account_only| blk: {
                var next = self.state;
                next.session_state = .authenticated;
                next.account_id = account_only.identity.account_id;
                next.profile_id = account_only.identity.profile_id;
                next.display_name = account_only.identity.display_name;
                next.execution_high_watermark =
                    account_only.execution_high_watermark;
                next.clearError();
                break :blk transitionNoAttempt(next, .restored);
            },
            .execution_ready => |*ready| self.prepareRestoreReady(restore, ready),
        };
    }

    pub fn prepareRestoreFailure(
        self: *const Account,
        failure: WorkerFailure,
    ) PrepareResult {
        if (self.state.session_state != .restoring)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = .shutting_down;
        next.error_code = if (failure.error_code == .none)
            .recovery_state_invalid
        else
            failure.error_code;
        next.safe_diagnostic = failure.safe_diagnostic;
        return transitionNoAttempt(next, .operation_failed);
    }

    /// Windows has no multi-record commit whose outcome requires a process
    /// restart to adjudicate. A local read/codec failure therefore returns to
    /// the login surface with an explicit error instead of manufacturing the
    /// macOS manifest recovery state.
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

    /// A logout manifest rename may have committed even when the filesystem
    /// cannot report the outcome. Continuing with the old in-memory execution
    /// would violate the tombstone boundary, so this state is deliberately
    /// non-recoverable in-process. Startup restore is the only authority that
    /// may decide which manifest won.
    pub fn prepareLogoutPersistenceUnknown(
        self: *const Account,
    ) PrepareResult {
        if (self.state.attempt_kind != .logout or
            self.state.operation != .logging_out or
            self.state.active_attempt_id == null)
            return .{ .rejected = .invalid_state };
        const attempt_id = self.state.active_attempt_id.?;
        var next = self.state;
        next.session_state = .shutting_down;
        next.execution_state = .none;
        next.operation = .none;
        next.active_attempt_id = null;
        next.attempt_kind = .none;
        next.selected_api_key_id.clear();
        next.selected_model.clear();
        next.pending_api_key_id.clear();
        next.pending_model.clear();
        next.execution_generation = 0;
        next.error_code = .recovery_state_invalid;
        next.safe_diagnostic.clear();
        return transitionNoEffect(
            next,
            .operation_failed,
            attempt_id,
        );
    }

    /// The execution manifest rename may have committed even when directory
    /// fsync could not report the result. The Host cannot safely choose either
    /// the old runtime generation or the staged one in-process, so it clears
    /// admission and requires startup restore to resolve the manifest.
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
        if ((self.state.session_state != .authenticated and
            self.state.session_state != .reauth_required) or
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
            .authenticated => |identity| self.prepareAuthenticated(identity),
            .token_refreshed => self.prepareTokenRefreshed(),
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

    pub fn prepareRestoredRefreshAdmissionFailure(
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
        next.session_state = .reauth_required;
        next.error_code = error_code;
        next.safe_diagnostic.clear();
        return transitionNoAttempt(next, .operation_failed);
    }

    fn prepareBeginLogin(self: *const Account) PrepareResult {
        if (self.state.session_state != .signed_out or
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

    fn prepareReauthenticate(self: *const Account) PrepareResult {
        if (self.state.session_state != .reauth_required or
            self.state.operation != .none)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .authorizing;
        next.operation = .oauth_callback;
        next.active_attempt_id = attempt.current;
        next.attempt_kind = .reauthenticate;
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .begin_oauth);
    }

    fn prepareReopenLogin(self: *const Account) PrepareResult {
        if (self.state.session_state != .authorizing or
            self.state.operation != .oauth_callback or
            self.state.active_attempt_id == null or
            (self.state.attempt_kind != .login and
                self.state.attempt_kind != .reauthenticate))
            return .{ .rejected = .invalid_state };
        return transition(
            self.state,
            .session_changed,
            self.state.active_attempt_id.?,
            .reopen_oauth,
        );
    }

    fn prepareCancel(self: *const Account) PrepareResult {
        if (self.state.operation == .persisting)
            return .{ .rejected = .invalid_state };
        const attempt = self.state.active_attempt_id orelse
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.session_state = switch (next.attempt_kind) {
            .login => .signed_out,
            .reauthenticate, .refresh_token => .reauth_required,
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
        return transition(
            next,
            .operation_failed,
            attempt,
            .{ .cancel_attempt = attempt },
        );
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
            (self.state.session_state != .authenticated and
                self.state.session_state != .reauth_required))
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
            .persist_signed_out_tombstone,
        );
    }

    fn prepareAuthenticated(
        self: *const Account,
        identity: AccountIdentity,
    ) PrepareResult {
        if (self.state.operation != .oauth_callback and
            self.state.operation != .token_exchange)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        switch (next.attempt_kind) {
            .login => {
                next.session_state = .authenticated;
                next.operation = .none;
                next.active_attempt_id = null;
                next.attempt_kind = .none;
                next.account_id = identity.account_id;
                next.profile_id = identity.profile_id;
                next.display_name = identity.display_name;
                next.clearError();
                return transitionNoEffect(
                    next,
                    .session_changed,
                    self.state.active_attempt_id.?,
                );
            },
            .reauthenticate => {
                next.session_state = .authenticated;
                next.execution_state = .none;
                next.operation = .none;
                next.active_attempt_id = null;
                next.attempt_kind = .none;
                next.account_id = identity.account_id;
                next.profile_id = identity.profile_id;
                next.display_name = identity.display_name;
                next.selected_api_key_id.clear();
                next.selected_model.clear();
                next.pending_api_key_id.clear();
                next.pending_model.clear();
                next.execution_generation = 0;
                next.clearError();
                return transitionNoEffect(
                    next,
                    .session_changed,
                    self.state.active_attempt_id.?,
                );
            },
            else => return .{ .rejected = .invalid_state },
        }
    }

    fn prepareTokenRefreshed(self: *const Account) PrepareResult {
        if (self.state.attempt_kind != .refresh_token or
            self.state.operation != .token_exchange)
            return .{ .rejected = .invalid_state };
        var next = self.state;
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
        const expected = incrementGeneration(self.state.execution_high_watermark) orelse {
            execution.deinit();
            completion.payload = dependencyFailure();
            return .{ .rejected = .generation_mismatch };
        };
        if (input.execution_generation != expected or
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
        next.execution_high_watermark = input.execution_generation;
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
        next.profile_id.clear();
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
        return transition(
            next,
            .signed_out,
            self.state.active_attempt_id.?,
            .delete_retired_credentials,
        );
    }

    fn prepareFailure(
        self: *const Account,
        failure: WorkerFailure,
    ) PrepareResult {
        const normalized_failure = if (failure.error_code == .none)
            WorkerFailure.fromCode(.dependency_contract_invalid)
        else
            failure;
        var next = self.state;
        next.session_state = switch (next.attempt_kind) {
            .login => if (next.session_state == .authorizing)
                .signed_out
            else
                next.session_state,
            .reauthenticate, .refresh_token => .reauth_required,
            .catalog, .logout, .none => next.session_state,
        };
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
        return transitionNoEffect(
            next,
            .operation_failed,
            self.state.active_attempt_id.?,
        );
    }

    fn prepareRestoreReady(
        self: *const Account,
        restore: *RestoreResult,
        ready: *RestoreReady,
    ) PrepareResult {
        var execution = ready.execution.take();
        const input = execution.input();
        if (input.execution_generation == 0) {
            execution.deinit();
            restore.* = emptyRestore();
            return .{ .rejected = .generation_mismatch };
        }
        var next = self.state;
        next.session_state = .authenticated;
        next.execution_state = .ready;
        next.account_id = ready.identity.account_id;
        next.profile_id = ready.identity.profile_id;
        next.display_name = ready.identity.display_name;
        next.selected_api_key_id = ready.api_key_id;
        next.selected_model.set(input.target.model) catch {
            execution.deinit();
            restore.* = emptyRestore();
            return .{ .rejected = .execution_config_invalid };
        };
        next.execution_generation = input.execution_generation;
        next.execution_high_watermark = input.execution_generation;
        next.clearError();
        restore.* = emptyRestore();
        return .{ .transition = .{
            .next = next,
            .fact_kind = .restored,
            .attempt_id = null,
            .execution = execution,
        } };
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
    if (state.execution_generation > state.execution_high_watermark)
        return false;
    if ((state.active_attempt_id == null) != (state.attempt_kind == .none))
        return false;
    if (state.active_attempt_id == null and state.operation != .none)
        return false;
    if (state.active_attempt_id != null and state.operation == .none)
        return false;

    switch (state.session_state) {
        .restoring, .signed_out, .reauth_required, .shutting_down => {
            if (state.operation != .none) return false;
        },
        .authorizing => {
            if (state.operation != .oauth_callback) return false;
            if (state.attempt_kind != .login and
                state.attempt_kind != .reauthenticate)
                return false;
        },
        .refreshing => {
            if (state.operation != .token_exchange or
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
    committed: bool = false,

    pub fn fact(self: *const PreparedTransition) contract.AccountFact {
        return .{
            .kind = self.fact_kind,
            .view = self.next.view(),
        };
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

pub const TestSupport = if (builtin.is_test) struct {
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
        next.profile_id.set("profile-1") catch unreachable;
        next.display_name.set("Metask User") catch unreachable;
        next.pending_api_key_id.set(api_key_id) catch unreachable;
        next.pending_model.set(model_id) catch unreachable;
        std.debug.assert(stateIsValid(&next));
        account.state = next;
    }
} else struct {};

pub const AccountIdentity = struct {
    account_id: AccountId,
    profile_id: ProfileId,
    display_name: DisplayName,

    pub fn init(
        account_id: []const u8,
        profile_id: []const u8,
        display_name: []const u8,
    ) contract.ValidationError!AccountIdentity {
        if (account_id.len == 0 or profile_id.len == 0)
            return error.FieldEmpty;
        return .{
            .account_id = try .init(account_id),
            .profile_id = try .init(profile_id),
            .display_name = try .init(display_name),
        };
    }

    pub fn accountId(self: *const AccountIdentity) []const u8 {
        return self.account_id.view();
    }

    pub fn displayName(self: *const AccountIdentity) []const u8 {
        return self.display_name.view();
    }

    pub fn profileId(self: *const AccountIdentity) []const u8 {
        return self.profile_id.view();
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
        authenticated: AccountIdentity,
        token_refreshed,
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

pub const RestoreReady = struct {
    identity: AccountIdentity,
    api_key_id: ApiKeyId,
    execution: contract.OwnedExecutionConfig,

    pub fn init(
        identity: AccountIdentity,
        api_key_id: []const u8,
        execution: *contract.OwnedExecutionConfig,
    ) contract.ValidationError!RestoreReady {
        if (api_key_id.len == 0) return error.FieldEmpty;
        const validated_api_key_id = try ApiKeyId.init(api_key_id);
        return .{
            .identity = identity,
            .api_key_id = validated_api_key_id,
            .execution = execution.take(),
        };
    }

    pub fn apiKeyId(self: *const RestoreReady) []const u8 {
        return self.api_key_id.view();
    }
};

pub const RestoreSignedOut = struct {
    execution_high_watermark: u64 = 0,
};

pub const RestoreAccountOnly = struct {
    identity: AccountIdentity,
    execution_high_watermark: u64 = 0,
};

pub const RestoreResult = union(enum) {
    signed_out: RestoreSignedOut,
    account_only: RestoreAccountOnly,
    execution_ready: RestoreReady,

    pub fn deinit(self: *RestoreResult) void {
        switch (self.*) {
            .execution_ready => |*ready| ready.execution.deinit(),
            else => {},
        }
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

    try std.testing.expectEqual(contract.AccountSessionState.signed_out, account.view().session_state);
    try std.testing.expectEqual(contract.AccountSessionState.authorizing, prepared.fact().view.session_state);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
    _ = prepared.takeEffect();
    prepared.commit(&account);
    try std.testing.expectEqual(contract.AccountSessionState.authorizing, account.view().session_state);
    try std.testing.expectEqual(@as(?u64, 1), account.activeAttempt());
}

test "Host product readiness exposes login recovery without Renderer inference" {
    var account = Account.initSignedOutForTest();
    try std.testing.expectEqual(
        contract.AccountReadiness.sign_in_required,
        account.view().readiness,
    );
    try std.testing.expectEqual(
        contract.AccountPrimaryAction.sign_in,
        account.view().primary_action,
    );

    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = begin.takeEffect();
    commitPrepared(&account, &begin);
    try std.testing.expectEqual(
        contract.AccountReadiness.preparing,
        account.view().readiness,
    );
    try std.testing.expectEqual(
        contract.AccountPrimaryAction.reopen_login,
        account.view().primary_action,
    );
    try std.testing.expect(account.view().can_cancel);

    var reopen = switch (account.prepareCommand(.reopen_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(reopen.takeEffect().? == .reopen_oauth);
    commitPrepared(&account, &reopen);

    var cancel = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = cancel.takeEffect();
    commitPrepared(&account, &cancel);
    try std.testing.expectEqual(
        contract.AccountReadiness.sign_in_required,
        account.view().readiness,
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
        contract.AccountSessionState.signed_out,
        account.view().session_state,
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
                .begin_oauth, .reopen_oauth => self.browser_calls += 1,
                .refresh_token => self.client_calls += 1,
                .load_api_keys, .load_models => self.client_calls += 1,
                .prepare_execution,
                .persist_signed_out_tombstone,
                .delete_retired_credentials,
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
        contract.AccountSessionState.signed_out,
        rejected_account.view().session_state,
    );
}

test "RestoreReady validation does not consume execution on failure" {
    const allocator = std.testing.allocator;
    var execution = try contract.OwnedExecutionConfig.initOwned(
        allocator,
        .anthropic,
        try allocator.dupe(u8, "model-1"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        1,
        try allocator.dupe(u8, "secret"),
    );
    defer execution.deinit();

    try std.testing.expectError(error.FieldEmpty, RestoreReady.init(
        try .init("account-1", "profile-1", "Metask User"),
        "",
        &execution,
    ));
    try std.testing.expectEqualStrings("model-1", execution.input().target.model);
}

test "explicit reauthentication replaces identity and clears prior execution" {
    const allocator = std.testing.allocator;
    var account = Account.initRestoring();
    var restored_execution = try contract.OwnedExecutionConfig.initOwned(
        allocator,
        .anthropic,
        try allocator.dupe(u8, "model-1"),
        try allocator.dupe(u8, contract.metask_anthropic_messages_url),
        9,
        try allocator.dupe(u8, "secret"),
    );
    defer restored_execution.deinit();
    var restore: RestoreResult = .{ .execution_ready = try .init(
        try .init("account-1", "profile-1", "Metask User"),
        "key-1",
        &restored_execution,
    ) };
    defer restore.deinit();
    var restored = switch (account.prepareRestore(&restore)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var installed = restored.takeExecution().?;
    defer installed.deinit();
    restored.commit(&account);
    restored.deinit();
    try std.testing.expectEqual(contract.ExecutionState.ready, account.view().execution_state);
    try std.testing.expectEqual(@as(u64, 9), account.view().execution_generation);

    var refresh = switch (account.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = refresh.takeEffect();
    commitPrepared(&account, &refresh);
    var refresh_failed: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .failed = try .init(.token_refresh_failed, "reauth required") },
    };
    var failed = switch (account.prepareCompletion(&refresh_failed)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(contract.AccountSessionState.reauth_required, account.view().session_state);
    try std.testing.expectEqual(contract.ExecutionState.ready, account.view().execution_state);

    var reauth = switch (account.prepareCommand(.reauthenticate)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = reauth.takeEffect();
    commitPrepared(&account, &reauth);
    var replacement: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{
            .authenticated = try .init(
                "account-2",
                "profile-2",
                "Other User",
            ),
        },
    };
    var replacement_transition = switch (account.prepareCompletion(&replacement)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &replacement_transition);
    try std.testing.expectEqual(contract.AccountSessionState.authenticated, account.view().session_state);
    try std.testing.expectEqual(contract.ExecutionState.none, account.view().execution_state);
    try std.testing.expectEqualStrings("account-2", account.view().account_id);
    try std.testing.expectEqualStrings("profile-2", account.view().profile_id);
    try std.testing.expectEqualStrings("Other User", account.view().display_name);
    try std.testing.expectEqual(@as(u64, 0), account.view().execution_generation);
    try std.testing.expectEqual(contract.ErrorCode.none, account.view().error_code);
}

test "failed reconfiguration preserves committed selection and generation high watermark" {
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
    var restore: RestoreResult = .{ .execution_ready = try .init(
        try .init("account-1", "profile-1", "Metask User"),
        "key-old",
        &restored_execution,
    ) };
    defer restore.deinit();
    var restored = switch (account.prepareRestore(&restore)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
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
    try std.testing.expectEqual(contract.ExecutionState.reconfiguring, account.view().execution_state);
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
    try std.testing.expectEqual(contract.ExecutionState.ready, account.view().execution_state);
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
        logout.takeEffect().? == .persist_signed_out_tombstone,
    );
    commitPrepared(&account, &logout);
    try std.testing.expect(!account.view().can_create_task);
    var logged_out: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .logged_out,
    };
    var logout_done = switch (account.prepareCompletion(&logged_out)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(
        logout_done.takeEffect().? == .delete_retired_credentials,
    );
    commitPrepared(&account, &logout_done);
    try std.testing.expectEqual(@as(u64, 0), account.view().execution_generation);
    try std.testing.expectEqual(@as(u64, 9), account.state.execution_high_watermark);

    var restarted = Account.initRestoring();
    var tombstone_restore: RestoreResult = .{ .signed_out = .{
        .execution_high_watermark = account.state.execution_high_watermark,
    } };
    var restored_tombstone = switch (restarted.prepareRestore(&tombstone_restore)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&restarted, &restored_tombstone);
    try std.testing.expectEqual(
        @as(u64, 9),
        restarted.state.execution_high_watermark,
    );
}

test "ready execution reloads authenticated catalog before reconfiguration" {
    var account: Account = .{ .state = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .operation = .none,
        .account_id = try .init("account-1"),
        .profile_id = try .init("profile-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-old"),
        .selected_model = try .init("model-old"),
        .catalog_generation = 4,
        .execution_generation = 9,
        .execution_high_watermark = 9,
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
    try std.testing.expectEqual(contract.OperationKind.loading_keys, view.operation);
    try std.testing.expectEqual(contract.ExecutionState.ready, view.execution_state);
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
    try std.testing.expectEqual(contract.OperationKind.persisting, view.operation);
    try std.testing.expectEqual(contract.ExecutionState.reconfiguring, view.execution_state);
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
    try std.testing.expectEqual(contract.AccountSessionState.shutting_down, account.view().session_state);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
    try std.testing.expectEqual(
        contract.ErrorCode.shutting_down,
        account.prepareCommand(.begin_login).rejected,
    );
}

test "shutdown revokes ready execution before publishing the terminal view" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .account_id = try .init("account-1"),
        .profile_id = try .init("profile-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-1"),
        .selected_model = try .init("model-1"),
        .execution_generation = 3,
        .execution_high_watermark = 3,
    } };

    var shutdown = account.prepareShutdown();
    _ = shutdown.takeEffect();
    shutdown.commit(&account);
    shutdown.deinit();

    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(contract.ExecutionState.none, view.execution_state);
    try std.testing.expectEqualStrings("", view.selected_api_key_id);
    try std.testing.expectEqualStrings("", view.selected_model);
    try std.testing.expectEqual(@as(u64, 0), view.execution_generation);
    try std.testing.expect(!view.can_create_task);
}

test "restore failure enters a terminal restart-required state" {
    var account: Account = .{};
    var failure = WorkerFailure.fromCode(.credential_store_read_failed);
    failure.safe_diagnostic = try .init("Keychain read failed");
    var prepared = switch (account.prepareRestoreFailure(failure)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &prepared);

    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.credential_store_read_failed,
        view.error_code,
    );
    try std.testing.expectEqualStrings(
        "Keychain read failed",
        view.safe_diagnostic,
    );
    try std.testing.expect(!view.can_create_task);
    try std.testing.expectEqual(
        contract.ErrorCode.shutting_down,
        account.prepareCommand(.begin_login).rejected,
    );
}

test "Windows restore failure returns to sign-in without restart semantics" {
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
        contract.AccountSessionState.signed_out,
        view.session_state,
    );
    try std.testing.expectEqual(
        contract.AccountReadiness.sign_in_required,
        view.readiness,
    );
    try std.testing.expectEqual(
        contract.AccountPrimaryAction.sign_in,
        view.primary_action,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.credential_store_read_failed,
        view.error_code,
    );
}

test "restored refresh admission failure requires reauthentication" {
    const identity = try AccountIdentity.init(
        "account-1",
        "profile-1",
        "MetaWork User",
    );
    var account: Account = .{};
    var restored: RestoreResult = .{
        .account_only = .{ .identity = identity },
    };
    var restore = switch (account.prepareRestore(&restored)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &restore);
    var failed = switch (account.prepareRestoredRefreshAdmissionFailure(
        .local_resource_exhausted,
    )) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountSessionState.reauth_required,
        view.session_state,
    );
    try std.testing.expectEqual(
        contract.AccountPrimaryAction.reauthenticate,
        view.primary_action,
    );
}

test "unknown logout persistence outcome cannot reopen ready execution" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .account_id = try .init("account-1"),
        .profile_id = try .init("profile-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-1"),
        .selected_model = try .init("model-1"),
        .execution_generation = 1,
        .execution_high_watermark = 1,
    } };
    var logout = switch (account.prepareCommand(.logout)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    _ = logout.takeEffect();
    commitPrepared(&account, &logout);
    var unknown = switch (account.prepareLogoutPersistenceUnknown()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &unknown);

    const view = account.view();
    try std.testing.expectEqual(
        contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(
        contract.ExecutionState.none,
        view.execution_state,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.recovery_state_invalid,
        view.error_code,
    );
    try std.testing.expect(!view.can_create_task);
}

test "unknown execution persistence outcome clears old runtime identity" {
    var account = Account{ .state = .{
        .session_state = .authenticated,
        .execution_state = .ready,
        .account_id = try .init("account-1"),
        .profile_id = try .init("profile-1"),
        .display_name = try .init("Metask User"),
        .selected_api_key_id = try .init("key-old"),
        .selected_model = try .init("model-old"),
        .execution_generation = 1,
        .execution_high_watermark = 1,
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
        contract.AccountSessionState.shutting_down,
        view.session_state,
    );
    try std.testing.expectEqual(
        contract.ExecutionState.none,
        view.execution_state,
    );
    try std.testing.expectEqualStrings("", view.selected_api_key_id);
    try std.testing.expectEqualStrings("", view.selected_model);
    try std.testing.expectEqual(@as(u64, 1), account.executionHighWatermark());
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

    var authenticated: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{
            .authenticated = try .init(
                "account-1",
                "profile-1",
                "Metask User",
            ),
        },
    };
    var auth_transition = switch (account.prepareCompletion(&authenticated)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &auth_transition);
    try std.testing.expectEqual(contract.OperationKind.none, account.view().operation);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
    try std.testing.expectEqualStrings(
        "profile-1",
        account.currentIdentity().?.profileId(),
    );

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
            1,
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
    try std.testing.expectEqual(contract.AccountSessionState.authenticated, view.session_state);
    try std.testing.expectEqual(contract.ExecutionState.ready, view.execution_state);
    try std.testing.expectEqual(@as(u64, 2), view.catalog_generation);
    try std.testing.expectEqual(@as(u64, 1), view.execution_generation);
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
