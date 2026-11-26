//! Product Account identity and authorization state machine.
//!
//! Account deliberately has no model catalog, selection, provider, source,
//! execution, Task, or consumer concepts. Those belong to Models and Product
//! Control. This state machine owns only OAuth identity lifecycle.
//!
//! Three facts are kept apart: the login (`Login`), the one operation Account
//! is doing (`Op`), and what it shows. An operation never changes the login
//! until its result is committed, so a failure only returns the operation to
//! idle and the login stays what it was.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_account_contract");

const AccountId = BoundedString(contract.Limits.account_id_bytes);
const DisplayName = BoundedString(contract.Limits.display_name_bytes);
const EmailHint = BoundedString(contract.Limits.email_hint_bytes);
const PhoneHint = BoundedString(contract.Limits.phone_hint_bytes);
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

/// What this device holds of the Metask login.
pub const Login = union(enum) {
    /// No login is held.
    none: struct {
        reason: NoneReason = .absent,
        /// A refresh token could not be deleted. Its marker keeps it from
        /// ever being sent; logging out again deletes it.
        residue: bool = false,
    },
    /// A refresh token is held, and perhaps an access token, but nothing has
    /// confirmed whose they are.
    held,
    verified: AccountIdentity,
};

pub const NoneReason = enum {
    /// The credential store has not been read yet.
    unread,
    absent,
    /// The credential store could not be read; reading it again may find a
    /// login. Nothing was written over it.
    unreadable,
    /// The person signed out.
    logged_out,
};

/// What waits for the operation underway. Logging out never waits, and
/// closing is the Runtime's own stop.
pub const Intent = enum { none, login };

/// The one operation underway. Each owns a nonzero attempt identity.
pub const Op = union(enum) {
    idle,
    authorize: struct { attempt: u64, exchanging: bool = false },
    renew: struct { attempt: u64 },
    identity: struct { attempt: u64 },

    fn attempt(self: Op) ?u64 {
        return switch (self) {
            .idle => null,
            inline .authorize, .renew, .identity => |value| value.attempt,
        };
    }
};

pub const Effect = union(enum) {
    begin_oauth,
    exchange_login,
    refresh_token,
    load_identity,
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
    login: Login = .{ .none = .{ .reason = .unread } },
    op: Op = .idle,
    intent: Intent = .none,
    error_code: contract.ErrorCode = .none,
    safe_diagnostic: SafeDiagnostic = .{},
    next_attempt_id: u64 = 1,

    fn activeAttempt(self: *const CommittedState) ?u64 {
        return self.op.attempt();
    }

    fn clearError(self: *CommittedState) void {
        self.error_code = .none;
        self.safe_diagnostic.clear();
    }

    fn setFailure(self: *CommittedState, failure: WorkerFailure) void {
        self.error_code = failure.error_code;
        self.safe_diagnostic = failure.safe_diagnostic;
    }

    /// A sign-in waiting for the operation underway can be withdrawn, and so
    /// can one waiting for its browser callback.
    fn canCancel(self: *const CommittedState) bool {
        if (self.intent == .login) return true;
        return switch (self.op) {
            .authorize => |value| !value.exchanging,
            .idle, .renew, .identity => false,
        };
    }

    fn storeRead(self: *const CommittedState) bool {
        return switch (self.login) {
            .none => |value| value.reason != .unread,
            .held, .verified => true,
        };
    }

    fn canRetry(self: *const CommittedState) bool {
        if (self.op != .idle) return false;
        return switch (self.login) {
            .held => self.error_code != .none,
            .verified => self.error_code == .refresh_schedule_failed,
            .none => false,
        };
    }

    fn view(self: *const CommittedState) contract.AccountView {
        const signing_in = self.op == .authorize or self.intent == .login;
        const state: contract.AccountState = if (signing_in) .authorizing else switch (self.login) {
            .none => |value| if (value.reason == .unread) .checking else .signed_out,
            .held => .checking,
            .verified => .authenticated,
        };
        var result: contract.AccountView = .{
            .state = state,
            .can_cancel = self.canCancel(),
            .can_retry = self.canRetry(),
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
        };
        if (state == .authenticated) {
            const identity = &self.login.verified;
            result.account_id = identity.account_id.view();
            result.display_name = identity.display_name.view();
            result.email_hint = identity.email_hint.view();
            result.phone_hint = identity.phone_hint.view();
            result.concurrency_limit = identity.concurrency_limit;
        }
        return result;
    }
};

