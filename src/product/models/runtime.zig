//! Product Models runtime owned by Product Control.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("metawork_product_models_contract");
const ports = @import("product_models_ports");
const registry_impl = @import("product_models_providers");
const metask_provider = @import("product_models_metask");
const builtin_providers = @import("product_models_builtin_providers");

pub const StartError = error{
    CustomProvidersDirectoryUnavailable,
    ModelsStateUnavailable,
};
pub const ModelBinding = registry_impl.Registry.ModelBinding;

pub const TestSupport = if (builtin.is_test) struct {
    /// A Metask credential port for tests, as `TestVault` is for keys. A
    /// test that needs its own values or counts holds its own instance.
    pub const FakeMetaskCredentials = struct {
        account_bytes: [contract.Limits.principal_ref_bytes]u8 = undefined,
        account_len: usize = 0,
        token_bytes: [contract.Limits.credential_bytes]u8 = undefined,
        token_len: usize = 0,
        generation: u64 = default_generation,
        /// How many times Models read it.
        reads: usize = 0,

        /// The generation fixtures have always paired with their catalog.
        pub const default_generation: u64 = 17;

        pub fn init(account: []const u8, token: []const u8, generation: u64) FakeMetaskCredentials {
            var result: FakeMetaskCredentials = .{ .generation = generation };
            result.set(account, token);
            return result;
        }

        pub fn set(self: *FakeMetaskCredentials, account: []const u8, token: []const u8) void {
            @memcpy(self.account_bytes[0..account.len], account);
            self.account_len = account.len;
            @memcpy(self.token_bytes[0..token.len], token);
            self.token_len = token.len;
        }

        pub fn port(self: *FakeMetaskCredentials) ports.MetaskCredentials {
            return .{ .context = self, .read_fn = read };
        }

        fn read(context: *anyopaque, account_storage: []u8, token_storage: []u8) std.mem.Allocator.Error!?ports.MetaskCredential {
            const self: *FakeMetaskCredentials = @ptrCast(@alignCast(context));
            self.reads += 1;
            if (self.token_len == 0) return null;
            @memcpy(account_storage[0..self.account_len], self.account_bytes[0..self.account_len]);
            @memcpy(token_storage[0..self.token_len], self.token_bytes[0..self.token_len]);
            return .{ .account = account_storage[0..self.account_len], .token = token_storage[0..self.token_len], .generation = self.generation };
        }
    };

    /// The one the catalog helpers below install, for the many tests that
    /// compose Models only through them. Every install starts it afresh, so
    /// nothing one test left in it reaches the next.
    pub var shared_credentials: FakeMetaskCredentials = .{};

    /// A port the test installed itself stays: the helper only installs the
    /// shared one where none, or the shared one, is.
    pub fn useSharedCredentials(runtime: *Runtime, account: []const u8, token: []const u8) void {
        shared_credentials = FakeMetaskCredentials.init(account, token, FakeMetaskCredentials.default_generation);
        if (runtime.metask_credentials) |installed| if (installed.context != @as(*anyopaque, @ptrCast(&shared_credentials))) return;
        runtime.metask_credentials = shared_credentials.port();
    }

    pub fn fixtureSelectionAvailable(runtime: *Runtime) bool {
        const target = runtime.view().default_selection orelse return false;
        const view = runtime.view();
        for (view.providers) |provider| if (std.mem.eql(u8, provider.id, target.source_id)) return runtime.sourceModelProtocol(target, provider.source_generation, provider.catalog_generation) != null;
        for (view.custom_providers) |provider| if (std.mem.eql(u8, provider.id, target.source_id)) return runtime.sourceModelProtocol(target, provider.source_generation, provider.catalog_generation) != null;
        return false;
    }
    pub fn resolveFixtureSelection(runtime: *Runtime) !?contract.OwnedSourceCandidate {
        const target = runtime.view().default_selection orelse return null;
        const view = runtime.view();
        for (view.providers) |provider| if (std.mem.eql(u8, provider.id, target.source_id)) return runtime.resolveModel(target, provider.source_generation, provider.catalog_generation);
        for (view.custom_providers) |provider| if (std.mem.eql(u8, provider.id, target.source_id)) return runtime.resolveModel(target, provider.source_generation, provider.catalog_generation);
        return null;
    }

    pub fn clearFixturePreference(runtime: *Runtime) void {
        _ = runtime.registry.clearDefault(runtime.registry.selection_revision + 1);
    }

    pub fn refreshMetaskCatalog(
        runtime: *Runtime,
        principal_ref: []const u8,
        models: []const contract.ModelView,
    ) !contract.ModelsError {
        return refreshMetaskCatalogWithCredential(runtime, principal_ref, "refreshed-secret", models);
    }

    pub fn refreshMetaskCatalogWithCredential(
        runtime: *Runtime,
        principal_ref: []const u8,
        credential: []const u8,
        models: []const contract.ModelView,
    ) !contract.ModelsError {
        var session = metask_provider.CatalogSession.init(runtime.allocator);
        defer session.deinit();
        try metask_provider.TestSupport.replaceOwnedCatalog(&session, principal_ref, models);
        return completeRequest(runtime, principal_ref, credential, &session);
    }

    pub fn refreshMetaskCatalogResponse(
        runtime: *Runtime,
        principal_ref: []const u8,
        response_body: []const u8,
    ) !contract.ModelsError {
        var session = metask_provider.CatalogSession.init(runtime.allocator);
        defer session.deinit();
        try metask_provider.TestSupport.loadCatalogResponse(&session, principal_ref, "refreshed-secret", response_body);
        return completeRequest(runtime, principal_ref, "refreshed-secret", &session);
    }

    /// One whole request as the person would ask for it: Models follows the
    /// account, the request starts with the credential of this moment and
    /// lands with `session`. The catalog error the view then shows, or none.
    fn completeRequest(runtime: *Runtime, principal_ref: []const u8, credential: []const u8, session: *metask_provider.CatalogSession) !contract.ModelsError {
        useSharedCredentials(runtime, principal_ref, credential);
        _ = runtime.followMetaskPrincipal(principal_ref, shared_credentials.generation);
        const id = switch (runtime.beginMetaskCatalogRequest(.user, .{ .ready = .{ .principal_ref = principal_ref, .generation = shared_credentials.generation } }, 0).outcome) {
            .started => |value| value,
            .skipped, .rejected => return error.TestUnexpectedResult,
        };
        var completion = metask_provider.OwnedCatalogCompletion.init(session);
        var port = completion.ownedPort();
        _ = runtime.completeMetaskCatalogRequest(id, &port, 0);
        return if (runtime.metask.catalog != null) .none else runtime.metaskError();
    }

    pub fn installMetaskDefault(
        runtime: *Runtime,
        principal_ref: []const u8,
        secret: []const u8,
        models: []const contract.ModelView,
        selected_model: []const u8,
        source_generation: u64,
        metask_selection_revision: u64,
        default_selection_revision: u64,
        catalog_generation: u64,
    ) !void {
        runtime.assertMainThread();
        runtime.clearMetask(false);
        if (!runtime.metask.principal.set(principal_ref)) return error.InvalidTestModel;
        runtime.metask.catalog = metask_provider.CatalogSession.init(runtime.allocator);
        const catalog = &runtime.metask.catalog.?;
        try metask_provider.TestSupport.replaceOwnedCatalog(catalog, principal_ref, models);
        useSharedCredentials(runtime, principal_ref, secret);
        if (!catalog.hasModel(selected_model))
            return error.InvalidTestModel;
        _ = metask_selection_revision;
        try runtime.registry.configureMetaskSource(principal_ref, source_generation);
        if (runtime.registry.defaultSelection()) |current| {
            if (runtime.registry.selection_revision == default_selection_revision) {
                _ = current;
                runtime.registry.selection_revision = 0;
            }
        }
        try runtime.registry.rememberPreference(
            .{ .source_id = contract.metask_source_id, .model_id = selected_model },
            catalog.preferenceDisplayName(selected_model),
            default_selection_revision,
        );
        runtime.metask.generation = catalog_generation;
        runtime.store_healthy = true;
        if (runtime.metask_public_catalog == null) {
            const public_catalog = try runtime.allocator.create(metask_provider.PublicCatalog);
            public_catalog.* = .{};
            runtime.metask_public_catalog = public_catalog;
        }
        runtime.metask_public_catalog.?.replaceFromSession(catalog);
    }
} else struct {};

/// Where one read of the Metask credential lands; zeroed after the call.
const MetaskCredentialStorage = struct {
    account: [contract.Limits.principal_ref_bytes]u8 = undefined,
    token: [contract.Limits.credential_bytes]u8 = undefined,

    fn zero(self: *MetaskCredentialStorage) void {
        std.crypto.secureZero(u8, &self.token);
        std.crypto.secureZero(u8, &self.account);
    }
};

fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), value: []const u8) bool {
            if (value.len > capacity or !std.unicode.utf8ValidateSlice(value))
                return false;
            if (value.len != 0) @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
            return true;
        }

        fn view(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const CanonicalCommitOutcome = enum {
    committed,
    not_committed,
    unresolved,
};

/// Commits one complete canonical image. A post-rename durability failure is
/// resolved only by reading the canonical file back and comparing exact bytes;
/// callers retain ownership of the policy decision for each outcome.
fn commitCanonical(
    allocator: std.mem.Allocator,
    store: anytype,
    bytes: []const u8,
) CanonicalCommitOutcome {
    store.commit(bytes) catch |err| {
        if (err != error.PersistenceOutcomeUnknown) return .not_committed;
        const loaded = store.loadAlloc(allocator) catch return .unresolved;
        const actual = loaded orelse return .unresolved;
        defer allocator.free(actual);
        return if (std.mem.eql(u8, actual, bytes)) .committed else .unresolved;
    };
    return .committed;
}

/// Where the Custom Provider keys Models holds for the projection come and
/// go. Each value is borrowed for the duration of its callback only.
pub const ResidentSink = struct {
    context: *anyopaque,
    /// A key about to be held. It is not yet visited, so the callee can tell
    /// whether anything else knew it. False: not held now, asked again at the
    /// next sync.
    admit_fn: *const fn (*anyopaque, []const u8) bool,
    /// A key about to be dropped, still visited. False: kept until the next
    /// sync, which only masks more.
    retire_fn: *const fn (*anyopaque, []const u8) bool,
};

/// One configured Custom Provider whose key Models holds for the projection
/// from the moment it is stored, not from its first use.
const Resident = struct {
    provider_id: []u8,
    /// The provider revision `secret` was read at.
    revision: u64,
    /// Null when the key at `revision` is a placeholder or was not found.
    secret: ?contract.SecretBuffer,
    /// A revision whose read failed. Not read again until the revision
    /// changes: some platform stores ask the person on every read.
    failed_revision: u64 = 0,
    /// A revision whose key the sink would not take or let go. Not read
    /// again until the revision changes or the sink says it can try again.
    refused_revision: u64 = 0,

    fn deinit(self: *Resident, allocator: std.mem.Allocator) void {
        if (self.secret) |*secret| secret.deinit();
        allocator.free(self.provider_id);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    registry: registry_impl.Registry,
    store: ?registry_impl.FileStore = null,
    store_healthy: bool = false,
    credential_vault: ?ports.CredentialVault = null,
    /// Where the Metask credential of the moment comes from, beside the vault.
    /// Read once per resolution; Models keeps no Metask token.
    metask_credentials: ?ports.MetaskCredentials = null,
    /// The Metask source's catalog, and when to ask for it again.
    metask: Metask = .{},
    metask_public_catalog: ?*metask_provider.PublicCatalog = null,
    preference_error: contract.ModelsError = .none,
    provider_views: [1]contract.ProviderView = undefined,
    resident: std.ArrayList(Resident) = .empty,

    /// The Metask catalog: one account's content, the load someone waits
    /// for while there is none, and the next time to ask. Its timing is
    /// Models' own; the Application only runs the timer and the request.
    const Metask = struct {
        /// The account followed; empty while none is signed in.
        principal: FixedText(contract.Limits.principal_ref_bytes) = .{},
        /// The credential generation of the last Account publication
        /// followed; 0 while no account is.
        followed_generation: u64 = 0,
        /// No account because one signed out or Models stopped.
        signed_out: bool = false,
        /// That account's catalog; a legal empty one is content too.
        catalog: ?metask_provider.CatalogSession = null,
        /// Changes only when the content does; 0 without content.
        generation: u64 = 0,
        /// Without content: the load someone waits for, or how it ended.
        load: union(enum) {
            none,
            loading: struct { failures: u1 = 0 },
            /// `generation`: the credential generation the last failed
            /// request used. Another one is worth one more try.
            failed: struct { code: contract.ModelsError, generation: u64 },
        } = .none,
        /// The one request underway.
        /// `followed`: the publication followed when it began; another one
        /// since means Account has a newer credential to try.
        request: ?struct { id: u64, generation: u64, followed: u64, visible: bool, user: bool } = null,
        next_request_id: u64 = 1,
        /// When to send the next request and why.
        next: union(enum) {
            none,
            /// At this time, in front or not: a load, its second try, a
            /// try with another credential, a reload after a reset.
            soon: u64,
            /// When Account next has a credential to give.
            credential,
            /// The beat: last result plus the interval, only in front.
            beat: u64,
        } = .none,
        /// MetaWork is in front.
        active: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, main_thread_id: std.Thread.Id) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .main_thread_id = main_thread_id,
            .registry = registry_impl.Registry.init(allocator),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.credential_vault == null);
        if (self.metask_public_catalog) |public_catalog|
            self.allocator.destroy(public_catalog);
        if (self.store) |*store| store.deinit();
        if (self.metask.catalog) |*catalog| catalog.deinit();
        for (self.resident.items) |*entry| entry.deinit(self.allocator);
        self.resident.deinit(self.allocator);
        self.registry.deinit();
        self.* = undefined;
    }

    /// Every configured key held for the projection.
    pub fn visitResidentCredentials(
        self: *const Runtime,
        context: *anyopaque,
        visit_fn: *const fn (*anyopaque, []const u8) std.mem.Allocator.Error!void,
    ) std.mem.Allocator.Error!void {
        for (self.resident.items) |*entry| if (entry.secret) |*secret| try visit_fn(context, secret.view());
    }

    /// Brings the held keys in line with the registry: a provider whose
    /// credential is ready is held from the moment it is stored, and dropped
    /// when it is gone, not ready, or Models stopped. Compared with the
    /// registry each time, so no change has to report itself. A placeholder
    /// key is not held: it is not a secret.
    pub fn syncResidentCredentials(self: *Runtime, sink: ResidentSink) void {
        self.assertMainThread();
        const providers: []const contract.CustomProviderView = if (self.credential_vault != null) self.registry.views() else &.{};
        var index: usize = 0;
        while (index < self.resident.items.len) {
            const entry = &self.resident.items[index];
            const ready = if (findProviderView(providers, entry.provider_id)) |provider| provider.credential_status == .ready else false;
            if (ready or !self.dropResident(entry, sink)) {
                index += 1;
                continue;
            }
            var removed = self.resident.orderedRemove(index);
            removed.deinit(self.allocator);
        }
        for (providers) |provider| {
            if (provider.credential_status != .ready) continue;
            const entry = for (self.resident.items) |*candidate| {
                if (std.mem.eql(u8, candidate.provider_id, provider.id)) break candidate;
            } else blk: {
                const provider_id = self.allocator.dupe(u8, provider.id) catch continue;
                self.resident.append(self.allocator, .{ .provider_id = provider_id, .revision = 0, .secret = null }) catch {
                    self.allocator.free(provider_id);
                    continue;
                };
                break :blk &self.resident.items[self.resident.items.len - 1];
            };
            if (entry.revision == provider.provider_revision or
                entry.failed_revision == provider.provider_revision or
                entry.refused_revision == provider.provider_revision) continue;
            self.readResident(entry, provider.provider_revision, sink);
        }
    }

    fn readResident(self: *Runtime, entry: *Resident, revision: u64, sink: ResidentSink) void {
        const vault = self.credential_vault.?;
        var storage: [contract.Limits.credential_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &storage);
        const read = vault.get(entry.provider_id, &storage) catch {
            // Keep what was held: a stale key only masks more.
            entry.failed_revision = revision;
            return;
        };
        const value: []const u8 = if (read) |bytes|
            if (contract.customProviderKeyIsSecret(bytes)) bytes else &.{}
        else
            &.{};
        if (entry.secret) |*held| if (std.mem.eql(u8, held.view(), value)) {
            entry.revision = revision;
            return;
        };
        if (!self.dropResident(entry, sink)) {
            entry.refused_revision = revision;
            return;
        }
        if (value.len != 0) {
            const owned = self.allocator.dupe(u8, value) catch {
                entry.failed_revision = revision;
                return;
            };
            if (!sink.admit_fn(sink.context, owned)) {
                std.crypto.secureZero(u8, owned);
                self.allocator.free(owned);
                entry.refused_revision = revision;
                return;
            }
            entry.secret = .initOwned(self.allocator, owned);
        }
        entry.revision = revision;
        entry.failed_revision = 0;
        entry.refused_revision = 0;
    }

    /// The sink can take or let go of keys again, as after its store
    /// recovered: the next sync reads each refused revision once more.
    pub fn retryRefusedResidentCredentials(self: *Runtime) void {
        self.assertMainThread();
        for (self.resident.items) |*entry| entry.refused_revision = 0;
    }

    /// Releases a held key after the sink has let it go. False: still held.
    fn dropResident(self: *Runtime, entry: *Resident, sink: ResidentSink) bool {
        _ = self;
        const held = if (entry.secret) |*value| value else return true;
        if (!sink.retire_fn(sink.context, held.view())) return false;
        held.deinit();
        entry.secret = null;
        return true;
    }

    pub fn start(self: *Runtime, absolute_directory: []const u8, vault: ports.CredentialVault) StartError!void {
        self.assertMainThread();
        std.debug.assert(self.store == null and self.credential_vault == null);
        if (absolute_directory.len == 0 or !std.fs.path.isAbsolute(absolute_directory))
            return error.CustomProvidersDirectoryUnavailable;
        const public_catalog = self.allocator.create(metask_provider.PublicCatalog) catch
            return error.ModelsStateUnavailable;
        public_catalog.* = .{};
        self.metask_public_catalog = public_catalog;
        self.credential_vault = vault;
        self.restore(absolute_directory);
    }

    pub fn startUnavailable(self: *Runtime) void {
        self.assertMainThread();
        std.debug.assert(self.store == null and self.credential_vault == null);
    }

    pub fn stop(self: *Runtime) void {
        self.assertMainThread();
        if (self.store) |*store| store.deinit();
        self.store = null;
        self.store_healthy = false;
        self.credential_vault = null;
        self.clearMetask(true);
        if (self.metask_public_catalog) |public_catalog| {
            self.allocator.destroy(public_catalog);
            self.metask_public_catalog = null;
        }
    }

    pub fn views(self: *Runtime) []const contract.CustomProviderView {
        self.assertMainThread();
        return self.registry.views();
    }

    pub fn view(self: *Runtime) contract.ModelsView {
        self.assertMainThread();
        const intent = self.registry.metaskSource();
        self.provider_views[0] = .{
            .id = contract.metask_source_id,
            .display_name = "Metask",
            .recommended = true,
            .catalog_state = self.metaskCatalogState(),
            .principal_ref = if (intent) |value| value.principal_ref else "",
            .models = if (self.metask_public_catalog) |public_catalog|
                public_catalog.modelViews()
            else
                &.{},
            .catalog_generation = self.metask.generation,
            .source_generation = if (intent) |value| value.source_generation else 0,
            .error_code = self.metaskError(),
            .safe_diagnostic = "",
        };
        return .{
            .availability = if (self.store_healthy) .ready else .unavailable,
            .persistence_health = if (self.store_healthy)
                .ready
            else if (self.store != null)
                .recovery_required
            else
                .unavailable,
            .providers = self.provider_views[0..],
            .default_selection = self.registry.defaultSelection(),
            .default_selection_display_name = if (self.registry.default_display_name.len == 0) null else self.registry.default_display_name,
            .selection_revision = self.registry.selection_revision,
            .operation = self.metaskOperation(),
            .error_code = if (!self.store_healthy) .persistence_unavailable else if (self.preference_error != .none) self.preference_error else self.metaskError(),
            .builtin_provider_presets = builtin_providers.views(),
            .custom_providers = self.registry.views(),
        };
    }

    pub fn sourceGenerations(self: *const Runtime, source_id: []const u8) ?registry_impl.Registry.SourceGenerations {
        self.assertMainThread();
        if (std.mem.eql(u8, source_id, contract.metask_source_id)) {
            const source = self.registry.metaskSource();
            return .{
                .source = if (source) |value| value.source_generation else 0,
                .catalog = self.metask.generation,
            };
        }
        return self.registry.sourceGenerations(source_id);
    }

    pub fn selectionCatalogAvailability(models: contract.ModelsView, intent_source: ?[]const u8) enum { available, catalog_loading, catalog_unavailable } {
        if (models.availability != .ready or models.persistence_health != .ready) return .catalog_unavailable;
        const source_scope = scope: {
            const source_id = intent_source orelse break :scope null;
            for (models.providers) |provider|
                if (std.mem.eql(u8, provider.id, source_id)) break :scope source_id;
            for (models.custom_providers) |provider|
                if (std.mem.eql(u8, provider.id, source_id)) break :scope source_id;
            break :scope null;
        };
        for (models.custom_providers) |provider| {
            if (source_scope) |source_id| if (!std.mem.eql(u8, provider.id, source_id)) continue;
            if (provider.state != .ready or !provider.enabled or provider.credential_status != .ready or
                provider.source_generation == 0 or provider.catalog_generation == 0) continue;
            for (provider.models) |model| {
                if (model.ready) return .available;
            }
        }
        var loading = false;
        for (models.providers) |provider| {
            if (source_scope) |source_id| if (!std.mem.eql(u8, provider.id, source_id)) continue;
            switch (provider.catalog_state) {
                .ready => {
                    if (provider.source_generation != 0 and provider.catalog_generation != 0 and provider.models.len != 0) return .available;
                },
                .loading, .choosing => loading = true,
                else => {},
            }
        }
        return if (loading) .catalog_loading else .catalog_unavailable;
    }

    /// What the current catalog says about one bound model. It reports Models
    /// facts only; what each answer means is the consumer's to decide.
    pub const BoundModel = union(enum) {
        /// Nothing to answer from now: the store, the catalog or the source's
        /// credential is not ready.
        unavailable,
        /// The binding names another identity of this source, or a source
        /// that no longer exists.
        source_changed,
        /// The bound source does not list this model.
        missing,
        present: struct { catalog_generation: u64, protocol: contract.Protocol },
    };

    pub fn boundModel(self: *Runtime, target: contract.ModelRef, source_generation: u64) BoundModel {
        const models = self.view();
        if (models.availability != .ready) return .unavailable;
        for (models.providers) |provider| {
            if (!std.mem.eql(u8, provider.id, target.source_id)) continue;
            if (provider.catalog_state != .ready) return .unavailable;
            if (provider.source_generation != source_generation) return .source_changed;
            return self.presentModel(target, source_generation, provider.catalog_generation);
        }
        for (models.custom_providers) |provider| {
            if (!std.mem.eql(u8, provider.id, target.source_id)) continue;
            if (!provider.enabled or provider.source_generation != source_generation) return .source_changed;
            // A missing credential keeps its generation until a new key brings
            // a new one, so it is not yet an answer about this binding.
            if (provider.credential_status != .ready) return .unavailable;
            return self.presentModel(target, source_generation, provider.catalog_generation);
        }
        return .source_changed;
    }

    fn presentModel(self: *Runtime, target: contract.ModelRef, source_generation: u64, catalog_generation: u64) BoundModel {
        const protocol = self.sourceModelProtocol(target, source_generation, catalog_generation) orelse return .missing;
        return .{ .present = .{ .catalog_generation = catalog_generation, .protocol = protocol } };
    }

    pub fn installedModelAvailable(self: *Runtime, target: contract.ModelRef, source_generation: u64, protocol: contract.Protocol) bool {
        const models = self.view();
        for (models.providers) |provider| if (std.mem.eql(u8, provider.id, target.source_id)) {
            if (provider.source_generation != source_generation) return false;
            // An installed Metask binding can retain its authority while the
            // catalog refresh is unavailable. Control still checks Account.
            if (provider.catalog_state == .loading or provider.catalog_state == .failed or provider.catalog_state == .unavailable)
                return true;
            return self.sourceModelProtocol(target, source_generation, provider.catalog_generation) == protocol;
        };
        for (models.custom_providers) |provider| if (std.mem.eql(u8, provider.id, target.source_id))
            return self.sourceModelProtocol(target, source_generation, provider.catalog_generation) == protocol;
        return false;
    }

    /// What the Metask source can do now, for the account it follows: the
    /// one Models answer every Metask admission reads.
    pub fn metaskCatalog(self: *const Runtime) contract.MetaskCatalogAvailability {
        if (self.metask.principal.len == 0) return .absent;
        if (self.metask.catalog != null) return .ready;
        return switch (self.metask.load) {
            .none => .absent,
            .loading => .loading,
            .failed => .failed,
        };
    }

    fn metaskCatalogState(self: *const Runtime) contract.CatalogState {
        return switch (self.metaskCatalog()) {
            .absent => .needs_authentication,
            .ready => .ready,
            .loading => .loading,
            .failed => .failed,
        };
    }

    fn metaskError(self: *const Runtime) contract.ModelsError {
        if (self.metask.principal.len == 0) return if (self.metask.signed_out) .authorization_unavailable else .none;
        if (self.metask.catalog != null) {
            const public_catalog = self.metask_public_catalog orelse return .none;
            return if (public_catalog.model_count == 0) .no_models else .none;
        }
        return switch (self.metask.load) {
            .failed => |failed| failed.code,
            .none, .loading => .none,
        };
    }

    /// Lit while a load runs, its retry included, or while the person's own
    /// request does; a request in the background never lights it. A failed
    /// load is idle: the person asking turns it back into a load first.
    fn metaskOperation(self: *const Runtime) contract.ModelsOperation {
        if (self.metask.catalog == null) return switch (self.metask.load) {
            .loading => .refreshing_catalog,
            .none, .failed => .idle,
        };
        const request = self.metask.request orelse return .idle;
        return if (request.user) .refreshing_catalog else .idle;
    }

    /// What a request's outcome can change that anyone sees.
    const MetaskFacts = struct {
        state: contract.CatalogState,
        error_code: contract.ModelsError,
        operation: contract.ModelsOperation,
        generation: u64,
    };

    fn metaskFacts(self: *const Runtime) MetaskFacts {
        return .{
            .state = self.metaskCatalogState(),
            .error_code = self.metaskError(),
            .operation = self.metaskOperation(),
            .generation = self.metask.generation,
        };
    }

    fn metaskChanged(self: *const Runtime, before: MetaskFacts) bool {
        return !std.meta.eql(before, self.metaskFacts());
    }

    /// Follows the account an Account publication leaves. The content
    /// belongs to the account: another one, or none, empties it; a new
    /// credential for the same one changes nothing, except that a load
    /// waiting for a credential, or one that failed on another, may now try.
    pub fn followMetaskPrincipal(self: *Runtime, principal_ref: ?[]const u8, generation: u64) contract.MetaskFollow {
        self.assertMainThread();
        const principal = principal_ref orelse {
            if (self.metask.principal.len == 0) {
                // Signed out only after an account: at a cold start without
                // one nothing was lost.
                const changed = !self.metask.signed_out and self.metask.followed_generation != 0;
                if (changed) self.metask.signed_out = true;
                self.metask.followed_generation = 0;
                return .{ .changed = changed, .dropped = false };
            }
            const dropped = self.metask.request != null;
            self.clearMetask(true);
            return .{ .changed = true, .dropped = dropped };
        };
        if (std.mem.eql(u8, principal, self.metask.principal.view())) {
            self.metask.followed_generation = generation;
            if (self.metask.request == null) {
                const retry = switch (self.metask.next) {
                    .credential => true,
                    else => if (self.metask.catalog == null) switch (self.metask.load) {
                        .failed => |failed| failed.generation != generation,
                        .none, .loading => false,
                    } else false,
                };
                if (retry) self.metask.next = .{ .soon = 0 };
            }
            return .{ .changed = false, .dropped = false };
        }
        const dropped = self.metask.request != null;
        self.clearMetask(false);
        self.metask.followed_generation = generation;
        // Account validated the account it gives; one Models could not hold
        // is no account here.
        if (!self.metask.principal.set(principal) or principal.len == 0) {
            self.metask.principal = .{};
            return .{ .changed = true, .dropped = dropped };
        }
        self.metask.load = .{ .loading = .{} };
        self.metask.next = .{ .soon = 0 };
        return .{ .changed = true, .dropped = dropped };
    }

    pub fn setMetaskCatalogActive(self: *Runtime, active: bool) void {
        self.assertMainThread();
        self.metask.active = active;
    }

    /// When the next catalog request is due; null when none is asked for
    /// now. The beat waits in the background and while the store cannot be
    /// trusted; a load still comes due there, so its wait can end.
    pub fn metaskCatalogNext(self: *const Runtime) ?u64 {
        if (self.metask.principal.len == 0 or self.metask.request != null) return null;
        return switch (self.metask.next) {
            .none, .credential => null,
            .soon => |at| at,
            .beat => |at| if (self.metask.active and self.store_healthy) at else null,
        };
    }

    pub fn metaskCatalogDue(self: *const Runtime, now_ms: u64) bool {
        const at = self.metaskCatalogNext() orelse return false;
        return now_ms >= at;
    }

    /// Starts the one catalog request, when Models finds it due or the
    /// person asks. Without content it is the load someone waits for; with
    /// content nobody sees it unless the person asked.
    pub fn beginMetaskCatalogRequest(self: *Runtime, kind: contract.CatalogRequestKind, credential: contract.CatalogCredential, now_ms: u64) contract.CatalogRequestStart {
        self.assertMainThread();
        if (self.metask.principal.len == 0) return .{ .outcome = .{ .rejected = .authorization_unavailable }, .changed = false };
        if (self.metask.request != null) return .{ .outcome = .{ .rejected = .operation_in_progress }, .changed = false };
        if (kind == .due and !self.metaskCatalogDue(now_ms)) return .{ .outcome = .skipped, .changed = false };
        const before = self.metaskFacts();
        if (!self.store_healthy) {
            if (self.metask.catalog == null and self.metask.load == .loading)
                self.metask.load = .{ .failed = .{ .code = .persistence_unavailable, .generation = 0 } };
            self.metask.next = .none;
            return .{ .outcome = .{ .rejected = .persistence_unavailable }, .changed = self.metaskChanged(before) };
        }
        const ready = switch (credential) {
            .ready => |value| if (std.mem.eql(u8, value.principal_ref, self.metask.principal.view())) value else null,
            .unavailable => null,
            .exhausted => {
                if (kind == .user and self.metask.catalog == null) self.metask.load = .{ .loading = .{} };
                // Nothing to do with the credential: the one of the moment
                // is as good as tried, so only another one, or the beat,
                // asks again.
                self.settleMetaskFailure(self.metask.catalog == null and self.metask.load == .loading, self.metask.followed_generation, false, .{ .code = .local_resource_exhausted, .retryable = false }, now_ms);
                return .{ .outcome = .{ .rejected = .local_resource_exhausted }, .changed = self.metaskChanged(before) };
            },
        } orelse {
            // Someone may wait for a load; a refresh just skips this beat.
            self.metask.next = if (self.metask.catalog == null) .credential else .{ .beat = now_ms +| metask_provider.refresh_interval_ms };
            return .{ .outcome = .{ .rejected = .authorization_unavailable }, .changed = false };
        };
        if (self.metask.catalog == null and kind == .user) self.metask.load = .{ .loading = .{} };
        const id = self.metask.next_request_id;
        self.metask.next_request_id +%= 1;
        if (self.metask.next_request_id == 0) self.metask.next_request_id = 1;
        self.metask.request = .{
            .id = id,
            .generation = ready.generation,
            .followed = self.metask.followed_generation,
            .visible = self.metask.catalog == null and self.metask.load == .loading,
            .user = kind == .user,
        };
        self.metask.next = .none;
        return .{ .outcome = .{ .started = id }, .changed = self.metaskChanged(before) };
    }

    /// The person asked while a request is underway: it becomes theirs, and
    /// one in the background after a failed load becomes the load they see.
    pub fn joinMetaskCatalogRequest(self: *Runtime) bool {
        self.assertMainThread();
        if (self.metask.request == null) return false;
        const before = self.metaskFacts();
        self.metask.request.?.user = true;
        if (self.metask.catalog == null and self.metask.load == .failed) {
            self.metask.load = .{ .loading = .{} };
            self.metask.request.?.visible = true;
        }
        return self.metaskChanged(before);
    }

    pub fn completeMetaskCatalogRequest(self: *Runtime, id: u64, completion_port: *ports.OwnedCatalogCompletion, now_ms: u64) bool {
        self.assertMainThread();
        const completion = metask_provider.fromOwnedPort(completion_port) orelse {
            completion_port.deinit();
            return self.failMetaskCatalogRequest(id, .{ .code = .catalog_invalid, .retryable = false }, now_ms);
        };
        defer completion_port.deinit();
        const request = self.metask.request orelse return false;
        if (request.id != id) return false;
        const before = self.metaskFacts();
        self.metask.request = null;
        const session = &completion.session;
        const failure: ?contract.ModelsError = failure: {
            if (!std.mem.eql(u8, session.ownerAccountId(), self.metask.principal.view())) break :failure .catalog_invalid;
            if (!self.store_healthy) break :failure .persistence_unavailable;
            if (self.ensureMetaskSource()) |code| break :failure code;
            if (self.metask.catalog) |*catalog| if (catalog.sameContent(session)) break :failure null;
            const public_catalog = self.metask_public_catalog orelse break :failure .persistence_unavailable;
            const generation = self.freshGeneration(self.metask.generation) catch break :failure .local_resource_exhausted;
            if (self.metask.catalog) |*catalog| catalog.deinit();
            self.metask.catalog = session.take();
            public_catalog.replaceFromSession(&self.metask.catalog.?);
            self.metask.generation = generation;
            self.metask.load = .none;
            break :failure null;
        };
        if (failure) |code| {
            self.settleMetaskFailure(request.visible, request.generation, request.followed != self.metask.followed_generation, .{ .code = code, .retryable = false }, now_ms);
        } else {
            self.metask.next = .{ .beat = now_ms +| metask_provider.refresh_interval_ms };
        }
        return self.metaskChanged(before);
    }

    pub fn failMetaskCatalogRequest(self: *Runtime, id: u64, failure: contract.CatalogFailure, now_ms: u64) bool {
        self.assertMainThread();
        const request = self.metask.request orelse return false;
        if (request.id != id) return false;
        const before = self.metaskFacts();
        self.metask.request = null;
        self.settleMetaskFailure(request.visible, request.generation, request.followed != self.metask.followed_generation, failure, now_ms);
        return self.metaskChanged(before);
    }

    /// A load gets one more try a moment later when that may help; then it
    /// ends as failed and the beat takes over, unless Account gave another
    /// credential while this one was underway: that one is tried at once.
    /// A failure out of sight changes nothing anyone sees.
    fn settleMetaskFailure(self: *Runtime, visible: bool, generation: u64, superseded: bool, failure: contract.CatalogFailure, now_ms: u64) void {
        if (visible and self.metask.load == .loading) {
            if (failure.retryable and self.metask.load.loading.failures == 0) {
                self.metask.load.loading.failures = 1;
                self.metask.next = .{ .soon = now_ms +| metask_provider.retry_delay_ms };
                return;
            }
            self.metask.load = .{ .failed = .{ .code = if (failure.code == .none) .catalog_invalid else failure.code, .generation = generation } };
        } else if (self.metask.catalog == null) switch (self.metask.load) {
            .failed => |*failed| failed.generation = generation,
            .none, .loading => {},
        };
        const again = superseded and self.metask.catalog == null and self.metask.load == .failed;
        self.metask.next = if (again) .{ .soon = 0 } else .{ .beat = now_ms +| metask_provider.refresh_interval_ms };
    }

    /// The source identity of the account whose content is installed, in
    /// models.json. The one place it is written; null when it holds.
    fn ensureMetaskSource(self: *Runtime) ?contract.ModelsError {
        const principal_ref = self.metask.principal.view();
        if (self.registry.metaskSource()) |source| if (std.mem.eql(u8, source.principal_ref, principal_ref)) return null;
        var candidate = self.registry.clone() catch return .local_resource_exhausted;
        defer candidate.deinit();
        candidate.configureMetaskSource(principal_ref, registry_impl.metaskSourceGeneration(principal_ref)) catch return .local_resource_exhausted;
        if (!self.commitCandidate(&candidate, true).accepted) return .persistence_unavailable;
        return null;
    }

    /// Resolve the preferred model or the first eligible catalog entry with
    /// the credential of this moment. No user selection is persisted.
    pub fn prepareMediaCandidate(self: *Runtime, kind: contract.MediaKind) contract.MediaPreparation {
        self.assertMainThread();
        if (!self.store_healthy) return .{ .rejected = .persistence_unavailable };
        const catalog = if (self.metask.catalog) |*value| value else return .{ .rejected = .catalog_unavailable };
        var storage: MetaskCredentialStorage = .{};
        defer storage.zero();
        const credential = (self.readMetaskCredential(&storage) catch return .{ .rejected = .local_resource_exhausted }) orelse
            return .{ .rejected = .authorization_unavailable };
        const selected = switch (kind) {
            .image => if (catalog.hasImageModel(contract.metask_default_image_model))
                contract.metask_default_image_model
            else
                catalog.firstImageModelId(),
            .video => catalog.selectVideoModel(contract.metask_default_video_model),
        };
        var candidate = contract.OwnedMediaCandidate.copy(
            self.allocator,
            kind,
            selected orelse return .{ .rejected = .model_not_found },
            credential.token,
            self.metask.generation,
        ) catch |err| return .{ .rejected = if (err == error.OutOfMemory) .local_resource_exhausted else .invalid_provider };
        candidate.credential_generation = credential.generation;
        return .{ .ready = candidate };
    }

    pub const MetaskAdoption = struct { stored: u64, derived: u64 };

    /// The generation an older version drew for the stored account, while it
    /// is still the one in use.
    pub fn pendingMetaskAdoption(self: *const Runtime) ?MetaskAdoption {
        self.assertMainThread();
        if (!self.store_healthy) return null;
        const source = self.registry.metaskSource() orelse return null;
        const derived = registry_impl.metaskSourceGeneration(source.principal_ref);
        return if (source.source_generation == derived) null else .{ .stored = source.source_generation, .derived = derived };
    }

    /// Memory moves first, because the bindings that named the stored value
    /// already moved. A failed write leaves that value for the next start.
    pub fn adoptMetaskGeneration(self: *Runtime, adoption: MetaskAdoption) void {
        self.assertMainThread();
        self.registry.metask_source_generation = adoption.derived;
        const encoded = registry_impl.encodeAlloc(self.allocator, &self.registry) catch return;
        defer self.allocator.free(encoded);
        const store = if (self.store) |*value| value else return;
        if (commitCanonical(self.allocator, store, encoded) == .unresolved) self.store_healthy = false;
    }

    /// Best-effort memory of a confirmed interactive consumer choice. This
    /// writes metadata only, without resolving credentials or execution.
    pub fn rememberPreference(self: *Runtime, target: contract.ModelRef) contract.CommandResult {
        const result = self.commitPreference(target);
        self.preference_error = if (result.accepted) .none else .preference_not_saved;
        return result;
    }

    fn commitPreference(self: *Runtime, target: contract.ModelRef) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        const display_name = self.preferenceDisplayName(target);
        if (self.registry.defaultSelection()) |current| {
            // After an unconfirmed write, retained memory is not evidence of
            // the canonical preference. Confirm this choice before clearing
            // the independent failure diagnostic, even if it matches memory.
            if (self.preference_error == .none and
                std.mem.eql(u8, current.source_id, target.source_id) and
                std.mem.eql(u8, current.model_id, target.model_id) and
                std.mem.eql(u8, self.registry.default_display_name, display_name))
                return .acceptedResult();
        }
        var candidate = self.registry.clone() catch return .rejected(.local_resource_exhausted);
        defer candidate.deinit();
        const revision = self.freshGeneration(candidate.selection_revision) catch return .rejected(.local_resource_exhausted);
        candidate.rememberPreference(target, display_name, revision) catch |err| return .rejected(mapRegistryError(err));
        const encoded = registry_impl.encodeAlloc(self.allocator, &candidate) catch |err| return .rejected(mapRegistryError(err));
        defer self.allocator.free(encoded);
        const store = if (self.store) |*value| value else return .rejected(.persistence_unavailable);
        return self.finishPreferenceCommit(&candidate, commitCanonical(self.allocator, store, encoded));
    }

    fn preferenceDisplayName(self: *Runtime, target: contract.ModelRef) []const u8 {
        if (!std.mem.eql(u8, target.source_id, contract.metask_source_id)) return "";
        const catalog = if (self.metask.catalog) |*value| value else return "";
        return catalog.preferenceDisplayName(target.model_id);
    }

    fn finishPreferenceCommit(self: *Runtime, candidate: *registry_impl.Registry, outcome: CanonicalCommitOutcome) contract.CommandResult {
        // Both possible canonical images have identical provider authority.
        // Reject an unconfirmed preference without revoking unrelated execution.
        if (outcome != .committed) return .rejected(.persistence_unavailable);
        self.registry.replace(candidate);
        return .acceptedResult();
    }

    pub fn metaskModelAvailable(
        self: *const Runtime,
        expected_catalog_generation: ?u64,
        protocol: contract.Protocol,
        model_id: []const u8,
    ) bool {
        self.assertMainThread();
        const catalog = if (self.metask.catalog) |*value| value else return false;
        if (catalog.modelProtocol(model_id) != protocol or !catalog.hasModel(model_id))
            return false;
        if (expected_catalog_generation) |expected|
            return expected != 0 and expected == self.metask.generation;
        return true;
    }

    /// Validates one source-qualified member of the current Metask catalog.
    /// This is provider state only; callers decide what consumer operation the
    /// validated model may be used for.
    pub fn metaskSourceModelAvailable(
        self: *const Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
        protocol: contract.Protocol,
    ) bool {
        self.assertMainThread();
        const intent = self.registry.metaskSource() orelse return false;
        if (intent.source_generation == 0 or
            intent.source_generation != expected_source_generation)
            return false;
        return std.mem.eql(u8, target.source_id, contract.metask_source_id) and
            self.metaskModelAvailable(
                expected_catalog_generation,
                protocol,
                target.model_id,
            );
    }

    /// Validates one source-qualified model against the exact current source
    /// and catalog generations. This does not change the global default.
    pub fn sourceModelAvailable(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
        protocol: contract.Protocol,
    ) bool {
        return self.sourceModelProtocol(target, expected_source_generation, expected_catalog_generation) == protocol;
    }

    /// Resolves the protocol declared by an exact ready source/catalog member.
    /// Consumer selection is independent of the Models global default.
    pub fn sourceModelProtocol(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
    ) ?contract.Protocol {
        self.assertMainThread();
        if (!self.store_healthy or expected_source_generation == 0 or expected_catalog_generation == 0)
            return null;
        if (std.mem.eql(u8, target.source_id, contract.metask_source_id)) {
            const catalog = if (self.metask.catalog) |*value| value else return null;
            const protocol = catalog.modelProtocol(target.model_id) orelse return null;
            return if (self.metaskSourceModelAvailable(
                target,
                expected_source_generation,
                expected_catalog_generation,
                protocol,
            )) protocol else null;
        }
        for (self.registry.views()) |provider| {
            if (!std.mem.eql(u8, provider.id, target.source_id)) continue;
            if (provider.state != .ready or
                provider.credential_status != .ready or
                !provider.enabled or
                provider.source_generation != expected_source_generation or
                provider.catalog_generation != expected_catalog_generation)
                return null;
            for (provider.models) |model|
                if (model.ready and std.mem.eql(u8, model.id, target.model_id))
                    return provider.protocol;
            return null;
        }
        return null;
    }

    pub fn submitCommand(self: *Runtime, command: contract.CustomProviderCommand) contract.CommandResult {
        self.assertMainThread();
        contract.validateCustomProviderCommand(command) catch
            return .rejected(.invalid_provider);
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        switch (command) {
            .create => |value| {
                if (value.spec.builtin_provider_id != null)
                    return .rejected(.invalid_provider);
                const provider_revision = self.freshGeneration(0) catch
                    return .rejected(.local_resource_exhausted);
                const source_generation = self.freshGeneration(provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(source_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.create(value, provider_revision, source_generation, catalog_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .update => |value| {
                const current = findProviderView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.provider_not_found);
                if (current.builtin_provider_id != null or
                    value.spec.builtin_provider_id != null)
                    return .rejected(.invalid_provider);
                const authority_changed = current.protocol != value.spec.protocol or
                    !std.mem.eql(u8, current.normalized_base_url, value.spec.normalized_base_url);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const source_generation = if (authority_changed)
                    self.freshGeneration(candidate.sourceGenerationForProvider(current.id) orelse
                        return .rejected(.provider_not_found)) catch
                        return .rejected(.local_resource_exhausted)
                else
                    null;
                candidate.update(value, provider_revision, source_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .remove => |value| {
                candidate.remove(value) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .test_model => |value| candidate.markTesting(value) catch |err|
                return .rejected(mapRegistryError(err)),
            .add_custom_model => |value| {
                const current = findProviderView(candidate.views(), value.source_id) orelse
                    return .rejected(.provider_not_found);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.addCustomModel(value, provider_revision, catalog_generation) catch |err|
                    return .rejected(mapRegistryError(err));
            },
            .replace_custom_model => |value| {
                const current = findProviderView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.provider_not_found);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.replaceCustomModel(
                    value,
                    provider_revision,
                    catalog_generation,
                ) catch |err| return .rejected(mapRegistryError(err));
            },
            .remove_custom_model => |value| {
                const current = findProviderView(candidate.views(), value.selection.source_id) orelse
                    return .rejected(.provider_not_found);
                const provider_revision = self.freshGeneration(current.provider_revision) catch
                    return .rejected(.local_resource_exhausted);
                const catalog_generation = self.freshGeneration(current.catalog_generation) catch
                    return .rejected(.local_resource_exhausted);
                candidate.removeCustomModel(
                    value,
                    provider_revision,
                    catalog_generation,
                ) catch |err| return .rejected(mapRegistryError(err));
            },
        }
        return self.commitCandidate(&candidate, true);
    }

    pub fn completeTest(
        self: *Runtime,
        command: contract.CustomModelTestCommand,
        succeeded: bool,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        candidate.completeTest(command, succeeded) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    pub fn clearDefault(self: *Runtime) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        if (candidate.defaultSelection() == null) return .acceptedResult();
        const selection_revision = self.freshGeneration(candidate.selection_revision) catch
            return .rejected(.local_resource_exhausted);
        if (!candidate.clearDefault(selection_revision)) return .acceptedResult();
        return self.commitCandidate(&candidate, true);
    }

    /// Recovers the Models canonical store without destroying a valid current
    /// schema. Missing or strictly invalid canonical bytes are replaced with
    /// the current empty schema after the caller explicitly requests reset.
    pub fn resetStore(self: *Runtime) contract.CommandResult {
        self.assertMainThread();
        if (self.store == null or self.store_healthy)
            return .rejected(.persistence_unavailable);
        if (self.metask.request != null)
            return .rejected(.operation_in_progress);
        const store = if (self.store) |*value| value else return .rejected(.persistence_unavailable);
        const bytes_optional = store.loadAlloc(self.allocator) catch
            return .rejected(.persistence_unavailable);
        if (bytes_optional) |bytes| {
            defer self.allocator.free(bytes);
            var restored = registry_impl.decode(self.allocator, bytes) catch |err| {
                if (err == error.OutOfMemory) return .rejected(.local_resource_exhausted);
                if (registry_impl.isRetiredCanonical(self.allocator, bytes)) {
                    return self.installEmptyRecovery(store, bytes);
                }
                return self.installEmptyRecovery(store, null);
            };
            defer restored.deinit();
            if (restored.reconcileInterruptedTests()) {
                const reconciled = registry_impl.encodeAlloc(self.allocator, &restored) catch |err|
                    return .rejected(mapRegistryError(err));
                defer self.allocator.free(reconciled);
                if (commitCanonical(self.allocator, store, reconciled) != .committed)
                    return .rejected(.persistence_unavailable);
            }
            self.registry.replace(&restored);
            self.store_healthy = true;
            self.reloadMetask();
            self.drainCredentialCleanup();
            return .acceptedResult();
        }
        return self.installEmptyRecovery(store, null);
    }

    fn installEmptyRecovery(
        self: *Runtime,
        store: *registry_impl.FileStore,
        retired_bytes: ?[]const u8,
    ) contract.CommandResult {
        var candidate = self.registry.resetCandidate() catch |err|
            return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        if (retired_bytes) |bytes| {
            registry_impl.collectRetiredCredentialDeletions(&candidate, bytes) catch |err|
                return .rejected(if (err == error.OutOfMemory) .local_resource_exhausted else .persistence_unavailable);
            for (candidate.credentialDeletions()) |slot|
                if (!ports.validCredentialSlot(slot)) return .rejected(.persistence_unavailable);
            store.quarantine(bytes) catch return .rejected(.persistence_unavailable);
        }
        const encoded = registry_impl.encodeAlloc(self.allocator, &candidate) catch |err|
            return .rejected(mapRegistryError(err));
        defer self.allocator.free(encoded);
        if (commitCanonical(self.allocator, store, encoded) != .committed)
            return .rejected(.persistence_unavailable);
        self.registry.replace(&candidate);
        self.store_healthy = true;
        self.reloadMetask();
        self.drainCredentialCleanup();
        return .acceptedResult();
    }

    pub fn createWithCredential(
        self: *Runtime,
        secret: []const u8,
        spec: contract.CustomProviderSpec,
    ) contract.CommandResult {
        if (spec.builtin_provider_id != null)
            return .rejected(.invalid_provider);
        return self.createWithResolvedCredential(secret, spec);
    }

    pub fn createBuiltinWithCredential(
        self: *Runtime,
        secret: []const u8,
        provider_id: contract.BuiltinProviderId,
        base_url: []const u8,
        initial_model: ?contract.CustomModelInput,
    ) contract.CommandResult {
        const definition = builtin_providers.find(provider_id);
        const endpoint = contract.completionEndpointFromBaseUrlAlloc(
            self.allocator,
            definition.protocol,
            base_url,
        ) catch return .rejected(.invalid_provider);
        defer self.allocator.free(endpoint);
        var spec = definition.spec(endpoint);
        spec.initial_model = initial_model;
        return self.createWithResolvedCredential(secret, spec);
    }

    pub fn updateBuiltinBaseUrl(
        self: *Runtime,
        selection: contract.CustomProviderSelectionCommand,
        base_url: []const u8,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        var candidate = self.registry.clone() catch |err|
            return .rejected(mapRegistryError(err));
        defer candidate.deinit();
        const current = findProviderView(candidate.views(), selection.source_id) orelse
            return .rejected(.provider_not_found);
        if (current.provider_revision != selection.expected_provider_revision)
            return .rejected(.generation_mismatch);
        const builtin_provider_id = current.builtin_provider_id orelse
            return .rejected(.invalid_provider);
        const definition = builtin_providers.find(builtin_provider_id);
        const endpoint = contract.completionEndpointFromBaseUrlAlloc(
            self.allocator,
            definition.protocol,
            base_url,
        ) catch return .rejected(.invalid_provider);
        defer self.allocator.free(endpoint);
        if (std.mem.eql(u8, current.normalized_base_url, endpoint))
            return .acceptedResult();
        const provider_revision = self.freshGeneration(current.provider_revision) catch
            return .rejected(.local_resource_exhausted);
        const source_generation = self.freshGeneration(
            candidate.sourceGenerationForProvider(current.id) orelse
                return .rejected(.provider_not_found),
        ) catch return .rejected(.local_resource_exhausted);
        candidate.update(.{
            .selection = selection,
            .spec = definition.spec(endpoint),
        }, provider_revision, source_generation) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&candidate, true);
    }

    fn createWithResolvedCredential(
        self: *Runtime,
        secret: []const u8,
        spec: contract.CustomProviderSpec,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        contract.validateCustomProviderSpec(spec) catch return .rejected(.invalid_provider);
        if (secret.len == 0 or secret.len > contract.Limits.credential_bytes)
            return .rejected(.invalid_provider);
        const vault = self.credential_vault orelse return .rejected(.capture_unavailable);
        var slot_storage: [ports.credential_slot_bytes]u8 = undefined;
        const slot_id = vault.generateSlot(&slot_storage) catch
            return .rejected(.credential_write_failed);

        var reserved = self.registry.clone() catch |err| return .rejected(mapRegistryError(err));
        defer reserved.deinit();
        reserved.reserveCredentialDeletion(slot_id) catch |err| return .rejected(mapRegistryError(err));
        const reserve_result = self.commitCandidate(&reserved, false);
        if (!reserve_result.accepted) return reserve_result;

        vault.store(slot_id, secret) catch {
            self.drainCredentialCleanup();
            return .rejected(.credential_write_failed);
        };
        var committed = self.registry.clone() catch |err| {
            self.drainCredentialCleanup();
            return .rejected(mapRegistryError(err));
        };
        defer committed.deinit();
        const provider_revision = self.freshGeneration(0) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        const source_generation = self.freshGeneration(provider_revision) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        const catalog_generation = self.freshGeneration(source_generation) catch {
            self.drainCredentialCleanup();
            return .rejected(.local_resource_exhausted);
        };
        committed.create(.{
            .provider_id = slot_id,
            .spec = spec,
            .credential_slot = .{ .id = slot_id },
        }, provider_revision, source_generation, catalog_generation) catch |err| {
            self.drainCredentialCleanup();
            return .rejected(mapRegistryError(err));
        };
        committed.completeCredentialDeletion(slot_id) catch {
            self.drainCredentialCleanup();
            return .rejected(.invalid_provider);
        };
        const result = self.commitCandidate(&committed, true);
        if (!result.accepted and self.store_healthy) self.drainCredentialCleanup();
        return result;
    }

    /// Replaces a credential using a fail-closed two-commit transaction:
    /// first revoke durable readiness, then write the Host secret, and only
    /// then publish a fresh source authority. A partial failure therefore
    /// leaves a repairable non-runnable provider, never stale readiness.
    pub fn replaceCredential(
        self: *Runtime,
        secret: []const u8,
        selection: contract.CustomProviderSelectionCommand,
    ) contract.CommandResult {
        self.assertMainThread();
        if (!self.store_healthy) return .rejected(.persistence_unavailable);
        if (secret.len == 0 or secret.len > contract.Limits.credential_bytes)
            return .rejected(.invalid_provider);
        const vault = self.credential_vault orelse return .rejected(.capture_unavailable);

        var revoked = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer revoked.deinit();
        revoked.markCredentialMissing(selection) catch |err|
            return .rejected(mapRegistryError(err));
        const revoke_result = self.commitCandidate(&revoked, false);
        if (!revoke_result.accepted) return revoke_result;

        vault.store(selection.source_id, secret) catch
            return .rejected(.credential_write_failed);

        const current = findProviderView(self.registry.views(), selection.source_id) orelse
            return .rejected(.provider_not_found);
        var restored = self.registry.clone() catch
            return .rejected(.local_resource_exhausted);
        defer restored.deinit();
        const provider_revision = self.freshGeneration(current.provider_revision) catch
            return .rejected(.local_resource_exhausted);
        const source_generation = self.freshGeneration(current.source_generation) catch
            return .rejected(.local_resource_exhausted);
        restored.restoreCredential(selection, provider_revision, source_generation) catch |err|
            return .rejected(mapRegistryError(err));
        return self.commitCandidate(&restored, true);
    }

    pub fn nextGeneration(self: *Runtime, current_generation: u64) !u64 {
        return self.freshGeneration(current_generation);
    }

    fn freshGeneration(self: *Runtime, current_generation: u64) !u64 {
        self.assertMainThread();
        while (true) {
            var bytes: [@sizeOf(u64)]u8 = undefined;
            try std.Io.randomSecure(self.io, &bytes);
            const generation = std.mem.readInt(u64, &bytes, .big);
            if (generation != 0 and generation != current_generation) return generation;
        }
    }

    /// Empties the Metask catalog and forgets the account; front or back stays.
    fn clearMetask(self: *Runtime, signed_out: bool) void {
        self.dropMetaskContent();
        self.metask.principal = .{};
        self.metask.followed_generation = 0;
        self.metask.signed_out = signed_out;
        self.metask.load = .none;
        self.metask.request = null;
        self.metask.next = .none;
    }

    fn dropMetaskContent(self: *Runtime) void {
        if (self.metask.catalog) |*catalog| catalog.deinit();
        self.metask.catalog = null;
        self.metask.generation = 0;
        if (self.metask_public_catalog) |public_catalog| public_catalog.clear();
    }

    /// A reset replaced models.json: what the catalog proved about it no
    /// longer holds, so the account followed loads again at once and its
    /// source identity is written back when that load lands.
    fn reloadMetask(self: *Runtime) void {
        if (self.metask.principal.len == 0) return;
        self.dropMetaskContent();
        self.metask.load = .{ .loading = .{} };
        self.metask.next = .{ .soon = 0 };
    }

    pub fn resolveProbeCandidate(
        self: *Runtime,
        command: contract.CustomModelTestCommand,
    ) !contract.OwnedSourceCandidate {
        self.assertMainThread();
        return self.resolveBindingCandidate(
            try self.registry.probeBinding(command),
        );
    }

    /// What resolving this model now would install, without its credential.
    pub fn currentTarget(self: *Runtime, target: contract.ModelRef) ?contract.TargetFacts {
        const generations = self.sourceGenerations(target.source_id) orelse return null;
        return self.targetFacts(target, generations.source, generations.catalog);
    }

    fn targetFacts(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
    ) ?contract.TargetFacts {
        const protocol = self.sourceModelProtocol(target, expected_source_generation, expected_catalog_generation) orelse return null;
        if (std.mem.eql(u8, target.source_id, contract.metask_source_id)) return .{
            .source_id = contract.metask_source_id,
            .model_id = target.model_id,
            .protocol = protocol,
            .base_url = contract.metaskEndpoint(protocol) orelse return null,
            .image_input = if (self.metask.catalog) |*catalog| catalog.imageInput(target.model_id) else null,
            .source_generation = expected_source_generation,
        };
        const provider = findProviderView(self.registry.views(), target.source_id) orelse return null;
        const image_input = for (provider.models) |model| {
            if (std.mem.eql(u8, model.id, target.model_id)) break model.metadata.capabilities.image_input;
        } else null;
        return .{
            .source_id = provider.id,
            .model_id = target.model_id,
            .protocol = protocol,
            .base_url = provider.normalized_base_url,
            .image_input = image_input,
            .source_generation = provider.source_generation,
        };
    }

    /// Produces a complete owned execution candidate for an explicit model.
    /// A stale/unavailable target never falls back to the global selection.
    pub fn resolveModel(
        self: *Runtime,
        target: contract.ModelRef,
        expected_source_generation: u64,
        expected_catalog_generation: u64,
    ) !?contract.OwnedSourceCandidate {
        const facts = self.targetFacts(target, expected_source_generation, expected_catalog_generation) orelse return null;
        if (std.mem.eql(u8, target.source_id, contract.metask_source_id)) {
            var storage: MetaskCredentialStorage = .{};
            defer storage.zero();
            const credential = (try self.readMetaskCredential(&storage)) orelse return null;
            const catalog = if (self.metask.catalog) |*value| value else return null;
            var candidate = catalog.prepareSourceCandidate(target.model_id, expected_source_generation, credential.token) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidProvider,
            };
            // The token and its Account generation were taken together.
            candidate.credential_generation = credential.generation;
            return candidate;
        }
        const provider = findProviderView(self.registry.views(), target.source_id) orelse return null;
        const binding: ModelBinding = .{
            .provider_id = provider.id,
            .model_id = target.model_id,
            .protocol = facts.protocol,
            .normalized_base_url = provider.normalized_base_url,
            .provider_revision = provider.provider_revision,
            .source_generation = provider.source_generation,
        };
        return self.resolveBindingCandidate(binding) catch |err| {
            if (err == error.CredentialNotFound) {
                self.markCredentialMissing(binding);
                return null;
            }
            return err;
        };
    }

    fn resolveBindingCandidate(
        self: *Runtime,
        binding: registry_impl.Registry.ModelBinding,
    ) !contract.OwnedSourceCandidate {
        const vault = self.credential_vault orelse return error.CredentialStoreUnavailable;
        var secret_storage: [contract.Limits.credential_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret_storage);
        const secret = (try vault.get(binding.provider_id, &secret_storage)) orelse
            return error.CredentialNotFound;
        var declarations: [contract.max_model_image_capabilities]contract.ModelImageCapability = undefined;
        var owned_capabilities = try contract.OwnedImageCapabilities.copy(self.allocator, self.registry.imageCapabilities(binding.provider_id, &declarations));
        errdefer owned_capabilities.deinit();
        var model_id: ?[]u8 = try self.allocator.dupe(u8, binding.model_id);
        errdefer if (model_id) |bytes| self.allocator.free(bytes);
        var normalized_base_url: ?[]u8 = try self.allocator.dupe(u8, binding.normalized_base_url);
        errdefer if (normalized_base_url) |bytes| self.allocator.free(bytes);
        const credential = try self.allocator.dupe(u8, secret);
        const transferred_model = model_id.?;
        const transferred_url = normalized_base_url.?;
        model_id = null;
        normalized_base_url = null;
        var result = try contract.OwnedSourceCandidate.initOwned(
            self.allocator,
            .custom_provider,
            binding.protocol,
            transferred_model,
            transferred_url,
            binding.source_generation,
            credential,
            binding.provider_id,
        );
        result.image_capabilities = owned_capabilities.take();
        return result;
    }

    fn commitCandidate(
        self: *Runtime,
        candidate: *registry_impl.Registry,
        drain_cleanup: bool,
    ) contract.CommandResult {
        const encoded = registry_impl.encodeAlloc(self.allocator, candidate) catch |err|
            return .rejected(mapRegistryError(err));
        defer self.allocator.free(encoded);
        const store = if (self.store) |*value| value else return .rejected(.persistence_unavailable);
        switch (commitCanonical(self.allocator, store, encoded)) {
            .committed => {},
            .not_committed => return .rejected(.persistence_unavailable),
            .unresolved => {
                self.store_healthy = false;
                return .rejected(.persistence_unavailable);
            },
        }
        self.registry.replace(candidate);
        if (drain_cleanup) self.drainCredentialCleanup();
        return .acceptedResult();
    }

    fn restore(self: *Runtime, absolute_directory: []const u8) void {
        self.store = registry_impl.FileStore.init(self.io, absolute_directory) catch return;
        self.store_healthy = true;
        const bytes_optional = self.store.?.loadAlloc(self.allocator) catch {
            self.store_healthy = false;
            return;
        };
        const bytes = bytes_optional orelse {
            self.initializeEmptyStore();
            return;
        };
        defer self.allocator.free(bytes);
        var restored = registry_impl.decode(self.allocator, bytes) catch {
            if (registry_impl.isRetiredCanonical(self.allocator, bytes)) {
                if (!self.installEmptyRecovery(&self.store.?, bytes).accepted)
                    self.store_healthy = false;
                return;
            }
            self.store_healthy = false;
            return;
        };
        self.installRestored(&restored);
    }

    fn installRestored(self: *Runtime, restored: *registry_impl.Registry) void {
        if (restored.reconcileInterruptedTests()) {
            const reconciled = registry_impl.encodeAlloc(self.allocator, restored) catch {
                self.store_healthy = false;
                self.registry.replace(restored);
                restored.deinit();
                return;
            };
            defer self.allocator.free(reconciled);
            if (commitCanonical(self.allocator, &self.store.?, reconciled) != .committed) {
                self.store_healthy = false;
            }
        }
        self.registry.replace(restored);
        restored.deinit();
        self.drainCredentialCleanup();
    }

    fn initializeEmptyStore(self: *Runtime) void {
        var empty = registry_impl.Registry.init(self.allocator);
        defer empty.deinit();
        const encoded = registry_impl.encodeAlloc(self.allocator, &empty) catch {
            self.store_healthy = false;
            return;
        };
        defer self.allocator.free(encoded);
        if (commitCanonical(self.allocator, &self.store.?, encoded) != .committed) {
            self.store_healthy = false;
            return;
        }
        self.registry.replace(&empty);
    }

    fn markCredentialMissing(self: *Runtime, binding: registry_impl.Registry.ModelBinding) void {
        var candidate = self.registry.clone() catch {
            self.store_healthy = false;
            return;
        };
        defer candidate.deinit();
        candidate.markCredentialMissing(.{
            .source_id = binding.provider_id,
            .expected_provider_revision = binding.provider_revision,
        }) catch {
            self.store_healthy = false;
            return;
        };
        if (!self.commitCandidate(&candidate, false).accepted) {
            self.store_healthy = false;
        }
    }

    fn drainCredentialCleanup(self: *Runtime) void {
        if (!self.store_healthy) return;
        const vault = self.credential_vault orelse return;
        var snapshot: std.ArrayList([]u8) = .empty;
        defer {
            for (snapshot.items) |provider_id| self.allocator.free(provider_id);
            snapshot.deinit(self.allocator);
        }
        snapshot.ensureTotalCapacity(
            self.allocator,
            self.registry.credentialDeletions().len,
        ) catch return;
        for (self.registry.credentialDeletions()) |provider_id| {
            const owned = self.allocator.dupe(u8, provider_id) catch return;
            snapshot.appendAssumeCapacity(owned);
        }
        for (snapshot.items) |provider_id| {
            vault.delete(provider_id) catch continue;
            var candidate = self.registry.clone() catch continue;
            defer candidate.deinit();
            candidate.completeCredentialDeletion(provider_id) catch continue;
            const result = self.commitCandidate(&candidate, false);
            if (!result.accepted and !self.store_healthy) return;
        }
    }

    /// The Metask credential of this moment, for the account whose catalog
    /// Models holds. Null when none may be used now or it is another account's.
    fn readMetaskCredential(self: *const Runtime, storage: *MetaskCredentialStorage) std.mem.Allocator.Error!?ports.MetaskCredential {
        const source = self.metask_credentials orelse return null;
        const credential = (try source.read(&storage.account, &storage.token)) orelse return null;
        if (credential.generation == 0 or credential.token.len == 0 or
            !std.mem.eql(u8, credential.account, self.metask.principal.view())) return null;
        return credential;
    }

    fn assertMainThread(self: *const Runtime) void {
        std.debug.assert(std.Thread.getCurrentId() == self.main_thread_id);
    }
};

test "Task model menu availability agrees with the Renderer fixture" {
    const Case = struct {
        intentSource: ?[]const u8,
        persistenceHealth: contract.PersistenceHealth,
        customState: contract.CustomProviderState,
        customEnabled: bool,
        metaskCatalog: contract.CatalogState,
        menuSources: []const []const u8,
        availability: []const u8,
    };
    const fixture = @import("product_models_contract_fixture").task_model_menu;
    const cases = try std.json.parseFromSlice([]const Case, std.testing.allocator, fixture, .{});
    defer cases.deinit();
    for (cases.value) |entry| {
        const providers = [_]contract.ProviderView{.{
            .id = contract.metask_source_id,
            .display_name = "Metask",
            .recommended = true,
            .catalog_state = entry.metaskCatalog,
            .models = &.{.{ .id = "model", .display_name = "Model" }},
            .source_generation = 1,
            .catalog_generation = 1,
        }};
        const custom = [_]contract.CustomProviderView{.{
            .id = "other",
            .display_name = "Other",
            .protocol = .openai_responses,
            .normalized_base_url = "https://example.com/v1/responses",
            .state = entry.customState,
            .credential_status = .ready,
            .enabled = entry.customEnabled,
            .models = &.{.{
                .id = "model",
                .test_status = if (entry.customState == .ready) .connected else .untested,
                .ready = entry.customState == .ready,
            }},
            .provider_revision = 1,
            .source_generation = 1,
            .catalog_generation = 1,
        }};
        const models: contract.ModelsView = .{
            .availability = .ready,
            .persistence_health = entry.persistenceHealth,
            .providers = &providers,
            .custom_providers = &custom,
        };
        try std.testing.expectEqualStrings(entry.availability, @tagName(Runtime.selectionCatalogAvailability(models, entry.intentSource)));
    }
}

fn mapRegistryError(err: anyerror) contract.ManagementError {
    return switch (err) {
        error.ProviderNotFound => .provider_not_found,
        error.GenerationMismatch => .generation_mismatch,
        error.ModelNotFound => .model_not_found,
        error.Capacity => .capacity,
        error.OutOfMemory => .local_resource_exhausted,
        else => .invalid_provider,
    };
}

fn mapModelsError(error_code: contract.ModelsError) contract.ManagementError {
    return switch (error_code) {
        .none => unreachable,
        .authorization_unavailable => .authorization_unavailable,
        .persistence_unavailable, .preference_not_saved => .persistence_unavailable,
        .operation_in_progress => .operation_in_progress,
        .local_resource_exhausted => .local_resource_exhausted,
        .catalog_unavailable,
        .catalog_invalid,
        .catalog_too_large,
        .no_models,
        => .catalog_unavailable,
    };
}

fn findProviderView(
    views: []const contract.CustomProviderView,
    provider_id: []const u8,
) ?contract.CustomProviderView {
    for (views) |view|
        if (std.mem.eql(u8, view.id, provider_id)) return view;
    return null;
}

const CanonicalCommitTestStore = struct {
    const Mode = enum {
        committed,
        write_failed,
        unknown_match,
        unknown_different,
        unknown_missing,
        unknown_read_failed,
    };

    mode: Mode,
    target: []const u8 = &.{},
    read_count: usize = 0,

    fn commit(self: *@This(), bytes: []const u8) registry_impl.FileStoreError!void {
        self.target = bytes;
        return switch (self.mode) {
            .committed => {},
            .write_failed => error.WriteFailed,
            .unknown_match,
            .unknown_different,
            .unknown_missing,
            .unknown_read_failed,
            => error.PersistenceOutcomeUnknown,
        };
    }

    fn loadAlloc(
        self: *@This(),
        allocator: std.mem.Allocator,
    ) (registry_impl.FileStoreError || std.mem.Allocator.Error)!?[]u8 {
        self.read_count += 1;
        return switch (self.mode) {
            .unknown_match => try allocator.dupe(u8, self.target),
            .unknown_different => try allocator.dupe(u8, "different-canonical"),
            .unknown_missing => null,
            .unknown_read_failed => error.ReadFailed,
            .committed, .write_failed => unreachable,
        };
    }
};

test "canonical commit resolves only an exact outcome-unknown readback" {
    const cases = [_]struct {
        mode: CanonicalCommitTestStore.Mode,
        expected: CanonicalCommitOutcome,
        expected_reads: usize,
    }{
        .{ .mode = .committed, .expected = .committed, .expected_reads = 0 },
        .{ .mode = .write_failed, .expected = .not_committed, .expected_reads = 0 },
        .{ .mode = .unknown_match, .expected = .committed, .expected_reads = 1 },
        .{ .mode = .unknown_different, .expected = .unresolved, .expected_reads = 1 },
        .{ .mode = .unknown_missing, .expected = .unresolved, .expected_reads = 1 },
        .{ .mode = .unknown_read_failed, .expected = .unresolved, .expected_reads = 1 },
    };
    for (cases) |case| {
        var store: CanonicalCommitTestStore = .{ .mode = case.mode };
        try std.testing.expectEqual(
            case.expected,
            commitCanonical(std.testing.allocator, &store, "candidate-canonical"),
        );
        try std.testing.expectEqual(case.expected_reads, store.read_count);
    }
}

test "unconfirmed preference commits reject memory without revoking unchanged source authority" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    defer runtime.deinit();
    try TestSupport.installMetaskDefault(&runtime, "principal", "synthetic-key", &.{.{ .id = "model-1", .display_name = "One" }}, "model-1", 1, 2, 3, 4);
    for ([_]CanonicalCommitOutcome{ .not_committed, .unresolved }) |outcome| {
        var candidate = try runtime.registry.clone();
        defer candidate.deinit();
        try candidate.rememberPreference(.{ .source_id = "metask", .model_id = "model-2" }, "Two", 5);
        try std.testing.expect(!runtime.finishPreferenceCommit(&candidate, outcome).accepted);
        try std.testing.expectEqualStrings("model-1", runtime.view().default_selection.?.model_id);
        try std.testing.expectEqual(@as(u64, 3), runtime.view().selection_revision);
        try std.testing.expectEqual(contract.PersistenceHealth.ready, runtime.view().persistence_health);
        try std.testing.expect(runtime.sourceModelProtocol(.{ .source_id = "metask", .model_id = "model-1" }, 1, 4) != null);
    }
}

test "choosing the retained preference after an unknown commit confirms the canonical value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    defer runtime.deinit();
    runtime.store = try registry_impl.FileStore.init(std.testing.io, root);
    try TestSupport.installMetaskDefault(&runtime, "principal", "synthetic-key", &.{
        .{ .id = "model-1", .display_name = "One" },
        .{ .id = "model-2", .display_name = "Two" },
    }, "model-1", 1, 2, 3, 4);

    var candidate = try runtime.registry.clone();
    defer candidate.deinit();
    try candidate.rememberPreference(.{ .source_id = "metask", .model_id = "model-2" }, "Two", 5);
    const encoded = try registry_impl.encodeAlloc(std.testing.allocator, &candidate);
    defer std.testing.allocator.free(encoded);
    try runtime.store.?.commit(encoded);
    // Model an installed candidate whose durability/readback could not be
    // confirmed. Apply the same failure diagnostic as rememberPreference.
    const unknown = runtime.finishPreferenceCommit(&candidate, .unresolved);
    runtime.preference_error = if (unknown.accepted) .none else .preference_not_saved;
    try std.testing.expectEqualStrings("model-1", runtime.view().default_selection.?.model_id);

    try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "model-1" }).accepted);
    const saved = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(saved);
    var restored = try registry_impl.decode(std.testing.allocator, saved);
    defer restored.deinit();
    try std.testing.expectEqualStrings("model-1", restored.defaultSelection().?.model_id);
    try std.testing.expectEqualStrings("One", restored.default_display_name);
    try std.testing.expectEqualStrings("One", runtime.view().default_selection_display_name.?);
    try std.testing.expectEqual(contract.ModelsError.none, runtime.view().error_code);
    try std.testing.expect(runtime.sourceModelProtocol(.{ .source_id = "metask", .model_id = "model-1" }, 1, 4) != null);
}

