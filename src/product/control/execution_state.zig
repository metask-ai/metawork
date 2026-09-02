//! Product Control-owned installed Execution state. This aggregate owns
//! replacement/redaction ordering and the process-local default execution
//! authority consumed by Task and Schedule. Account projection and catalog
//! authority remain outside this aggregate.

const std = @import("std");
const builtin = @import("builtin");
const models_contract = @import("metawork_product_models_contract");

const ActiveExecution = struct {
    allocator: std.mem.Allocator,
    credential_storage: []u8,
    model_storage: []u8,
    base_url_storage: []u8,
    credential_len: usize = 0,
    model_len: usize = 0,
    base_url_len: usize = 0,
    provider_id_storage: [models_contract.Limits.provider_id_bytes]u8 = undefined,
    provider_id_len: usize = 0,
    protocol: ?models_contract.Protocol = null,
    generation: u64 = 0,

    fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!ActiveExecution {
        const credential_storage = try allocator.alloc(u8, models_contract.Limits.credential_bytes);
        errdefer allocator.free(credential_storage);
        const model_storage = try allocator.alloc(u8, models_contract.Limits.model_id_bytes);
        errdefer allocator.free(model_storage);
        const base_url_storage = try allocator.alloc(u8, models_contract.Limits.base_url_bytes);
        errdefer allocator.free(base_url_storage);
        return .{
            .allocator = allocator,
            .credential_storage = credential_storage,
            .model_storage = model_storage,
            .base_url_storage = base_url_storage,
        };
    }

    fn deinit(self: *ActiveExecution) void {
        std.crypto.secureZero(u8, self.credential_storage);
        self.allocator.free(self.base_url_storage);
        self.allocator.free(self.model_storage);
        self.allocator.free(self.credential_storage);
        self.* = undefined;
    }

    fn installNoFail(self: *ActiveExecution, execution: *models_contract.OwnedConfig) void {
        const input = execution.input();
        const validation = if (execution.source == .model_connection)
            models_contract.validateModelConnectionExecutionConfig(input)
        else
            models_contract.validateConfigStructure(input);
        validation catch @panic("Product received an invalid ExecutionConfig");
        self.installBytesNoFail(input);
        execution.deinit();
    }

    fn installBytesNoFail(self: *ActiveExecution, input: models_contract.ConfigInput) void {
        const credential_bytes = input.api_key;
        const model_id = input.target.model;
        const base_url = input.target.base_url;
        const generation = input.execution_generation;
        std.debug.assert(input.target.provider_id.len <= self.provider_id_storage.len);
        @memcpy(self.provider_id_storage[0..input.target.provider_id.len], input.target.provider_id);
        self.provider_id_len = input.target.provider_id.len;
        self.protocol = input.target.protocol;
        std.debug.assert(credential_bytes.len <= self.credential_storage.len);
        std.debug.assert(model_id.len <= self.model_storage.len);
        std.debug.assert(base_url.len <= self.base_url_storage.len);
        std.crypto.secureZero(u8, self.credential_storage);
        @memcpy(self.credential_storage[0..credential_bytes.len], credential_bytes);
        @memcpy(self.model_storage[0..model_id.len], model_id);
        @memcpy(self.base_url_storage[0..base_url.len], base_url);
        self.credential_len = credential_bytes.len;
        self.model_len = model_id.len;
        self.base_url_len = base_url.len;
        self.generation = generation;
    }

    fn clearNoFail(self: *ActiveExecution) void {
        std.crypto.secureZero(u8, self.credential_storage);
        self.credential_len = 0;
        self.model_len = 0;
        self.base_url_len = 0;
        self.protocol = null;
        self.provider_id_len = 0;
        self.generation = 0;
    }

    fn providerId(self: *const ActiveExecution) []const u8 {
        return self.provider_id_storage[0..self.provider_id_len];
    }
    fn credential(self: *const ActiveExecution) []const u8 {
        return self.credential_storage[0..self.credential_len];
    }
    fn model(self: *const ActiveExecution) []const u8 {
        return self.model_storage[0..self.model_len];
    }
    fn baseUrl(self: *const ActiveExecution) []const u8 {
        return self.base_url_storage[0..self.base_url_len];
    }
    fn ready(self: *const ActiveExecution) bool {
        return self.generation != 0 and self.protocol != null and
            self.provider_id_len != 0 and
            self.credential_len != 0 and self.model_len != 0;
    }
};