pub const Account = struct {
    state: CommittedState = .{},

    pub fn initRestoring() Account {
        return .{};
    }

    fn initSignedOutForTest() Account {
        return .{ .state = .{ .login = .{ .none = .{} } } };
    }

    pub fn view(self: *const Account) contract.AccountView {
        return self.state.view();
    }

    pub fn login(self: *const Account) std.meta.Tag(Login) {
        return self.state.login;
    }

    /// The store was read; until then nothing is known of a login.
    pub fn storeRead(self: *const Account) bool {
        return self.state.storeRead();
    }

    /// The store could not be read, and nothing is underway: reading it
    /// again is what a retry does.
    pub fn readsStoreAgain(self: *const Account) bool {
        return self.state.op == .idle and switch (self.state.login) {
            .none => |value| value.reason == .unreadable,
            .held, .verified => false,
        };
    }

    /// A refresh token is stored that a logout could not delete.
    pub fn residue(self: *const Account) bool {
        return switch (self.state.login) {
            .none => |value| value.residue,
            .held, .verified => false,
        };
    }

    /// Something is stored to delete: a login, or what a logout left.
    pub fn acceptsLogout(self: *const Account) bool {
        return self.state.login != .none or self.residue();
    }

    /// A sign-in waits for the operation underway to end.
    pub fn loginWaiting(self: *const Account) bool {
        return self.state.intent == .login;
    }

    pub fn activeAttempt(self: *const Account) ?u64 {
        return self.state.activeAttempt();
    }

    pub fn refreshInFlight(self: *const Account) bool {
        return self.state.op == .renew;
    }

    pub fn identityInFlight(self: *const Account) bool {
        return self.state.op == .identity;
    }

    /// A renewal or an identity request: what a waiting consumer waits for.
    pub fn confirmationInFlight(self: *const Account) bool {
        return switch (self.state.op) {
            .renew, .identity => true,
            .idle, .authorize => false,
        };
    }

    /// A renewal may still follow: a login is held.
    pub fn renewable(self: *const Account) bool {
        return self.state.login != .none;
    }

    /// A held login waits for its next confirmation.
    pub fn confirming(self: *const Account) bool {
        return self.state.login == .held and self.state.op == .idle;
    }

    pub fn unconfirmed(self: *const Account) bool {
        return self.state.login == .held;
    }

    pub fn activeRequestUsesCredential(self: *const Account) bool {
        return switch (self.state.op) {
            .renew, .identity => true,
            .idle, .authorize => false,
        };
    }

    /// Borrows the committed identity; `currentIdentity` returns a copy.
    pub fn accountId(self: *const Account) []const u8 {
        return switch (self.state.login) {
            .verified => |*identity| identity.account_id.view(),
            .none, .held => "",
        };
    }

    pub fn currentIdentity(self: *const Account) ?AccountIdentity {
        return switch (self.state.login) {
            .verified => |identity| identity,
            .none, .held => null,
        };
    }

    pub fn prepareCommand(
        self: *const Account,
        command: contract.AccountCommand,
    ) PrepareResult {
        contract.validateCommand(command) catch
            return .{ .rejected = .invalid_command };
        return switch (command) {
            .begin_login => self.prepareBeginLogin(),
            .cancel_operation => self.prepareCancel(),
            .retry_refresh => self.prepareRetryRefresh(),
            // Summary effects are coordinated by Account Runtime and never
            // enter the identity transaction state machine.
            .refresh_summary => .{ .rejected = .invalid_state },
            .open_recharge => .{ .rejected = .invalid_state },
            // Account Runtime deletes what is stored before this state ends.
            .logout => .{ .rejected = .invalid_state },
        };
    }

    /// What reading the store found: at start, or again after it could not
    /// be read.
    pub fn prepareRestore(
        self: *const Account,
        restore: *RestoreResult,
    ) PrepareResult {
        if ((self.storeRead() and !self.readsStoreAgain()) or self.state.op != .idle) {
            restore.deinit();
            return .{ .rejected = .invalid_state };
        }
        var next = self.state;
        next.clearError();
        next.login = switch (restore.*) {
            .signed_out => .{ .none = .{} },
            .refresh_only => .held,
        };
        return transitionNoAttempt(next, .restored);
    }

    /// Reading the store found no login it can use. `unreadable` when reading
    /// it again may: nothing was written over what it holds.
    pub fn prepareSignedOutRestoreFailure(
        self: *const Account,
        failure: WorkerFailure,
        unreadable: bool,
    ) PrepareResult {
        if ((self.storeRead() and !self.readsStoreAgain()) or self.state.op != .idle)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.login = .{ .none = .{ .reason = if (unreadable) .unreadable else .absent } };
        next.setFailure(if (failure.error_code == .none) .fromCode(.credential_store_read_failed) else failure);
        return transitionNoAttempt(next, .operation_failed);
    }

    pub fn prepareTokenRefresh(self: *const Account) PrepareResult {
        if (self.state.login != .verified or self.state.op != .idle)
            return .{ .rejected = .invalid_state };
        return self.prepareRenewal();
    }

    pub fn prepareRestoredTokenRefresh(self: *const Account) PrepareResult {
        if (self.state.login != .held or self.state.op != .idle)
            return .{ .rejected = .invalid_state };
        return self.prepareRenewal();
    }

    fn prepareRenewal(self: *const Account) PrepareResult {
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.op = .{ .renew = .{ .attempt = attempt.current } };
        next.next_attempt_id = attempt.next;
        // Trying again says nothing new: what went wrong stays shown until
        // this attempt says otherwise.
        return transition(next, .session_changed, attempt.current, .refresh_token);
    }

    /// Reads the identity of a held login whose token is already exchanged.
    pub fn prepareRestoredIdentity(self: *const Account) PrepareResult {
        if (!self.confirming()) return .{ .rejected = .invalid_state };
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.op = .{ .identity = .{ .attempt = attempt.current } };
        next.next_attempt_id = attempt.next;
        return transition(next, .session_changed, attempt.current, .load_identity);
    }

    pub fn prepareLoginExchange(
        self: *const Account,
        attempt_id: u64,
    ) PrepareResult {
        const authorize = switch (self.state.op) {
            .authorize => |value| value,
            else => return .{ .rejected = .invalid_state },
        };
        if (authorize.exchanging) return .{ .rejected = .invalid_state };
        if (authorize.attempt != attempt_id) return .ignored_stale;
        var next = self.state;
        next.op = .{ .authorize = .{ .attempt = attempt_id, .exchanging = true } };
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
        next.login = .{ .none = .{} };
        next.op = .idle;
        next.intent = .none;
        next.clearError();
        const active_attempt = self.state.activeAttempt();
        return .{
            .next = next,
            .fact_kind = .session_changed,
            .attempt_id = active_attempt,
            .effect = .{ .shutdown = active_attempt },
        };
    }

    pub fn prepareRefreshScheduleFailure(self: *const Account) PrepareResult {
        if (self.state.login != .verified or self.state.op != .idle)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.error_code = .refresh_schedule_failed;
        next.safe_diagnostic.clear();
        return transitionNoAttempt(next, .operation_failed);
    }

    pub fn prepareRetryRefresh(self: *const Account) PrepareResult {
        if (self.state.login != .verified or self.state.op != .idle)
            return .{ .rejected = .invalid_state };
        var next = self.state;
        next.clearError();
        return transitionNoAttempt(next, .session_changed);
    }

    /// A login is only begun where none is verified: changing accounts means
    /// signing out first. A renewal that may be sent is waited for, and the
    /// sign-in is not needed if that renewal confirms the login. An identity
    /// request is given up for it: it holds nothing.
    fn prepareBeginLogin(self: *const Account) PrepareResult {
        return self.prepareLoginOver(false);
    }

    /// As a sign-in is begun, but over a renewal Runtime stopped before it
    /// could send anything: that renewal is given up too.
    pub fn prepareBeginLoginOverUnsentRenewal(self: *const Account) PrepareResult {
        if (self.state.op != .renew) return .{ .rejected = .invalid_state };
        return self.prepareLoginOver(true);
    }

    fn prepareLoginOver(self: *const Account, renewal_unsent: bool) PrepareResult {
        const accepted = switch (self.state.login) {
            .none => self.storeRead(),
            .held => true,
            .verified => false,
        };
        if (!accepted or self.state.intent != .none)
            return .{ .rejected = .invalid_state };
        const given_up: ?u64 = switch (self.state.op) {
            .idle => null,
            .renew => |value| if (renewal_unsent) value.attempt else {
                var next = self.state;
                next.intent = .login;
                return transitionNoEffect(next, .session_changed, value.attempt);
            },
            .identity => |value| value.attempt,
            .authorize => return .{ .rejected = .invalid_state },
        };
        var begun = self.prepareAuthorize();
        switch (begun) {
            .transition => |*value| value.abandoned = given_up,
            else => {},
        }
        return begun;
    }

    /// A sign-in that waited for the operation before it may begin now.
    pub fn prepareWaitingLogin(self: *const Account) PrepareResult {
        if (self.state.intent != .login or self.state.op != .idle)
            return .{ .rejected = .invalid_state };
        return self.prepareAuthorize();
    }

    fn prepareAuthorize(self: *const Account) PrepareResult {
        const attempt = nextAttempt(self.state.next_attempt_id) orelse
            return .{ .rejected = .generation_mismatch };
        var next = self.state;
        next.op = .{ .authorize = .{ .attempt = attempt.current } };
        next.intent = .none;
        next.next_attempt_id = attempt.next;
        next.clearError();
        return transition(next, .session_changed, attempt.current, .begin_oauth);
    }

    /// Withdraws a sign-in still waiting, or gives up one waiting for its
    /// browser callback.
    fn prepareCancel(self: *const Account) PrepareResult {
        if (!self.state.canCancel()) return .{ .rejected = .invalid_state };
        const attempt_id = self.state.activeAttempt().?;
        var next = self.state;
        if (self.state.intent == .login) {
            next.intent = .none;
            return transitionNoEffect(next, .session_changed, attempt_id);
        }
        next.op = .idle;
        next.error_code = .user_cancelled;
        next.safe_diagnostic.clear();
        var result = transitionNoEffect(next, .operation_failed, attempt_id);
        result.transition.abandoned = attempt_id;
        return result;
    }

    /// The login's stored refresh token is deleted, or could not be
    /// (`residue`). Either way no login is held from here, and whatever
    /// operation was underway is given up: its result is no longer wanted.
    pub fn prepareSignedOut(self: *const Account, residue_left: bool, failure: ?WorkerFailure) PrepareResult {
        if (!self.acceptsLogout()) return .{ .rejected = .invalid_state };
        var next = self.state;
        next.login = .{ .none = .{ .reason = .logged_out, .residue = residue_left } };
        next.op = .idle;
        next.intent = .none;
        if (failure) |value| next.setFailure(value) else next.clearError();
        const attempt_id = self.state.activeAttempt();
        var result = if (attempt_id) |id|
            transitionNoEffect(next, .signed_out, id)
        else
            transitionNoAttempt(next, .signed_out);
        result.transition.abandoned = attempt_id;
        return result;
    }

    /// Nothing could be deleted, so nothing changed but the error shown.
    pub fn prepareLogoutFailure(self: *const Account, failure: WorkerFailure) PrepareResult {
        if (!self.acceptsLogout()) return .{ .rejected = .invalid_state };
        var next = self.state;
        next.setFailure(failure);
        return if (self.state.activeAttempt()) |id|
            transitionNoEffect(next, .operation_failed, id)
        else
            transitionNoAttempt(next, .operation_failed);
    }

    /// The token exchange underway was answered and its refresh token is
    /// stored. A login's tokens are now the held login: whatever was held or
    /// verified before ends here, and its identity is asked next. Unlike a
    /// worker's completion, a refusal stays one: nothing may be stored for it.
    pub fn prepareTokensStored(self: *const Account) PrepareResult {
        var next = self.state;
        switch (self.state.op) {
            .authorize => |value| {
                if (!value.exchanging) return .{ .rejected = .invalid_state };
                next.login = .held;
                next.op = .{ .identity = .{ .attempt = value.attempt } };
                next.clearError();
                return transition(next, .session_changed, value.attempt, .load_identity);
            },
            .renew => |value| switch (self.state.login) {
                .held => {
                    next.op = .{ .identity = .{ .attempt = value.attempt } };
                    return transition(next, .session_changed, value.attempt, .load_identity);
                },
                .verified => {
                    next.op = .idle;
                    next.clearError();
                    return transitionNoEffect(next, .session_changed, value.attempt);
                },
                .none => unreachable,
            },
            .idle, .identity => return .{ .rejected = .invalid_state },
        }
    }

    fn prepareIdentityLoaded(
        self: *const Account,
        identity: AccountIdentity,
    ) PrepareResult {
        const loading = switch (self.state.op) {
            .identity => |value| value,
            else => return .{ .rejected = .invalid_state },
        };
        var next = self.state;
        next.login = .{ .verified = identity };
        next.op = .idle;
        // A sign-in that waited for this confirmation is not needed any more.
        next.intent = .none;
        next.clearError();
        return transitionNoEffect(next, .session_changed, loading.attempt);
    }

    /// A failure returns the operation to idle. Only what proves the login
    /// unusable ends it: a renewal that cannot be sent again, and an identity
    /// the server says is gone. Runtime marks every other one retryable.
    fn prepareFailure(self: *const Account, failure_value: WorkerFailure) PrepareResult {
        const attempt_id = self.state.activeAttempt() orelse
            return .{ .rejected = .invalid_state };
        const failure = if (failure_value.error_code == .none)
            WorkerFailure.fromCode(.account_operation_failed)
        else
            failure_value;
        var next = self.state;
        switch (self.state.op) {
            .authorize => {},
            .renew, .identity => if (!failure.retryable) {
                next.login = .{ .none = .{ .residue = failure.residue } };
            },
            .idle => unreachable,
        }
        next.op = .idle;
        next.setFailure(failure);
        return transitionNoEffect(next, .operation_failed, attempt_id);
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
    const may_sign_in = state.login != .verified and state.storeRead();
    if (state.intent == .login and (!may_sign_in or state.op == .authorize)) return false;
    return switch (state.op) {
        .idle => true,
        .authorize => may_sign_in,
        .renew => state.login != .none,
        .identity => state.login == .held,
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
    /// The attempt whose worker this commit gives up: told to cancel, never
    /// waited for, and its result discarded.
    abandoned: ?u64 = null,
    committed: bool = false,

    /// A sign-in waits once this commits.
    pub fn loginWaits(self: *const PreparedTransition) bool {
        return self.next.intent == .login;
    }

    pub fn view(self: *const PreparedTransition) contract.AccountView {
        return self.next.view();
    }

    pub fn factKind(self: *const PreparedTransition) contract.AccountFactKind {
        return self.fact_kind;
    }

    pub fn finishesAttempt(self: *const PreparedTransition) bool {
        return self.attempt_id != null and self.next.activeAttempt() == null;
    }

    /// No login is held once this commits.
    pub fn endsLogin(self: *const PreparedTransition) bool {
        return self.next.login == .none;
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
    email_hint: EmailHint,
    phone_hint: PhoneHint,
    concurrency_limit: ?u32,

    pub fn init(
        account_id: []const u8,
        display_name: []const u8,
        email_hint: []const u8,
        phone_hint: []const u8,
        concurrency_limit: ?u32,
    ) contract.ValidationError!AccountIdentity {
        if (account_id.len == 0) return error.FieldEmpty;
        return .{
            .account_id = try .init(account_id),
            .display_name = try .init(display_name),
            .email_hint = try .init(email_hint),
            .phone_hint = try .init(phone_hint),
            .concurrency_limit = concurrency_limit,
        };
    }

    pub fn accountId(self: *const AccountIdentity) []const u8 {
        return self.account_id.view();
    }

    pub fn displayName(self: *const AccountIdentity) []const u8 {
        return self.display_name.view();
    }

    pub fn emailHint(self: *const AccountIdentity) []const u8 {
        return self.email_hint.view();
    }

    pub fn phoneHint(self: *const AccountIdentity) []const u8 {
        return self.phone_hint.view();
    }
};

pub const WorkerFailure = struct {
    error_code: contract.ErrorCode,
    safe_diagnostic: SafeDiagnostic = .{},
    /// Internal transport evidence only; never projected to the public Account wire.
    refresh_not_consumed: bool = false,
    /// Account Runtime proved this failure leaves the login usable and will
    /// try again. Any other renewal or identity failure ends the login.
    retryable: bool = false,
    /// Ending the login, Runtime could not delete its refresh token.
    residue: bool = false,

    pub fn fromCode(error_code: contract.ErrorCode) WorkerFailure {
        std.debug.assert(error_code != .none);
        return .{ .error_code = error_code };
    }

    /// A verified session's renewal is lost. It reads as the failure a
    /// restore from the same store reports; the cause stays diagnosable.
    pub fn renewalLost(cause: contract.ErrorCode) WorkerFailure {
        var failure: WorkerFailure = .fromCode(.token_refresh_failed);
        if (cause != .token_refresh_failed and cause != .none)
            failure.safe_diagnostic.set(@tagName(cause)) catch {};
        return failure;
    }
};

pub const WorkerCompletion = struct {
    attempt_id: u64,
    payload: Payload,

    pub const Payload = union(enum) {
        identity_loaded: AccountIdentity,
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
        if (account.storeRead()) return error.InvalidState;
        var next = account.state;
        next.login = .{ .verified = identity };
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
        .payload = .{ .identity_loaded = try .init("account-1", "User", "u***@example.com", "", 5) },
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

    var load_identity = switch (account.prepareTokensStored()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(load_identity.takeEffect().? == .load_identity);
    load_identity.commit(&account);
    load_identity.deinit();
    // The exchanged tokens are the held login now; only its identity is asked.
    try std.testing.expectEqual(contract.AccountState.checking, account.view().state);
    try std.testing.expectEqualStrings("", account.view().account_id);
    try std.testing.expect(!account.view().can_cancel and !account.view().can_retry);

    var identity: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-1", "User", "u***@example.com", "", 5) },
    };
    var authenticated = switch (account.prepareCompletion(&identity)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &authenticated);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-1", account.view().account_id);
    try std.testing.expectEqualStrings("u***@example.com", account.view().email_hint);
    try std.testing.expectEqualStrings("", account.view().phone_hint);
    try std.testing.expectEqual(@as(?u32, 5), account.view().concurrency_limit);
}

test "optional profile omissions do not block authenticated identity" {
    var account = Account.initSignedOutForTest();
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    try commitLoginExchange(&account);

    var load_identity = switch (account.prepareTokensStored()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &load_identity);

    var identity: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-1", "", "", "", null) },
    };
    var authenticated = switch (account.prepareCompletion(&identity)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &authenticated);

    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("account-1", account.view().account_id);
    try std.testing.expectEqualStrings("", account.view().display_name);
    try std.testing.expectEqualStrings("", account.view().email_hint);
    try std.testing.expectEqualStrings("", account.view().phone_hint);
    try std.testing.expectEqual(@as(?u32, null), account.view().concurrency_limit);
    try contract.validateView(account.view());
}

test "a login is refused over a verified one and replaces a held one" {
    var verified = Account.initRestoring();
    var verified_restore = try TestSupport.prepareAuthenticated(
        &verified,
        try AccountIdentity.init("account-1", "Old User", "o***@example.com", "", 5),
    );
    commitPrepared(&verified, &verified_restore);
    // Changing accounts means signing out first.
    try std.testing.expect(verified.prepareCommand(.begin_login) == .rejected);

    var account = Account.initRestoring();
    var restore: RestoreResult = .{ .refresh_only = {} };
    var restored = switch (account.prepareRestore(&restore)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &restored);
    var begin = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &begin);
    try commitLoginExchange(&account);
    var load_identity = switch (account.prepareTokensStored()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &load_identity);

    var identity: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("account-2", "New User", "n***@example.com", "", 0) },
    };
    var authenticated = switch (account.prepareCompletion(&identity)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &authenticated);
    try std.testing.expectEqualStrings("account-2", account.view().account_id);
    try std.testing.expectEqualStrings("New User", account.view().display_name);
    try std.testing.expectEqualStrings("n***@example.com", account.view().email_hint);
    try std.testing.expectEqual(@as(?u32, 0), account.view().concurrency_limit);
}