const TestVault = struct {
    const slot = "custom-provider-00000000000000000000000000000001";

    secret: [contract.Limits.credential_bytes]u8 = undefined,
    secret_len: usize = 0,
    present: bool = false,
    fail_store: bool = false,
    expected_secret_ptr: ?[*]const u8 = null,
    observed_direct_borrow: bool = false,

    fn port(self: *TestVault) ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generate,
            .store_fn = store,
            .get_fn = get,
            .delete_fn = delete,
        };
    }

    fn generate(_: *anyopaque, output: *[ports.credential_slot_bytes]u8) anyerror!void {
        @memcpy(output, slot);
    }

    fn store(context: *anyopaque, _: []const u8, secret: []const u8) anyerror!void {
        const self: *TestVault = @ptrCast(@alignCast(context));
        self.observed_direct_borrow = if (self.expected_secret_ptr) |expected|
            secret.ptr == expected
        else
            false;
        if (self.fail_store) return error.WriteFailed;
        if (secret.len > self.secret.len) return error.WriteFailed;
        @memcpy(self.secret[0..secret.len], secret);
        self.secret_len = secret.len;
        self.present = true;
    }

    fn get(context: *anyopaque, _: []const u8, output: []u8) anyerror!?[]const u8 {
        const self: *TestVault = @ptrCast(@alignCast(context));
        if (!self.present) return null;
        if (self.secret_len > output.len) return error.ReadFailed;
        @memcpy(output[0..self.secret_len], self.secret[0..self.secret_len]);
        return output[0..self.secret_len];
    }

    fn delete(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *TestVault = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, self.secret[0..self.secret_len]);
        self.secret_len = 0;
        self.present = false;
    }
};

