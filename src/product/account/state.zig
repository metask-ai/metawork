//! Product Account identity and authorization state machine.
//!
//! Account deliberately has no model catalog, selection, provider, source,
//! execution, Task, or consumer concepts. Those belong to Models and Product
//! Control. This state machine owns only OAuth identity lifecycle.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");

const AccountId = BoundedString(contract.Limits.account_id_bytes);
const DisplayName = BoundedString(contract.Limits.display_name_bytes);
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

const SessionState = enum {
    restoring,
    signed_out,
    authorizing,
    authenticated,
    refreshing,
    shutting_down,
};

const AttemptKind = enum { login, refresh_token, logout };
const IdentityAttemptKind = enum { login, refresh_token };

const Transaction = union(enum) {
    none,
    oauth_callback: u64,
    token_exchange: struct {
        attempt_id: u64,
        kind: IdentityAttemptKind,
    },
    loading_identity: struct {
        attempt_id: u64,
        kind: IdentityAttemptKind,
    },
    logging_out: u64,

    fn attemptId(self: Transaction) ?u64 {
        return switch (self) {
            .none => null,
            .oauth_callback, .logging_out => |id| id,
            .token_exchange => |value| value.attempt_id,
            .loading_identity => |value| value.attempt_id,
        };
    }

    fn attemptKind(self: Transaction) ?AttemptKind {
        return switch (self) {
            .none => null,
            .oauth_callback => .login,
            .token_exchange => |value| switch (value.kind) {
                .login => .login,
                .refresh_token => .refresh_token,
            },
            .loading_identity => |value| switch (value.kind) {
                .login => .login,
                .refresh_token => .refresh_token,
            },
            .logging_out => .logout,
        };
    }
};

pub const Effect = union(enum) {
    begin_oauth,
    exchange_login,
    refresh_token,
    load_identity,
    cancel_attempt: u64,
    delete_credential,
    shutdown: ?u64,
};

pub const EffectSink = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, ?u64, Effect) bool,

    pub fn submit(self: EffectSink, attempt_id: ?u64, effect: Effect) bool {
        return self.submit_fn(self.context, attempt_id, effect);
    }
};

const CommittedState = struct {
    session_state: SessionState = .restoring,
    transaction: Transaction = .none,
    account_id: AccountId = .{},
    display_name: DisplayName = .{},
    error_code: contract.ErrorCode = .none,
    safe_diagnostic: SafeDiagnostic = .{},
    next_attempt_id: u64 = 1,

    fn activeAttempt(self: *const CommittedState) ?u64 {
        return self.transaction.attemptId();
    }

    fn attemptKind(self: *const CommittedState) ?AttemptKind {
        return self.transaction.attemptKind();
    }

    fn clearTransaction(self: *CommittedState) void {
        self.transaction = .none;
    }

    fn clearIdentity(self: *CommittedState) void {
        self.account_id.clear();
        self.display_name.clear();
    }

    fn clearError(self: *CommittedState) void {
        self.error_code = .none;
        self.safe_diagnostic.clear();
    }

    fn canCancel(self: *const CommittedState) bool {
        return self.transaction == .oauth_callback;
    }

    fn view(self: *const CommittedState) contract.AccountView {
        const state: contract.AccountState = switch (self.session_state) {
            .restoring => .checking,
            .signed_out, .shutting_down => .signed_out,
            .authorizing => .authorizing,
            .authenticated => .authenticated,
            .refreshing => if (self.account_id.len == 0) .checking else .authenticated,
        };
        const publish_identity = state == .authenticated;
        return .{
            .state = state,
            .can_cancel = self.canCancel(),
            .account_id = if (publish_identity) self.account_id.view() else "",
            .display_name = if (publish_identity) self.display_name.view() else "",
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
        };
    }
};

