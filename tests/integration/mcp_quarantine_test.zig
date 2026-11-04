//! Product recovery exercised through the real Application-owned file capability.
const std = @import("std");
const builtin = @import("builtin");
const configuration = @import("mcp_configuration");
const platform = @import("mcp_platform");
const FileStore = configuration.FileStore;
const file_name = configuration.file_name;
const transaction_file_name = configuration.transaction_file_name;
const schema_version = configuration.schema_version;
const encode = configuration.encode;
const quarantine_directory = configuration.testing.quarantine_directory_name;
const test_limits = configuration.testing.limits;
const lock_file_name = "fixture.lock";

test "quarantine resumes before and after each rename and preserves exact companion bytes" {
    const Probe = struct {
        var base: std.Io = undefined;
        var count: usize = 0;
        var fail_at: usize = 0;
        var after: bool = false;
        fn rename(raw: ?*anyopaque, old: std.Io.Dir, old_name: []const u8, new: std.Io.Dir, new_name: []const u8) std.Io.Dir.RenameError!void {
            count += 1;
            if (count == fail_at and !after) return error.AccessDenied;
            try base.vtable.dirRename(raw, old, old_name, new, new_name);
            if (count == fail_at and after) return error.AccessDenied;
        }
        fn move(io: std.Io, old: std.Io.Dir, new: std.Io.Dir, request: configuration.QuarantineMove.Request) configuration.FileStoreError!void {
            count += 1;
            if (count == fail_at and !after) return error.WriteFailed;
            try platform.quarantineMove().move(io, old, new, request);
            if (count == fail_at and after) return error.WriteFailed;
        }
        fn expectBytes(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
            var file = try dir.openFile(std.testing.io, name, .{ .follow_symlinks = false });
            defer file.close(std.testing.io);
            if (builtin.os.tag == .windows) file.flags.nonblocking = true;
            var bytes: [256]u8 = undefined;
            try std.testing.expectEqual(expected.len, try file.length(std.testing.io));
            const length = try file.readPositionalAll(std.testing.io, bytes[0..expected.len], 0);
            try std.testing.expectEqualStrings(expected, bytes[0..length]);
        }
    };
    const broken = "{ broken registry\r\n exact bytes\x00";
    const journal = "{ companion journal\r\n exact bytes }";
    var empty_storage: [256]u8 = undefined;
    const empty = try encode(&empty_storage, .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &.{} }, test_limits);
    for ([_]bool{ false, true }) |after| {
        for (1..6) |index| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true, .truncate = false });
            defer lock.close(std.testing.io);
            var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = platform.quarantineMove() };
            try store.commit(broken);
            try store.commitTransaction(journal);
            Probe.base = std.testing.io;
            Probe.count = 0;
            Probe.fail_at = index;
            Probe.after = after;
            var vtable = std.testing.io.vtable.*;
            vtable.dirRename = Probe.rename;
            store.quarantine_move = .{ .move_fn = Probe.move };
            store.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
            try std.testing.expectError(error.WriteFailed, store.quarantine(std.testing.allocator, .registry, empty));
            store.io = std.testing.io;
            store.quarantine_move = platform.quarantineMove();
            // Recreate all recovery decisions from disk, with no in-memory phase.
            if (!(try store.resumeQuarantine(std.testing.allocator, empty))) {
                const canonical = (try store.loadAlloc(std.testing.allocator)).?;
                defer std.testing.allocator.free(canonical);
                if (!std.mem.eql(u8, canonical, empty)) try store.quarantine(std.testing.allocator, .registry, empty);
            }
            try Probe.expectBytes(tmp.dir, file_name, empty);
            try std.testing.expectEqual(@as(?[]u8, null), try store.loadTransactionAlloc(std.testing.allocator));
            try std.testing.expect(!(try store.resumeQuarantine(std.testing.allocator, empty)));
            const root = try tmp.dir.openDir(std.testing.io, quarantine_directory, .{ .iterate = true, .follow_symlinks = false });
            defer root.close(std.testing.io);
            var iterator = root.iterate();
            var found = false;
            while (try iterator.next(std.testing.io)) |entry| {
                if (!std.mem.startsWith(u8, entry.name, "finished-")) continue;
                try std.testing.expect(!found);
                found = true;
                const record = try root.openDir(std.testing.io, entry.name, .{ .follow_symlinks = false });
                defer record.close(std.testing.io);
                try Probe.expectBytes(record, file_name, broken);
                try Probe.expectBytes(record, transaction_file_name, journal);
            }
            try std.testing.expect(found);
        }
    }
}