const CleanupTestVault = struct {
    fail_id: []const u8 = &.{},
    calls: [8][contract.Limits.instance_id_bytes]u8 = undefined,
    call_lengths: [8]usize = @splat(0),
    call_count: usize = 0,

    fn port(self: *@This()) ports.CredentialVault {
        return .{
            .context = self,
            .generate_slot_fn = generate,
            .store_fn = store,
            .get_fn = get,
            .delete_fn = delete,
        };
    }

    fn generate(_: *anyopaque, _: *[ports.credential_slot_bytes]u8) anyerror!void {
        return error.Unavailable;
    }

    fn store(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.Unavailable;
    }

    fn get(_: *anyopaque, _: []const u8, _: []u8) anyerror!?[]const u8 {
        return null;
    }

    fn delete(context: *anyopaque, provider_id: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const index = self.call_count;
        if (index >= self.calls.len or provider_id.len > self.calls[index].len)
            return error.Unavailable;
        @memcpy(self.calls[index][0..provider_id.len], provider_id);
        self.call_lengths[index] = provider_id.len;
        self.call_count += 1;
        if (std.mem.eql(u8, provider_id, self.fail_id)) return error.DeleteFailed;
    }

    fn call(self: *const @This(), index: usize) []const u8 {
        return self.calls[index][0..self.call_lengths[index]];
    }
};