pub const Account = struct {
    state: CommittedState = .{},

    pub fn initRestoring() Account {
        return .{};
    }

    fn initSignedOutForTest() Account {
        return .{ .state = .{ .session_state = .signed_out } };
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

    pub fn activeRequestUsesCredential(self: *const Account) bool {
        return switch (self.state.transaction) {
            .token_exchange => |value| value.kind == .refresh_token,
            .loading_identity => true,
            else => false,
        };
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
            .retry_refresh => self.prepareRetryRefresh(),
            // Summary effects are coordinated by Account Runtime and never
            // enter the identity transaction state machine.
            .refresh_summary => .{ .rejected = .invalid_state },
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
        var next = self.state;
        return switch (restore.*) {
            .signed_out => blk: {
                next.session_state = .signed_out;
                next.clearError();
                break :blk transitionNoAttempt(next, .restored);
            },
            .refresh_only => blk: {
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

    pub fn prepareTokenRefresh(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        return self.prepareRefreshTransition();
    }

    pub fn prepareRestoredTokenRefresh(self: *const Account) PrepareResult {
        if (self.state.session_state != .restoring or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        return self.prepareRefreshTransition();
    }

    fn prepareRefreshTransition(self: *const Account) PrepareResult {
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.session_state = .refreshing;
        next.transaction = .{ .token_exchange = .{
            .attempt_id = attempt.current,
            .kind = .refresh_token,
        } };
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .refresh_token);
    }

    pub fn prepareLoginExchange(
        self: *const Account,
        attempt_id: u64,
    ) PrepareResult {
        const active = switch (self.state.transaction) {
            .oauth_callback => |value| value,
            else => return .{ .rejected = .invalid_state },
        };
        if (active != attempt_id) return .ignored_stale;
        var next = self.state;
        next.transaction = .{ .token_exchange = .{
            .attempt_id = attempt_id,
            .kind = .login,
        } };
        next.clearError();
        return transition(next, .session_changed, attempt_id, .exchange_login);
    }

    pub fn prepareCompletion(
        self: *const Account,
        completion: *WorkerCompletion,
    ) PrepareResult {
        if (self.state.activeAttempt() != completion.attempt_id) {
            completion.deinit();
            return .ignored_stale;
        }
        const result = switch (completion.payload) {
            .identity_loaded => |identity| self.prepareIdentityLoaded(identity),
            .tokens_persisted => self.prepareTokensPersisted(),
            .logged_out => self.prepareLoggedOut(),
            .failed => |failure| self.prepareFailure(failure),
        };
        return switch (result) {
            .rejected => |code| blk: {
                completion.deinit();
                break :blk self.prepareFailure(.fromCode(code));
            },
            else => result,
        };
    }

    pub fn prepareShutdown(self: *const Account) PreparedTransition {
        var next = self.state;
        next.session_state = .shutting_down;
        next.clearIdentity();
        next.clearError();
        const active_attempt = next.activeAttempt();
        next.clearTransaction();
        return .{
            .next = next,
            .fact_kind = .session_changed,
            .attempt_id = active_attempt,
            .effect = .{ .shutdown = active_attempt },
        };
    }

    pub fn prepareRefreshScheduleFailure(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.error_code = .refresh_schedule_failed;
        next.safe_diagnostic.clear();
        return transitionNoAttempt(next, .operation_failed);
    }

    pub fn prepareRetryRefresh(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.clearError();
        return transitionNoAttempt(next, .session_changed);
    }

    fn prepareBeginLogin(self: *const Account) PrepareResult {
        if ((self.state.session_state != .signed_out and
            self.state.session_state != .authenticated) or
            self.state.activeAttempt() != null)
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
        if (!self.state.canCancel()) return .{ .rejected = .invalid_state };
        const attempt_id = self.state.activeAttempt().?;
        var next = self.state;
        next.session_state = if (next.account_id.len == 0) .signed_out else .authenticated;
        next.clearTransaction();
        next.error_code = .user_cancelled;
        next.safe_diagnostic.clear();
        return transition(
            next,
            .operation_failed,
            attempt_id,
            .{ .cancel_attempt = attempt_id },
        );
    }

    fn prepareLogout(self: *const Account) PrepareResult {
        if (self.state.session_state != .authenticated or
            self.state.activeAttempt() != null)
            return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.transaction = .{ .logging_out = attempt.current };
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .delete_credential);
    }

    fn prepareTokensPersisted(self: *const Account) PrepareResult {
        const kind = self.state.attemptKind() orelse
            return .{ .rejected = .invalid_state };
        const exchange_kind = switch (self.state.transaction) {
            .token_exchange => |value| value.kind,
            else => return .{ .rejected = .invalid_state },
        };
        if ((kind == .login and exchange_kind != .login) or
            (kind == .refresh_token and exchange_kind != .refresh_token))
            return .{ .rejected = .invalid_state };
        var next = self.state;
        if (kind == .login or next.account_id.len == 0) {
            const attempt_id = next.activeAttempt().?;
            next.transaction = .{ .loading_identity = .{
                .attempt_id = attempt_id,
                .kind = if (kind == .login) .login else .refresh_token,
            } };
            next.clearError();
            return transition(next, .session_changed, attempt_id, .load_identity);
        }
        next.session_state = .authenticated;
        next.clearTransaction();
        next.clearError();
        return transitionNoEffect(next, .session_changed, self.state.activeAttempt().?);
    }

    fn prepareIdentityLoaded(
        self: *const Account,
        identity: AccountIdentity,
    ) PrepareResult {
        const loading = switch (self.state.transaction) {
            .loading_identity => |value| value,
            else => return .{ .rejected = .invalid_state },
        };
        if (loading.kind == .refresh_token and self.state.account_id.len != 0 and
            !std.mem.eql(u8, identity.accountId(), self.state.account_id.view()))
            return .{ .rejected = .metask_unauthorized };
        var next = self.state;
        next.session_state = .authenticated;
        next.clearTransaction();
        next.account_id = identity.account_id;
        next.display_name = identity.display_name;
        next.clearError();
        return transitionNoEffect(next, .session_changed, loading.attempt_id);
    }

    fn prepareLoggedOut(self: *const Account) PrepareResult {
        if (self.state.transaction != .logging_out)
            return .{ .rejected = .invalid_state };
        const attempt_id = self.state.activeAttempt().?;
        var next = self.state;
        next.session_state = .signed_out;
        next.clearIdentity();
        next.clearTransaction();
        next.clearError();
        return transitionNoEffect(next, .signed_out, attempt_id);
    }

    fn prepareFailure(self: *const Account, failure_value: WorkerFailure) PrepareResult {
        const kind = self.state.attemptKind() orelse
            return .{ .rejected = .invalid_state };
        const failure = if (failure_value.error_code == .none)
            WorkerFailure.fromCode(.account_operation_failed)
        else
            failure_value;
        const login_replaced = kind == .login and self.state.transaction == .loading_identity;
        const authentication_invalid = kind == .refresh_token and
            (failure.error_code == .metask_unauthorized or
                failure.error_code == .credential_store_delete_failed);
        var next = self.state;
        next.session_state = switch (kind) {
            .login => if (login_replaced or next.account_id.len == 0)
                .signed_out
            else
                .authenticated,
            .refresh_token => if (authentication_invalid or next.account_id.len == 0)
                .signed_out
            else
                .authenticated,
            .logout => .authenticated,
        };
        if (next.session_state == .signed_out) next.clearIdentity();
        next.clearTransaction();
        next.error_code = failure.error_code;
        next.safe_diagnostic = failure.safe_diagnostic;
        return transitionNoEffect(next, .operation_failed, self.state.activeAttempt().?);
    }
};

const AttemptAdvance = struct { current: u64, next: u64 };

fn nextAttempt(current: u64) ?AttemptAdvance {
    if (current == 0 or current == std.math.maxInt(u64)) return null;
    return .{ .current = current, .next = current + 1 };
}

fn transition(next: CommittedState, fact_kind: contract.AccountFactKind, attempt_id: u64, effect: Effect) PrepareResult {
    std.debug.assert(stateIsValid(&next));
    return .{ .transition = .{ .next = next, .fact_kind = fact_kind, .attempt_id = attempt_id, .effect = effect } };
}

fn transitionNoEffect(next: CommittedState, fact_kind: contract.AccountFactKind, attempt_id: u64) PrepareResult {
    std.debug.assert(stateIsValid(&next));
    return .{ .transition = .{ .next = next, .fact_kind = fact_kind, .attempt_id = attempt_id } };
}

fn transitionNoAttempt(next: CommittedState, fact_kind: contract.AccountFactKind) PrepareResult {
    std.debug.assert(stateIsValid(&next));
    return .{ .transition = .{ .next = next, .fact_kind = fact_kind, .attempt_id = null } };
}

fn stateIsValid(state: *const CommittedState) bool {
    return switch (state.session_state) {
        .restoring, .signed_out, .shutting_down => state.activeAttempt() == null,
        .authorizing => state.attemptKind() == .login,
        .refreshing => state.attemptKind() == .refresh_token,
        .authenticated => state.transaction == .none or state.transaction == .logging_out,
    };
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
    committed: bool = false,

    pub fn view(self: *const PreparedTransition) contract.AccountView {
        return self.next.view();
    }

    pub fn factKind(self: *const PreparedTransition) contract.AccountFactKind {
        return self.fact_kind;
    }

    pub fn finishesAttempt(self: *const PreparedTransition) bool {
        return self.attempt_id != null and self.next.activeAttempt() == null;
    }

    pub fn nextAttemptId(self: *const PreparedTransition) ?u64 {
        return self.next.activeAttempt();
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
    }
};

pub const AccountIdentity = struct {
    account_id: AccountId,
    display_name: DisplayName,

    pub fn init(account_id: []const u8, display_name: []const u8) contract.ValidationError!AccountIdentity {
        if (account_id.len == 0) return error.FieldEmpty;
        return .{ .account_id = try .init(account_id), .display_name = try .init(display_name) };
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
        logged_out,
        failed: WorkerFailure,
    };

    pub fn deinit(self: *WorkerCompletion) void {
        self.payload = .{ .failed = .fromCode(.account_operation_failed) };
    }
};

pub const RestoreResult = union(enum) {
    signed_out: void,
    refresh_only: void,

    pub fn deinit(self: *RestoreResult) void {
        self.* = .{ .signed_out = {} };
    }
};

pub const TestSupport = if (builtin.is_test) struct {
    pub fn prepareAuthenticated(account: *const Account, identity: AccountIdentity) !PreparedTransition {
        if (account.state.session_state != .restoring) return error.InvalidState;
        var next = account.state;
        next.session_state = .authenticated;
        next.account_id = identity.account_id;
        next.display_name = identity.display_name;
        next.clearError();
        return .{ .next = next, .fact_kind = .restored, .attempt_id = null };
    }
} else struct {};

fn commitPrepared(account: *Account, prepared: *PreparedTransition) void {
    _ = prepared.takeEffect();
    prepared.commit(account);
    prepared.deinit();
}

fn commitLoginExchange(account: *Account) !void {
    var exchange = switch (account.prepareLoginExchange(account.activeAttempt().?)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(exchange.takeEffect().? == .exchange_login);
    exchange.commit(account);
    exchange.deinit();
}

test "command prepare does not mutate committed identity before commit" {
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
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    try std.testing.expectEqual(contract.AccountState.authorizing, account.view().state);
    try std.testing.expect(account.view().can_cancel);

    var cancel = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &cancel);
    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expect(!account.view().can_cancel);
}

test "matching malformed completion fails the authorization attempt" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);

    var malformed: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-1", "User") },
    };
    var failed = switch (account.prepareCompletion(&malformed)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expectEqual(contract.ErrorCode.invalid_state, account.view().error_code);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
}

test "explicit login persists tokens before publishing identity" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    try commitLoginExchange(&account);
    try std.testing.expect(!account.view().can_cancel);
    try std.testing.expect(account.prepareCommand(.cancel_operation) == .rejected);

    var persisted: WorkerCompletion = .{ .attempt_id = account.activeAttempt().?, .payload = .tokens_persisted };
    var load_identity = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(load_identity.takeEffect().? == .load_identity);
    load_identity.commit(&account);
    load_identity.deinit();
    try std.testing.expectEqual(contract.AccountState.authorizing, account.view().state);
    try std.testing.expectEqualStrings("", account.view().account_id);
    try std.testing.expect(!account.view().can_cancel);

    var identity: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-1", "User") },
    };
    var authenticated = switch (account.prepareCompletion(&identity)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &authenticated);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-1", account.view().account_id);
}