const ReplacementKind = enum { none, default, identity };

const RedactionPreparation = union(enum) {
    none,
    install: struct {
        generation: u64,
        credential_ptr: [*]const u8,
        credential_len: usize,
    },
    clear: u64,
};

pub const PreparedModelConnectionBinding = struct {
    allocator: std.mem.Allocator,
    connection_id: []u8,
    model_id: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        connection_id: []const u8,
        model_id: []const u8,
    ) std.mem.Allocator.Error!PreparedModelConnectionBinding {
        const owned_connection_id = try allocator.dupe(u8, connection_id);
        errdefer allocator.free(owned_connection_id);
        return .{
            .allocator = allocator,
            .connection_id = owned_connection_id,
            .model_id = try allocator.dupe(u8, model_id),
        };
    }

    pub fn deinit(self: *PreparedModelConnectionBinding) void {
        self.allocator.free(self.model_id);
        self.allocator.free(self.connection_id);
        self.* = undefined;
    }
};

pub const ExecutionIdentity = struct {
    generation: u64,
    protocol: models_contract.Protocol,
};

pub const AutomationInput = struct {
    protocol: models_contract.Protocol,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
    generation: u64,
};

pub const ProjectionRedaction = struct {
    context: *anyopaque,
    apply_fn: *const fn (*anyopaque, []const u8) void,

    pub fn apply(self: ProjectionRedaction, credential: []const u8) void {
        self.apply_fn(self.context, credential);
    }
};