test "credential cleanup skips failed tombstones and completes later IDs" {
    const cleanup_a = "custom-provider-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const cleanup_b = "custom-provider-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const cleanup_c = "custom-provider-cccccccccccccccccccccccccccccccc";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: CleanupTestVault = .{ .fail_id = cleanup_a };
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    var candidate = try runtime.registry.clone();
    defer candidate.deinit();
    try candidate.reserveCredentialDeletion(cleanup_a);
    try candidate.reserveCredentialDeletion(cleanup_b);
    try candidate.reserveCredentialDeletion(cleanup_c);
    try std.testing.expect(runtime.commitCandidate(&candidate, false).accepted);

    runtime.drainCredentialCleanup();
    try std.testing.expectEqual(@as(usize, 3), vault.call_count);
    try std.testing.expectEqualStrings(cleanup_a, vault.call(0));
    try std.testing.expectEqualStrings(cleanup_b, vault.call(1));
    try std.testing.expectEqualStrings(cleanup_c, vault.call(2));
    try std.testing.expectEqual(@as(usize, 1), runtime.registry.credentialDeletions().len);
    try std.testing.expectEqualStrings(cleanup_a, runtime.registry.credentialDeletions()[0]);

    vault.fail_id = &.{};
    runtime.drainCredentialCleanup();
    try std.testing.expectEqual(@as(usize, 4), vault.call_count);
    try std.testing.expectEqualStrings(cleanup_a, vault.call(3));
    try std.testing.expectEqual(@as(usize, 0), runtime.registry.credentialDeletions().len);
}

fn createTestProviderWithModel(
    runtime: *Runtime,
    secret: []const u8,
    spec: contract.CustomProviderSpec,
    model: contract.CustomModelInput,
) !void {
    try std.testing.expect(runtime.createWithCredential(secret, spec).accepted);
    const providers = runtime.views();
    const provider = providers[providers.len - 1];
    try std.testing.expect(runtime.submitCommand(.{ .add_custom_model = .{
        .source_id = provider.id,
        .expected_provider_revision = provider.provider_revision,
        .expected_catalog_generation = provider.catalog_generation,
        .model = model,
    } }).accepted);
}

test "Models Runtime creates a connection and its first model in the same durable candidate" {
    for ([_]bool{ false, true }) |builtin_recipe| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
        const directory = directory_storage[0..directory_len];
        var vault: TestVault = .{};
        {
            var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
            try runtime.start(directory, vault.port());
            defer {
                runtime.stop();
                runtime.deinit();
            }
            const invalid = runtime.createWithCredential("secret", .{
                .display_name = "Custom",
                .protocol = .openai_responses,
                .normalized_base_url = "https://example.com/responses",
                .initial_model = .{ .id = "" },
            });
            try std.testing.expect(!invalid.accepted);
            try std.testing.expect(!vault.present);
            try std.testing.expectEqual(@as(usize, 0), runtime.views().len);
            const result = if (builtin_recipe)
                runtime.createBuiltinWithCredential("secret", .deepseek, "https://api.deepseek.com", .{ .id = "deepseek-flash" })
            else
                runtime.createWithCredential("secret", .{
                    .display_name = "Custom",
                    .protocol = .openai_responses,
                    .normalized_base_url = "https://example.com/responses",
                    .initial_model = .{ .id = "deepseek-flash" },
                });
            try std.testing.expect(result.accepted);
            const source = runtime.views()[0];
            try std.testing.expectEqual(@as(usize, 1), source.models.len);
            try std.testing.expectEqualStrings("deepseek-flash", source.models[0].id);
            try std.testing.expect(!source.models[0].ready);
            try std.testing.expectEqual(contract.CustomModelTestStatus.untested, source.models[0].test_status);
            try std.testing.expect(runtime.view().default_selection == null);
            const persisted = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(persisted);
            try std.testing.expect(std.mem.indexOf(u8, persisted, "secret") == null);
        }
        var restored = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restored.start(directory, vault.port());
        defer {
            restored.stop();
            restored.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), restored.views()[0].models.len);
        try std.testing.expectEqualStrings("deepseek-flash", restored.views()[0].models[0].id);
        try std.testing.expect(!restored.views()[0].models[0].ready);
        const saved = restored.views()[0];
        try std.testing.expect(restored.submitCommand(.{ .remove_custom_model = .{
            .selection = .{ .source_id = saved.id, .model_id = "deepseek-flash" },
            .expected_provider_revision = saved.provider_revision,
            .expected_catalog_generation = saved.catalog_generation,
        } }).accepted);
        try std.testing.expectEqual(@as(usize, 0), restored.views().len);
        try std.testing.expectEqual(@as(usize, 0), restored.registry.credentialDeletions().len);
        try std.testing.expect(!vault.present);
    }
}

test "Models Runtime durably creates a Provider before its first model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};

    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }
        try std.testing.expect(runtime.createWithCredential("provider-secret", .{
            .display_name = "Provider without models",
            .protocol = .anthropic_messages,
            .normalized_base_url = "https://api.anthropic.com/v1/messages",
        }).accepted);
        const provider = runtime.views()[0];
        try std.testing.expectEqual(contract.CustomProviderState.configuring, provider.state);
        try std.testing.expectEqual(@as(usize, 0), provider.models.len);
        try std.testing.expect(vault.present);
        try std.testing.expect(runtime.view().default_selection == null);
        try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
    }

    {
        var restored = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restored.start(directory, vault.port());
        defer {
            restored.stop();
            restored.deinit();
        }
        const providers = restored.views();
        try std.testing.expectEqual(@as(usize, 1), providers.len);
        try std.testing.expectEqual(@as(usize, 0), providers[0].models.len);
        try std.testing.expect(restored.sourceModelProtocol(.{ .source_id = TestVault.slot, .model_id = "gpt-5" }, restored.views()[0].source_generation, restored.views()[0].catalog_generation) == null);
    }
}

test "built-in recipe fixes protocol and endpoint while rejecting credential slot collisions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    try std.testing.expect(runtime.createBuiltinWithCredential(
        "official-secret",
        .deepseek,
        builtin_providers.find(.deepseek).default_base_url,
        null,
    ).accepted);
    try std.testing.expectEqual(
        contract.BuiltinProviderId.deepseek,
        runtime.views()[0].builtin_provider_id.?,
    );
    // The fixture deliberately generates the same credential slot again.
    try std.testing.expect(!runtime.createBuiltinWithCredential(
        "second-secret",
        .deepseek,
        builtin_providers.find(.deepseek).default_base_url,
        null,
    ).accepted);

    const provider = runtime.views()[0];
    try std.testing.expectEqualStrings(
        "https://api.deepseek.com/chat/completions",
        provider.normalized_base_url,
    );
    try std.testing.expect(runtime.submitCommand(.{ .add_custom_model = .{
        .source_id = provider.id,
        .expected_provider_revision = provider.provider_revision,
        .expected_catalog_generation = provider.catalog_generation,
        .model = .{ .id = "deepseek-chat", .display_name = "DeepSeek Chat" },
    } }).accepted);
    const before_update = runtime.views()[0];
    const before_source_generation = before_update.source_generation;
    try std.testing.expect(runtime.updateBuiltinBaseUrl(.{
        .source_id = TestVault.slot,
        .expected_provider_revision = before_update.provider_revision,
    }, "https://gateway.example.com/deepseek/v1/").accepted);
    const updated = runtime.views()[0];
    try std.testing.expectEqualStrings(
        "https://gateway.example.com/deepseek/v1/chat/completions",
        updated.normalized_base_url,
    );
    try std.testing.expectEqualStrings("DeepSeek", updated.display_name);
    try std.testing.expectEqual(contract.Protocol.openai_chat_completions, updated.protocol);
    try std.testing.expect(updated.source_generation != before_source_generation);
    try std.testing.expectEqual(@as(usize, 1), updated.models.len);
    try std.testing.expectEqual(contract.CustomModelTestStatus.untested, updated.models[0].test_status);
}

test "Models Runtime owns durable custom providers and source resolution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};

    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }
        try createTestProviderWithModel(
            &runtime,
            "provider-secret",
            .{
                .display_name = "OpenAI",
                .protocol = .openai_responses,
                .normalized_base_url = "https://api.openai.com/v1/responses",
            },
            .{ .id = "gpt-5", .display_name = "GPT-5" },
        );
        const view = runtime.views()[0];
        try std.testing.expectEqualStrings(TestVault.slot, view.id);
        const selection: contract.CustomProviderSelectionCommand = .{
            // Registry views are borrowed until the next committed mutation.
            // Commands arrive with independently owned request bytes in
            // production, so keep this test selection independently stable.
            .source_id = TestVault.slot,
            .expected_provider_revision = view.provider_revision,
        };
        try std.testing.expect(runtime.submitCommand(.{ .test_model = .{
            .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_provider_revision = selection.expected_provider_revision,
            .expected_source_generation = view.source_generation,
            .expected_catalog_generation = view.catalog_generation,
        } }).accepted);
        try std.testing.expect(runtime.completeTest(.{
            .model = .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            .expected_provider_revision = selection.expected_provider_revision,
            .expected_source_generation = view.source_generation,
            .expected_catalog_generation = view.catalog_generation,
        }, true).accepted);
        const provider = runtime.views()[0];
        try std.testing.expect(runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            provider.source_generation,
            provider.catalog_generation,
            .openai_responses,
        ));
        try std.testing.expect(!runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "missing-model" },
            provider.source_generation,
            provider.catalog_generation,
            .openai_responses,
        ));
        try std.testing.expect(!runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            provider.source_generation + 1,
            provider.catalog_generation,
            .openai_responses,
        ));
        try std.testing.expect(!runtime.sourceModelAvailable(
            .{ .source_id = selection.source_id, .model_id = "gpt-5" },
            provider.source_generation,
            provider.catalog_generation,
            .anthropic_messages,
        ));
        try std.testing.expect(runtime.rememberPreference(.{ .source_id = selection.source_id, .model_id = "gpt-5" }).accepted);
        try std.testing.expectEqualStrings(TestVault.slot, runtime.view().default_selection.?.source_id);
        try std.testing.expect(runtime.view().selection_revision != 0);
        var candidate = (try TestSupport.resolveFixtureSelection(&runtime)) orelse
            return error.TestUnexpectedResult;
        defer candidate.deinit();
        try std.testing.expectEqualStrings("provider-secret", candidate.input().api_key);
        try std.testing.expectEqual(contract.Protocol.openai_responses, candidate.input().target.protocol);
        try std.testing.expectEqual(provider.source_generation, candidate.input().source_generation);
    }

    {
        var restored = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restored.start(directory, vault.port());
        defer {
            restored.stop();
            restored.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), restored.views().len);
        {
            var candidate = (try TestSupport.resolveFixtureSelection(&restored)) orelse
                return error.TestUnexpectedResult;
            defer candidate.deinit();
            try std.testing.expectEqualStrings("provider-secret", candidate.input().api_key);
            try std.testing.expectEqualStrings("custom_provider:" ++ TestVault.slot, candidate.input().target.provider_id);
        }

        const previous_selection_revision = restored.view().selection_revision;
        try TestVault.delete(&vault, TestVault.slot);
        try std.testing.expect((try TestSupport.resolveFixtureSelection(&restored)) == null);
        try std.testing.expect(restored.store_healthy);
        try std.testing.expect(restored.sourceModelProtocol(.{ .source_id = TestVault.slot, .model_id = "gpt-5" }, restored.views()[0].source_generation, restored.views()[0].catalog_generation) == null);
        try std.testing.expect(restored.view().default_selection != null);
        try std.testing.expect(restored.view().selection_revision == previous_selection_revision);
        const missing = restored.views()[0];
        try std.testing.expectEqual(
            contract.CustomProviderCredentialStatus.missing,
            missing.credential_status,
        );
        try std.testing.expectEqual(contract.CustomProviderState.configuring, missing.state);
    }

    {
        var restarted = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restarted.start(directory, vault.port());
        defer {
            restarted.stop();
            restarted.deinit();
        }
        try std.testing.expect(restarted.store_healthy);
        try std.testing.expectEqual(@as(usize, 1), restarted.views().len);
        try std.testing.expect(restarted.sourceModelProtocol(.{ .source_id = TestVault.slot, .model_id = "gpt-5" }, restarted.views()[0].source_generation, restarted.views()[0].catalog_generation) == null);
        try std.testing.expect(restarted.view().default_selection != null);
        const missing = restarted.views()[0];
        try std.testing.expectEqual(
            contract.CustomProviderCredentialStatus.missing,
            missing.credential_status,
        );
        try std.testing.expectEqual(contract.CustomProviderState.configuring, missing.state);
    }
}

test "Models explicit resolution preserves the global default across sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal", &.{.{ .id = "default-model", .display_name = "Default" }}));
    try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "default-model" }).accepted);
    const default_revision = runtime.view().selection_revision;
    try createTestProviderWithModel(&runtime, "custom-secret", .{
        .display_name = "Other connection",
        .protocol = .openai_responses,
        .normalized_base_url = "https://other.example.com/v1/responses",
    }, .{ .id = "other-model" });
    const target: contract.ModelRef = .{ .source_id = TestVault.slot, .model_id = "other-model" };
    const configuring = runtime.views()[0];
    try std.testing.expect((try runtime.resolveModel(target, configuring.source_generation, configuring.catalog_generation)) == null);
    const probe: contract.CustomModelTestCommand = .{
        .model = target,
        .expected_provider_revision = configuring.provider_revision,
        .expected_source_generation = configuring.source_generation,
        .expected_catalog_generation = configuring.catalog_generation,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_model = probe }).accepted);
    try std.testing.expect(runtime.completeTest(probe, true).accepted);
    const ready = runtime.views()[0];
    try std.testing.expect((try runtime.resolveModel(target, ready.source_generation +% 1, ready.catalog_generation)) == null);
    try std.testing.expect((try runtime.resolveModel(target, ready.source_generation, ready.catalog_generation +% 1)) == null);
    try std.testing.expect((try runtime.resolveModel(.{ .source_id = TestVault.slot, .model_id = "missing" }, ready.source_generation, ready.catalog_generation)) == null);
    var candidate = (try runtime.resolveModel(target, ready.source_generation, ready.catalog_generation)).?;
    defer candidate.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_responses, candidate.input().target.protocol);
    try std.testing.expectEqualStrings("https://other.example.com/v1/responses", candidate.input().target.base_url);
    try std.testing.expectEqualStrings("custom_provider:" ++ TestVault.slot, candidate.input().target.provider_id);
    try std.testing.expectEqualStrings("custom-secret", candidate.input().api_key);
    try std.testing.expectEqual(default_revision, runtime.view().selection_revision);
    try std.testing.expectEqualStrings("metask", runtime.view().default_selection.?.source_id);
    try std.testing.expectEqualStrings("default-model", runtime.view().default_selection.?.model_id);

    // Losing this connection's credential revokes only its new resolutions.
    // An unrelated default and an already owned execution remain intact.
    try TestVault.delete(&vault, TestVault.slot);
    try std.testing.expect((try runtime.resolveModel(target, ready.source_generation, ready.catalog_generation)) == null);
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.missing, runtime.views()[0].credential_status);
    try std.testing.expectEqual(default_revision, runtime.view().selection_revision);
    try std.testing.expectEqualStrings("metask", runtime.view().default_selection.?.source_id);
    try std.testing.expectEqualStrings("custom-secret", candidate.input().api_key);
}

test "Models explicit resolution uses the target Metask protocol and rejects stale catalogs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const response =
        \\{"object":"list","has_more":false,"data":[{"id":"default-model","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}},{"id":"other-model","object":"model","type":"model","capabilities":{"endpoints":{"responses":{"supported":true}}}}]}
    ;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", response));
    try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "default-model" }).accepted);
    const view = runtime.view();
    const source_generation = view.providers[0].source_generation;
    const catalog_generation = view.providers[0].catalog_generation;
    const selection_revision = view.selection_revision;
    const target: contract.ModelRef = .{ .source_id = "metask", .model_id = "other-model" };
    var candidate = (try runtime.resolveModel(target, source_generation, catalog_generation)).?;
    defer candidate.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_responses, candidate.input().target.protocol);
    try std.testing.expectEqualStrings(contract.metaskEndpoint(.openai_responses).?, candidate.input().target.base_url);
    try std.testing.expectEqualStrings("refreshed-secret", candidate.input().api_key);
    try std.testing.expectEqual(source_generation, candidate.input().source_generation);
    try std.testing.expectEqual(selection_revision, runtime.view().selection_revision);
    try std.testing.expectEqualStrings("default-model", runtime.view().default_selection.?.model_id);
    try std.testing.expectEqual(contract.Protocol.anthropic_messages, runtime.sourceModelProtocol(.{ .source_id = "metask", .model_id = "default-model" }, source_generation, catalog_generation).?);
    try std.testing.expect((try runtime.resolveModel(target, source_generation +% 1, catalog_generation)) == null);
    try std.testing.expect((try runtime.resolveModel(target, source_generation, catalog_generation +% 1)) == null);
    try std.testing.expect((try runtime.resolveModel(target, 0, catalog_generation)) == null);

    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal", &.{}));
    try std.testing.expect((try runtime.resolveModel(target, source_generation, catalog_generation)) == null);
    try std.testing.expectEqualStrings("other-model", candidate.input().target.model);
    try std.testing.expectEqualStrings("refreshed-secret", candidate.input().api_key);
    runtime.store_healthy = false;
    try std.testing.expect((try runtime.resolveModel(target, source_generation, catalog_generation)) == null);
}