test "quarantine retries a moved journal durability barrier before touching registry" {
    const Probe = struct {
        var base: std.Io = undefined;
        var fail_sync: bool = false;
        var journal_sync: bool = false;
        fn open(raw: ?*anyopaque, dir: std.Io.Dir, name: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const file = try base.vtable.dirOpenFile(raw, dir, name, options);
            if (options.mode == .read_write) journal_sync = std.mem.eql(u8, name, transaction_file_name);
            return file;
        }
        fn move(io: std.Io, old: std.Io.Dir, new: std.Io.Dir, request: configuration.QuarantineMove.Request) configuration.FileStoreError!void {
            try platform.quarantineMove().move(io, old, new, request);
            if (request == .journal) fail_sync = true;
        }
        fn sync(raw: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            if (fail_sync and journal_sync) {
                fail_sync = false;
                return error.InputOutput;
            }
            return base.vtable.fileSync(raw, file);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true, .truncate = false });
    defer lock.close(std.testing.io);
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = platform.quarantineMove() };
    try store.commit("broken");
    try store.commitTransaction("journal");
    var empty_storage: [256]u8 = undefined;
    const empty = try encode(&empty_storage, .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &.{} }, test_limits);
    Probe.base = std.testing.io;
    var vtable = std.testing.io.vtable.*;
    store.quarantine_move = .{ .move_fn = Probe.move };
    vtable.fileSync = Probe.sync;
    vtable.dirOpenFile = Probe.open;
    store.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.PersistenceOutcomeUnknown, store.quarantine(std.testing.allocator, .registry, empty));
    Probe.fail_sync = true;
    try std.testing.expectError(error.PersistenceOutcomeUnknown, store.resumeQuarantine(std.testing.allocator, empty));
    const unchanged = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("broken", unchanged);
    store.io = std.testing.io;
    store.quarantine_move = platform.quarantineMove();
    try std.testing.expect(try store.resumeQuarantine(std.testing.allocator, empty));
}

test "pending quarantine cannot take over replacement canonical files" {
    const Probe = struct {
        var base: std.Io = undefined;
        fn rename(raw: ?*anyopaque, old: std.Io.Dir, old_name: []const u8, new: std.Io.Dir, new_name: []const u8) std.Io.Dir.RenameError!void {
            try base.vtable.dirRename(raw, old, old_name, new, new_name);
            if (std.mem.eql(u8, new_name, "intent")) return error.AccessDenied;
        }
    };
    var empty_storage: [256]u8 = undefined;
    const empty = try encode(&empty_storage, .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &.{} }, test_limits);
    for ([_]bool{ false, true }) |replace_journal| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true, .truncate = false });
        defer lock.close(std.testing.io);
        var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = platform.quarantineMove() };
        try store.commit("original registry");
        try store.commitTransaction("original journal");
        Probe.base = std.testing.io;
        var vtable = std.testing.io.vtable.*;
        vtable.dirRename = Probe.rename;
        store.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
        try std.testing.expectError(error.WriteFailed, store.quarantine(std.testing.allocator, .registry, empty));
        store.io = std.testing.io;
        store.quarantine_move = platform.quarantineMove();
        if (replace_journal) try store.commitTransaction("replacement journal") else try store.commit(empty);
        try std.testing.expectError(error.WriteFailed, store.resumeQuarantine(std.testing.allocator, empty));
        const registry = (try store.loadAlloc(std.testing.allocator)).?;
        defer std.testing.allocator.free(registry);
        const journal = (try store.loadTransactionAlloc(std.testing.allocator)).?;
        defer std.testing.allocator.free(journal);
        try std.testing.expectEqualStrings(if (replace_journal) "original registry" else empty, registry);
        try std.testing.expectEqualStrings(if (replace_journal) "replacement journal" else "original journal", journal);
    }
}