pub const State = struct {
    execution: ActiveExecution,
    metask_source_binding_generation: u64 = 0,
    replacement: ReplacementKind = .none,
    redaction_preparation: RedactionPreparation = .none,
    custom_binding: ?PreparedModelConnectionBinding = null,
    default_selection_revision: u64 = 0,
    availability_error: models_contract.AvailabilityError = .none,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!State {
        return .{
            .execution = try ActiveExecution.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.execution.deinit();
        if (self.custom_binding) |*binding| binding.deinit();
        self.* = undefined;
    }

    pub fn beginIdentityReplacement(self: *State) error{ExecutionInUse}!void {
        if (self.replacement != .none) return error.ExecutionInUse;
        std.debug.assert(self.redaction_preparation == .none);
        self.replacement = .identity;
        self.availability_error = .none;
    }

    pub fn beginDefaultReplacement(self: *State) error{ExecutionInUse}!void {
        if (self.replacement != .none) return error.ExecutionInUse;
        std.debug.assert(self.redaction_preparation == .none);
        self.replacement = .default;
        self.availability_error = .none;
    }

    pub fn endReplacementNoFail(self: *State) void {
        std.debug.assert(self.replacement != .none);
        self.replacement = .none;
        self.redaction_preparation = .none;
    }

    pub fn prepareInstall(self: *State, input: models_contract.ConfigInput, durable: anytype) !void {
        std.debug.assert(self.replacement != .none);
        std.debug.assert(self.redaction_preparation == .none);
        try durable.apply(input.api_key);
        self.redaction_preparation = .{ .install = .{
            .generation = input.execution_generation,
            .credential_ptr = input.api_key.ptr,
            .credential_len = input.api_key.len,
        } };
    }

    pub fn prepareClear(self: *State, durable: anytype) !void {
        std.debug.assert(self.replacement != .none);
        std.debug.assert(self.redaction_preparation == .none);
        try durable.apply("");
        self.redaction_preparation = .{ .clear = self.execution.generation };
    }

    pub fn installMetaskNoFail(
        self: *State,
        execution: *models_contract.OwnedConfig,
        source_generation: u64,
        redaction: ProjectionRedaction,
    ) void {
        std.debug.assert(self.replacement != .none);
        const input = execution.input();
        std.debug.assert(source_generation != 0);
        self.consumeInstallPreparation(input);
        redaction.apply(self.execution.credential());
        redaction.apply(input.api_key);
        if (self.custom_binding) |*binding| binding.deinit();
        self.custom_binding = null;
        self.execution.installNoFail(execution);
        self.metask_source_binding_generation = source_generation;
        self.default_selection_revision = 0;
    }

    pub fn installModelConnectionNoFail(
        self: *State,
        execution: *models_contract.OwnedConfig,
        prepared_binding: *PreparedModelConnectionBinding,
        redaction: ProjectionRedaction,
    ) void {
        std.debug.assert(self.replacement != .none);
        self.consumeInstallPreparation(execution.input());
        redaction.apply(self.execution.credential());
        redaction.apply(execution.input().api_key);
        self.execution.installNoFail(execution);
        self.metask_source_binding_generation = 0;
        self.default_selection_revision = 0;
        if (self.custom_binding) |*previous| previous.deinit();
        self.custom_binding = prepared_binding.*;
        prepared_binding.* = undefined;
    }

    pub fn installAutomationNoFail(
        self: *State,
        input: AutomationInput,
        redaction: ProjectionRedaction,
    ) void {
        const execution_input: models_contract.ConfigInput = .{
            .target = .{
                .provider_id = "metask:automation-key",
                .protocol = input.protocol,
                .model = input.model,
                .base_url = input.base_url,
            },
            .api_key = input.credential,
            .execution_generation = input.generation,
        };
        self.consumeInstallPreparation(execution_input);
        redaction.apply(self.execution.credential());
        redaction.apply(input.credential);
        if (self.custom_binding) |*binding| binding.deinit();
        self.custom_binding = null;
        self.execution.installBytesNoFail(execution_input);
        self.metask_source_binding_generation = 0;
        self.default_selection_revision = 0;
    }

    pub fn clearNoFail(self: *State, redaction: ProjectionRedaction) void {
        std.debug.assert(self.replacement != .none);
        self.consumeClearPreparation(self.execution.generation);
        redaction.apply(self.execution.credential());
        self.execution.clearNoFail();
        self.metask_source_binding_generation = 0;
        self.default_selection_revision = 0;
        if (self.custom_binding) |*binding| binding.deinit();
        self.custom_binding = null;
    }

    fn consumeInstallPreparation(self: *State, input: models_contract.ConfigInput) void {
        switch (self.redaction_preparation) {
            .install => |prepared| {
                std.debug.assert(prepared.generation == input.execution_generation);
                std.debug.assert(prepared.credential_len == input.api_key.len);
                std.debug.assert(prepared.credential_ptr == input.api_key.ptr);
            },
            else => unreachable,
        }
        self.redaction_preparation = .none;
    }

    fn consumeClearPreparation(self: *State, execution_generation: u64) void {
        switch (self.redaction_preparation) {
            .clear => |prepared| std.debug.assert(prepared == execution_generation),
            else => unreachable,
        }
        self.redaction_preparation = .none;
    }

    pub fn metaskExecutionActive(self: *const State) bool {
        return self.custom_binding == null and self.execution.ready();
    }

    pub fn canCreateTask(
        self: *const State,
        owner_available: bool,
        metask_authority_current: bool,
    ) bool {
        return owner_available and self.replacement == .none and self.execution.ready() and
            if (self.custom_binding != null)
                true
            else
                metask_authority_current;
    }

    pub fn availability(self: *const State) models_contract.Availability {
        if (self.replacement != .none) return .replacing;
        return if (self.execution.ready()) .ready else .unavailable;
    }

    pub fn availabilityError(self: *const State) models_contract.AvailabilityError {
        return self.availability_error;
    }

    pub fn rejectReplacementNoFail(
        self: *State,
        error_code: models_contract.AvailabilityError,
    ) void {
        std.debug.assert(error_code != .none);
        std.debug.assert(self.replacement != .none);
        self.redaction_preparation = .none;
        self.availability_error = error_code;
    }

    pub fn recordAvailabilityErrorNoFail(
        self: *State,
        error_code: models_contract.AvailabilityError,
    ) void {
        std.debug.assert(error_code != .none);
        self.availability_error = error_code;
    }

    pub fn abortReplacementPreparationNoFail(self: *State) void {
        std.debug.assert(self.replacement != .none);
        self.redaction_preparation = .none;
    }

    pub fn taskModelSelectionBaseAuthorized(
        self: *const State,
        identity: ExecutionIdentity,
    ) bool {
        return self.replacement == .none and
            self.custom_binding == null and
            self.execution.ready() and
            identity.generation == self.execution.generation and
            identity.protocol == self.execution.protocol.?;
    }

    pub fn supportsTaskExecution(
        self: *const State,
        expected_protocol: models_contract.Protocol,
        model_id: []const u8,
        metask_authority_current: bool,
        metask_model_available: bool,
    ) bool {
        return self.replacement == .none and self.execution.ready() and
            expected_protocol == self.execution.protocol.? and
            if (self.custom_binding) |binding|
                std.mem.eql(u8, binding.model_id, self.execution.model()) and
                    std.mem.eql(u8, model_id, binding.model_id)
            else
                metask_authority_current and metask_model_available;
    }

    pub fn recoveryAuthorityExact(
        self: *const State,
        execution_generation: u64,
        expected_protocol: models_contract.Protocol,
        model_id: []const u8,
        metask_authority_current: bool,
        metask_model_available: bool,
    ) bool {
        return execution_generation == self.execution.generation and
            self.supportsTaskExecution(
                expected_protocol,
                model_id,
                metask_authority_current,
                metask_model_available,
            );
    }

    pub fn validExecutionGeneration(
        self: *const State,
        execution_generation: u64,
        metask_authority_current: bool,
    ) bool {
        return execution_generation != 0 and execution_generation == self.execution.generation and
            (self.custom_binding != null or metask_authority_current);
    }

    pub fn executionInput(self: *const State) ?models_contract.ConfigInput {
        if (!self.execution.ready()) return null;
        return .{
            .target = .{
                .provider_id = self.execution.providerId(),
                .protocol = self.execution.protocol.?,
                .model = self.execution.model(),
                .base_url = self.execution.baseUrl(),
            },
            .api_key = self.execution.credential(),
            .execution_generation = self.execution.generation,
        };
    }

    pub fn credential(self: *const State) []const u8 {
        return self.execution.credential();
    }
    pub fn generation(self: *const State) u64 {
        return self.execution.generation;
    }
    pub fn protocol(self: *const State) ?models_contract.Protocol {
        return self.execution.protocol;
    }
    pub fn model(self: *const State) []const u8 {
        return self.execution.model();
    }
    pub fn metaskBindingMatches(self: *const State, source_generation: u64) bool {
        return self.custom_binding == null and
            source_generation != 0 and
            self.metask_source_binding_generation == source_generation;
    }

    /// Records the exact Models desired identity after an installation has
    /// consumed its owned credential. This is Product Control's process-local
    /// equality authority; it is never persisted by Models.
    pub fn recordDefaultAuthorityNoFail(
        self: *State,
        authority: models_contract.DefaultSelectionAuthority,
    ) void {
        std.debug.assert(self.execution.ready());
        std.debug.assert(authority.source_generation != 0);
        std.debug.assert(authority.selection_revision != 0);
        std.debug.assert(authority.protocol == self.execution.protocol.?);
        std.debug.assert(std.mem.eql(u8, authority.selection.model_id, self.execution.model()));
        switch (authority.source) {
            .metask => {
                std.debug.assert(self.custom_binding == null);
                std.debug.assert(self.metask_source_binding_generation == authority.source_generation);
                std.debug.assert(std.mem.eql(
                    u8,
                    authority.selection.source_id,
                    self.execution.providerId(),
                ));
            },
            .model_connection => {
                const binding = self.custom_binding orelse unreachable;
                std.debug.assert(std.mem.eql(
                    u8,
                    authority.selection.source_id,
                    binding.connection_id,
                ));
            },
        }
        self.default_selection_revision = authority.selection_revision;
    }

    pub fn defaultAuthorityMatches(
        self: *const State,
        authority: models_contract.DefaultSelectionAuthority,
    ) bool {
        if (!self.execution.ready() or
            self.replacement != .none or
            self.default_selection_revision != authority.selection_revision or
            self.execution.protocol.? != authority.protocol or
            !std.mem.eql(u8, self.execution.model(), authority.selection.model_id))
            return false;
        return switch (authority.source) {
            .metask => self.custom_binding == null and
                self.metask_source_binding_generation == authority.source_generation and
                std.mem.eql(
                    u8,
                    self.execution.providerId(),
                    authority.selection.source_id,
                ),
            .model_connection => if (self.custom_binding) |binding|
                std.mem.eql(u8, binding.connection_id, authority.selection.source_id)
            else
                false,
        };
    }
    pub fn hasRecordedDefaultAuthority(self: *const State) bool {
        return self.default_selection_revision != 0;
    }
    pub fn ready(self: *const State) bool {
        return self.execution.ready();
    }
    pub fn replacementPending(self: *const State) bool {
        return self.replacement != .none;
    }
    pub fn identityReplacementPending(self: *const State) bool {
        return self.replacement == .identity;
    }
    pub fn defaultReplacementPending(self: *const State) bool {
        return self.replacement == .default;
    }
    pub fn modelConnectionActive(self: *const State, connection_id: []const u8) bool {
        const binding = self.custom_binding orelse return false;
        return std.mem.eql(u8, binding.connection_id, connection_id);
    }
    pub fn modelConnectionSelected(self: *const State) bool {
        return self.custom_binding != null;
    }

    pub fn activeSource(self: *const State) ?models_contract.Source {
        if (!self.execution.ready()) return null;
        return if (self.custom_binding == null) .metask else .model_connection;
    }

    pub fn selectedModelConnectionId(self: *const State) []const u8 {
        return if (self.custom_binding) |binding| binding.connection_id else "";
    }
};

pub const testing = if (builtin.is_test) struct {
    pub fn clearExecutionNoFail(state: *State) void {
        state.execution.clearNoFail();
    }

    pub fn setGeneration(state: *State, generation: u64) void {
        state.execution.generation = generation;
    }

    pub fn setCredentialBytes(state: *State, credential: []const u8) void {
        std.debug.assert(credential.len <= state.execution.credential_storage.len);
        std.crypto.secureZero(u8, state.execution.credential_storage);
        @memcpy(state.execution.credential_storage[0..credential.len], credential);
        state.execution.credential_len = credential.len;
    }

    pub fn installModelConnectionBinding(
        state: *State,
        binding: *PreparedModelConnectionBinding,
    ) void {
        std.debug.assert(state.custom_binding == null);
        state.custom_binding = binding.*;
        binding.* = undefined;
    }
} else struct {};

const TestDurableRedaction = struct {
    calls: *usize,

    fn apply(self: TestDurableRedaction, credential: []const u8) !void {
        _ = credential;
        self.calls.* += 1;
    }
};

const TestProjectionRedaction = struct {
    calls: usize = 0,

    fn capability(self: *TestProjectionRedaction) ProjectionRedaction {
        return .{
            .context = self,
            .apply_fn = apply,
        };
    }

    fn apply(context: *anyopaque, credential: []const u8) void {
        _ = credential;
        const self: *TestProjectionRedaction = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
};

fn secureFreeTest(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    std.testing.allocator.free(bytes);
}

fn testExecution(
    protocol: models_contract.Protocol,
    model: []const u8,
    generation: u64,
    credential: []const u8,
) !models_contract.OwnedConfig {
    const owned_model = try std.testing.allocator.dupe(u8, model);
    errdefer std.testing.allocator.free(owned_model);
    const owned_base_url = try std.testing.allocator.dupe(
        u8,
        "https://api.metask.ai/v1/messages",
    );
    errdefer std.testing.allocator.free(owned_base_url);
    const owned_credential = try std.testing.allocator.dupe(u8, credential);
    errdefer secureFreeTest(owned_credential);
    return models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .metask,
        protocol,
        owned_model,
        owned_base_url,
        generation,
        owned_credential,
        "fixture-provider",
    ) catch unreachable;
}

fn testModelConnectionExecution() !models_contract.OwnedConfig {
    const owned_model = try std.testing.allocator.dupe(u8, "gpt-5");
    errdefer std.testing.allocator.free(owned_model);
    const owned_base_url = try std.testing.allocator.dupe(
        u8,
        "https://api.openai.com/v1/chat/completions",
    );
    errdefer std.testing.allocator.free(owned_base_url);
    const owned_credential = try std.testing.allocator.dupe(u8, "SECRET-TWO");
    errdefer secureFreeTest(owned_credential);
    return models_contract.OwnedConfig.initOwned(
        std.testing.allocator,
        .model_connection,
        .openai_chat_completions,
        owned_model,
        owned_base_url,
        3,
        owned_credential,
        "fixture-provider",
    ) catch unreachable;
}

test "Metask installation owns only execution and source binding" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    var execution = try testExecution(.anthropic_messages, "model-old", 7, "SECRET-ONE");
    var execution_owned = true;
    defer if (execution_owned) execution.deinit();
    try state.beginDefaultReplacement();
    var durable_calls: usize = 0;
    try state.prepareInstall(
        execution.input(),
        TestDurableRedaction{ .calls = &durable_calls },
    );
    var projection_redaction: TestProjectionRedaction = .{};
    state.installMetaskNoFail(&execution, 11, projection_redaction.capability());
    execution_owned = false;
    const authority: models_contract.DefaultSelectionAuthority = .{
        .selection = .{
            .source_id = "metask:fixture-provider",
            .model_id = "model-old",
        },
        .source = .metask,
        .source_generation = 11,
        .selection_revision = 13,
        .protocol = .anthropic_messages,
    };
    state.recordDefaultAuthorityNoFail(authority);
    state.endReplacementNoFail();

    try std.testing.expectEqual(@as(usize, 1), durable_calls);
    try std.testing.expectEqual(@as(usize, 2), projection_redaction.calls);
    try std.testing.expect(state.taskModelSelectionBaseAuthorized(.{
        .generation = 7,
        .protocol = .anthropic_messages,
    }));
    try std.testing.expect(!state.taskModelSelectionBaseAuthorized(.{
        .generation = 11,
        .protocol = .anthropic_messages,
    }));
    try std.testing.expect(state.canCreateTask(true, true));
    try std.testing.expect(!state.canCreateTask(true, false));
    try std.testing.expect(state.defaultAuthorityMatches(authority));
    var stale = authority;
    stale.selection_revision = 14;
    try std.testing.expect(!state.defaultAuthorityMatches(stale));
}

