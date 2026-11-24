//! The identity one Workspace file has on the Bridge.
//!
//! The Renderer names a file by what it can already see: a Run's file
//! reference, or a path in the Task's Workspace. It never holds an absolute
//! path or a root. Product Control resolves every kind in one place, so
//! preview and the file actions cannot disagree about who may reach a file.

const std = @import("std");

pub const max_path_bytes: usize = 4096;

pub const Target = union(enum) {
    reference: Reference,
    workspace: Workspace,

    pub const Reference = struct { task_id: u64, run_id: u64, id: []const u8 };
    pub const Workspace = struct {
        task_id: u64,
        workspace_id: u64,
        workspace_epoch: u64,
        path: []const u8,

        pub fn clone(self: Workspace, allocator: std.mem.Allocator) std.mem.Allocator.Error!Workspace {
            var copy = self;
            copy.path = try allocator.dupe(u8, self.path);
            return copy;
        }

        pub fn free(self: Workspace, allocator: std.mem.Allocator) void {
            freeText(allocator, self.path);
        }
    };

    pub fn clone(self: Target, allocator: std.mem.Allocator) std.mem.Allocator.Error!Target {
        switch (self) {
            .reference => |value| {
                var copy = value;
                copy.id = try allocator.dupe(u8, value.id);
                return .{ .reference = copy };
            },
            .workspace => |value| return .{ .workspace = try value.clone(allocator) },
        }
    }

    pub fn free(self: Target, allocator: std.mem.Allocator) void {
        switch (self) {
            .reference => |value| freeText(allocator, value.id),
            .workspace => |value| value.free(allocator),
        }
    }
};

/// Where a target points right now. Borrowed: the slices belong to Product
/// state, the caller's target, or the caller's scratch.
pub const Location = struct {
    workspace_id: u64,
    workspace_epoch: u64,
    root: []const u8,
    relative: []const u8,
    /// The Host generated this reference's file as a video. A fact of the
    /// record, not of the path.
    generated_video: bool = false,

    pub fn eql(self: Location, other: Location) bool {
        return self.workspace_id == other.workspace_id and
            self.workspace_epoch == other.workspace_epoch and
            self.generated_video == other.generated_video and
            std.mem.eql(u8, self.root, other.root) and
            std.mem.eql(u8, self.relative, other.relative);
    }

    pub fn clone(self: Location, allocator: std.mem.Allocator) std.mem.Allocator.Error!Location {
        var copy = self;
        copy.root = try allocator.dupe(u8, self.root);
        errdefer allocator.free(copy.root);
        copy.relative = try allocator.dupe(u8, self.relative);
        return copy;
    }

    pub fn free(self: Location, allocator: std.mem.Allocator) void {
        freeText(allocator, self.relative);
        freeText(allocator, self.root);
    }
};

/// Why a target does not resolve. Nothing here says more than the Renderer may
/// learn about a file it named itself.
pub const Error = error{
    ShuttingDown,
    StaleSecurityEpoch,
    UnknownFile,
    RestrictedFile,
    UnsupportedFile,
};

fn freeText(allocator: std.mem.Allocator, text: []const u8) void {
    const owned: []u8 = @constCast(text);
    std.crypto.secureZero(u8, owned);
    allocator.free(owned);
}

test "a file target and its location are copied whole and released on every failed allocation" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            for ([_]Target{
                .{ .reference = .{ .task_id = 3, .run_id = 7, .id = "file-3-1-1-1" } },
                .{ .workspace = .{ .task_id = 3, .workspace_id = 2, .workspace_epoch = 1, .path = "docs/中文.md" } },
            }) |target| {
                const copy = try target.clone(allocator);
                defer copy.free(allocator);
                try std.testing.expectEqualDeep(target, copy);
            }
            const location: Location = .{ .workspace_id = 2, .workspace_epoch = 1, .root = "/workspace", .relative = "docs/中文.md" };
            const copy = try location.clone(allocator);
            defer copy.free(allocator);
            try std.testing.expect(copy.eql(location));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "a file location differs when any of its facts differs" {
    const location: Location = .{ .workspace_id = 2, .workspace_epoch = 1, .root = "/workspace", .relative = "a.mp4", .generated_video = true };
    inline for (.{
        .{ "workspace_id", @as(u64, 3) },
        .{ "workspace_epoch", @as(u64, 2) },
        .{ "root", @as([]const u8, "/other") },
        .{ "relative", @as([]const u8, "b.mp4") },
        .{ "generated_video", false },
    }) |change| {
        var other = location;
        @field(other, change[0]) = change[1];
        try std.testing.expect(!location.eql(other));
    }
}