test "credential replacement revokes readiness before writing and restores fresh authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};

    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const old_secret = "old-secret";
    vault.expected_secret_ptr = old_secret.ptr;
    try createTestProviderWithModel(
        &runtime,
        old_secret,
        .{
            .display_name = "Provider",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.example.com/v1/responses",
        },
        .{ .id = "model-1", .display_name = "Model 1" },
    );
    try std.testing.expect(vault.observed_direct_borrow);
    try std.testing.expectEqualStrings(old_secret, vault.secret[0..vault.secret_len]);
    const created_canonical = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(created_canonical);
    try std.testing.expect(std.mem.indexOf(u8, created_canonical, old_secret) == null);
    const initial = runtime.views()[0];
    const selection: contract.CustomProviderSelectionCommand = .{
        .source_id = TestVault.slot,
        .expected_provider_revision = initial.provider_revision,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_model = .{
        .model = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_provider_revision = initial.provider_revision,
        .expected_source_generation = initial.source_generation,
        .expected_catalog_generation = initial.catalog_generation,
    } }).accepted);
    try std.testing.expect(runtime.completeTest(.{
        .model = .{ .source_id = TestVault.slot, .model_id = "model-1" },
        .expected_provider_revision = initial.provider_revision,
        .expected_source_generation = initial.source_generation,
        .expected_catalog_generation = initial.catalog_generation,
    }, true).accepted);
    try std.testing.expect(runtime.rememberPreference(.{ .source_id = TestVault.slot, .model_id = "model-1" }).accepted);

    vault.fail_store = true;
    const new_secret = "new-secret";
    vault.expected_secret_ptr = new_secret.ptr;
    vault.observed_direct_borrow = false;
    const failed = runtime.replaceCredential(new_secret, selection);
    try std.testing.expect(!failed.accepted);
    try std.testing.expect(vault.observed_direct_borrow);
    try std.testing.expectEqual(contract.ManagementError.credential_write_failed, failed.error_code.?);
    try std.testing.expectEqualStrings(old_secret, vault.secret[0..vault.secret_len]);
    const failed_canonical = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(failed_canonical);
    try std.testing.expect(std.mem.indexOf(u8, failed_canonical, new_secret) == null);
    try std.testing.expectEqualStrings("model-1", runtime.view().default_selection.?.model_id);
    const revoked = runtime.views()[0];
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.missing, revoked.credential_status);
    try std.testing.expectEqual(contract.CustomProviderState.configuring, revoked.state);
    try std.testing.expect(!revoked.models[0].ready);

    vault.fail_store = false;
    vault.observed_direct_borrow = false;
    try std.testing.expect(runtime.replaceCredential(new_secret, .{
        .source_id = TestVault.slot,
        .expected_provider_revision = revoked.provider_revision,
    }).accepted);
    try std.testing.expect(vault.observed_direct_borrow);
    const restored = runtime.views()[0];
    try std.testing.expectEqual(contract.CustomProviderCredentialStatus.ready, restored.credential_status);
    try std.testing.expectEqual(contract.CustomProviderState.configuring, restored.state);
    try std.testing.expect(restored.provider_revision != initial.provider_revision);
    try std.testing.expect(restored.source_generation != initial.source_generation);
    try std.testing.expectEqualStrings(new_secret, vault.secret[0..vault.secret_len]);
    const replaced_canonical = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(replaced_canonical);
    try std.testing.expect(std.mem.indexOf(u8, replaced_canonical, new_secret) == null);
}

test "Models owns Metask catalog authority without changing global default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    const models = [_]contract.ModelView{.{ .id = "model-1", .display_name = "Model One" }};
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogWithCredential(&runtime, "principal-1", "model-secret", &models));

    const first = runtime.view();
    try std.testing.expectEqual(contract.CatalogState.ready, first.providers[0].catalog_state);
    try std.testing.expectEqualStrings("principal-1", first.providers[0].principal_ref);
    try std.testing.expect(first.providers[0].source_generation != 0);
    try std.testing.expect(first.default_selection == null);
    const first_source_generation = first.providers[0].source_generation;
    const first_catalog_generation = first.providers[0].catalog_generation;

    // The same content again, asked with another token: nothing it stands
    // for changed, so neither does its generation.
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogWithCredential(&runtime, "principal-1", "rotated-model-secret", &models));
    const second = runtime.view();
    try std.testing.expectEqual(first_source_generation, second.providers[0].source_generation);
    try std.testing.expectEqual(first_catalog_generation, second.providers[0].catalog_generation);

    try std.testing.expect(runtime.rememberPreference(.{
        .source_id = "metask",
        .model_id = "model-1",
    }).accepted);
    runtime.metask_credentials = null;
    // The catalog holds no token: resolution reads the credential of the
    // moment, and only for the account whose catalog it is.
    try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
    var credentials = TestSupport.FakeMetaskCredentials.init("principal-2", "other-account-secret", 6);
    runtime.metask_credentials = credentials.port();
    try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
    credentials = TestSupport.FakeMetaskCredentials.init("principal-1", "rotated-model-secret", 6);
    var first_candidate = (try TestSupport.resolveFixtureSelection(&runtime)) orelse
        return error.TestUnexpectedResult;
    defer first_candidate.deinit();
    var second_candidate = (try TestSupport.resolveFixtureSelection(&runtime)) orelse
        return error.TestUnexpectedResult;
    defer second_candidate.deinit();
    try std.testing.expectEqualStrings(
        "rotated-model-secret",
        first_candidate.input().api_key,
    );
    try std.testing.expectEqualStrings(
        "rotated-model-secret",
        second_candidate.input().api_key,
    );
    try std.testing.expectEqual(
        second.providers[0].source_generation,
        second_candidate.input().source_generation,
    );
    // The token and its Account generation travel together.
    try std.testing.expectEqual(@as(u64, 6), second_candidate.input().credential_generation);
    try std.testing.expectEqual(
        contract.Protocol.anthropic_messages,
        second_candidate.input().target.protocol,
    );
    try std.testing.expectEqualStrings(
        contract.metask_anthropic_messages_url,
        second_candidate.input().target.base_url,
    );

    _ = runtime.followMetaskPrincipal(null, 0);
    const unavailable = runtime.view();
    try std.testing.expectEqual(
        contract.CatalogState.needs_authentication,
        unavailable.providers[0].catalog_state,
    );
    try std.testing.expectEqual(contract.ModelsError.authorization_unavailable, unavailable.providers[0].error_code);
    try std.testing.expectEqual(@as(usize, 0), unavailable.providers[0].models.len);
    try std.testing.expectEqualStrings("model-1", unavailable.default_selection.?.model_id);
    try std.testing.expect(!TestSupport.fixtureSelectionAvailable(&runtime));
    try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
}

test "Metask catalog drift keeps a tracked global default durable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};
    var committed_selection_revision: u64 = 0;

    {
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }

        try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogWithCredential(&runtime, "principal-1", "initial-secret", &.{.{ .id = "model-1", .display_name = "Model One" }}));
        try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "model-1" }).accepted);
        const previous_selection_revision = runtime.view().selection_revision;
        try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogWithCredential(&runtime, "principal-1", "replacement-secret", &.{.{ .id = "model-2", .display_name = "Model Two" }}));

        const drifted = runtime.view();
        try std.testing.expect(runtime.store_healthy);
        try std.testing.expectEqualStrings("metask", drifted.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", drifted.default_selection.?.model_id);
        try std.testing.expectEqualStrings("metask", drifted.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", drifted.default_selection.?.model_id);
        try std.testing.expectEqual(previous_selection_revision, drifted.selection_revision);
        try std.testing.expectEqual(contract.CatalogState.ready, drifted.providers[0].catalog_state);
        try std.testing.expectEqualStrings("model-2", drifted.providers[0].models[0].id);
        try std.testing.expect(!TestSupport.fixtureSelectionAvailable(&runtime));
        try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
        committed_selection_revision = drifted.selection_revision;
    }

    {
        var restarted = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restarted.start(directory, vault.port());
        defer {
            restarted.stop();
            restarted.deinit();
        }
        try std.testing.expect(restarted.store_healthy);
        const restored = restarted.view();
        try std.testing.expectEqual(
            contract.CatalogState.needs_authentication,
            restored.providers[0].catalog_state,
        );
        try std.testing.expectEqual(@as(usize, 0), restored.providers[0].models.len);
        try std.testing.expectEqualStrings("metask", restored.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", restored.default_selection.?.model_id);
        try std.testing.expectEqualStrings("metask", restored.default_selection.?.source_id);
        try std.testing.expectEqualStrings("model-1", restored.default_selection.?.model_id);
        try std.testing.expectEqual(committed_selection_revision, restored.selection_revision);
    }
}

test "Models bootstrap initializes canonical store and ignores retired files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    try writeTestFile(
        &tmp.dir,
        "preferences.json",
        "{\"selection_owner_account_id\":\"retired\"}",
    );
    try writeTestFile(&tmp.dir, "custom-providers.json", "not-json");

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }

    try std.testing.expect(runtime.store_healthy);
    const view = runtime.view();
    try std.testing.expect(view.default_selection == null);
    try std.testing.expectEqual(@as(usize, 0), view.custom_providers.len);
    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"schema\":3,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}",
        bytes,
    );
}

test "retired Models canonical is quarantined exactly before continuing with an empty store" {
    const retired = "{\"schema\":2,\"metask\":{\"principal_ref\":\"old\",\"model_id\":\"disabled\",\"protocol\":\"anthropic_messages\",\"source_generation\":1,\"selection_revision\":2},\"default_selection\":{\"source_id\":\"metask\",\"model_id\":\"disabled\"},\"selection_revision\":3,\"pending_credential_deletions\":[],\"custom_providers\":[]}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try writeTestFile(&tmp.dir, registry_impl.store_file_name, retired);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(root, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expectEqual(contract.PersistenceHealth.ready, runtime.view().persistence_health);
    try std.testing.expect(runtime.view().default_selection == null);
    try std.testing.expectEqual(@as(u64, 0), runtime.view().providers[0].source_generation);
    const current = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(current);
    var decoded = try registry_impl.decode(std.testing.allocator, current);
    defer decoded.deinit();
    try std.testing.expect(decoded.defaultSelection() == null);
    var dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".quarantine")) continue;
        var file = try dir.openFile(std.testing.io, entry.name, .{});
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        defer file.close(std.testing.io);
        var bytes: [retired.len]u8 = undefined;
        try std.testing.expectEqual(bytes.len, try file.readPositionalAll(std.testing.io, &bytes, 0));
        try std.testing.expectEqualStrings(retired, &bytes);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "retired Models credentials remain durably queued until deletion succeeds" {
    const retired = "{\"schema\":2,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[\"custom-provider-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"custom-provider-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"],\"custom_providers\":[{\"id\":\"custom-provider-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}]}";
    for ([_]bool{ false, true }) |explicit_reset| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        var vault: CleanupTestVault = .{ .fail_id = "custom-provider-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" };
        {
            if (!explicit_reset) try writeTestFile(&tmp.dir, registry_impl.store_file_name, retired);
            var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
            try runtime.start(root, vault.port());
            defer {
                runtime.stop();
                runtime.deinit();
            }
            if (explicit_reset) {
                try tmp.dir.deleteFile(std.testing.io, registry_impl.store_file_name);
                try writeTestFile(&tmp.dir, registry_impl.store_file_name, retired);
                runtime.store_healthy = false;
                try std.testing.expect(runtime.resetStore().accepted);
            }
            try std.testing.expect(runtime.store_healthy);
            try std.testing.expectEqual(@as(usize, 2), vault.call_count);
            try std.testing.expectEqual(@as(usize, 0), runtime.views().len);
            try std.testing.expect(runtime.view().default_selection == null);
            const saved = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
            defer std.testing.allocator.free(saved);
            var decoded = try registry_impl.decode(std.testing.allocator, saved);
            defer decoded.deinit();
            try std.testing.expectEqual(@as(usize, 1), decoded.credentialDeletions().len);
            try std.testing.expectEqualStrings("custom-provider-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", decoded.credentialDeletions()[0]);
        }
        vault.fail_id = "";
        var restarted = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try restarted.start(root, vault.port());
        defer {
            restarted.stop();
            restarted.deinit();
        }
        try std.testing.expectEqual(@as(usize, 3), vault.call_count);
        try std.testing.expectEqual(@as(usize, 0), restarted.registry.credentialDeletions().len);
        try std.testing.expectEqual(@as(usize, 0), restarted.views().len);
    }
}

test "retired Models with unverified cleanup identities preserves the original canonical" {
    for ([_][]const u8{
        "{\"schema\":2,\"pending_credential_deletions\":[],\"custom_providers\":[{\"id\":\"invalid-slot\"}]}",
        "{\"schema\":2,\"custom_providers\":[]}",
    }) |retired| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        try writeTestFile(&tmp.dir, registry_impl.store_file_name, retired);
        var vault: CleanupTestVault = .{ .fail_id = "" };
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(root, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }
        try std.testing.expect(!runtime.store_healthy);
        try std.testing.expect(!runtime.resetStore().accepted);
        try std.testing.expectEqual(@as(usize, 0), vault.call_count);
        const saved = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
        defer std.testing.allocator.free(saved);
        try std.testing.expectEqualStrings(retired, saved);
    }
}

test "Models bootstrap rejects damaged canonical shapes" {
    const inputs = [_][]const u8{
        "{\"schema\":3,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[]}",
        "{\"schema\":3,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[],\"unknown\":true}",
        "not-json",
    };
    for (inputs) |input| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
        try writeTestFile(&tmp.dir, registry_impl.store_file_name, input);

        var vault: TestVault = .{};
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory_storage[0..directory_len], vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }

        try std.testing.expect(!runtime.store_healthy);
        try std.testing.expectEqual(contract.CatalogState.unavailable, runtime.view().availability);
        try std.testing.expectEqual(
            contract.PersistenceHealth.recovery_required,
            runtime.view().persistence_health,
        );
        const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
            return error.TestExpectedEqual;
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(input, bytes);
    }
}

test "Models reset replaces damaged canonical bytes with current empty schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    try writeTestFile(
        &tmp.dir,
        registry_impl.store_file_name,
        "{\"schema\":3,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[]}",
    );

    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(!runtime.store_healthy);
    try std.testing.expectEqual(
        contract.PersistenceHealth.recovery_required,
        runtime.view().persistence_health,
    );
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expect(runtime.store_healthy);
    try std.testing.expectEqual(contract.PersistenceHealth.ready, runtime.view().persistence_health);
    try std.testing.expectEqual(@as(usize, 0), runtime.views().len);
    try std.testing.expect(runtime.view().default_selection == null);
    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"schema\":3,\"metask\":null,\"default_selection\":null,\"selection_revision\":0,\"pending_credential_deletions\":[],\"custom_providers\":[]}",
        bytes,
    );
}

test "Models reset rejects healthy store and non-destructively recovers a valid canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try createTestProviderWithModel(
        &runtime,
        "reset-secret",
        .{
            .display_name = "Reset me",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .{ .id = "gpt-5", .display_name = "GPT-5" },
    );
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(
        contract.ManagementError.persistence_unavailable,
        runtime.resetStore().error_code.?,
    );
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(@as(usize, 1), runtime.views().len);

    const canonical_before = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(canonical_before);

    // A prior uncertain result must not authorize destroying a canonical that
    // strict readback now proves valid.
    runtime.store_healthy = false;
    try std.testing.expectEqual(
        contract.PersistenceHealth.recovery_required,
        runtime.view().persistence_health,
    );
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expect(vault.present);
    try std.testing.expectEqual(@as(usize, 1), runtime.views().len);
    try std.testing.expect(runtime.view().default_selection == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.registry.credentialDeletions().len);
    const canonical_after = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(canonical_after);
    try std.testing.expectEqualStrings(canonical_before, canonical_after);
}

test "Models reset durably reconciles interrupted tests in a valid canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try createTestProviderWithModel(
        &runtime,
        "reset-secret",
        .{
            .display_name = "Interrupted",
            .protocol = .openai_responses,
            .normalized_base_url = "https://api.openai.com/v1/responses",
        },
        .{ .id = "gpt-5", .display_name = "GPT-5" },
    );
    const provider = runtime.views()[0];
    try std.testing.expect(runtime.submitCommand(.{ .test_model = .{
        .model = .{ .source_id = provider.id, .model_id = "gpt-5" },
        .expected_provider_revision = provider.provider_revision,
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    } }).accepted);
    try std.testing.expectEqual(
        contract.CustomModelTestStatus.testing,
        runtime.views()[0].models[0].test_status,
    );

    runtime.store_healthy = false;
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expect(runtime.store_healthy);
    try std.testing.expectEqual(
        contract.CustomModelTestStatus.failed,
        runtime.views()[0].models[0].test_status,
    );

    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)) orelse
        return error.TestExpectedEqual;
    defer std.testing.allocator.free(bytes);
    var restored = try registry_impl.decode(std.testing.allocator, bytes);
    defer restored.deinit();
    try std.testing.expect(!restored.reconcileInterruptedTests());
}

test "Models reset rejects unavailable persistence capability" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    runtime.startUnavailable();
    defer runtime.deinit();

    try std.testing.expectEqual(
        contract.PersistenceHealth.unavailable,
        runtime.view().persistence_health,
    );
    try std.testing.expectEqual(
        contract.ManagementError.persistence_unavailable,
        runtime.resetStore().error_code.?,
    );
}

