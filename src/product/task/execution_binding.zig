//! Process-local execution authority owned by one Task attachment.

const std = @import("std");
const account_contract = @import("metawork_account_contract");

pub const OwnedTaskExecution = struct {
    allocator: std.mem.Allocator,
    provider_kind: account_contract.ProviderKind,
    model: []u8,
    base_url: []u8,
    execution_generation: u64,
    secret: []u8,
    owned: bool = true,

    pub fn clone(
        allocator: std.mem.Allocator,
        provider_kind: account_contract.ProviderKind,
        model: []const u8,
        base_url: []const u8,
        execution_generation: u64,
        api_key: []const u8,
    ) std.mem.Allocator.Error!OwnedTaskExecution {
        std.debug.assert(model.len != 0);
        std.debug.assert(base_url.len != 0);
        std.debug.assert(execution_generation != 0);
        std.debug.assert(api_key.len != 0);
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
            .provider_kind = provider_kind,
            .model = owned_model,
            .base_url = owned_base_url,
            .execution_generation = execution_generation,
            .secret = owned_secret,
        };
    }

    pub fn take(self: *OwnedTaskExecution) OwnedTaskExecution {
        std.debug.assert(self.owned);
        const result = self.*;
        self.owned = false;
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.execution_generation = 0;
        return result;
    }

    pub fn input(self: *const OwnedTaskExecution) account_contract.ExecutionConfigInput {
        std.debug.assert(self.owned);
        return .{
            .target = .{
                .provider_kind = self.provider_kind,
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
        self.owned = false;
        self.model = &.{};
        self.base_url = &.{};
        self.secret = &.{};
        self.execution_generation = 0;
    }
};