test "a login that fails before or after its exchange keeps what is held" {
    for ([_]enum { exchange, identity }{ .exchange, .identity }) |stage| {
        var account = Account.initRestoring();
        var restore: RestoreResult = .{ .refresh_only = {} };
        var restored = switch (account.prepareRestore(&restore)) {
            .transition => |value| value,
            else => return error.TestUnexpectedResult,
        };
        commitPrepared(&account, &restored);
        var begin = switch (account.prepareCommand(.begin_login)) {
            .transition => |value| value,
            else => return error.TestUnexpectedResult,
        };
        commitPrepared(&account, &begin);
        try commitLoginExchange(&account);
        if (stage == .identity) {
            var load_identity = switch (account.prepareTokensStored()) {
                .transition => |value| value,
                else => return error.TestUnexpectedResult,
            };
            commitPrepared(&account, &load_identity);
        }
        // An identity that could not be read says nothing about the login.
        var failure: WorkerFailure = .fromCode(if (stage == .exchange) .oauth_exchange_failed else .metask_service_unavailable);
        failure.retryable = stage == .identity;
        var completion: WorkerCompletion = .{
            .attempt_id = account.activeAttempt().?,
            .payload = .{ .failed = failure },
        };
        var failed = switch (account.prepareCompletion(&completion)) {
            .transition => |value| value,
            else => return error.TestUnexpectedResult,
        };
        commitPrepared(&account, &failed);
        try std.testing.expectEqual(std.meta.Tag(Login).held, account.login());
        try std.testing.expectEqual(contract.AccountState.checking, account.view().state);
        try std.testing.expect(account.view().can_retry);
        try contract.validateView(account.view());
    }
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
    var load_identity = switch (account.prepareTokensStored()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &load_identity);
    try std.testing.expectEqual(contract.AccountState.checking, account.view().state);

    var identified: WorkerCompletion = .{
        .attempt_id = account.activeAttempt().?,
        .payload = .{ .identity_loaded = try .init("22", "朱健", "z***@example.com", "+861****8000", 6) },
    };
    var completed = switch (account.prepareCompletion(&identified)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &completed);
    try std.testing.expectEqual(contract.AccountState.authenticated, account.view().state);
    try std.testing.expectEqualStrings("22", account.view().account_id);
    try std.testing.expectEqualStrings("朱健", account.view().display_name);
    try std.testing.expectEqualStrings("+861****8000", account.view().phone_hint);
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
    // Nothing proven about the stored login: it stays, and says why.
    var unreached_failure: WorkerFailure = .fromCode(.deadline_exceeded);
    unreached_failure.retryable = true;
    var unreached: WorkerCompletion = .{
        .attempt_id = cold.activeAttempt().?,
        .payload = .{ .failed = unreached_failure },
    };
    var waiting = switch (cold.prepareCompletion(&unreached)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&cold, &waiting);
    try std.testing.expectEqual(contract.AccountState.checking, cold.view().state);
    try std.testing.expectEqual(contract.ErrorCode.deadline_exceeded, cold.view().error_code);
    try std.testing.expect(cold.view().can_retry);
    var again = switch (cold.prepareRestoredTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&cold, &again);
    // Trying again neither shows another state nor offers its actions.
    try std.testing.expectEqual(contract.ErrorCode.deadline_exceeded, cold.view().error_code);
    try std.testing.expect(!cold.view().can_retry);
    try contract.validateView(cold.view());

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
        try AccountIdentity.init("account-1", "Metask User", "m***@example.com", "", 5),
    );
    commitPrepared(&active, &active_restore);

    // Only a failure the Runtime proved unsent keeps the verified identity.
    var unsent_refresh = switch (active.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&active, &unsent_refresh);
    var unsent_failure: WorkerFailure = .fromCode(.metask_service_unavailable);
    unsent_failure.retryable = true;
    var unsent: WorkerCompletion = .{
        .attempt_id = active.activeAttempt().?,
        .payload = .{ .failed = unsent_failure },
    };
    var kept = switch (active.prepareCompletion(&unsent)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&active, &kept);
    try std.testing.expectEqual(contract.AccountState.authenticated, active.view().state);
    try std.testing.expectEqual(contract.ErrorCode.metask_service_unavailable, active.view().error_code);

    var lost_refresh = switch (active.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&active, &lost_refresh);
    var lost: WorkerCompletion = .{
        .attempt_id = active.activeAttempt().?,
        .payload = .{ .failed = .renewalLost(.metask_rate_limited) },
    };
    var signed_out = switch (active.prepareCompletion(&lost)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&active, &signed_out);
    try std.testing.expectEqual(contract.AccountState.signed_out, active.view().state);
    try std.testing.expectEqualStrings("", active.view().account_id);
    try std.testing.expectEqual(contract.ErrorCode.token_refresh_failed, active.view().error_code);
    try std.testing.expectEqualStrings("metask_rate_limited", active.view().safe_diagnostic);

    var replaced = Account.initRestoring();
    var replaced_restore = try TestSupport.prepareAuthenticated(
        &replaced,
        try AccountIdentity.init("account-1", "Metask User", "m***@example.com", "", 5),
    );
    commitPrepared(&replaced, &replaced_restore);
    var replaced_refresh = switch (replaced.prepareTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&replaced, &replaced_refresh);
    var unauthorized: WorkerCompletion = .{
        .attempt_id = replaced.activeAttempt().?,
        .payload = .{ .failed = .fromCode(.metask_unauthorized) },
    };
    var invalid = switch (replaced.prepareCompletion(&unauthorized)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&replaced, &invalid);
    try std.testing.expectEqual(contract.AccountState.signed_out, replaced.view().state);
    try std.testing.expectEqualStrings("", replaced.view().account_id);
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
        true,
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
        try AccountIdentity.init("account-1", "Metask User", "m***@example.com", "", 5),
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