fn writeTestFile(dir: *std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(std.testing.io, name, .{ .exclusive = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    try file.sync(std.testing.io);
}

test "successful empty Metask catalog preserves intent but removes all resolvable members" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var vault = TestVault{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(home, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try TestSupport.installMetaskDefault(
        &runtime,
        "principal-1",
        "old-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
        "model-1",
        1,
        2,
        3,
        4,
    );
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal-1", &.{}));
    const view = runtime.view();
    try std.testing.expectEqual(contract.CatalogState.ready, view.providers[0].catalog_state);
    try std.testing.expectEqual(contract.ModelsError.no_models, view.providers[0].error_code);
    try std.testing.expectEqual(@as(usize, 0), view.providers[0].models.len);
    try std.testing.expect(view.providers[0].catalog_generation != 4);
    try std.testing.expectEqual(@as(u64, 1), view.providers[0].source_generation);
    try std.testing.expectEqual(@as(u64, 3), view.selection_revision);
    try std.testing.expectEqualStrings("model-1", view.default_selection.?.model_id);
    try std.testing.expectEqualStrings("model-1", view.default_selection.?.model_id);
    try std.testing.expect(!TestSupport.fixtureSelectionAvailable(&runtime));
    try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
}

test "fixed image model resolves without user configuration alongside a Custom dialogue default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    const directory = directory_storage[0..directory_len];
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try createTestProviderWithModel(&runtime, "custom-secret", .{
        .display_name = "Custom",
        .protocol = .openai_responses,
        .normalized_base_url = "https://example.com/v1/responses",
    }, .{ .id = "chat" });
    const provider = runtime.views()[0];
    const probe: contract.CustomModelTestCommand = .{
        .model = .{ .source_id = TestVault.slot, .model_id = "chat" },
        .expected_provider_revision = provider.provider_revision,
        .expected_source_generation = provider.source_generation,
        .expected_catalog_generation = provider.catalog_generation,
    };
    try std.testing.expect(runtime.submitCommand(.{ .test_model = probe }).accepted);
    try std.testing.expect(runtime.completeTest(probe, true).accepted);
    try std.testing.expect(runtime.rememberPreference(probe.model).accepted);
    const dialogue_revision = runtime.view().selection_revision;
    const catalog = test_image_catalog;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-a", catalog));
    try std.testing.expectEqual(contract.ModelsError.no_models, runtime.view().providers[0].error_code);
    try std.testing.expectEqual(@as(usize, 0), runtime.view().providers[0].models.len);
    var credentials = TestSupport.FakeMetaskCredentials.init("principal-a", "fresh-lease", 17);
    runtime.metask_credentials = credentials.port();
    var candidate = runtime.prepareMediaCandidate(.image).ready;
    defer candidate.deinit();
    // The candidate owns its copy of the credential of that moment.
    credentials.set("principal-a", "other-lease");
    try std.testing.expectEqualStrings("fresh-lease", candidate.input().bearer);
    try std.testing.expectEqual(@as(u64, 17), candidate.credential_generation);
    try std.testing.expectEqualStrings("gemini-3.1-flash-image-preview", candidate.input().selection.model_id);
    try std.testing.expectEqualStrings(contract.metask_images_generations_url, candidate.input().endpoint);
    const bytes = (try runtime.store.?.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(bytes);
    for ([_][]const u8{ "fresh-lease", "refreshed-secret", "custom-secret", "metask_image" }) |secret|
        try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
    _ = runtime.followMetaskPrincipal(null, 0);
    try std.testing.expectEqual(contract.ManagementError.catalog_unavailable, runtime.prepareMediaCandidate(.image).rejected);
    try std.testing.expectEqualStrings("fresh-lease", candidate.input().bearer);
    var dialogue = (try TestSupport.resolveFixtureSelection(&runtime)).?;
    defer dialogue.deinit();
    try std.testing.expectEqualStrings("chat", dialogue.input().target.model);
    try std.testing.expectEqualStrings("custom-secret", dialogue.input().api_key);
    try std.testing.expectEqual(dialogue_revision, runtime.view().selection_revision);
    runtime.stop();
    try runtime.start(directory, vault.port());
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-b", catalog));
    // Another account's credential does not resolve against this catalog.
    credentials = TestSupport.FakeMetaskCredentials.init("principal-a", "new-account-lease", 18);
    runtime.metask_credentials = credentials.port();
    try std.testing.expectEqual(contract.ManagementError.authorization_unavailable, runtime.prepareMediaCandidate(.image).rejected);
    credentials.set("principal-b", "new-account-lease");
    var restarted = runtime.prepareMediaCandidate(.image).ready;
    defer restarted.deinit();
    try std.testing.expectEqualStrings(contract.metask_default_image_model, restarted.input().selection.model_id);
    try std.testing.expectEqual(dialogue_revision, runtime.view().selection_revision);
}

const test_image_catalog = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"" ++ contract.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";

test "image preparation requires current lease and falls back only before sending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    var credentials = TestSupport.FakeMetaskCredentials.init("principal", "fresh-secret", 17);
    runtime.metask_credentials = credentials.port();
    try std.testing.expectEqual(contract.ManagementError.catalog_unavailable, runtime.prepareMediaCandidate(.image).rejected);
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", test_image_catalog));
    // The helper left the port this test installed.
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&credentials)), runtime.metask_credentials.?.context);
    for (0..3) |case| {
        var wrong = TestSupport.FakeMetaskCredentials.init("principal", "fresh-secret", 17);
        switch (case) {
            0 => wrong.set("other", "fresh-secret"),
            1 => wrong.generation = 0,
            2 => wrong.set("principal", ""),
            else => unreachable,
        }
        runtime.metask_credentials = wrong.port();
        try std.testing.expectEqual(contract.ManagementError.authorization_unavailable, runtime.prepareMediaCandidate(.image).rejected);
    }
    runtime.metask_credentials = credentials.port();
    // A request underway and a renewed credential neither stop nor delay a
    // preparation: it reads the credential of the moment.
    _ = runtime.beginMetaskCatalogRequest(.user, .{ .ready = .{ .principal_ref = "principal", .generation = 17 } }, 0);
    credentials.generation = 18;
    var candidate = runtime.prepareMediaCandidate(.image).ready;
    defer candidate.deinit();
    try std.testing.expectEqualStrings("fresh-secret", candidate.input().bearer);
    try std.testing.expectEqual(@as(u64, 18), candidate.credential_generation);
    _ = runtime.failMetaskCatalogRequest(runtime.metask.request.?.id, .{ .code = .catalog_unavailable, .retryable = true }, 0);
    const unsupported = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"" ++ contract.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":false}}}}]}";
    const absent = "{\"object\":\"list\",\"has_more\":false,\"data\":[{\"id\":\"other-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";
    for ([_][]const u8{ unsupported, "{\"object\":\"list\",\"has_more\":false,\"data\":[]}" }) |body| {
        try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", body));
        try std.testing.expectEqual(contract.ManagementError.model_not_found, runtime.prepareMediaCandidate(.image).rejected);
    }
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", absent));
    // Each preparation reads the credential of its own moment.
    credentials.set("principal", "later-secret");
    var fallback = runtime.prepareMediaCandidate(.image).ready;
    defer fallback.deinit();
    try std.testing.expectEqualStrings("other-image", fallback.input().selection.model_id);
    try std.testing.expectEqualStrings("later-secret", fallback.input().bearer);
    try std.testing.expectEqualStrings("fresh-secret", candidate.input().bearer);
    try std.testing.expectEqualStrings(contract.metask_default_image_model, candidate.input().selection.model_id);
}

test "first empty Metask catalog has no inferred selection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal-1", &.{}));
    const view = runtime.view();
    try std.testing.expectEqual(contract.CatalogState.ready, view.providers[0].catalog_state);
    try std.testing.expectEqual(contract.ModelsError.no_models, view.providers[0].error_code);
    try std.testing.expect(view.providers[0].catalog_generation != 0);
    try std.testing.expect(view.default_selection == null);
    try std.testing.expect(!TestSupport.fixtureSelectionAvailable(&runtime));
    // A later populated catalog also leaves the starting preference unset.
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalog(&runtime, "principal-1", &.{.{ .id = "model-2", .display_name = "Model Two" }}));
    try std.testing.expect(runtime.view().default_selection == null);
}

test "stale Metask completion leaves the current catalog attempt intact" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    defer runtime.deinit();
    try TestSupport.installMetaskDefault(
        &runtime,
        "principal-1",
        "old-secret",
        &.{.{ .id = "model-1", .display_name = "Model One" }},
        "model-1",
        1,
        2,
        3,
        4,
    );
    _ = runtime.followMetaskPrincipal("principal-1", 17);
    const id = runtime.beginMetaskCatalogRequest(.user, .{ .ready = .{ .principal_ref = "principal-1", .generation = 17 } }, 0).outcome.started;
    var session = metask_provider.CatalogSession.init(std.testing.allocator);
    try metask_provider.TestSupport.replaceOwnedCatalog(&session, "principal-1", &.{});
    var completion = metask_provider.OwnedCatalogCompletion.init(&session);
    var port = completion.ownedPort();
    // Another request's answer is destroyed and changes nothing.
    try std.testing.expect(!runtime.completeMetaskCatalogRequest(id +% 1, &port, 0));
    try std.testing.expectEqual(id, runtime.metask.request.?.id);
    try std.testing.expectEqual(contract.CatalogState.ready, runtime.view().providers[0].catalog_state);
    try std.testing.expectEqual(@as(u64, 4), runtime.view().providers[0].catalog_generation);
    try std.testing.expect(!runtime.failMetaskCatalogRequest(id +% 1, .{ .code = .catalog_unavailable, .retryable = true }, 0));
    try std.testing.expectEqual(id, runtime.metask.request.?.id);
}

test "declared protocol refresh changes default authority and preserves old owned candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path[0..length], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const initial =
        \\{"object":"list","has_more":false,"data":[{"id":"model-1","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}}]}
    ;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-1", initial));
    try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "model-1" }).accepted);
    const old_source = runtime.view().providers[0].source_generation;
    const old_selection = runtime.view().selection_revision;
    var old_owned = (try TestSupport.resolveFixtureSelection(&runtime)).?;
    defer old_owned.deinit();

    const replacement =
        \\{"object":"list","has_more":false,"data":[{"id":"model-1","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":false,"status":"unknown"},"chat_completions":{"supported":true}}}},{"id":"model-2","object":"model","type":"model","capabilities":{"endpoints":{"responses":{"supported":true},"chat_completions":{"supported":true}}}}]}
    ;
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal-1", replacement));
    const current = runtime.view();
    try std.testing.expectEqualStrings("model-1", current.default_selection.?.model_id);
    try std.testing.expectEqual(old_selection, current.selection_revision);
    try std.testing.expectEqual(old_source, current.providers[0].source_generation);
    try std.testing.expectEqual(contract.Protocol.openai_chat_completions, runtime.sourceModelProtocol(.{ .source_id = "metask", .model_id = "model-1" }, current.providers[0].source_generation, current.providers[0].catalog_generation).?);
    try std.testing.expect(!runtime.metaskSourceModelAvailable(.{ .source_id = "metask", .model_id = "model-1" }, old_source, current.providers[0].catalog_generation, .anthropic_messages));
    try std.testing.expect(runtime.metaskSourceModelAvailable(.{ .source_id = "metask", .model_id = "model-1" }, current.providers[0].source_generation, current.providers[0].catalog_generation, .openai_chat_completions));
    try std.testing.expect(!runtime.metaskModelAvailable(null, .openai_chat_completions, "model-2"));
    try std.testing.expect(runtime.metaskModelAvailable(null, .openai_responses, "model-2"));
    var new_owned = (try TestSupport.resolveFixtureSelection(&runtime)).?;
    defer new_owned.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_chat_completions, new_owned.input().target.protocol);
    try std.testing.expectEqualStrings(contract.metaskEndpoint(.openai_chat_completions).?, new_owned.input().target.base_url);
    try std.testing.expectEqual(contract.Protocol.anthropic_messages, old_owned.input().target.protocol);
    try std.testing.expectEqualStrings(contract.metaskEndpoint(.anthropic_messages).?, old_owned.input().target.base_url);

    try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "model-2" }).accepted);
    var other = (try runtime.resolveModel(.{ .source_id = "metask", .model_id = "model-2" }, current.providers[0].source_generation, current.providers[0].catalog_generation)).?;
    defer other.deinit();
    try std.testing.expectEqual(contract.Protocol.openai_responses, other.input().target.protocol);
    try std.testing.expectEqualStrings("model-2", runtime.view().default_selection.?.model_id);
}

test "image model policy prefers the default and then the first declared generation endpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(path, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const entries = "{\"id\":\"text\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"messages\":{\"supported\":true}}}}," ++
        "{\"id\":\"video\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"videos\":{\"supported\":true}}}}," ++
        "{\"id\":\"guessed-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"output\":{\"image\":{\"supported\":true}}}}," ++
        "{\"id\":\"first-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}," ++
        "{\"id\":\"second-image\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}";
    const fallback_catalog = "{\"object\":\"list\",\"has_more\":false,\"data\":[" ++ entries ++ "]}";
    const preferred_catalog = "{\"object\":\"list\",\"has_more\":false,\"data\":[" ++ entries ++ "," ++
        "{\"id\":\"" ++ contract.metask_default_image_model ++ "\",\"object\":\"model\",\"type\":\"model\",\"capabilities\":{\"endpoints\":{\"images_generations\":{\"supported\":true}}}}]}";
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", preferred_catalog));
    var preferred = runtime.prepareMediaCandidate(.image).ready;
    defer preferred.deinit();
    try std.testing.expectEqualStrings(contract.metask_default_image_model, preferred.input().selection.model_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.view().providers[0].models.len);
    try std.testing.expectEqualStrings("text", runtime.view().providers[0].models[0].id);
    try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogResponse(&runtime, "principal", fallback_catalog));
    var fallback = runtime.prepareMediaCandidate(.image).ready;
    defer fallback.deinit();
    try std.testing.expectEqualStrings("first-image", fallback.input().selection.model_id);
    try std.testing.expectEqualStrings(contract.metask_default_image_model, preferred.input().selection.model_id);
}

test "Metask source survives a credential change when the selected model leaves the catalog" {
    const Refresh = struct {
        fn run(runtime: *Runtime, token: []const u8, generation: u64, body: []const u8) !void {
            var session = metask_provider.CatalogSession.init(std.testing.allocator);
            defer session.deinit();
            try metask_provider.TestSupport.loadCatalogResponse(&session, "principal", token, body);
            _ = runtime.followMetaskPrincipal("principal", generation);
            const id = runtime.beginMetaskCatalogRequest(.user, .{ .ready = .{ .principal_ref = "principal", .generation = generation } }, 0).outcome.started;
            // What Account lends from now on: this token, of this generation.
            TestSupport.useSharedCredentials(runtime, "principal", token);
            TestSupport.shared_credentials.generation = generation;
            var completion = metask_provider.OwnedCatalogCompletion.init(&session);
            var port = completion.ownedPort();
            _ = runtime.completeMetaskCatalogRequest(id, &port, 0);
            try std.testing.expect(runtime.metask.catalog != null);
        }
    };
    const initial =
        \\{"object":"list","has_more":false,"data":[{"id":"selected","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}},{"id":"other","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}}]}
    ;
    const removed =
        \\{"object":"list","has_more":false,"data":[{"id":"other","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}}]}
    ;
    const excluded =
        \\{"object":"list","has_more":false,"data":[{"id":"selected","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true},"images_generations":{"supported":true}}}},{"id":"other","object":"model","type":"model","capabilities":{"endpoints":{"messages":{"supported":true}}}}]}
    ;
    const empty =
        \\{"object":"list","has_more":false,"data":[]}
    ;
    for ([_][]const u8{ removed, excluded, empty }) |updated| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(home);
        var vault = TestVault{};
        var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
        try runtime.start(home, vault.port());
        defer {
            runtime.stop();
            runtime.deinit();
        }
        try Refresh.run(&runtime, "synthetic-authority-a", 17, initial);
        try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "selected" }).accepted);
        const source_a = runtime.view().providers[0].source_generation;
        const selection = runtime.view().selection_revision;
        try Refresh.run(&runtime, "synthetic-authority-b", 18, updated);
        const source_b = runtime.view().providers[0].source_generation;
        try std.testing.expect(source_b != 0 and source_b == source_a);
        try std.testing.expectEqual(selection, runtime.view().selection_revision);
        try std.testing.expectEqualStrings("selected", runtime.view().default_selection.?.model_id);
        try std.testing.expectEqualStrings("selected", runtime.view().default_selection.?.model_id);
        try std.testing.expect((try TestSupport.resolveFixtureSelection(&runtime)) == null);
        if (!std.mem.eql(u8, updated, empty)) {
            var other = (try runtime.resolveModel(.{ .source_id = "metask", .model_id = "other" }, source_b, runtime.view().providers[0].catalog_generation)).?;
            defer other.deinit();
            try std.testing.expectEqualStrings("synthetic-authority-b", other.input().api_key);
            try std.testing.expectEqual(source_b, other.input().source_generation);
            try std.testing.expectEqual(@as(u64, 18), other.input().credential_generation);
        }
        // No new persistent shape or implicit selection is needed.
        const encoded = try registry_impl.encodeAlloc(std.testing.allocator, &runtime.registry);
        defer std.testing.allocator.free(encoded);
        var decoded = try registry_impl.decode(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(source_b, decoded.metaskSource().?.source_generation);
        try std.testing.expectEqualStrings("selected", decoded.defaultSelection().?.model_id);
        try Refresh.run(&runtime, "synthetic-authority-b", 18, updated);
        try std.testing.expectEqual(source_b, runtime.view().providers[0].source_generation);
    }
}

test "Metask source follows its account through a switch, a return, a restart and an adoption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);
    var vault = TestVault{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(home, vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    const models = [_]contract.ModelView{.{ .id = "model-1", .display_name = "Model One" }};
    const Account = struct { principal: []const u8, token: []const u8 };
    var seen: [4]u64 = undefined;
    for ([_]Account{
        .{ .principal = "account-a", .token = "a-1" },
        .{ .principal = "account-a", .token = "a-2" },
        .{ .principal = "account-b", .token = "b-1" },
        .{ .principal = "account-a", .token = "a-3" },
    }, &seen) |account, *generation| {
        try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogWithCredential(&runtime, account.principal, account.token, &models));
        generation.* = runtime.view().providers[0].source_generation;
    }
    try std.testing.expect(seen[0] == seen[1] and seen[0] == seen[3] and seen[0] != seen[2]);
    runtime.stop();
    try runtime.start(home, vault.port());
    try std.testing.expectEqual(seen[0], runtime.view().providers[0].source_generation);
    try std.testing.expect(runtime.pendingMetaskAdoption() == null);

    // An older version left the same account under a value it drew itself.
    runtime.registry.metask_source_generation = 1234;
    try std.testing.expect(runtime.rememberPreference(.{ .source_id = "metask", .model_id = "model-1" }).accepted);
    for ([_]bool{ false, true }) |writes| {
        runtime.stop();
        try runtime.start(home, vault.port());
        const adoption = runtime.pendingMetaskAdoption().?;
        try std.testing.expectEqual(@as(u64, 1234), adoption.stored);
        try std.testing.expectEqual(seen[0], adoption.derived);
        // Until it is adopted the stored value is as stable as the derived one.
        try std.testing.expectEqual(contract.ModelsError.none, try TestSupport.refreshMetaskCatalogWithCredential(&runtime, "account-a", "a-4", &models));
        try std.testing.expectEqual(@as(u64, 1234), runtime.view().providers[0].source_generation);
        const store = runtime.store;
        if (!writes) runtime.store = null;
        runtime.adoptMetaskGeneration(adoption);
        runtime.store = store;
        try std.testing.expectEqual(seen[0], runtime.view().providers[0].source_generation);
        try std.testing.expect(runtime.pendingMetaskAdoption() == null);
    }
    runtime.stop();
    try runtime.start(home, vault.port());
    try std.testing.expect(runtime.pendingMetaskAdoption() == null);
    try std.testing.expectEqual(seen[0], runtime.view().providers[0].source_generation);
}

/// Passes allocations through and remembers whether anything freed still held
/// `secret`, which is how a key that was not zeroed would be left behind.
const SecretWatchingAllocator = struct {
    secret: []const u8,
    leaked: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn resize(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        return std.testing.allocator.rawResize(bytes, alignment, len, ra);
    }
    fn remap(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(bytes, alignment, len, ra);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.indexOf(u8, bytes, self.secret) != null) self.leaked = true;
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};

test "a held key is zeroed when it is dropped and when Models is destroyed" {
    const secret = "held-configured-key-0001";
    const Sink = struct {
        admitted: usize = 0,
        retired: usize = 0,
        held_at: ?[*]const u8 = null,
        retired_at: ?[*]const u8 = null,
        fn admit(context: *anyopaque, value: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.mem.eql(u8, value, secret));
            self.admitted += 1;
            return true;
        }
        fn retire(context: *anyopaque, value: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(std.mem.eql(u8, value, secret));
            self.retired += 1;
            self.retired_at = value.ptr;
            return true;
        }
        fn remember(context: *anyopaque, value: []const u8) std.mem.Allocator.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.held_at = value.ptr;
        }
        fn port(self: *@This()) ResidentSink {
            return .{ .context = self, .admit_fn = admit, .retire_fn = retire };
        }
        fn count(context: *anyopaque, _: []const u8) std.mem.Allocator.Error!void {
            const held: *usize = @ptrCast(@alignCast(context));
            held.* += 1;
        }
    };
    // Dropped by a sync once Models stopped, or still held when it is destroyed.
    for ([_]bool{ true, false }) |drop_before_deinit| {
        var watching: SecretWatchingAllocator = .{ .secret = secret };
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
        var vault: TestVault = .{};
        var runtime = Runtime.init(watching.allocator(), std.testing.io, std.Thread.getCurrentId());
        try runtime.start(directory_storage[0..directory_len], vault.port());
        try std.testing.expect(runtime.createWithCredential(secret, .{
            .display_name = "Local",
            .protocol = .openai_chat_completions,
            .normalized_base_url = "http://127.0.0.1:11434/v1/chat/completions",
        }).accepted);
        var sink: Sink = .{};
        runtime.syncResidentCredentials(sink.port());
        var held: usize = 0;
        try runtime.visitResidentCredentials(&held, Sink.count);
        try std.testing.expectEqual(@as(usize, 1), sink.admitted);
        try std.testing.expectEqual(@as(usize, 1), held);
        try runtime.visitResidentCredentials(&sink, Sink.remember);
        runtime.stop();
        if (drop_before_deinit) {
            runtime.syncResidentCredentials(sink.port());
            try std.testing.expectEqual(@as(usize, 1), sink.retired);
            // What leaves is the copy that was held, so a caller can tell it
            // apart by pointer from another holder's equal bytes.
            try std.testing.expectEqual(sink.held_at, sink.retired_at);
            held = 0;
            try runtime.visitResidentCredentials(&held, Sink.count);
            try std.testing.expectEqual(@as(usize, 0), held);
        }
        runtime.deinit();
        try std.testing.expect(!watching.leaked);
    }
}

