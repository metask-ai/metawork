//! Process-local execution authority owned by one Task attachment.

const std = @import("std");
const execution_contract = @import("metawork_product_execution_contract");

pub const OwnedTaskExecution = struct {
    allocator: std.mem.Allocator,
    provider_id: []u8,
    protocol: execution_contract.Protocol,
    model: []u8,
    base_url: []u8,
    execution_generation: u64,
    secret: []u8,
    owned: bool = true,

    pub fn clone(
        allocator: std.mem.Allocator,
        source: execution_contract.ConfigInput,
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

    pub fn input(self: *const OwnedTaskExecution) execution_contract.ConfigInput {
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

    pub fn deinit(self: *OwnedTaskExecution) void {
        if (!self.owned) return;
        std.crypto.secureZero(u8, self.secret);
        self.allocator.free(self.secret);
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
