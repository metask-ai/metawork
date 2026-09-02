//! Product snapshot composition copy of the canonical, secret-free Account
//! projection. This is not Execution state: it preserves the latest committed
//! Account fact so Product Control can compose the root snapshot and evaluate
//! cross-owner authority at its orchestration boundary.

const std = @import("std");
const account = @import("metawork_account_contract");
const execution_contract = @import("metawork_product_execution_contract");

fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn setNoFail(self: *Self, value: []const u8) void {
            std.debug.assert(value.len <= capacity);
            std.debug.assert(std.unicode.utf8ValidateSlice(value));
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        fn view(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const ApiKeyProjection = struct {
    id: FixedText(account.Limits.api_key_id_bytes) = .{},
    name: FixedText(account.Limits.api_key_name_bytes) = .{},
    suffix: FixedText(account.Limits.api_key_suffix_bytes) = .{},
    protocol: execution_contract.Protocol = .anthropic_messages,
};

const ModelProjection = struct {
    id: FixedText(account.Limits.model_id_bytes) = .{},
    display_name: FixedText(account.Limits.model_display_name_bytes) = .{},
};

pub const Projection = struct {
    allocator: std.mem.Allocator,
    state: account.AccountState = .checking,
    catalog_state: account.CatalogState = .unavailable,
    can_cancel: bool = false,
    account_id: FixedText(account.Limits.account_id_bytes) = .{},
    display_name: FixedText(account.Limits.display_name_bytes) = .{},
    selected_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    selected_model: FixedText(account.Limits.model_id_bytes) = .{},
    candidate_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    candidate_model: FixedText(account.Limits.model_id_bytes) = .{},
    model_catalog_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    authority_account_id: FixedText(account.Limits.account_id_bytes) = .{},
    authority_api_key_id: FixedText(account.Limits.api_key_id_bytes) = .{},
    authority_model_id: FixedText(account.Limits.model_id_bytes) = .{},
    authority_protocol: ?execution_contract.Protocol = null,
    api_keys: []ApiKeyProjection,
    api_key_views: []account.ApiKeyView,
    api_key_count: usize = 0,
    models: []ModelProjection,
    model_views: []account.ModelView,
    model_count: usize = 0,
    error_code: account.ErrorCode = .none,
    catalog_generation: u64 = 0,
    metask_source_generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Projection {
        const api_keys = try allocator.alloc(ApiKeyProjection, account.Limits.api_key_entries);
        errdefer allocator.free(api_keys);
        @memset(api_keys, .{});
        const api_key_views = try allocator.alloc(account.ApiKeyView, account.Limits.api_key_entries);
        errdefer allocator.free(api_key_views);
        const models = try allocator.alloc(ModelProjection, account.Limits.model_entries);
        errdefer allocator.free(models);
        @memset(models, .{});
        const model_views = try allocator.alloc(account.ModelView, account.Limits.model_entries);
        errdefer allocator.free(model_views);
        return .{
            .allocator = allocator,
            .api_keys = api_keys,
            .api_key_views = api_key_views,
            .models = models,
            .model_views = model_views,
        };
    }

    pub fn deinit(self: *Projection) void {
        self.allocator.free(self.model_views);
        self.allocator.free(self.models);
        self.allocator.free(self.api_key_views);
        self.allocator.free(self.api_keys);
        self.* = undefined;
    }

    pub fn commitNoFail(self: *Projection, fact: account.AccountFact) void {
        account.validateFact(fact) catch
            @panic("Account published an invalid AccountFact");
        const source_view = fact.view;
        std.debug.assert(source_view.api_keys.len <= self.api_keys.len);
        std.debug.assert(source_view.models.len <= self.models.len);
        self.state = source_view.state;
        self.catalog_state = source_view.catalog_state;
        self.can_cancel = source_view.can_cancel;
        self.account_id.setNoFail(source_view.account_id);
        self.display_name.setNoFail(source_view.display_name);
        self.selected_api_key_id.setNoFail(source_view.selected_api_key_id);
        self.selected_model.setNoFail(source_view.selected_model);
        self.candidate_api_key_id.setNoFail(source_view.candidate_api_key_id);
        self.candidate_model.setNoFail(source_view.candidate_model);
        self.model_catalog_api_key_id.setNoFail(source_view.model_catalog_api_key_id);
        self.safe_diagnostic.setNoFail(source_view.safe_diagnostic);
        self.api_key_count = source_view.api_keys.len;
        for (
            source_view.api_keys,
            self.api_keys[0..source_view.api_keys.len],
            self.api_key_views[0..source_view.api_keys.len],
        ) |source, *target, *target_view| {
            target.id.setNoFail(source.id);
            target.name.setNoFail(source.name);
            target.suffix.setNoFail(source.suffix);
            target.protocol = source.protocol;
            target_view.* = .{
                .id = target.id.view(),
                .name = target.name.view(),
                .suffix = target.suffix.view(),
                .protocol = target.protocol,
            };
        }
        self.model_count = source_view.models.len;
        for (
            source_view.models,
            self.models[0..source_view.models.len],
            self.model_views[0..source_view.models.len],
        ) |source, *target, *target_view| {
            target.id.setNoFail(source.id);
            target.display_name.setNoFail(source.display_name);
            target_view.* = .{
                .id = target.id.view(),
                .display_name = target.display_name.view(),
                .metadata = source.metadata,
            };
        }
        self.error_code = source_view.error_code;
        self.catalog_generation = source_view.catalog_generation;
        if (fact.authority) |authority| {
            self.authority_account_id.setNoFail(authority.account_id);
            self.authority_api_key_id.setNoFail(authority.api_key_id);
            self.authority_model_id.setNoFail(authority.model_id);
            self.authority_protocol = authority.protocol;
            self.metask_source_generation = authority.source_generation;
        } else {
            self.authority_account_id.setNoFail("");
            self.authority_api_key_id.setNoFail("");
            self.authority_model_id.setNoFail("");
            self.authority_protocol = null;
            self.metask_source_generation = 0;
        }
    }

    pub fn view(self: *const Projection) account.AccountView {
        return .{
            .state = self.state,
            .catalog_state = self.catalog_state,
            .can_cancel = self.can_cancel,
            .account_id = self.account_id.view(),
            .display_name = self.display_name.view(),
            .api_keys = self.api_key_views[0..self.api_key_count],
            .models = self.model_views[0..self.model_count],
            .selected_api_key_id = self.selected_api_key_id.view(),
            .selected_model = self.selected_model.view(),
            .candidate_api_key_id = self.candidate_api_key_id.view(),
            .candidate_model = self.candidate_model.view(),
            .model_catalog_api_key_id = self.model_catalog_api_key_id.view(),
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
            .catalog_generation = self.catalog_generation,
        };
    }

    pub fn metaskReady(self: *const Projection) bool {
        return self.state == .authenticated and
            self.authority_protocol != null and
            self.metask_source_generation != 0;
    }

    pub fn hasModel(self: *const Projection, model: []const u8) bool {
        for (self.model_views[0..self.model_count]) |candidate|
            if (std.mem.eql(u8, candidate.id, model)) return true;
        return false;
    }

    pub fn selectedProtocol(self: *const Projection) ?execution_contract.Protocol {
        for (self.api_key_views[0..self.api_key_count]) |api_key| {
            if (std.mem.eql(u8, api_key.id, self.selected_api_key_id.view()))
                return api_key.protocol;
        }
        return null;
    }

    pub fn accountId(self: *const Projection) []const u8 {
        return self.account_id.view();
    }

    pub fn selectedModel(self: *const Projection) []const u8 {
        return self.selected_model.view();
    }

    pub fn sourceGeneration(self: *const Projection) u64 {
        return self.metask_source_generation;
    }

    pub fn catalogGeneration(self: *const Projection) u64 {
        return self.catalog_generation;
    }

    pub fn bindingCurrent(self: *const Projection, source_generation: u64) bool {
        return self.metaskReady() and
            source_generation != 0 and
            self.metask_source_generation == source_generation;
    }

    pub fn authorityMatches(
        self: *const Projection,
        authority: account.MetaskSourceAuthority,
    ) bool {
        return self.metaskReady() and
            std.mem.eql(u8, self.authority_account_id.view(), authority.account_id) and
            std.mem.eql(u8, self.authority_api_key_id.view(), authority.api_key_id) and
            std.mem.eql(u8, self.authority_model_id.view(), authority.model_id) and
            self.authority_protocol == authority.protocol and
            self.metask_source_generation == authority.source_generation;
    }
};

test "Account projection commit and view allocate nothing after initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var projection = try Projection.init(failing.allocator());
    defer projection.deinit();

    const fact: account.AccountFact = .{
        .kind = .restored,
        .view = .{ .state = .signed_out, .catalog_state = .unavailable },
    };
    const allocations_after_init = failing.alloc_index;
    failing.fail_index = allocations_after_init;
    projection.commitNoFail(fact);
    const first = projection.view();
    try account.validateView(first);
    try std.testing.expectEqual(account.AccountState.signed_out, first.state);
    projection.commitNoFail(fact);
    _ = projection.view();
    try std.testing.expectEqual(allocations_after_init, failing.alloc_index);
}

test "transient catalog refresh preserves the exact committed source authority" {
    var projection = try Projection.init(std.testing.allocator);
    defer projection.deinit();

    const api_keys = [_]account.ApiKeyView{.{
        .id = "key-1",
        .name = "Primary",
        .suffix = "1234",
        .protocol = .anthropic_messages,
    }};
    const authority: account.MetaskSourceAuthority = .{
        .account_id = "account-1",
        .api_key_id = "key-1",
        .model_id = "model-1",
        .protocol = .anthropic_messages,
        .source_generation = 7,
    };
    projection.commitNoFail(.{
        .kind = .catalog_changed,
        .view = .{
            .state = .authenticated,
            .catalog_state = .loading,
            .can_cancel = true,
            .account_id = "account-1",
            .display_name = "Metask User",
            .api_keys = &api_keys,
            .selected_api_key_id = "key-1",
            .selected_model = "model-1",
            .model_catalog_api_key_id = "key-1",
            .catalog_generation = 8,
        },
        .authority = authority,
    });

    try std.testing.expectEqual(account.CatalogState.loading, projection.view().catalog_state);
    try std.testing.expect(projection.authorityMatches(authority));
    try std.testing.expect(projection.bindingCurrent(7));
}
