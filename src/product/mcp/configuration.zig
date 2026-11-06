//! Workbench-owned Product MCP configuration, persistence, preparation, and transaction kernel.
//! The registry contains product configuration and credential locators only;
//! credential material is resolved by a separate Host capability.

const std = @import("std");
const builtin = @import("builtin");
const mcp_http_protocol = @import("agent_mcp_http_protocol");
const grant_schedule = @import("grant_schedule.zig");

pub const schema_version: u8 = 3;
pub const transaction_schema_version: u8 = 1;
pub const file_name = "registry.json";
pub const transaction_file_name = "transaction.json";
pub const max_store_bytes: usize = 256 * 1024;
pub const max_transaction_bytes: usize = 64 * 1024;
const lock_file_name = ".registry.lock";

/// Management exchanges have a Host ceiling; tool calls keep the user timeout.
pub const max_management_timeout_ms: u32 = 120_000;
pub const candidate_timeout_windows: u32 = 8;
pub fn managementTimeoutMs(configured: u32) u32 {
    return @min(configured, max_management_timeout_ms);
}

pub const Limits = struct {
    max_servers: usize,
    max_tools_per_server: usize,
    max_identity_bytes: usize = 128,
    max_display_name_bytes: usize = 256,
    max_namespace_bytes: usize,
    max_command_bytes: usize = 4096,
    max_argument_count: usize = 128,
    max_argument_bytes: usize = 16 * 1024,
    max_environment_count: usize = 128,
    max_header_count: usize = 128,
    max_url_bytes: usize = 4096,
    max_credential_locators: usize,
    max_credential_locator_bytes: usize = 256,
    max_credential_secret_bytes: usize = 16 * 1024,
    max_runtime_secrets_per_server: usize,
    max_runtime_secret_bytes_per_server: usize,
    max_tool_name_bytes: usize = 256,
    max_oauth_scopes: usize = 128,
    max_oauth_scope_bytes: usize = 256,
    max_oauth_uri_bytes: usize = 4096,
    max_oauth_client_id_bytes: usize = 4096,
};

pub const Error = error{
    RegistryEmpty,
    RegistryTooLarge,
    RegistryCorrupt,
    RegistryEncodeFailed,
    GenerationMismatch,
    GenerationExhausted,
    InvalidMutation,
    TransactionCorrupt,
    TransactionEncodeFailed,
    TransactionGenerationMismatch,
    TransactionRegistryMismatch,
    CredentialCleanupFailed,
};

pub const FileStoreError = std.mem.Allocator.Error || error{
    DirectoryUnavailable,
    WriterAlreadyActive,
    ReadFailed,
    WriteFailed,
    PersistenceOutcomeUnknown,
};

pub const RegistryWire = struct {
    schema_version: u8,
    generation: u64,
    oauth_operation: ?OauthOperationWire,
    servers: []ServerWire,
};

pub const ServerWire = struct {
    id: []const u8,
    namespace: []const u8,
    display_name: []const u8,
    enabled: bool,
    negotiation: []const u8,
    timeout_ms: u32,
    transport: TransportWire,
    auth: AuthWire,
    connection_approval: ?ConnectionApprovalWire,
    tools: []const []const u8,
    installation: ?InstallationWire = null,
};

/// Durable, secret-free progress attached to the exact installed server.
/// Only the Product installation path can create or advance this record.
pub const initial_installation_timeout_ms: u32 = 180_000;
pub fn initialInstallation(server: ServerWire) bool {
    const operation = server.installation orelse return false;
    return std.mem.eql(u8, server.transport.kind, "stdio") and operation.phase == .connecting and operation.initial_grant_pending;
}

pub const installation_active_budget_ms = 300_000;

pub const InstallationPhase = enum {
    preparing,
    acquiring_credentials,
    needs_authorization,
    needs_credentials,
    needs_oauth,
    connecting,
    ready,
    no_tools,
    failed,
    cancelled,
    pub fn allows(self: @This(), next: @This()) bool {
        if (!self.active()) return false;
        if (next == .failed or next == .cancelled or next == self) return true;
        return switch (self) {
            .preparing => next == .needs_authorization or next == .acquiring_credentials or next == .needs_credentials or next == .needs_oauth or next == .connecting,
            .needs_authorization => next == .preparing,
            .acquiring_credentials => next == .preparing or next == .needs_credentials or next == .needs_oauth or next == .connecting,
            .needs_credentials => next == .preparing or next == .needs_oauth or next == .connecting,
            .needs_oauth => next == .connecting,
            .connecting => next == .ready or next == .no_tools,
            else => false,
        };
    }
    pub fn active(self: @This()) bool {
        return switch (self) {
            .ready, .no_tools, .failed, .cancelled => false,
            else => true,
        };
    }
};
pub const InstallationWire = struct {
    task_id: u64,
    run_id: u64,
    source_message_id: u64,
    revision: u64,
    source_origin: []const u8,
    request_refs: []const []const u8,
    phase: InstallationPhase,
    initial_grant_pending: bool = true,
    initial_grant_completed: bool = false,
    cross_origin_authorized: bool = false,
    active_elapsed_ms: u32 = 0,
    stop_pending: bool = false,
};
pub const InstallationStart = struct {
    task_id: u64,
    run_id: u64,
    source_message_id: u64,
    source_origin: []const u8,
    phase: InstallationPhase = .preparing,
    request: []const u8,
    existing_server_id: ?[]const u8 = null,
};
pub const InstallationConnection = union(enum) {
    http: CreateHttpServerInput,
    oauth: CreateOauthHttpServerInput,
    stdio: CreateStdioServerInput,
};
pub const InstallationUpdate = struct {
    server_id: []const u8,
    expected_revision: u64,
    phase: InstallationPhase,
    active_elapsed_ms: u32,
    cross_origin_authorized: bool = false,
    /// Supplied only from a validated current catalog by Product Runtime.
    initial_tools: ?[]const []const u8 = null,
};

pub fn serverEnabled(server: ServerWire) bool {
    if (!server.enabled) return false;
    if (server.installation) |operation| return !operation.stop_pending;
    return true;
}

pub const AuthWire = struct {
    kind: []const u8,
    oauth: ?OauthAuthorizationWire,
};

pub const ConnectionApprovalWire = struct {
    fingerprint: []const u8,
};

pub const OauthAuthorizationWire = struct {
    status: []const u8,
    registration: OauthRegistrationWire,
    consent: ?OauthConsentWire,
    grant: ?OauthGrantWire,
    pending_resource: ?SensitiveEndpointWire = null,
};

pub const OauthRegistrationWire = struct {
    kind: []const u8,
    issuer: ?[]const u8,
    client_id: ?[]const u8,
    token_endpoint_auth_method: ?[]const u8,
    client_credential_revision: u64,
    client_secret_ref: ?[]const u8,
};

pub const OauthConsentWire = struct {
    epoch: u64,
    fingerprint: []const u8,
    resource: []const u8,
    private_resource: ?SensitiveEndpointWire = null,
    issuer: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
    client_credential_revision: u64,
};

pub const OauthGrantWire = struct {
    consent_epoch: u64,
    token_revision: u64,
    access_token_ref: []const u8,
    refresh_token_ref: ?[]const u8,
    expires_at_unix_ms: ?u64,
};

pub const OauthConsentDraftWire = struct {
    resource: []const u8,
    private_resource: ?SensitiveEndpointWire = null,
    issuer: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
};

pub const OauthOperationWire = struct {
    id: []const u8,
    kind: []const u8,
    server_id: []const u8,
    connection_fingerprint: []const u8,
    consent_fingerprint: []const u8,
    consent_epoch: u64,
    token_revision: ?u64,
    consent_draft: ?OauthConsentDraftWire = null,
};

const LegacyRegistryWire = struct {
    schema_version: u8,
    generation: u64,
    servers: []LegacyServerWire,
};

const LegacyServerWire = struct {
    id: []const u8,
    namespace: []const u8,
    display_name: []const u8,
    enabled: bool,
    negotiation: []const u8,
    timeout_ms: u32,
    transport: LegacyTransportWire,
    tools: []const []const u8 = &.{},
};

const LegacyTransportWire = struct {
    kind: []const u8,
    command: ?[]const u8 = null,
    arguments: []ValueSourceWire = &.{},
    cwd: ?[]const u8 = null,
    environment: []LegacyNamedValueWire = &.{},
    url: ?[]const u8 = null,
    headers: []LegacyNamedValueWire = &.{},
};

const LegacyNamedValueWire = struct {
    name: []const u8,
    value: ValueSourceWire,
};

pub const TransportWire = struct {
    kind: []const u8,
    command: ?[]const u8 = null,
    arguments: []ValueSourceWire = &.{},
    cwd: ?[]const u8 = null,
    environment: []SecretSlotWire = &.{},
    url: ?[]const u8 = null,
    sensitive_endpoint: ?SensitiveEndpointWire = null,
    headers: []SecretSlotWire = &.{},
};

/// Only the public origin and a Host-generated identity are configuration.
/// Every ordered URL part, including template literals, lives in credential storage.
pub const SensitiveEndpointWire = struct {
    origin: []const u8,
    identity: []const u8,
    credential_refs: []const []const u8,
    secret_parts: []const u32 = &.{},
};

pub const EndpointPartInput = struct {
    value: []const u8,
    is_credential: bool,
};

pub fn endpointDisplay(transport: TransportWire) []const u8 {
    if (transport.sensitive_endpoint) |endpoint| return endpoint.origin;
    return transport.url orelse "";
}

pub fn endpointOrigin(value: []const u8, max_bytes: usize) ?[]const u8 {
    if (!validEndpoint(value, max_bytes)) return null;
    const scheme = std.mem.indexOf(u8, value, "://") orelse return null;
    const end = std.mem.indexOfAnyPos(u8, value, scheme + 3, "/?") orelse value.len;
    return value[0..end];
}

/// The caller owns and must clear the complete private URL after use.
pub fn resolveEndpoint(
    allocator: std.mem.Allocator,
    transport: TransportWire,
    credentials: []const ResolvedCredential,
    max_bytes: usize,
) (std.mem.Allocator.Error || error{InvalidEndpoint})![]u8 {
    if (transport.sensitive_endpoint) |endpoint| {
        var length: usize = 0;
        for (endpoint.credential_refs) |locator| {
            const part = resolvedCredential(credentials, locator) orelse return error.InvalidEndpoint;
            length = std.math.add(usize, length, part.len) catch return error.InvalidEndpoint;
            if (length > max_bytes) return error.InvalidEndpoint;
        }
        const value = try allocator.alloc(u8, length);
        errdefer secureFree(allocator, value);
        var offset: usize = 0;
        for (endpoint.credential_refs) |locator| {
            const part = resolvedCredential(credentials, locator).?;
            @memcpy(value[offset..][0..part.len], part);
            offset += part.len;
        }
        const origin = endpointOrigin(value, max_bytes) orelse return error.InvalidEndpoint;
        if (!std.mem.eql(u8, origin, endpoint.origin)) return error.InvalidEndpoint;
        return value;
    }
    const value = transport.url orelse return error.InvalidEndpoint;
    if (!validEndpoint(value, max_bytes)) return error.InvalidEndpoint;
    return allocator.dupe(u8, value);
}

pub fn resolvePrivateEndpoint(allocator: std.mem.Allocator, endpoint: SensitiveEndpointWire, resolver: CredentialResolver, limits: Limits) (std.mem.Allocator.Error || error{ InvalidEndpoint, CredentialStoreUnavailable })![]u8 {
    var credentials: std.ArrayList(ResolvedCredential) = .empty;
    defer {
        for (credentials.items) |credential| secureFree(allocator, credential.secret);
        credentials.deinit(allocator);
    }
    for (endpoint.credential_refs) |locator|
        if (!try resolveCredential(allocator, locator, resolver, limits, &credentials)) return error.InvalidEndpoint;
    return resolveEndpoint(allocator, .{ .kind = "streamable_http", .sensitive_endpoint = endpoint }, credentials.items, limits.max_url_bytes);
}

pub fn ownSensitiveEndpoint(arena: *std.heap.ArenaAllocator, endpoint: ?SensitiveEndpointWire) std.mem.Allocator.Error!?SensitiveEndpointWire {
    const value = endpoint orelse return null;
    const allocator = arena.allocator();
    const refs = try allocator.alloc([]const u8, value.credential_refs.len);
    // Callers use an arena: the copied descriptor and references have one owner.
    for (value.credential_refs, refs) |source, *dest| dest.* = try allocator.dupe(u8, source);
    return .{ .origin = try allocator.dupe(u8, value.origin), .identity = try allocator.dupe(u8, value.identity), .credential_refs = refs, .secret_parts = try allocator.dupe(u32, value.secret_parts) };
}

/// Exactly one field must be present. `literal` is ordinary configuration;
/// credential material must be represented by `credential_ref`.
pub const ValueSourceWire = struct {
    literal: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
};

pub const SecretSlotWire = struct {
    name: []const u8,
    credential_ref: ?[]const u8,
};

pub const TransactionWire = struct {
    schema_version: u8,
    base_generation: u64,
    target_generation: u64,
    candidate_locators: []const []const u8,
    retired_locators: []const []const u8,
};

/// Owned, effect-free plan for one base -> target registry transaction. The
/// immutable target is the same value validated by the planner, encoded by the
/// coordinator, and installed as desired state after a successful commit.
/// Candidate locators are exactly the fresh credential identities introduced
/// by target; retired locators are derived from the trusted reference-set
/// difference and are never accepted from a caller.
pub const MutationPlan = struct {
    arena: std.heap.ArenaAllocator,
    target: ?std.json.Parsed(RegistryWire),
    transaction: TransactionWire,

    pub fn targetRegistry(self: *const MutationPlan) Error!RegistryWire {
        return if (self.target) |target| target.value else error.InvalidMutation;
    }

    fn takeTarget(self: *MutationPlan) std.json.Parsed(RegistryWire) {
        const target = self.target.?;
        self.target = null;
        return target;
    }

    pub fn deinit(self: *MutationPlan) void {
        if (self.target) |*target| target.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Same-file transition for durable operation markers, without network effects.
/// It deliberately carries no credential journal and does not advance the
/// desired generation because no server target changed.
pub const OperationStatePlan = struct {
    base: std.json.Parsed(RegistryWire),
    target: ?std.json.Parsed(RegistryWire),

    pub fn targetRegistry(self: *const OperationStatePlan) Error!RegistryWire {
        return if (self.target) |target| target.value else error.InvalidMutation;
    }

    pub fn takeTarget(self: *OperationStatePlan) std.json.Parsed(RegistryWire) {
        const target = self.target.?;
        self.target = null;
        return target;
    }

    pub fn deinit(self: *OperationStatePlan) void {
        if (self.target) |*target| target.deinit();
        self.base.deinit();
        self.* = undefined;
    }
};

pub const CredentialCleanup = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    delete_fn: *const fn (?*anyopaque, []const u8) bool = unavailableDelete,

    fn delete(self: CredentialCleanup, locator: []const u8) bool {
        return self.available and self.delete_fn(self.context, locator);
    }

    fn unavailableDelete(_: ?*anyopaque, _: []const u8) bool {
        return false;
    }
};

pub const StoreHealth = enum {
    ready,
    recovery_required,
    outcome_unknown,
};

pub const PersistenceEffect = enum {
    committed,
    failed,
    outcome_unknown,
};

pub const MutationPersistence = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    commit_journal_fn: *const fn (?*anyopaque, []const u8) PersistenceEffect = unavailableCommit,
    commit_registry_fn: *const fn (?*anyopaque, []const u8) PersistenceEffect = unavailableCommit,
    clear_journal_fn: *const fn (?*anyopaque) PersistenceEffect = unavailableClear,

    fn commitJournal(self: MutationPersistence, bytes: []const u8) PersistenceEffect {
        if (!self.available) return .failed;
        return self.commit_journal_fn(self.context, bytes);
    }

    fn commitRegistry(self: MutationPersistence, bytes: []const u8) PersistenceEffect {
        if (!self.available) return .failed;
        return self.commit_registry_fn(self.context, bytes);
    }

    fn clearJournal(self: MutationPersistence) PersistenceEffect {
        if (!self.available) return .failed;
        return self.clear_journal_fn(self.context);
    }

    fn unavailableCommit(_: ?*anyopaque, _: []const u8) PersistenceEffect {
        return .failed;
    }

    fn unavailableClear(_: ?*anyopaque) PersistenceEffect {
        return .failed;
    }
};

pub const CredentialPresence = enum {
    missing,
    present,
    unavailable,
};

pub const CredentialEffects = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    probe_fn: *const fn (?*anyopaque, []const u8) CredentialPresence = unavailableProbe,
    create_fn: *const fn (?*anyopaque, []const u8, []const u8) bool = unavailableCreate,
    delete_fn: *const fn (?*anyopaque, []const u8) bool = unavailableDelete,

    fn probe(self: CredentialEffects, locator: []const u8) CredentialPresence {
        if (!self.available) return .unavailable;
        return self.probe_fn(self.context, locator);
    }

    fn create(self: CredentialEffects, locator: []const u8, secret: []const u8) bool {
        return self.available and self.create_fn(self.context, locator, secret);
    }

    fn delete(self: CredentialEffects, locator: []const u8) bool {
        return self.available and self.delete_fn(self.context, locator);
    }

    fn unavailableProbe(_: ?*anyopaque, _: []const u8) CredentialPresence {
        return .unavailable;
    }

    fn unavailableCreate(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }

    fn unavailableDelete(_: ?*anyopaque, _: []const u8) bool {
        return false;
    }
};

pub const CandidateCredential = struct {
    locator: []const u8,
    secret: []u8,
};

pub const MutationCommit = enum {
    saved,
    saved_recovery_required,
    not_saved,
    not_saved_recovery_required,
    registry_outcome_unknown,
    blocked,
};

/// Serial owner for the single durable MCP credential transaction. The plan
/// owns the registry bytes; callers retain candidate secret storage, which is
/// securely zeroed on every return path.
pub const TransactionCoordinator = struct {
    health: StoreHealth = .ready,

    pub fn commit(
        self: *TransactionCoordinator,
        allocator: std.mem.Allocator,
        persistence: MutationPersistence,
        credentials: CredentialEffects,
        plan: *const MutationPlan,
        candidates: []CandidateCredential,
        limits: Limits,
    ) (Error || std.mem.Allocator.Error)!MutationCommit {
        defer for (candidates) |candidate| std.crypto.secureZero(u8, candidate.secret);
        if (self.health != .ready) return .blocked;
        try validateCommitInputs(plan, candidates, limits);

        const registry_buffer = try allocator.alloc(u8, max_store_bytes);
        defer allocator.free(registry_buffer);
        const registry_bytes = try encode(
            registry_buffer,
            try plan.targetRegistry(),
            limits,
        );
        const journal_buffer = try allocator.alloc(u8, max_transaction_bytes);
        defer allocator.free(journal_buffer);
        const journal_bytes = try encodeTransaction(
            journal_buffer,
            plan.transaction,
            limits,
        );

        for (plan.transaction.candidate_locators) |locator| switch (credentials.probe(locator)) {
            .missing => {},
            .present, .unavailable => return .not_saved,
        };

        switch (persistence.commitJournal(journal_bytes)) {
            .committed => {},
            .failed => return .not_saved,
            .outcome_unknown => {
                self.health = .outcome_unknown;
                return .not_saved_recovery_required;
            },
        }
        for (plan.transaction.candidate_locators) |locator| {
            const candidate = candidateForLocator(candidates, locator) orelse unreachable;
            if (!credentials.create(locator, candidate.secret))
                return self.recoverBase(
                    persistence,
                    credentials,
                    plan.transaction.candidate_locators,
                );
        }
        switch (persistence.commitRegistry(registry_bytes)) {
            .committed => {},
            .failed => return self.recoverBase(
                persistence,
                credentials,
                plan.transaction.candidate_locators,
            ),
            .outcome_unknown => {
                self.health = .outcome_unknown;
                return .registry_outcome_unknown;
            },
        }
        if (!deleteAll(credentials, plan.transaction.retired_locators)) {
            self.health = .recovery_required;
            return .saved_recovery_required;
        }
        return switch (persistence.clearJournal()) {
            .committed => .saved,
            .failed => blocked: {
                self.health = .recovery_required;
                break :blocked .saved_recovery_required;
            },
            .outcome_unknown => blocked: {
                self.health = .outcome_unknown;
                break :blocked .saved_recovery_required;
            },
        };
    }

    fn recoverBase(
        self: *TransactionCoordinator,
        persistence: MutationPersistence,
        credentials: CredentialEffects,
        candidate_locators: []const []const u8,
    ) MutationCommit {
        if (!deleteAll(credentials, candidate_locators)) {
            self.health = .recovery_required;
            return .not_saved_recovery_required;
        }
        return switch (persistence.clearJournal()) {
            .committed => .not_saved,
            .failed => blocked: {
                self.health = .recovery_required;
                break :blocked .not_saved_recovery_required;
            },
            .outcome_unknown => blocked: {
                self.health = .outcome_unknown;
                break :blocked .not_saved_recovery_required;
            },
        };
    }
};

pub const FreshLocatorGenerator = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    fill_fn: *const fn (?*anyopaque, *[16]u8) bool = unavailableFill,

    fn fill(self: FreshLocatorGenerator, bytes: *[16]u8) bool {
        return self.available and self.fill_fn(self.context, bytes);
    }

    fn unavailableFill(_: ?*anyopaque, _: *[16]u8) bool {
        return false;
    }
};

pub const FreshServerIdentityGenerator = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    fill_fn: *const fn (?*anyopaque, *[16]u8) bool = unavailableFill,

    fn fill(self: FreshServerIdentityGenerator, bytes: *[16]u8) bool {
        return self.available and self.fill_fn(self.context, bytes);
    }

    fn unavailableFill(_: ?*anyopaque, _: *[16]u8) bool {
        return false;
    }
};

pub const StaticAuthMode = enum {
    none,
    static,
};

pub const OauthClientPlan = union(enum) {
    pre_registered: struct {
        client_id: []const u8,
        token_endpoint_auth_method: []const u8 = "none",
    },
    dynamic_registration,
};

pub const CreateOauthHttpServerInput = struct {
    proposal_id: ?u64 = null,
    display_name: []const u8,
    negotiation: []const u8 = "automatic",
    timeout_ms: u32 = 30_000,
    url: []const u8,
    sensitive_endpoint: bool = false,
    endpoint_parts: []const EndpointPartInput = &.{},
    client: OauthClientPlan,
};

pub const UpdateOauthHttpConnectionInput = struct {
    server_id: []const u8,
    display_name: []const u8,
    negotiation: []const u8,
    timeout_ms: u32,
    url: []const u8,
    sensitive_endpoint: bool = false,
    endpoint_parts: []const EndpointPartInput = &.{},
    client: OauthClientPlan,
};

/// Host-owned mutable copy of a manually entered client secret, forwarded once
/// by its dedicated Bridge command. Product validates and stores it through the
/// static-credential locator journal, consuming and zeroing `secret` on every path.
pub const CaptureOauthClientSecretInput = struct {
    server_id: []const u8,
    secret: []u8,
};

pub const CaptureOauthResourceInput = struct {
    server_id: []const u8,
    resource: []u8,
};

pub const CaptureOauthResourceResult = struct {
    outcome: ManagementOutcome,
    identity: ?[35]u8 = null,
};

/// Metadata-validated consent facts supplied by the Application OAuth owner.
/// Scopes must already be a strictly sorted set.
pub const OauthConsentInput = struct {
    server_id: []const u8,
    resource: []const u8,
    private_resource_identity: ?[]const u8 = null,
    issuer: []const u8,
    scopes: []const []const u8,
    redirect_uri: []const u8,
};

pub const RequireOauthReauthorizationInput = struct {
    server_id: []const u8,
    consent_epoch: u64,
    token_revision: u64,
};

pub const CompleteDynamicRegistrationInput = struct {
    operation_id: []const u8,
    server_id: []const u8,
    client_id: []const u8,
    token_endpoint_auth_method: []const u8,
    client_secret: ?[]u8 = null,
};

pub const CompleteCodeExchangeInput = struct {
    operation_id: []const u8,
    server_id: []const u8,
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    expires_at_unix_ms: ?u64 = null,
};

pub const BeginDynamicRegistrationInput = struct {
    consent: OauthConsentInput,
};

pub const BeginCodeExchangeInput = struct {
    server_id: []const u8,
};

pub const BeginRefreshInput = struct {
    server_id: []const u8,
    /// Product has proved a disabled row is still the referenced actual source.
    retained_member: bool = false,
};

pub const CompleteRefreshInput = struct {
    operation_id: []const u8,
    server_id: []const u8,
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    expires_at_unix_ms: ?u64 = null,
};

pub const PreparedOperationState = struct {
    plan: OperationStatePlan,

    pub fn target(self: *const PreparedOperationState) RegistryWire {
        return self.plan.targetRegistry() catch unreachable;
    }

    pub fn deinit(self: *PreparedOperationState) void {
        self.plan.deinit();
        self.* = undefined;
    }
};

pub const OperationStatePreparation = union(enum) {
    rejected,
    prepared: PreparedOperationState,
};

const SecretCandidateSource = struct {
    locator: []const u8,
    secret: []const u8,
};

pub const CreateStdioServerInput = struct {
    proposal_id: ?u64 = null,
    display_name: []const u8,
    negotiation: []const u8 = "automatic",
    timeout_ms: u32 = 30_000,
    command: []const u8,
    arguments: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    auth_mode: StaticAuthMode = .none,
    environment_names: []const []const u8 = &.{},
};

pub const CreateHttpServerInput = struct {
    proposal_id: ?u64 = null,
    display_name: []const u8,
    negotiation: []const u8 = "automatic",
    timeout_ms: u32 = 30_000,
    url: []const u8,
    sensitive_endpoint: bool = false,
    endpoint_parts: []const EndpointPartInput = &.{},
    auth_mode: StaticAuthMode = .none,
    header_names: []const []const u8 = &.{},
};

pub const UpdateStdioConnectionInput = struct {
    server_id: []const u8,
    display_name: []const u8,
    negotiation: []const u8,
    timeout_ms: u32,
    command: []const u8,
    arguments: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    auth_mode: StaticAuthMode,
    environment_names: []const []const u8 = &.{},
};

pub const UpdateHttpConnectionInput = struct {
    server_id: []const u8,
    display_name: []const u8,
    negotiation: []const u8,
    timeout_ms: u32,
    url: []const u8,
    sensitive_endpoint: bool = false,
    endpoint_parts: []const EndpointPartInput = &.{},
    auth_mode: StaticAuthMode,
    header_names: []const []const u8 = &.{},
};

/// Host-owned mutable copy of a manually entered static secret, forwarded once
/// by its dedicated Bridge command. Product validates and stores it through the
/// credential transaction, consuming and zeroing `secret` on every path.
pub const CaptureStaticSecretInput = struct {
    server_id: []const u8,
    slot_name: []const u8,
    secret: []u8,
};

pub const RenameServerInput = struct {
    server_id: []const u8,
    display_name: []const u8,
};

pub const ApproveConnectionInput = struct {
    server_id: []const u8,
};

pub const SetServerEnabledInput = struct {
    server_id: []const u8,
    enabled: bool,
};

pub const SetAllowedToolsInput = struct {
    server_id: []const u8,
    tools: []const []const u8,
};

pub const ManagementConfiguration = struct {
    persistence: MutationPersistence,
    credentials: CredentialEffects,
    locator_generator: FreshLocatorGenerator = .{},
    identity_generator: FreshServerIdentityGenerator = .{},
    limits: Limits,
    initial_health: StoreHealth = .ready,
    /// Candidate ownership is transferred only after Agent Runtime creation
    /// has succeeded. A null manifest means Runtime alignment is unknowable.
    runtime_manifest: ?*RuntimeManifest = null,
};

pub const RuntimeAlignment = enum {
    current,
    restart_required,
    unknown,
};

pub const ManagementInspection = struct {
    health: StoreHealth,
    desired_generation: ?u64,
    runtime_alignment: RuntimeAlignment,
    server_count: usize,
    authorization_recovery_pending: bool = false,
};

/// The attempted target is independent of the global Desired generation.
/// IDs and fingerprints contain no credential material.
pub const RuntimeApplyTarget = struct {
    id_storage: [128]u8 = undefined,
    id_len: usize,
    fingerprint: [32]u8,
    kind: enum { add, replace, remove },
    oauth: bool = false,

    pub fn init(id_value: []const u8, server: ?ServerWire, kind: @FieldType(RuntimeApplyTarget, "kind")) RuntimeApplyTarget {
        std.debug.assert(id_value.len <= 128);
        var value: RuntimeApplyTarget = .{ .id_len = id_value.len, .fingerprint = @splat(0), .kind = kind };
        @memcpy(value.id_storage[0..id_value.len], id_value);
        if (server) |target| {
            value.oauth = std.mem.eql(u8, target.auth.kind, "oauth");
            var hash = Sha256.init(.{});
            hashField(&hash, "metawork.mcp.apply-target/v1");
            hashField(&hash, &runtimeDescriptorFingerprint(target));
            hashField(&hash, &authenticationFingerprint(target));
            hashField(&hash, if (target.enabled) "enabled" else "disabled");
            if (target.connection_approval) |approval| hashField(&hash, approval.fingerprint);
            hash.final(&value.fingerprint);
        }
        return value;
    }

    pub fn id(self: *const RuntimeApplyTarget) []const u8 {
        return self.id_storage[0..self.id_len];
    }
};

pub const RuntimeApplyFailure = enum { preparation, rejected, unknown };

pub const RuntimeApplyIntent = union(enum) { automatic, retry_all, retry_server: []const u8 };

/// Product's attempt ledger. Membership growth never invalidates failures;
/// removal/replacement can reopen ordinary failures after the current round.
/// OAuth failures stay bound until explicit retry or that target changes.
pub const RuntimeConvergence = struct {
    pub const Outcome = enum { pending, waiting_auth, rejected, failed, capacity };
    const Result = struct { target: RuntimeApplyTarget, epoch: u64, round: u64, outcome: Outcome, http_auth_rejected: bool = false };
    results: std.ArrayList(Result) = .empty,
    epoch: u64 = 0,
    round: u64 = 1,

    pub fn deinit(self: *RuntimeConvergence, allocator: std.mem.Allocator) void {
        self.results.deinit(allocator);
        self.* = undefined;
    }

    pub fn handled(self: *const RuntimeConvergence, target: RuntimeApplyTarget) bool {
        return self.handledInRound(target, false);
    }

    /// Failed current credentials must not become an automatic refresh loop.
    /// Membership epochs do not erase the evidence of that connection attempt.
    pub fn failedTarget(self: *const RuntimeConvergence, target: RuntimeApplyTarget) bool {
        for (self.results.items) |result|
            if (std.mem.eql(u8, result.target.id(), target.id()) and std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint))
                return result.outcome == .rejected or result.outcome == .failed;
        return false;
    }

    pub fn httpAuthRejected(self: *const RuntimeConvergence, target: RuntimeApplyTarget) bool {
        for (self.results.items) |result|
            if (std.mem.eql(u8, result.target.id(), target.id()) and std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint))
                return result.http_auth_rejected;
        return false;
    }

    pub fn discardObsolete(self: *RuntimeConvergence, manifest: *const RuntimeManifest, desired: ?RegistryWire, limits: Limits) void {
        var index: usize = 0;
        while (index < self.results.items.len) {
            const result = self.results.items[index];
            const current = manifest.targetFor(result.target.id(), desired, limits);
            if (current == null or current.?.kind != result.target.kind or
                !std.mem.eql(u8, &current.?.fingerprint, &result.target.fingerprint))
            {
                _ = self.results.swapRemove(index);
            } else index += 1;
        }
    }

    pub fn recordHttpAuthRejection(self: *RuntimeConvergence, allocator: std.mem.Allocator, target: RuntimeApplyTarget) std.mem.Allocator.Error!void {
        for (self.results.items) |*result| if (std.mem.eql(u8, result.target.id(), target.id()) and std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint)) {
            result.http_auth_rejected = true;
            return;
        };
        try self.prepare(allocator, target);
        self.reject(target, .failed);
        for (self.results.items) |*result| if (std.mem.eql(u8, result.target.id(), target.id())) {
            result.http_auth_rejected = true;
            return;
        };
        unreachable;
    }

    fn handledInRound(self: *const RuntimeConvergence, target: RuntimeApplyTarget, next_round: bool) bool {
        for (self.results.items) |result| {
            if (!std.mem.eql(u8, result.target.id(), target.id()) or
                !std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint)) continue;
            if (holdsBinding(result)) return true;
            return result.outcome != .pending and (result.epoch == self.epoch or (!next_round and result.round == self.round));
        }
        return false;
    }

    /// Reserve result storage before any external effect.
    pub fn prepare(self: *RuntimeConvergence, allocator: std.mem.Allocator, target: RuntimeApplyTarget) std.mem.Allocator.Error!void {
        for (self.results.items) |*result| {
            if (!std.mem.eql(u8, result.target.id(), target.id())) continue;
            result.* = .{ .target = target, .epoch = self.epoch, .round = self.round, .outcome = .pending };
            return;
        }
        try self.results.append(allocator, .{ .target = target, .epoch = self.epoch, .round = self.round, .outcome = .pending });
    }

    pub fn reject(self: *RuntimeConvergence, target: RuntimeApplyTarget, outcome: Outcome) void {
        std.debug.assert(outcome != .pending);
        for (self.results.items) |*result| {
            if (std.mem.eql(u8, result.target.id(), target.id()) and
                std.mem.eql(u8, &result.target.fingerprint, &target.fingerprint))
            {
                result.outcome = outcome;
                return;
            }
        }
        unreachable;
    }

    pub fn applied(self: *RuntimeConvergence, target: RuntimeApplyTarget) void {
        for (self.results.items, 0..) |result, index| {
            if (std.mem.eql(u8, result.target.id(), target.id())) {
                _ = self.results.swapRemove(index);
                break;
            }
        }
        if (target.kind != .add) self.epoch +|= 1;
    }

    pub fn nextRound(self: *RuntimeConvergence) bool {
        for (self.results.items) |result| {
            if (result.epoch != self.epoch and result.round == self.round and result.outcome != .pending and !holdsBinding(result)) {
                self.round +|= 1;
                return true;
            }
        }
        return false;
    }

    fn holdsBinding(result: Result) bool {
        return result.outcome == .waiting_auth or
            (result.target.oauth and (result.outcome == .rejected or result.outcome == .failed));
    }

    pub fn retry(self: *RuntimeConvergence) void {
        self.results.clearRetainingCapacity();
        self.round +|= 1;
    }

    pub fn retryServer(self: *RuntimeConvergence, server_id: []const u8) void {
        for (self.results.items, 0..) |result, index| {
            if (std.mem.eql(u8, result.target.id(), server_id)) {
                _ = self.results.swapRemove(index);
                break;
            }
        }
    }
};

/// Immutable full Runtime target for one atomic apply. Only candidate_id
/// requires a newly constructed transport; every other member is shared.
pub const RuntimeApplyStep = struct {
    pub const Grant = struct { id: []const u8, tools: []const []const u8 };
    preparation: Preparation,
    member_ids: []const []const u8,
    grants: []const Grant,
    candidate_id: ?[]const u8,
    target: RuntimeApplyTarget,

    pub fn init(allocator: std.mem.Allocator, desired: RegistryWire, servers: []ServerWire, target: RuntimeApplyTarget, limits: Limits) (Error || std.mem.Allocator.Error)!RuntimeApplyStep {
        var registry = try cloneRegistry(allocator, .{ .schema_version = schema_version, .generation = desired.generation, .oauth_operation = null, .servers = servers }, limits);
        errdefer registry.deinit();
        const states = try allocator.alloc(ServerPreparationState, servers.len);
        errdefer allocator.free(states);
        @memset(states, .eligible);
        const ids = try registry.arena.allocator().alloc([]const u8, servers.len);
        const grants = try registry.arena.allocator().alloc(Grant, servers.len);
        var candidate_id: ?[]const u8 = null;
        for (registry.value.servers, ids, grants) |server, *id_value, *grant| {
            id_value.* = server.id;
            if (target.kind != .remove and std.mem.eql(u8, server.id, target.id())) candidate_id = server.id;
            const current = findServer(desired.servers, server.id);
            const tools: []const []const u8 = if (current != null and
                std.mem.eql(u8, &runtimeDescriptorFingerprint(current.?), &runtimeDescriptorFingerprint(server))) admissionTools(desired, current.?) else &.{};
            const copied = try registry.arena.allocator().alloc([]const u8, tools.len);
            for (tools, copied) |tool, *value| value.* = try registry.arena.allocator().dupe(u8, tool);
            grant.* = .{ .id = server.id, .tools = copied };
        }
        return .{ .preparation = .{ .allocator = allocator, .state = .available, .registry = registry, .server_states = states }, .member_ids = ids, .grants = grants, .candidate_id = candidate_id, .target = target };
    }

    pub fn deinit(self: *RuntimeApplyStep) void {
        self.preparation.deinit();
        self.* = undefined;
    }
};

pub const ManagementOutcome = enum {
    unchanged,
    saved,
    saved_recovery_required,
    stale_generation,
    rejected,
    indeterminate,
};

/// An owned create receipt. Identity is copied before preparation is released.
/// Only confirmed canonical saves carry an identity; no allocation follows commit.
pub const created_identity_bytes = 24;
/// Host observations are ephemeral and are never encoded into the registry.
pub const ProcessFact = enum(u8) {
    pending,
    spawned,
    executable_missing,
    access_denied,
    invalid_executable,
    spawn_failed,
    host_resource_unavailable,
    stdio_closed,
};
pub const ProcessObservation = struct {
    server_id: []const u8,
    source: [32]u8,
    attempt: u64,
    fact: ProcessFact,
};
pub const CreateResult = struct {
    outcome: ManagementOutcome,
    server_id: ?[created_identity_bytes]u8 = null,
};

pub const PreparedMutation = struct {
    allocator: std.mem.Allocator,
    plan: MutationPlan,
    candidates: []CandidateCredential = &.{},

    pub fn target(self: *const PreparedMutation) RegistryWire {
        return self.plan.targetRegistry() catch unreachable;
    }

    pub fn deinit(self: *PreparedMutation) void {
        for (self.candidates) |candidate| secureFree(self.allocator, candidate.secret);
        if (self.candidates.len != 0) self.allocator.free(self.candidates);
        self.plan.deinit();
        self.* = undefined;
    }
};

pub const MutationPreparation = union(enum) {
    unchanged,
    rejected,
    prepared: PreparedMutation,
};

/// Workbench-owned desired MCP registry and mutation admission boundary.
/// The startup Runtime preparation is deliberately not retained here: saving
/// desired configuration never changes the effective Runtime or Sessions in
/// the current process.
pub const ManagementPort = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    desired: ?std.json.Parsed(RegistryWire),
    runtime_manifest: ?RuntimeManifest,
    persistence: MutationPersistence,
    credentials: CredentialEffects,
    locator_generator: FreshLocatorGenerator,
    identity_generator: FreshServerIdentityGenerator,
    coordinator: TransactionCoordinator,
    oauth_schedule: OauthRefreshSchedule,
    convergence: RuntimeConvergence = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        startup_registry: ?RegistryWire,
        configuration: ManagementConfiguration,
    ) std.mem.Allocator.Error!ManagementPort {
        var health = configuration.initial_health;
        if (!configuration.persistence.available or !configuration.credentials.available)
            health = .recovery_required;
        var desired: ?std.json.Parsed(RegistryWire) = null;
        if (startup_registry) |registry| {
            desired = cloneRegistry(allocator, registry, configuration.limits) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => failed: {
                    health = .recovery_required;
                    break :failed null;
                },
            };
        }
        errdefer if (desired) |*registry| registry.deinit();
        var oauth_schedule = try OauthRefreshSchedule.init(allocator, configuration.limits);
        oauth_schedule.reconcile(if (desired) |registry| registry.value else null);
        return .{
            .allocator = allocator,
            .limits = configuration.limits,
            .desired = desired,
            .runtime_manifest = if (configuration.runtime_manifest) |manifest|
                manifest.take()
            else
                null,
            .persistence = configuration.persistence,
            .credentials = configuration.credentials,
            .locator_generator = configuration.locator_generator,
            .identity_generator = configuration.identity_generator,
            .coordinator = .{ .health = health },
            .oauth_schedule = oauth_schedule,
        };
    }

    pub fn deinit(self: *ManagementPort) void {
        self.convergence.deinit(self.allocator);
        self.oauth_schedule.deinit();
        if (self.runtime_manifest) |*manifest| manifest.deinit();
        if (self.desired) |*registry| registry.deinit();
        self.* = undefined;
    }

    pub fn inspect(self: *const ManagementPort) ManagementInspection {
        const desired_generation = if (self.desired) |registry|
            registry.value.generation
        else
            null;
        return .{
            .health = self.coordinator.health,
            .desired_generation = desired_generation,
            .runtime_alignment = if (self.runtime_manifest) |*manifest|
                manifest.alignmentWithResults(if (self.desired) |registry| registry.value else null, self.limits, &self.convergence)
            else
                .unknown,
            .server_count = if (self.desired) |registry| registry.value.servers.len else 0,
        };
    }

    pub fn runtimeAlignmentFor(
        self: *const ManagementPort,
        target: RegistryWire,
    ) RuntimeAlignment {
        return if (self.runtime_manifest) |*manifest|
            manifest.alignmentWithResults(target, self.limits, &self.convergence)
        else
            .unknown;
    }

    /// Installs the proof for a Runtime configuration that AgentCore has
    /// already accepted. The caller retains transaction authority and only
    /// invokes this after the apply result is known.
    pub fn installRuntimeManifest(
        self: *ManagementPort,
        replacement: *RuntimeManifest,
    ) void {
        if (self.runtime_manifest) |*manifest| manifest.deinit();
        self.runtime_manifest = replacement.take();
    }

    pub fn desiredRegistry(self: *const ManagementPort) ?RegistryWire {
        return if (self.desired) |registry| registry.value else null;
    }

    /// Safe product-state query. This reveals only whether a referenced
    /// credential slot can currently be resolved, never the credential.
    pub fn credentialPresence(
        self: *const ManagementPort,
        locator: []const u8,
    ) CredentialPresence {
        return self.credentials.probe(locator);
    }

    pub fn prepareCreateHttpServer(
        self: *ManagementPort,
        expected_generation: u64,
        input: CreateHttpServerInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        const headers = try secretSlotsFromNames(
            self.allocator,
            input.header_names,
            &.{},
            .http_header,
        );
        defer self.allocator.free(headers);
        const public_url = if (input.sensitive_endpoint)
            endpointOrigin(input.url, self.limits.max_url_bytes) orelse return .rejected
        else
            input.url;
        var preparation = try self.prepareCreateServer(
            expected_generation,
            input.display_name,
            input.negotiation,
            input.timeout_ms,
            .{
                .kind = "streamable_http",
                .url = public_url,
                .headers = headers,
            },
            input.auth_mode,
        );
        if (!input.sensitive_endpoint) {
            if (input.endpoint_parts.len != 0) {
                switch (preparation) {
                    .prepared => |*value| value.deinit(),
                    else => {},
                }
                return .rejected;
            }
            return preparation;
        }
        return self.secureEndpointPreparation(&preparation, null, input.url, input.endpoint_parts);
    }

    pub fn prepareCreateOauthHttpServer(
        self: *ManagementPort,
        expected_generation: u64,
        input: CreateOauthHttpServerInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        const public_url = if (input.sensitive_endpoint)
            endpointOrigin(input.url, self.limits.max_url_bytes) orelse return .rejected
        else
            input.url;
        var preparation = try self.prepareCreateServerAuth(
            expected_generation,
            input.display_name,
            input.negotiation,
            input.timeout_ms,
            .{ .kind = "streamable_http", .url = public_url },
            oauthAuth(input.client),
        );
        if (!input.sensitive_endpoint) {
            if (input.endpoint_parts.len != 0) {
                switch (preparation) {
                    .prepared => |*value| value.deinit(),
                    else => {},
                }
                return .rejected;
            }
            return preparation;
        }
        return self.secureEndpointPreparation(&preparation, null, input.url, input.endpoint_parts);
    }

    pub fn prepareCreateStdioServer(
        self: *ManagementPort,
        expected_generation: u64,
        input: CreateStdioServerInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        const arguments = try literalArguments(self.allocator, input.arguments);
        defer self.allocator.free(arguments);
        const environment = try secretSlotsFromNames(
            self.allocator,
            input.environment_names,
            &.{},
            .exact,
        );
        defer self.allocator.free(environment);
        return self.prepareCreateServer(
            expected_generation,
            input.display_name,
            input.negotiation,
            input.timeout_ms,
            .{
                .kind = "stdio",
                .command = input.command,
                .arguments = arguments,
                .cwd = input.cwd,
                .environment = environment,
            },
            input.auth_mode,
        );
    }

    fn prepareCreateServer(
        self: *ManagementPort,
        expected_generation: u64,
        display_name: []const u8,
        negotiation: []const u8,
        timeout_ms: u32,
        transport: TransportWire,
        auth_mode: StaticAuthMode,
    ) std.mem.Allocator.Error!MutationPreparation {
        return self.prepareCreateServerAuth(
            expected_generation,
            display_name,
            negotiation,
            timeout_ms,
            transport,
            staticAuth(auth_mode),
        );
    }

    fn prepareCreateServerAuth(
        self: *ManagementPort,
        expected_generation: u64,
        display_name: []const u8,
        negotiation: []const u8,
        timeout_ms: u32,
        transport: TransportWire,
        auth: AuthWire,
    ) std.mem.Allocator.Error!MutationPreparation {
        const base = if (self.desired) |registry| registry.value else null;
        const base_servers = if (base) |registry| registry.servers else &.{};
        if (!self.mutationReady(expected_generation) or
            base_servers.len >= self.limits.max_servers)
            return .rejected;
        var identity_storage: [created_identity_bytes]u8 = undefined;
        var namespace_storage: [24]u8 = undefined;
        const generated = generated: {
            var attempts: usize = 0;
            while (attempts < 8) : (attempts += 1) {
                var entropy: [16]u8 = undefined;
                if (!self.identity_generator.fill(&entropy)) return .rejected;
                const hex = std.fmt.bytesToHex(entropy, .lower);
                const identity = std.fmt.bufPrint(
                    &identity_storage,
                    "mcp-{s}",
                    .{hex[0..20]},
                ) catch unreachable;
                const namespace = std.fmt.bufPrint(
                    &namespace_storage,
                    "mcp_{s}",
                    .{hex[0..20]},
                ) catch unreachable;
                var collision = false;
                for (base_servers) |existing| {
                    if (std.mem.eql(u8, existing.id, identity) or
                        std.mem.eql(u8, existing.namespace, namespace))
                    {
                        collision = true;
                        break;
                    }
                }
                if (!collision) break :generated .{
                    .identity = identity,
                    .namespace = namespace,
                };
            }
            return .rejected;
        };
        var server: ServerWire = .{
            .id = generated.identity,
            .namespace = generated.namespace,
            .display_name = display_name,
            .enabled = false,
            .negotiation = negotiation,
            .timeout_ms = timeout_ms,
            .transport = transport,
            .auth = auth,
            .connection_approval = null,
            .tools = &.{},
        };
        if (serverProblem(server, self.limits) != null) return .rejected;
        const fingerprint = connectionFingerprint(server);
        server.connection_approval = .{ .fingerprint = &fingerprint };
        server.enabled = true;
        if (serverProblem(server, self.limits) != null) return .rejected;
        const servers = try self.allocator.alloc(ServerWire, base_servers.len + 1);
        defer self.allocator.free(servers);
        @memcpy(servers[0..base_servers.len], base_servers);
        servers[base_servers.len] = server;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = if (base) |registry| registry.oauth_operation else null,
            .servers = servers,
        });
    }

    pub fn prepareUpdateHttpConnection(
        self: *ManagementPort,
        expected_generation: u64,
        input: UpdateHttpConnectionInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (!std.mem.eql(u8, base.servers[index].transport.kind, "streamable_http"))
            return .rejected;
        const existing = base.servers[index];
        const public_url = if (input.sensitive_endpoint)
            endpointOrigin(input.url, self.limits.max_url_bytes) orelse return .rejected
        else
            input.url;
        const preserve_credentials =
            staticCredentialDestinationEqual(existing, .{
                .kind = "streamable_http",
                .url = public_url,
            }, input.auth_mode);
        const headers = try secretSlotsFromNames(
            self.allocator,
            input.header_names,
            if (preserve_credentials) existing.transport.headers else &.{},
            .http_header,
        );
        defer self.allocator.free(headers);
        var replacement = existing;
        replacement.display_name = input.display_name;
        replacement.negotiation = input.negotiation;
        replacement.timeout_ms = input.timeout_ms;
        replacement.transport = .{
            .kind = "streamable_http",
            .url = public_url,
            .headers = headers,
        };
        replacement.auth = staticAuth(input.auth_mode);
        var preparation = try self.prepareConnectionReplacement(
            expected_generation,
            base,
            index,
            replacement,
        );
        if (!input.sensitive_endpoint) {
            if (input.endpoint_parts.len != 0) {
                switch (preparation) {
                    .prepared => |*value| value.deinit(),
                    else => {},
                }
                return .rejected;
            }
            return preparation;
        }
        return self.secureEndpointPreparation(&preparation, input.server_id, input.url, input.endpoint_parts);
    }

    pub fn prepareUpdateOauthHttpConnection(
        self: *ManagementPort,
        expected_generation: u64,
        input: UpdateOauthHttpConnectionInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (!std.mem.eql(u8, base.servers[index].transport.kind, "streamable_http"))
            return .rejected;
        const public_url = if (input.sensitive_endpoint)
            endpointOrigin(input.url, self.limits.max_url_bytes) orelse return .rejected
        else
            input.url;
        var replacement = base.servers[index];
        replacement.display_name = input.display_name;
        replacement.negotiation = input.negotiation;
        replacement.timeout_ms = input.timeout_ms;
        replacement.transport = .{
            .kind = "streamable_http",
            .url = public_url,
        };
        // Editing presentation or transport policy does not revoke an unchanged
        // OAuth destination/registration plan (including an issued DCR client).
        const existing = base.servers[index];
        const preserve_authorization = optionalTextEqual(existing.transport.url, input.url) and
            oauthClientPlanMatches(existing.auth, input.client);
        replacement.auth = if (preserve_authorization) existing.auth else oauthAuth(input.client);
        var consent_fingerprint: [64]u8 = undefined;
        if (preserve_authorization) {
            if (replacement.auth.oauth.?.consent) |consent| {
                consent_fingerprint = oauthConsentFingerprint(replacement, consent).?;
                replacement.auth.oauth.?.consent.?.fingerprint = &consent_fingerprint;
            }
        }
        var preparation = try self.prepareConnectionReplacement(
            expected_generation,
            base,
            index,
            replacement,
        );
        if (!input.sensitive_endpoint) {
            if (input.endpoint_parts.len != 0) {
                switch (preparation) {
                    .prepared => |*value| value.deinit(),
                    else => {},
                }
                return .rejected;
            }
            return preparation;
        }
        return self.secureEndpointPreparation(&preparation, input.server_id, input.url, input.endpoint_parts);
    }

    pub fn prepareUpdateStdioConnection(
        self: *ManagementPort,
        expected_generation: u64,
        input: UpdateStdioConnectionInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (!std.mem.eql(u8, base.servers[index].transport.kind, "stdio"))
            return .rejected;
        const arguments = try literalArguments(self.allocator, input.arguments);
        defer self.allocator.free(arguments);
        const existing = base.servers[index];
        const replacement_destination: TransportWire = .{
            .kind = "stdio",
            .command = input.command,
            .arguments = arguments,
            .cwd = input.cwd,
        };
        const preserve_credentials = staticCredentialDestinationEqual(
            existing,
            replacement_destination,
            input.auth_mode,
        );
        const environment = try secretSlotsFromNames(
            self.allocator,
            input.environment_names,
            if (preserve_credentials) existing.transport.environment else &.{},
            .exact,
        );
        defer self.allocator.free(environment);
        var replacement = existing;
        replacement.display_name = input.display_name;
        replacement.negotiation = input.negotiation;
        replacement.timeout_ms = input.timeout_ms;
        replacement.transport = .{
            .kind = "stdio",
            .command = input.command,
            .arguments = arguments,
            .cwd = input.cwd,
            .environment = environment,
        };
        replacement.auth = staticAuth(input.auth_mode);
        return self.prepareConnectionReplacement(
            expected_generation,
            base,
            index,
            replacement,
        );
    }

    fn prepareConnectionReplacement(
        self: *ManagementPort,
        expected_generation: u64,
        base: RegistryWire,
        index: usize,
        replacement_input: ServerWire,
    ) std.mem.Allocator.Error!MutationPreparation {
        var replacement = replacement_input;
        const existing_connection = connectionFingerprint(base.servers[index]);
        const replacement_connection = connectionFingerprint(replacement);
        if (!std.mem.eql(u8, &existing_connection, &replacement_connection))
            replacement.connection_approval = .{ .fingerprint = &replacement_connection };
        if (serverWireEqual(base.servers[index], replacement)) return .unchanged;
        if (serverProblem(replacement, self.limits) != null) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index] = replacement;
        return self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    pub fn prepareRenameServer(
        self: *ManagementPort,
        expected_generation: u64,
        input: RenameServerInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (std.mem.eql(u8, base.servers[index].display_name, input.display_name))
            return .unchanged;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index].display_name = input.display_name;
        if (serverProblem(servers[index], self.limits) != null) return .rejected;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    /// Prepare one disabled durable target before any credential fetch or spawn.
    /// Request bytes are encrypted in bounded system-store chunks, never metadata.
    pub fn prepareInstallationStart(self: *ManagementPort, expected_generation: u64, connection: InstallationConnection, input: InstallationStart) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation) or input.request.len == 0 or input.request.len > 32 * 1024 or
            input.task_id == 0 or input.run_id == 0 or input.source_message_id == 0 or !input.phase.active()) return .rejected;
        var preparation = switch (connection) {
            .http => |value| if (input.existing_server_id) |id| try self.prepareUpdateHttpConnection(expected_generation, .{
                .server_id = id,
                .display_name = value.display_name,
                .negotiation = value.negotiation,
                .timeout_ms = value.timeout_ms,
                .url = value.url,
                .sensitive_endpoint = true,
                .endpoint_parts = value.endpoint_parts,
                .auth_mode = value.auth_mode,
                .header_names = value.header_names,
            }) else try self.prepareCreateHttpServer(expected_generation, .{
                .display_name = value.display_name,
                .negotiation = value.negotiation,
                .timeout_ms = value.timeout_ms,
                .url = value.url,
                .sensitive_endpoint = true,
                .endpoint_parts = value.endpoint_parts,
                .auth_mode = value.auth_mode,
                .header_names = value.header_names,
            }),
            .oauth => |value| if (input.existing_server_id) |id| try self.prepareUpdateOauthHttpConnection(expected_generation, .{
                .server_id = id,
                .display_name = value.display_name,
                .negotiation = value.negotiation,
                .timeout_ms = value.timeout_ms,
                .url = value.url,
                .sensitive_endpoint = true,
                .endpoint_parts = value.endpoint_parts,
                .client = value.client,
            }) else try self.prepareCreateOauthHttpServer(expected_generation, .{
                .display_name = value.display_name,
                .negotiation = value.negotiation,
                .timeout_ms = value.timeout_ms,
                .url = value.url,
                .sensitive_endpoint = true,
                .endpoint_parts = value.endpoint_parts,
                .client = value.client,
            }),
            .stdio => |value| if (input.existing_server_id) |id| try self.prepareUpdateStdioConnection(expected_generation, .{
                .server_id = id,
                .display_name = value.display_name,
                .negotiation = value.negotiation,
                .timeout_ms = value.timeout_ms,
                .command = value.command,
                .arguments = value.arguments,
                .cwd = value.cwd,
                .auth_mode = value.auth_mode,
                .environment_names = value.environment_names,
            }) else try self.prepareCreateStdioServer(expected_generation, value),
        };
        defer switch (preparation) {
            .prepared => |*value| value.deinit(),
            else => {},
        };
        var target = switch (preparation) {
            .prepared => |*value| value.target(),
            .unchanged => if (self.desired) |value| blk: {
                var next = value.value;
                next.generation += 1;
                break :blk next;
            } else return .rejected,
            .rejected => return .rejected,
        };
        target.servers = try self.allocator.dupe(ServerWire, target.servers);
        defer self.allocator.free(target.servers);
        const index = if (input.existing_server_id) |id| findServerIndex(target.servers, id) orelse return .rejected else target.servers.len - 1;
        const server = &target.servers[index];
        if (server.installation) |old| {
            if (old.task_id != input.task_id or old.phase.active()) return .rejected;
        } else if (input.existing_server_id != null) return .rejected;
        const old = server.installation;
        const completed = if (old) |value| value.initial_grant_completed else false;
        const chunk_bytes = self.limits.max_credential_secret_bytes;
        if (chunk_bytes == 0) return .rejected;
        const chunk_count = std.math.divCeil(usize, input.request.len, chunk_bytes) catch return .rejected;
        if (chunk_count > self.limits.max_credential_locators) return .rejected;
        const storage = try self.allocator.alloc([35]u8, chunk_count);
        defer self.allocator.free(storage);
        const refs = try self.allocator.alloc([]const u8, chunk_count);
        defer self.allocator.free(refs);
        server.enabled = false;
        server.installation = .{
            .task_id = input.task_id,
            .run_id = input.run_id,
            .source_message_id = input.source_message_id,
            .revision = if (old) |value| value.revision + 1 else 1,
            .source_origin = input.source_origin,
            .request_refs = &.{},
            .phase = input.phase,
            .initial_grant_pending = !completed,
            .initial_grant_completed = completed,
        };
        for (refs, 0..) |*reference, i| {
            server.installation.?.request_refs = refs[0..i];
            reference.* = self.freshCredentialLocator(target, &storage[i]) orelse return .rejected;
        }
        server.installation.?.request_refs = refs;
        var sources: std.array_list.Managed(SecretCandidateSource) = .init(self.allocator);
        defer sources.deinit();
        if (preparation == .prepared) for (preparation.prepared.candidates) |candidate| {
            try sources.append(.{ .locator = candidate.locator, .secret = candidate.secret });
        };
        for (refs, 0..) |locator, i| {
            const start = i * chunk_bytes;
            try sources.append(.{ .locator = locator, .secret = input.request[start..@min(input.request.len, start + chunk_bytes)] });
        }
        return self.prepareInstallationTarget(target, sources.items);
    }

    fn prepareInstallationTarget(self: *ManagementPort, target: RegistryWire, sources: []const SecretCandidateSource) std.mem.Allocator.Error!MutationPreparation {
        const locators = try self.allocator.alloc([]const u8, sources.len);
        defer self.allocator.free(locators);
        for (sources, locators) |source, *locator| locator.* = source.locator;
        var plan = (planMutation(self.allocator, if (self.desired) |value| value.value else null, target, if (self.desired) |value| value.value.generation else 0, locators, self.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        }) orelse return .unchanged;
        errdefer plan.deinit();
        const candidates = try self.allocator.alloc(CandidateCredential, sources.len);
        var initialized: usize = 0;
        errdefer {
            for (candidates[0..initialized]) |candidate| secureFree(self.allocator, candidate.secret);
            self.allocator.free(candidates);
        }
        for (sources, candidates) |source, *candidate| {
            candidate.* = .{ .locator = findText(plan.transaction.candidate_locators, source.locator) orelse unreachable, .secret = try self.allocator.dupe(u8, source.secret) };
            initialized += 1;
        }
        return .{ .prepared = .{ .allocator = self.allocator, .plan = plan, .candidates = candidates } };
    }

    pub fn prepareInstallationUpdate(self: *ManagementPort, expected_generation: u64, input: InstallationUpdate) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |value| value.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        const old = base.servers[index].installation orelse return .rejected;
        if (old.revision != input.expected_revision or !old.phase.allows(input.phase) or input.active_elapsed_ms < old.active_elapsed_ms or input.active_elapsed_ms > installation_active_budget_ms) return .rejected;
        if (input.cross_origin_authorized and (old.phase != .needs_authorization or input.phase != .preparing)) return .rejected;
        if (input.phase == .ready and input.initial_tools == null and (!old.initial_grant_completed or base.servers[index].tools.len == 0)) return .rejected;
        if (input.phase == .no_tools and old.initial_grant_pending and input.initial_tools == null) return .rejected;
        if (input.initial_tools != null and input.phase != .connecting and input.phase != .no_tools) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        const server = &servers[index];
        const operation = &server.installation.?;
        operation.phase = input.phase;
        operation.revision += 1;
        operation.active_elapsed_ms = input.active_elapsed_ms;
        operation.cross_origin_authorized = old.cross_origin_authorized or input.cross_origin_authorized;
        if (!input.phase.active()) operation.initial_grant_pending = false;
        if (input.initial_tools) |tools| {
            if (!old.initial_grant_pending or old.initial_grant_completed or (input.phase == .ready and tools.len == 0) or (input.phase == .no_tools and tools.len != 0)) return .rejected;
            server.tools = tools;
            operation.initial_grant_completed = true;
            operation.initial_grant_pending = false;
        }
        if (input.phase == .cancelled or input.phase == .failed) server.enabled = false else if (input.phase == .connecting or input.phase == .needs_oauth) server.enabled = true;
        return self.prepareTarget(expected_generation, .{ .schema_version = schema_version, .generation = expected_generation + 1, .oauth_operation = base.oauth_operation, .servers = servers });
    }

    /// Persist Stop even while an uninterruptible Core apply is in flight.
    /// The marker vetoes loading/admission immediately; a later normal mutation
    /// reconciles enabled=false. No descriptor or credential reference is changed.
    pub fn prepareInstallationCancellation(self: *ManagementPort, server_id: []const u8, expected_revision: u64) std.mem.Allocator.Error!OperationStatePreparation {
        if (self.coordinator.health != .ready) return .rejected;
        const base = if (self.desired) |value| value.value else return .rejected;
        const index = findServerIndex(base.servers, server_id) orelse return .rejected;
        const old = base.servers[index].installation orelse return .rejected;
        if (old.phase == .cancelled) return .rejected;
        if (old.revision != expected_revision or !old.phase.active()) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        const operation = &servers[index].installation.?;
        operation.phase = .cancelled;
        operation.stop_pending = true;
        operation.revision += 1;
        operation.initial_grant_pending = false;
        var target = base;
        target.servers = servers;
        var owned_base = cloneRegistry(self.allocator, base, self.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        errdefer owned_base.deinit();
        return .{ .prepared = .{ .plan = .{ .base = owned_base, .target = cloneRegistry(self.allocator, target, self.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        } } } };
    }

    /// Replaces an effect-free public draft with one credential-journal target.
    /// No public-origin intermediate configuration is ever committed or connected.
    fn secureEndpointPreparation(self: *ManagementPort, preparation: *MutationPreparation, server_id: ?[]const u8, endpoint: []const u8, supplied_parts: []const EndpointPartInput) std.mem.Allocator.Error!MutationPreparation {
        defer switch (preparation.*) {
            .prepared => |*value| value.deinit(),
            else => {},
        };
        const origin = endpointOrigin(endpoint, self.limits.max_url_bytes) orelse return .rejected;
        var target = switch (preparation.*) {
            .prepared => |*value| value.target(),
            .unchanged => if (self.desired) |value| blk: {
                var next = value.value;
                next.generation += 1;
                break :blk next;
            } else return .rejected,
            .rejected => return .rejected,
        };
        target.servers = try self.allocator.dupe(ServerWire, target.servers);
        defer self.allocator.free(target.servers);
        const index = if (server_id) |id| findServerIndex(target.servers, id) orelse return .rejected else target.servers.len - 1;
        const default_parts = [_]EndpointPartInput{.{ .value = endpoint, .is_credential = true }};
        const parts = if (supplied_parts.len == 0) &default_parts else supplied_parts;
        if (parts.len > self.limits.max_credential_locators) return .rejected;
        var offset: usize = 0;
        for (parts) |part| {
            if (part.value.len == 0 or part.value.len > endpoint.len - offset or
                !std.mem.eql(u8, endpoint[offset..][0..part.value.len], part.value)) return .rejected;
            offset += part.value.len;
        }
        if (offset != endpoint.len) return .rejected;
        const storage = try self.allocator.alloc([35]u8, parts.len);
        defer self.allocator.free(storage);
        const refs = try self.allocator.alloc([]const u8, parts.len);
        defer self.allocator.free(refs);
        var secret_parts: std.array_list.Managed(u32) = .init(self.allocator);
        defer secret_parts.deinit();
        var server = &target.servers[index];
        server.transport.url = null;
        for (parts, 0..) |part, i| {
            // Include the already generated locators in collision detection.
            server.transport.sensitive_endpoint = .{ .origin = origin, .identity = "pending", .credential_refs = refs[0..i] };
            refs[i] = self.freshCredentialLocator(target, &storage[i]) orelse return .rejected;
            if (part.is_credential) try secret_parts.append(@intCast(i));
        }
        server.transport.sensitive_endpoint = .{ .origin = origin, .identity = refs[0], .credential_refs = refs, .secret_parts = secret_parts.items };
        const fingerprint = connectionFingerprint(server.*);
        server.connection_approval = .{ .fingerprint = &fingerprint };
        var plan = (planMutation(self.allocator, if (self.desired) |value| value.value else null, target, if (self.desired) |value| value.value.generation else 0, refs, self.limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        }) orelse return .unchanged;
        errdefer plan.deinit();
        const candidates = try self.allocator.alloc(CandidateCredential, parts.len);
        var initialized: usize = 0;
        errdefer {
            for (candidates[0..initialized]) |candidate| {
                std.crypto.secureZero(u8, candidate.secret);
                self.allocator.free(candidate.secret);
            }
            self.allocator.free(candidates);
        }
        for (parts, refs, candidates) |part, locator, *candidate| {
            const owned_locator = findText(plan.transaction.candidate_locators, locator) orelse unreachable;
            candidate.* = .{ .locator = owned_locator, .secret = try self.allocator.dupe(u8, part.value) };
            initialized += 1;
        }
        return .{ .prepared = .{ .allocator = self.allocator, .plan = plan, .candidates = candidates } };
    }

    pub fn prepareApproveConnection(
        self: *ManagementPort,
        expected_generation: u64,
        input: ApproveConnectionInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (serverProblem(base.servers[index], self.limits)) |problem|
            if (problem != .invalid_connection_approval) return .rejected;
        const fingerprint = connectionFingerprint(base.servers[index]);
        if (base.servers[index].connection_approval) |approval|
            if (std.mem.eql(u8, approval.fingerprint, &fingerprint)) return .unchanged;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index].connection_approval = .{ .fingerprint = &fingerprint };
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    pub fn prepareCaptureStaticSecret(
        self: *ManagementPort,
        expected_generation: u64,
        input: CaptureStaticSecretInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        defer std.crypto.secureZero(u8, input.secret);
        if (!self.mutationReady(expected_generation) or input.secret.len == 0 or
            input.secret.len > self.limits.max_credential_secret_bytes)
            return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        const existing = base.servers[index];
        if (!std.mem.eql(u8, existing.auth.kind, "static") or
            existing.connection_approval == null or
            serverProblem(existing, self.limits) != null)
            return .rejected;

        var locator_storage: [35]u8 = undefined;
        const locator = self.freshCredentialLocator(base, &locator_storage) orelse
            return .rejected;
        var replacement = existing;
        if (std.mem.eql(u8, existing.transport.kind, "stdio")) {
            const slots = try self.allocator.dupe(
                SecretSlotWire,
                existing.transport.environment,
            );
            defer self.allocator.free(slots);
            const slot_index = findSecretSlot(slots, input.slot_name) orelse return .rejected;
            slots[slot_index].credential_ref = locator;
            replacement.transport.environment = slots;
            return self.prepareSecretTarget(
                base,
                index,
                replacement,
                locator,
                input.secret,
            );
        }
        if (!std.mem.eql(u8, existing.transport.kind, "streamable_http"))
            return .rejected;
        const slots = try self.allocator.dupe(
            SecretSlotWire,
            existing.transport.headers,
        );
        defer self.allocator.free(slots);
        const slot_index = findSecretSlot(slots, input.slot_name) orelse return .rejected;
        slots[slot_index].credential_ref = locator;
        replacement.transport.headers = slots;
        return self.prepareSecretTarget(
            base,
            index,
            replacement,
            locator,
            input.secret,
        );
    }

    pub fn prepareCaptureOauthClientSecret(
        self: *ManagementPort,
        expected_generation: u64,
        input: CaptureOauthClientSecretInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        defer std.crypto.secureZero(u8, input.secret);
        if (!self.mutationReady(expected_generation) or input.secret.len == 0 or
            input.secret.len > self.limits.max_credential_secret_bytes)
            return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        const existing = base.servers[index];
        const oauth = existing.auth.oauth orelse return .rejected;
        const method = oauth.registration.token_endpoint_auth_method orelse
            return .rejected;
        if (existing.connection_approval == null or
            !std.mem.eql(u8, oauth.registration.kind, "pre_registered") or
            std.mem.eql(u8, method, "none") or
            base.oauth_operation != null)
            return .rejected;
        var locator_storage: [35]u8 = undefined;
        const locator = self.freshCredentialLocator(base, &locator_storage) orelse
            return .rejected;
        if (oauth.registration.client_credential_revision == std.math.maxInt(u64))
            return .rejected;
        var replacement = existing;
        var replacement_auth = existing.auth;
        var replacement_oauth = oauth;
        replacement_oauth.status = "consent_required";
        replacement_oauth.registration.client_secret_ref = locator;
        replacement_oauth.registration.client_credential_revision += 1;
        replacement_oauth.consent = null;
        replacement_oauth.grant = null;
        replacement_auth.oauth = replacement_oauth;
        replacement.auth = replacement_auth;
        return self.prepareSecretTarget(
            base,
            index,
            replacement,
            locator,
            input.secret,
        );
    }

    pub fn prepareCaptureOauthResource(self: *ManagementPort, expected_generation: u64, input: CaptureOauthResourceInput) std.mem.Allocator.Error!MutationPreparation {
        defer std.crypto.secureZero(u8, input.resource);
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |value| value.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        const existing = base.servers[index];
        if (existing.auth.oauth == null or existing.connection_approval == null or serverProblem(existing, self.limits) != null) return .rejected;
        const origin = endpointOrigin(input.resource, self.limits.max_oauth_uri_bytes) orelse return .rejected;
        var storage: [35]u8 = undefined;
        const locator = self.freshCredentialLocator(base, &storage) orelse return .rejected;
        const refs = [_][]const u8{locator};
        var replacement = existing;
        replacement.auth.oauth.?.pending_resource = .{ .origin = origin, .identity = locator, .credential_refs = &refs };
        return self.prepareSecretTarget(base, index, replacement, locator, input.resource);
    }

    pub fn prepareOauthConsent(
        self: *ManagementPort,
        expected_generation: u64,
        input: OauthConsentInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        if (base.oauth_operation != null) return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        const existing = base.servers[index];
        const approval = existing.connection_approval orelse return .rejected;
        if (!std.mem.eql(u8, approval.fingerprint, &connectionFingerprint(existing)))
            return .rejected;
        const oauth = existing.auth.oauth orelse return .rejected;
        if ((!std.mem.eql(u8, oauth.registration.kind, "pre_registered") and
            !std.mem.eql(u8, oauth.registration.kind, "dynamic_registration")) or
            oauth.registration.client_id == null)
            return .rejected;
        if (oauth.registration.issuer) |issuer|
            if (!std.mem.eql(u8, issuer, input.issuer)) return .rejected;
        const method = oauth.registration.token_endpoint_auth_method orelse
            return .rejected;
        if (!std.mem.eql(u8, method, "none") and
            oauth.registration.client_secret_ref == null)
            return .rejected;
        const next_epoch = if (oauth.consent) |consent|
            std.math.add(u64, consent.epoch, 1) catch return .rejected
        else
            1;
        var replacement = existing;
        var replacement_auth = existing.auth;
        var replacement_oauth = oauth;
        replacement_oauth.registration.issuer = input.issuer;
        const resource = consentResourceInput(existing, input) orelse return .rejected;
        var consent: OauthConsentWire = .{
            .epoch = next_epoch,
            .fingerprint = "0000000000000000000000000000000000000000000000000000000000000000",
            .resource = resource.value,
            .private_resource = resource.private,
            .issuer = input.issuer,
            .scopes = input.scopes,
            .redirect_uri = input.redirect_uri,
            .client_credential_revision = oauth.registration.client_credential_revision,
        };
        replacement_oauth.status = "awaiting_tokens";
        replacement_oauth.pending_resource = null;
        replacement_oauth.consent = consent;
        replacement_oauth.grant = null;
        replacement_auth.oauth = replacement_oauth;
        replacement.auth = replacement_auth;
        const fingerprint = oauthConsentFingerprint(replacement, consent) orelse
            return .rejected;
        consent.fingerprint = &fingerprint;
        replacement_oauth.consent = consent;
        replacement_auth.oauth = replacement_oauth;
        replacement.auth = replacement_auth;
        if (serverProblem(replacement, self.limits) != null) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index] = replacement;
        return self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = null,
            .servers = servers,
        });
    }

    pub fn prepareRequireOauthReauthorization(
        self: *ManagementPort,
        expected_generation: u64,
        input: RequireOauthReauthorizationInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        if (base.oauth_operation) |operation|
            if (std.mem.eql(u8, operation.server_id, input.server_id))
                return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse
            return .rejected;
        const existing = base.servers[index];
        const oauth = existing.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        const grant = oauth.grant orelse return .rejected;
        if (!existing.enabled or
            !std.mem.eql(u8, existing.transport.kind, "streamable_http") or
            !std.mem.eql(u8, existing.auth.kind, "oauth") or
            !std.mem.eql(u8, oauth.status, "ready") or
            consent.epoch != input.consent_epoch or
            grant.consent_epoch != input.consent_epoch or
            grant.token_revision != input.token_revision)
            return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        var replacement = existing;
        var replacement_auth = existing.auth;
        var replacement_oauth = oauth;
        replacement_oauth.status = "reauth_required";
        replacement_oauth.grant = null;
        replacement_auth.oauth = replacement_oauth;
        replacement.auth = replacement_auth;
        servers[index] = replacement;
        return self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    pub fn prepareBeginDynamicRegistration(
        self: *ManagementPort,
        expected_generation: u64,
        input: BeginDynamicRegistrationInput,
    ) std.mem.Allocator.Error!OperationStatePreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.consent.server_id) orelse return .rejected;
        const server = base.servers[index];
        const oauth = server.auth.oauth orelse return .rejected;
        const registration_needed = std.mem.eql(
            u8,
            oauth.status,
            "client_registration_required",
        ) or std.mem.eql(u8, oauth.status, "reauth_required");
        if (server.connection_approval == null or
            !registration_needed or
            !std.mem.eql(u8, oauth.registration.kind, "dynamic_registration") or
            oauth.registration.client_id != null or
            serverProblem(server, self.limits) != null)
            return .rejected;
        const resource = consentResourceInput(server, input.consent) orelse return .rejected;
        const draft: OauthConsentDraftWire = .{
            .resource = resource.value,
            .private_resource = resource.private,
            .issuer = input.consent.issuer,
            .scopes = input.consent.scopes,
            .redirect_uri = input.consent.redirect_uri,
        };
        if (!validateOauthConsentDraft(draft, self.limits)) return .rejected;
        const epoch: u64 = 1;
        const fingerprint = oauthConsentDraftFingerprint(server, epoch, draft) orelse
            return .rejected;
        var id_storage: [26]u8 = undefined;
        const operation_id = self.freshOauthOperationId(&id_storage) orelse
            return .rejected;
        var plan = planBeginOauthOperation(
            self.allocator,
            base,
            expected_generation,
            .{
                .id = operation_id,
                .kind = "dynamic_registration",
                .server_id = input.consent.server_id,
                .connection_fingerprint = server.connection_approval.?.fingerprint,
                .consent_fingerprint = &fingerprint,
                .consent_epoch = epoch,
                .token_revision = null,
                .consent_draft = draft,
            },
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        errdefer plan.deinit();
        return .{ .prepared = .{ .plan = plan } };
    }

    pub fn prepareBeginCodeExchange(
        self: *ManagementPort,
        expected_generation: u64,
        input: BeginCodeExchangeInput,
    ) std.mem.Allocator.Error!OperationStatePreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const server = findServer(base.servers, input.server_id) orelse return .rejected;
        const oauth = server.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        if (!std.mem.eql(u8, oauth.status, "awaiting_tokens") or
            server.connection_approval == null)
            return .rejected;
        var id_storage: [26]u8 = undefined;
        const operation_id = self.freshOauthOperationId(&id_storage) orelse
            return .rejected;
        var plan = planBeginOauthOperation(
            self.allocator,
            base,
            expected_generation,
            .{
                .id = operation_id,
                .kind = "code_exchange",
                .server_id = input.server_id,
                .connection_fingerprint = server.connection_approval.?.fingerprint,
                .consent_fingerprint = consent.fingerprint,
                .consent_epoch = consent.epoch,
                .token_revision = null,
                .consent_draft = null,
            },
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        errdefer plan.deinit();
        return .{ .prepared = .{ .plan = plan } };
    }

    pub fn prepareBeginRefresh(
        self: *ManagementPort,
        expected_generation: u64,
        input: BeginRefreshInput,
    ) std.mem.Allocator.Error!OperationStatePreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const server = findServer(base.servers, input.server_id) orelse return .rejected;
        const approval = server.connection_approval orelse return .rejected;
        const oauth = server.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        const grant = oauth.grant orelse return .rejected;
        if ((!server.enabled and !input.retained_member) or !std.mem.eql(u8, oauth.status, "ready") or
            grant.refresh_token_ref == null or
            grant.consent_epoch != consent.epoch or
            grant.token_revision == std.math.maxInt(u64))
            return .rejected;
        var id_storage: [26]u8 = undefined;
        const operation_id = self.freshOauthOperationId(&id_storage) orelse
            return .rejected;
        var plan = planBeginOauthOperation(
            self.allocator,
            base,
            expected_generation,
            .{
                .id = operation_id,
                .kind = "refresh",
                .server_id = input.server_id,
                .connection_fingerprint = approval.fingerprint,
                .consent_fingerprint = consent.fingerprint,
                .consent_epoch = consent.epoch,
                .token_revision = grant.token_revision,
                .consent_draft = null,
            },
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        errdefer plan.deinit();
        return .{ .prepared = .{ .plan = plan } };
    }

    pub fn prepareCompleteDynamicRegistration(
        self: *ManagementPort,
        input: CompleteDynamicRegistrationInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        defer if (input.client_secret) |secret| std.crypto.secureZero(u8, secret);
        if (self.coordinator.health != .ready) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const operation = base.oauth_operation orelse return .rejected;
        if (!std.mem.eql(u8, operation.id, input.operation_id) or
            !std.mem.eql(u8, operation.kind, "dynamic_registration") or
            !std.mem.eql(u8, operation.server_id, input.server_id))
            return .rejected;
        const draft = operation.consent_draft orelse return .rejected;
        if (base.generation == std.math.maxInt(u64)) return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        const existing = base.servers[index];
        const method = input.token_endpoint_auth_method;
        if (!oneOf(method, &.{ "none", "client_secret_basic", "client_secret_post" }) or
            !validText(input.client_id, self.limits.max_oauth_client_id_bytes, false))
            return .rejected;
        const secret_required = !std.mem.eql(u8, method, "none");
        if (secret_required != (input.client_secret != null)) return .rejected;
        if (input.client_secret) |secret|
            if (secret.len > self.limits.max_credential_secret_bytes or
                !validHttpHeaderCredential(secret))
                return .rejected;
        var locator_storage: [35]u8 = undefined;
        const secret_locator = if (input.client_secret != null)
            self.freshCredentialLocator(base, &locator_storage) orelse return .rejected
        else
            null;
        var replacement = existing;
        var replacement_auth = existing.auth;
        var oauth = existing.auth.oauth orelse return .rejected;
        oauth.registration = .{
            .kind = "dynamic_registration",
            .issuer = draft.issuer,
            .client_id = input.client_id,
            .token_endpoint_auth_method = method,
            .client_credential_revision = 1,
            .client_secret_ref = secret_locator,
        };
        var consent: OauthConsentWire = .{
            .epoch = operation.consent_epoch,
            .fingerprint = "0000000000000000000000000000000000000000000000000000000000000000",
            .resource = draft.resource,
            .private_resource = draft.private_resource,
            .issuer = draft.issuer,
            .scopes = draft.scopes,
            .redirect_uri = draft.redirect_uri,
            .client_credential_revision = 1,
        };
        oauth.status = "awaiting_tokens";
        oauth.pending_resource = null;
        oauth.consent = consent;
        oauth.grant = null;
        replacement_auth.oauth = oauth;
        replacement.auth = replacement_auth;
        const fingerprint = oauthConsentFingerprint(replacement, consent) orelse
            return .rejected;
        consent.fingerprint = &fingerprint;
        oauth.consent = consent;
        replacement_auth.oauth = oauth;
        replacement.auth = replacement_auth;
        if (serverProblem(replacement, self.limits) != null) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index] = replacement;
        var sources: [1]SecretCandidateSource = undefined;
        const source_slice = if (input.client_secret) |secret| sources_slice: {
            sources[0] = .{ .locator = secret_locator.?, .secret = secret };
            break :sources_slice sources[0..1];
        } else sources[0..0];
        return self.prepareOauthResultTarget(base, servers, source_slice);
    }

    pub fn prepareCompleteCodeExchange(
        self: *ManagementPort,
        input: CompleteCodeExchangeInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        defer std.crypto.secureZero(u8, input.access_token);
        defer if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
        if (self.coordinator.health != .ready or
            !validHttpHeaderCredential(input.access_token) or
            input.access_token.len > self.limits.max_credential_secret_bytes or
            (input.expires_at_unix_ms != null and input.expires_at_unix_ms.? == 0))
            return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const operation = base.oauth_operation orelse return .rejected;
        if (base.generation == std.math.maxInt(u64)) return .rejected;
        if (!std.mem.eql(u8, operation.id, input.operation_id) or
            !std.mem.eql(u8, operation.kind, "code_exchange") or
            !std.mem.eql(u8, operation.server_id, input.server_id))
            return .rejected;
        if (input.refresh_token) |secret|
            if (secret.len > self.limits.max_credential_secret_bytes or
                !validHttpHeaderCredential(secret))
                return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        var replacement = base.servers[index];
        var replacement_auth = replacement.auth;
        var oauth = replacement.auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        if (!std.mem.eql(u8, oauth.status, "awaiting_tokens") or
            consent.epoch != operation.consent_epoch or
            !std.mem.eql(u8, consent.fingerprint, operation.consent_fingerprint))
            return .rejected;
        var access_storage: [35]u8 = undefined;
        const access_locator = self.freshCredentialLocator(base, &access_storage) orelse
            return .rejected;
        var refresh_storage: [35]u8 = undefined;
        const refresh_locator = if (input.refresh_token != null)
            self.freshCredentialLocatorExcluding(
                base,
                access_locator,
                &refresh_storage,
            ) orelse return .rejected
        else
            null;
        oauth.status = "ready";
        oauth.grant = .{
            .consent_epoch = consent.epoch,
            .token_revision = 1,
            .access_token_ref = access_locator,
            .refresh_token_ref = refresh_locator,
            .expires_at_unix_ms = input.expires_at_unix_ms,
        };
        replacement_auth.oauth = oauth;
        replacement.auth = replacement_auth;
        if (serverProblem(replacement, self.limits) != null) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index] = replacement;
        var sources: [2]SecretCandidateSource = undefined;
        sources[0] = .{ .locator = access_locator, .secret = input.access_token };
        var count: usize = 1;
        if (input.refresh_token) |secret| {
            sources[count] = .{ .locator = refresh_locator.?, .secret = secret };
            count += 1;
        }
        return self.prepareOauthResultTarget(base, servers, sources[0..count]);
    }

    pub fn prepareCompleteRefresh(
        self: *ManagementPort,
        input: CompleteRefreshInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        defer std.crypto.secureZero(u8, input.access_token);
        defer if (input.refresh_token) |secret| std.crypto.secureZero(u8, secret);
        if (self.coordinator.health != .ready or
            !validHttpHeaderCredential(input.access_token) or
            input.access_token.len > self.limits.max_credential_secret_bytes or
            (input.expires_at_unix_ms != null and input.expires_at_unix_ms.? == 0))
            return .rejected;
        if (input.refresh_token) |secret|
            if (secret.len > self.limits.max_credential_secret_bytes or
                !validHttpHeaderCredential(secret))
                return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const operation = base.oauth_operation orelse return .rejected;
        if (base.generation == std.math.maxInt(u64) or
            !std.mem.eql(u8, operation.id, input.operation_id) or
            !std.mem.eql(u8, operation.kind, "refresh") or
            !std.mem.eql(u8, operation.server_id, input.server_id))
            return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        var replacement = base.servers[index];
        const approval = replacement.connection_approval orelse return .rejected;
        var replacement_auth = replacement.auth;
        var oauth = replacement_auth.oauth orelse return .rejected;
        const consent = oauth.consent orelse return .rejected;
        const grant = oauth.grant orelse return .rejected;
        const expected_revision = operation.token_revision orelse return .rejected;
        if (!std.mem.eql(u8, oauth.status, "ready") or
            grant.refresh_token_ref == null or
            grant.consent_epoch != operation.consent_epoch or
            grant.token_revision != expected_revision or
            grant.token_revision == std.math.maxInt(u64) or
            consent.epoch != operation.consent_epoch or
            !std.mem.eql(u8, approval.fingerprint, operation.connection_fingerprint) or
            !std.mem.eql(u8, consent.fingerprint, operation.consent_fingerprint))
            return .rejected;

        var access_storage: [35]u8 = undefined;
        const access_locator = self.freshCredentialLocator(base, &access_storage) orelse
            return .rejected;
        var refresh_storage: [35]u8 = undefined;
        const refresh_locator = if (input.refresh_token != null)
            self.freshCredentialLocatorExcluding(
                base,
                access_locator,
                &refresh_storage,
            ) orelse return .rejected
        else
            grant.refresh_token_ref.?;
        oauth.grant = .{
            .consent_epoch = grant.consent_epoch,
            .token_revision = grant.token_revision + 1,
            .access_token_ref = access_locator,
            .refresh_token_ref = refresh_locator,
            .expires_at_unix_ms = input.expires_at_unix_ms,
        };
        replacement_auth.oauth = oauth;
        replacement.auth = replacement_auth;
        if (serverProblem(replacement, self.limits) != null) return .rejected;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index] = replacement;
        var sources: [2]SecretCandidateSource = undefined;
        sources[0] = .{ .locator = access_locator, .secret = input.access_token };
        var count: usize = 1;
        if (input.refresh_token) |secret| {
            sources[count] = .{ .locator = refresh_locator, .secret = secret };
            count += 1;
        }
        return self.prepareOauthResultTarget(base, servers, sources[0..count]);
    }

    pub fn prepareClearOauthOperation(
        self: *ManagementPort,
        expected_operation_id: []const u8,
    ) std.mem.Allocator.Error!OperationStatePreparation {
        if (self.coordinator.health != .ready) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        var plan = planClearOauthOperation(
            self.allocator,
            base,
            base.generation,
            expected_operation_id,
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        errdefer plan.deinit();
        return .{ .prepared = .{ .plan = plan } };
    }

    pub fn prepareOauthOperationRecovery(
        self: *ManagementPort,
        expected_operation_id: []const u8,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (self.coordinator.health != .ready) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const operation = base.oauth_operation orelse return .rejected;
        if (!std.mem.eql(u8, operation.id, expected_operation_id)) return .rejected;
        var plan = planOauthOperationRecovery(
            self.allocator,
            base,
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        errdefer plan.deinit();
        return .{ .prepared = .{ .allocator = self.allocator, .plan = plan } };
    }

    fn prepareOauthResultTarget(
        self: *ManagementPort,
        base: RegistryWire,
        servers: []ServerWire,
        sources: []const SecretCandidateSource,
    ) std.mem.Allocator.Error!MutationPreparation {
        const locators = try self.allocator.alloc([]const u8, sources.len);
        defer self.allocator.free(locators);
        for (sources, locators) |source, *locator| locator.* = source.locator;
        var plan = (planMutationWithMode(
            self.allocator,
            base,
            .{
                .schema_version = schema_version,
                .generation = base.generation + 1,
                .oauth_operation = null,
                .servers = servers,
            },
            base.generation,
            locators,
            self.limits,
            .oauth_result,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        }) orelse return .unchanged;
        errdefer plan.deinit();
        const candidates = try self.allocator.alloc(CandidateCredential, sources.len);
        var initialized: usize = 0;
        errdefer {
            for (candidates[0..initialized]) |candidate|
                secureFree(self.allocator, candidate.secret);
            self.allocator.free(candidates);
        }
        for (sources, candidates) |source, *candidate| {
            const owned_locator = findText(plan.transaction.candidate_locators, source.locator) orelse
                return .rejected;
            candidate.* = .{
                .locator = owned_locator,
                .secret = try self.allocator.dupe(u8, source.secret),
            };
            initialized += 1;
        }
        return .{ .prepared = .{
            .allocator = self.allocator,
            .plan = plan,
            .candidates = candidates,
        } };
    }

    fn freshOauthOperationId(
        self: *ManagementPort,
        storage: *[26]u8,
    ) ?[]const u8 {
        var random: [16]u8 = undefined;
        if (!self.identity_generator.fill(&random)) return null;
        const hex = std.fmt.bytesToHex(random, .lower);
        return std.fmt.bufPrint(storage, "oauth-{s}", .{hex[0..20]}) catch unreachable;
    }

    pub fn commitPreparedOperationState(
        self: *ManagementPort,
        prepared: *PreparedOperationState,
    ) std.mem.Allocator.Error!ManagementOutcome {
        const target = prepared.plan.targetRegistry() catch return .rejected;
        if (self.coordinator.health != .ready) return .rejected;
        const current = if (self.desired) |registry| registry.value else return .rejected;
        if (current.generation != target.generation or
            !registryContentEqual(current, prepared.plan.base.value))
            return .rejected;
        const buffer = try self.allocator.alloc(u8, max_store_bytes);
        defer self.allocator.free(buffer);
        const bytes = encode(buffer, target, self.limits) catch return .rejected;
        return switch (self.persistence.commitRegistry(bytes)) {
            .committed => saved: {
                self.replaceDesired(prepared.plan.takeTarget());
                break :saved .saved;
            },
            .failed => .rejected,
            .outcome_unknown => unknown: {
                self.coordinator.health = .outcome_unknown;
                break :unknown .indeterminate;
            },
        };
    }

    fn freshCredentialLocator(
        self: *ManagementPort,
        registry: RegistryWire,
        storage: *[35]u8,
    ) ?[]const u8 {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var random: [16]u8 = undefined;
            if (!self.locator_generator.fill(&random)) return null;
            const hex = std.fmt.bytesToHex(random, .lower);
            const candidate = std.fmt.bufPrint(storage, "v1/{s}", .{hex}) catch
                unreachable;
            var referenced = false;
            for (registry.servers) |server| {
                if (!serverReferencesCredential(server, candidate)) continue;
                referenced = true;
                break;
            }
            if (!referenced) return candidate;
        }
        return null;
    }

    fn freshCredentialLocatorExcluding(
        self: *ManagementPort,
        registry: RegistryWire,
        excluded: []const u8,
        storage: *[35]u8,
    ) ?[]const u8 {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const candidate = self.freshCredentialLocator(registry, storage) orelse
                return null;
            if (!std.mem.eql(u8, candidate, excluded)) return candidate;
        }
        return null;
    }

    fn prepareSecretTarget(
        self: *ManagementPort,
        base: RegistryWire,
        index: usize,
        replacement: ServerWire,
        locator: []const u8,
        secret: []const u8,
    ) std.mem.Allocator.Error!MutationPreparation {
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index] = replacement;
        var plan = (planMutation(
            self.allocator,
            base,
            .{
                .schema_version = schema_version,
                .generation = base.generation + 1,
                .oauth_operation = base.oauth_operation,
                .servers = servers,
            },
            base.generation,
            &.{locator},
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        }) orelse return .unchanged;
        errdefer plan.deinit();
        const candidates = try self.allocator.alloc(CandidateCredential, 1);
        errdefer self.allocator.free(candidates);
        const secret_copy = try self.allocator.dupe(u8, secret);
        errdefer secureFree(self.allocator, secret_copy);
        candidates[0] = .{
            .locator = plan.transaction.candidate_locators[0],
            .secret = secret_copy,
        };
        return .{ .prepared = .{
            .allocator = self.allocator,
            .plan = plan,
            .candidates = candidates,
        } };
    }

    pub fn prepareSetServerEnabled(
        self: *ManagementPort,
        expected_generation: u64,
        input: SetServerEnabledInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (serverEnabled(base.servers[index]) == input.enabled and (base.servers[index].installation == null or !base.servers[index].installation.?.stop_pending)) return .unchanged;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index].enabled = input.enabled;
        if (servers[index].installation) |*operation| {
            operation.stop_pending = false;
            if (operation.phase.active()) {
                operation.phase = .cancelled;
                operation.initial_grant_pending = false;
                operation.revision += 1;
            }
        }
        if (input.enabled and (serverProblem(servers[index], self.limits) != null or
            servers[index].connection_approval == null))
            return .rejected;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    pub fn prepareSetAllowedTools(
        self: *ManagementPort,
        expected_generation: u64,
        input: SetAllowedToolsInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (stringSlicesEqual(base.servers[index].tools, input.tools) and (base.servers[index].installation == null or !base.servers[index].installation.?.initial_grant_pending)) return .unchanged;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index].tools = input.tools;
        if (servers[index].installation) |*operation| {
            if (operation.initial_grant_pending) {
                operation.initial_grant_pending = false;
                operation.initial_grant_completed = true;
                operation.phase = .cancelled;
                operation.revision += 1;
            }
        }
        if (serverProblem(servers[index], self.limits) != null) return .rejected;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    pub fn prepareRemoveServer(
        self: *ManagementPort,
        expected_generation: u64,
        server_id: []const u8,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .unchanged;
        const index = findServerIndex(base.servers, server_id) orelse return .unchanged;
        const servers = try self.allocator.alloc(ServerWire, base.servers.len - 1);
        defer self.allocator.free(servers);
        @memcpy(servers[0..index], base.servers[0..index]);
        @memcpy(servers[index..], base.servers[index + 1 ..]);
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .oauth_operation = base.oauth_operation,
            .servers = servers,
        });
    }

    pub fn commitPreparedMutation(
        self: *ManagementPort,
        mutation: *PreparedMutation,
    ) std.mem.Allocator.Error!ManagementOutcome {
        if (!self.mutationReady(mutation.plan.transaction.base_generation))
            return .rejected;
        const commit = self.coordinator.commit(
            self.allocator,
            self.persistence,
            self.credentials,
            &mutation.plan,
            mutation.candidates,
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        return switch (commit) {
            .saved => saved: {
                self.replaceDesired(mutation.plan.takeTarget());
                break :saved .saved;
            },
            .saved_recovery_required => saved: {
                self.replaceDesired(mutation.plan.takeTarget());
                break :saved .saved_recovery_required;
            },
            .registry_outcome_unknown => .indeterminate,
            .not_saved, .not_saved_recovery_required, .blocked => .rejected,
        };
    }

    fn mutationReady(self: *const ManagementPort, expected_generation: u64) bool {
        return self.coordinator.health == .ready and
            expected_generation != std.math.maxInt(u64) and
            expected_generation == generationValue(self.inspect().desired_generation);
    }

    fn prepareTarget(
        self: *ManagementPort,
        expected_generation: u64,
        target: RegistryWire,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        var plan = (planMutation(
            self.allocator,
            if (self.desired) |registry| registry.value else null,
            target,
            expected_generation,
            &.{},
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        }) orelse return .unchanged;
        errdefer plan.deinit();
        return .{ .prepared = .{ .allocator = self.allocator, .plan = plan } };
    }

    fn replaceDesired(
        self: *ManagementPort,
        replacement: std.json.Parsed(RegistryWire),
    ) void {
        self.oauth_schedule.reconcile(replacement.value);
        if (self.desired) |*registry| registry.deinit();
        self.desired = replacement;
        var index: usize = 0;
        while (index < self.convergence.results.items.len) {
            const id = self.convergence.results.items[index].target.id();
            const retained = if (self.runtime_manifest) |*manifest| findManifestEntry(manifest.entries, id) != null else false;
            if (findServer(replacement.value.servers, id) != null or retained) {
                index += 1;
            } else _ = self.convergence.results.swapRemove(index);
        }
    }
};

/// Process-only grant deadlines and retry state. Storage is bounded by registry
/// limits and reserved before any durable mutation; installation cannot fail.
pub const OauthRefreshSchedule = struct {
    const Entry = struct {
        id_len: usize = 0,
        binding: [32]u8 = undefined,
        timing: grant_schedule.Grant = .{ .expires_at = 0 },
    };
    allocator: std.mem.Allocator,
    entries: []Entry,
    ids: []u8,
    id_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) std.mem.Allocator.Error!OauthRefreshSchedule {
        const entries = try allocator.alloc(Entry, limits.max_servers);
        errdefer allocator.free(entries);
        @memset(entries, .{});
        const size = std.math.mul(usize, limits.max_servers, limits.max_identity_bytes) catch return error.OutOfMemory;
        return .{ .allocator = allocator, .entries = entries, .ids = try allocator.alloc(u8, size), .id_capacity = limits.max_identity_bytes };
    }
    pub fn deinit(self: *OauthRefreshSchedule) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.ids);
        self.* = undefined;
    }
    fn id(self: *const OauthRefreshSchedule, index: usize) []const u8 {
        return self.ids[index * self.id_capacity ..][0..self.entries[index].id_len];
    }
    pub fn indexOf(self: *const OauthRefreshSchedule, server_id: []const u8) ?usize {
        for (self.entries, 0..) |entry, index| if (entry.id_len != 0 and std.mem.eql(u8, self.id(index), server_id)) return index;
        return null;
    }
    fn binding(server: ServerWire) ?[32]u8 {
        const oauth = server.auth.oauth orelse return null;
        const consent = oauth.consent orelse return null;
        const grant = oauth.grant orelse return null;
        if (grant.refresh_token_ref == null) return null;
        var hash = Sha256.init(.{});
        hashField(&hash, &connectionFingerprint(server));
        hashField(&hash, consent.fingerprint);
        hashInteger(&hash, consent.epoch);
        hashInteger(&hash, grant.token_revision);
        hashInteger(&hash, grant.expires_at_unix_ms orelse 0);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return digest;
    }
    pub fn reconcile(self: *OauthRefreshSchedule, registry: ?RegistryWire) void {
        // Retire obsolete slots first so full-capacity replacement is no-fail.
        for (self.entries, 0..) |*entry, index| {
            if (entry.id_len == 0) continue;
            const server = if (registry) |value| findServer(value.servers, self.id(index)) else null;
            const next = if (server) |value| binding(value) else null;
            if (next == null or !std.mem.eql(u8, &entry.binding, &next.?)) entry.* = .{};
        }
        const target = registry orelse return;
        for (target.servers) |server| {
            const next = binding(server) orelse continue;
            if (self.indexOf(server.id) != null) continue;
            const index = for (self.entries, 0..) |entry, index| {
                if (entry.id_len == 0) break index;
            } else unreachable;
            std.debug.assert(server.id.len <= self.id_capacity);
            @memcpy(self.ids[index * self.id_capacity ..][0..server.id.len], server.id);
            self.entries[index] = .{ .id_len = server.id.len, .binding = next, .timing = .{ .expires_at = server.auth.oauth.?.grant.?.expires_at_unix_ms orelse std.math.maxInt(u64) } };
        }
    }
    pub fn observeTime(self: *OauthRefreshSchedule, now_ms: ?u64) void {
        for (self.entries) |*entry| {
            if (entry.id_len != 0) entry.timing.observeTime(now_ms);
        }
    }
    pub fn eligibleAt(self: *const OauthRefreshSchedule, server_id: []const u8, expiry: u64) u64 {
        const index = self.indexOf(server_id) orelse return expiry;
        return self.entries[index].timing.eligibleAt();
    }

    pub fn requestRefresh(self: *OauthRefreshSchedule, server_id: []const u8) void {
        if (self.indexOf(server_id)) |index| self.entries[index].timing.manual_requested = true;
    }

    pub fn refreshRequested(self: *const OauthRefreshSchedule, server_id: []const u8) bool {
        const index = self.indexOf(server_id) orelse return false;
        return self.entries[index].timing.manual_requested;
    }
    pub fn deferServer(self: *OauthRefreshSchedule, server_id: []const u8, now_ms: ?u64) void {
        const index = self.indexOf(server_id) orelse return;
        self.entries[index].timing.deferAttempt(now_ms);
    }
};

fn generationValue(generation: ?u64) u64 {
    return generation orelse 0;
}

fn stringSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value|
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    return true;
}

fn cloneRegistry(
    allocator: std.mem.Allocator,
    registry: RegistryWire,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(RegistryWire) {
    const buffer = try allocator.alloc(u8, max_store_bytes);
    defer allocator.free(buffer);
    const bytes = try encode(buffer, registry, limits);
    return try decode(allocator, bytes, limits);
}

fn findServerIndex(servers: []const ServerWire, id: []const u8) ?usize {
    for (servers, 0..) |server, index|
        if (std.mem.eql(u8, server.id, id)) return index;
    return null;
}

fn literalArguments(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error![]ValueSourceWire {
    const values = try allocator.alloc(ValueSourceWire, arguments.len);
    for (arguments, 0..) |argument, index| values[index] = .{ .literal = argument };
    return values;
}

fn secretSlotsFromNames(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    existing: []const SecretSlotWire,
    semantics: enum { exact, http_header },
) std.mem.Allocator.Error![]SecretSlotWire {
    const slots = try allocator.alloc(SecretSlotWire, names.len);
    for (names, slots) |name, *slot| {
        slot.* = .{ .name = name, .credential_ref = null };
        for (existing) |candidate| {
            const same_name = switch (semantics) {
                .exact => std.mem.eql(u8, candidate.name, name),
                .http_header => std.ascii.eqlIgnoreCase(candidate.name, name),
            };
            if (!same_name) continue;
            slot.credential_ref = candidate.credential_ref;
            break;
        }
    }
    return slots;
}

fn staticAuth(mode: StaticAuthMode) AuthWire {
    return .{
        .kind = switch (mode) {
            .none => "none",
            .static => "static",
        },
        .oauth = null,
    };
}

/// Static credentials belong to the process or endpoint that receives them,
/// not to an environment/header name in isolation. Presentation, timeout and
/// negotiation changes do not move that destination; executable/argv/cwd,
/// endpoint or auth-mode changes do.
fn staticCredentialDestinationEqual(
    existing: ServerWire,
    replacement: TransportWire,
    replacement_auth: StaticAuthMode,
) bool {
    if (replacement_auth != .static or
        !std.mem.eql(u8, existing.auth.kind, "static") or
        !std.mem.eql(u8, existing.transport.kind, replacement.kind))
        return false;
    if (std.mem.eql(u8, replacement.kind, "streamable_http"))
        return optionalTextEqual(existing.transport.url, replacement.url) and
            sensitiveEndpointEqual(existing.transport.sensitive_endpoint, replacement.sensitive_endpoint);
    if (!std.mem.eql(u8, replacement.kind, "stdio") or
        !optionalTextEqual(existing.transport.command, replacement.command) or
        !optionalTextEqual(existing.transport.cwd, replacement.cwd) or
        existing.transport.arguments.len != replacement.arguments.len)
        return false;
    for (existing.transport.arguments, replacement.arguments) |left, right|
        if (!optionalTextEqual(left.literal, right.literal) or
            !optionalTextEqual(left.credential_ref, right.credential_ref))
            return false;
    return true;
}

fn oauthAuth(client: OauthClientPlan) AuthWire {
    const registration: OauthRegistrationWire = switch (client) {
        .pre_registered => |value| .{
            .kind = "pre_registered",
            .issuer = null,
            .client_id = value.client_id,
            .token_endpoint_auth_method = value.token_endpoint_auth_method,
            .client_credential_revision = 1,
            .client_secret_ref = null,
        },
        .dynamic_registration => .{
            .kind = "dynamic_registration",
            .issuer = null,
            .client_id = null,
            .token_endpoint_auth_method = null,
            .client_credential_revision = 0,
            .client_secret_ref = null,
        },
    };
    return .{ .kind = "oauth", .oauth = .{
        .status = switch (client) {
            .pre_registered => "consent_required",
            .dynamic_registration => "client_registration_required",
        },
        .registration = registration,
        .consent = null,
        .grant = null,
    } };
}

fn findSecretSlot(slots: []const SecretSlotWire, name: []const u8) ?usize {
    for (slots, 0..) |slot, index|
        if (std.ascii.eqlIgnoreCase(slot.name, name)) return index;
    return null;
}

fn validateCommitInputs(
    plan: *const MutationPlan,
    candidates: []const CandidateCredential,
    limits: Limits,
) Error!void {
    validateTransaction(&plan.transaction, limits) catch return error.InvalidMutation;
    const target = try plan.targetRegistry();
    validateRegistryIdentity(&target, limits) catch return error.InvalidMutation;
    if (target.generation != plan.transaction.target_generation)
        return error.InvalidMutation;
    if (candidates.len != plan.transaction.candidate_locators.len)
        return error.InvalidMutation;
    for (candidates, 0..) |candidate, index| {
        if (!containsText(plan.transaction.candidate_locators, candidate.locator) or
            candidate.secret.len == 0 or
            candidate.secret.len > limits.max_credential_secret_bytes)
            return error.InvalidMutation;
        for (candidates[0..index]) |previous|
            if (std.mem.eql(u8, previous.locator, candidate.locator))
                return error.InvalidMutation;
    }
}

fn candidateForLocator(
    candidates: []const CandidateCredential,
    locator: []const u8,
) ?CandidateCredential {
    for (candidates) |candidate|
        if (std.mem.eql(u8, candidate.locator, locator)) return candidate;
    return null;
}

fn deleteAll(credentials: CredentialEffects, locators: []const []const u8) bool {
    var deleted = true;
    for (locators) |locator| deleted = credentials.delete(locator) and deleted;
    return deleted;
}

pub const ServerProblem = enum {
    invalid_namespace,
    invalid_display_name,
    invalid_negotiation,
    invalid_timeout,
    invalid_transport,
    invalid_authentication,
    invalid_connection_approval,
    invalid_allowlist,
    invalid_credential_locator,
    credential_capacity_exceeded,
};

pub const ServerPreparationState = union(enum) {
    eligible,
    disabled,
    unapproved,
    needs_authentication,
    reauth_required,
    invalid_catalog: ServerProblem,
};

pub const UnavailableReason = enum {
    persistence_unavailable,
    read_failed,
    corrupt,
    credential_store_unavailable,
};

pub const PreparationState = union(enum) {
    empty,
    available,
    unavailable: UnavailableReason,
};

pub const CredentialResolution = union(enum) {
    /// The callback allocates with the supplied allocator and transfers
    /// ownership to the caller.
    value: []u8,
    missing,
    unavailable,
    out_of_memory,
};

pub const CredentialResolver = struct {
    context: ?*anyopaque = null,
    available: bool = false,
    resolve_fn: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        locator: []const u8,
    ) CredentialResolution = unavailableCredential,

    fn resolve(
        self: CredentialResolver,
        allocator: std.mem.Allocator,
        locator: []const u8,
    ) CredentialResolution {
        if (!self.available) return .unavailable;
        return self.resolve_fn(self.context, allocator, locator);
    }

    fn unavailableCredential(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
    ) CredentialResolution {
        return .unavailable;
    }
};

pub const ResolvedCredential = struct {
    locator: []const u8,
    secret: []u8,
};

pub const Preparation = struct {
    allocator: std.mem.Allocator,
    state: PreparationState,
    recovery_diagnostic: RecoveryDiagnostic = .none,
    registry: ?std.json.Parsed(RegistryWire) = null,
    server_states: []ServerPreparationState = &.{},
    credentials: []ResolvedCredential = &.{},

    pub fn deinit(self: *Preparation) void {
        for (self.credentials) |credential| secureFree(self.allocator, credential.secret);
        if (self.credentials.len != 0) self.allocator.free(self.credentials);
        if (self.server_states.len != 0) self.allocator.free(self.server_states);
        if (self.registry) |*registry| registry.deinit();
        self.* = undefined;
    }

    pub fn generation(self: *const Preparation) ?u64 {
        return if (self.registry) |registry| registry.value.generation else null;
    }

    /// Releases the linear credential staging copy after App has constructed
    /// Agent-owned transport capabilities. Product state retains only the
    /// registry and per-server preparation facts.
    pub fn releaseCredentials(self: *Preparation) void {
        for (self.credentials) |credential| secureFree(self.allocator, credential.secret);
        if (self.credentials.len != 0) self.allocator.free(self.credentials);
        self.credentials = &.{};
    }

    /// Moves the complete preparation into Workbench after every other
    /// fallible initialization step has succeeded.
    pub fn take(self: *Preparation) Preparation {
        const moved = self.*;
        self.* = undefined;
        return moved;
    }
};

const DescriptorFingerprint = [32]u8;

const AbsenceProof = union(enum) {
    disabled,
    unapproved,
    needs_authentication: DescriptorFingerprint,
    reauth_required: DescriptorFingerprint,
    invalid_catalog: struct {
        problem: ServerProblem,
        fingerprint: DescriptorFingerprint,
    },
};

const RuntimeManifestEntry = struct {
    id: []const u8,
    task_references: u32 = 0,
    state: union(enum) {
        loaded: DescriptorFingerprint,
        absent: AbsenceProof,
    },
};

/// In-memory proof of accepted descriptors with live Product lifetime counts.
/// Descriptor facts are immutable until apply; reference counts never authorize
/// a tool. It contains no credentials and is never persisted or sent over Bridge.
pub const RuntimeManifest = struct {
    allocator: std.mem.Allocator,
    entries: []RuntimeManifestEntry,

    /// Returns a proof for every successfully prepared Runtime input,
    /// including a zero-entry proof for the canonical empty configuration.
    /// Null is reserved for unavailable preparation facts.
    pub fn candidate(
        allocator: std.mem.Allocator,
        preparation: *const Preparation,
    ) std.mem.Allocator.Error!?RuntimeManifest {
        switch (preparation.state) {
            .empty => return .{
                .allocator = allocator,
                .entries = try allocator.alloc(RuntimeManifestEntry, 0),
            },
            .available => {},
            .unavailable => return null,
        }
        std.debug.assert(preparation.registry != null);
        const registry = preparation.registry.?.value;
        std.debug.assert(preparation.server_states.len == registry.servers.len);
        const entries = try allocator.alloc(RuntimeManifestEntry, registry.servers.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |entry| allocator.free(entry.id);
            allocator.free(entries);
        }
        for (registry.servers, preparation.server_states, 0..) |server, state, index| {
            entries[index] = .{
                .id = try allocator.dupe(u8, server.id),
                .state = switch (state) {
                    .eligible => .{ .loaded = runtimeDescriptorFingerprint(server) },
                    .disabled => .{ .absent = .disabled },
                    .unapproved => .{ .absent = .unapproved },
                    .needs_authentication => .{
                        .absent = .{ .needs_authentication = authenticationFingerprint(server) },
                    },
                    .reauth_required => .{
                        .absent = .{ .reauth_required = authenticationFingerprint(server) },
                    },
                    .invalid_catalog => |problem| .{
                        .absent = .{ .invalid_catalog = .{
                            .problem = problem,
                            .fingerprint = validationFingerprint(server),
                        } },
                    },
                },
            };
            initialized += 1;
        }
        return .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *RuntimeManifest) void {
        for (self.entries) |entry| self.allocator.free(entry.id);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn take(self: *RuntimeManifest) RuntimeManifest {
        const moved = self.*;
        self.* = undefined;
        return moved;
    }

    pub fn alignment(
        self: *const RuntimeManifest,
        desired: ?RegistryWire,
        limits: Limits,
    ) RuntimeAlignment {
        return self.alignmentWithResults(desired, limits, null);
    }

    pub fn alignmentWithResults(
        self: *const RuntimeManifest,
        desired: ?RegistryWire,
        limits: Limits,
        convergence: ?*const RuntimeConvergence,
    ) RuntimeAlignment {
        return if (self.nextStep(desired, limits, convergence) != null) .restart_required else .current;
    }

    pub const Plan = struct { target: RuntimeApplyTarget, next_round: bool = false };

    /// Count only failed attempts that still describe actual membership work.
    /// This also keeps failed removals visible after their Desired row is gone.
    pub fn failureCount(self: *const RuntimeManifest, desired: ?RegistryWire, limits: Limits, convergence: *const RuntimeConvergence) usize {
        var count: usize = 0;
        for (convergence.results.items) |result| {
            if (result.outcome == .pending or result.outcome == .waiting_auth or !convergence.handled(result.target)) continue;
            const target = self.targetFor(result.target.id(), desired, limits) orelse continue;
            if (std.mem.eql(u8, &target.fingerprint, &result.target.fingerprint)) count += 1;
        }
        return count;
    }

    /// The sole membership policy. A waiting/unloadable Desired is not work;
    /// retained membership and admission authorization are independent facts.
    pub fn targetFor(self: *const RuntimeManifest, id: []const u8, desired: ?RegistryWire, limits: Limits) ?RuntimeApplyTarget {
        const target = if (desired) |registry| findServer(registry.servers, id) else null;
        const entry = findManifestEntry(self.entries, id);
        const eligible = if (target) |server| runtimeLoadEligible(server, limits) else false;
        if (entry) |actual| {
            if (actual.state == .loaded) {
                if (!eligible) return if (actual.task_references != 0) null else RuntimeApplyTarget.init(id, target, .remove);
                if (std.mem.eql(u8, &actual.state.loaded, &runtimeDescriptorFingerprint(target.?))) return null;
                return RuntimeApplyTarget.init(id, target, .replace);
            }
            if (entryCompatible(actual.*, target, limits)) return null;
        }
        return if (eligible) RuntimeApplyTarget.init(id, target, .add) else null;
    }

    pub fn nextStep(self: *const RuntimeManifest, desired: ?RegistryWire, limits: Limits, convergence: ?*const RuntimeConvergence) ?Plan {
        // Removal makes space first. All other actions follow Desired order.
        for ([_]bool{ false, true }) |next_round| {
            if (next_round) {
                const ledger = convergence orelse break;
                const eligible_round = for (ledger.results.items) |result| {
                    if (result.epoch != ledger.epoch and result.round == ledger.round and result.outcome != .pending and result.outcome != .waiting_auth) break true;
                } else false;
                if (!eligible_round) break;
            }
            for (self.entries) |entry| {
                const target = self.targetFor(entry.id, desired, limits) orelse continue;
                if (target.kind != .remove) continue;
                if (convergence) |ledger| if (ledger.handledInRound(target, next_round)) continue;
                return .{ .target = target, .next_round = next_round };
            }
            if (desired) |registry| for (registry.servers) |server| {
                const target = self.targetFor(server.id, desired, limits) orelse continue;
                if (target.kind == .remove) continue;
                if (convergence) |ledger| if (ledger.handledInRound(target, next_round)) continue;
                return .{ .target = target, .next_round = next_round };
            };
        }
        return null;
    }
};

fn entryCompatible(
    entry: RuntimeManifestEntry,
    target: ?ServerWire,
    limits: Limits,
) bool {
    return switch (entry.state) {
        .loaded => unreachable,
        .absent => |proof| switch (proof) {
            .disabled => if (target) |server| !serverEnabled(server) else true,
            .unapproved => if (target) |server|
                !serverEnabled(server) or server.connection_approval == null
            else
                true,
            .needs_authentication => |fingerprint| if (target) |server|
                !serverEnabled(server) or
                    serverProblem(server, limits) != null or
                    oauthDoesNotRequireLoading(server) or
                    std.mem.eql(u8, &fingerprint, &authenticationFingerprint(server))
            else
                true,
            .reauth_required => |fingerprint| if (target) |server|
                !serverEnabled(server) or
                    serverProblem(server, limits) != null or
                    oauthDoesNotRequireLoading(server) or
                    std.mem.eql(u8, &fingerprint, &authenticationFingerprint(server))
            else
                true,
            .invalid_catalog => |invalid| if (target) |server| invalid_target: {
                if (!serverEnabled(server)) break :invalid_target true;
                if (serverProblem(server, limits) != null)
                    break :invalid_target true;
                break :invalid_target invalid.problem == .credential_capacity_exceeded and
                    std.mem.eql(u8, &invalid.fingerprint, &validationFingerprint(server));
            } else true,
        },
    };
}

pub fn serverRuntimeAuthorizationReady(server: ServerWire) bool {
    if (server.connection_approval == null) return false;
    if (server.auth.oauth) |oauth|
        return std.mem.eql(u8, oauth.status, "ready") and oauth.grant != null;
    return true;
}

pub fn runtimeLoadEligible(server: ServerWire, limits: Limits) bool {
    return serverEnabled(server) and serverRuntimeAuthorizationReady(server) and serverProblem(server, limits) == null;
}

pub fn admissionTools(registry: RegistryWire, server: ServerWire) []const []const u8 {
    if (!serverEnabled(server) or !serverRuntimeAuthorizationReady(server)) return &.{};
    if (registry.oauth_operation) |operation|
        if (std.mem.eql(u8, operation.server_id, server.id)) return &.{};
    return server.tools;
}

fn oauthDoesNotRequireLoading(server: ServerWire) bool {
    if (!std.mem.eql(u8, server.auth.kind, "oauth")) return false;
    const oauth = server.auth.oauth orelse return false;
    return !std.mem.eql(u8, oauth.status, "ready");
}

fn oauthClientPlanMatches(auth: AuthWire, plan: OauthClientPlan) bool {
    if (!std.mem.eql(u8, auth.kind, "oauth")) return false;
    const registration = (auth.oauth orelse return false).registration;
    return switch (plan) {
        .dynamic_registration => std.mem.eql(u8, registration.kind, "dynamic_registration"),
        .pre_registered => |client| std.mem.eql(u8, registration.kind, "pre_registered") and
            optionalTextEqual(registration.client_id, client.client_id) and
            optionalTextEqual(registration.token_endpoint_auth_method, client.token_endpoint_auth_method),
    };
}

fn findManifestEntry(
    entries: []const RuntimeManifestEntry,
    id: []const u8,
) ?*const RuntimeManifestEntry {
    for (entries) |*entry|
        if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

fn findServer(servers: []const ServerWire, id: []const u8) ?ServerWire {
    for (servers) |server|
        if (std.mem.eql(u8, server.id, id)) return server;
    return null;
}

pub fn connectionFingerprint(server: ServerWire) [64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, "metawork.mcp.connection-approval/v1");
    hashField(&hash, server.negotiation);
    hashField(&hash, server.auth.kind);
    hashField(&hash, server.transport.kind);
    hashOptionalField(&hash, server.transport.command);
    hashInteger(&hash, server.transport.arguments.len);
    for (server.transport.arguments) |argument|
        hashOptionalField(&hash, argument.literal);
    hashOptionalField(&hash, server.transport.cwd);
    hashInteger(&hash, server.transport.environment.len);
    for (server.transport.environment) |entry| hashField(&hash, entry.name);
    hashOptionalField(&hash, server.transport.url);
    hashSensitiveEndpoint(&hash, server.transport.sensitive_endpoint);
    hashInteger(&hash, server.transport.headers.len);
    for (server.transport.headers) |entry| hashField(&hash, entry.name);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn oauthConsentFingerprint(
    server: ServerWire,
    consent: OauthConsentWire,
) ?[64]u8 {
    var hash = Sha256.init(.{});
    hashField(&hash, "metawork.mcp.oauth-consent/v1");
    const connection = connectionFingerprint(server);
    hashField(&hash, &connection);
    const oauth = server.auth.oauth orelse return null;
    hashField(&hash, oauth.registration.kind);
    hashOptionalField(&hash, oauth.registration.issuer);
    hashOptionalField(&hash, oauth.registration.client_id);
    hashOptionalField(&hash, oauth.registration.token_endpoint_auth_method);
    hashInteger(&hash, oauth.registration.client_credential_revision);
    hashField(&hash, consent.resource);
    hashSensitiveEndpoint(&hash, consent.private_resource);
    hashField(&hash, consent.issuer);
    hashInteger(&hash, consent.scopes.len);
    for (consent.scopes) |scope| hashField(&hash, scope);
    hashField(&hash, consent.redirect_uri);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn oauthConsentDraftFingerprint(
    server: ServerWire,
    epoch: u64,
    draft: OauthConsentDraftWire,
) ?[64]u8 {
    const oauth = server.auth.oauth orelse return null;
    var hash = Sha256.init(.{});
    hashField(&hash, "metawork.mcp.oauth-consent-draft/v1");
    const connection = connectionFingerprint(server);
    hashField(&hash, &connection);
    hashField(&hash, oauth.registration.kind);
    hashInteger(&hash, epoch);
    hashField(&hash, draft.resource);
    hashSensitiveEndpoint(&hash, draft.private_resource);
    hashField(&hash, draft.issuer);
    hashInteger(&hash, draft.scopes.len);
    for (draft.scopes) |scope| hashField(&hash, scope);
    hashField(&hash, draft.redirect_uri);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn runtimeDescriptorFingerprint(server: ServerWire) DescriptorFingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "metawork.mcp.runtime-descriptor/v1");
    hashField(&hash, server.namespace);
    hashField(&hash, server.negotiation);
    hashInteger(&hash, server.timeout_ms);
    hashTransport(&hash, server.transport);
    hashField(&hash, server.auth.kind);
    if (server.auth.oauth) |oauth| {
        hashField(&hash, oauth.registration.kind);
        hashOptionalField(&hash, oauth.registration.client_id);
        if (oauth.consent) |consent| {
            hashInteger(&hash, consent.epoch);
            hashField(&hash, consent.fingerprint);
        }
    }
    var result: DescriptorFingerprint = undefined;
    hash.final(&result);
    return result;
}

fn validationFingerprint(server: ServerWire) DescriptorFingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "metawork.mcp.absence-proof/v1");
    hashField(&hash, server.display_name);
    hashField(&hash, server.namespace);
    hashField(&hash, server.negotiation);
    hashInteger(&hash, server.timeout_ms);
    hashTransport(&hash, server.transport);
    hashInteger(&hash, server.tools.len);
    for (server.tools) |tool| hashField(&hash, tool);
    var result: DescriptorFingerprint = undefined;
    hash.final(&result);
    return result;
}

fn authenticationFingerprint(server: ServerWire) DescriptorFingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "metawork.mcp.authentication-absence/v1");
    hashField(&hash, server.auth.kind);
    hashInteger(&hash, credentialReferenceCount(server) - if (server.installation) |operation| operation.request_refs.len else @as(usize, 0));
    if (server.transport.sensitive_endpoint) |endpoint|
        for (endpoint.credential_refs) |locator| hashField(&hash, locator);
    for (server.transport.arguments) |argument| {
        if (argument.credential_ref) |locator| hashField(&hash, locator);
    }
    for (server.transport.environment) |entry| {
        if (entry.credential_ref) |locator| hashField(&hash, locator);
    }
    for (server.transport.headers) |entry| {
        if (entry.credential_ref) |locator| hashField(&hash, locator);
    }
    if (server.auth.oauth) |oauth| {
        hashField(&hash, oauth.status);
        hashOptionalField(&hash, oauth.registration.client_secret_ref);
        if (oauth.grant) |grant| {
            hashField(&hash, grant.access_token_ref);
            hashOptionalField(&hash, grant.refresh_token_ref);
        }
    }
    var result: DescriptorFingerprint = undefined;
    hash.final(&result);
    return result;
}

const Sha256 = std.crypto.hash.sha2.Sha256;

fn hashTransport(hash: *Sha256, transport: TransportWire) void {
    hashField(hash, transport.kind);
    hashOptionalField(hash, transport.command);
    hashInteger(hash, transport.arguments.len);
    for (transport.arguments) |argument| hashValueSource(hash, argument);
    hashOptionalField(hash, transport.cwd);
    hashInteger(hash, transport.environment.len);
    for (transport.environment) |entry| {
        hashField(hash, entry.name);
        hashOptionalField(hash, entry.credential_ref);
    }
    hashOptionalField(hash, transport.url);
    hashSensitiveEndpoint(hash, transport.sensitive_endpoint);
    hashInteger(hash, transport.headers.len);
    for (transport.headers) |entry| {
        hashField(hash, entry.name);
        hashOptionalField(hash, entry.credential_ref);
    }
}

fn hashSensitiveEndpoint(hash: *Sha256, endpoint: ?SensitiveEndpointWire) void {
    // Preserve existing public connection fingerprints during schema migration.
    if (endpoint) |value| {
        hashField(hash, "sensitive-endpoint/v1");
        hashField(hash, value.origin);
        hashField(hash, value.identity);
        hashInteger(hash, value.credential_refs.len);
        for (value.credential_refs) |locator| hashField(hash, locator);
        hashInteger(hash, value.secret_parts.len);
        for (value.secret_parts) |part| hashInteger(hash, part);
    }
}

fn hashValueSource(hash: *Sha256, source: ValueSourceWire) void {
    hashOptionalField(hash, source.literal);
    hashOptionalField(hash, source.credential_ref);
}

fn hashOptionalField(hash: *Sha256, value: ?[]const u8) void {
    if (value) |bytes| {
        hash.update(&.{1});
        hashField(hash, bytes);
    } else {
        hash.update(&.{0});
    }
}

fn hashField(hash: *Sha256, bytes: []const u8) void {
    hashInteger(hash, bytes.len);
    hash.update(bytes);
}

fn hashInteger(hash: *Sha256, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

/// Restores a registry and resolves only credentials referenced by enabled,
/// semantically valid servers. Expected MCP failures become typed state; only
/// allocator failure escapes as a fatal error.
pub fn prepare(
    allocator: std.mem.Allocator,
    restored_bytes: ?[]const u8,
    persistence_available: bool,
    restore_failed: bool,
    resolver: CredentialResolver,
    limits: Limits,
) std.mem.Allocator.Error!Preparation {
    if (!persistence_available)
        return .{ .allocator = allocator, .state = .{ .unavailable = .persistence_unavailable } };
    if (restore_failed)
        return .{ .allocator = allocator, .state = .{ .unavailable = .read_failed } };
    const bytes = restored_bytes orelse
        return .{ .allocator = allocator, .state = .empty };
    var registry = decode(allocator, bytes, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .allocator = allocator, .state = .{ .unavailable = .corrupt } },
    };
    errdefer registry.deinit();
    const server_states = try allocator.alloc(ServerPreparationState, registry.value.servers.len);
    errdefer allocator.free(server_states);
    var credentials: std.ArrayList(ResolvedCredential) = .empty;
    errdefer {
        for (credentials.items) |credential| secureFree(allocator, credential.secret);
        credentials.deinit(allocator);
    }

    for (registry.value.servers, 0..) |server, index| {
        if (serverProblem(server, limits)) |problem| {
            server_states[index] = .{ .invalid_catalog = problem };
            continue;
        }
        if (!serverEnabled(server)) {
            server_states[index] = .disabled;
            continue;
        }
        if (registry.value.oauth_operation) |operation| {
            if (std.mem.eql(u8, operation.server_id, server.id)) {
                server_states[index] = .reauth_required;
                continue;
            }
        }
        if (server.connection_approval == null) {
            server_states[index] = .unapproved;
            continue;
        }
        if (server.auth.oauth) |oauth| {
            if (std.mem.eql(u8, oauth.status, "reauth_required")) {
                server_states[index] = .reauth_required;
                continue;
            }
            if (!std.mem.eql(u8, oauth.status, "ready")) {
                server_states[index] = .needs_authentication;
                continue;
            }
        }
        const resolution = resolveServerCredentials(
            allocator,
            server,
            resolver,
            limits,
            &credentials,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CredentialStoreUnavailable => {
                for (credentials.items) |credential| secureFree(allocator, credential.secret);
                credentials.deinit(allocator);
                allocator.free(server_states);
                registry.deinit();
                return .{
                    .allocator = allocator,
                    .state = .{ .unavailable = .credential_store_unavailable },
                };
            },
        };
        if (!resolution) {
            server_states[index] = .needs_authentication;
            continue;
        }
        server_states[index] = switch (try validateResolvedServerCredentials(
            allocator,
            server,
            credentials.items,
            limits,
        )) {
            .usable => .eligible,
            .unusable => .needs_authentication,
            .capacity_exceeded => .{
                .invalid_catalog = .credential_capacity_exceeded,
            },
        };
    }
    pruneUnusedCredentials(registry.value.servers, server_states, allocator, &credentials);
    return .{
        .allocator = allocator,
        .state = .available,
        .registry = registry,
        .server_states = server_states,
        .credentials = try credentials.toOwnedSlice(allocator),
    };
}

fn pruneUnusedCredentials(
    servers: []const ServerWire,
    states: []const ServerPreparationState,
    allocator: std.mem.Allocator,
    credentials: *std.ArrayList(ResolvedCredential),
) void {
    var write: usize = 0;
    for (credentials.items) |credential| {
        var used = false;
        for (servers, states) |server, state| {
            if (state != .eligible) continue;
            if (serverReferencesCredential(server, credential.locator)) {
                used = true;
                break;
            }
        }
        if (!used) {
            secureFree(allocator, credential.secret);
            continue;
        }
        credentials.items[write] = credential;
        write += 1;
    }
    credentials.shrinkRetainingCapacity(write);
}

fn serverReferencesCredential(server: ServerWire, locator: []const u8) bool {
    if (server.installation) |operation| for (operation.request_refs) |reference| {
        if (std.mem.eql(u8, reference, locator)) return true;
    };
    if (server.transport.sensitive_endpoint) |endpoint|
        for (endpoint.credential_refs) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (oauthPrivateResources(server)) |resource| if (resource) |endpoint|
        for (endpoint.credential_refs) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.arguments) |value|
        if (value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.environment) |entry|
        if (entry.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.headers) |entry|
        if (entry.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    if (server.auth.oauth) |oauth| {
        if (oauth.registration.client_secret_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
        if (oauth.grant) |grant| {
            if (std.mem.eql(u8, grant.access_token_ref, locator)) return true;
            if (grant.refresh_token_ref) |candidate|
                if (std.mem.eql(u8, candidate, locator)) return true;
        }
    }
    return false;
}

const ResolveError = std.mem.Allocator.Error || error{CredentialStoreUnavailable};

fn resolveServerCredentials(
    allocator: std.mem.Allocator,
    server: ServerWire,
    resolver: CredentialResolver,
    limits: Limits,
    credentials: *std.ArrayList(ResolvedCredential),
) ResolveError!bool {
    var ready = true;
    for (oauthPrivateResources(server)) |resource| if (resource) |endpoint|
        for (endpoint.credential_refs) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        };
    if (server.transport.sensitive_endpoint) |endpoint|
        for (endpoint.credential_refs) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        };
    for (server.transport.arguments) |value| {
        if (value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    for (server.transport.environment) |entry| {
        if (entry.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    for (server.transport.headers) |entry| {
        if (entry.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    if (server.auth.oauth) |oauth| {
        if (oauth.registration.client_secret_ref) |locator|
            ready = (try resolveCredential(
                allocator,
                locator,
                resolver,
                limits,
                credentials,
            )) and ready;
        if (oauth.grant) |grant| {
            ready = (try resolveCredential(
                allocator,
                grant.access_token_ref,
                resolver,
                limits,
                credentials,
            )) and ready;
            if (grant.refresh_token_ref) |locator|
                ready = (try resolveCredential(
                    allocator,
                    locator,
                    resolver,
                    limits,
                    credentials,
                )) and ready;
        }
    }
    return ready;
}

fn resolveCredential(
    allocator: std.mem.Allocator,
    locator: []const u8,
    resolver: CredentialResolver,
    limits: Limits,
    credentials: *std.ArrayList(ResolvedCredential),
) ResolveError!bool {
    for (credentials.items) |credential|
        if (std.mem.eql(u8, credential.locator, locator)) return true;
    return switch (resolver.resolve(allocator, locator)) {
        .unavailable => error.CredentialStoreUnavailable,
        .out_of_memory => error.OutOfMemory,
        .missing => false,
        .value => |secret| blk: {
            if (secret.len == 0 or secret.len > limits.max_credential_secret_bytes) {
                secureFree(allocator, secret);
                break :blk false;
            }
            errdefer secureFree(allocator, secret);
            try credentials.append(allocator, .{ .locator = locator, .secret = secret });
            break :blk true;
        },
    };
}

const CredentialUse = enum { usable, unusable, capacity_exceeded };

fn validateResolvedServerCredentials(
    allocator: std.mem.Allocator,
    server: ServerWire,
    credentials: []const ResolvedCredential,
    limits: Limits,
) std.mem.Allocator.Error!CredentialUse {
    var unique_secrets: std.ArrayList([]const u8) = .empty;
    defer unique_secrets.deinit(allocator);
    var total_bytes: usize = 0;

    if (std.mem.eql(u8, server.transport.kind, "stdio")) {
        for (server.transport.environment) |entry| {
            const locator = entry.credential_ref orelse return .unusable;
            const secret = resolvedCredential(credentials, locator) orelse return .unusable;
            if (!validEnvironmentCredential(secret)) return .unusable;
            if (try appendUniqueSecret(allocator, &unique_secrets, secret)) {
                total_bytes = std.math.add(usize, total_bytes, secret.len) catch
                    return .capacity_exceeded;
            }
        }
    } else if (std.mem.eql(u8, server.transport.kind, "streamable_http")) {
        if (server.transport.sensitive_endpoint) |endpoint| {
            const resolved = resolveEndpoint(allocator, server.transport, credentials, limits.max_url_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidEndpoint => return .unusable,
            };
            defer secureFree(allocator, resolved);
            for (endpoint.credential_refs) |locator| {
                const secret = resolvedCredential(credentials, locator) orelse return .unusable;
                if (try appendUniqueSecret(allocator, &unique_secrets, secret))
                    total_bytes = std.math.add(usize, total_bytes, secret.len) catch return .capacity_exceeded;
            }
        }
        for (server.transport.headers) |entry| {
            const locator = entry.credential_ref orelse return .unusable;
            const secret = resolvedCredential(credentials, locator) orelse return .unusable;
            if (!validHttpHeaderCredential(secret)) return .unusable;
            if (try appendUniqueSecret(allocator, &unique_secrets, secret)) {
                total_bytes = std.math.add(usize, total_bytes, secret.len) catch
                    return .capacity_exceeded;
            }
        }
    } else return .unusable;

    if (server.auth.oauth) |oauth| {
        for (oauthPrivateResources(server)) |resource| if (resource) |endpoint| {
            const resolved = resolveEndpoint(allocator, .{ .kind = "streamable_http", .sensitive_endpoint = endpoint }, credentials, limits.max_oauth_uri_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidEndpoint => return .unusable,
            };
            defer secureFree(allocator, resolved);
            for (endpoint.credential_refs) |locator| {
                const secret = resolvedCredential(credentials, locator) orelse return .unusable;
                if (try appendUniqueSecret(allocator, &unique_secrets, secret))
                    total_bytes = std.math.add(usize, total_bytes, secret.len) catch return .capacity_exceeded;
            }
        };
        if (oauth.registration.client_secret_ref) |locator| {
            const secret = resolvedCredential(credentials, locator) orelse return .unusable;
            if (!validHttpHeaderCredential(secret)) return .unusable;
            if (try appendUniqueSecret(allocator, &unique_secrets, secret))
                total_bytes = std.math.add(usize, total_bytes, secret.len) catch
                    return .capacity_exceeded;
        }
        const grant = oauth.grant orelse return .unusable;
        const access_token = resolvedCredential(
            credentials,
            grant.access_token_ref,
        ) orelse return .unusable;
        if (!validHttpHeaderCredential(access_token)) return .unusable;
        if (try appendUniqueSecret(allocator, &unique_secrets, access_token))
            total_bytes = std.math.add(usize, total_bytes, access_token.len) catch
                return .capacity_exceeded;
        if (grant.refresh_token_ref) |locator| {
            const refresh_token = resolvedCredential(credentials, locator) orelse return .unusable;
            if (!validHttpHeaderCredential(refresh_token)) return .unusable;
            if (try appendUniqueSecret(allocator, &unique_secrets, refresh_token))
                total_bytes = std.math.add(usize, total_bytes, refresh_token.len) catch
                    return .capacity_exceeded;
        }
    }

    if (unique_secrets.items.len > limits.max_runtime_secrets_per_server or
        total_bytes > limits.max_runtime_secret_bytes_per_server)
        return .capacity_exceeded;
    return .usable;
}

fn appendUniqueSecret(
    allocator: std.mem.Allocator,
    secrets: *std.ArrayList([]const u8),
    candidate: []const u8,
) std.mem.Allocator.Error!bool {
    for (secrets.items) |secret|
        if (std.mem.eql(u8, secret, candidate)) return false;
    try secrets.append(allocator, candidate);
    return true;
}

fn resolvedCredential(
    credentials: []const ResolvedCredential,
    locator: []const u8,
) ?[]const u8 {
    for (credentials) |credential|
        if (std.mem.eql(u8, credential.locator, locator)) return credential.secret;
    return null;
}

pub fn validEnvironmentCredential(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null;
}

pub fn validHttpHeaderCredential(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f)
        return false;
    return true;
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

pub fn decode(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(RegistryWire) {
    return switch (try registrySourceSchemaVersion(allocator, input)) {
        schema_version => decodeCurrent(allocator, input, limits),
        2 => migrateSchemaTwo(allocator, input, limits),
        1 => migrateLegacyRegistry(allocator, input, limits),
        else => error.RegistryCorrupt,
    };
}

fn migrateSchemaTwo(allocator: std.mem.Allocator, input: []const u8, limits: Limits) (Error || std.mem.Allocator.Error)!std.json.Parsed(RegistryWire) {
    var parsed = std.json.parseFromSlice(RegistryWire, allocator, input, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RegistryCorrupt,
    };
    errdefer parsed.deinit();
    // Schema 2 never had the private endpoint representation.
    for (parsed.value.servers) |server| {
        if (server.transport.sensitive_endpoint != null or server.installation != null) return error.RegistryCorrupt;
        for (oauthPrivateResources(server)) |resource| if (resource != null) return error.RegistryCorrupt;
    }
    parsed.value.schema_version = schema_version;
    validateRegistryIdentity(&parsed.value, limits) catch return error.RegistryCorrupt;
    return parsed;
}

pub fn registrySourceSchemaVersion(
    allocator: std.mem.Allocator,
    input: []const u8,
) (Error || std.mem.Allocator.Error)!u8 {
    if (input.len == 0) return error.RegistryEmpty;
    if (input.len > max_store_bytes) return error.RegistryTooLarge;
    const SchemaProbe = struct { schema_version: u8 };
    var probe = std.json.parseFromSlice(
        SchemaProbe,
        allocator,
        input,
        .{ .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RegistryCorrupt,
    };
    defer probe.deinit();
    return probe.value.schema_version;
}

fn decodeCurrent(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(RegistryWire) {
    var parsed = std.json.parseFromSlice(
        RegistryWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RegistryCorrupt,
    };
    errdefer parsed.deinit();
    validateRegistryIdentity(&parsed.value, limits) catch
        return error.RegistryCorrupt;
    return parsed;
}

fn migrateLegacyRegistry(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(RegistryWire) {
    var legacy = std.json.parseFromSlice(
        LegacyRegistryWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.RegistryCorrupt,
    };
    defer legacy.deinit();
    if (legacy.value.schema_version != 1) return error.RegistryCorrupt;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const servers = try temporary.alloc(ServerWire, legacy.value.servers.len);
    for (legacy.value.servers, 0..) |server, index| {
        const transport = try migrateLegacyTransport(temporary, server.transport);
        const has_secret_slots = transport.environment.len != 0 or
            transport.headers.len != 0;
        servers[index] = .{
            .id = server.id,
            .namespace = server.namespace,
            .display_name = server.display_name,
            .enabled = false,
            .negotiation = server.negotiation,
            .timeout_ms = server.timeout_ms,
            .transport = transport,
            .auth = .{
                .kind = if (has_secret_slots) "static" else "none",
                .oauth = null,
            },
            .connection_approval = null,
            .tools = server.tools,
        };
    }
    const migrated: RegistryWire = .{
        .schema_version = schema_version,
        .generation = legacy.value.generation,
        .oauth_operation = null,
        .servers = servers,
    };
    const buffer = try allocator.alloc(u8, max_store_bytes);
    defer allocator.free(buffer);
    const encoded = encode(buffer, migrated, limits) catch |err| switch (err) {
        error.RegistryTooLarge => return error.RegistryTooLarge,
        else => return error.RegistryCorrupt,
    };
    return decodeCurrent(allocator, encoded, limits);
}

fn migrateLegacyTransport(
    allocator: std.mem.Allocator,
    legacy: LegacyTransportWire,
) std.mem.Allocator.Error!TransportWire {
    return .{
        .kind = legacy.kind,
        .command = legacy.command,
        .arguments = legacy.arguments,
        .cwd = legacy.cwd,
        .environment = try migrateLegacySecretSlots(allocator, legacy.environment),
        .url = legacy.url,
        .headers = try migrateLegacySecretSlots(allocator, legacy.headers),
    };
}

fn migrateLegacySecretSlots(
    allocator: std.mem.Allocator,
    legacy: []const LegacyNamedValueWire,
) std.mem.Allocator.Error![]SecretSlotWire {
    const slots = try allocator.alloc(SecretSlotWire, legacy.len);
    for (legacy, slots) |source, *target| target.* = .{
        .name = source.name,
        // Legacy literal env/header values are deliberately discarded instead
        // of being copied into schema 2. The named slot remains missing and
        // requires Host-owned secure capture.
        .credential_ref = source.value.credential_ref,
    };
    return slots;
}

pub fn encode(output: []u8, registry: RegistryWire, limits: Limits) Error![]const u8 {
    if (output.len == 0) return error.RegistryEncodeFailed;
    validateRegistryIdentity(&registry, limits) catch
        return error.RegistryEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    std.json.Stringify.value(registry, .{}, &writer) catch
        return error.RegistryEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_store_bytes) return error.RegistryTooLarge;
    return encoded;
}

pub fn decodeTransaction(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!std.json.Parsed(TransactionWire) {
    if (input.len == 0 or input.len > max_transaction_bytes)
        return error.TransactionCorrupt;
    var parsed = std.json.parseFromSlice(
        TransactionWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TransactionCorrupt,
    };
    errdefer parsed.deinit();
    validateTransaction(&parsed.value, limits) catch
        return error.TransactionCorrupt;
    return parsed;
}

pub fn encodeTransaction(
    output: []u8,
    transaction: TransactionWire,
    limits: Limits,
) Error![]const u8 {
    if (output.len == 0) return error.TransactionEncodeFailed;
    validateTransaction(&transaction, limits) catch
        return error.TransactionEncodeFailed;
    var writer = std.Io.Writer.fixed(output);
    std.json.Stringify.value(transaction, .{}, &writer) catch
        return error.TransactionEncodeFailed;
    const encoded = writer.buffered();
    if (encoded.len > max_transaction_bytes) return error.TransactionEncodeFailed;
    return encoded;
}

/// Plans one complete desired-registry replacement without performing file or
/// credential effects. A null result is a semantic no-op. A mutation may keep
/// existing server-local failures byte-identical or remove them, but it cannot
/// introduce or alter an invalid server. `candidate_locators` is supplied only
/// by the Host-owned fresh-locator stage; every newly referenced trusted
/// locator must be present exactly once and no base locator may be reclassified
/// as a candidate.
pub fn planMutation(
    allocator: std.mem.Allocator,
    base: ?RegistryWire,
    target: RegistryWire,
    expected_generation: u64,
    candidate_locators: []const []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!?MutationPlan {
    return planMutationWithMode(
        allocator,
        base,
        target,
        expected_generation,
        candidate_locators,
        limits,
        .normal,
    );
}

const MutationMode = enum {
    normal,
    oauth_recovery,
    oauth_result,
};

fn planMutationWithMode(
    allocator: std.mem.Allocator,
    base: ?RegistryWire,
    target: RegistryWire,
    expected_generation: u64,
    candidate_locators: []const []const u8,
    limits: Limits,
    mode: MutationMode,
) (Error || std.mem.Allocator.Error)!?MutationPlan {
    const base_generation = if (base) |registry| registry.generation else 0;
    if (base_generation != expected_generation) return error.GenerationMismatch;
    if (base_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    if (target.generation != base_generation + 1) return error.InvalidMutation;

    if (base) |registry| {
        validateRegistryIdentity(&registry, limits) catch return error.InvalidMutation;
    }
    validateMutationTransition(base, &target, limits, mode) catch
        return error.InvalidMutation;
    if (base) |registry|
        if (registryContentEqual(registry, target) and candidate_locators.len == 0)
            return null;

    var base_references: std.ArrayList([]const u8) = .empty;
    defer base_references.deinit(allocator);
    if (base) |registry| try collectCredentialReferences(
        allocator,
        registry,
        &base_references,
        limits,
    );
    var target_references: std.ArrayList([]const u8) = .empty;
    defer target_references.deinit(allocator);
    try collectCredentialReferences(allocator, target, &target_references, limits);

    for (candidate_locators, 0..) |locator, index| {
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes) or
            containsText(base_references.items, locator) or
            !containsText(target_references.items, locator))
            return error.InvalidMutation;
        for (candidate_locators[0..index]) |previous|
            if (std.mem.eql(u8, previous, locator)) return error.InvalidMutation;
    }
    var candidate_count: usize = 0;
    for (target_references.items) |locator| {
        if (containsText(base_references.items, locator)) continue;
        if (!containsText(candidate_locators, locator)) return error.InvalidMutation;
        candidate_count += 1;
    }
    if (candidate_count != candidate_locators.len) return error.InvalidMutation;

    var retired_count: usize = 0;
    for (base_references.items) |locator| {
        if (!containsText(target_references.items, locator)) retired_count += 1;
    }
    if (candidate_count > limits.max_credential_locators or
        retired_count > limits.max_credential_locators - candidate_count)
        return error.InvalidMutation;

    var owned_target = try cloneRegistry(allocator, target, limits);
    errdefer owned_target.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const owned_candidates = try owned.alloc([]const u8, candidate_count);
    var candidate_write: usize = 0;
    for (target_references.items) |locator| {
        if (containsText(base_references.items, locator)) continue;
        owned_candidates[candidate_write] = try owned.dupe(u8, locator);
        candidate_write += 1;
    }
    const owned_retired = try owned.alloc([]const u8, retired_count);
    var retired_write: usize = 0;
    for (base_references.items) |locator| {
        if (containsText(target_references.items, locator)) continue;
        owned_retired[retired_write] = try owned.dupe(u8, locator);
        retired_write += 1;
    }
    const transaction: TransactionWire = .{
        .schema_version = transaction_schema_version,
        .base_generation = base_generation,
        .target_generation = target.generation,
        .candidate_locators = owned_candidates,
        .retired_locators = owned_retired,
    };
    validateTransaction(&transaction, limits) catch return error.InvalidMutation;
    return .{
        .arena = arena,
        .target = owned_target,
        .transaction = transaction,
    };
}

fn validateMutationTransition(
    base: ?RegistryWire,
    target: *const RegistryWire,
    limits: Limits,
    mode: MutationMode,
) !void {
    try validateRegistryIdentity(target, limits);
    if (base) |base_registry| {
        switch (mode) {
            .normal => {
                if (!optionalOauthOperationEqual(
                    base_registry.oauth_operation,
                    target.oauth_operation,
                )) return error.Invalid;
                if (base_registry.oauth_operation) |operation| {
                    const base_server = findServer(
                        base_registry.servers,
                        operation.server_id,
                    ) orelse return error.Invalid;
                    const target_server = findServer(
                        target.servers,
                        operation.server_id,
                    ) orelse return error.Invalid;
                    if (!serverWireEqual(base_server, target_server))
                        return error.Invalid;
                }
            },
            .oauth_recovery => try validateOauthRecoveryTransition(
                base_registry,
                target,
            ),
            .oauth_result => try validateOauthResultTransition(
                base_registry,
                target,
            ),
        }
    } else if (target.oauth_operation != null) return error.Invalid;
    for (target.servers) |target_server| {
        if (serverProblem(target_server, limits) == null) continue;
        const base_registry = base orelse return error.Invalid;
        const base_index = findServerIndex(
            base_registry.servers,
            target_server.id,
        ) orelse return error.Invalid;
        if (!serverWireEqual(base_registry.servers[base_index], target_server))
            return error.Invalid;
    }
}

fn validateOauthResultTransition(
    base: RegistryWire,
    target: *const RegistryWire,
) !void {
    const operation = base.oauth_operation orelse return error.Invalid;
    if (target.oauth_operation != null or base.servers.len != target.servers.len)
        return error.Invalid;
    for (base.servers) |base_server| {
        const target_server = findServer(target.servers, base_server.id) orelse
            return error.Invalid;
        if (!std.mem.eql(u8, base_server.id, operation.server_id) and
            !serverWireEqual(base_server, target_server))
            return error.Invalid;
    }
}

fn validateOauthRecoveryTransition(
    base: RegistryWire,
    target: *const RegistryWire,
) !void {
    const operation = base.oauth_operation orelse return error.Invalid;
    if (target.oauth_operation != null or base.servers.len != target.servers.len)
        return error.Invalid;
    for (base.servers) |base_server| {
        const target_server = findServer(
            target.servers,
            base_server.id,
        ) orelse return error.Invalid;
        if (!std.mem.eql(u8, base_server.id, operation.server_id)) {
            if (!serverWireEqual(base_server, target_server)) return error.Invalid;
            continue;
        }
        var expected = base_server;
        var expected_auth = base_server.auth;
        var expected_oauth = expected_auth.oauth orelse return error.Invalid;
        expected_oauth.status = "reauth_required";
        expected_oauth.grant = null;
        expected_auth.oauth = expected_oauth;
        expected.auth = expected_auth;
        if (!serverWireEqual(expected, target_server)) return error.Invalid;
    }
}

pub fn planBeginOauthOperation(
    allocator: std.mem.Allocator,
    base: RegistryWire,
    expected_generation: u64,
    operation: OauthOperationWire,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!OperationStatePlan {
    if (base.generation != expected_generation) return error.GenerationMismatch;
    validateRegistryIdentity(&base, limits) catch return error.InvalidMutation;
    if (base.oauth_operation != null) return error.InvalidMutation;
    var target = base;
    target.oauth_operation = operation;
    validateRegistryIdentity(&target, limits) catch return error.InvalidMutation;
    var owned_base = try cloneRegistry(allocator, base, limits);
    errdefer owned_base.deinit();
    return .{
        .base = owned_base,
        .target = try cloneRegistry(allocator, target, limits),
    };
}

pub fn planClearOauthOperation(
    allocator: std.mem.Allocator,
    base: RegistryWire,
    expected_generation: u64,
    expected_operation_id: []const u8,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!OperationStatePlan {
    if (base.generation != expected_generation) return error.GenerationMismatch;
    validateRegistryIdentity(&base, limits) catch return error.InvalidMutation;
    const operation = base.oauth_operation orelse return error.InvalidMutation;
    if (!std.mem.eql(u8, operation.id, expected_operation_id))
        return error.InvalidMutation;
    var target = base;
    target.oauth_operation = null;
    var owned_base = try cloneRegistry(allocator, base, limits);
    errdefer owned_base.deinit();
    return .{
        .base = owned_base,
        .target = try cloneRegistry(allocator, target, limits),
    };
}

/// Startup recovery for an OAuth request whose remote outcome cannot be
/// proven. The marker is never replayed: the bound server loses its grant and
/// moves to reauthorization while the ordinary credential journal retires any
/// token locators no longer referenced by the new desired generation.
pub fn planOauthOperationRecovery(
    allocator: std.mem.Allocator,
    base: RegistryWire,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!MutationPlan {
    const operation = base.oauth_operation orelse return error.InvalidMutation;
    if (base.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    const index = findServerIndex(base.servers, operation.server_id) orelse
        return error.InvalidMutation;
    const servers = try allocator.dupe(ServerWire, base.servers);
    defer allocator.free(servers);
    var auth = servers[index].auth;
    var oauth = auth.oauth orelse return error.InvalidMutation;
    oauth.status = "reauth_required";
    oauth.grant = null;
    oauth.pending_resource = null;
    auth.oauth = oauth;
    servers[index].auth = auth;
    return (try planMutationWithMode(
        allocator,
        base,
        .{
            .schema_version = schema_version,
            .generation = base.generation + 1,
            .oauth_operation = null,
            .servers = servers,
        },
        base.generation,
        &.{},
        limits,
        .oauth_recovery,
    )) orelse return error.InvalidMutation;
}

fn collectCredentialReferences(
    allocator: std.mem.Allocator,
    registry: RegistryWire,
    references: *std.ArrayList([]const u8),
    limits: Limits,
) std.mem.Allocator.Error!void {
    for (registry.servers) |server| {
        if (server.installation) |operation| for (operation.request_refs) |locator| {
            if (validCredentialLocator(locator, limits.max_credential_locator_bytes)) try appendUniqueText(allocator, references, locator);
        };
        for (oauthPrivateResources(server)) |resource| if (resource) |endpoint|
            for (endpoint.credential_refs) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        if (server.transport.sensitive_endpoint) |endpoint|
            for (endpoint.credential_refs) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        for (server.transport.arguments) |value|
            if (value.credential_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        for (server.transport.environment) |entry|
            if (entry.credential_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        for (server.transport.headers) |entry|
            if (entry.credential_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        if (server.auth.oauth) |oauth| {
            if (oauth.registration.client_secret_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
            if (oauth.grant) |grant| {
                if (validCredentialLocator(
                    grant.access_token_ref,
                    limits.max_credential_locator_bytes,
                )) try appendUniqueText(allocator, references, grant.access_token_ref);
                if (grant.refresh_token_ref) |locator|
                    if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                        try appendUniqueText(allocator, references, locator);
            }
        }
    }
}

fn appendUniqueText(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    candidate: []const u8,
) std.mem.Allocator.Error!void {
    if (!containsText(values.items, candidate)) try values.append(allocator, candidate);
}

fn containsText(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn findText(values: []const []const u8, candidate: []const u8) ?[]const u8 {
    for (values) |value| if (std.mem.eql(u8, value, candidate)) return value;
    return null;
}

fn registryContentEqual(left: RegistryWire, right: RegistryWire) bool {
    if (left.schema_version != right.schema_version or
        !optionalOauthOperationEqual(left.oauth_operation, right.oauth_operation) or
        left.servers.len != right.servers.len)
        return false;
    for (left.servers, right.servers) |left_server, right_server|
        if (!serverWireEqual(left_server, right_server)) return false;
    return true;
}

fn serverWireEqual(left: ServerWire, right: ServerWire) bool {
    if (!std.mem.eql(u8, left.id, right.id) or
        !std.mem.eql(u8, left.namespace, right.namespace) or
        !std.mem.eql(u8, left.display_name, right.display_name) or
        left.enabled != right.enabled or
        !std.mem.eql(u8, left.negotiation, right.negotiation) or
        left.timeout_ms != right.timeout_ms or
        !transportWireEqual(left.transport, right.transport) or
        !authWireEqual(left.auth, right.auth) or
        !installationEqual(left.installation, right.installation) or
        !optionalConnectionApprovalEqual(
            left.connection_approval,
            right.connection_approval,
        ) or
        left.tools.len != right.tools.len)
        return false;
    for (left.tools, right.tools) |left_tool, right_tool|
        if (!std.mem.eql(u8, left_tool, right_tool)) return false;
    return true;
}

fn installationEqual(left: ?InstallationWire, right: ?InstallationWire) bool {
    if (left == null or right == null) return left == null and right == null;
    const a = left.?;
    const b = right.?;
    return a.task_id == b.task_id and a.run_id == b.run_id and a.source_message_id == b.source_message_id and
        a.revision == b.revision and std.mem.eql(u8, a.source_origin, b.source_origin) and
        stringSlicesEqual(a.request_refs, b.request_refs) and a.phase == b.phase and
        a.initial_grant_pending == b.initial_grant_pending and a.initial_grant_completed == b.initial_grant_completed and
        a.cross_origin_authorized == b.cross_origin_authorized and a.active_elapsed_ms == b.active_elapsed_ms and a.stop_pending == b.stop_pending;
}

fn optionalConnectionApprovalEqual(
    left: ?ConnectionApprovalWire,
    right: ?ConnectionApprovalWire,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?.fingerprint, right.?.fingerprint);
}

fn authWireEqual(left: AuthWire, right: AuthWire) bool {
    return std.mem.eql(u8, left.kind, right.kind) and
        optionalOauthAuthorizationEqual(left.oauth, right.oauth);
}

fn optionalOauthAuthorizationEqual(
    left: ?OauthAuthorizationWire,
    right: ?OauthAuthorizationWire,
) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_oauth = left.?;
    const right_oauth = right.?;
    return std.mem.eql(u8, left_oauth.status, right_oauth.status) and
        sensitiveEndpointEqual(left_oauth.pending_resource, right_oauth.pending_resource) and
        oauthRegistrationEqual(left_oauth.registration, right_oauth.registration) and
        optionalOauthConsentEqual(left_oauth.consent, right_oauth.consent) and
        optionalOauthGrantEqual(left_oauth.grant, right_oauth.grant);
}

fn oauthRegistrationEqual(
    left: OauthRegistrationWire,
    right: OauthRegistrationWire,
) bool {
    return std.mem.eql(u8, left.kind, right.kind) and
        optionalTextEqual(left.issuer, right.issuer) and
        optionalTextEqual(left.client_id, right.client_id) and
        optionalTextEqual(
            left.token_endpoint_auth_method,
            right.token_endpoint_auth_method,
        ) and
        left.client_credential_revision == right.client_credential_revision and
        optionalTextEqual(left.client_secret_ref, right.client_secret_ref);
}

fn optionalOauthConsentEqual(left: ?OauthConsentWire, right: ?OauthConsentWire) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_consent = left.?;
    const right_consent = right.?;
    return left_consent.epoch == right_consent.epoch and
        left_consent.client_credential_revision == right_consent.client_credential_revision and
        std.mem.eql(u8, left_consent.fingerprint, right_consent.fingerprint) and
        std.mem.eql(u8, left_consent.resource, right_consent.resource) and
        sensitiveEndpointEqual(left_consent.private_resource, right_consent.private_resource) and
        std.mem.eql(u8, left_consent.issuer, right_consent.issuer) and
        stringSlicesEqual(left_consent.scopes, right_consent.scopes) and
        std.mem.eql(u8, left_consent.redirect_uri, right_consent.redirect_uri);
}

fn optionalOauthGrantEqual(left: ?OauthGrantWire, right: ?OauthGrantWire) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_grant = left.?;
    const right_grant = right.?;
    return left_grant.consent_epoch == right_grant.consent_epoch and
        left_grant.token_revision == right_grant.token_revision and
        std.mem.eql(u8, left_grant.access_token_ref, right_grant.access_token_ref) and
        optionalTextEqual(left_grant.refresh_token_ref, right_grant.refresh_token_ref) and
        left_grant.expires_at_unix_ms == right_grant.expires_at_unix_ms;
}

fn optionalOauthOperationEqual(
    left: ?OauthOperationWire,
    right: ?OauthOperationWire,
) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_operation = left.?;
    const right_operation = right.?;
    return std.mem.eql(u8, left_operation.id, right_operation.id) and
        std.mem.eql(u8, left_operation.kind, right_operation.kind) and
        std.mem.eql(u8, left_operation.server_id, right_operation.server_id) and
        std.mem.eql(
            u8,
            left_operation.connection_fingerprint,
            right_operation.connection_fingerprint,
        ) and
        std.mem.eql(
            u8,
            left_operation.consent_fingerprint,
            right_operation.consent_fingerprint,
        ) and
        left_operation.consent_epoch == right_operation.consent_epoch and
        left_operation.token_revision == right_operation.token_revision and
        optionalOauthConsentDraftEqual(
            left_operation.consent_draft,
            right_operation.consent_draft,
        );
}

fn optionalOauthConsentDraftEqual(
    left: ?OauthConsentDraftWire,
    right: ?OauthConsentDraftWire,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?.resource, right.?.resource) and
        sensitiveEndpointEqual(left.?.private_resource, right.?.private_resource) and
        std.mem.eql(u8, left.?.issuer, right.?.issuer) and
        stringSlicesEqual(left.?.scopes, right.?.scopes) and
        std.mem.eql(u8, left.?.redirect_uri, right.?.redirect_uri);
}

fn transportWireEqual(left: TransportWire, right: TransportWire) bool {
    if (!std.mem.eql(u8, left.kind, right.kind) or
        !optionalTextEqual(left.command, right.command) or
        !optionalTextEqual(left.cwd, right.cwd) or
        !optionalTextEqual(left.url, right.url) or
        !sensitiveEndpointEqual(left.sensitive_endpoint, right.sensitive_endpoint) or
        left.arguments.len != right.arguments.len or
        left.environment.len != right.environment.len or
        left.headers.len != right.headers.len)
        return false;
    for (left.arguments, right.arguments) |left_value, right_value|
        if (!valueSourceEqual(left_value, right_value)) return false;
    for (left.environment, right.environment) |left_entry, right_entry|
        if (!secretSlotEqual(left_entry, right_entry)) return false;
    for (left.headers, right.headers) |left_entry, right_entry|
        if (!secretSlotEqual(left_entry, right_entry)) return false;
    return true;
}

fn sensitiveEndpointEqual(left: ?SensitiveEndpointWire, right: ?SensitiveEndpointWire) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?.origin, right.?.origin) and
        std.mem.eql(u8, left.?.identity, right.?.identity) and
        stringSlicesEqual(left.?.credential_refs, right.?.credential_refs) and
        std.mem.eql(u32, left.?.secret_parts, right.?.secret_parts);
}

fn secretSlotEqual(left: SecretSlotWire, right: SecretSlotWire) bool {
    return std.mem.eql(u8, left.name, right.name) and
        optionalTextEqual(left.credential_ref, right.credential_ref);
}

fn valueSourceEqual(left: ValueSourceWire, right: ValueSourceWire) bool {
    return optionalTextEqual(left.literal, right.literal) and
        optionalTextEqual(left.credential_ref, right.credential_ref);
}

fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// Prove the entire association before deleting anything. Generation selects
/// the phase; current references must also match both locator sets.
fn validateTransactionRegistry(transaction: TransactionWire, registry: ?RegistryWire) Error!void {
    const generation = if (registry) |value| value.generation else 0;
    const at_base = generation == transaction.base_generation;
    if (!at_base and generation != transaction.target_generation)
        return error.TransactionGenerationMismatch;
    for (transaction.candidate_locators) |locator| {
        var referenced = false;
        if (registry) |value| for (value.servers) |server| {
            referenced = referenced or serverReferencesCredential(server, locator);
        };
        if (referenced == at_base) return error.TransactionRegistryMismatch;
    }
    for (transaction.retired_locators) |locator| {
        var referenced = false;
        if (registry) |value| for (value.servers) |server| {
            referenced = referenced or serverReferencesCredential(server, locator);
        };
        if (referenced != at_base) return error.TransactionRegistryMismatch;
    }
}

fn recoverCredentialTransaction(
    transaction: TransactionWire,
    current_registry_generation: u64,
    cleanup: CredentialCleanup,
) Error!void {
    const locators = if (current_registry_generation == transaction.base_generation)
        transaction.candidate_locators
    else if (current_registry_generation == transaction.target_generation)
        transaction.retired_locators
    else
        return error.TransactionGenerationMismatch;
    for (locators) |locator|
        if (!cleanup.delete(locator)) return error.CredentialCleanupFailed;
}

fn validateTransaction(transaction: *const TransactionWire, limits: Limits) !void {
    if (transaction.schema_version != transaction_schema_version or
        transaction.base_generation == std.math.maxInt(u64) or
        transaction.target_generation != transaction.base_generation + 1 or
        limits.max_credential_locators == 0 or
        transaction.candidate_locators.len > limits.max_credential_locators or
        transaction.retired_locators.len >
            limits.max_credential_locators - transaction.candidate_locators.len)
        return error.Invalid;
    for (transaction.candidate_locators, 0..) |locator, index| {
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes))
            return error.Invalid;
        for (transaction.candidate_locators[0..index]) |previous|
            if (std.mem.eql(u8, previous, locator)) return error.Invalid;
    }
    for (transaction.retired_locators, 0..) |locator, index| {
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes))
            return error.Invalid;
        for (transaction.retired_locators[0..index]) |previous|
            if (std.mem.eql(u8, previous, locator)) return error.Invalid;
        for (transaction.candidate_locators) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return error.Invalid;
    }
}

/// Server-local semantic failures remain classifiable product state instead
/// of making the complete registry unreadable.
pub fn serverProblem(server: ServerWire, limits: Limits) ?ServerProblem {
    if (!validRuntimeNamespace(server.namespace, limits.max_namespace_bytes))
        return .invalid_namespace;
    if (server.display_name.len > limits.max_display_name_bytes or
        !publishableProductText(server.display_name))
        return .invalid_display_name;
    if (!oneOf(server.negotiation, &.{ "automatic", "modern_only", "compat_only" }))
        return .invalid_negotiation;
    if (server.timeout_ms == 0) return .invalid_timeout;
    for (server.tools, 0..) |tool, index| {
        if (tool.len > limits.max_tool_name_bytes or
            !publishableProductText(tool))
            return .invalid_allowlist;
        for (server.tools[0..index]) |previous|
            if (std.mem.eql(u8, previous, tool)) return .invalid_allowlist;
    }
    if (server.installation) |operation| {
        if (operation.task_id == 0 or operation.run_id == 0 or operation.source_message_id == 0 or operation.revision == 0 or operation.revision == std.math.maxInt(u64) or
            operation.active_elapsed_ms > installation_active_budget_ms or operation.request_refs.len == 0 or operation.request_refs.len > limits.max_credential_locators or
            (operation.initial_grant_pending and operation.initial_grant_completed) or
            (operation.stop_pending and operation.phase != .cancelled) or
            (!operation.phase.active() and operation.initial_grant_pending) or
            (operation.phase == .ready and !operation.initial_grant_completed)) return .invalid_transport;
        const origin = endpointOrigin(operation.source_origin, limits.max_url_bytes) orelse return .invalid_transport;
        if (!std.mem.eql(u8, origin, operation.source_origin)) return .invalid_transport;
        for (operation.request_refs, 0..) |locator, i| {
            if (!validCredentialLocator(locator, limits.max_credential_locator_bytes)) return .invalid_transport;
            if (containsText(operation.request_refs[0..i], locator)) return .invalid_transport;
        }
    }
    if (validateTransport(server.transport, limits)) |problem| return problem;
    if (validateAuth(server, limits)) |problem| return problem;
    if (server.connection_approval) |approval| {
        if (!validFingerprint(approval.fingerprint) or
            !std.mem.eql(u8, approval.fingerprint, &connectionFingerprint(server)))
            return .invalid_connection_approval;
    }
    return null;
}

fn validateRegistryIdentity(registry: *const RegistryWire, limits: Limits) !void {
    if (registry.schema_version != schema_version or registry.generation == 0 or
        registry.servers.len > limits.max_servers or limits.max_servers == 0 or
        limits.max_tools_per_server == 0 or limits.max_namespace_bytes == 0 or
        limits.max_runtime_secrets_per_server == 0 or
        limits.max_runtime_secret_bytes_per_server == 0)
        return error.Invalid;
    if (registry.oauth_operation) |operation|
        try validateOauthOperation(operation, registry.servers, limits);
    for (registry.servers, 0..) |server, index| {
        if (!validIdentifier(server.id, limits.max_identity_bytes) or
            !validStoredNamespace(server.namespace, limits.max_namespace_bytes) or
            server.tools.len > limits.max_tools_per_server)
            return error.Invalid;
        for (registry.servers[0..index]) |previous|
            if (std.mem.eql(u8, previous.id, server.id) or
                std.mem.eql(u8, previous.namespace, server.namespace))
                return error.Invalid;
    }
    var credential_locators: usize = 0;
    for (registry.servers) |server| {
        credential_locators = std.math.add(
            usize,
            credential_locators,
            credentialReferenceCount(server),
        ) catch return error.Invalid;
        if (credential_locators > limits.max_credential_locators)
            return error.Invalid;
    }
}

fn validateAuth(server: ServerWire, limits: Limits) ?ServerProblem {
    const transport_secret_slots = server.transport.environment.len +
        server.transport.headers.len;
    if (std.mem.eql(u8, server.auth.kind, "none")) {
        if (server.auth.oauth != null or transport_secret_slots != 0)
            return .invalid_authentication;
        return null;
    }
    if (std.mem.eql(u8, server.auth.kind, "static")) {
        if (server.auth.oauth != null or transport_secret_slots == 0)
            return .invalid_authentication;
        return null;
    }
    if (!std.mem.eql(u8, server.auth.kind, "oauth") or
        !std.mem.eql(u8, server.transport.kind, "streamable_http") or
        server.transport.headers.len != 0)
        return .invalid_authentication;
    const oauth = server.auth.oauth orelse return .invalid_authentication;
    for (oauthPrivateResources(server)) |resource| if (resource) |endpoint|
        if (!validSensitiveEndpoint(endpoint, limits)) return .invalid_authentication;
    if (!validateOauthRegistration(oauth.registration, limits))
        return .invalid_authentication;
    if (oauth.consent != null and server.connection_approval == null)
        return .invalid_authentication;
    const consent_valid = if (oauth.consent) |consent|
        validateOauthConsent(server, consent, limits)
    else
        true;
    if (!consent_valid) return .invalid_authentication;
    if (oauth.grant) |grant| {
        const consent = oauth.consent orelse return .invalid_authentication;
        if (grant.consent_epoch != consent.epoch or grant.token_revision == 0 or
            !validCredentialLocator(
                grant.access_token_ref,
                limits.max_credential_locator_bytes,
            ) or
            (grant.refresh_token_ref != null and !validCredentialLocator(
                grant.refresh_token_ref.?,
                limits.max_credential_locator_bytes,
            )) or
            (grant.refresh_token_ref != null and std.mem.eql(
                u8,
                grant.access_token_ref,
                grant.refresh_token_ref.?,
            )) or
            (grant.expires_at_unix_ms != null and grant.expires_at_unix_ms.? == 0))
            return .invalid_authentication;
    }
    if (std.mem.eql(u8, oauth.status, "client_registration_required")) {
        if (!std.mem.eql(u8, oauth.registration.kind, "dynamic_registration") or
            oauth.registration.issuer != null or
            oauth.registration.client_id != null or
            oauth.registration.token_endpoint_auth_method != null or
            oauth.registration.client_credential_revision != 0 or
            oauth.registration.client_secret_ref != null or
            oauth.consent != null or oauth.grant != null)
            return .invalid_authentication;
    } else if (std.mem.eql(u8, oauth.status, "consent_required")) {
        if (oauth.registration.client_id == null or
            oauth.consent != null or oauth.grant != null)
            return .invalid_authentication;
    } else if (std.mem.eql(u8, oauth.status, "awaiting_tokens")) {
        if (oauth.consent == null or oauth.grant != null)
            return .invalid_authentication;
    } else if (std.mem.eql(u8, oauth.status, "ready")) {
        if (oauth.consent == null or oauth.grant == null)
            return .invalid_authentication;
    } else if (std.mem.eql(u8, oauth.status, "reauth_required")) {
        if (oauth.grant != null) return .invalid_authentication;
    } else return .invalid_authentication;
    return null;
}

fn validateOauthRegistration(
    registration: OauthRegistrationWire,
    limits: Limits,
) bool {
    if (registration.issuer) |issuer|
        if (!validHttpsUri(issuer, limits.max_oauth_uri_bytes)) return false;
    if (registration.client_id) |client_id|
        if (!validText(client_id, limits.max_oauth_client_id_bytes, false)) return false;
    if (registration.token_endpoint_auth_method) |method|
        if (!oneOf(method, &.{ "none", "client_secret_basic", "client_secret_post" }))
            return false;
    if (registration.client_secret_ref) |locator|
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes)) return false;
    const secret_required = if (registration.token_endpoint_auth_method) |method|
        !std.mem.eql(u8, method, "none")
    else
        false;
    if ((!secret_required and registration.client_secret_ref != null) or
        (registration.client_credential_revision == 0 and
            registration.client_secret_ref != null))
        return false;
    if (std.mem.eql(u8, registration.kind, "pre_registered"))
        return registration.client_id != null and
            registration.token_endpoint_auth_method != null and
            registration.client_credential_revision != 0;
    if (std.mem.eql(u8, registration.kind, "dynamic_registration"))
        return (registration.client_id == null and
            registration.issuer == null and
            registration.token_endpoint_auth_method == null and
            registration.client_credential_revision == 0 and
            registration.client_secret_ref == null) or
            (registration.client_id != null and
                registration.issuer != null and
                registration.token_endpoint_auth_method != null and
                registration.client_credential_revision != 0);
    return false;
}

fn validateOauthConsent(
    server: ServerWire,
    consent: OauthConsentWire,
    limits: Limits,
) bool {
    const oauth = server.auth.oauth orelse return false;
    if (consent.private_resource) |resource|
        if (!std.mem.eql(u8, consent.resource, resource.origin)) return false;
    if (oauth.registration.client_id == null or
        oauth.registration.issuer == null or
        !std.mem.eql(u8, oauth.registration.issuer.?, consent.issuer) or
        oauth.registration.client_credential_revision != consent.client_credential_revision or
        (oauth.registration.token_endpoint_auth_method != null and
            !std.mem.eql(u8, oauth.registration.token_endpoint_auth_method.?, "none") and
            oauth.registration.client_secret_ref == null))
        return false;
    if (consent.epoch == 0 or consent.client_credential_revision == 0 or
        !validFingerprint(consent.fingerprint) or
        !validEndpoint(consent.resource, limits.max_oauth_uri_bytes) or
        !validHttpsUri(consent.issuer, limits.max_oauth_uri_bytes) or
        !validEndpoint(consent.redirect_uri, limits.max_oauth_uri_bytes) or
        consent.scopes.len > limits.max_oauth_scopes)
        return false;
    for (consent.scopes, 0..) |scope, index| {
        if (!validOauthScope(scope, limits.max_oauth_scope_bytes)) return false;
        if (index != 0 and std.mem.order(u8, consent.scopes[index - 1], scope) != .lt)
            return false;
    }
    const fingerprint = oauthConsentFingerprint(server, consent) orelse return false;
    return std.mem.eql(u8, consent.fingerprint, &fingerprint);
}

fn validateOauthConsentDraft(
    draft: OauthConsentDraftWire,
    limits: Limits,
) bool {
    if (draft.private_resource) |resource|
        if (!validSensitiveEndpoint(resource, limits) or !std.mem.eql(u8, draft.resource, resource.origin)) return false;
    if (!validEndpoint(draft.resource, limits.max_oauth_uri_bytes) or
        !validHttpsUri(draft.issuer, limits.max_oauth_uri_bytes) or
        !validEndpoint(draft.redirect_uri, limits.max_oauth_uri_bytes) or
        draft.scopes.len > limits.max_oauth_scopes)
        return false;
    for (draft.scopes, 0..) |scope, index| {
        if (!validOauthScope(scope, limits.max_oauth_scope_bytes)) return false;
        if (index != 0 and std.mem.order(u8, draft.scopes[index - 1], scope) != .lt)
            return false;
    }
    return true;
}

fn validateOauthOperation(
    operation: OauthOperationWire,
    servers: []const ServerWire,
    limits: Limits,
) !void {
    if (!validIdentifier(operation.id, limits.max_identity_bytes) or
        !validIdentifier(operation.server_id, limits.max_identity_bytes) or
        !oneOf(
            operation.kind,
            &.{ "dynamic_registration", "code_exchange", "refresh" },
        ) or
        !validFingerprint(operation.connection_fingerprint) or
        !validFingerprint(operation.consent_fingerprint) or
        operation.consent_epoch == 0)
        return error.Invalid;
    const server = findServer(servers, operation.server_id) orelse return error.Invalid;
    const approval = server.connection_approval orelse return error.Invalid;
    const current_connection = connectionFingerprint(server);
    if (!std.mem.eql(
        u8,
        operation.connection_fingerprint,
        approval.fingerprint,
    ) or !std.mem.eql(
        u8,
        approval.fingerprint,
        &current_connection,
    )) return error.Invalid;
    const oauth = server.auth.oauth orelse return error.Invalid;
    if (serverProblem(server, limits) != null) return error.Invalid;
    if (std.mem.eql(u8, operation.kind, "dynamic_registration")) {
        if (!std.mem.eql(u8, oauth.registration.kind, "dynamic_registration") or
            oauth.registration.client_id != null or
            oauth.registration.client_credential_revision != 0)
            return error.Invalid;
        const draft = operation.consent_draft orelse return error.Invalid;
        if (!sensitiveEndpointEqual(draft.private_resource, oauth.pending_resource)) return error.Invalid;
        if (!validateOauthConsentDraft(draft, limits)) return error.Invalid;
        const draft_fingerprint = oauthConsentDraftFingerprint(
            server,
            operation.consent_epoch,
            draft,
        ) orelse return error.Invalid;
        if (!std.mem.eql(u8, operation.consent_fingerprint, &draft_fingerprint))
            return error.Invalid;
    } else if (std.mem.eql(u8, operation.kind, "code_exchange")) {
        if (!std.mem.eql(u8, oauth.status, "awaiting_tokens"))
            return error.Invalid;
    } else if (!std.mem.eql(u8, oauth.status, "ready")) return error.Invalid;
    if (std.mem.eql(u8, operation.kind, "refresh")) {
        if (operation.token_revision == null or operation.token_revision.? == 0)
            return error.Invalid;
    } else if (operation.token_revision != null) return error.Invalid;
    if (!std.mem.eql(u8, operation.kind, "dynamic_registration")) {
        if (operation.consent_draft != null) return error.Invalid;
        const consent = oauth.consent orelse return error.Invalid;
        if (consent.epoch != operation.consent_epoch or
            !std.mem.eql(
                u8,
                consent.fingerprint,
                operation.consent_fingerprint,
            )) return error.Invalid;
        if (std.mem.eql(u8, operation.kind, "refresh")) {
            const grant = oauth.grant orelse return error.Invalid;
            if (grant.token_revision != operation.token_revision.?)
                return error.Invalid;
        }
    }
}

fn credentialReferenceCount(server: ServerWire) usize {
    var count = transportCredentialReferenceCount(server.transport);
    if (server.installation) |operation| count += operation.request_refs.len;
    for (oauthPrivateResources(server)) |resource| if (resource) |endpoint| {
        count += endpoint.credential_refs.len;
    };
    if (server.auth.oauth) |oauth| {
        if (oauth.registration.client_secret_ref != null) count += 1;
        if (oauth.grant) |grant| {
            count += 1;
            if (grant.refresh_token_ref != null) count += 1;
        }
    }
    return count;
}

fn transportCredentialReferenceCount(transport: TransportWire) usize {
    var count: usize = 0;
    if (transport.sensitive_endpoint) |endpoint| count += endpoint.credential_refs.len;
    for (transport.arguments) |value| if (value.credential_ref != null) {
        count += 1;
    };
    for (transport.environment) |entry| if (entry.credential_ref != null) {
        count += 1;
    };
    for (transport.headers) |entry| if (entry.credential_ref != null) {
        count += 1;
    };
    return count;
}

fn validateTransport(transport: TransportWire, limits: Limits) ?ServerProblem {
    if (std.mem.eql(u8, transport.kind, "stdio")) {
        const command = transport.command orelse return .invalid_transport;
        if (transport.url != null or transport.sensitive_endpoint != null or transport.headers.len != 0 or
            !validText(command, limits.max_command_bytes, false) or
            std.mem.indexOfScalar(u8, command, 0) != null or
            transport.arguments.len > limits.max_argument_count or
            transport.environment.len > limits.max_environment_count)
            return .invalid_transport;
        if (transport.cwd) |cwd|
            if (!validText(cwd, limits.max_command_bytes, false) or
                !std.fs.path.isAbsolute(cwd) or
                std.mem.indexOfScalar(u8, cwd, 0) != null)
                return .invalid_transport;
        var argument_bytes: usize = 0;
        for (transport.arguments) |argument| {
            if (argument.credential_ref != null) return .invalid_credential_locator;
            const value = validateValueSource(argument, limits) orelse
                return .invalid_credential_locator;
            argument_bytes = std.math.add(usize, argument_bytes, value.len) catch
                return .invalid_transport;
            if (argument_bytes > limits.max_argument_bytes)
                return .invalid_transport;
        }
        for (transport.environment, 0..) |entry, index| {
            if (!validEnvironmentName(entry.name)) return .invalid_transport;
            if (entry.credential_ref) |locator|
                if (!validCredentialLocator(
                    locator,
                    limits.max_credential_locator_bytes,
                )) return .invalid_credential_locator;
            for (transport.environment[0..index]) |previous|
                if (std.ascii.eqlIgnoreCase(previous.name, entry.name))
                    return .invalid_transport;
        }
        return null;
    }
    if (!std.mem.eql(u8, transport.kind, "streamable_http"))
        return .invalid_transport;
    if (transport.command != null or transport.arguments.len != 0 or
        transport.cwd != null or transport.environment.len != 0 or
        transport.headers.len > limits.max_header_count)
        return .invalid_transport;
    if (transport.sensitive_endpoint) |endpoint| {
        if (transport.url != null or !validSensitiveEndpoint(endpoint, limits)) return .invalid_transport;
    } else {
        const url = transport.url orelse return .invalid_transport;
        if (!validEndpoint(url, limits.max_url_bytes)) return .invalid_transport;
    }
    for (transport.headers, 0..) |entry, index| {
        if (!validHeaderName(entry.name) or reservedHttpHeader(entry.name))
            return .invalid_transport;
        if (entry.credential_ref) |locator|
            if (!validCredentialLocator(
                locator,
                limits.max_credential_locator_bytes,
            )) return .invalid_credential_locator;
        for (transport.headers[0..index]) |previous|
            if (std.ascii.eqlIgnoreCase(previous.name, entry.name))
                return .invalid_transport;
    }
    return null;
}

fn validSensitiveEndpoint(endpoint: SensitiveEndpointWire, limits: Limits) bool {
    if (!validText(endpoint.identity, limits.max_identity_bytes, false) or endpoint.credential_refs.len == 0 or endpoint.credential_refs.len > limits.max_credential_locators) return false;
    for (endpoint.secret_parts, 0..) |part, i| {
        if (part >= endpoint.credential_refs.len or (i > 0 and part <= endpoint.secret_parts[i - 1])) return false;
    }
    const origin = endpointOrigin(endpoint.origin, limits.max_url_bytes) orelse return false;
    if (!std.mem.eql(u8, origin, endpoint.origin)) return false;
    for (endpoint.credential_refs) |locator|
        if (!validCredentialLocator(locator, limits.max_credential_locator_bytes)) return false;
    return true;
}

fn oauthPrivateResources(server: ServerWire) [2]?SensitiveEndpointWire {
    const oauth = server.auth.oauth orelse return .{ null, null };
    return .{ oauth.pending_resource, if (oauth.consent) |consent| consent.private_resource else null };
}

fn consentResourceInput(server: ServerWire, input: OauthConsentInput) ?struct { value: []const u8, private: ?SensitiveEndpointWire } {
    if (input.private_resource_identity) |identity| {
        const oauth = server.auth.oauth orelse return null;
        const resource = oauth.pending_resource orelse return null;
        if (!std.mem.eql(u8, identity, resource.identity)) return null;
        return .{ .value = resource.origin, .private = resource };
    }
    if (server.transport.sensitive_endpoint != null) return null;
    return .{ .value = input.resource, .private = null };
}

pub fn consentResourceMatches(consent: OauthConsentWire, resource: []const u8, identity: ?[]const u8) bool {
    if (consent.private_resource) |private|
        return if (identity) |expected| std.mem.eql(u8, expected, private.identity) else false;
    return identity == null and std.mem.eql(u8, consent.resource, resource);
}

fn reservedHttpHeader(name: []const u8) bool {
    inline for (.{
        "Accept-Encoding",
        "Content-Length",
        "Host",
    }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    return mcp_http_protocol.isReservedRequestHeader(name);
}

fn validateValueSource(value: ValueSourceWire, limits: Limits) ?[]const u8 {
    if ((value.literal == null) == (value.credential_ref == null)) return null;
    if (value.credential_ref) |locator|
        return if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
            locator
        else
            null;
    const literal = value.literal.?;
    return if (validText(literal, limits.max_argument_bytes, true) and
        std.mem.indexOfScalar(u8, literal, 0) == null)
        literal
    else
        null;
}

fn validEndpoint(value: []const u8, max_bytes: usize) bool {
    if (!validText(value, max_bytes, false)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\')
        return false;
    if (std.mem.indexOfScalar(u8, value, '#') != null)
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or
        uri.fragment != null or uri.host == null)
        return false;
    const scheme_suffix = value[uri.scheme.len..];
    if (!std.mem.startsWith(u8, scheme_suffix, "://")) return false;
    const authority_and_path = scheme_suffix[3..];
    const authority_end = std.mem.indexOfAny(u8, authority_and_path, "/?") orelse
        authority_and_path.len;
    const authority = parseEndpointAuthority(authority_and_path[0..authority_end]) orelse
        return false;
    const parsed_host = switch (uri.host.?) {
        .raw, .percent_encoded => |bytes| bytes,
    };
    if (!std.mem.eql(u8, parsed_host, authority.host) or uri.port != authority.port)
        return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    return std.ascii.eqlIgnoreCase(authority.host, "localhost") or
        std.mem.eql(u8, authority.host, "127.0.0.1") or
        std.mem.eql(u8, authority.host, "[::1]");
}

fn validFingerprint(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f'))
        return false;
    return true;
}

fn validOauthScope(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte| if (byte != 0x21 and
        (byte < 0x23 or byte > 0x5b) and
        (byte < 0x5d or byte > 0x7e)) return false;
    return true;
}

pub fn validOauthScopeSet(
    scopes: []const []const u8,
    limits: Limits,
) bool {
    if (scopes.len > limits.max_oauth_scopes) return false;
    for (scopes, 0..) |scope, index| {
        if (!validOauthScope(scope, limits.max_oauth_scope_bytes)) return false;
        if (index != 0 and std.mem.order(u8, scopes[index - 1], scope) != .lt)
            return false;
    }
    return true;
}

fn validHttpsUri(value: []const u8, max_bytes: usize) bool {
    if (!validText(value, max_bytes, false)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\')
        return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") and
        uri.host != null and uri.user == null and uri.password == null and
        uri.query == null and uri.fragment == null;
}

const EndpointAuthority = struct {
    host: []const u8,
    port: ?u16,
};

fn parseEndpointAuthority(value: []const u8) ?EndpointAuthority {
    if (value.len == 0) return null;
    for (value) |byte|
        if (byte >= 0x80 or byte == '%' or byte == '@') return null;

    var host = value;
    var port: ?u16 = null;
    if (value[0] == '[') {
        const closing_bracket = std.mem.indexOfScalar(u8, value, ']') orelse return null;
        host = value[0 .. closing_bracket + 1];
        const suffix = value[closing_bracket + 1 ..];
        if (suffix.len != 0) port = parseEndpointPort(suffix) orelse return null;
    } else if (std.mem.indexOfScalar(u8, value, ':')) |separator| {
        if (std.mem.indexOfScalar(u8, value[separator + 1 ..], ':') != null)
            return null;
        host = value[0..separator];
        port = parseEndpointPort(value[separator..]) orelse return null;
    }

    if (!validEndpointHost(host)) return null;
    return .{ .host = host, .port = port };
}

fn parseEndpointPort(value: []const u8) ?u16 {
    if (value.len < 2 or value[0] != ':') return null;
    for (value[1..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    const port = std.fmt.parseInt(u16, value[1..], 10) catch return null;
    return if (port == 0) null else port;
}

fn validEndpointHost(host: []const u8) bool {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch
            return false;
        return true;
    }
    std.Io.net.HostName.validate(host) catch return false;
    return true;
}

/// Product text accepted into the canonical MCP registry and safe projection.
/// Field-specific byte limits are checked by the caller; this predicate owns
/// the shared UTF-8, control-character, and non-blank semantics.
pub fn publishableProductText(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    var visible = false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
        if (byte != ' ') visible = true;
    }
    return visible;
}

fn validIdentifier(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return false;
    return true;
}

fn validStoredNamespace(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return false;
    return true;
}

fn validRuntimeNamespace(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes or
        !std.ascii.isAlphabetic(value[0]))
        return false;
    for (value[1..]) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn validCredentialLocator(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and
            byte != '.' and byte != '/')
            return false;
    return true;
}

fn validEnvironmentName(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or
        (!std.ascii.isAlphabetic(value[0]) and value[0] != '_'))
        return false;
    for (value[1..]) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn validHeaderName(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and
            std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
            return false;
    return true;
}

fn validText(value: []const u8, max_bytes: usize, allow_empty: bool) bool {
    return (allow_empty or value.len != 0) and value.len <= max_bytes and
        std.unicode.utf8ValidateSlice(value);
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

pub const RecoveryDiagnostic = enum {
    none,
    quarantined_credentials_retained,
    read_failed,
    unrecognized_format,
    quarantine_failed,
    quarantine_outcome_unknown,
    journal_recovery_failed,
};

pub const QuarantineScope = enum {
    registry,
    journal,

    fn pendingName(scope: QuarantineScope) []const u8 {
        return switch (scope) {
            .registry => "pending-registry",
            .journal => "pending-journal",
        };
    }
};

const quarantine_directory = ".quarantine";
const QuarantineIntent = struct {
    journal_present: bool,
    registry_hash: [32]u8,
    journal_hash: [32]u8,
};

/// Product chooses the move; Application owns the atomic, non-replacing effect.
/// Directory handles are borrowed only for the synchronous call.
pub const QuarantineMove = struct {
    pub const Request = union(enum) {
        registry,
        journal,
        finish: struct { scope: QuarantineScope, nonce: [8]u8 },

        pub fn sourceName(self: Request) []const u8 {
            return switch (self) {
                .registry => file_name,
                .journal => transaction_file_name,
                .finish => |value| value.scope.pendingName(),
            };
        }

        pub fn targetName(self: Request, storage: *[25]u8) []const u8 {
            return switch (self) {
                .registry => file_name,
                .journal => transaction_file_name,
                .finish => |value| std.fmt.bufPrint(storage, "finished-{s}", .{std.fmt.bytesToHex(value.nonce, .lower)}) catch unreachable,
            };
        }
    };

    move_fn: ?*const fn (std.Io, std.Io.Dir, std.Io.Dir, Request) FileStoreError!void = null,

    pub fn move(self: QuarantineMove, io: std.Io, source: std.Io.Dir, target: std.Io.Dir, request: Request) FileStoreError!void {
        const effect = self.move_fn orelse return error.WriteFailed;
        try effect(io, source, target, request);
    }
};

pub const testing = if (builtin.is_test) struct {
    pub const quarantine_directory_name = quarantine_directory;
    pub const limits = test_limits;
} else struct {};

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,
    quarantine_move: QuarantineMove = .{},

    pub fn init(io: std.Io, absolute_directory: []const u8) FileStoreError!FileStore {
        if (!std.fs.path.isAbsolute(absolute_directory))
            return error.DirectoryUnavailable;
        const dir = std.Io.Dir.cwd().createDirPathOpen(io, absolute_directory, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = directoryPermissions(),
        }) catch return error.DirectoryUnavailable;
        errdefer dir.close(io);
        const lock_file = openOrCreateLock(io, dir) catch |err| switch (err) {
            error.WouldBlock => return error.WriterAlreadyActive,
            else => return error.DirectoryUnavailable,
        };
        return .{ .io = io, .dir = dir, .lock_file = lock_file };
    }

    pub fn deinit(self: *FileStore) void {
        self.lock_file.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn loadAlloc(self: *FileStore, allocator: std.mem.Allocator) FileStoreError!?[]u8 {
        return self.loadNamedAlloc(allocator, file_name, max_store_bytes);
    }

    pub fn loadTransactionAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
    ) FileStoreError!?[]u8 {
        return self.loadNamedAlloc(allocator, transaction_file_name, max_transaction_bytes);
    }

    fn loadNamedAlloc(
        self: *FileStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        max_bytes: usize,
    ) FileStoreError!?[]u8 {
        var file = self.dir.openFile(self.io, name, .{
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(self.io);
        const metadata = file.stat(self.io) catch return error.ReadFailed;
        if (metadata.kind != .file) return error.ReadFailed;
        const length = metadata.size;
        if (length > max_bytes) return error.ReadFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        const read = file.readPositionalAll(self.io, bytes, 0) catch
            return error.ReadFailed;
        if (read != length) return error.ReadFailed;
        return bytes;
    }

    pub fn commit(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_store_bytes) return error.WriteFailed;
        return self.commitNamed(bytes, file_name, ".registry");
    }

    pub fn commitTransaction(self: *FileStore, bytes: []const u8) FileStoreError!void {
        if (bytes.len == 0 or bytes.len > max_transaction_bytes) return error.WriteFailed;
        return self.commitNamed(bytes, transaction_file_name, ".transaction");
    }

    pub fn mutationPersistence(self: *FileStore) MutationPersistence {
        return .{
            .context = self,
            .available = true,
            .commit_journal_fn = commitJournalEffect,
            .commit_registry_fn = commitRegistryEffect,
            .clear_journal_fn = clearJournalEffect,
        };
    }

    pub fn clearTransaction(self: *FileStore) FileStoreError!void {
        self.dir.deleteFile(self.io, transaction_file_name) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.WriteFailed,
        };
        // Replaying credential cleanup is idempotent. Windows cannot fsync the
        // containing directory, so a crash may leave the journal to be replayed
        // once more instead of making the cleanup outcome ambiguous.
        if (!self.syncCommit(null)) return error.PersistenceOutcomeUnknown;
    }

    pub fn hasQuarantine(self: *FileStore) FileStoreError!bool {
        const dir = (try self.openQuarantine()) orelse return false;
        dir.close(self.io);
        return true;
    }

    fn openQuarantine(self: *FileStore) FileStoreError!?std.Io.Dir {
        return self.dir.openDir(self.io, quarantine_directory, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => error.ReadFailed,
        };
    }

    /// Only pending intent is active recovery input. Finished records are
    /// diagnostic evidence and never grant credential use or deletion.
    pub fn resumeQuarantine(self: *FileStore, allocator: std.mem.Allocator, empty_registry: []const u8) FileStoreError!bool {
        const root = (try self.openQuarantine()) orelse return false;
        defer root.close(self.io);
        var selected: ?QuarantineScope = null;
        inline for (std.meta.tags(QuarantineScope)) |scope| {
            const pending = root.openDir(self.io, scope.pendingName(), .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return error.ReadFailed,
            };
            if (pending) |dir| {
                defer dir.close(self.io);
                // Creating the directory alone is not durable authorization to
                // move files. With no intent, canonical classification resumes.
                if (try self.quarantineIntent(dir)) |_| {
                    if (selected != null) return error.ReadFailed;
                    selected = scope;
                }
            }
        }
        const scope = selected orelse return false;
        try self.finishQuarantine(allocator, root, scope, empty_registry);
        return true;
    }

    pub fn quarantine(self: *FileStore, allocator: std.mem.Allocator, scope: QuarantineScope, empty_registry: []const u8) FileStoreError!void {
        if (self.quarantine_move.move_fn == null) return error.WriteFailed;
        // A read/size failure is not corrupt data. Do not start isolation if
        // the companion journal cannot be read within its own bound.
        const journal = try self.loadTransactionAlloc(allocator);
        defer if (journal) |bytes| allocator.free(bytes);
        if (scope == .journal and journal == null) return error.ReadFailed;
        const registry = if (scope == .registry) (try self.loadAlloc(allocator)) orelse return error.ReadFailed else null;
        defer if (registry) |bytes| allocator.free(bytes);
        self.dir.createDir(self.io, quarantine_directory, directoryPermissions()) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.WriteFailed,
        };
        const root = (try self.openQuarantine()) orelse return error.ReadFailed;
        defer root.close(self.io);
        root.createDir(self.io, scope.pendingName(), directoryPermissions()) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.WriteFailed,
        };
        const pending = root.openDir(self.io, scope.pendingName(), .{ .follow_symlinks = false }) catch return error.ReadFailed;
        defer pending.close(self.io);
        if (try self.quarantineIntent(pending) != null) return error.WriteFailed;
        var intent_bytes: [65]u8 = @splat(0);
        intent_bytes[0] = if (journal != null) '1' else '0';
        if (registry) |bytes| Sha256.hash(bytes, intent_bytes[1..33], .{});
        if (journal) |bytes| Sha256.hash(bytes, intent_bytes[33..65], .{});
        try self.commitNamedIn(pending, &intent_bytes, "intent", ".intent");
        if (!self.syncCommitDir(root, null) or !self.syncCommit(null)) return error.PersistenceOutcomeUnknown;
        try self.finishQuarantine(allocator, root, scope, empty_registry);
    }

    fn quarantineIntent(self: *FileStore, dir: std.Io.Dir) FileStoreError!?QuarantineIntent {
        var file = dir.openFile(self.io, "intent", .{ .follow_symlinks = false, .resolve_beneath = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.ReadFailed,
        };
        defer file.close(self.io);
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        var bytes: [65]u8 = undefined;
        if ((file.length(self.io) catch return error.ReadFailed) != bytes.len) return error.ReadFailed;
        if ((file.readPositionalAll(self.io, &bytes, 0) catch return error.ReadFailed) != bytes.len) return error.ReadFailed;
        return .{
            .journal_present = switch (bytes[0]) {
                '0' => false,
                '1' => true,
                else => return error.ReadFailed,
            },
            .registry_hash = bytes[1..33].*,
            .journal_hash = bytes[33..65].*,
        };
    }

    fn finishQuarantine(self: *FileStore, allocator: std.mem.Allocator, root: std.Io.Dir, scope: QuarantineScope, empty_registry: []const u8) FileStoreError!void {
        if (self.quarantine_move.move_fn == null) return error.WriteFailed;
        const pending = root.openDir(self.io, scope.pendingName(), .{ .follow_symlinks = false }) catch return error.ReadFailed;
        defer pending.close(self.io);
        const intent = (try self.quarantineIntent(pending)) orelse return error.ReadFailed;
        if (scope == .journal and !intent.journal_present) return error.ReadFailed;
        if (!self.syncCommitDir(pending, "intent") or !self.syncCommitDir(root, null) or !self.syncCommit(null)) return error.PersistenceOutcomeUnknown;
        // The untrusted journal is removed from the active path before a new
        // empty registry can become canonical. Every move preserves bytes.
        const journal_hash: ?[32]u8 = if (intent.journal_present) intent.journal_hash else null;
        const journal_state = try self.inspectQuarantineFile(pending, transaction_file_name, journal_hash, false);
        const registry_state = if (scope == .registry) try self.inspectQuarantineFile(pending, file_name, intent.registry_hash, true) else .absent;
        const current = if (scope == .registry and registry_state == .isolated) try self.loadAlloc(allocator) else null;
        defer if (current) |bytes| allocator.free(bytes);
        if (current) |bytes| if (!std.mem.eql(u8, bytes, empty_registry)) return error.WriteFailed;
        try self.isolateFile(pending, transaction_file_name, journal_hash, journal_state);
        if (scope == .registry) {
            try self.isolateFile(pending, file_name, intent.registry_hash, registry_state);
            if (current == null) try self.commit(empty_registry);
        }
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const request: QuarantineMove.Request = .{ .finish = .{ .scope = scope, .nonce = random } };
        var storage: [25]u8 = undefined;
        const finished = request.targetName(&storage);
        try self.quarantine_move.move(self.io, root, root, request);
        var path_storage: [80]u8 = undefined;
        const intent_path = std.fmt.bufPrint(&path_storage, "{s}/intent", .{finished}) catch unreachable;
        if (!self.syncCommitDir(root, intent_path)) return error.PersistenceOutcomeUnknown;
    }

    const IsolationFile = enum { absent, active, isolated };

    fn inspectQuarantineFile(self: *FileStore, pending: std.Io.Dir, name: []const u8, expected_hash: ?[32]u8, allow_empty_registry: bool) FileStoreError!IsolationFile {
        const target = pending.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.ReadFailed,
        };
        const source = self.dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.ReadFailed,
        };
        const expected = expected_hash orelse return if (source == null and target == null) .absent else error.WriteFailed;
        if (target) |stat| {
            if (stat.kind != .file or (source != null and !allow_empty_registry)) return error.WriteFailed;
            if (!std.mem.eql(u8, &(try self.hashFile(pending, name)), &expected)) return error.WriteFailed;
            return .isolated;
        } else {
            if (source) |stat| {
                if (stat.kind != .file) return error.ReadFailed;
            } else return error.WriteFailed;
            if (!std.mem.eql(u8, &(try self.hashFile(self.dir, name)), &expected)) return error.WriteFailed;
            return .active;
        }
    }

    fn isolateFile(self: *FileStore, pending: std.Io.Dir, name: []const u8, expected_hash: ?[32]u8, state: IsolationFile) FileStoreError!void {
        if (state == .absent) return;
        if (state == .active) try self.quarantine_move.move(self.io, self.dir, pending, if (std.mem.eql(u8, name, file_name)) .registry else .journal);
        if (!std.mem.eql(u8, &(try self.hashFile(pending, name)), &expected_hash.?)) return error.WriteFailed;
        const moved = pending.openFile(self.io, name, .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true }) catch return error.PersistenceOutcomeUnknown;
        defer moved.close(self.io);
        moved.sync(self.io) catch return error.PersistenceOutcomeUnknown;
        if (!self.syncCommitDir(pending, null) or !self.syncCommit(null)) return error.PersistenceOutcomeUnknown;
    }

    fn hashFile(self: *FileStore, dir: std.Io.Dir, name: []const u8) FileStoreError![32]u8 {
        var file = dir.openFile(self.io, name, .{ .follow_symlinks = false, .resolve_beneath = true }) catch return error.ReadFailed;
        defer file.close(self.io);
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length > (if (std.mem.eql(u8, name, transaction_file_name)) max_transaction_bytes else max_store_bytes)) return error.ReadFailed;
        var hash: Sha256 = .init(.{});
        var offset: u64 = 0;
        var buffer: [4096]u8 = undefined;
        while (offset < length) {
            const wanted: usize = @intCast(@min(length - offset, buffer.len));
            const count = file.readPositionalAll(self.io, buffer[0..wanted], offset) catch return error.ReadFailed;
            if (count != wanted) return error.ReadFailed;
            hash.update(buffer[0..count]);
            offset += count;
        }
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }

    pub fn recoverPendingCredentialTransaction(
        self: *FileStore,
        allocator: std.mem.Allocator,
        current_registry: ?RegistryWire,
        cleanup: CredentialCleanup,
        limits: Limits,
    ) (FileStoreError || Error)!bool {
        const bytes = (try self.loadTransactionAlloc(allocator)) orelse return false;
        defer allocator.free(bytes);
        var transaction = try decodeTransaction(allocator, bytes, limits);
        defer transaction.deinit();
        try validateTransactionRegistry(transaction.value, current_registry);
        try recoverCredentialTransaction(
            transaction.value,
            if (current_registry) |value| value.generation else 0,
            cleanup,
        );
        try self.clearTransaction();
        return true;
    }

    fn commitNamed(self: *FileStore, bytes: []const u8, target_name: []const u8, temp_prefix: []const u8) FileStoreError!void {
        return self.commitNamedIn(self.dir, bytes, target_name, temp_prefix);
    }

    fn commitNamedIn(
        self: *FileStore,
        dir: std.Io.Dir,
        bytes: []const u8,
        target_name: []const u8,
        temp_prefix: []const u8,
    ) FileStoreError!void {
        var random: [8]u8 = undefined;
        std.Io.randomSecure(self.io, &random) catch return error.WriteFailed;
        const random_hex = std.fmt.bytesToHex(random, .lower);
        var name_storage: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&name_storage);
        writer.print("{s}.{s}.tmp", .{ temp_prefix, random_hex }) catch
            return error.WriteFailed;
        const temp_name = writer.buffered();
        const file = dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        dir.rename(temp_name, dir, target_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommitDir(dir, target_name)) return error.PersistenceOutcomeUnknown;
    }

    fn commitJournalEffect(context: ?*anyopaque, bytes: []const u8) PersistenceEffect {
        const self: *FileStore = @ptrCast(@alignCast(context orelse return .failed));
        self.commitTransaction(bytes) catch |err| return switch (err) {
            error.PersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn commitRegistryEffect(context: ?*anyopaque, bytes: []const u8) PersistenceEffect {
        const self: *FileStore = @ptrCast(@alignCast(context orelse return .failed));
        self.commit(bytes) catch |err| return switch (err) {
            error.PersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn clearJournalEffect(context: ?*anyopaque) PersistenceEffect {
        const self: *FileStore = @ptrCast(@alignCast(context orelse return .failed));
        self.clearTransaction() catch |err| return switch (err) {
            error.PersistenceOutcomeUnknown => .outcome_unknown,
            else => .failed,
        };
        return .committed;
    }

    fn syncCommit(self: *FileStore, target_name: ?[]const u8) bool {
        return self.syncCommitDir(self.dir, target_name);
    }

    fn syncCommitDir(self: *FileStore, dir: std.Io.Dir, target_name: ?[]const u8) bool {
        if (builtin.os.tag == .windows) {
            const name = target_name orelse return true;
            const file = dir.openFile(self.io, name, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch return false;
            defer file.close(self.io);
            file.sync(self.io) catch return false;
            return true;
        }
        const directory_file: std.Io.File = .{
            .handle = dir.handle,
            .flags = .{ .nonblocking = false },
        };
        directory_file.sync(self.io) catch return false;
        return true;
    }
};

fn openOrCreateLock(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    const existing = dir.openFile(io, lock_file_name, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |file| return file;
    return dir.createFile(io, lock_file_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = privateFilePermissions(),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return dir.openFile(io, lock_file_name, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }),
        else => return err,
    };
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

const test_limits: Limits = .{
    .max_servers = 4,
    .max_tools_per_server = 8,
    .max_namespace_bytes = 24,
    .max_credential_locators = 16,
    .max_runtime_secrets_per_server = 128,
    .max_runtime_secret_bytes_per_server = 16 * 1024,
};

test "OAuth deadlines freeze per grant and bounded retry does not extend credentials" {
    const server: ServerWire = .{
        .id = "a",
        .namespace = "a",
        .display_name = "A",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "streamable_http", .url = "https://mcp.example.test/mcp" },
        .connection_approval = null,
        .tools = &.{},
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "ready",
            .registration = .{ .kind = "pre_registered", .issuer = null, .client_id = "client", .token_endpoint_auth_method = "none", .client_credential_revision = 1, .client_secret_ref = null },
            .consent = .{ .epoch = 1, .fingerprint = "consent", .resource = "https://mcp.example.test/mcp", .issuer = "https://issuer.example.test", .scopes = &.{}, .redirect_uri = "http://127.0.0.1/callback", .client_credential_revision = 1 },
            .grant = .{ .consent_epoch = 1, .token_revision = 1, .access_token_ref = "a/access", .refresh_token_ref = "a/refresh", .expires_at_unix_ms = 101_000 },
        } },
    };
    var second = server;
    second.id = "b";
    second.auth.oauth.?.grant.?.expires_at_unix_ms = 111_000;
    var servers = [_]ServerWire{ server, second };
    const registry: RegistryWire = .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &servers };
    var schedule = try OauthRefreshSchedule.init(std.testing.allocator, test_limits);
    defer schedule.deinit();
    schedule.reconcile(registry);
    schedule.observeTime(null);
    try std.testing.expectEqual(@as(u64, 101_000), schedule.eligibleAt("a", 101_000));
    schedule.observeTime(1000);
    try std.testing.expectEqual(@as(u64, 76_000), schedule.eligibleAt("a", 101_000));
    schedule.observeTime(70_000);
    schedule.reconcile(registry);
    try std.testing.expectEqual(@as(u64, 76_000), schedule.eligibleAt("a", 101_000));
    schedule.deferServer("a", 80_000);
    try std.testing.expect(schedule.eligibleAt("b", 111_000) < schedule.eligibleAt("a", 101_000));
    for (0..20) |_| schedule.deferServer("a", 80_000);
    try std.testing.expectEqual(@as(u64, 380_000), schedule.eligibleAt("a", 101_000));
    try std.testing.expectEqual(@as(?u64, 101_000), servers[0].auth.oauth.?.grant.?.expires_at_unix_ms);
    servers[0].auth.oauth.?.grant.?.token_revision += 1;
    schedule.reconcile(registry);
    schedule.observeTime(1000);
    try std.testing.expectEqual(@as(u64, 76_000), schedule.eligibleAt("a", 101_000));
    servers[0].auth.oauth.?.consent.?.epoch += 1;
    schedule.reconcile(registry);
    schedule.observeTime(100_996);
    try std.testing.expectEqual(@as(u64, 100_999), schedule.eligibleAt("a", 101_000));
    // Removing all grants also removes their retry state; max-size replacement
    // and absent/invalid clocks need no allocations after installation.
    schedule.reconcile(null);
    schedule.observeTime(0);
    try std.testing.expect(schedule.indexOf("a") == null);
}

fn approvedSchema2TestBytes(
    allocator: std.mem.Allocator,
    legacy_bytes: []const u8,
) ![]u8 {
    var legacy = try std.json.parseFromSlice(
        LegacyRegistryWire,
        allocator,
        legacy_bytes,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    );
    defer legacy.deinit();
    var migrated = try decode(allocator, legacy_bytes, test_limits);
    defer migrated.deinit();
    const fingerprints = try allocator.alloc([64]u8, migrated.value.servers.len);
    defer allocator.free(fingerprints);
    for (migrated.value.servers, legacy.value.servers, 0..) |*server, source, index| {
        server.enabled = source.enabled;
        if (source.enabled) {
            fingerprints[index] = connectionFingerprint(server.*);
            server.connection_approval = .{ .fingerprint = &fingerprints[index] };
        }
    }
    const buffer = try allocator.alloc(u8, max_store_bytes);
    defer allocator.free(buffer);
    return try allocator.dupe(
        u8,
        try encode(buffer, migrated.value, test_limits),
    );
}

test "registry strictly decodes valid stdio and HTTP configuration" {
    const bytes =
        \\{"schema_version":1,"generation":7,"servers":[{"id":"local-files","namespace":"files","display_name":"Files","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"/usr/bin/files-mcp","arguments":[{"literal":"--root"},{"literal":"/tmp"}],"environment":[{"name":"FILES_TOKEN","value":{"credential_ref":"files/token"}}]},"tools":["read_file"]},{"id":"remote-search","namespace":"search","display_name":"Search","enabled":true,"negotiation":"compat_only","timeout_ms":2000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"search/bearer"}}]},"tools":[]}]}
    ;
    var parsed = try decode(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.generation);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.servers.len);
    for (parsed.value.servers) |server|
        try std.testing.expectEqual(@as(?ServerProblem, null), serverProblem(server, test_limits));
}

test "schema 1 migration scrubs literal HTTP credentials into missing slots" {
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"literal":"raw-secret"}}]}}]}
    ;
    var parsed = try decode(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    const server = parsed.value.servers[0];
    try std.testing.expect(!server.enabled);
    try std.testing.expectEqualStrings("static", server.auth.kind);
    try std.testing.expect(server.transport.headers[0].credential_ref == null);
    try std.testing.expectEqual(@as(?ServerProblem, null), serverProblem(server, test_limits));
}

test "registry never treats argv env or headers as secret-capable literals" {
    const cases = [_][]const u8{
        \\{"schema_version":1,"generation":1,"servers":[{"id":"argv","namespace":"argv","display_name":"Argv","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","arguments":[{"credential_ref":"secret/arg"}]}}]}
        ,
        \\{"schema_version":1,"generation":1,"servers":[{"id":"env","namespace":"env","display_name":"Env","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"literal":"secret"}}]}}]}
        ,
        \\{"schema_version":1,"generation":1,"servers":[{"id":"header","namespace":"header","display_name":"Header","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"X-Custom-Token","value":{"literal":"secret"}}]}}]}
        ,
    };
    for (cases, 0..) |bytes, index| {
        var parsed = try decode(std.testing.allocator, bytes, test_limits);
        defer parsed.deinit();
        if (index == 0) {
            try std.testing.expectEqual(
                ServerProblem.invalid_credential_locator,
                serverProblem(parsed.value.servers[0], test_limits).?,
            );
        } else {
            try std.testing.expectEqual(
                @as(?ServerProblem, null),
                serverProblem(parsed.value.servers[0], test_limits),
            );
            const slot = if (index == 1)
                parsed.value.servers[0].transport.environment[0]
            else
                parsed.value.servers[0].transport.headers[0];
            try std.testing.expect(slot.credential_ref == null);
        }
    }
}

test "registry reserves transport and Agent protocol HTTP headers" {
    inline for (.{
        "Accept",
        "accept-encoding",
        "Content-Length",
        "content-type",
        "Host",
        "mcp-protocol-version",
        "Mcp-Session-Id",
    }) |header_name| {
        const bytes = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"generation\":1,\"servers\":[{{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{{\"name\":\"{s}\",\"value\":{{\"credential_ref\":\"secret/header\"}}}}]}}}}]}}",
            .{header_name},
        );
        defer std.testing.allocator.free(bytes);
        var parsed = try decode(std.testing.allocator, bytes, test_limits);
        defer parsed.deinit();
        try std.testing.expectEqual(
            ServerProblem.invalid_transport,
            serverProblem(parsed.value.servers[0], test_limits).?,
        );
    }
}

test "registry bounds the aggregate credential locator count" {
    var limits = test_limits;
    limits.max_credential_locators = 1;
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"env\",\"namespace\":\"env\",\"display_name\":\"Env\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\",\"environment\":[{\"name\":\"FIRST\",\"value\":{\"credential_ref\":\"secret/one\"}},{\"name\":\"SECOND\",\"value\":{\"credential_ref\":\"secret/two\"}}]}}]}",
            limits,
        ),
    );
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":2,\"generation\":1,\"servers\":[]}",
            test_limits,
        ),
    );
}

test "registry rejects ambiguous identity and unknown fields" {
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[],\"extra\":true}",
            test_limits,
        ),
    );
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"same\",\"namespace\":\"one\",\"display_name\":\"One\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"}},{\"id\":\"same\",\"namespace\":\"two\",\"display_name\":\"Two\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"}}]}",
            test_limits,
        ),
    );
    inline for (.{ "mcp-server", "1server" }) |namespace| {
        const bytes = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"generation\":1,\"servers\":[{{\"id\":\"server\",\"namespace\":\"{s}\",\"display_name\":\"Server\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1,\"transport\":{{\"kind\":\"stdio\",\"command\":\"tool\"}}}}]}}",
            .{namespace},
        );
        defer std.testing.allocator.free(bytes);
        var parsed = try decode(std.testing.allocator, bytes, test_limits);
        defer parsed.deinit();
        try std.testing.expectEqual(
            ServerProblem.invalid_namespace,
            serverProblem(parsed.value.servers[0], test_limits).?,
        );
        try std.testing.expect(!parsed.value.servers[0].enabled);
    }
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"server\",\"namespace\":\"server.name\",\"display_name\":\"Server\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"}}]}",
            test_limits,
        ),
    );
}

test "registry enforces the shared MCP HTTP endpoint contract" {
    const Fixture = struct {
        accepted: []const []const u8,
        rejected: []const []const u8,
    };
    const parsed = try std.json.parseFromSlice(
        Fixture,
        std.testing.allocator,
        @embedFile("testdata/mcp-http-endpoints.json"),
        .{},
    );
    defer parsed.deinit();

    for (parsed.value.accepted) |endpoint|
        try std.testing.expect(validEndpoint(endpoint, 4096));
    for (parsed.value.rejected) |endpoint|
        try std.testing.expect(!validEndpoint(endpoint, 4096));
}

test "sensitive endpoint creation journals its complete URL without a public intermediate" {
    const Entropy = struct {
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xab);
            return true;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
    };
    var management = try ManagementPort.init(std.testing.allocator, null, .{
        .persistence = .{ .available = true },
        .credentials = .{ .available = true, .probe_fn = Entropy.probe },
        .identity_generator = .{ .available = true, .fill_fn = Entropy.fill },
        .locator_generator = .{ .available = true, .fill_fn = Entropy.fill },
        .limits = test_limits,
    });
    defer management.deinit();
    const private_url = "https://mcp.example.test/k/synthetic-key?route=private";
    var mutation = switch (try management.prepareCreateHttpServer(0, .{
        .display_name = "Private endpoint",
        .url = private_url,
        .sensitive_endpoint = true,
    })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer mutation.deinit();
    try std.testing.expect(management.desiredRegistry() == null);
    const target = mutation.target();
    const transport = target.servers[0].transport;
    try std.testing.expect(transport.url == null);
    try std.testing.expectEqualStrings("https://mcp.example.test", endpointDisplay(transport));
    try std.testing.expectEqual(@as(usize, 1), mutation.candidates.len);
    try std.testing.expectEqualStrings(private_url, mutation.candidates[0].secret);
    try std.testing.expectEqualStrings(transport.sensitive_endpoint.?.credential_refs[0], mutation.plan.transaction.candidate_locators[0]);
    var buffer: [max_store_bytes]u8 = undefined;
    const encoded = try encode(&buffer, target, test_limits);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "synthetic-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "route=private") == null);
    const credentials = [_]ResolvedCredential{.{ .locator = mutation.candidates[0].locator, .secret = mutation.candidates[0].secret }};
    const resolved = try resolveEndpoint(std.testing.allocator, transport, &credentials, 4096);
    defer secureFree(std.testing.allocator, resolved);
    try std.testing.expectEqualStrings(private_url, resolved);
    var changed = transport;
    var private = changed.sensitive_endpoint.?;
    private.origin = "https://other.example.test";
    changed.sensitive_endpoint = private;
    try std.testing.expectError(error.InvalidEndpoint, resolveEndpoint(std.testing.allocator, changed, &credentials, 4096));
    try std.testing.expectError(error.InvalidEndpoint, resolveEndpoint(std.testing.allocator, transport, &.{}, 4096));
}

test "private endpoint parts remain ordered and protect only credential substitutions" {
    const Entropy = struct {
        next: u8 = 0,
        fn fill(context: ?*anyopaque, output: *[16]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.next += 1;
            @memset(output, self.next);
            return true;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
    };
    var entropy: Entropy = .{};
    var management = try ManagementPort.init(std.testing.allocator, null, .{
        .persistence = .{ .available = true },
        .credentials = .{ .available = true, .probe_fn = Entropy.probe },
        .identity_generator = .{ .context = &entropy, .available = true, .fill_fn = Entropy.fill },
        .locator_generator = .{ .context = &entropy, .available = true, .fill_fn = Entropy.fill },
        .limits = test_limits,
    });
    defer management.deinit();
    const parts = [_]EndpointPartInput{
        .{ .value = "https://mcp.example.test/k/", .is_credential = false },
        .{ .value = "synthetic-key", .is_credential = true },
        .{ .value = "?route=one", .is_credential = false },
    };
    const url = "https://mcp.example.test/k/synthetic-key?route=one";
    var mutation = switch (try management.prepareCreateHttpServer(0, .{ .display_name = "Template", .url = url, .sensitive_endpoint = true, .endpoint_parts = &parts })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer mutation.deinit();
    const transport = mutation.target().servers[0].transport;
    try std.testing.expectEqualSlices(u32, &.{1}, transport.sensitive_endpoint.?.secret_parts);
    var credentials: [3]ResolvedCredential = undefined;
    for (mutation.candidates, &credentials) |candidate, *credential| credential.* = .{ .locator = candidate.locator, .secret = candidate.secret };
    const resolved = try resolveEndpoint(std.testing.allocator, transport, &credentials, 4096);
    defer secureFree(std.testing.allocator, resolved);
    try std.testing.expectEqualStrings(url, resolved);
    // Swapping stored parts cannot silently redirect the connection.
    std.mem.swap(ResolvedCredential, &credentials[0], &credentials[2]);
    const resolved_again = try resolveEndpoint(std.testing.allocator, transport, &credentials, 4096);
    defer secureFree(std.testing.allocator, resolved_again);
    try std.testing.expectEqualStrings(url, resolved_again);
    var buffer: [max_store_bytes]u8 = undefined;
    const encoded = try encode(&buffer, mutation.target(), test_limits);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "synthetic-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "route=one") == null);
    try std.testing.expectEqual(std.meta.Tag(MutationPreparation).rejected, std.meta.activeTag(try management.prepareCreateHttpServer(0, .{ .display_name = "Mismatch", .url = "https://elsewhere.test/", .sensitive_endpoint = true, .endpoint_parts = &parts })));
}

test "installation target persists before effects and grants the initial catalog once" {
    const Fake = struct {
        entropy: u8 = 0,
        fn fill(context: ?*anyopaque, output: *[16]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.entropy += 1;
            @memset(output, self.entropy);
            return true;
        }
        fn commit(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var fake: Fake = .{};
    var limits = test_limits;
    limits.max_credential_secret_bytes = 32;
    var management = try ManagementPort.init(std.testing.allocator, null, .{
        .persistence = .{ .available = true, .commit_journal_fn = Fake.commit, .commit_registry_fn = Fake.commit, .clear_journal_fn = Fake.clear },
        .credentials = .{ .available = true, .probe_fn = Fake.probe, .create_fn = Fake.create, .delete_fn = Fake.delete },
        .identity_generator = .{ .context = &fake, .available = true, .fill_fn = Fake.fill },
        .locator_generator = .{ .context = &fake, .available = true, .fill_fn = Fake.fill },
        .limits = limits,
    });
    defer management.deinit();
    const request = "{this is a synthetic private request, not a user secret or an executable payload}";
    var start = switch (try management.prepareInstallationStart(0, .{ .stdio = .{ .display_name = "Fixture", .command = "node" } }, .{
        .task_id = 1,
        .run_id = 3,
        .source_message_id = 2,
        .source_origin = "https://source.example",
        .request = request,
    })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer start.deinit();
    try std.testing.expect(management.desiredRegistry() == null);
    const target = start.target();
    const id = try std.testing.allocator.dupe(u8, target.servers[0].id);
    defer std.testing.allocator.free(id);
    try std.testing.expect(!target.servers[0].enabled);
    try std.testing.expect(target.servers[0].installation.?.request_refs.len > 1);
    try std.testing.expectEqual(.saved, try management.commitPreparedMutation(&start));
    var buffer: [max_store_bytes]u8 = undefined;
    const durable = try encode(&buffer, management.desiredRegistry().?, limits);
    try std.testing.expect(std.mem.indexOf(u8, durable, "synthetic private") == null);
    var restored = try decode(std.testing.allocator, durable, limits);
    defer restored.deinit();
    try std.testing.expect(!restored.value.servers[0].enabled);
    try std.testing.expectEqual(.preparing, restored.value.servers[0].installation.?.phase);
    try std.testing.expectEqual(.rejected, std.meta.activeTag(try management.prepareInstallationUpdate(1, .{ .server_id = id, .expected_revision = 1, .phase = .ready, .active_elapsed_ms = 0, .initial_tools = &.{"echo"} })));
    var connect = switch (try management.prepareInstallationUpdate(1, .{ .server_id = id, .expected_revision = 1, .phase = .connecting, .active_elapsed_ms = 1 })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer connect.deinit();
    try std.testing.expectEqual(.saved, try management.commitPreparedMutation(&connect));
    var grant = switch (try management.prepareInstallationUpdate(2, .{ .server_id = id, .expected_revision = 2, .phase = .connecting, .active_elapsed_ms = 2, .initial_tools = &.{"echo"} })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer grant.deinit();
    try std.testing.expectEqual(.saved, try management.commitPreparedMutation(&grant));
    var ready = switch (try management.prepareInstallationUpdate(3, .{ .server_id = id, .expected_revision = 3, .phase = .ready, .active_elapsed_ms = 3 })) {
        .prepared => |value| value,
        else => return error.TestUnexpectedResult,
    };
    defer ready.deinit();
    try std.testing.expectEqual(.saved, try management.commitPreparedMutation(&ready));
    const installed = management.desiredRegistry().?.servers[0];
    try std.testing.expectEqual(@as(usize, 1), installed.tools.len);
    try std.testing.expectEqualStrings("echo", installed.tools[0]);
    try std.testing.expect(installed.installation.?.initial_grant_completed);
    try std.testing.expect(!installed.installation.?.initial_grant_pending);
    try std.testing.expectEqual(.rejected, std.meta.activeTag(try management.prepareInstallationUpdate(4, .{ .server_id = id, .expected_revision = 4, .phase = .ready, .active_elapsed_ms = 4, .initial_tools = &.{ "echo", "new_tool" } })));
}

test "schema two migration preserves approved public connections and tool grants" {
    const old =
        \\{"schema_version":2,"generation":8,"oauth_operation":null,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":30000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/mcp"},"auth":{"kind":"none","oauth":null},"connection_approval":{"fingerprint":"e7fd88fc9bfb80b164aaa354e7ed4fe8992f942d608d51da74b8f232406578a7"},"tools":["search"]}]}
    ;
    var migrated = try decode(std.testing.allocator, old, test_limits);
    defer migrated.deinit();
    try std.testing.expectEqual(schema_version, migrated.value.schema_version);
    try std.testing.expectEqual(@as(u64, 8), migrated.value.generation);
    const server = migrated.value.servers[0];
    try std.testing.expect(server.enabled);
    try std.testing.expectEqualStrings("search", server.tools[0]);
    try std.testing.expectEqualStrings(server.connection_approval.?.fingerprint, &connectionFingerprint(server));
    try std.testing.expect(serverProblem(server, test_limits) == null);
    try std.testing.expect(server.transport.sensitive_endpoint == null);
    try std.testing.expectEqualStrings("https://mcp.example.test/mcp", server.transport.url.?);
}

test "registry file store atomically replaces bytes under one writer lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    try store.commit("{\"schema_version\":1}");
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("{\"schema_version\":1}", restored);
    try store.commitTransaction("{\"schema_version\":1}");
    const transaction = (try store.loadTransactionAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(transaction);
    try std.testing.expectEqualStrings("{\"schema_version\":1}", transaction);
    try store.clearTransaction();
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try store.loadTransactionAlloc(std.testing.allocator),
    );
    store.lock_file.close(std.testing.io);
}

test "credential transaction recovery follows the durable registry generation" {
    const Cleanup = struct {
        deleted: [2][]const u8 = undefined,
        count: usize = 0,

        fn remove(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.deleted[self.count] = locator;
            self.count += 1;
            return true;
        }
    };
    const bytes =
        \\{"schema_version":1,"base_generation":4,"target_generation":5,"candidate_locators":["candidate/a"],"retired_locators":["retired/a"]}
    ;
    var parsed = try decodeTransaction(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    var cleanup: Cleanup = .{};
    const capability: CredentialCleanup = .{
        .context = &cleanup,
        .available = true,
        .delete_fn = Cleanup.remove,
    };
    try recoverCredentialTransaction(parsed.value, 4, capability);
    try std.testing.expectEqualStrings("candidate/a", cleanup.deleted[0]);
    cleanup.count = 0;
    try recoverCredentialTransaction(parsed.value, 5, capability);
    try std.testing.expectEqualStrings("retired/a", cleanup.deleted[0]);
    try std.testing.expectError(
        error.TransactionGenerationMismatch,
        recoverCredentialTransaction(parsed.value, 6, capability),
    );

    var initial = try decodeTransaction(
        std.testing.allocator,
        "{\"schema_version\":1,\"base_generation\":0,\"target_generation\":1,\"candidate_locators\":[\"candidate/a\"],\"retired_locators\":[]}",
        test_limits,
    );
    defer initial.deinit();
    cleanup.count = 0;
    try recoverCredentialTransaction(initial.value, 0, capability);
    try std.testing.expectEqualStrings("candidate/a", cleanup.deleted[0]);
}

test "file store recovery cleans and closes a pending credential transaction" {
    const Cleanup = struct {
        count: usize = 0,

        fn remove(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!std.mem.eql(u8, locator, "candidate/a")) return false;
            self.count += 1;
            return true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    defer store.lock_file.close(std.testing.io);
    try store.commitTransaction(
        "{\"schema_version\":1,\"base_generation\":4,\"target_generation\":5,\"candidate_locators\":[\"candidate/a\"],\"retired_locators\":[]}",
    );
    var cleanup: Cleanup = .{};
    try std.testing.expect(try store.recoverPendingCredentialTransaction(
        std.testing.allocator,
        .{ .schema_version = schema_version, .generation = 4, .oauth_operation = null, .servers = &.{} },
        .{ .context = &cleanup, .available = true, .delete_fn = Cleanup.remove },
        test_limits,
    ));
    try std.testing.expectEqual(@as(usize, 1), cleanup.count);
    try std.testing.expect(!(try store.recoverPendingCredentialTransaction(
        std.testing.allocator,
        .{ .schema_version = schema_version, .generation = 4, .oauth_operation = null, .servers = &.{} },
        .{ .context = &cleanup, .available = true, .delete_fn = Cleanup.remove },
        test_limits,
    )));
}

test "credential transaction rejects aliases across candidate and retired sets" {
    try std.testing.expectError(
        error.TransactionCorrupt,
        decodeTransaction(
            std.testing.allocator,
            "{\"schema_version\":1,\"base_generation\":1,\"target_generation\":2,\"candidate_locators\":[\"same\"],\"retired_locators\":[\"same\"]}",
            test_limits,
        ),
    );

    var limits = test_limits;
    limits.max_credential_locators = 1;
    try std.testing.expectError(
        error.TransactionCorrupt,
        decodeTransaction(
            std.testing.allocator,
            "{\"schema_version\":1,\"base_generation\":1,\"target_generation\":2,\"candidate_locators\":[\"candidate\"],\"retired_locators\":[\"retired\"]}",
            limits,
        ),
    );
}

test "registry and transaction decoding preserve resource failure instead of diagnosing corruption" {
    const Probe = struct {
        fn registry(allocator: std.mem.Allocator, bytes: []const u8) !void {
            var parsed = try decode(allocator, bytes, test_limits);
            defer parsed.deinit();
        }
        fn transaction(allocator: std.mem.Allocator) !void {
            var parsed = try decodeTransaction(allocator, "{\"schema_version\":1,\"base_generation\":0,\"target_generation\":1,\"candidate_locators\":[\"candidate/a\"],\"retired_locators\":[]}", test_limits);
            defer parsed.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.registry, .{"{\"schema_version\":1,\"generation\":1,\"servers\":[]}"});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.registry, .{"{\"schema_version\":2,\"generation\":1,\"oauth_operation\":null,\"servers\":[]}"});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.transaction, .{});
}

test "journal cleanup checks current references before any credential deletion" {
    const Cleanup = struct {
        count: usize = 0,
        fn remove(raw: ?*anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.count += 1;
            return true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true, .truncate = false });
    defer lock.close(std.testing.io);
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    const journal = "{\"schema_version\":1,\"base_generation\":4,\"target_generation\":5,\"candidate_locators\":[\"candidate/a\"],\"retired_locators\":[\"retired/a\"]}";
    for ([_]u64{ 4, 5 }) |generation| {
        try store.commitTransaction(journal);
        var slots = [_]SecretSlotWire{.{ .name = "X-Token", .credential_ref = if (generation == 4) "candidate/a" else "retired/a" }};
        var servers = [_]ServerWire{.{ .id = "server", .namespace = "server", .display_name = "Server", .enabled = true, .negotiation = "automatic", .timeout_ms = 1000, .transport = .{ .kind = "streamable_http", .url = "https://mcp.example.test/mcp", .headers = &slots }, .auth = .{ .kind = "none", .oauth = null }, .connection_approval = null, .tools = &.{} }};
        const registry: RegistryWire = .{ .schema_version = schema_version, .generation = generation, .oauth_operation = null, .servers = &servers };
        var cleanup: Cleanup = .{};
        const capability: CredentialCleanup = .{ .context = &cleanup, .available = true, .delete_fn = Cleanup.remove };
        try std.testing.expectError(error.TransactionRegistryMismatch, store.recoverPendingCredentialTransaction(std.testing.allocator, registry, capability, test_limits));
        try std.testing.expectEqual(@as(usize, 0), cleanup.count);
        const retained = (try store.loadTransactionAlloc(std.testing.allocator)).?;
        defer std.testing.allocator.free(retained);
        try std.testing.expectEqualStrings(journal, retained);
        slots[0].credential_ref = if (generation == 4) "retired/a" else "candidate/a";
        try std.testing.expect(try store.recoverPendingCredentialTransaction(std.testing.allocator, registry, capability, test_limits));
        try std.testing.expectEqual(@as(usize, 1), cleanup.count);
    }
}

test "mutation plan rotates a fresh locator without retiring a shared reference" {
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":4,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/shared\"}},{\"name\":\"X-Backup\",\"value\":{\"credential_ref\":\"v1/shared\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":5,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/fresh\"}},{\"name\":\"X-Backup\",\"value\":{\"credential_ref\":\"v1/shared\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer target.deinit();

    var plan = (try planMutation(
        std.testing.allocator,
        base.value,
        target.value,
        4,
        &.{"v1/fresh"},
        test_limits,
    )).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(u64, 4), plan.transaction.base_generation);
    try std.testing.expectEqual(@as(u64, 5), plan.transaction.target_generation);
    try std.testing.expectEqual(@as(usize, 1), plan.transaction.candidate_locators.len);
    try std.testing.expectEqualStrings(
        "v1/fresh",
        plan.transaction.candidate_locators[0],
    );
    try std.testing.expectEqual(@as(usize, 0), plan.transaction.retired_locators.len);
}

test "mutation plan retires only the last registry reference" {
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":8,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/retired\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":9,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[]},\"tools\":[]}]}",
        test_limits,
    );
    defer target.deinit();

    var plan = (try planMutation(
        std.testing.allocator,
        base.value,
        target.value,
        8,
        &.{},
        test_limits,
    )).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 0), plan.transaction.candidate_locators.len);
    try std.testing.expectEqual(@as(usize, 1), plan.transaction.retired_locators.len);
    try std.testing.expectEqualStrings(
        "v1/retired",
        plan.transaction.retired_locators[0],
    );
}

test "mutation plan rejects unbacked locators and recognizes semantic no-op" {
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"local\",\"namespace\":\"local\",\"display_name\":\"Local\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var unchanged = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[{\"id\":\"local\",\"namespace\":\"local\",\"display_name\":\"Local\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer unchanged.deinit();
    try std.testing.expect((try planMutation(
        std.testing.allocator,
        base.value,
        unchanged.value,
        1,
        &.{},
        test_limits,
    )) == null);

    var missing = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/missing\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer missing.deinit();
    try std.testing.expectError(
        error.InvalidMutation,
        planMutation(
            std.testing.allocator,
            base.value,
            missing.value,
            1,
            &.{},
            test_limits,
        ),
    );
}

test "mutation plan permits only monotonic repair of invalid servers" {
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"broken\",\"namespace\":\"broken\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var unchanged_invalid = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[{\"id\":\"broken\",\"namespace\":\"broken\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]},{\"id\":\"healthy\",\"namespace\":\"healthy\",\"display_name\":\"Healthy\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer unchanged_invalid.deinit();
    var allowed = (try planMutation(
        std.testing.allocator,
        base.value,
        unchanged_invalid.value,
        1,
        &.{},
        test_limits,
    )).?;
    allowed.deinit();

    var changed_invalid = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[{\"id\":\"broken\",\"namespace\":\"broken\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"different\"},\"tools\":[]}]}",
        test_limits,
    );
    defer changed_invalid.deinit();
    try std.testing.expectError(
        error.InvalidMutation,
        planMutation(
            std.testing.allocator,
            base.value,
            changed_invalid.value,
            1,
            &.{},
            test_limits,
        ),
    );

    var valid_base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"healthy\",\"namespace\":\"healthy\",\"display_name\":\"Healthy\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer valid_base.deinit();
    var damaged_target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[{\"id\":\"healthy\",\"namespace\":\"healthy\",\"display_name\":\"Healthy\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":0,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer damaged_target.deinit();
    try std.testing.expectError(
        error.InvalidMutation,
        planMutation(
            std.testing.allocator,
            valid_base.value,
            damaged_target.value,
            1,
            &.{},
            test_limits,
        ),
    );

    var introduced_invalid = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"broken\",\"namespace\":\"broken\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer introduced_invalid.deinit();
    try std.testing.expectError(
        error.InvalidMutation,
        planMutation(
            std.testing.allocator,
            null,
            introduced_invalid.value,
            0,
            &.{},
            test_limits,
        ),
    );
}

test "mutation plan retires only trusted references from invalid servers" {
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"debris\",\"namespace\":\"debris\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"bad locator\"}}]},\"tools\":[]},{\"id\":\"owned\",\"namespace\":\"owned\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/owned\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[]}",
        test_limits,
    );
    defer target.deinit();
    var plan = (try planMutation(
        std.testing.allocator,
        base.value,
        target.value,
        1,
        &.{},
        test_limits,
    )).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.transaction.retired_locators.len);
    try std.testing.expectEqualStrings(
        "v1/owned",
        plan.transaction.retired_locators[0],
    );
}

test "transaction coordinator commits journal credentials registry cleanup and clear in order" {
    const Fake = struct {
        const Event = enum { probe, journal, create, registry, delete, clear };
        events: [8]Event = undefined,
        event_count: usize = 0,

        fn record(self: *@This(), event: Event) void {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }
        fn commitJournal(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.journal);
            return .committed;
        }
        fn commitRegistry(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.registry);
            return .committed;
        }
        fn clear(context: ?*anyopaque) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.clear);
            return .committed;
        }
        fn probe(context: ?*anyopaque, _: []const u8) CredentialPresence {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.probe);
            return .missing;
        }
        fn create(context: ?*anyopaque, _: []const u8, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.create);
            return true;
        }
        fn delete(context: ?*anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.delete);
            return true;
        }
        fn persistence(self: *@This()) MutationPersistence {
            return .{
                .context = self,
                .available = true,
                .commit_journal_fn = commitJournal,
                .commit_registry_fn = commitRegistry,
                .clear_journal_fn = clear,
            };
        }
        fn credentials(self: *@This()) CredentialEffects {
            return .{
                .context = self,
                .available = true,
                .probe_fn = probe,
                .create_fn = create,
                .delete_fn = delete,
            };
        }
    };
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":3,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/old\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":4,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/new\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer target.deinit();
    var plan = (try planMutation(
        std.testing.allocator,
        base.value,
        target.value,
        3,
        &.{"v1/new"},
        test_limits,
    )).?;
    defer plan.deinit();
    var secret = [_]u8{ 1, 2, 3, 4 };
    var candidates = [_]CandidateCredential{.{ .locator = "v1/new", .secret = &secret }};
    var fake: Fake = .{};
    var coordinator: TransactionCoordinator = .{};
    try std.testing.expectEqual(
        MutationCommit.saved,
        try coordinator.commit(
            std.testing.allocator,
            fake.persistence(),
            fake.credentials(),
            &plan,
            &candidates,
            test_limits,
        ),
    );
    try std.testing.expectEqual(StoreHealth.ready, coordinator.health);
    try std.testing.expectEqualSlices(
        Fake.Event,
        &.{ .probe, .journal, .create, .registry, .delete, .clear },
        fake.events[0..fake.event_count],
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &secret);
}

test "transaction coordinator freezes the store at every uncertain boundary" {
    const Mode = enum {
        journal_failed,
        journal_unknown,
        create_failed,
        registry_failed,
        registry_unknown,
        delete_failed,
        clear_unknown,
    };
    const Fake = struct {
        mode: Mode,
        fn commitJournal(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return switch (self.mode) {
                .journal_failed => .failed,
                .journal_unknown => .outcome_unknown,
                else => .committed,
            };
        }
        fn commitRegistry(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return switch (self.mode) {
                .registry_failed => .failed,
                .registry_unknown => .outcome_unknown,
                else => .committed,
            };
        }
        fn clear(context: ?*anyopaque) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return if (self.mode == .clear_unknown) .outcome_unknown else .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(context: ?*anyopaque, _: []const u8, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.mode != .create_failed;
        }
        fn delete(context: ?*anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.mode != .delete_failed;
        }
        fn persistence(self: *@This()) MutationPersistence {
            return .{
                .context = self,
                .available = true,
                .commit_journal_fn = commitJournal,
                .commit_registry_fn = commitRegistry,
                .clear_journal_fn = clear,
            };
        }
        fn credentials(self: *@This()) CredentialEffects {
            return .{
                .context = self,
                .available = true,
                .probe_fn = probe,
                .create_fn = create,
                .delete_fn = delete,
            };
        }
    };
    const Expectation = struct { mode: Mode, commit: MutationCommit, health: StoreHealth };
    const expectations = [_]Expectation{
        .{ .mode = .journal_failed, .commit = .not_saved, .health = .ready },
        .{ .mode = .journal_unknown, .commit = .not_saved_recovery_required, .health = .outcome_unknown },
        .{ .mode = .create_failed, .commit = .not_saved, .health = .ready },
        .{ .mode = .registry_failed, .commit = .not_saved, .health = .ready },
        .{ .mode = .registry_unknown, .commit = .registry_outcome_unknown, .health = .outcome_unknown },
        .{ .mode = .delete_failed, .commit = .saved_recovery_required, .health = .recovery_required },
        .{ .mode = .clear_unknown, .commit = .saved_recovery_required, .health = .outcome_unknown },
    };
    var base = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":5,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/old\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer base.deinit();
    var target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":6,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/new\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer target.deinit();
    var plan = (try planMutation(
        std.testing.allocator,
        base.value,
        target.value,
        5,
        &.{"v1/new"},
        test_limits,
    )).?;
    defer plan.deinit();

    for (expectations) |expectation| {
        var secret = [_]u8{ 9, 8, 7 };
        var candidates = [_]CandidateCredential{.{ .locator = "v1/new", .secret = &secret }};
        var fake: Fake = .{ .mode = expectation.mode };
        var coordinator: TransactionCoordinator = .{};
        try std.testing.expectEqual(
            expectation.commit,
            try coordinator.commit(
                std.testing.allocator,
                fake.persistence(),
                fake.credentials(),
                &plan,
                &candidates,
                test_limits,
            ),
        );
        try std.testing.expectEqual(expectation.health, coordinator.health);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &secret);
        if (coordinator.health != .ready) {
            var blocked_secret = [_]u8{ 1, 1, 1 };
            var blocked_candidates = [_]CandidateCredential{.{
                .locator = "v1/new",
                .secret = &blocked_secret,
            }};
            try std.testing.expectEqual(
                MutationCommit.blocked,
                try coordinator.commit(
                    std.testing.allocator,
                    fake.persistence(),
                    fake.credentials(),
                    &plan,
                    &blocked_candidates,
                    test_limits,
                ),
            );
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &blocked_secret);
        }
    }
}

test "file store mutation persistence commits target and clears the journal" {
    const Credentials = struct {
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn effects() CredentialEffects {
            return .{
                .available = true,
                .probe_fn = probe,
                .create_fn = create,
                .delete_fn = delete,
            };
        }
    };
    const base_bytes =
        "{\"schema_version\":1,\"generation\":1,\"servers\":[]}";
    var base = try decode(std.testing.allocator, base_bytes, test_limits);
    defer base.deinit();
    var target = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":2,\"servers\":[{\"id\":\"local\",\"namespace\":\"local\",\"display_name\":\"Local\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer target.deinit();
    var plan = (try planMutation(
        std.testing.allocator,
        base.value,
        target.value,
        1,
        &.{},
        test_limits,
    )).?;
    defer plan.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    defer store.lock_file.close(std.testing.io);
    try store.commit(base_bytes);
    var coordinator: TransactionCoordinator = .{};
    try std.testing.expectEqual(
        MutationCommit.saved,
        try coordinator.commit(
            std.testing.allocator,
            store.mutationPersistence(),
            Credentials.effects(),
            &plan,
            &.{},
            test_limits,
        ),
    );
    const saved = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(saved);
    var decoded_saved = try decode(std.testing.allocator, saved, test_limits);
    defer decoded_saved.deinit();
    try std.testing.expectEqual(@as(u64, 2), decoded_saved.value.generation);
    try std.testing.expect((try store.loadTransactionAlloc(std.testing.allocator)) == null);
}

test "management port owns fresh locators and keeps Runtime replacement pending" {
    const Fake = struct {
        created: bool = false,
        retired: bool = false,

        fn journal(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn registry(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, locator: []const u8) CredentialPresence {
            return if (std.mem.eql(u8, locator, "v1/abababababababababababababababab"))
                .missing
            else
                .unavailable;
        }
        fn create(context: ?*anyopaque, locator: []const u8, secret: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.created = std.mem.eql(u8, locator, "v1/abababababababababababababababab") and
                std.mem.eql(u8, secret, "replacement");
            return self.created;
        }
        fn delete(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.retired = std.mem.eql(u8, locator, "v1/old");
            return self.retired;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xab);
            return true;
        }
    };
    var parsed = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":4,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/old\"}}]},\"tools\":[]}]}",
        test_limits,
    );
    defer parsed.deinit();
    var fake: Fake = .{};
    var management = try ManagementPort.init(std.testing.allocator, parsed.value, .{
        .persistence = .{
            .context = &fake,
            .available = true,
            .commit_journal_fn = Fake.journal,
            .commit_registry_fn = Fake.registry,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .context = &fake,
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .locator_generator = .{ .available = true, .fill_fn = Fake.fill },
        .limits = test_limits,
    });
    defer management.deinit();
    var approval = switch (try management.prepareApproveConnection(
        4,
        .{ .server_id = "remote" },
    )) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer approval.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&approval),
    );
    var secret = [_]u8{ 'r', 'e', 'p', 'l', 'a', 'c', 'e', 'm', 'e', 'n', 't' };
    var capture = switch (try management.prepareCaptureStaticSecret(5, .{
        .server_id = "remote",
        .slot_name = "Authorization",
        .secret = &secret,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer capture.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&capture),
    );
    try std.testing.expect(fake.created);
    try std.testing.expect(fake.retired);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** secret.len), &secret);
    const inspection = management.inspect();
    try std.testing.expectEqual(@as(?u64, 6), inspection.desired_generation);
    try std.testing.expectEqual(RuntimeAlignment.unknown, inspection.runtime_alignment);
    try std.testing.expectEqualStrings(
        "Remote",
        management.desired.?.value.servers[0].display_name,
    );
}

test "typed management creates approved enabled servers with an empty allowlist" {
    const Fake = struct {
        registry_commits: usize = 0,

        fn journal(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn registry(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.registry_commits += 1;
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xab);
            return true;
        }
    };
    var fake: Fake = .{};
    var management = try ManagementPort.init(std.testing.allocator, null, .{
        .persistence = .{
            .context = &fake,
            .available = true,
            .commit_journal_fn = Fake.journal,
            .commit_registry_fn = Fake.registry,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .context = &fake,
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .identity_generator = .{ .available = true, .fill_fn = Fake.fill },
        .limits = test_limits,
    });
    defer management.deinit();

    try std.testing.expect((try management.prepareCreateHttpServer(0, .{
        .display_name = "Unsafe",
        .url = "http://example.test/rpc",
    })) == .rejected);
    try std.testing.expect((try management.prepareCreateHttpServer(0, .{
        .display_name = "Unsafe\nname",
        .url = "https://mcp.example.test/rpc",
    })) == .rejected);
    try std.testing.expect((try management.prepareCreateHttpServer(0, .{
        .display_name = "Remote",
        .url = "https://exa mple.test/rpc",
    })) == .rejected);
    var stdio_preparation = try management.prepareCreateStdioServer(0, .{
        .display_name = "Local",
        .command = "/usr/bin/local-mcp",
        .arguments = &.{ "--root", "/tmp" },
        .auth_mode = .static,
        .environment_names = &.{"LOCAL_TOKEN"},
    });
    switch (stdio_preparation) {
        .prepared => |*mutation| {
            defer mutation.deinit();
            const server = mutation.target().servers[0];
            try std.testing.expectEqualStrings("stdio", server.transport.kind);
            try std.testing.expectEqualStrings("/usr/bin/local-mcp", server.transport.command.?);
            try std.testing.expectEqualStrings("--root", server.transport.arguments[0].literal.?);
            try std.testing.expectEqualStrings("LOCAL_TOKEN", server.transport.environment[0].name);
            try std.testing.expect(server.transport.environment[0].credential_ref == null);
            try std.testing.expectEqualStrings("static", server.auth.kind);
            try std.testing.expect(server.connection_approval != null);
            try std.testing.expect(server.enabled);
        },
        .unchanged, .rejected => return error.TestUnexpectedResult,
    }
    var preparation = try management.prepareCreateHttpServer(0, .{
        .display_name = "Remote",
        .url = "https://mcp.example.test/rpc",
    });
    switch (preparation) {
        .prepared => |*mutation| {
            defer mutation.deinit();
            const target = mutation.target();
            try std.testing.expectEqual(@as(u64, 1), target.generation);
            try std.testing.expectEqual(@as(usize, 1), target.servers.len);
            try std.testing.expectEqualStrings(
                "mcp-abababababababababab",
                target.servers[0].id,
            );
            try std.testing.expectEqualStrings(
                "mcp_abababababababababab",
                target.servers[0].namespace,
            );
            try std.testing.expect(target.servers[0].enabled);
            try std.testing.expectEqualStrings("streamable_http", target.servers[0].transport.kind);
            try std.testing.expectEqualStrings("none", target.servers[0].auth.kind);
            try std.testing.expect(target.servers[0].connection_approval != null);
            try std.testing.expectEqual(@as(usize, 0), target.servers[0].tools.len);
            try std.testing.expectEqual(
                ManagementOutcome.saved,
                try management.commitPreparedMutation(mutation),
            );
        },
        .unchanged, .rejected => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), fake.registry_commits);
    try std.testing.expectEqual(@as(?u64, 1), management.inspect().desired_generation);
}

test "static secret rotation preserves approval and requires Runtime replacement" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            if (!std.mem.eql(u8, locator, "v1/old")) return .missing;
            return .{ .value = allocator.dupe(u8, "old-secret") catch
                return .out_of_memory };
        }
    };
    const Effects = struct {
        created: bool = false,
        retired: bool = false,

        fn journal(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn registry(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, locator: []const u8) CredentialPresence {
            return if (std.mem.eql(u8, locator, "v1/cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"))
                .missing
            else
                .present;
        }
        fn create(context: ?*anyopaque, locator: []const u8, secret: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.created = std.mem.eql(
                u8,
                locator,
                "v1/cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
            ) and std.mem.eql(u8, secret, "new-secret");
            return self.created;
        }
        fn delete(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.retired = std.mem.eql(u8, locator, "v1/old");
            return self.retired;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xcd);
            return true;
        }
    };
    const legacy =
        "{\"schema_version\":1,\"generation\":7,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"credential_ref\":\"v1/old\"}}]},\"tools\":[]}]}";
    const startup = try approvedSchema2TestBytes(std.testing.allocator, legacy);
    defer std.testing.allocator.free(startup);
    var preparation = try prepare(
        std.testing.allocator,
        startup,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer preparation.deinit();
    try std.testing.expectEqual(ServerPreparationState.eligible, preparation.server_states[0]);
    var manifest = (try RuntimeManifest.candidate(std.testing.allocator, &preparation)).?;
    var effects: Effects = .{};
    var management = try ManagementPort.init(
        std.testing.allocator,
        preparation.registry.?.value,
        .{
            .persistence = .{
                .context = &effects,
                .available = true,
                .commit_journal_fn = Effects.journal,
                .commit_registry_fn = Effects.registry,
                .clear_journal_fn = Effects.clear,
            },
            .credentials = .{
                .context = &effects,
                .available = true,
                .probe_fn = Effects.probe,
                .create_fn = Effects.create,
                .delete_fn = Effects.delete,
            },
            .locator_generator = .{ .available = true, .fill_fn = Effects.fill },
            .limits = test_limits,
            .runtime_manifest = &manifest,
        },
    );
    defer management.deinit();
    try std.testing.expectEqual(RuntimeAlignment.current, management.inspect().runtime_alignment);
    const approval_before = management.desired.?.value.servers[0].connection_approval.?.fingerprint;
    var secret = [_]u8{ 'n', 'e', 'w', '-', 's', 'e', 'c', 'r', 'e', 't' };
    var rotation = switch (try management.prepareCaptureStaticSecret(7, .{
        .server_id = "remote",
        .slot_name = "Authorization",
        .secret = &secret,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer rotation.deinit();
    try std.testing.expectEqual(ManagementOutcome.saved, try management.commitPreparedMutation(&rotation));
    try std.testing.expect(effects.created);
    try std.testing.expect(effects.retired);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** secret.len), &secret);
    try std.testing.expectEqualStrings(
        approval_before,
        management.desired.?.value.servers[0].connection_approval.?.fingerprint,
    );
    try std.testing.expectEqual(
        RuntimeAlignment.restart_required,
        management.inspect().runtime_alignment,
    );
}

test "static secret capture before approval has no persistence or credential effects" {
    const Fake = struct {
        effects: usize = 0,

        fn effect(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return .committed;
        }
        fn clear(context: ?*anyopaque) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return .committed;
        }
        fn probe(context: ?*anyopaque, _: []const u8) CredentialPresence {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return .missing;
        }
        fn create(context: ?*anyopaque, _: []const u8, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return true;
        }
        fn delete(context: ?*anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xef);
            return true;
        }
    };
    var slot = [_]SecretSlotWire{.{ .name = "TOKEN", .credential_ref = null }};
    const server: ServerWire = .{
        .id = "local",
        .namespace = "local",
        .display_name = "Local",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "stdio",
            .command = "/usr/bin/local-mcp",
            .environment = &slot,
        },
        .auth = .{ .kind = "static", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    var servers = [_]ServerWire{server};
    var fake: Fake = .{};
    var management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &servers,
    }, .{
        .persistence = .{
            .context = &fake,
            .available = true,
            .commit_journal_fn = Fake.effect,
            .commit_registry_fn = Fake.effect,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .context = &fake,
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .locator_generator = .{ .available = true, .fill_fn = Fake.fill },
        .limits = test_limits,
    });
    defer management.deinit();
    var secret = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    try std.testing.expect((try management.prepareCaptureStaticSecret(1, .{
        .server_id = "local",
        .slot_name = "TOKEN",
        .secret = &secret,
    })) == .rejected);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** secret.len), &secret);
    try std.testing.expectEqual(@as(usize, 0), fake.effects);
}

test "typed management validates field transitions before persistence" {
    const Fake = struct {
        fn journal(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn registry(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var parsed = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":4,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\"},\"tools\":[\"read\"]}]}",
        test_limits,
    );
    defer parsed.deinit();
    var management = try ManagementPort.init(std.testing.allocator, parsed.value, .{
        .persistence = .{
            .available = true,
            .commit_journal_fn = Fake.journal,
            .commit_registry_fn = Fake.registry,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .limits = test_limits,
    });
    defer management.deinit();

    try std.testing.expect((try management.prepareRenameServer(3, .{
        .server_id = "remote",
        .display_name = "Stale",
    })) == .rejected);
    try std.testing.expect((try management.prepareRenameServer(4, .{
        .server_id = "remote",
        .display_name = "Remote",
    })) == .unchanged);
    try std.testing.expect((try management.prepareRenameServer(4, .{
        .server_id = "remote",
        .display_name = "Remote\x00hidden",
    })) == .rejected);
    try std.testing.expect((try management.prepareSetAllowedTools(4, .{
        .server_id = "remote",
        .tools = &.{ "read", "read" },
    })) == .rejected);
    try std.testing.expect((try management.prepareSetServerEnabled(4, .{
        .server_id = "missing",
        .enabled = false,
    })) == .rejected);

    var approval = switch (try management.prepareApproveConnection(4, .{
        .server_id = "remote",
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer approval.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&approval),
    );
    const approved_fingerprint = management.desired.?.value.servers[0]
        .connection_approval.?.fingerprint;
    var timeout_update = switch (try management.prepareUpdateHttpConnection(5, .{
        .server_id = "remote",
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 2000,
        .url = "https://mcp.example.test/rpc",
        .auth_mode = .none,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer timeout_update.deinit();
    try std.testing.expectEqualStrings(
        approved_fingerprint,
        timeout_update.target().servers[0].connection_approval.?.fingerprint,
    );
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&timeout_update),
    );
    var endpoint_update = switch (try management.prepareUpdateHttpConnection(6, .{
        .server_id = "remote",
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 2000,
        .url = "https://other.example.test/rpc",
        .auth_mode = .none,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer endpoint_update.deinit();
    try std.testing.expect(
        endpoint_update.target().servers[0].connection_approval != null,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        approved_fingerprint,
        endpoint_update.target().servers[0].connection_approval.?.fingerprint,
    ));
}

test "connection replacement retains static credentials only for the same destination" {
    const Fake = struct {
        fn commit(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .present;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var http_headers = [_]SecretSlotWire{.{
        .name = "Authorization",
        .credential_ref = "secret/http",
    }};
    var stdio_arguments = [_]ValueSourceWire{
        .{ .literal = "--mode" },
        .{ .literal = "safe" },
    };
    var stdio_environment = [_]SecretSlotWire{.{
        .name = "TOKEN",
        .credential_ref = "secret/stdio",
    }};
    var servers = [_]ServerWire{
        .{
            .id = "remote",
            .namespace = "remote",
            .display_name = "Remote",
            .enabled = false,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{
                .kind = "streamable_http",
                .url = "https://mcp.example.test/rpc",
                .headers = &http_headers,
            },
            .auth = .{ .kind = "static", .oauth = null },
            .connection_approval = null,
            .tools = &.{},
        },
        .{
            .id = "local",
            .namespace = "local",
            .display_name = "Local",
            .enabled = false,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{
                .kind = "stdio",
                .command = "/usr/bin/local-mcp",
                .arguments = &stdio_arguments,
                .cwd = "/tmp/workspace",
                .environment = &stdio_environment,
            },
            .auth = .{ .kind = "static", .oauth = null },
            .connection_approval = null,
            .tools = &.{},
        },
    };
    var management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &servers,
    }, .{
        .persistence = .{
            .available = true,
            .commit_journal_fn = Fake.commit,
            .commit_registry_fn = Fake.commit,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .limits = test_limits,
    });
    defer management.deinit();

    var http_same = switch (try management.prepareUpdateHttpConnection(1, .{
        .server_id = "remote",
        .display_name = "Remote renamed",
        .negotiation = "modern_only",
        .timeout_ms = 2000,
        .url = "https://mcp.example.test/rpc",
        .auth_mode = .static,
        .header_names = &.{"Authorization"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer http_same.deinit();
    try std.testing.expectEqualStrings(
        "secret/http",
        http_same.target().servers[0].transport.headers[0].credential_ref.?,
    );
    try std.testing.expectEqual(@as(usize, 0), http_same.plan.transaction.retired_locators.len);

    var http_header_case = switch (try management.prepareUpdateHttpConnection(1, .{
        .server_id = "remote",
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .url = "https://mcp.example.test/rpc",
        .auth_mode = .static,
        .header_names = &.{"authorization"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer http_header_case.deinit();
    try std.testing.expectEqualStrings(
        "secret/http",
        http_header_case.target().servers[0].transport.headers[0].credential_ref.?,
    );

    var http_slot_added = switch (try management.prepareUpdateHttpConnection(1, .{
        .server_id = "remote",
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .url = "https://mcp.example.test/rpc",
        .auth_mode = .static,
        .header_names = &.{ "Authorization", "X-Trace-Token" },
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer http_slot_added.deinit();
    try std.testing.expectEqualStrings(
        "secret/http",
        http_slot_added.target().servers[0].transport.headers[0].credential_ref.?,
    );
    try std.testing.expect(http_slot_added.target().servers[0].transport.headers[1].credential_ref == null);
    try std.testing.expectEqual(@as(usize, 0), http_slot_added.plan.transaction.retired_locators.len);

    var http_slot_renamed = switch (try management.prepareUpdateHttpConnection(1, .{
        .server_id = "remote",
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .url = "https://mcp.example.test/rpc",
        .auth_mode = .static,
        .header_names = &.{"X-Authorization"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer http_slot_renamed.deinit();
    try std.testing.expect(http_slot_renamed.target().servers[0].transport.headers[0].credential_ref == null);
    try std.testing.expectEqual(@as(usize, 1), http_slot_renamed.plan.transaction.retired_locators.len);
    try std.testing.expectEqualStrings(
        "secret/http",
        http_slot_renamed.plan.transaction.retired_locators[0],
    );

    var http_moved = switch (try management.prepareUpdateHttpConnection(1, .{
        .server_id = "remote",
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .url = "https://other.example.test/rpc",
        .auth_mode = .static,
        .header_names = &.{"Authorization"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer http_moved.deinit();
    try std.testing.expect(http_moved.target().servers[0].transport.headers[0].credential_ref == null);
    try std.testing.expectEqual(@as(usize, 1), http_moved.plan.transaction.retired_locators.len);
    try std.testing.expectEqualStrings(
        "secret/http",
        http_moved.plan.transaction.retired_locators[0],
    );

    var stdio_same = switch (try management.prepareUpdateStdioConnection(1, .{
        .server_id = "local",
        .display_name = "Local renamed",
        .negotiation = "compat_only",
        .timeout_ms = 2000,
        .command = "/usr/bin/local-mcp",
        .arguments = &.{ "--mode", "safe" },
        .cwd = "/tmp/workspace",
        .auth_mode = .static,
        .environment_names = &.{"TOKEN"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer stdio_same.deinit();
    try std.testing.expectEqualStrings(
        "secret/stdio",
        stdio_same.target().servers[1].transport.environment[0].credential_ref.?,
    );

    var stdio_environment_case = switch (try management.prepareUpdateStdioConnection(1, .{
        .server_id = "local",
        .display_name = "Local",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .command = "/usr/bin/local-mcp",
        .arguments = &.{ "--mode", "safe" },
        .cwd = "/tmp/workspace",
        .auth_mode = .static,
        .environment_names = &.{"token"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer stdio_environment_case.deinit();
    try std.testing.expect(stdio_environment_case.target().servers[1].transport.environment[0].credential_ref == null);
    try std.testing.expectEqual(@as(usize, 1), stdio_environment_case.plan.transaction.retired_locators.len);

    const changed_stdio_destinations = [_]UpdateStdioConnectionInput{
        .{
            .server_id = "local",
            .display_name = "Local",
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .command = "/usr/bin/other-mcp",
            .arguments = &.{ "--mode", "safe" },
            .cwd = "/tmp/workspace",
            .auth_mode = .static,
            .environment_names = &.{"TOKEN"},
        },
        .{
            .server_id = "local",
            .display_name = "Local",
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .command = "/usr/bin/local-mcp",
            .arguments = &.{ "--mode", "unsafe" },
            .cwd = "/tmp/workspace",
            .auth_mode = .static,
            .environment_names = &.{"TOKEN"},
        },
        .{
            .server_id = "local",
            .display_name = "Local",
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .command = "/usr/bin/local-mcp",
            .arguments = &.{ "--mode", "safe" },
            .cwd = "/tmp/other",
            .auth_mode = .static,
            .environment_names = &.{"TOKEN"},
        },
    };
    for (changed_stdio_destinations) |input| {
        var moved = switch (try management.prepareUpdateStdioConnection(1, input)) {
            .prepared => |prepared| prepared,
            else => return error.TestUnexpectedResult,
        };
        defer moved.deinit();
        try std.testing.expect(moved.target().servers[1].transport.environment[0].credential_ref == null);
        try std.testing.expectEqual(@as(usize, 1), moved.plan.transaction.retired_locators.len);
        try std.testing.expectEqualStrings(
            "secret/stdio",
            moved.plan.transaction.retired_locators[0],
        );
    }
}

test "management port repairs multiple invalid servers one transaction at a time" {
    const Fake = struct {
        registry_commits: usize = 0,

        fn journal(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn registry(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.registry_commits += 1;
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var parsed = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":3,\"servers\":[{\"id\":\"bad-name\",\"namespace\":\"bad_name\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]},{\"id\":\"bad-negotiation\",\"namespace\":\"bad_negotiation\",\"display_name\":\"Broken\",\"enabled\":true,\"negotiation\":\"unsupported\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer parsed.deinit();
    var fake: Fake = .{};
    var management = try ManagementPort.init(std.testing.allocator, parsed.value, .{
        .persistence = .{
            .context = &fake,
            .available = true,
            .commit_journal_fn = Fake.journal,
            .commit_registry_fn = Fake.registry,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .context = &fake,
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .limits = test_limits,
    });
    defer management.deinit();

    var removal = switch (try management.prepareRemoveServer(3, "bad-name")) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer removal.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&removal),
    );
    try std.testing.expectEqual(@as(?u64, 4), management.inspect().desired_generation);
    try std.testing.expectEqual(
        ServerProblem.invalid_negotiation,
        serverProblem(management.desired.?.value.servers[0], test_limits).?,
    );
    var repair = switch (try management.prepareUpdateStdioConnection(4, .{
        .server_id = "bad-negotiation",
        .display_name = "Broken",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .command = "tool",
        .auth_mode = .none,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer repair.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&repair),
    );
    try std.testing.expectEqual(@as(?u64, 5), management.inspect().desired_generation);
    try std.testing.expect(serverProblem(
        management.desired.?.value.servers[0],
        test_limits,
    ) == null);
    try std.testing.expectEqual(@as(usize, 2), fake.registry_commits);
}

test "management port freezes a second mutation after registry outcome uncertainty" {
    const Fake = struct {
        journal_count: usize = 0,

        fn journal(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.journal_count += 1;
            return .committed;
        }
        fn registry(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .outcome_unknown;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var parsed = try decode(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":7,\"servers\":[{\"id\":\"local\",\"namespace\":\"local\",\"display_name\":\"Local\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
        test_limits,
    );
    defer parsed.deinit();
    var fake: Fake = .{};
    var management = try ManagementPort.init(std.testing.allocator, parsed.value, .{
        .persistence = .{
            .context = &fake,
            .available = true,
            .commit_journal_fn = Fake.journal,
            .commit_registry_fn = Fake.registry,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .context = &fake,
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .limits = test_limits,
    });
    defer management.deinit();
    var removal = switch (try management.prepareRemoveServer(7, "local")) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer removal.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.indeterminate,
        try management.commitPreparedMutation(&removal),
    );
    try std.testing.expectEqual(StoreHealth.outcome_unknown, management.inspect().health);
    try std.testing.expect((try management.prepareRemoveServer(7, "local")) == .rejected);
    try std.testing.expectEqual(@as(usize, 1), fake.journal_count);
}

test "saved desired registry becomes effective only through cold-start preparation" {
    const Credentials = struct {
        locator: [64]u8 = undefined,
        locator_len: usize = 0,
        secret: [64]u8 = undefined,
        secret_len: usize = 0,

        fn probe(context: ?*anyopaque, locator: []const u8) CredentialPresence {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.locator_len == 0) return .missing;
            return if (std.mem.eql(u8, self.locator[0..self.locator_len], locator))
                .present
            else
                .missing;
        }
        fn create(context: ?*anyopaque, locator: []const u8, secret: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.locator_len != 0 or locator.len > self.locator.len or
                secret.len > self.secret.len)
                return false;
            @memcpy(self.locator[0..locator.len], locator);
            self.locator_len = locator.len;
            @memcpy(self.secret[0..secret.len], secret);
            self.secret_len = secret.len;
            return true;
        }
        fn delete(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.locator_len == 0) return true;
            if (!std.mem.eql(u8, self.locator[0..self.locator_len], locator))
                return false;
            std.crypto.secureZero(u8, self.secret[0..self.secret_len]);
            self.locator_len = 0;
            self.secret_len = 0;
            return true;
        }
        fn resolve(
            context: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.locator_len == 0 or
                !std.mem.eql(u8, self.locator[0..self.locator_len], locator))
                return .missing;
            return .{ .value = allocator.dupe(
                u8,
                self.secret[0..self.secret_len],
            ) catch return .out_of_memory };
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xcd);
            return true;
        }
        fn effects(self: *@This()) CredentialEffects {
            return .{
                .context = self,
                .available = true,
                .probe_fn = probe,
                .create_fn = create,
                .delete_fn = delete,
            };
        }
    };
    var initial = try prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        test_limits,
    );
    defer initial.deinit();
    try std.testing.expect(initial.generation() == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    defer store.lock_file.close(std.testing.io);
    var credentials: Credentials = .{};
    var management = try ManagementPort.init(std.testing.allocator, null, .{
        .persistence = store.mutationPersistence(),
        .credentials = credentials.effects(),
        .locator_generator = .{ .available = true, .fill_fn = Credentials.fill },
        .identity_generator = .{ .available = true, .fill_fn = Credentials.fill },
        .limits = test_limits,
    });
    defer management.deinit();
    var creation = switch (try management.prepareCreateHttpServer(0, .{
        .display_name = "Remote",
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .url = "https://mcp.example.test/rpc",
        .auth_mode = .static,
        .header_names = &.{"Authorization"},
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer creation.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&creation),
    );
    try std.testing.expectEqual(@as(?u64, 1), management.inspect().desired_generation);
    try std.testing.expectEqual(
        RuntimeAlignment.unknown,
        management.inspect().runtime_alignment,
    );
    const server_id = management.desired.?.value.servers[0].id;
    var secret = [_]u8{ 'c', 'o', 'l', 'd', '-', 's', 't', 'a', 'r', 't' };
    var capture = switch (try management.prepareCaptureStaticSecret(1, .{
        .server_id = server_id,
        .slot_name = "Authorization",
        .secret = &secret,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer capture.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&capture),
    );
    const restored = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(restored);
    var restarted = try prepare(
        std.testing.allocator,
        restored,
        true,
        false,
        .{
            .context = &credentials,
            .available = true,
            .resolve_fn = Credentials.resolve,
        },
        test_limits,
    );
    defer restarted.deinit();
    try std.testing.expectEqual(@as(?u64, 2), restarted.generation());
    try std.testing.expectEqual(PreparationState.available, restarted.state);
    try std.testing.expectEqual(
        ServerPreparationState.eligible,
        restarted.server_states[0],
    );
}

test "management rejects an oversized target before persistence effects" {
    const Fake = struct {
        effects: usize = 0,

        fn journal(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return .committed;
        }
        fn registry(context: ?*anyopaque, _: []const u8) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return .committed;
        }
        fn clear(context: ?*anyopaque) PersistenceEffect {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.effects += 1;
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
        fn fill(_: ?*anyopaque, output: *[16]u8) bool {
            @memset(output, 0xab);
            return true;
        }
    };
    var arguments: [129][]const u8 = undefined;
    @memset(&arguments, "x");
    var fake: Fake = .{};
    var management = try ManagementPort.init(std.testing.allocator, null, .{
        .persistence = .{
            .context = &fake,
            .available = true,
            .commit_journal_fn = Fake.journal,
            .commit_registry_fn = Fake.registry,
            .clear_journal_fn = Fake.clear,
        },
        .credentials = .{
            .available = true,
            .probe_fn = Fake.probe,
            .create_fn = Fake.create,
            .delete_fn = Fake.delete,
        },
        .identity_generator = .{ .available = true, .fill_fn = Fake.fill },
        .limits = test_limits,
    });
    defer management.deinit();
    try std.testing.expect((try management.prepareCreateStdioServer(0, .{
        .display_name = "Large",
        .command = "tool",
        .arguments = &arguments,
    })) == .rejected);
    try std.testing.expectEqual(@as(usize, 0), fake.effects);
}

test "preparation separates disabled invalid missing-auth and eligible servers" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            if (std.mem.eql(u8, locator, "present/token"))
                return .{ .value = allocator.dupe(u8, "credential-value") catch
                    return .out_of_memory };
            return .missing;
        }
    };
    const bytes =
        \\{"schema_version":1,"generation":9,"servers":[{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"}},{"id":"invalid","namespace":"invalid","display_name":"Invalid","enabled":true,"negotiation":"automatic","timeout_ms":0,"transport":{"kind":"stdio","command":"tool"}},{"id":"missing","namespace":"missing","display_name":"Missing","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"credential_ref":"missing/token"}}]}},{"id":"ready","namespace":"ready","display_name":"Ready","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"credential_ref":"present/token"}}]}}]}
    ;
    const current = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current);
    var prepared = try prepare(
        std.testing.allocator,
        current,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.state == .available);
    try std.testing.expect(prepared.server_states[0] == .disabled);
    try std.testing.expectEqual(
        ServerProblem.invalid_timeout,
        prepared.server_states[1].invalid_catalog,
    );
    try std.testing.expect(prepared.server_states[2] == .needs_authentication);
    try std.testing.expect(prepared.server_states[3] == .eligible);
    try std.testing.expectEqual(@as(usize, 1), prepared.credentials.len);
    try std.testing.expectEqualStrings("present/token", prepared.credentials[0].locator);
    try std.testing.expectEqualStrings("credential-value", prepared.credentials[0].secret);
}

test "preparation classifies an empty static slot without reading credentials" {
    const Resolver = struct {
        calls: usize = 0,

        fn resolve(
            context: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) CredentialResolution {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return .unavailable;
        }
    };
    const legacy =
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/rpc\",\"headers\":[{\"name\":\"Authorization\",\"value\":{\"literal\":\"must-not-migrate\"}}]},\"tools\":[]}] }";
    const migrated = try approvedSchema2TestBytes(std.testing.allocator, legacy);
    defer std.testing.allocator.free(migrated);
    var resolver: Resolver = .{};
    var preparation = try prepare(
        std.testing.allocator,
        migrated,
        true,
        false,
        .{
            .context = &resolver,
            .available = true,
            .resolve_fn = Resolver.resolve,
        },
        test_limits,
    );
    defer preparation.deinit();
    try std.testing.expectEqual(PreparationState.available, preparation.state);
    try std.testing.expectEqual(
        ServerPreparationState.needs_authentication,
        preparation.server_states[0],
    );
    try std.testing.expectEqual(@as(usize, 0), resolver.calls);
    try std.testing.expect(preparation.registry.?.value.servers[0].transport.headers[0].credential_ref == null);
}

test "preparation rejects unusable or over-capacity credentials per server" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            const value: []const u8 = if (std.mem.eql(u8, locator, "unsafe/header"))
                "bad\r\nheader"
            else if (std.mem.eql(u8, locator, "unsafe/environment"))
                "bad\x00environment"
            else if (std.mem.eql(u8, locator, "large/one"))
                "1234"
            else if (std.mem.eql(u8, locator, "large/two"))
                "5678"
            else
                return .missing;
            return .{ .value = allocator.dupe(u8, value) catch return .out_of_memory };
        }
    };
    const registry =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"unsafe-http","namespace":"unsafe_http","display_name":"Unsafe HTTP","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"unsafe/header"}}]}},{"id":"unsafe-env","namespace":"unsafe_env","display_name":"Unsafe env","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"TOKEN","value":{"credential_ref":"unsafe/environment"}}]}},{"id":"too-large","namespace":"too_large","display_name":"Too large","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"ONE","value":{"credential_ref":"large/one"}},{"name":"TWO","value":{"credential_ref":"large/two"}}]}},{"id":"ready","namespace":"ready","display_name":"Ready","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"}}]}
    ;
    const current = try approvedSchema2TestBytes(std.testing.allocator, registry);
    defer std.testing.allocator.free(current);
    var limits = test_limits;
    limits.max_runtime_secret_bytes_per_server = 6;
    var prepared = try prepare(
        std.testing.allocator,
        current,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        limits,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.server_states[0] == .needs_authentication);
    try std.testing.expect(prepared.server_states[1] == .needs_authentication);
    try std.testing.expectEqual(
        ServerProblem.credential_capacity_exceeded,
        prepared.server_states[2].invalid_catalog,
    );
    try std.testing.expect(prepared.server_states[3] == .eligible);
    try std.testing.expectEqual(@as(usize, 0), prepared.credentials.len);
}

test "preparation classifies unsafe disabled server facts before projection" {
    const registry =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"disabled","namespace":"disabled","display_name":"Unsafe\nname","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"},"tools":[]}]}
    ;
    var prepared = try prepare(
        std.testing.allocator,
        registry,
        true,
        false,
        .{},
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expectEqual(
        ServerProblem.invalid_display_name,
        prepared.server_states[0].invalid_catalog,
    );
}

test "preparation keeps ordinary MCP empty or eligible without credential services" {
    var empty = try prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        test_limits,
    );
    defer empty.deinit();
    try std.testing.expect(empty.state == .empty);

    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"local","namespace":"local","display_name":"Local","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","arguments":[{"literal":"--safe"}]}}]}
    ;
    const current = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current);
    var local = try prepare(
        std.testing.allocator,
        current,
        true,
        false,
        .{},
        test_limits,
    );
    defer local.deinit();
    try std.testing.expect(local.state == .available);
    try std.testing.expect(local.server_states[0] == .eligible);
}

test "preparation makes credential backend failure globally unavailable" {
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"remote/token"}}]}}]}
    ;
    const current = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current);
    var prepared = try prepare(
        std.testing.allocator,
        current,
        true,
        false,
        .{},
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expectEqual(
        UnavailableReason.credential_store_unavailable,
        prepared.state.unavailable,
    );
    try std.testing.expectEqual(@as(?u64, null), prepared.generation());
}

test "preparation keeps resolver allocation failure fatal" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) CredentialResolution {
            return .out_of_memory;
        }
    };
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"remote/token"}}]}}]}
    ;
    const current = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current);
    try std.testing.expectError(
        error.OutOfMemory,
        prepare(
            std.testing.allocator,
            current,
            true,
            false,
            .{ .available = true, .resolve_fn = Resolver.resolve },
            test_limits,
        ),
    );
}

test "preparation does not retain partial credentials for ineligible servers" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            locator: []const u8,
        ) CredentialResolution {
            if (std.mem.eql(u8, locator, "present/token"))
                return .{ .value = allocator.dupe(u8, "must-not-remain") catch
                    return .out_of_memory };
            return .missing;
        }
    };
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"partial","namespace":"partial","display_name":"Partial","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool","environment":[{"name":"FIRST","value":{"credential_ref":"present/token"}},{"name":"SECOND","value":{"credential_ref":"missing/token"}}]}}]}
    ;
    const current = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current);
    var prepared = try prepare(
        std.testing.allocator,
        current,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.server_states[0] == .needs_authentication);
    try std.testing.expectEqual(@as(usize, 0), prepared.credentials.len);
}

fn expectRuntimeAlignment(
    manifest: *const RuntimeManifest,
    bytes: []const u8,
    expected: RuntimeAlignment,
) !void {
    const current = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current);
    var desired = try decode(std.testing.allocator, current, test_limits);
    defer desired.deinit();
    try std.testing.expectEqual(expected, manifest.alignment(desired.value, test_limits));
}

test "runtime manifest derives compatibility from loaded and absence proofs" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) CredentialResolution {
            return .missing;
        }
    };
    const startup =
        \\{"schema_version":1,"generation":7,"servers":[
        \\{"id":"loaded","namespace":"loaded","display_name":"Loaded","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://loaded.example.test/rpc"},"tools":["read"]},
        \\{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://disabled.example.test/rpc"}},
        \\{"id":"invalid","namespace":"invalid","display_name":"","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://invalid.example.test/rpc"}},
        \\{"id":"missing","namespace":"missing","display_name":"Missing","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://missing.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"missing/token"}}]}}
        \\]}
    ;
    const current_startup = try approvedSchema2TestBytes(
        std.testing.allocator,
        startup,
    );
    defer std.testing.allocator.free(current_startup);
    var preparation = try prepare(
        std.testing.allocator,
        current_startup,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer preparation.deinit();
    var manifest = (try RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    defer manifest.deinit();

    try expectRuntimeAlignment(&manifest, startup, .current);
    var approval_removed = try decode(
        std.testing.allocator,
        current_startup,
        test_limits,
    );
    defer approval_removed.deinit();
    approval_removed.value.servers[0].connection_approval = null;
    try std.testing.expectEqual(
        RuntimeAlignment.restart_required,
        manifest.alignment(approval_removed.value, test_limits),
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":8,"servers":[{"id":"loaded","namespace":"loaded","display_name":"Renamed","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://loaded.example.test/rpc"},"tools":["read","write"]},{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"modern_only","timeout_ms":5000,"transport":{"kind":"streamable_http","url":"https://other.example.test/rpc"}},{"id":"missing","namespace":"missing","display_name":"Renamed missing","enabled":true,"negotiation":"modern_only","timeout_ms":5000,"transport":{"kind":"streamable_http","url":"https://changed.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"missing/token"}}]}},{"id":"new-disabled","namespace":"new_disabled","display_name":"New disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://new.example.test/rpc"}}]}
    ,
        .current,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":8,"servers":[{"id":"loaded","namespace":"loaded","display_name":"Loaded","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://changed.example.test/rpc"}}]}
    ,
        .restart_required,
    );
    try expectRuntimeAlignment(&manifest, startup, .current);
}

test "runtime manifest rejects enabled additions and invalidated absence proofs" {
    const Resolver = struct {
        fn resolve(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
        ) CredentialResolution {
            return .missing;
        }
    };
    const startup =
        \\{"schema_version":1,"generation":3,"servers":[{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://disabled.example.test/rpc"}},{"id":"invalid","namespace":"invalid","display_name":"","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://invalid.example.test/rpc"}},{"id":"missing","namespace":"missing","display_name":"Missing","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://missing.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"missing/token"}}]}}]}
    ;
    const current_startup = try approvedSchema2TestBytes(
        std.testing.allocator,
        startup,
    );
    defer std.testing.allocator.free(current_startup);
    var preparation = try prepare(
        std.testing.allocator,
        current_startup,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer preparation.deinit();
    var manifest = (try RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    defer manifest.deinit();

    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[]}
    ,
        .current,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[{"id":"invalid","namespace":"invalid","display_name":"Still invalid","enabled":true,"negotiation":"unsupported","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://changed.example.test/rpc"}}]}
    ,
        .current,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://disabled.example.test/rpc"}}]}
    ,
        .restart_required,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[{"id":"invalid","namespace":"invalid","display_name":"Fixed","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://invalid.example.test/rpc"}}]}
    ,
        .restart_required,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[{"id":"missing","namespace":"missing","display_name":"Missing","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://changed.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"missing/token"}}]}}]}
    ,
        .current,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[{"id":"missing","namespace":"missing","display_name":"Missing","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://changed.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"other/token"}}]}}]}
    ,
        .restart_required,
    );
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":4,"servers":[{"id":"new","namespace":"new","display_name":"New","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://new.example.test/rpc"}}]}
    ,
        .restart_required,
    );
}

test "runtime manifest is unavailable when preparation facts are unavailable" {
    var preparation = try prepare(
        std.testing.allocator,
        null,
        false,
        false,
        .{},
        test_limits,
    );
    defer preparation.deinit();
    try std.testing.expect((try RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )) == null);
}

test "runtime manifest proves a successfully prepared empty runtime" {
    var preparation = try prepare(
        std.testing.allocator,
        null,
        true,
        false,
        .{},
        test_limits,
    );
    defer preparation.deinit();
    var manifest = (try RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    defer manifest.deinit();
    try std.testing.expectEqual(@as(usize, 0), manifest.entries.len);
    try std.testing.expectEqual(
        RuntimeAlignment.current,
        manifest.alignment(null, test_limits),
    );
    const enabled_bytes = try approvedSchema2TestBytes(
        std.testing.allocator,
        "{\"schema_version\":1,\"generation\":1,\"servers\":[{\"id\":\"new\",\"namespace\":\"new\",\"display_name\":\"New\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://new.example.test/mcp\"}}]}",
    );
    defer std.testing.allocator.free(enabled_bytes);
    var enabled = try decode(std.testing.allocator, enabled_bytes, test_limits);
    defer enabled.deinit();
    try std.testing.expectEqual(
        RuntimeAlignment.restart_required,
        manifest.alignment(enabled.value, test_limits),
    );
}

test "runtime manifest candidate stays unpublished until ownership commit" {
    const bytes =
        \\{"schema_version":1,"generation":2,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://remote.example.test/rpc"}}]}
    ;
    const current_bytes = try approvedSchema2TestBytes(std.testing.allocator, bytes);
    defer std.testing.allocator.free(current_bytes);
    var preparation = try prepare(
        std.testing.allocator,
        current_bytes,
        true,
        false,
        .{},
        test_limits,
    );
    defer preparation.deinit();

    var abandoned = (try RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    abandoned.deinit();
    var unknown = try ManagementPort.init(
        std.testing.allocator,
        preparation.registry.?.value,
        .{
            .persistence = .{},
            .credentials = .{},
            .limits = test_limits,
        },
    );
    defer unknown.deinit();
    try std.testing.expectEqual(
        RuntimeAlignment.unknown,
        unknown.inspect().runtime_alignment,
    );

    var committed = (try RuntimeManifest.candidate(
        std.testing.allocator,
        &preparation,
    )).?;
    var current = try ManagementPort.init(
        std.testing.allocator,
        preparation.registry.?.value,
        .{
            .persistence = .{},
            .credentials = .{},
            .limits = test_limits,
            .runtime_manifest = &committed,
        },
    );
    defer current.deinit();
    try std.testing.expectEqual(
        RuntimeAlignment.current,
        current.inspect().runtime_alignment,
    );
}

test "schema 1 migration preserves identity but disables and unapproves every server" {
    const bytes =
        \\{"schema_version":1,"generation":7,"servers":[{"id":"local","namespace":"local","display_name":"Local","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"},"tools":["read"]},{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"modern_only","timeout_ms":2000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/mcp","headers":[{"name":"Authorization","value":{"credential_ref":"remote/token"}}]}}]}
    ;
    var migrated = try decode(std.testing.allocator, bytes, test_limits);
    defer migrated.deinit();
    try std.testing.expectEqual(schema_version, migrated.value.schema_version);
    try std.testing.expectEqual(@as(u64, 7), migrated.value.generation);
    try std.testing.expect(migrated.value.oauth_operation == null);
    try std.testing.expectEqual(@as(usize, 2), migrated.value.servers.len);
    try std.testing.expectEqualStrings("local", migrated.value.servers[0].id);
    try std.testing.expect(!migrated.value.servers[0].enabled);
    try std.testing.expect(migrated.value.servers[0].connection_approval == null);
    try std.testing.expectEqualStrings("none", migrated.value.servers[0].auth.kind);
    try std.testing.expectEqualStrings("read", migrated.value.servers[0].tools[0]);
    try std.testing.expect(!migrated.value.servers[1].enabled);
    try std.testing.expect(migrated.value.servers[1].connection_approval == null);
    try std.testing.expectEqualStrings("static", migrated.value.servers[1].auth.kind);
    try std.testing.expectEqualStrings(
        "remote/token",
        migrated.value.servers[1].transport.headers[0].credential_ref.?,
    );
}

test "schema 2 codec rejects unknown fields and inconsistent auth state" {
    try std.testing.expectError(
        error.RegistryCorrupt,
        decode(
            std.testing.allocator,
            "{\"schema_version\":2,\"generation\":1,\"oauth_operation\":null,\"servers\":[],\"extra\":true}",
            test_limits,
        ),
    );
    var parsed = try decode(
        std.testing.allocator,
        "{\"schema_version\":2,\"generation\":1,\"oauth_operation\":null,\"servers\":[{\"id\":\"remote\",\"namespace\":\"remote\",\"display_name\":\"Remote\",\"enabled\":false,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"streamable_http\",\"url\":\"https://mcp.example.test/mcp\",\"headers\":[{\"name\":\"Authorization\",\"credential_ref\":\"remote/token\"}]},\"auth\":{\"kind\":\"none\",\"oauth\":null},\"connection_approval\":null,\"tools\":[]}]}",
        test_limits,
    );
    defer parsed.deinit();
    try std.testing.expectEqual(
        ServerProblem.invalid_authentication,
        serverProblem(parsed.value.servers[0], test_limits).?,
    );
}

test "connection approval fingerprint binds only executable connection facts" {
    var headers = [_]SecretSlotWire{.{
        .name = "Authorization",
        .credential_ref = "secret/one",
    }};
    const base: ServerWire = .{
        .id = "remote",
        .namespace = "remote",
        .display_name = "Remote",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
            .headers = &headers,
        },
        .auth = .{ .kind = "static", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    const fingerprint = connectionFingerprint(base);
    var presentation_change = base;
    presentation_change.display_name = "Renamed";
    presentation_change.enabled = true;
    presentation_change.timeout_ms = 2000;
    try std.testing.expectEqual(
        fingerprint,
        connectionFingerprint(presentation_change),
    );
    var changed_headers = [_]SecretSlotWire{.{
        .name = "Authorization",
        .credential_ref = "secret/two",
    }};
    var secret_rotation = base;
    secret_rotation.transport.headers = &changed_headers;
    try std.testing.expectEqual(fingerprint, connectionFingerprint(secret_rotation));
    var endpoint_change = base;
    endpoint_change.transport.url = "https://other.example.test/mcp";
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint,
        &connectionFingerprint(endpoint_change),
    ));
    var approved = base;
    approved.connection_approval = .{ .fingerprint = &fingerprint };
    approved.transport.url = "https://other.example.test/mcp";
    try std.testing.expectEqual(
        ServerProblem.invalid_connection_approval,
        serverProblem(approved, test_limits).?,
    );
}

test "OAuth consent fingerprint binds registration and authorization facts" {
    var server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "consent_required",
            .registration = .{
                .kind = "pre_registered",
                .issuer = "https://issuer.example.test",
                .client_id = "client-one",
                .token_endpoint_auth_method = "none",
                .client_credential_revision = 1,
                .client_secret_ref = null,
            },
            .consent = null,
            .grant = null,
        } },
        .connection_approval = null,
        .tools = &.{},
    };
    const scopes = [_][]const u8{ "files.read", "files.write" };
    var consent: OauthConsentWire = .{
        .epoch = 1,
        .fingerprint = "unused",
        .resource = "https://mcp.example.test/mcp",
        .issuer = "https://issuer.example.test",
        .scopes = &scopes,
        .redirect_uri = "http://127.0.0.1:43123/callback",
        .client_credential_revision = 1,
    };
    const fingerprint = oauthConsentFingerprint(server, consent).?;
    var oauth = server.auth.oauth.?;
    oauth.registration.client_credential_revision = 2;
    server.auth.oauth = oauth;
    consent.client_credential_revision = 2;
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint,
        &oauthConsentFingerprint(server, consent).?,
    ));
    oauth.registration.client_credential_revision = 1;
    server.auth.oauth = oauth;
    consent.client_credential_revision = 1;
    oauth.registration.client_id = "client-two";
    server.auth.oauth = oauth;
    try std.testing.expect(!std.mem.eql(
        u8,
        &fingerprint,
        &oauthConsentFingerprint(server, consent).?,
    ));
}

test "OAuth operation marker keeps generation and serializes only its server" {
    var oauth_server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "client_registration_required",
            .registration = .{
                .kind = "dynamic_registration",
                .issuer = null,
                .client_id = null,
                .token_endpoint_auth_method = null,
                .client_credential_revision = 0,
                .client_secret_ref = null,
            },
            .consent = null,
            .grant = null,
        } },
        .connection_approval = null,
        .tools = &.{},
    };
    const connection = connectionFingerprint(oauth_server);
    oauth_server.connection_approval = .{ .fingerprint = &connection };
    const other: ServerWire = .{
        .id = "other",
        .namespace = "other",
        .display_name = "Other",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "stdio", .command = "tool" },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    var servers = [_]ServerWire{ oauth_server, other };
    const base: RegistryWire = .{
        .schema_version = schema_version,
        .generation = 4,
        .oauth_operation = null,
        .servers = &servers,
    };
    const draft: OauthConsentDraftWire = .{
        .resource = "https://mcp.example.test/mcp",
        .issuer = "https://issuer.example.test",
        .scopes = &.{"files.read"},
        .redirect_uri = "http://127.0.0.1:43123/callback",
    };
    const draft_fingerprint = oauthConsentDraftFingerprint(oauth_server, 1, draft).?;
    const operation: OauthOperationWire = .{
        .id = "operation-1",
        .kind = "dynamic_registration",
        .server_id = "oauth",
        .connection_fingerprint = &connection,
        .consent_fingerprint = &draft_fingerprint,
        .consent_epoch = 1,
        .token_revision = null,
        .consent_draft = draft,
    };
    var begin = try planBeginOauthOperation(
        std.testing.allocator,
        base,
        4,
        operation,
        test_limits,
    );
    defer begin.deinit();
    try std.testing.expectEqual(@as(u64, 4), (try begin.targetRegistry()).generation);

    const marked = try begin.targetRegistry();
    try std.testing.expectError(
        error.InvalidMutation,
        planMutation(
            std.testing.allocator,
            marked,
            .{
                .schema_version = schema_version,
                .generation = 5,
                .oauth_operation = null,
                .servers = marked.servers,
            },
            4,
            &.{},
            test_limits,
        ),
    );
    var same_server_changed = oauth_server;
    same_server_changed.display_name = "Changed";
    var blocked_servers = [_]ServerWire{ same_server_changed, other };
    try std.testing.expectError(
        error.InvalidMutation,
        planMutation(
            std.testing.allocator,
            marked,
            .{
                .schema_version = schema_version,
                .generation = 5,
                .oauth_operation = marked.oauth_operation,
                .servers = &blocked_servers,
            },
            4,
            &.{},
            test_limits,
        ),
    );
    var other_changed = other;
    other_changed.display_name = "Other renamed";
    var allowed_servers = [_]ServerWire{ oauth_server, other_changed };
    var allowed = (try planMutation(
        std.testing.allocator,
        marked,
        .{
            .schema_version = schema_version,
            .generation = 5,
            .oauth_operation = marked.oauth_operation,
            .servers = &allowed_servers,
        },
        4,
        &.{},
        test_limits,
    )).?;
    allowed.deinit();
    var clear = try planClearOauthOperation(
        std.testing.allocator,
        marked,
        4,
        "operation-1",
        test_limits,
    );
    defer clear.deinit();
    try std.testing.expectEqual(@as(u64, 4), (try clear.targetRegistry()).generation);
    try std.testing.expect((try clear.targetRegistry()).oauth_operation == null);
}

test "OAuth operation recovery retires grant locators and never replays" {
    var server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "consent_required",
            .registration = .{
                .kind = "pre_registered",
                .issuer = "https://issuer.example.test",
                .client_id = "client",
                .token_endpoint_auth_method = "none",
                .client_credential_revision = 1,
                .client_secret_ref = null,
            },
            .consent = null,
            .grant = null,
        } },
        .connection_approval = null,
        .tools = &.{},
    };
    const connection = connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &connection };
    const scopes = [_][]const u8{"files.read"};
    var consent: OauthConsentWire = .{
        .epoch = 3,
        .fingerprint = "unused",
        .resource = "https://mcp.example.test/mcp",
        .issuer = "https://issuer.example.test",
        .scopes = &scopes,
        .redirect_uri = "http://127.0.0.1:43123/callback",
        .client_credential_revision = 1,
    };
    const consent_fingerprint = oauthConsentFingerprint(server, consent).?;
    consent.fingerprint = &consent_fingerprint;
    var oauth = server.auth.oauth.?;
    oauth.status = "ready";
    oauth.consent = consent;
    oauth.grant = .{
        .consent_epoch = 3,
        .token_revision = 8,
        .access_token_ref = "oauth/access-8",
        .refresh_token_ref = "oauth/refresh-8",
        .expires_at_unix_ms = null,
    };
    server.auth.oauth = oauth;
    const operation: OauthOperationWire = .{
        .id = "refresh-9",
        .kind = "refresh",
        .server_id = "oauth",
        .connection_fingerprint = &connection,
        .consent_fingerprint = &consent_fingerprint,
        .consent_epoch = 3,
        .token_revision = 8,
    };
    var servers = [_]ServerWire{server};
    const registry: RegistryWire = .{
        .schema_version = schema_version,
        .generation = 11,
        .oauth_operation = operation,
        .servers = &servers,
    };
    var recovery = try planOauthOperationRecovery(
        std.testing.allocator,
        registry,
        test_limits,
    );
    defer recovery.deinit();
    const target = try recovery.targetRegistry();
    try std.testing.expectEqual(@as(u64, 12), target.generation);
    try std.testing.expect(target.oauth_operation == null);
    try std.testing.expectEqualStrings(
        "reauth_required",
        target.servers[0].auth.oauth.?.status,
    );
    try std.testing.expect(target.servers[0].auth.oauth.?.grant == null);
    try std.testing.expectEqual(@as(usize, 2), recovery.transaction.retired_locators.len);
    try std.testing.expect(containsText(
        recovery.transaction.retired_locators,
        "oauth/access-8",
    ));
    try std.testing.expect(containsText(
        recovery.transaction.retired_locators,
        "oauth/refresh-8",
    ));

    const Effects = struct {
        deleted: usize = 0,

        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        fn delete(context: ?*anyopaque, locator: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, locator, "oauth/access-8") or
                std.mem.eql(u8, locator, "oauth/refresh-8"))
                self.deleted += 1;
            return true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{
        .read = true,
        .truncate = false,
    });
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    defer store.lock_file.close(std.testing.io);
    var registry_buffer: [max_store_bytes]u8 = undefined;
    try store.commit(try encode(&registry_buffer, registry, test_limits));
    var effects: Effects = .{};
    var coordinator: TransactionCoordinator = .{};
    try std.testing.expectEqual(
        MutationCommit.saved,
        try coordinator.commit(
            std.testing.allocator,
            store.mutationPersistence(),
            .{
                .context = &effects,
                .available = true,
                .probe_fn = Effects.probe,
                .create_fn = Effects.create,
                .delete_fn = Effects.delete,
            },
            &recovery,
            &.{},
            test_limits,
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), effects.deleted);
    try std.testing.expect((try store.loadTransactionAlloc(std.testing.allocator)) == null);
    const stored_bytes = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(stored_bytes);
    var stored = try decode(std.testing.allocator, stored_bytes, test_limits);
    defer stored.deinit();
    try std.testing.expectEqual(@as(u64, 12), stored.value.generation);
    try std.testing.expect(stored.value.oauth_operation == null);
    try std.testing.expectEqualStrings(
        "reauth_required",
        stored.value.servers[0].auth.oauth.?.status,
    );
}

test "runtime OAuth rejection retires the grant without invalidating its loaded descriptor" {
    const Effects = struct {
        fn commit(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .present;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = true,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = .{ .kind = "oauth", .oauth = .{
            .status = "ready",
            .registration = .{
                .kind = "pre_registered",
                .issuer = "https://auth.example.test",
                .client_id = "client",
                .token_endpoint_auth_method = "none",
                .client_credential_revision = 1,
                .client_secret_ref = null,
            },
            .consent = .{
                .epoch = 3,
                .fingerprint = "pending",
                .resource = "https://mcp.example.test/mcp",
                .issuer = "https://auth.example.test",
                .scopes = &.{"files.read"},
                .redirect_uri = "http://127.0.0.1:49152/auth/callback",
                .client_credential_revision = 1,
            },
            .grant = .{
                .consent_epoch = 3,
                .token_revision = 8,
                .access_token_ref = "oauth/access-8",
                .refresh_token_ref = "oauth/refresh-8",
                .expires_at_unix_ms = null,
            },
        } },
        .connection_approval = null,
        .tools = &.{"files.read"},
    };
    const approval = connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &approval };
    const consent_fingerprint = oauthConsentFingerprint(
        server,
        server.auth.oauth.?.consent.?,
    ).?;
    server.auth.oauth.?.consent.?.fingerprint = &consent_fingerprint;
    var servers = [_]ServerWire{server};
    const registry: RegistryWire = .{
        .schema_version = schema_version,
        .generation = 4,
        .oauth_operation = null,
        .servers = &servers,
    };
    var management = try ManagementPort.init(
        std.testing.allocator,
        registry,
        .{
            .persistence = .{
                .available = true,
                .commit_journal_fn = Effects.commit,
                .commit_registry_fn = Effects.commit,
                .clear_journal_fn = Effects.clear,
            },
            .credentials = .{
                .available = true,
                .probe_fn = Effects.probe,
                .create_fn = Effects.create,
                .delete_fn = Effects.delete,
            },
            .limits = test_limits,
        },
    );
    defer management.deinit();
    var preparation = try management.prepareRequireOauthReauthorization(4, .{
        .server_id = "oauth",
        .consent_epoch = 3,
        .token_revision = 8,
    });
    defer switch (preparation) {
        .prepared => |*mutation| mutation.deinit(),
        .unchanged, .rejected => {},
    };
    try std.testing.expect(preparation == .prepared);
    const target = preparation.prepared.target();
    try std.testing.expectEqualStrings(
        "reauth_required",
        target.servers[0].auth.oauth.?.status,
    );
    try std.testing.expect(target.servers[0].auth.oauth.?.grant == null);
    try std.testing.expectEqual(@as(usize, 2), preparation.prepared.plan.transaction.retired_locators.len);
    var entries = [_]RuntimeManifestEntry{.{ .id = "oauth", .state = .{ .loaded = runtimeDescriptorFingerprint(server) } }};
    const manifest: RuntimeManifest = .{ .allocator = std.testing.allocator, .entries = &entries };
    try std.testing.expectEqual(.remove, manifest.targetFor("oauth", target, test_limits).?.kind);
    entries[0].task_references = 1;
    try std.testing.expect(manifest.targetFor("oauth", target, test_limits) == null);
    var awaiting_servers = [_]ServerWire{target.servers[0]};
    awaiting_servers[0].auth.oauth.?.status = "awaiting_tokens";
    var awaiting_registry = target;
    awaiting_registry.servers = &awaiting_servers;
    try std.testing.expect(manifest.targetFor("oauth", awaiting_registry, test_limits) == null);
    entries[0].task_references = 0;
    try std.testing.expectEqual(.remove, manifest.targetFor("oauth", awaiting_registry, test_limits).?.kind);
}

test "typed OAuth management commits consent marker and fresh token locators" {
    const Harness = struct {
        entropy: u8 = 0,

        fn fill(context: ?*anyopaque, output: *[16]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.entropy +%= 1;
            @memset(output, self.entropy);
            return true;
        }

        fn commit(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }

        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }

        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }

        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }

        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var harness: Harness = .{};
    var server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = oauthAuth(.{ .pre_registered = .{
            .client_id = "client",
            .token_endpoint_auth_method = "none",
        } }),
        .connection_approval = null,
        .tools = &.{},
    };
    const connection = connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &connection };
    var servers = [_]ServerWire{server};
    var management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 1,
        .oauth_operation = null,
        .servers = &servers,
    }, .{
        .persistence = .{
            .context = &harness,
            .available = true,
            .commit_journal_fn = Harness.commit,
            .commit_registry_fn = Harness.commit,
            .clear_journal_fn = Harness.clear,
        },
        .credentials = .{
            .context = &harness,
            .available = true,
            .probe_fn = Harness.probe,
            .create_fn = Harness.create,
            .delete_fn = Harness.delete,
        },
        .locator_generator = .{
            .context = &harness,
            .available = true,
            .fill_fn = Harness.fill,
        },
        .identity_generator = .{
            .context = &harness,
            .available = true,
            .fill_fn = Harness.fill,
        },
        .limits = test_limits,
    });
    defer management.deinit();
    var consent = switch (try management.prepareOauthConsent(1, .{
        .server_id = "oauth",
        .resource = "https://mcp.example.test/mcp",
        .issuer = "https://issuer.example.test",
        .scopes = &.{ "files.read", "files.write" },
        .redirect_uri = "http://127.0.0.1:43123/auth/callback",
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer consent.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&consent),
    );
    var begin = switch (try management.prepareBeginCodeExchange(2, .{
        .server_id = "oauth",
    })) {
        .prepared => |prepared| prepared,
        .rejected => return error.TestUnexpectedResult,
    };
    defer begin.deinit();
    try std.testing.expectEqual(@as(u64, 2), begin.target().generation);
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedOperationState(&begin),
    );
    const operation_id = management.desiredRegistry().?.oauth_operation.?.id;
    var access = [_]u8{ 'a', 'c', 'c', 'e', 's', 's' };
    var refresh = [_]u8{ 'r', 'e', 'f', 'r', 'e', 's', 'h' };
    var tokens = switch (try management.prepareCompleteCodeExchange(.{
        .operation_id = operation_id,
        .server_id = "oauth",
        .access_token = &access,
        .refresh_token = &refresh,
        .expires_at_unix_ms = 9000,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer tokens.deinit();
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &access);
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0)), &refresh);
    try std.testing.expectEqual(@as(usize, 2), tokens.candidates.len);
    try std.testing.expect(tokens.target().oauth_operation == null);
    try std.testing.expectEqualStrings(
        "ready",
        tokens.target().servers[0].auth.oauth.?.status,
    );
}

test "dynamic registration marker durably binds draft before issued identity" {
    const Entropy = struct {
        value: u8 = 0,

        fn fill(context: ?*anyopaque, output: *[16]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.value +%= 1;
            @memset(output, self.value);
            return true;
        }
    };
    var entropy: Entropy = .{};
    var server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = oauthAuth(.dynamic_registration),
        .connection_approval = null,
        .tools = &.{},
    };
    const connection = connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &connection };
    const other: ServerWire = .{
        .id = "other",
        .namespace = "other",
        .display_name = "Other",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "stdio", .command = "tool" },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    var servers = [_]ServerWire{ server, other };
    var management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 3,
        .oauth_operation = null,
        .servers = &servers,
    }, .{
        .persistence = .{ .available = true },
        .credentials = .{ .available = true },
        .locator_generator = .{
            .context = &entropy,
            .available = true,
            .fill_fn = Entropy.fill,
        },
        .identity_generator = .{
            .context = &entropy,
            .available = true,
            .fill_fn = Entropy.fill,
        },
        .limits = test_limits,
    });
    defer management.deinit();
    var begin = switch (try management.prepareBeginDynamicRegistration(3, .{
        .consent = .{
            .server_id = "oauth",
            .resource = "https://mcp.example.test/mcp",
            .issuer = "https://issuer.example.test",
            .scopes = &.{"files.read"},
            .redirect_uri = "http://127.0.0.1:43123/auth/callback",
        },
    })) {
        .prepared => |prepared| prepared,
        .rejected => return error.TestUnexpectedResult,
    };
    defer begin.deinit();
    const marked = begin.target();
    const operation = marked.oauth_operation.?;
    try std.testing.expectEqual(@as(u64, 3), marked.generation);
    try std.testing.expect(operation.consent_draft != null);
    var other_changed = marked.servers[1];
    other_changed.display_name = "Other renamed concurrently";
    var current_servers = [_]ServerWire{ marked.servers[0], other_changed };
    var marked_management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 4,
        .oauth_operation = operation,
        .servers = &current_servers,
    }, .{
        .persistence = .{ .available = true },
        .credentials = .{ .available = true },
        .locator_generator = .{
            .context = &entropy,
            .available = true,
            .fill_fn = Entropy.fill,
        },
        .identity_generator = .{
            .context = &entropy,
            .available = true,
            .fill_fn = Entropy.fill,
        },
        .limits = test_limits,
    });
    defer marked_management.deinit();
    var secret = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var completed = switch (try marked_management.prepareCompleteDynamicRegistration(.{
        .operation_id = operation.id,
        .server_id = "oauth",
        .client_id = "issued-client",
        .token_endpoint_auth_method = "client_secret_basic",
        .client_secret = &secret,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer completed.deinit();
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &secret);
    try std.testing.expectEqual(@as(u64, 5), completed.target().generation);
    try std.testing.expectEqualStrings(
        "Other renamed concurrently",
        completed.target().servers[1].display_name,
    );
    const target_oauth = completed.target().servers[0].auth.oauth.?;
    try std.testing.expectEqualStrings("awaiting_tokens", target_oauth.status);
    try std.testing.expectEqualStrings(
        "https://issuer.example.test",
        target_oauth.registration.issuer.?,
    );
    try std.testing.expect(target_oauth.consent != null);

    var recovered_server = server;
    var recovered_auth = recovered_server.auth;
    var recovered_oauth = recovered_auth.oauth.?;
    recovered_oauth.status = "reauth_required";
    recovered_auth.oauth = recovered_oauth;
    recovered_server.auth = recovered_auth;
    var recovered_servers = [_]ServerWire{recovered_server};
    var recovered_management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 9,
        .oauth_operation = null,
        .servers = &recovered_servers,
    }, .{
        .persistence = .{ .available = true },
        .credentials = .{ .available = true },
        .identity_generator = .{
            .context = &entropy,
            .available = true,
            .fill_fn = Entropy.fill,
        },
        .limits = test_limits,
    });
    defer recovered_management.deinit();
    var retry = switch (try recovered_management.prepareBeginDynamicRegistration(9, .{
        .consent = .{
            .server_id = "oauth",
            .resource = "https://mcp.example.test/mcp",
            .issuer = "https://issuer.example.test",
            .scopes = &.{"files.read"},
            .redirect_uri = "http://127.0.0.1:43124/auth/callback",
        },
    })) {
        .prepared => |prepared| prepared,
        .rejected => return error.TestUnexpectedResult,
    };
    defer retry.deinit();
    try std.testing.expectEqualStrings(
        "dynamic_registration",
        retry.target().oauth_operation.?.kind,
    );
}

test "disabled referenced OAuth refresh rebases unrelated changes and rotates fresh token locators" {
    const Harness = struct {
        entropy: u8 = 0,

        fn fill(context: ?*anyopaque, output: *[16]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.entropy +%= 1;
            @memset(output, self.entropy);
            return true;
        }
        fn commit(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn clear(_: ?*anyopaque) PersistenceEffect {
            return .committed;
        }
        fn probe(_: ?*anyopaque, _: []const u8) CredentialPresence {
            return .missing;
        }
        fn create(_: ?*anyopaque, _: []const u8, _: []const u8) bool {
            return true;
        }
        fn delete(_: ?*anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var harness: Harness = .{};
    var oauth_server: ServerWire = .{
        .id = "oauth",
        .namespace = "oauth",
        .display_name = "OAuth",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{
            .kind = "streamable_http",
            .url = "https://mcp.example.test/mcp",
        },
        .auth = oauthAuth(.{ .pre_registered = .{
            .client_id = "client",
            .token_endpoint_auth_method = "none",
        } }),
        .connection_approval = null,
        .tools = &.{"files.read"},
    };
    var registered = oauth_server.auth.oauth.?;
    registered.registration.issuer = "https://issuer.example.test";
    oauth_server.auth.oauth = registered;
    const connection = connectionFingerprint(oauth_server);
    oauth_server.connection_approval = .{ .fingerprint = &connection };
    var consent: OauthConsentWire = .{
        .epoch = 3,
        .fingerprint = "unused",
        .resource = "https://mcp.example.test/mcp",
        .issuer = "https://issuer.example.test",
        .scopes = &.{"files.read"},
        .redirect_uri = "http://127.0.0.1:43123/auth/callback",
        .client_credential_revision = 1,
    };
    const consent_fingerprint = oauthConsentFingerprint(oauth_server, consent).?;
    consent.fingerprint = &consent_fingerprint;
    var oauth = oauth_server.auth.oauth.?;
    oauth.status = "ready";
    oauth.consent = consent;
    oauth.grant = .{
        .consent_epoch = 3,
        .token_revision = 8,
        .access_token_ref = "oauth/access-8",
        .refresh_token_ref = "oauth/refresh-8",
        .expires_at_unix_ms = 1000,
    };
    oauth_server.auth.oauth = oauth;
    const other: ServerWire = .{
        .id = "other",
        .namespace = "other",
        .display_name = "Other",
        .enabled = false,
        .negotiation = "automatic",
        .timeout_ms = 1000,
        .transport = .{ .kind = "stdio", .command = "tool" },
        .auth = .{ .kind = "none", .oauth = null },
        .connection_approval = null,
        .tools = &.{},
    };
    var servers = [_]ServerWire{ oauth_server, other };
    var management = try ManagementPort.init(std.testing.allocator, .{
        .schema_version = schema_version,
        .generation = 20,
        .oauth_operation = null,
        .servers = &servers,
    }, .{
        .persistence = .{
            .context = &harness,
            .available = true,
            .commit_journal_fn = Harness.commit,
            .commit_registry_fn = Harness.commit,
            .clear_journal_fn = Harness.clear,
        },
        .credentials = .{
            .context = &harness,
            .available = true,
            .probe_fn = Harness.probe,
            .create_fn = Harness.create,
            .delete_fn = Harness.delete,
        },
        .locator_generator = .{
            .context = &harness,
            .available = true,
            .fill_fn = Harness.fill,
        },
        .identity_generator = .{
            .context = &harness,
            .available = true,
            .fill_fn = Harness.fill,
        },
        .limits = test_limits,
    });
    defer management.deinit();
    try std.testing.expect((try management.prepareBeginRefresh(20, .{ .server_id = "oauth" })) == .rejected);
    var begin = switch (try management.prepareBeginRefresh(20, .{
        .server_id = "oauth",
        .retained_member = true,
    })) {
        .prepared => |prepared| prepared,
        .rejected => return error.TestUnexpectedResult,
    };
    defer begin.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedOperationState(&begin),
    );
    const operation = management.desiredRegistry().?.oauth_operation.?;
    var operation_storage: [64]u8 = undefined;
    @memcpy(operation_storage[0..operation.id.len], operation.id);
    const operation_id = operation_storage[0..operation.id.len];
    var rename = switch (try management.prepareRenameServer(20, .{
        .server_id = "other",
        .display_name = "Other concurrently renamed",
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer rename.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.commitPreparedMutation(&rename),
    );
    var access = [_]u8{ 'a', 'c', 'c', 'e', 's', 's', '-', '9' };
    var refresh = [_]u8{ 'r', 'e', 'f', 'r', 'e', 's', 'h', '-', '9' };
    var completion = switch (try management.prepareCompleteRefresh(.{
        .operation_id = operation_id,
        .server_id = "oauth",
        .access_token = &access,
        .refresh_token = &refresh,
        .expires_at_unix_ms = 9000,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer completion.deinit();
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), &access);
    try std.testing.expectEqualSlices(u8, &@as([9]u8, @splat(0)), &refresh);
    try std.testing.expectEqual(@as(u64, 22), completion.target().generation);
    try std.testing.expectEqualStrings(
        "Other concurrently renamed",
        completion.target().servers[1].display_name,
    );
    const rotated = completion.target().servers[0].auth.oauth.?.grant.?;
    try std.testing.expectEqual(@as(u64, 9), rotated.token_revision);
    try std.testing.expectEqual(@as(?u64, 9000), rotated.expires_at_unix_ms);
    try std.testing.expect(!std.mem.eql(
        u8,
        rotated.access_token_ref,
        "oauth/access-8",
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        rotated.refresh_token_ref.?,
        "oauth/refresh-8",
    ));
    try std.testing.expect(containsText(
        completion.plan.transaction.retired_locators,
        "oauth/access-8",
    ));
    try std.testing.expect(containsText(
        completion.plan.transaction.retired_locators,
        "oauth/refresh-8",
    ));

    var access_without_refresh = [_]u8{ 'a', 'c', 'c', 'e', 's', 's', '-', 'x' };
    var preserved = switch (try management.prepareCompleteRefresh(.{
        .operation_id = operation_id,
        .server_id = "oauth",
        .access_token = &access_without_refresh,
        .refresh_token = null,
        .expires_at_unix_ms = 12_000,
    })) {
        .prepared => |prepared| prepared,
        else => return error.TestUnexpectedResult,
    };
    defer preserved.deinit();
    try std.testing.expectEqualStrings(
        "oauth/refresh-8",
        preserved.target().servers[0].auth.oauth.?.grant.?.refresh_token_ref.?,
    );
    try std.testing.expectEqual(@as(usize, 1), preserved.candidates.len);
    try std.testing.expect(containsText(
        preserved.plan.transaction.retired_locators,
        "oauth/access-8",
    ));
    try std.testing.expect(!containsText(
        preserved.plan.transaction.retired_locators,
        "oauth/refresh-8",
    ));
}

test "unapproved server never resolves credentials" {
    const Resolver = struct {
        var calls: usize = 0;

        fn resolve(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
        ) CredentialResolution {
            calls += 1;
            return .{ .value = allocator.dupe(u8, "secret") catch
                return .out_of_memory };
        }
    };
    Resolver.calls = 0;
    const bytes =
        \\{"schema_version":2,"generation":1,"oauth_operation":null,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/mcp","headers":[{"name":"Authorization","credential_ref":"remote/token"}]},"auth":{"kind":"static","oauth":null},"connection_approval":null,"tools":[]}]}
    ;
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
        true,
        false,
        .{ .available = true, .resolve_fn = Resolver.resolve },
        test_limits,
    );
    defer prepared.deinit();
    try std.testing.expect(prepared.server_states[0] == .unapproved);
    try std.testing.expectEqual(@as(usize, 0), Resolver.calls);
    try std.testing.expectEqual(@as(usize, 0), prepared.credentials.len);
}

test "failed MCP candidate survives membership growth and retries once after replacement" {
    var ledger: RuntimeConvergence = .{};
    defer ledger.deinit(std.testing.allocator);
    const bad = RuntimeApplyTarget.init("bad", null, .add);
    try ledger.prepare(std.testing.allocator, bad);
    ledger.reject(bad, .rejected);
    ledger.applied(RuntimeApplyTarget.init("healthy", null, .add));
    try std.testing.expect(ledger.handled(bad));
    try std.testing.expect(!ledger.nextRound());
    ledger.applied(RuntimeApplyTarget.init("healthy", null, .replace));
    try std.testing.expect(ledger.handled(bad));
    try std.testing.expect(ledger.nextRound());
    try std.testing.expect(!ledger.handled(bad));
    try ledger.prepare(std.testing.allocator, bad);
    ledger.reject(bad, .rejected);
    try std.testing.expect(ledger.handled(bad));
    try std.testing.expect(!ledger.nextRound());
    ledger.retry();
    try std.testing.expect(!ledger.handled(bad));
}

test "removed unattemptable MCP targets cannot create endless follow-up rounds" {
    var ledger: RuntimeConvergence = .{};
    defer ledger.deinit(std.testing.allocator);
    const bad = RuntimeApplyTarget.init("bad", null, .add);
    try ledger.prepare(std.testing.allocator, bad);
    ledger.reject(bad, .failed);
    ledger.applied(RuntimeApplyTarget.init("other", null, .remove));
    try std.testing.expect(ledger.nextRound());
    try std.testing.expect(!ledger.nextRound());
}

test "Runtime explicit member retry preserves unrelated failures across growth" {
    var ledger: RuntimeConvergence = .{};
    defer ledger.deinit(std.testing.allocator);
    const a = RuntimeApplyTarget.init("a", null, .add);
    const b = RuntimeApplyTarget.init("b", null, .add);
    try ledger.prepare(std.testing.allocator, a);
    ledger.reject(a, .rejected);
    try ledger.prepare(std.testing.allocator, b);
    ledger.reject(b, .failed);
    ledger.retryServer("a");
    try std.testing.expect(!ledger.handled(a));
    try std.testing.expect(ledger.handled(b));
    try ledger.prepare(std.testing.allocator, a);
    ledger.applied(a);
    try std.testing.expect(ledger.handled(b));
    ledger.retryServer("missing");
    try std.testing.expect(ledger.handled(b));
    ledger.retry();
    try std.testing.expect(!ledger.handled(b));
}

test "membership planner exhausts eligibility membership retention and processed outcomes" {
    var server: ServerWire = .{ .id = "source", .namespace = "source", .display_name = "Source", .enabled = true, .negotiation = "automatic", .timeout_ms = 2000, .transport = .{ .kind = "streamable_http", .url = "https://example.test/mcp" }, .auth = .{ .kind = "none", .oauth = null }, .connection_approval = null, .tools = &.{} };
    const approval = connectionFingerprint(server);
    server.connection_approval = .{ .fingerprint = &approval };
    var entries = [_]RuntimeManifestEntry{.{ .id = server.id, .state = .{ .loaded = runtimeDescriptorFingerprint(server) } }};
    var manifest: RuntimeManifest = .{ .allocator = std.testing.allocator, .entries = &entries };
    var desired_servers = [_]ServerWire{server};
    var desired: RegistryWire = .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &desired_servers };
    for ([_]bool{ false, true }) |present| for ([_]bool{ false, true }) |enabled| for ([_]bool{ false, true }) |approved| for ([_]bool{ false, true }) |valid| for ([_]bool{ false, true }) |changed| for ([_]bool{ false, true }) |loaded| for ([_]bool{ false, true }) |referenced| {
        desired_servers[0] = server;
        desired_servers[0].enabled = enabled;
        desired_servers[0].connection_approval = if (approved) server.connection_approval else null;
        if (!valid) desired_servers[0].timeout_ms = 0;
        if (changed) desired_servers[0].display_name = "Changed";
        // A connection change (rather than presentation) changes Runtime identity.
        if (changed) desired_servers[0].transport.url = "https://changed.example.test/mcp";
        const current_approval = connectionFingerprint(desired_servers[0]);
        if (approved) desired_servers[0].connection_approval = .{ .fingerprint = &current_approval };
        desired.servers = if (present) &desired_servers else &.{};
        manifest.entries = if (loaded) &entries else &.{};
        entries[0].task_references = @intFromBool(referenced);
        const eligible = present and enabled and approved and valid;
        const expected: ?@FieldType(RuntimeApplyTarget, "kind") = if (loaded and !eligible) (if (referenced) null else .remove) else if (eligible and !loaded) .add else if (eligible and loaded and changed) .replace else null;
        const plan = manifest.nextStep(desired, test_limits, null);
        try std.testing.expectEqual(expected, if (plan) |value| value.target.kind else null);
        try std.testing.expectEqual(if (plan == null) RuntimeAlignment.current else .restart_required, manifest.alignment(desired, test_limits));
        if (plan) |value| {
            var ledger: RuntimeConvergence = .{};
            defer ledger.deinit(std.testing.allocator);
            try ledger.prepare(std.testing.allocator, value.target);
            ledger.reject(value.target, .failed);
            try std.testing.expect(manifest.nextStep(desired, test_limits, &ledger) == null);
            try std.testing.expectEqual(.current, manifest.alignmentWithResults(desired, test_limits, &ledger));
        }
    };
}
