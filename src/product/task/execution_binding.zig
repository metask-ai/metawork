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
        const model = source.target.model;
        const base_url = source.target.base_url;
        const api_key = source.api_key;
        std.debug.assert(source.target.provider_id.len != 0);
        std.debug.assert(model.len != 0);
        std.debug.assert(base_url.len != 0);
        std.debug.assert(source.execution_generation != 0);
        std.debug.assert(api_key.len != 0);
        const provider_id = try allocator.dupe(u8, source.target.provider_id);
        errdefer allocator.free(provider_id);
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        const owned_base_url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(owned_base_url);
        const owned_secret = try allocator.dupe(u8, api_key);
        errdefer {
            std.crypto.secureZero(u8, owned_secret);
            allocator.free(owned_secret);
        }
        return .{
            .image_capabilities = try .copy(allocator, source.target.image_capabilities),
            .allocator = allocator,
            .provider_id = provider_id,
            .protocol = source.target.protocol,
            .model = owned_model,
            .base_url = owned_base_url,
            .execution_generation = source.execution_generation,
            .secret = owned_secret,
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