test "a key the sink refuses is not read again until its revision changes or the sink can try again" {
    const Sink = struct {
        refuse: bool = true,
        admits: usize = 0,
        retires: usize = 0,
        fn admit(context: *anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.admits += 1;
            return !self.refuse;
        }
        fn retire(context: *anyopaque, _: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.retires += 1;
            return !self.refuse;
        }
        fn port(self: *@This()) ResidentSink {
            return .{ .context = self, .admit_fn = admit, .retire_fn = retire };
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_len = try tmp.dir.realPath(std.testing.io, &directory_storage);
    var vault: TestVault = .{};
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    try runtime.start(directory_storage[0..directory_len], vault.port());
    defer {
        runtime.stop();
        runtime.deinit();
    }
    try std.testing.expect(runtime.createWithCredential("first-configured-key-0001", .{
        .display_name = "Local",
        .protocol = .openai_chat_completions,
        .normalized_base_url = "http://127.0.0.1:11434/v1/chat/completions",
    }).accepted);
    var sink: Sink = .{};
    // A key the sink cannot take now is asked about once per revision.
    runtime.syncResidentCredentials(sink.port());
    runtime.syncResidentCredentials(sink.port());
    try std.testing.expectEqual(@as(usize, 1), sink.admits);
    runtime.retryRefusedResidentCredentials();
    sink.refuse = false;
    runtime.syncResidentCredentials(sink.port());
    try std.testing.expectEqual(@as(usize, 2), sink.admits);
    // So is one it cannot let go of when the key is replaced.
    sink.refuse = true;
    const view = runtime.views()[0];
    try std.testing.expect(runtime.replaceCredential("second-configured-key-02", .{ .source_id = view.id, .expected_provider_revision = view.provider_revision }).accepted);
    runtime.syncResidentCredentials(sink.port());
    runtime.syncResidentCredentials(sink.port());
    try std.testing.expectEqual(@as(usize, 1), sink.retires);
    try std.testing.expectEqual(@as(usize, 2), sink.admits);
    runtime.retryRefusedResidentCredentials();
    sink.refuse = false;
    runtime.syncResidentCredentials(sink.port());
    try std.testing.expectEqual(@as(usize, 2), sink.retires);
    try std.testing.expectEqual(@as(usize, 3), sink.admits);
}

test "every catalog helper starts the shared credential port afresh" {
    var runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId());
    defer runtime.deinit();
    const models = [_]contract.ModelView{.{ .id = "model-1", .display_name = "Model One" }};
    for ([_][]const u8{ "secret-a", "secret-b" }) |secret| {
        // Whatever an earlier test left behind.
        TestSupport.shared_credentials.generation = 99;
        TestSupport.shared_credentials.reads = 5;
        try TestSupport.installMetaskDefault(&runtime, "principal-1", secret, &models, "model-1", 1, 2, 3, 4);
        try std.testing.expectEqual(TestSupport.FakeMetaskCredentials.default_generation, TestSupport.shared_credentials.generation);
        try std.testing.expectEqual(@as(usize, 0), TestSupport.shared_credentials.reads);
        var candidate = (try TestSupport.resolveFixtureSelection(&runtime)).?;
        defer candidate.deinit();
        try std.testing.expectEqualStrings(secret, candidate.input().api_key);
        try std.testing.expectEqual(TestSupport.FakeMetaskCredentials.default_generation, candidate.input().credential_generation);
        try std.testing.expectEqual(@as(usize, 1), TestSupport.shared_credentials.reads);
    }
}

/// A started Models runtime for the Metask catalog tests below.
const MetaskCatalogFixture = struct {
    tmp: std.testing.TmpDir,
    vault: TestVault = .{},
    runtime: Runtime,
    credentials: TestSupport.FakeMetaskCredentials,

    fn init(self: *MetaskCatalogFixture) !void {
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .runtime = Runtime.init(std.testing.allocator, std.testing.io, std.Thread.getCurrentId()),
            .credentials = TestSupport.FakeMetaskCredentials.init("principal", "token-a", 17),
        };
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &path);
        try self.runtime.start(path[0..len], self.vault.port());
        self.runtime.metask_credentials = self.credentials.port();
    }

    fn deinit(self: *MetaskCatalogFixture) void {
        self.runtime.stop();
        self.runtime.deinit();
        self.tmp.cleanup();
    }

    fn begin(self: *MetaskCatalogFixture, kind: contract.CatalogRequestKind, generation: u64, now_ms: u64) contract.CatalogRequestStart {
        return self.runtime.beginMetaskCatalogRequest(kind, .{ .ready = .{ .principal_ref = "principal", .generation = generation } }, now_ms);
    }

    /// Completes request `id` with these models; whether anything published changed.
    fn complete(self: *MetaskCatalogFixture, id: u64, models: []const contract.ModelView, now_ms: u64) !bool {
        var session = metask_provider.CatalogSession.init(std.testing.allocator);
        defer session.deinit();
        try metask_provider.TestSupport.replaceOwnedCatalog(&session, "principal", models);
        var completion = metask_provider.OwnedCatalogCompletion.init(&session);
        var port = completion.ownedPort();
        return self.runtime.completeMetaskCatalogRequest(id, &port, now_ms);
    }

    fn provider(self: *MetaskCatalogFixture) contract.ProviderView {
        return self.runtime.view().providers[0];
    }
};

const catalog_one = [_]contract.ModelView{.{ .id = "model-1", .display_name = "Model One" }};
const catalog_two = [_]contract.ModelView{ .{ .id = "model-1", .display_name = "Model One" }, .{ .id = "model-2", .display_name = "Model Two" } };
const catalog_two_reordered = [_]contract.ModelView{ .{ .id = "model-2", .display_name = "Model Two" }, .{ .id = "model-1", .display_name = "Model One" } };

test "the Metask catalog follows its account: a new credential changes nothing, another account empties it" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    // Before any account Models has nothing, and nothing is due.
    try std.testing.expectEqual(contract.CatalogState.needs_authentication, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsError.none, fixture.provider().error_code);
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
    // A cold start without an account lost none: no reason to show.
    try std.testing.expect(!runtime.followMetaskPrincipal(null, 0).changed);
    try std.testing.expectEqual(contract.CatalogState.needs_authentication, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsError.none, fixture.provider().error_code);
    const first = runtime.followMetaskPrincipal("principal", 17);
    try std.testing.expect(first.changed and !first.dropped);
    try std.testing.expectEqual(contract.CatalogState.loading, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsOperation.refreshing_catalog, runtime.view().operation);
    try std.testing.expect(runtime.metaskCatalogDue(0));
    const id = fixture.begin(.due, 17, 0).outcome.started;
    try std.testing.expect(try fixture.complete(id, &catalog_one, 0));
    const loaded = fixture.provider();
    try std.testing.expectEqual(contract.CatalogState.ready, loaded.catalog_state);
    try std.testing.expectEqual(contract.ModelsOperation.idle, runtime.view().operation);
    // Renewed: the account is the same, so the catalog, its generation and
    // its next time stay as they were.
    const renewed = runtime.followMetaskPrincipal("principal", 18);
    try std.testing.expect(!renewed.changed and !renewed.dropped);
    try std.testing.expectEqual(loaded.catalog_generation, fixture.provider().catalog_generation);
    try std.testing.expect(!runtime.metaskCatalogDue(0));
    // Another account: the content goes, a request underway with it.
    const background = fixture.begin(.user, 18, 0).outcome.started;
    _ = background;
    const switched = runtime.followMetaskPrincipal("principal-b", 3);
    try std.testing.expect(switched.changed and switched.dropped);
    try std.testing.expect(runtime.metask.request == null);
    try std.testing.expectEqual(contract.CatalogState.loading, fixture.provider().catalog_state);
    try std.testing.expectEqual(@as(u64, 0), fixture.provider().catalog_generation);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider().models.len);
    // Signed out: nothing is left, and the view says why.
    try std.testing.expect(runtime.followMetaskPrincipal(null, 0).changed);
    try std.testing.expectEqual(contract.CatalogState.needs_authentication, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsError.authorization_unavailable, fixture.provider().error_code);
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
}

test "a Metask refresh with content in hand publishes only a change of content" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    _ = runtime.followMetaskPrincipal("principal", 17);
    try std.testing.expect(try fixture.complete(fixture.begin(.due, 17, 0).outcome.started, &catalog_two, 0));
    const generation = fixture.provider().catalog_generation;
    const source = fixture.provider().source_generation;
    // The beat runs only in front.
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
    runtime.setMetaskCatalogActive(true);
    const due = metask_provider.refresh_interval_ms;
    try std.testing.expectEqual(@as(?u64, due), runtime.metaskCatalogNext());
    try std.testing.expect(fixture.begin(.due, 17, due - 1).outcome == .skipped);
    // Out of sight while underway, and when it fails.
    const failing = fixture.begin(.due, 17, due);
    try std.testing.expect(!failing.changed);
    try std.testing.expectEqual(contract.ModelsOperation.idle, runtime.view().operation);
    try std.testing.expect(!runtime.failMetaskCatalogRequest(failing.outcome.started, .{ .code = .catalog_unavailable, .retryable = true }, due));
    try std.testing.expectEqual(contract.CatalogState.ready, fixture.provider().catalog_state);
    try std.testing.expectEqual(@as(?u64, 2 * due), runtime.metaskCatalogNext());
    // The same content, in another order, is no change.
    try std.testing.expect(!try fixture.complete(fixture.begin(.due, 17, 2 * due).outcome.started, &catalog_two_reordered, 2 * due));
    try std.testing.expectEqual(generation, fixture.provider().catalog_generation);
    try std.testing.expectEqualStrings("model-1", fixture.provider().models[0].id);
    // A model gone is: the whole catalog is replaced under a new generation,
    // the source identity untouched.
    try std.testing.expect(try fixture.complete(fixture.begin(.due, 17, 3 * due).outcome.started, &catalog_one, 3 * due));
    try std.testing.expect(generation != fixture.provider().catalog_generation);
    try std.testing.expectEqual(source, fixture.provider().source_generation);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider().models.len);
    // The person's own refresh shows while it runs.
    const own = fixture.begin(.user, 17, 3 * due);
    try std.testing.expect(own.changed);
    try std.testing.expectEqual(contract.ModelsOperation.refreshing_catalog, runtime.view().operation);
    try std.testing.expect(try fixture.complete(own.outcome.started, &catalog_one, 3 * due));
    try std.testing.expectEqual(contract.ModelsOperation.idle, runtime.view().operation);
    // In the background nothing comes due, however long it stays there.
    runtime.setMetaskCatalogActive(false);
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
    try std.testing.expect(!runtime.metaskCatalogDue(10 * due));
    // Back in front after its time passed: due at once.
    runtime.setMetaskCatalogActive(true);
    try std.testing.expect(runtime.metaskCatalogDue(10 * due));
}

test "a Metask load tries once more before it fails, and stays lit in between" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    _ = runtime.followMetaskPrincipal("principal", 17);
    const first = fixture.begin(.due, 17, 0).outcome.started;
    // The first failure is not the end of the load anyone waits for.
    try std.testing.expect(!runtime.failMetaskCatalogRequest(first, .{ .code = .catalog_unavailable, .retryable = true }, 0));
    try std.testing.expectEqual(contract.CatalogState.loading, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsOperation.refreshing_catalog, runtime.view().operation);
    try std.testing.expectEqual(contract.MetaskCatalogAvailability.loading, runtime.metaskCatalog());
    try std.testing.expectEqual(@as(?u64, metask_provider.retry_delay_ms), runtime.metaskCatalogNext());
    try std.testing.expect(!runtime.metaskCatalogDue(metask_provider.retry_delay_ms - 1));
    // An Account publication in between does not try the same token early.
    _ = runtime.followMetaskPrincipal("principal", 17);
    try std.testing.expectEqual(@as(?u64, metask_provider.retry_delay_ms), runtime.metaskCatalogNext());
    const second = fixture.begin(.due, 17, metask_provider.retry_delay_ms).outcome.started;
    try std.testing.expect(runtime.failMetaskCatalogRequest(second, .{ .code = .catalog_unavailable, .retryable = true }, metask_provider.retry_delay_ms));
    try std.testing.expectEqual(contract.CatalogState.failed, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsError.catalog_unavailable, fixture.provider().error_code);
    try std.testing.expectEqual(contract.ModelsOperation.idle, runtime.view().operation);
    // A failure nothing changes soon ends the load at once.
    _ = runtime.followMetaskPrincipal(null, 0);
    _ = runtime.followMetaskPrincipal("principal", 17);
    const refused = fixture.begin(.due, 17, 0).outcome.started;
    try std.testing.expect(runtime.failMetaskCatalogRequest(refused, .{ .code = .catalog_invalid, .retryable = false }, 0));
    try std.testing.expectEqual(contract.CatalogState.failed, fixture.provider().catalog_state);
}

test "a failed Metask load tries once with another credential, out of sight, and the person's retry is the load they see" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    _ = runtime.followMetaskPrincipal("principal", 17);
    _ = runtime.failMetaskCatalogRequest(fixture.begin(.due, 17, 0).outcome.started, .{ .code = .catalog_unavailable, .retryable = true }, 0);
    _ = runtime.failMetaskCatalogRequest(fixture.begin(.due, 17, 2_000).outcome.started, .{ .code = .catalog_unavailable, .retryable = true }, 2_000);
    try std.testing.expectEqual(contract.CatalogState.failed, fixture.provider().catalog_state);
    // The credential it failed with asks for nothing again.
    _ = runtime.followMetaskPrincipal("principal", 17);
    try std.testing.expect(!runtime.metaskCatalogDue(2_000));
    // Another one does, in front or not, and out of sight.
    _ = runtime.followMetaskPrincipal("principal", 18);
    try std.testing.expect(runtime.metaskCatalogDue(2_000));
    const quiet = fixture.begin(.due, 18, 2_000);
    try std.testing.expect(!quiet.changed);
    try std.testing.expectEqual(contract.CatalogState.failed, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsOperation.idle, runtime.view().operation);
    // The person asks meanwhile: that request becomes the load they see.
    try std.testing.expect(runtime.joinMetaskCatalogRequest());
    try std.testing.expectEqual(contract.CatalogState.loading, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsOperation.refreshing_catalog, runtime.view().operation);
    try std.testing.expect(runtime.metask.request.?.visible);
    try std.testing.expect(try fixture.complete(quiet.outcome.started, &catalog_one, 2_000));
    try std.testing.expectEqual(contract.CatalogState.ready, fixture.provider().catalog_state);
    try std.testing.expectEqual(contract.ModelsOperation.idle, runtime.view().operation);
}

test "a Metask load that fails after Account renewed under it tries the new credential at once" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    const retry = metask_provider.retry_delay_ms;
    _ = runtime.followMetaskPrincipal("principal", 17);
    _ = runtime.failMetaskCatalogRequest(fixture.begin(.due, 17, 0).outcome.started, .{ .code = .catalog_unavailable, .retryable = true }, 0);
    // The second try goes out with 17, and Account renews while it is underway.
    const second = fixture.begin(.due, 17, retry).outcome.started;
    _ = runtime.followMetaskPrincipal("principal", 18);
    try std.testing.expect(runtime.failMetaskCatalogRequest(second, .{ .code = .catalog_unavailable, .retryable = true }, retry));
    try std.testing.expectEqual(contract.CatalogState.failed, fixture.provider().catalog_state);
    // Not the beat: 18 has not been tried.
    try std.testing.expect(runtime.metaskCatalogDue(retry));
    const third = fixture.begin(.due, 18, retry);
    try std.testing.expect(!third.changed);
    try std.testing.expect(!runtime.failMetaskCatalogRequest(third.outcome.started, .{ .code = .catalog_unavailable, .retryable = true }, retry));
    // 18 failed too: now the beat.
    try std.testing.expect(!runtime.metaskCatalogDue(retry));
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
    runtime.setMetaskCatalogActive(true);
    try std.testing.expectEqual(@as(?u64, retry + metask_provider.refresh_interval_ms), runtime.metaskCatalogNext());
}

test "a Metask request without a credential waits for Account, and a reset loads the catalog again" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    _ = runtime.followMetaskPrincipal("principal", 17);
    // No credential to give now: the load waits for Account's next one.
    const waiting = runtime.beginMetaskCatalogRequest(.due, .unavailable, 0);
    try std.testing.expectEqual(contract.ModelsError.authorization_unavailable, waiting.outcome.rejected);
    try std.testing.expectEqual(contract.CatalogState.loading, fixture.provider().catalog_state);
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
    _ = runtime.followMetaskPrincipal("principal", 17);
    try std.testing.expect(runtime.metaskCatalogDue(0));
    try std.testing.expect(try fixture.complete(fixture.begin(.due, 17, 0).outcome.started, &catalog_one, 0));
    // With content, a beat without a credential just skips.
    runtime.setMetaskCatalogActive(true);
    const due = metask_provider.refresh_interval_ms;
    _ = runtime.beginMetaskCatalogRequest(.due, .unavailable, due);
    try std.testing.expectEqual(@as(?u64, 2 * due), runtime.metaskCatalogNext());
    // A store that cannot be trusted asks for nothing and keeps the content.
    runtime.store_healthy = false;
    try std.testing.expectEqual(@as(?u64, null), runtime.metaskCatalogNext());
    try std.testing.expectEqual(contract.ModelsError.persistence_unavailable, fixture.begin(.user, 17, 2 * due).outcome.rejected);
    try std.testing.expect(runtime.metask.catalog != null);
    // A reset empties it and loads it again at once; the load writes the
    // source identity back.
    try std.testing.expect(runtime.resetStore().accepted);
    try std.testing.expectEqual(contract.CatalogState.loading, fixture.provider().catalog_state);
    try std.testing.expect(runtime.metaskCatalogDue(2 * due));
    try std.testing.expect(try fixture.complete(fixture.begin(.due, 17, 2 * due).outcome.started, &catalog_one, 2 * due));
    try std.testing.expectEqual(contract.CatalogState.ready, fixture.provider().catalog_state);
    try std.testing.expectEqualStrings("principal", fixture.provider().principal_ref);
}

test "Metask resolution reads the credential once, for the catalog's account only" {
    var fixture: MetaskCatalogFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const runtime = &fixture.runtime;
    _ = runtime.followMetaskPrincipal("principal", 17);
    try std.testing.expect(try fixture.complete(fixture.begin(.due, 17, 0).outcome.started, &catalog_one, 0));
    const provider = fixture.provider();
    const target: contract.ModelRef = .{ .source_id = "metask", .model_id = "model-1" };
    const reads = fixture.credentials.reads;
    fixture.credentials.generation = 21;
    var candidate = (try runtime.resolveModel(target, provider.source_generation, provider.catalog_generation)).?;
    defer candidate.deinit();
    try std.testing.expectEqual(reads + 1, fixture.credentials.reads);
    try std.testing.expectEqualStrings("token-a", candidate.input().api_key);
    try std.testing.expectEqual(@as(u64, 21), candidate.input().credential_generation);
    // Another account's credential, or none, resolves nothing.
    fixture.credentials.set("principal-b", "token-b");
    try std.testing.expect((try runtime.resolveModel(target, provider.source_generation, provider.catalog_generation)) == null);
    fixture.credentials.set("principal", "");
    try std.testing.expect((try runtime.resolveModel(target, provider.source_generation, provider.catalog_generation)) == null);
}