test "Model Connection execution never borrows Metask model authority" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    var execution = try testModelConnectionExecution();
    var execution_owned = true;
    defer if (execution_owned) execution.deinit();
    var binding = try PreparedModelConnectionBinding.init(
        std.testing.allocator,
        "connection-1",
        "gpt-5",
    );
    var binding_owned = true;
    defer if (binding_owned) binding.deinit();
    var durable_calls: usize = 0;
    var projection_redaction: TestProjectionRedaction = .{};
    try state.beginDefaultReplacement();
    try state.prepareInstall(
        execution.input(),
        TestDurableRedaction{ .calls = &durable_calls },
    );
    state.installModelConnectionNoFail(
        &execution,
        &binding,
        projection_redaction.capability(),
    );
    execution_owned = false;
    binding_owned = false;
    const authority: models_contract.DefaultSelectionAuthority = .{
        .selection = .{
            .source_id = "connection-1",
            .model_id = "gpt-5",
        },
        .source = .model_connection,
        .source_generation = 19,
        .selection_revision = 23,
        .protocol = .openai_chat_completions,
    };
    state.recordDefaultAuthorityNoFail(authority);
    state.endReplacementNoFail();

    try std.testing.expect(state.modelConnectionSelected());
    try std.testing.expect(state.defaultAuthorityMatches(authority));
    const resolved = state.executionInput().?;
    try std.testing.expectEqualStrings("model_connection:fixture-provider", resolved.target.provider_id);
    try std.testing.expectEqual(models_contract.Protocol.openai_chat_completions, resolved.target.protocol);
    try std.testing.expect(!state.taskModelSelectionBaseAuthorized(.{
        .generation = 3,
        .protocol = .openai_chat_completions,
    }));
    try std.testing.expect(state.canCreateTask(true, false));
}
