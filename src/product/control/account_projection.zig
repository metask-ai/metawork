//! Product snapshot composition copy of the canonical, secret-free Account
//! identity projection. Model providers, catalogs, and selections are copied
//! from Models independently.

const std = @import("std");
const account = @import("metawork_account_contract");

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

pub const Projection = struct {
    allocator: std.mem.Allocator,
    state: account.AccountState = .checking,
    can_cancel: bool = false,
    account_id: FixedText(account.Limits.account_id_bytes) = .{},
    display_name: FixedText(account.Limits.display_name_bytes) = .{},
    safe_diagnostic: FixedText(account.Limits.safe_diagnostic_bytes) = .{},
    error_code: account.ErrorCode = .none,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Projection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Projection) void {
        self.* = undefined;
    }

    pub fn commitNoFail(self: *Projection, fact: account.AccountFact) void {
        account.validateFact(fact) catch
            @panic("Account published an invalid AccountFact");
        const source = fact.view;
        self.state = source.state;
        self.can_cancel = source.can_cancel;
        self.account_id.setNoFail(source.account_id);
        self.display_name.setNoFail(source.display_name);
        self.error_code = source.error_code;
        self.safe_diagnostic.setNoFail(source.safe_diagnostic);
    }

    pub fn view(self: *const Projection) account.AccountView {
        return .{
            .state = self.state,
            .can_cancel = self.can_cancel,
            .account_id = self.account_id.view(),
            .display_name = self.display_name.view(),
            .error_code = self.error_code,
            .safe_diagnostic = self.safe_diagnostic.view(),
        };
    }

    pub fn accountId(self: *const Projection) []const u8 {
        return self.account_id.view();
    }
};

test "Account projection copies identity without allocating after initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var projection = try Projection.init(failing.allocator());
    defer projection.deinit();

    const fact: account.AccountFact = .{
        .kind = .restored,
        .view = .{ .state = .signed_out },
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
