//! Workbench-owned MCP registry codec and single-writer file capability.
//! The registry contains product configuration and credential locators only;
//! credential material is resolved by a separate Host capability.

const std = @import("std");
const builtin = @import("builtin");

pub const schema_version: u8 = 1;
pub const file_name = "registry.json";
pub const transaction_file_name = "transaction.json";
pub const max_store_bytes: usize = 256 * 1024;
pub const max_transaction_bytes: usize = 64 * 1024;
const lock_file_name = ".registry.lock";

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
    tools: []const []const u8 = &.{},
};

pub const TransportWire = struct {
    kind: []const u8,
    command: ?[]const u8 = null,
    arguments: []ValueSourceWire = &.{},
    cwd: ?[]const u8 = null,
    environment: []NamedValueWire = &.{},
    url: ?[]const u8 = null,
    headers: []NamedValueWire = &.{},
};

/// Exactly one field must be present. `literal` is ordinary configuration;
/// credential material must be represented by `credential_ref`.
pub const ValueSourceWire = struct {
    literal: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
};

pub const NamedValueWire = struct {
    name: []const u8,
    value: ValueSourceWire,
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

    fn targetRegistry(self: *const MutationPlan) Error!RegistryWire {
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

/// Credential-bearing management input. `replace` is consumed by the call
/// and securely zeroed on every return path. Durable credential locators are
/// generated inside the Workbench owner and never accepted from callers.
pub const CredentialUpdate = union(enum) {
    retain,
    replace: []u8,
};

pub const NamedCredentialInput = struct {
    name: []const u8,
    value: CredentialUpdate,
};

pub const StdioServerInput = struct {
    command: []const u8,
    arguments: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    environment: []const NamedCredentialInput = &.{},
};

pub const HttpServerInput = struct {
    url: []const u8,
    headers: []const NamedCredentialInput = &.{},
};

pub const ManagedTransportInput = union(enum) {
    stdio: StdioServerInput,
    streamable_http: HttpServerInput,
};

pub const ManagedServerInput = struct {
    id: []const u8,
    namespace: []const u8,
    display_name: []const u8,
    enabled: bool,
    negotiation: []const u8,
    timeout_ms: u32,
    transport: ManagedTransportInput,
    tools: []const []const u8 = &.{},
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

pub const CreateHttpServerInput = struct {
    display_name: []const u8,
    url: []const u8,
};

pub const RenameServerInput = struct {
    server_id: []const u8,
    display_name: []const u8,
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
};

pub const ManagementOutcome = enum {
    unchanged,
    saved,
    saved_recovery_required,
    rejected,
    indeterminate,
};

pub const PreparedMutation = struct {
    plan: MutationPlan,

    pub fn target(self: *const PreparedMutation) RegistryWire {
        return self.plan.targetRegistry() catch unreachable;
    }

    pub fn deinit(self: *PreparedMutation) void {
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
        };
    }

    pub fn deinit(self: *ManagementPort) void {
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
                manifest.alignment(if (self.desired) |registry| registry.value else null, self.limits)
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
            manifest.alignment(target, self.limits)
        else
            .unknown;
    }

    pub fn desiredRegistry(self: *const ManagementPort) ?RegistryWire {
        return if (self.desired) |registry| registry.value else null;
    }

    pub fn prepareCreateHttpServer(
        self: *ManagementPort,
        expected_generation: u64,
        input: CreateHttpServerInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        const base = if (self.desired) |registry| registry.value else null;
        const base_servers = if (base) |registry| registry.servers else &.{};
        if (!self.mutationReady(expected_generation) or
            base_servers.len >= self.limits.max_servers)
            return .rejected;
        var identity_storage: [24]u8 = undefined;
        const identity = identity: {
            var attempts: usize = 0;
            while (attempts < 8) : (attempts += 1) {
                var entropy: [16]u8 = undefined;
                if (!self.identity_generator.fill(&entropy)) return .rejected;
                const hex = std.fmt.bytesToHex(entropy, .lower);
                const candidate = std.fmt.bufPrint(
                    &identity_storage,
                    "mcp-{s}",
                    .{hex[0..20]},
                ) catch unreachable;
                if (findServerIndex(base_servers, candidate) == null)
                    break :identity candidate;
            }
            return .rejected;
        };
        const server: ServerWire = .{
            .id = identity,
            .namespace = identity,
            .display_name = input.display_name,
            .enabled = false,
            .negotiation = "automatic",
            .timeout_ms = 30_000,
            .transport = .{
                .kind = "streamable_http",
                .url = input.url,
            },
            .tools = &.{},
        };
        if (serverProblem(server, self.limits) != null) return .rejected;
        const servers = try self.allocator.alloc(ServerWire, base_servers.len + 1);
        defer self.allocator.free(servers);
        @memcpy(servers[0..base_servers.len], base_servers);
        servers[base_servers.len] = server;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
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
            .servers = servers,
        });
    }

    pub fn prepareSetServerEnabled(
        self: *ManagementPort,
        expected_generation: u64,
        input: SetServerEnabledInput,
    ) std.mem.Allocator.Error!MutationPreparation {
        if (!self.mutationReady(expected_generation)) return .rejected;
        const base = if (self.desired) |registry| registry.value else return .rejected;
        const index = findServerIndex(base.servers, input.server_id) orelse return .rejected;
        if (base.servers[index].enabled == input.enabled) return .unchanged;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index].enabled = input.enabled;
        if (input.enabled and serverProblem(servers[index], self.limits) != null)
            return .rejected;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
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
        if (stringSlicesEqual(base.servers[index].tools, input.tools)) return .unchanged;
        const servers = try self.allocator.dupe(ServerWire, base.servers);
        defer self.allocator.free(servers);
        servers[index].tools = input.tools;
        if (serverProblem(servers[index], self.limits) != null) return .rejected;
        return try self.prepareTarget(expected_generation, .{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
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
            &.{},
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
        return .{ .prepared = .{ .plan = plan } };
    }

    pub fn upsertServer(
        self: *ManagementPort,
        expected_generation: u64,
        input: ManagedServerInput,
    ) std.mem.Allocator.Error!ManagementOutcome {
        defer zeroManagedServerSecrets(input);
        if (self.coordinator.health != .ready or
            expected_generation != generationValue(self.inspect().desired_generation))
            return .rejected;

        const base = if (self.desired) |registry| registry.value else null;
        const base_servers = if (base) |registry| registry.servers else &.{};
        const existing_index = findServerIndex(base_servers, input.id);
        const target_count = if (existing_index == null)
            std.math.add(usize, base_servers.len, 1) catch return .rejected
        else
            base_servers.len;
        if (target_count > self.limits.max_servers) return .rejected;
        if (expected_generation == std.math.maxInt(u64)) return .rejected;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        var candidates: std.ArrayList(CandidateCredential) = .empty;
        defer candidates.deinit(self.allocator);
        const existing = if (existing_index) |index| base_servers[index] else null;
        const replacement = buildManagedServer(
            temporary,
            input,
            existing,
            self.locator_generator,
            &candidates,
            self.allocator,
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        const target_servers = try self.allocator.alloc(ServerWire, target_count);
        defer self.allocator.free(target_servers);
        if (existing_index) |replace_index| {
            @memcpy(target_servers, base_servers);
            target_servers[replace_index] = replacement;
        } else {
            @memcpy(target_servers[0..base_servers.len], base_servers);
            target_servers[base_servers.len] = replacement;
        }
        return self.commitTarget(.{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .servers = target_servers,
        }, candidates.items);
    }

    pub fn removeServer(
        self: *ManagementPort,
        expected_generation: u64,
        server_id: []const u8,
    ) std.mem.Allocator.Error!ManagementOutcome {
        if (self.coordinator.health != .ready or
            expected_generation != generationValue(self.inspect().desired_generation))
            return .rejected;
        const base = if (self.desired) |registry| registry.value else return .unchanged;
        const remove_index = findServerIndex(base.servers, server_id) orelse
            return .unchanged;
        if (expected_generation == std.math.maxInt(u64)) return .rejected;
        const target_servers = try self.allocator.alloc(ServerWire, base.servers.len - 1);
        defer self.allocator.free(target_servers);
        @memcpy(target_servers[0..remove_index], base.servers[0..remove_index]);
        @memcpy(target_servers[remove_index..], base.servers[remove_index + 1 ..]);
        return self.commitTarget(.{
            .schema_version = schema_version,
            .generation = expected_generation + 1,
            .servers = target_servers,
        }, &.{});
    }

    fn commitTarget(
        self: *ManagementPort,
        target: RegistryWire,
        candidates: []CandidateCredential,
    ) std.mem.Allocator.Error!ManagementOutcome {
        var candidate_locators: std.ArrayList([]const u8) = .empty;
        defer candidate_locators.deinit(self.allocator);
        for (candidates) |candidate|
            candidate_locators.append(self.allocator, candidate.locator) catch
                return error.OutOfMemory;
        var plan = (planMutation(
            self.allocator,
            if (self.desired) |registry| registry.value else null,
            target,
            generationValue(self.inspect().desired_generation),
            candidate_locators.items,
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        }) orelse return .unchanged;
        defer plan.deinit();
        const commit = self.coordinator.commit(
            self.allocator,
            self.persistence,
            self.credentials,
            &plan,
            candidates,
            self.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .rejected,
        };
        return switch (commit) {
            .saved => saved: {
                self.replaceDesired(plan.takeTarget());
                break :saved .saved;
            },
            .saved_recovery_required => saved: {
                self.replaceDesired(plan.takeTarget());
                break :saved .saved_recovery_required;
            },
            .registry_outcome_unknown => .indeterminate,
            .not_saved, .not_saved_recovery_required, .blocked => .rejected,
        };
    }

    fn replaceDesired(
        self: *ManagementPort,
        replacement: std.json.Parsed(RegistryWire),
    ) void {
        if (self.desired) |*registry| registry.deinit();
        self.desired = replacement;
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

fn buildManagedServer(
    allocator: std.mem.Allocator,
    input: ManagedServerInput,
    existing: ?ServerWire,
    generator: FreshLocatorGenerator,
    candidates: *std.ArrayList(CandidateCredential),
    candidate_allocator: std.mem.Allocator,
    limits: Limits,
) (Error || std.mem.Allocator.Error)!ServerWire {
    const transport: TransportWire = switch (input.transport) {
        .stdio => |stdio| .{
            .kind = "stdio",
            .command = stdio.command,
            .arguments = try literalArguments(allocator, stdio.arguments),
            .cwd = stdio.cwd,
            .environment = try credentialEntries(
                allocator,
                stdio.environment,
                if (existing) |server| server.transport.environment else &.{},
                generator,
                candidates,
                candidate_allocator,
                limits,
            ),
        },
        .streamable_http => |http| .{
            .kind = "streamable_http",
            .url = http.url,
            .headers = try credentialEntries(
                allocator,
                http.headers,
                if (existing) |server| server.transport.headers else &.{},
                generator,
                candidates,
                candidate_allocator,
                limits,
            ),
        },
    };
    const server: ServerWire = .{
        .id = input.id,
        .namespace = input.namespace,
        .display_name = input.display_name,
        .enabled = input.enabled,
        .negotiation = input.negotiation,
        .timeout_ms = input.timeout_ms,
        .transport = transport,
        .tools = input.tools,
    };
    if (serverProblem(server, limits) != null) return error.InvalidMutation;
    return server;
}

fn literalArguments(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error![]ValueSourceWire {
    const values = try allocator.alloc(ValueSourceWire, arguments.len);
    for (arguments, 0..) |argument, index| values[index] = .{ .literal = argument };
    return values;
}

fn credentialEntries(
    allocator: std.mem.Allocator,
    inputs: []const NamedCredentialInput,
    existing: []const NamedValueWire,
    generator: FreshLocatorGenerator,
    candidates: *std.ArrayList(CandidateCredential),
    candidate_allocator: std.mem.Allocator,
    limits: Limits,
) (Error || std.mem.Allocator.Error)![]NamedValueWire {
    const entries = try allocator.alloc(NamedValueWire, inputs.len);
    for (inputs, 0..) |input, index| {
        const locator = switch (input.value) {
            .retain => retained: {
                for (existing) |entry| {
                    if (!std.ascii.eqlIgnoreCase(entry.name, input.name)) continue;
                    break :retained entry.value.credential_ref orelse
                        return error.InvalidMutation;
                }
                return error.InvalidMutation;
            },
            .replace => |secret| fresh: {
                if (secret.len == 0 or secret.len > limits.max_credential_secret_bytes)
                    return error.InvalidMutation;
                var random: [16]u8 = undefined;
                if (!generator.fill(&random)) return error.InvalidMutation;
                const hex = std.fmt.bytesToHex(random, .lower);
                const locator = try std.fmt.allocPrint(allocator, "v1/{s}", .{hex});
                if (!validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    return error.InvalidMutation;
                try candidates.append(candidate_allocator, .{
                    .locator = locator,
                    .secret = secret,
                });
                break :fresh locator;
            },
        };
        entries[index] = .{
            .name = input.name,
            .value = .{ .credential_ref = locator },
        };
    }
    return entries;
}

pub fn zeroManagedServerSecrets(input: ManagedServerInput) void {
    const values = switch (input.transport) {
        .stdio => |stdio| stdio.environment,
        .streamable_http => |http| http.headers,
    };
    for (values) |value| switch (value.value) {
        .retain => {},
        .replace => |secret| std.crypto.secureZero(u8, secret),
    };
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
    invalid_display_name,
    invalid_negotiation,
    invalid_timeout,
    invalid_transport,
    invalid_allowlist,
    invalid_credential_locator,
    credential_capacity_exceeded,
};

pub const ServerPreparationState = union(enum) {
    eligible,
    disabled,
    needs_authentication,
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
    needs_authentication: DescriptorFingerprint,
    invalid_catalog: struct {
        problem: ServerProblem,
        fingerprint: DescriptorFingerprint,
    },
};

const RuntimeManifestEntry = struct {
    id: []const u8,
    state: union(enum) {
        loaded: DescriptorFingerprint,
        absent: AbsenceProof,
    },
};

/// Immutable, in-memory proof of the descriptors accepted by one Agent
/// Runtime. It contains no credential bytes and is never persisted or
/// projected through Bridge.
pub const RuntimeManifest = struct {
    allocator: std.mem.Allocator,
    entries: []RuntimeManifestEntry,

    pub fn candidate(
        allocator: std.mem.Allocator,
        preparation: *const Preparation,
    ) std.mem.Allocator.Error!?RuntimeManifest {
        if (preparation.state != .available or preparation.registry == null)
            return null;
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
                    .eligible => .{ .loaded = descriptorFingerprint(server) },
                    .disabled => .{ .absent = .disabled },
                    .needs_authentication => .{
                        .absent = .{ .needs_authentication = authenticationFingerprint(server) },
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
        for (self.entries) |entry| {
            const target = if (desired) |registry|
                findServer(registry.servers, entry.id)
            else
                null;
            if (!entryCompatible(entry, target, limits)) return .restart_required;
        }
        if (desired) |registry| {
            for (registry.servers) |server| {
                if (findManifestEntry(self.entries, server.id) != null) continue;
                if (server.enabled) return .restart_required;
            }
        }
        return .current;
    }
};

fn entryCompatible(
    entry: RuntimeManifestEntry,
    target: ?ServerWire,
    limits: Limits,
) bool {
    return switch (entry.state) {
        .loaded => |fingerprint| if (target) |server|
            server.enabled and
                serverProblem(server, limits) == null and
                std.mem.eql(u8, &fingerprint, &descriptorFingerprint(server))
        else
            false,
        .absent => |proof| switch (proof) {
            .disabled => if (target) |server| !server.enabled else true,
            .needs_authentication => |fingerprint| if (target) |server|
                !server.enabled or
                    serverProblem(server, limits) != null or
                    std.mem.eql(u8, &fingerprint, &authenticationFingerprint(server))
            else
                true,
            .invalid_catalog => |invalid| if (target) |server| invalid_target: {
                if (!server.enabled) break :invalid_target true;
                if (serverProblem(server, limits) != null)
                    break :invalid_target true;
                break :invalid_target invalid.problem == .credential_capacity_exceeded and
                    std.mem.eql(u8, &invalid.fingerprint, &validationFingerprint(server));
            } else true,
        },
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

fn descriptorFingerprint(server: ServerWire) DescriptorFingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "metawork.mcp.runtime-descriptor/v1");
    hashField(&hash, server.namespace);
    hashField(&hash, server.negotiation);
    hashInteger(&hash, server.timeout_ms);
    hashTransport(&hash, server.transport);
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
    var reference_count: usize = 0;
    for (server.transport.arguments) |argument| {
        if (argument.credential_ref != null) reference_count += 1;
    }
    for (server.transport.environment) |entry| {
        if (entry.value.credential_ref != null) reference_count += 1;
    }
    for (server.transport.headers) |entry| {
        if (entry.value.credential_ref != null) reference_count += 1;
    }
    hashInteger(&hash, reference_count);
    for (server.transport.arguments) |argument| {
        if (argument.credential_ref) |locator| hashField(&hash, locator);
    }
    for (server.transport.environment) |entry| {
        if (entry.value.credential_ref) |locator| hashField(&hash, locator);
    }
    for (server.transport.headers) |entry| {
        if (entry.value.credential_ref) |locator| hashField(&hash, locator);
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
        hashValueSource(hash, entry.value);
    }
    hashOptionalField(hash, transport.url);
    hashInteger(hash, transport.headers.len);
    for (transport.headers) |entry| {
        hashField(hash, entry.name);
        hashValueSource(hash, entry.value);
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
        if (!server.enabled) {
            server_states[index] = .disabled;
            continue;
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
    for (server.transport.arguments) |value|
        if (value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.environment) |entry|
        if (entry.value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
    for (server.transport.headers) |entry|
        if (entry.value.credential_ref) |candidate|
            if (std.mem.eql(u8, candidate, locator)) return true;
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
    for (server.transport.arguments) |value| {
        if (value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    for (server.transport.environment) |entry| {
        if (entry.value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
        }
    }
    for (server.transport.headers) |entry| {
        if (entry.value.credential_ref) |locator| {
            ready = (try resolveCredential(allocator, locator, resolver, limits, credentials)) and ready;
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
            const locator = entry.value.credential_ref orelse return .unusable;
            const secret = resolvedCredential(credentials, locator) orelse return .unusable;
            if (!validEnvironmentCredential(secret)) return .unusable;
            if (try appendUniqueSecret(allocator, &unique_secrets, secret)) {
                total_bytes = std.math.add(usize, total_bytes, secret.len) catch
                    return .capacity_exceeded;
            }
        }
    } else if (std.mem.eql(u8, server.transport.kind, "streamable_http")) {
        for (server.transport.headers) |entry| {
            const locator = entry.value.credential_ref orelse return .unusable;
            const secret = resolvedCredential(credentials, locator) orelse return .unusable;
            if (!validHttpHeaderCredential(secret)) return .unusable;
            if (try appendUniqueSecret(allocator, &unique_secrets, secret)) {
                total_bytes = std.math.add(usize, total_bytes, secret.len) catch
                    return .capacity_exceeded;
            }
        }
    } else return .unusable;

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
    if (input.len == 0) return error.RegistryEmpty;
    if (input.len > max_store_bytes) return error.RegistryTooLarge;
    var parsed = std.json.parseFromSlice(
        RegistryWire,
        allocator,
        input,
        .{ .ignore_unknown_fields = false, .allocate = .alloc_always },
    ) catch return error.RegistryCorrupt;
    errdefer parsed.deinit();
    validateRegistryIdentity(&parsed.value, limits) catch
        return error.RegistryCorrupt;
    return parsed;
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
    ) catch return error.TransactionCorrupt;
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
    const base_generation = if (base) |registry| registry.generation else 0;
    if (base_generation != expected_generation) return error.GenerationMismatch;
    if (base_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    if (target.generation != base_generation + 1) return error.InvalidMutation;

    if (base) |registry| {
        validateRegistryIdentity(&registry, limits) catch return error.InvalidMutation;
    }
    validateMutationTransition(base, &target, limits) catch
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
        .schema_version = schema_version,
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
) !void {
    try validateRegistryIdentity(target, limits);
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

fn collectCredentialReferences(
    allocator: std.mem.Allocator,
    registry: RegistryWire,
    references: *std.ArrayList([]const u8),
    limits: Limits,
) std.mem.Allocator.Error!void {
    for (registry.servers) |server| {
        for (server.transport.arguments) |value|
            if (value.credential_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        for (server.transport.environment) |entry|
            if (entry.value.credential_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
        for (server.transport.headers) |entry|
            if (entry.value.credential_ref) |locator|
                if (validCredentialLocator(locator, limits.max_credential_locator_bytes))
                    try appendUniqueText(allocator, references, locator);
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

fn registryContentEqual(left: RegistryWire, right: RegistryWire) bool {
    if (left.schema_version != right.schema_version or
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
        left.tools.len != right.tools.len)
        return false;
    for (left.tools, right.tools) |left_tool, right_tool|
        if (!std.mem.eql(u8, left_tool, right_tool)) return false;
    return true;
}

fn transportWireEqual(left: TransportWire, right: TransportWire) bool {
    if (!std.mem.eql(u8, left.kind, right.kind) or
        !optionalTextEqual(left.command, right.command) or
        !optionalTextEqual(left.cwd, right.cwd) or
        !optionalTextEqual(left.url, right.url) or
        left.arguments.len != right.arguments.len or
        left.environment.len != right.environment.len or
        left.headers.len != right.headers.len)
        return false;
    for (left.arguments, right.arguments) |left_value, right_value|
        if (!valueSourceEqual(left_value, right_value)) return false;
    for (left.environment, right.environment) |left_entry, right_entry|
        if (!namedValueEqual(left_entry, right_entry)) return false;
    for (left.headers, right.headers) |left_entry, right_entry|
        if (!namedValueEqual(left_entry, right_entry)) return false;
    return true;
}

fn namedValueEqual(left: NamedValueWire, right: NamedValueWire) bool {
    return std.mem.eql(u8, left.name, right.name) and
        valueSourceEqual(left.value, right.value);
}

fn valueSourceEqual(left: ValueSourceWire, right: ValueSourceWire) bool {
    return optionalTextEqual(left.literal, right.literal) and
        optionalTextEqual(left.credential_ref, right.credential_ref);
}

fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// Recovery is decided from the durable registry generation, not from a
/// separately mutable phase flag. At the old generation candidate credentials
/// are orphaned; at the target generation retired credentials are obsolete.
pub fn recoverCredentialTransaction(
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
    if (transaction.schema_version != schema_version or
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
    if (!validText(server.display_name, limits.max_display_name_bytes, false))
        return .invalid_display_name;
    if (!oneOf(server.negotiation, &.{ "automatic", "modern_only", "compat_only" }))
        return .invalid_negotiation;
    if (server.timeout_ms == 0) return .invalid_timeout;
    for (server.tools, 0..) |tool, index| {
        if (!validText(tool, limits.max_tool_name_bytes, false))
            return .invalid_allowlist;
        for (server.tools[0..index]) |previous|
            if (std.mem.eql(u8, previous, tool)) return .invalid_allowlist;
    }
    return validateTransport(server.transport, limits);
}

fn validateRegistryIdentity(registry: *const RegistryWire, limits: Limits) !void {
    if (registry.schema_version != schema_version or registry.generation == 0 or
        registry.servers.len > limits.max_servers or limits.max_servers == 0 or
        limits.max_tools_per_server == 0 or limits.max_namespace_bytes == 0 or
        limits.max_runtime_secrets_per_server == 0 or
        limits.max_runtime_secret_bytes_per_server == 0)
        return error.Invalid;
    for (registry.servers, 0..) |server, index| {
        if (!validIdentifier(server.id, limits.max_identity_bytes) or
            !validNamespace(server.namespace, limits.max_namespace_bytes) or
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

fn credentialReferenceCount(server: ServerWire) usize {
    var count: usize = 0;
    for (server.transport.arguments) |value| if (value.credential_ref != null) {
        count += 1;
    };
    for (server.transport.environment) |entry| if (entry.value.credential_ref != null) {
        count += 1;
    };
    for (server.transport.headers) |entry| if (entry.value.credential_ref != null) {
        count += 1;
    };
    return count;
}

fn validateTransport(transport: TransportWire, limits: Limits) ?ServerProblem {
    if (std.mem.eql(u8, transport.kind, "stdio")) {
        const command = transport.command orelse return .invalid_transport;
        if (transport.url != null or transport.headers.len != 0 or
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
            if (entry.value.literal != null or
                validateValueSource(entry.value, limits) == null)
                return .invalid_credential_locator;
            for (transport.environment[0..index]) |previous|
                if (std.ascii.eqlIgnoreCase(previous.name, entry.name))
                    return .invalid_transport;
        }
        return null;
    }
    if (!std.mem.eql(u8, transport.kind, "streamable_http"))
        return .invalid_transport;
    const url = transport.url orelse return .invalid_transport;
    if (transport.command != null or transport.arguments.len != 0 or
        transport.cwd != null or transport.environment.len != 0 or
        transport.headers.len > limits.max_header_count or
        !validEndpoint(url, limits.max_url_bytes))
        return .invalid_transport;
    for (transport.headers, 0..) |entry, index| {
        if (!validHeaderName(entry.name) or reservedHttpHeader(entry.name))
            return .invalid_transport;
        const source = validateValueSource(entry.value, limits) orelse
            return .invalid_credential_locator;
        if (entry.value.literal != null)
            return .invalid_credential_locator;
        if (source.len == 0) return .invalid_transport;
        for (transport.headers[0..index]) |previous|
            if (std.ascii.eqlIgnoreCase(previous.name, entry.name))
                return .invalid_transport;
    }
    return null;
}

fn reservedHttpHeader(name: []const u8) bool {
    inline for (.{
        "Accept",
        "Accept-Encoding",
        "Content-Length",
        "Content-Type",
        "Host",
        "MCP-Protocol-Version",
        "Mcp-Session-Id",
    }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    return false;
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
    if (!validText(value, max_bytes, false) or
        std.mem.indexOfAny(u8, value, "?#\r\n") != null)
        return false;
    const uri = std.Uri.parse(value) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or
        uri.fragment != null or uri.host == null)
        return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    var host_storage: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_storage) catch return false;
    return std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
        std.mem.eql(u8, host.bytes, "127.0.0.1") or
        std.mem.eql(u8, host.bytes, "::1") or
        std.mem.eql(u8, host.bytes, "[::1]");
}

fn validIdentifier(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return false;
    return true;
}

fn validNamespace(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_')
            return false;
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

pub const FileStore = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,

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
        const length = file.length(self.io) catch return error.ReadFailed;
        if (length == 0 or length > max_bytes) return error.ReadFailed;
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

    pub fn recoverPendingCredentialTransaction(
        self: *FileStore,
        allocator: std.mem.Allocator,
        current_registry_generation: u64,
        cleanup: CredentialCleanup,
        limits: Limits,
    ) (FileStoreError || Error)!bool {
        const bytes = (try self.loadTransactionAlloc(allocator)) orelse return false;
        defer allocator.free(bytes);
        var transaction = try decodeTransaction(allocator, bytes, limits);
        defer transaction.deinit();
        try recoverCredentialTransaction(
            transaction.value,
            current_registry_generation,
            cleanup,
        );
        try self.clearTransaction();
        return true;
    }

    fn commitNamed(
        self: *FileStore,
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
        const file = self.dir.createFile(self.io, temp_name, .{
            .exclusive = true,
            .permissions = privateFilePermissions(),
            .resolve_beneath = true,
        }) catch return error.WriteFailed;
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(self.io);
            if (temp_exists) self.dir.deleteFile(self.io, temp_name) catch {};
        }
        file.writeStreamingAll(self.io, bytes) catch return error.WriteFailed;
        file.sync(self.io) catch return error.WriteFailed;
        file.close(self.io);
        file_open = false;
        self.dir.rename(temp_name, self.dir, target_name, self.io) catch
            return error.WriteFailed;
        temp_exists = false;
        if (!self.syncCommit(target_name)) return error.PersistenceOutcomeUnknown;
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
        if (builtin.os.tag == .windows) {
            const name = target_name orelse return true;
            const file = self.dir.openFile(self.io, name, .{
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
            .handle = self.dir.handle,
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

test "registry preserves server-local invalid configuration for product classification" {
    const bytes =
        \\{"schema_version":1,"generation":1,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://mcp.example.test/rpc","headers":[{"name":"Authorization","value":{"literal":"raw-secret"}}]}}]}
    ;
    var parsed = try decode(std.testing.allocator, bytes, test_limits);
    defer parsed.deinit();
    try std.testing.expectEqual(
        ServerProblem.invalid_credential_locator,
        serverProblem(parsed.value.servers[0], test_limits).?,
    );
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
    for (cases) |bytes| {
        var parsed = try decode(std.testing.allocator, bytes, test_limits);
        defer parsed.deinit();
        try std.testing.expectEqual(
            ServerProblem.invalid_credential_locator,
            serverProblem(parsed.value.servers[0], test_limits).?,
        );
    }
}

test "registry reserves Host-owned Streamable HTTP mechanics headers" {
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
}

test "registry permits plaintext HTTP only for exact loopback authorities" {
    try std.testing.expect(validEndpoint("http://localhost:4310/mcp", 4096));
    try std.testing.expect(validEndpoint("http://127.0.0.1/mcp", 4096));
    try std.testing.expect(validEndpoint("http://[::1]:4310/mcp", 4096));
    try std.testing.expect(!validEndpoint("http://localhost.example/mcp", 4096));
    try std.testing.expect(!validEndpoint("http://127.0.0.1.example/mcp", 4096));
    try std.testing.expect(!validEndpoint("http://localhost:70000/mcp", 4096));
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
        4,
        .{ .context = &cleanup, .available = true, .delete_fn = Cleanup.remove },
        test_limits,
    ));
    try std.testing.expectEqual(@as(usize, 1), cleanup.count);
    try std.testing.expect(!(try store.recoverPendingCredentialTransaction(
        std.testing.allocator,
        4,
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

test "management port owns fresh locators and keeps restart pending" {
    const Fake = struct {
        created: bool = false,
        retired: bool = false,

        fn journal(_: ?*anyopaque, _: []const u8) PersistenceEffect {
            return .committed;
        }
        fn registry(_: ?*anyopaque, bytes: []const u8) PersistenceEffect {
            return if (std.mem.indexOf(u8, bytes, "v1/abababababababababababababababab") != null)
                .committed
            else
                .failed;
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
    var secret = [_]u8{ 'r', 'e', 'p', 'l', 'a', 'c', 'e', 'm', 'e', 'n', 't' };
    const headers = [_]NamedCredentialInput{.{
        .name = "Authorization",
        .value = .{ .replace = &secret },
    }};
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.upsertServer(4, .{
            .id = "remote",
            .namespace = "remote",
            .display_name = "Remote updated",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .streamable_http = .{
                .url = "https://mcp.example.test/rpc",
                .headers = &headers,
            } },
        }),
    );
    try std.testing.expect(fake.created);
    try std.testing.expect(fake.retired);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** secret.len), &secret);
    const inspection = management.inspect();
    try std.testing.expectEqual(@as(?u64, 5), inspection.desired_generation);
    try std.testing.expectEqual(RuntimeAlignment.unknown, inspection.runtime_alignment);
    try std.testing.expectEqualStrings(
        "Remote updated",
        management.desired.?.value.servers[0].display_name,
    );
}

test "typed management creates default-disabled HTTP server and commits one target" {
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
            try std.testing.expectEqualStrings(target.servers[0].id, target.servers[0].namespace);
            try std.testing.expect(!target.servers[0].enabled);
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
    try std.testing.expect((try management.prepareSetAllowedTools(4, .{
        .server_id = "remote",
        .tools = &.{ "read", "read" },
    })) == .rejected);
    try std.testing.expect((try management.prepareSetServerEnabled(4, .{
        .server_id = "missing",
        .enabled = false,
    })) == .rejected);
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
        "{\"schema_version\":1,\"generation\":3,\"servers\":[{\"id\":\"bad-name\",\"namespace\":\"bad-name\",\"display_name\":\"\",\"enabled\":true,\"negotiation\":\"automatic\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]},{\"id\":\"bad-negotiation\",\"namespace\":\"bad-negotiation\",\"display_name\":\"Broken\",\"enabled\":true,\"negotiation\":\"unsupported\",\"timeout_ms\":1000,\"transport\":{\"kind\":\"stdio\",\"command\":\"tool\"},\"tools\":[]}]}",
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

    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.removeServer(3, "bad-name"),
    );
    try std.testing.expectEqual(@as(?u64, 4), management.inspect().desired_generation);
    try std.testing.expectEqual(
        ServerProblem.invalid_negotiation,
        serverProblem(management.desired.?.value.servers[0], test_limits).?,
    );
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.upsertServer(4, .{
            .id = "bad-negotiation",
            .namespace = "bad-negotiation",
            .display_name = "Repaired",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .stdio = .{ .command = "tool" } },
        }),
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
    try std.testing.expectEqual(
        ManagementOutcome.indeterminate,
        try management.removeServer(7, "local"),
    );
    try std.testing.expectEqual(StoreHealth.outcome_unknown, management.inspect().health);
    try std.testing.expectEqual(
        ManagementOutcome.rejected,
        try management.removeServer(7, "local"),
    );
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
        .limits = test_limits,
    });
    defer management.deinit();
    var secret = [_]u8{ 'c', 'o', 'l', 'd', '-', 's', 't', 'a', 'r', 't' };
    const headers = [_]NamedCredentialInput{.{
        .name = "Authorization",
        .value = .{ .replace = &secret },
    }};
    try std.testing.expectEqual(
        ManagementOutcome.saved,
        try management.upsertServer(0, .{
            .id = "remote",
            .namespace = "remote",
            .display_name = "Remote",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .streamable_http = .{
                .url = "https://mcp.example.test/rpc",
                .headers = &headers,
            } },
        }),
    );
    try std.testing.expectEqual(@as(?u64, 1), management.inspect().desired_generation);
    try std.testing.expectEqual(
        RuntimeAlignment.unknown,
        management.inspect().runtime_alignment,
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
    try std.testing.expectEqual(@as(?u64, 1), restarted.generation());
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
    };
    var limits = test_limits;
    limits.max_tools_per_server = 1024;
    limits.max_tool_name_bytes = 256;
    const tool_storage = try std.testing.allocator.alloc([256]u8, 1024);
    defer std.testing.allocator.free(tool_storage);
    const tools = try std.testing.allocator.alloc([]const u8, tool_storage.len);
    defer std.testing.allocator.free(tools);
    for (tool_storage, tools, 0..) |*storage, *tool, index| {
        @memset(storage, 'x');
        _ = std.fmt.bufPrint(storage[0..20], "tool-{d}", .{index}) catch unreachable;
        tool.* = storage;
    }
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
        .limits = limits,
    });
    defer management.deinit();
    try std.testing.expectEqual(
        ManagementOutcome.rejected,
        try management.upsertServer(0, .{
            .id = "large",
            .namespace = "large",
            .display_name = "Large",
            .enabled = true,
            .negotiation = "automatic",
            .timeout_ms = 1000,
            .transport = .{ .stdio = .{ .command = "tool" } },
            .tools = tools,
        }),
    );
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
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
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
    var limits = test_limits;
    limits.max_runtime_secret_bytes_per_server = 6;
    var prepared = try prepare(
        std.testing.allocator,
        registry,
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
        \\{"schema_version":1,"generation":1,"servers":[{"id":"disabled","namespace":"disabled","display_name":"","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"stdio","command":"tool"},"tools":[]}]}
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
    var local = try prepare(
        std.testing.allocator,
        bytes,
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
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
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
    try std.testing.expectError(
        error.OutOfMemory,
        prepare(
            std.testing.allocator,
            bytes,
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
    var prepared = try prepare(
        std.testing.allocator,
        bytes,
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
    var desired = try decode(std.testing.allocator, bytes, test_limits);
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
    var preparation = try prepare(
        std.testing.allocator,
        startup,
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
    try expectRuntimeAlignment(
        &manifest,
        \\{"schema_version":1,"generation":8,"servers":[{"id":"loaded","namespace":"loaded","display_name":"Renamed","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://loaded.example.test/rpc"},"tools":["read","write"]},{"id":"disabled","namespace":"disabled","display_name":"Disabled","enabled":false,"negotiation":"modern_only","timeout_ms":5000,"transport":{"kind":"streamable_http","url":"https://other.example.test/rpc"}},{"id":"missing","namespace":"missing","display_name":"Renamed missing","enabled":true,"negotiation":"modern_only","timeout_ms":5000,"transport":{"kind":"streamable_http","url":"https://changed.example.test/rpc","headers":[{"name":"Authorization","value":{"credential_ref":"missing/token"}}]}},{"id":"new-disabled","namespace":"new-disabled","display_name":"New disabled","enabled":false,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://new.example.test/rpc"}}]}
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
    var preparation = try prepare(
        std.testing.allocator,
        startup,
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

test "runtime manifest candidate stays unpublished until ownership commit" {
    const bytes =
        \\{"schema_version":1,"generation":2,"servers":[{"id":"remote","namespace":"remote","display_name":"Remote","enabled":true,"negotiation":"automatic","timeout_ms":1000,"transport":{"kind":"streamable_http","url":"https://remote.example.test/rpc"}}]}
    ;
    var preparation = try prepare(
        std.testing.allocator,
        bytes,
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