test "explicit login accepts a newly verified identity" {
    var account = Account.initRestoring();
    var restored = try TestSupport.prepareAuthenticated(
        &account,
        try AccountIdentity.init("account-1", "Old User"),
    );
    commitPrepared(&account, &restored);
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    try commitLoginExchange(&account);
    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var load_identity = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &load_identity);

    var identity: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-2", "New User") },
    };
    var authenticated = switch (account.prepareCompletion(&identity)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &authenticated);
    try std.testing.expectEqualStrings("account-2", account.view().account_id);
    try std.testing.expectEqualStrings("New User", account.view().display_name);
}

test "failed login before token commit preserves the current identity" {
    var account = Account.initRestoring();
    var restored = try TestSupport.prepareAuthenticated(
        &account,
        try AccountIdentity.init("account-1", "Current User"),
    );
    commitPrepared(&account, &restored);
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    try commitLoginExchange(&account);
    var completion: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.oauth_exchange_failed) },
    };
    var failed = switch (account.prepareCompletion(&completion)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-1", account.view().account_id);
    try std.testing.expectEqualStrings("Current User", account.view().display_name);
}

test "cold refresh publishes identity only after verification" {
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
    commitPrepared(&account, &refresh);
    var persisted: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .tokens_persisted,
    };
    var load_identity = switch (account.prepareCompletion(&persisted)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &load_identity);
    try std.testing.expectEqual(contract.AccountState.checking, account.view().state);

    var identified: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("22", "朱健") },
    };
    var completed = switch (account.prepareCompletion(&identified)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &completed);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("22", account.view().account_id);
    try std.testing.expectEqualStrings("朱健", account.view().display_name);
}