test "a logout is taken from any login and from what one left, and a waiting sign-in can be withdrawn" {
    var account = Account.initRestoring();
    var restore: RestoreResult = .{ .refresh_only = {} };
    var restored = switch (account.prepareRestore(&restore)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &restored);
    var renewal = switch (account.prepareRestoredTokenRefresh()) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &renewal);
    const attempt_id = account.activeAttempt().?;

    // A sign-in waits for the renewal; withdrawing it leaves the renewal.
    var waiting = switch (account.prepareCommand(.begin_login)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &waiting);
    try std.testing.expectEqual(contract.AccountState.authorizing, account.view().state);
    try std.testing.expect(account.view().can_cancel);
    var withdrawn = switch (account.prepareCommand(.cancel_operation)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(withdrawn.abandoned == null);
    commitPrepared(&account, &withdrawn);
    try std.testing.expectEqual(contract.AccountState.checking, account.view().state);
    try std.testing.expectEqual(@as(?u64, attempt_id), account.activeAttempt());

    // A logout during it gives the renewal up; a token it could not delete
    // leaves a residue that a second logout clears.
    var residue = switch (account.prepareSignedOut(true, .fromCode(.credential_store_delete_failed))) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u64, attempt_id), residue.abandoned);
    commitPrepared(&account, &residue);
    try std.testing.expectEqual(contract.AccountState.signed_out, account.view().state);
    try std.testing.expect(account.residue() and account.activeAttempt() == null);
    try contract.validateView(account.view());
    var cleared = switch (account.prepareSignedOut(false, null)) {
        .transition => |value| value,
        else => return error.TestUnexpectedResult,
    };
    commitPrepared(&account, &cleared);
    try std.testing.expect(!account.residue() and !account.acceptsLogout());
    try std.testing.expect(account.prepareSignedOut(false, null) == .rejected);
}
