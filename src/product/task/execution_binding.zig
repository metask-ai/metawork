//! Process-local execution authority owned by one Task attachment.

const std = @import("std");
const models_contract = @import("metawork_product_models_contract");

pub const OwnedTaskExecution = struct {
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
        self.provider_id = &.{};
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.execution_generation = 0;
        return result;
    }

    pub fn input(self: *const OwnedTaskExecution) models_contract.ConfigInput {
        std.debug.assert(self.owned);
        return .{
            .target = .{
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
        return self.owned and self.source_generation != 0 and self.source_generation == target.source_generation and
            self.protocol == target.target.protocol and std.mem.eql(u8, self.provider_id, target.target.provider_id) and
            std.mem.eql(u8, self.base_url, target.target.base_url) and std.mem.eql(u8, self.secret, target.api_key);
    }

    /// A rejected restore retains only the metadata needed to close its
    /// Session owner. It cannot keep a credential for future execution.
    pub fn clearCredential(self: *OwnedTaskExecution) void {
        std.debug.assert(self.owned);
        std.crypto.secureZero(u8, self.secret);
        self.allocator.free(self.secret);
        self.secret = &.{};
    }

    pub fn deinit(self: *OwnedTaskExecution) void {
        if (!self.owned) return;
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