test "refresh failure distinguishes retryable and invalid credentials" {
    var cold = Account.initRestoring();
    var restore_value: RestoreResult = .{ .refresh_only = {} };
    var restore = switch (cold.prepareRestore(&restore_value)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&cold, &restore);
    var cold_refresh = switch (cold.prepareRestoredTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
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
    try std.testing.expectEqual(contract.ErrorCode.metask_service_unavailable, cold.view().error_code);
    try std.testing.expect(cold.prepareRestoredTokenRefresh() == .rejected);
    var explicit_login = switch (cold.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer explicit_login.deinit();
    try std.testing.expect(explicit_login.takeEffect().? == .begin_oauth);

    var active = Account.initRestoring();
    var active_restore = try TestSupport.prepareAuthenticated(
        &active,
        try AccountIdentity.init("account-1", "Metask User"),
    );
    commitPrepared(&active, &active_restore);
    var active_refresh = switch (active.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
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

test "shutdown invalidates an active authorization attempt" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    var shutdown = account.prepareShutdown();
    const effect = shutdown.takeEffect().?;
    try std.testing.expectEqual(account.activeAttempt(), effect.shutdown);
    shutdown.commit(&account);
    shutdown.deinit();
    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expectEqual(@as(?u64, null), account.activeAttempt());
}

test "restore failure returns to sign-in without restart semantics" {
    var account = Account.initRestoring();
    var failed = switch (account.prepareSignedOutRestoreFailure(
        .fromCode(.credential_store_read_failed),
    )) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expectEqual(
        contract.ErrorCode.credential_store_read_failed,
        account.view().error_code,
    );
}

test "refresh schedule failure is restricted to authenticated idle state" {
    var signed_out = Account.initSignedOutForTest();
    try std.testing.expect(
        signed_out.prepareRefreshScheduleFailure() == .rejected,
    );

    var account = Account.initRestoring();
    var restored = try TestSupport.prepareAuthenticated(
        &account,
        try AccountIdentity.init("account-1", "Metask User"),
    );
    commitPrepared(&account, &restored);
    var failed = switch (account.prepareRefreshScheduleFailure()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &failed);
    try std.testing.expectEqual(
        contract.AccountState.authenticated,
        account.view().state,
    );
    try std.testing.expectEqual(
        contract.ErrorCode.refresh_schedule_failed,
        account.view().error_code,
    );
}