test "quarantine resumes a registry move when no companion journal existed" {
    const Probe = struct {
        var base: std.Io = undefined;
        fn move(io: std.Io, old: std.Io.Dir, new: std.Io.Dir, request: configuration.QuarantineMove.Request) configuration.FileStoreError!void {
            try platform.quarantineMove().move(io, old, new, request);
            if (request == .registry) return error.WriteFailed;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true, .truncate = false });
    defer lock.close(std.testing.io);
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = platform.quarantineMove() };
    try store.commit("broken registry without journal");
    var empty_storage: [256]u8 = undefined;
    const empty = try encode(&empty_storage, .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &.{} }, test_limits);
    Probe.base = std.testing.io;
    var vtable = std.testing.io.vtable.*;
    store.quarantine_move = .{ .move_fn = Probe.move };
    store.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.WriteFailed, store.quarantine(std.testing.allocator, .registry, empty));
    store.io = std.testing.io;
    store.quarantine_move = platform.quarantineMove();
    try std.testing.expect(try store.resumeQuarantine(std.testing.allocator, empty));
    const canonical = (try store.loadAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(empty, canonical);
    try std.testing.expect((try store.loadTransactionAlloc(std.testing.allocator)) == null);
}
fn expectFile(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    const bytes = try dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "MCP quarantine macOS moves preserve occupied files directories and links" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const requests = [_]configuration.QuarantineMove.Request{
        .registry,
        .journal,
        .{ .finish = .{ .scope = .registry, .nonce = @splat(1) } },
        .{ .finish = .{ .scope = .journal, .nonce = @splat(2) } },
    };
    for (requests) |request| {
        for ([_]std.Io.File.Kind{ .file, .directory, .sym_link }) |kind| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = std.testing.io;
            const source = try tmp.dir.createDirPathOpen(io, "source", .{});
            defer source.close(io);
            const target = try tmp.dir.createDirPathOpen(io, "target", .{});
            defer target.close(io);
            var storage: [25]u8 = undefined;
            const from = request.sourceName();
            const to = request.targetName(&storage);
            if (request == .finish) {
                const record = try source.createDirPathOpen(io, from, .{});
                defer record.close(io);
                try record.writeFile(io, .{ .sub_path = "evidence", .data = "original" });
            } else try source.writeFile(io, .{ .sub_path = from, .data = "original" });
            switch (kind) {
                .file => try target.writeFile(io, .{ .sub_path = to, .data = "occupied" }),
                .directory => try target.createDir(io, to, .default_dir),
                .sym_link => try target.symLink(io, "unrelated", to, .{}),
                else => unreachable,
            }
            try std.testing.expectError(error.WriteFailed, platform.quarantineMove().move(io, source, target, request));
            try std.testing.expectEqual(kind, (try target.statFile(io, to, .{ .follow_symlinks = false })).kind);
            switch (kind) {
                .file => try expectFile(target, to, "occupied"),
                .directory => {
                    const occupied = try target.openDir(io, to, .{ .iterate = true });
                    defer occupied.close(io);
                    var iterator = occupied.iterate();
                    try std.testing.expect((try iterator.next(io)) == null);
                },
                .sym_link => {
                    var link: [64]u8 = undefined;
                    try std.testing.expectEqualStrings("unrelated", link[0..try target.readLink(io, to, &link)]);
                },
                else => unreachable,
            }
            if (kind == .directory) try target.deleteDir(io, to) else try target.deleteFile(io, to);
            try platform.quarantineMove().move(io, source, target, request);
            try std.testing.expectError(error.FileNotFound, source.statFile(io, from, .{ .follow_symlinks = false }));
            if (request == .finish) {
                const record = try target.openDir(io, to, .{ .follow_symlinks = false });
                defer record.close(io);
                try expectFile(record, "evidence", "original");
            } else try expectFile(target, to, "original");
        }
    }
}

