//! Process-local execution authority owned by one Task attachment.

const std = @import("std");
const models_contract = @import("metawork_product_models_contract");
pub const credential = @import("execution_credential.zig");

pub const OwnedTaskExecution = struct {
    image_capabilities: models_contract.OwnedImageCapabilities = .{},
    allocator: std.mem.Allocator,
    provider_id: []u8,
    protocol: models_contract.Protocol,
    model: []u8,
    base_url: []u8,
    execution_generation: u64,
    source_generation: u64 = 0,
    /// Process-local proof that this attachment installed the committed intent.
    model_intent_revision: u64 = 0,
    secret: []u8,
    credential_generation: u64 = 0,
    credential_source: ?*credential.Source = null,
    retired_credentials: std.ArrayList([]u8) = .empty,
    owned: bool = true,

    pub fn clone(
        allocator: std.mem.Allocator,
        source: models_contract.ConfigInput,
    ) std.mem.Allocator.Error!OwnedTaskExecution {
        std.debug.assert(source.api_key.len != 0);
        var result = try cloneTarget(allocator, source.target, source.execution_generation);
        errdefer result.deinit();
        result.secret = try allocator.dupe(u8, source.api_key);
        return result;
    }

    /// Delayed consumers freeze their target separately from the live reader.
    pub fn cloneTarget(
        allocator: std.mem.Allocator,
        target: models_contract.Target,
        execution_generation: u64,
    ) std.mem.Allocator.Error!OwnedTaskExecution {
        std.debug.assert(target.provider_id.len != 0);
        std.debug.assert(target.model.len != 0);
        std.debug.assert(target.base_url.len != 0);
        std.debug.assert(execution_generation != 0);
        const provider_id = try allocator.dupe(u8, target.provider_id);
        errdefer allocator.free(provider_id);
        const owned_model = try allocator.dupe(u8, target.model);
        errdefer allocator.free(owned_model);
        const owned_base_url = try allocator.dupe(u8, target.base_url);
        errdefer allocator.free(owned_base_url);
        return .{
            .image_capabilities = try .copy(allocator, target.image_capabilities),
            .allocator = allocator,
            .provider_id = provider_id,
            .protocol = target.protocol,
            .model = owned_model,
            .base_url = owned_base_url,
            .execution_generation = execution_generation,
            .secret = &.{},
        };
    }

    pub fn take(self: *OwnedTaskExecution) OwnedTaskExecution {
        std.debug.assert(self.owned);
        const result = self.*;
        self.owned = false;
        self.image_capabilities = .{};
        self.provider_id = &.{};
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.credential_source = null;
        self.retired_credentials = .empty;
        self.execution_generation = 0;
        return result;
    }

    pub fn input(self: *const OwnedTaskExecution) models_contract.ConfigInput {
        std.debug.assert(self.owned);
        return .{
            .target = .{
                .image_capabilities = self.image_capabilities.entries,
                .provider_id = self.provider_id,
                .protocol = self.protocol,
                .model = self.model,
                .base_url = self.base_url,
            },
            .api_key = self.secret,
            .execution_generation = self.execution_generation,
        };
    }

    pub fn modelRef(self: *const OwnedTaskExecution) ?models_contract.ModelRef {
        const source = if (std.mem.eql(u8, self.provider_id, models_contract.metask_source_id))
            models_contract.metask_source_id
        else if (std.mem.startsWith(u8, self.provider_id, "custom_provider:"))
            self.provider_id["custom_provider:".len..]
        else
            return null;
        return .{ .source_id = source, .model_id = self.model };
    }

    pub fn matchesSource(self: *const OwnedTaskExecution, target: models_contract.SourceCandidateInput) bool {
        return self.matchesTarget(target) and self.source_generation != 0 and self.source_generation == target.source_generation and
            std.mem.eql(u8, self.secret, target.api_key);
    }

    pub fn matchesTarget(self: *const OwnedTaskExecution, target: models_contract.SourceCandidateInput) bool {
        return self.owned and models_contract.sameImageCapabilities(self.image_capabilities.entries, target.target.image_capabilities) and
            self.protocol == target.target.protocol and std.mem.eql(u8, self.provider_id, target.target.provider_id) and
            std.mem.eql(u8, self.base_url, target.target.base_url);
    }

    pub fn reader(self: *OwnedTaskExecution, io: std.Io) std.mem.Allocator.Error!*credential.Source {
        if (self.credential_source == null)
            self.credential_source = try credential.Source.create(self.allocator, io, self.secret);
        return self.credential_source.?.retain();
    }

    /// Reserves all allocation before the external Session mutation. The
    /// caller must either install or securely discard the returned bytes.
    pub fn prepareCredential(self: *OwnedTaskExecution, value: []const u8) std.mem.Allocator.Error![]u8 {
        try self.retired_credentials.ensureUnusedCapacity(self.allocator, 1);
        return self.allocator.dupe(u8, value);
    }

    pub fn installCredential(self: *OwnedTaskExecution, value: []u8, generation: u64) void {
        self.retired_credentials.appendAssumeCapacity(self.secret);
        self.secret = value;
        self.credential_generation = generation;
        if (self.credential_source) |source| source.replace(value);
    }

    /// A rejected restore retains only the metadata needed to close its
    /// Session owner. It cannot keep a credential for future execution.
    pub fn clearCredential(self: *OwnedTaskExecution) void {
        std.debug.assert(self.owned);
        std.crypto.secureZero(u8, self.secret);
        self.allocator.free(self.secret);
        self.secret = &.{};
        for (self.retired_credentials.items) |value| {
            std.crypto.secureZero(u8, value);
            self.allocator.free(value);
        }
        self.retired_credentials.deinit(self.allocator);
        self.retired_credentials = .empty;
        if (self.credential_source) |source| source.release();
        self.credential_source = null;
    }

    pub fn deinit(self: *OwnedTaskExecution) void {
        if (!self.owned) return;
        self.image_capabilities.deinit();
        self.clearCredential();
        self.allocator.free(self.base_url);
        self.allocator.free(self.model);
        self.allocator.free(self.provider_id);
        self.owned = false;
        self.provider_id = &.{};
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.execution_generation = 0;
    }
};

test {
    _ = credential;
}