test "MCP quarantine macOS completion has one concurrent winner" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Context = struct {
        parent: std.Io.Dir,
        request: configuration.QuarantineMove.Request,
        start: *std.atomic.Value(bool),
        succeeded: bool = false,
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            platform.quarantineMove().move(std.testing.io, self.parent, self.parent, self.request) catch return;
            self.succeeded = true;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var start: std.atomic.Value(bool) = .init(false);
    var first: Context = .{ .parent = tmp.dir, .request = .{ .finish = .{ .scope = .registry, .nonce = @splat(3) } }, .start = &start };
    var second: Context = .{ .parent = tmp.dir, .request = .{ .finish = .{ .scope = .journal, .nonce = @splat(3) } }, .start = &start };
    for ([_]*Context{ &first, &second }, [_][]const u8{ "registry", "journal" }) |context, bytes| {
        const record = try tmp.dir.createDirPathOpen(std.testing.io, context.request.sourceName(), .{});
        defer record.close(std.testing.io);
        try record.writeFile(std.testing.io, .{ .sub_path = "evidence", .data = bytes });
    }
    const one = try std.Thread.spawn(.{}, Context.run, .{&first});
    errdefer {
        start.store(true, .release);
        one.join();
    }
    const two = try std.Thread.spawn(.{}, Context.run, .{&second});
    start.store(true, .release);
    one.join();
    two.join();
    try std.testing.expect(first.succeeded != second.succeeded);
    var storage: [25]u8 = undefined;
    const record = try tmp.dir.openDir(std.testing.io, first.request.targetName(&storage), .{});
    defer record.close(std.testing.io);
    try expectFile(record, "evidence", if (first.succeeded) "registry" else "journal");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, (if (first.succeeded) first else second).request.sourceName(), .{}));
    const remaining = try tmp.dir.openDir(std.testing.io, (if (first.succeeded) second else first).request.sourceName(), .{});
    defer remaining.close(std.testing.io);
    try expectFile(remaining, "evidence", if (first.succeeded) "journal" else "registry");
}

test "MCP quarantine without an injected move preserves canonical files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true });
    defer lock.close(std.testing.io);
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock };
    try store.commit("original registry");
    try store.commitTransaction("original journal");
    try std.testing.expectError(error.WriteFailed, store.quarantine(std.testing.allocator, .registry, "empty"));
    try expectFile(tmp.dir, file_name, "original registry");
    try expectFile(tmp.dir, transaction_file_name, "original journal");
    try std.testing.expect(!(try store.hasQuarantine()));
}

test "MCP quarantine completion sync failure retains evidence and reports unknown outcome" {
    const Probe = struct {
        var base: std.Io = undefined;
        var fail_sync: bool = false;
        fn move(io: std.Io, source: std.Io.Dir, target: std.Io.Dir, request: configuration.QuarantineMove.Request) configuration.FileStoreError!void {
            try platform.quarantineMove().move(io, source, target, request);
            if (request == .finish) fail_sync = true;
        }
        fn sync(raw: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            if (fail_sync) return error.InputOutput;
            return base.vtable.fileSync(raw, file);
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = try tmp.dir.createFile(std.testing.io, lock_file_name, .{ .read = true });
    defer lock.close(std.testing.io);
    var store: FileStore = .{ .io = std.testing.io, .dir = tmp.dir, .lock_file = lock, .quarantine_move = .{ .move_fn = Probe.move } };
    try store.commit("original registry");
    try store.commitTransaction("original journal");
    var empty_storage: [256]u8 = undefined;
    const empty = try encode(&empty_storage, .{ .schema_version = schema_version, .generation = 1, .oauth_operation = null, .servers = &.{} }, test_limits);
    Probe.base = std.testing.io;
    Probe.fail_sync = false;
    var vtable = std.testing.io.vtable.*;
    vtable.fileSync = Probe.sync;
    store.io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    try std.testing.expectError(error.PersistenceOutcomeUnknown, store.quarantine(std.testing.allocator, .registry, empty));
    store.io = std.testing.io;
    store.quarantine_move = platform.quarantineMove();
    try std.testing.expect(!(try store.resumeQuarantine(std.testing.allocator, empty)));
    try expectFile(tmp.dir, file_name, empty);
    const root = try tmp.dir.openDir(std.testing.io, quarantine_directory, .{ .iterate = true });
    defer root.close(std.testing.io);
    var iterator = root.iterate();
    const entry = (try iterator.next(std.testing.io)).?;
    try std.testing.expect(std.mem.startsWith(u8, entry.name, "finished-"));
    const record = try root.openDir(std.testing.io, entry.name, .{});
    defer record.close(std.testing.io);
    try expectFile(record, file_name, "original registry");
    try expectFile(record, transaction_file_name, "original journal");
    try std.testing.expect((try iterator.next(std.testing.io)) == null);
}
