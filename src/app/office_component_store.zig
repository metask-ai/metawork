//! Application mechanical Office installation. Product admits one operation;
//! Application holds the product data-root single-instance authority throughout.
//! Current/pending records belong to this component, never Task or Session data.
const std = @import("std");
const builtin = @import("builtin");
const archive = @import("office_component_archive.zig");
const process = @import("office_process");
const platform = @import("office_component_windows");

pub const Release = @import("office_component_contract.zig").Release;
pub const Identity = @import("office_component_contract.zig").Identity;

pub const Phase = @import("product_office_component").Phase;
pub const Progress = struct { phase: Phase, bytes: u64 = 0, total: u64 = 0 };
pub const Observer = struct {
    context: ?*anyopaque = null,
    observe_fn: ?*const fn (?*anyopaque, Progress) bool = null,
    /// Product's atomic admission gate. False rejects publication after cancel;
    /// once true, a committed receipt wins over a later cancellation request.
    activate_fn: ?*const fn (?*anyopaque) bool = null,

    fn update(self: Observer, cancellation: *const process.Cancellation, progress: Progress) !void {
        if (cancellation.requested.load(.acquire)) return error.Cancelled;
        if (self.observe_fn) |observe| if (!observe(self.context, progress)) return error.Cancelled;
    }
};

pub const Download = struct {
    context: ?*anyopaque = null,
    read_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, Release, *std.Io.Writer, *const process.Cancellation) anyerror!void,
};

pub const ValidationResult = enum { ready, rejected, cleanup_incomplete };
pub const Validation = struct {
    context: ?*anyopaque = null,
    parent_environment: ?*const std.process.Environ.Map = null,
    available_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!u64 = available,
    test_fn: ?*const fn (?*anyopaque, std.mem.Allocator, std.Io, Identity, []const u8, []const u8, *const process.Cancellation) ValidationResult = null,

    fn available(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) !u64 {
        return platform.availableBytes(allocator, path);
    }

    fn testComponent(self: Validation, allocator: std.mem.Allocator, io: std.Io, identity: Identity, path: []const u8, scratch: []const u8, cancellation: *const process.Cancellation) ValidationResult {
        if (self.test_fn) |test_fn| return test_fn(self.context, allocator, io, identity, path, scratch, cancellation);
        const environment = self.parent_environment orelse return .rejected;
        verifyRuntime(allocator, io, path, scratch, environment, cancellation) catch |failure| return switch (failure) {
            error.JobTerminationFailed, error.JobObservationFailed, error.JobDidNotSettle => .cleanup_incomplete,
            else => .rejected,
        };
        return .ready;
    }

    fn check(self: Validation, allocator: std.mem.Allocator, io: std.Io, identity: Identity, path: []const u8, scratch: []const u8, cancellation: *const process.Cancellation, preserve: *bool) !void {
        switch (self.testComponent(allocator, io, identity, path, scratch, cancellation)) {
            .ready => {},
            .rejected => return if (cancellation.requested.load(.acquire)) error.Cancelled else error.ComponentValidationFailed,
            .cleanup_incomplete => {
                preserve.* = true;
                return error.ComponentProcessesOutstanding;
            },
        }
    }
};

pub const Record = struct {
    install_id: [16]u8,
    archive_sha256: [32]u8,

    pub fn versionName(self: Record, buffer: *[32]u8) []const u8 {
        // The record already owns the archive digest. Repeating its 64-byte
        // hex spelling in every runtime path can break vendor Windows loaders.
        buffer.* = std.fmt.bytesToHex(self.install_id, .lower);
        return buffer;
    }

    pub fn sameDirectory(self: Record, other: Record) bool {
        return std.mem.eql(u8, &self.install_id, &other.install_id);
    }

    fn eql(self: Record, other: Record) bool {
        return self.sameDirectory(other) and std.mem.eql(u8, &self.archive_sha256, &other.archive_sha256);
    }
};
pub const Receipt = struct { record: Record, cleanup_pending: bool };
pub const Retirements = struct {
    pub const capacity = 128;
    records: [capacity]Record = undefined,
    count: usize = 0,

    pub fn slice(self: *const Retirements) []const Record {
        return self.records[0..self.count];
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: [:0]u8,
    directory: std.Io.Dir,
    stages: std.Io.Dir,
    versions: std.Io.Dir,
    fault: if (builtin.is_test) Fault else void = if (builtin.is_test) .none else {},

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidComponentRoot;
        const directory = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true, .follow_symlinks = false } });
        errdefer directory.close(io);
        const root = try std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator);
        errdefer allocator.free(root);
        const stages = try childDirectory(io, directory, "staging");
        errdefer stages.close(io);
        const versions = try childDirectory(io, directory, "versions");
        return .{ .allocator = allocator, .io = io, .root = root, .directory = directory, .stages = stages, .versions = versions };
    }

    pub fn deinit(self: *Store) void {
        self.versions.close(self.io);
        self.stages.close(self.io);
        self.directory.close(self.io);
        self.allocator.free(self.root);
        self.* = undefined;
    }

    pub fn hasPending(self: *Store) !bool {
        return try self.readRecord("pending.json") != null;
    }

    pub fn current(self: *Store) !?Record {
        return self.readRecord("current.json");
    }

    pub fn versionPath(self: *Store, record: Record) ![]u8 {
        var name: [32]u8 = undefined;
        return std.fs.path.join(self.allocator, &.{ self.root, "versions", record.versionName(&name) });
    }

    /// Component-owned deletion intents, not persisted Session references.
    /// Only exact records are read; version directories are never discovered or
    /// adopted by scanning. Unknown files cannot grant cleanup authority.
    pub fn retirements(self: *Store) !Retirements {
        var result: Retirements = .{};
        var iterator = self.directory.iterate();
        var entries: usize = 0;
        while (try iterator.next(self.io)) |entry| {
            entries += 1;
            if (entries > 1024) return error.ComponentStoreCorrupt;
            if (!std.mem.startsWith(u8, entry.name, "retired-")) continue;
            if (entry.kind != .file or entry.name.len != 45 or !std.mem.endsWith(u8, entry.name, ".json")) return error.ComponentStoreCorrupt;
            const record = try self.readRecord(entry.name) orelse return error.ComponentStoreCorrupt;
            var name: [45]u8 = undefined;
            if (!std.mem.eql(u8, entry.name, retiredName(record, &name))) return error.ComponentStoreCorrupt;
            if (result.count == result.records.len) return error.ComponentRetirementLimit;
            result.records[result.count] = record;
            result.count += 1;
        }
        return result;
    }

    pub fn hasRetired(self: *Store) !bool {
        const active = try self.current();
        const records = try self.retirements();
        for (records.slice()) |record| {
            if (active) |value| if (value.sameDirectory(record)) {
                if (!value.eql(record)) return error.ComponentStoreCorrupt;
                continue;
            };
            return true;
        }
        return false;
    }

    /// Current removal commits before resource reclamation. The durable intent
    /// is written first, so a crash cannot orphan a former current directory.
    /// The caller still owns every live catalog/process pin until source handoff.
    pub fn removeCurrent(self: *Store, record: Record, observer: Observer, cancellation: *const process.Cancellation) !void {
        if (try self.hasPending()) return error.ComponentRecoveryRequired;
        try self.assertCurrent(record);
        try observer.update(cancellation, .{ .phase = .preparing });
        try self.enqueueRetirement(record);
        try observer.update(cancellation, .{ .phase = .activating });
        if (observer.activate_fn) |activate| if (!activate(observer.context)) return error.Cancelled;
        if (builtin.is_test and self.fault == .before_current_delete) return error.ComponentWriteFailed;
        self.directory.deleteFile(self.io, "current.json") catch return error.ComponentCommitUnknown;
        if (builtin.is_test and self.fault == .after_current_delete) return error.ComponentCommitUnknown;
        // Readback is about the committed active fact, never a guess based on a
        // failed delete result. An uncertain result is reconciled by a check.
        if (try self.current() != null) return error.ComponentCommitUnknown;
    }

    /// Called only on the single component worker. The owner-thread snapshot
    /// protects all live registry entries, including ones being separately
    /// collected by this operation. Cold cleanup has an empty snapshot only
    /// after acquiring Primary authority and proving process quiescence.
    pub fn cleanupRetired(self: *Store, protected: []const Record, observer: Observer, cancellation: *const process.Cancellation) !bool {
        const records = try self.retirements();
        const active = try self.current();
        for (records.slice()) |record| {
            try observer.update(cancellation, .{ .phase = .cleaning });
            if (active) |value| if (value.sameDirectory(record)) {
                if (!value.eql(record)) return error.ComponentStoreCorrupt;
                // An update/removal cancelled before commit can leave an intent
                // for the still-current version. Remove only the intent.
                var name: [45]u8 = undefined;
                try self.deleteKnownFile(retiredName(record, &name));
                continue;
            };
            var pinned = false;
            for (protected) |value| if (value.sameDirectory(record)) {
                if (!value.eql(record)) return error.ComponentStoreCorrupt;
                pinned = true;
                break;
            };
            if (!pinned) try self.removeRetired(record);
        }
        return self.hasRetired();
    }

    fn enqueueRetirement(self: *Store, record: Record) !void {
        const records = try self.retirements();
        for (records.slice()) |value| if (value.sameDirectory(record)) {
            if (!value.eql(record)) return error.ComponentStoreCorrupt;
            return;
        };
        if (records.count == Retirements.capacity) return error.ComponentRetirementLimit;
        try self.writeRecord("retired", record);
        var name: [45]u8 = undefined;
        try self.directory.renamePreserve("retired.json", self.directory, retiredName(record, &name), self.io);
    }

    /// Only a process-local version owner that has observed zero references may
    /// call this. Current/pending facts still protect publication and recovery.
    pub fn removeRetired(self: *Store, record: Record) !void {
        if (try self.current()) |active| if (active.sameDirectory(record)) return error.ComponentStillCurrent;
        if (try self.readRecord("pending.json")) |pending| if (pending.sameDirectory(record)) return error.ComponentTransactionActive;
        var intent_name: [45]u8 = undefined;
        _ = retiredName(record, &intent_name);
        if (try self.readRecord(&intent_name)) |intent| if (!intent.eql(record)) return error.ComponentStoreCorrupt;
        var name: [32]u8 = undefined;
        try removeDirectory(self.io, self.versions, record.versionName(&name));
        try self.deleteKnownFile(&intent_name);
    }

    /// Explicit recovery after startup/worker quiescence only. It never retries
    /// download, execution or activation. Canonical readback decides ownership.
    pub fn recover(self: *Store) !void {
        const committed = try self.current();
        // Enqueue's fixed temporary record never authorizes deletion. The
        // current pointer cannot change until its named intent was published.
        try self.deleteKnownFile("retired.next");
        try self.deleteKnownFile("retired.json");
        if (try self.readRecord("pending.json")) |pending| {
            if (committed) |value| if (value.sameDirectory(pending) and !value.eql(pending)) return error.ComponentStoreCorrupt;
            const adopted = if (committed) |value| value.eql(pending) else false;
            if (!adopted) {
                var name: [32]u8 = undefined;
                try removeDirectory(self.io, self.versions, pending.versionName(&name));
            }
            const stage = std.fmt.bytesToHex(pending.install_id, .lower);
            try removeDirectory(self.io, self.stages, &stage);
            try self.deleteKnownFile("current.next");
            try self.deleteKnownFile("pending.next");
            try self.deleteKnownFile("pending.json");
        } else {
            // These fixed mechanical temporary files are never active records.
            // Unrecorded staging/version directories are not scanned or adopted.
            try self.deleteKnownFile("pending.next");
            try self.deleteKnownFile("current.next");
        }
    }

    pub fn install(self: *Store, release: Release, source: Download, validation: Validation, observer: Observer, cancellation: *const process.Cancellation) !Receipt {
        try release.validate();
        if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.UnsupportedComponentTarget;
        if (try self.readRecord("pending.json") != null) return error.ComponentRecoveryRequired;
        _ = try self.current(); // corruption cannot be overwritten by installation
        try observer.update(cancellation, .{ .phase = .preparing });
        const reserve: u64 = 64 * 1024 * 1024;
        const space = try validation.available_fn(validation.context, self.allocator, self.root);
        if (space < release.expected.archive_bytes + release.expected.unpacked_bytes + reserve) return error.InsufficientComponentSpace;
        const record = try self.preparePending(release.expected.sha256);
        const stage_name = std.fmt.bytesToHex(record.install_id, .lower);
        const stage_path = try std.fs.path.join(self.allocator, &.{ self.root, "staging", &stage_name });
        defer self.allocator.free(stage_path);
        var stage_owned = false;
        var published = false;
        var preserve = false;
        return self.perform(release, source, validation, observer, cancellation, record, &stage_name, stage_path, &stage_owned, &published, &preserve) catch |failure| {
            if (!preserve) {
                if (stage_owned) try removeDirectory(self.io, self.stages, &stage_name);
                if (published) {
                    var name: [32]u8 = undefined;
                    try removeDirectory(self.io, self.versions, record.versionName(&name));
                }
                try self.deleteKnownFile("current.next");
                try self.deleteKnownFile("pending.json");
            }
            return failure;
        };
    }

    /// Startup/retry validation of the exact canonical record. The manifest pin
    /// comes from the main, including an explicitly retained older identity.
    pub fn verifyCurrent(self: *Store, identity: Identity, record: Record, validation: Validation, observer: Observer, cancellation: *const process.Cancellation) !Receipt {
        try identity.validate();
        if (!std.mem.eql(u8, &identity.expected.sha256, &record.archive_sha256)) return error.ComponentNotAccepted;
        if (try self.readRecord("pending.json") != null) return error.ComponentRecoveryRequired;
        try self.assertCurrent(record);
        try observer.update(cancellation, .{ .phase = .verifying, .total = identity.expected.unpacked_bytes });
        var name: [32]u8 = undefined;
        const root = try self.versions.openDir(self.io, record.versionName(&name), .{ .iterate = true, .follow_symlinks = false });
        defer root.close(self.io);
        const before = try root.stat(self.io);
        var state: ContentsObserver = .{ .observer = observer, .cancellation = cancellation, .expected = identity.expected.unpacked_bytes, .phase = .verifying };
        _ = try archive.verifyInstalled(self.allocator, self.io, root, identity.expected, identity.manifest_sha256, .{}, .{ .context = &state, .observe_fn = ContentsObserver.update });
        try self.assertCurrent(record);
        try observer.update(cancellation, .{ .phase = .testing });
        if (try validation.available_fn(validation.context, self.allocator, self.root) < 64 * 1024 * 1024) return error.InsufficientComponentSpace;
        // This distinct pending identity owns only a check's temporary stage,
        // never the installed target. Existing crash recovery can clean it
        // precisely without rescanning, replaying, or adopting a version.
        const temporary = try self.preparePending(identity.expected.sha256);
        const stage_name = std.fmt.bytesToHex(temporary.install_id, .lower);
        var owned = false;
        var preserve = false;
        const result = self.testCurrent(identity, record, validation, observer, cancellation, &stage_name, &owned, &preserve, before);
        return result catch |failure| {
            if (!preserve) {
                if (owned) try removeDirectory(self.io, self.stages, &stage_name);
                try self.deleteKnownFile("pending.json");
            }
            return failure;
        };
    }

    fn testCurrent(self: *Store, identity: Identity, record: Record, validation: Validation, observer: Observer, cancellation: *const process.Cancellation, stage_name: []const u8, owned: *bool, preserve: *bool, before: std.Io.File.Stat) !Receipt {
        try self.stages.createDir(self.io, stage_name, .default_dir);
        owned.* = true;
        const stage = try self.stages.openDir(self.io, stage_name, .{ .follow_symlinks = false });
        var opened = true;
        defer if (opened) stage.close(self.io);
        try stage.createDir(self.io, "scratch", .default_dir);
        const scratch = try std.fs.path.join(self.allocator, &.{ self.root, "staging", stage_name, "scratch" });
        defer self.allocator.free(scratch);
        const path = try self.versionPath(record);
        defer self.allocator.free(path);
        try validation.check(self.allocator, self.io, identity, path, scratch, cancellation, preserve);
        try observer.update(cancellation, .{ .phase = .cleaning });
        try self.assertCurrent(record);
        var name: [32]u8 = undefined;
        const after = try self.versions.statFile(self.io, record.versionName(&name), .{ .follow_symlinks = false });
        if (after.kind != .directory or after.inode != before.inode) return error.ComponentChanged;
        stage.close(self.io);
        opened = false;
        return .{ .record = record, .cleanup_pending = !self.cleanupCommitted(stage_name) };
    }

    fn assertCurrent(self: *Store, record: Record) !void {
        const current_record = try self.current() orelse return error.ComponentChanged;
        if (!current_record.eql(record)) return error.ComponentChanged;
    }

    fn preparePending(self: *Store, digest: [32]u8) !Record {
        var record: Record = .{ .archive_sha256 = digest, .install_id = undefined };
        try std.Io.randomSecure(self.io, &record.install_id);
        const name = std.fmt.bytesToHex(record.install_id, .lower);
        for ([_]std.Io.Dir{ self.stages, self.versions }) |parent| {
            if (parent.statFile(self.io, &name, .{ .follow_symlinks = false })) |_| return error.ComponentIdentityCollision else |failure| if (failure != error.FileNotFound) return failure;
        }
        try self.writeRecord("pending", record);
        return record;
    }

    fn perform(self: *Store, release: Release, source: Download, validation: Validation, observer: Observer, cancellation: *const process.Cancellation, record: Record, stage_name: []const u8, stage_path: []const u8, stage_owned: *bool, published: *bool, preserve: *bool) !Receipt {
        try self.stages.createDir(self.io, stage_name, .default_dir);
        stage_owned.* = true;
        const stage = try self.stages.openDir(self.io, stage_name, .{ .follow_symlinks = false });
        var stage_open = true;
        defer if (stage_open) stage.close(self.io);
        {
            const file = try stage.createFile(self.io, "archive.tar.gz", .{ .read = true, .exclusive = true });
            defer file.close(self.io);
            var sink: DownloadSink = .{ .file = file, .io = self.io, .limit = release.expected.archive_bytes, .observer = observer, .cancellation = cancellation };
            sink.writer.buffer = &sink.buffer;
            try observer.update(cancellation, .{ .phase = .downloading, .total = release.expected.archive_bytes });
            source.read_fn(source.context, self.allocator, self.io, release, &sink.writer, cancellation) catch |failure| return sink.problem orelse failure;
            sink.writer.flush() catch |failure| return sink.problem orelse failure;
            if (sink.bytes != release.expected.archive_bytes) return error.ComponentDownloadSize;
            if (!std.mem.eql(u8, &sink.digest.finalResult(), &release.expected.sha256)) return error.ComponentDownloadDigest;
            try file.sync(self.io);
            if (try validation.available_fn(validation.context, self.allocator, self.root) < release.expected.unpacked_bytes + 64 * 1024 * 1024)
                return error.InsufficientComponentSpace;
            try observer.update(cancellation, .{ .phase = .unpacking });
            var state: ContentsObserver = .{ .observer = observer, .cancellation = cancellation, .expected = release.expected.unpacked_bytes };
            var buffer: [64 * 1024]u8 = undefined;
            var input = file.reader(self.io, &buffer);
            const summary = try archive.unpack(self.allocator, self.io, &input.interface, stage, "component", release.expected, .{}, .{ .context = &state, .observe_fn = ContentsObserver.update });
            if (!std.mem.eql(u8, &summary.manifest_sha256, &release.manifest_sha256)) return error.ComponentManifestIdentity;
        }
        try observer.update(cancellation, .{ .phase = .verifying });
        try stage.createDir(self.io, "scratch", .default_dir);
        const component = try std.fs.path.join(self.allocator, &.{ stage_path, "component" });
        defer self.allocator.free(component);
        const scratch = try std.fs.path.join(self.allocator, &.{ stage_path, "scratch" });
        defer self.allocator.free(scratch);
        try observer.update(cancellation, .{ .phase = .testing });
        try validation.check(self.allocator, self.io, release.identity(), component, scratch, cancellation, preserve);
        try observer.update(cancellation, .{ .phase = .publishing });
        var name: [32]u8 = undefined;
        try stage.renamePreserve("component", self.versions, record.versionName(&name), self.io);
        published.* = true;
        try observer.update(cancellation, .{ .phase = .finalizing });
        const final_path = try self.versionPath(record);
        defer self.allocator.free(final_path);
        try validation.check(self.allocator, self.io, release.identity(), final_path, scratch, cancellation, preserve);
        try observer.update(cancellation, .{ .phase = .activating });
        if (observer.activate_fn) |activate| if (!activate(observer.context)) return error.Cancelled;
        if (try self.current()) |previous| try self.enqueueRetirement(previous);
        self.writeRecord("current", record) catch |failure| {
            if (failure == error.ComponentCommitUnknown) preserve.* = true;
            return failure;
        };
        // A committed fact survives cancellation. Remaining cleanup is not an
        // activation failure and must not undo the current component receipt.
        if (observer.observe_fn) |observe| _ = observe(observer.context, .{ .phase = .cleaning });
        stage.close(self.io);
        stage_open = false;
        const staging_clean = self.cleanupCommitted(stage_name);
        return .{ .record = record, .cleanup_pending = !staging_clean or (self.hasRetired() catch true) };
    }

    fn cleanupCommitted(self: *Store, stage_name: []const u8) bool {
        removeDirectory(self.io, self.stages, stage_name) catch return false;
        self.deleteKnownFile("pending.json") catch return false;
        return true;
    }

    fn readRecord(self: *Store, path: []const u8) !?Record {
        var file = self.directory.openFile(self.io, path, .{ .follow_symlinks = false, .resolve_beneath = true }) catch |failure| {
            if (failure == error.FileNotFound) return null;
            return error.ComponentStoreCorrupt;
        };
        defer file.close(self.io);
        const status = try file.stat(self.io);
        if (status.kind != .file or status.size == 0 or status.size > 1024) return error.ComponentStoreCorrupt;
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        var buffer: [1024]u8 = undefined;
        const bytes = buffer[0..@intCast(status.size)];
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.ComponentStoreCorrupt;
        const after = try file.stat(self.io);
        if (after.size != status.size or after.mtime.nanoseconds != status.mtime.nanoseconds) return error.ComponentStoreCorrupt;
        const Raw = struct { schema: u32, installId: []const u8, archiveSha256: []const u8 };
        const parsed = std.json.parseFromSlice(Raw, self.allocator, bytes, .{ .max_value_len = 128, .duplicate_field_behavior = .@"error" }) catch return error.ComponentStoreCorrupt;
        defer parsed.deinit();
        if (parsed.value.schema != 1 or parsed.value.installId.len != 32 or parsed.value.archiveSha256.len != 64) return error.ComponentStoreCorrupt;
        for ([_][]const u8{ parsed.value.installId, parsed.value.archiveSha256 }) |hex| {
            for (hex) |character| if (!std.ascii.isDigit(character) and (character < 'a' or character > 'f')) return error.ComponentStoreCorrupt;
        }
        var result: Record = undefined;
        _ = std.fmt.hexToBytes(&result.install_id, parsed.value.installId) catch return error.ComponentStoreCorrupt;
        _ = std.fmt.hexToBytes(&result.archive_sha256, parsed.value.archiveSha256) catch return error.ComponentStoreCorrupt;
        return result;
    }

    fn writeRecord(self: *Store, comptime kind: []const u8, record: Record) !void {
        var buffer: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const id = std.fmt.bytesToHex(record.install_id, .lower);
        const digest = std.fmt.bytesToHex(record.archive_sha256, .lower);
        try std.json.Stringify.value(.{ .schema = @as(u32, 1), .installId = @as([]const u8, &id), .archiveSha256 = @as([]const u8, &digest) }, .{}, &writer);
        const file = try self.directory.createFile(self.io, kind ++ ".next", .{ .exclusive = true, .read = true, .resolve_beneath = true });
        {
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, writer.buffered());
            try file.sync(self.io);
        }
        if (builtin.is_test and std.mem.eql(u8, kind, "current")) if (self.fault == .before_current_rename) return error.ComponentWriteFailed;
        try self.directory.rename(kind ++ ".next", self.directory, kind ++ ".json", self.io);
        if (builtin.is_test and std.mem.eql(u8, kind, "current")) if (self.fault == .after_current_rename) return error.ComponentCommitUnknown;
        const committed = self.directory.openFile(self.io, kind ++ ".json", .{ .mode = .read_write, .follow_symlinks = false }) catch return error.ComponentCommitUnknown;
        defer committed.close(self.io);
        committed.sync(self.io) catch return error.ComponentCommitUnknown;
    }

    fn deleteKnownFile(self: *Store, name: []const u8) !void {
        self.directory.deleteFile(self.io, name) catch |failure| if (failure != error.FileNotFound) return failure;
    }
};

const Fault = enum { none, before_current_rename, after_current_rename, before_current_delete, after_current_delete };

fn retiredName(record: Record, buffer: *[45]u8) []const u8 {
    const id = std.fmt.bytesToHex(record.install_id, .lower);
    @memcpy(buffer[0..8], "retired-");
    @memcpy(buffer[8..40], &id);
    @memcpy(buffer[40..45], ".json");
    return buffer;
}

fn childDirectory(io: std.Io, parent: std.Io.Dir, name: []const u8) !std.Io.Dir {
    parent.createDir(io, name, .default_dir) catch |failure| if (failure != error.PathAlreadyExists) return failure;
    return parent.openDir(io, name, .{ .follow_symlinks = false });
}

fn removeDirectory(io: std.Io, parent: std.Io.Dir, name: []const u8) !void {
    const status = parent.statFile(io, name, .{ .follow_symlinks = false }) catch |failure| {
        if (failure == error.FileNotFound) return;
        return failure;
    };
    if (status.kind != .directory) return error.ComponentStoreCorrupt;
    try parent.deleteTree(io, name);
}

const DownloadSink = struct {
    file: std.Io.File,
    io: std.Io,
    limit: u64,
    bytes: u64 = 0,
    observer: Observer,
    cancellation: *const process.Cancellation,
    problem: ?anyerror = null,
    digest: std.crypto.hash.sha2.Sha256 = .init(.{}),
    buffer: [32 * 1024]u8 = undefined,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *DownloadSink = @alignCast(@fieldParentPtr("writer", writer));
        if (writer.end != 0) {
            self.write(writer.buffered()) catch |failure| {
                self.problem = failure;
                return error.WriteFailed;
            };
            writer.end = 0;
        }
        for (data, 0..) |bytes, index| {
            if (bytes.len == 0 or (index == data.len - 1 and splat == 0)) continue;
            const chunk = bytes[0..@min(bytes.len, 32 * 1024)];
            self.write(chunk) catch |failure| {
                self.problem = failure;
                return error.WriteFailed;
            };
            return chunk.len;
        }
        return 0;
    }

    fn write(self: *DownloadSink, chunk: []const u8) !void {
        try self.observer.update(self.cancellation, .{ .phase = .downloading, .bytes = self.bytes, .total = self.limit });
        if (chunk.len > self.limit -| self.bytes) return error.ComponentDownloadSize;
        try self.file.writeStreamingAll(self.io, chunk);
        self.digest.update(chunk);
        self.bytes += chunk.len;
    }
};

const ContentsObserver = struct {
    observer: Observer,
    cancellation: *const process.Cancellation,
    expected: u64,
    phase: Phase = .unpacking,

    fn update(context: ?*anyopaque, progress: archive.Progress) bool {
        const self: *ContentsObserver = @ptrCast(@alignCast(context.?));
        self.observer.update(self.cancellation, .{ .phase = self.phase, .bytes = progress.unpacked_bytes, .total = self.expected }) catch return false;
        return true;
    }
};

fn verifyRuntime(allocator: std.mem.Allocator, io: std.Io, root: []const u8, scratch: []const u8, environment: *const std.process.Environ.Map, cancellation: *const process.Cancellation) !void {
    for ([_][]const u8{ "bin/office.exe", "python/bin/python.exe", "node/node.exe", "engine/program/soffice.com" }) |relative| {
        if (cancellation.requested.load(.acquire)) return error.Cancelled;
        const path = try std.fs.path.join(allocator, &.{ root, relative });
        defer allocator.free(path);
        try verifyPe(io, path);
        try platform.verifySignature(allocator, path);
    }
    var result = try process.run(allocator, io, root, .selftest, .{ .parent_environment = environment, .scratch_root = scratch }, 120_000, cancellation);
    defer result.deinit(allocator);
    if (result.term != .exited or result.term.exited != 0) return error.ComponentSelftestFailed;
    const Status = struct { schema: u32, status: []const u8, python: []const u8, node: []const u8, font: []const u8 };
    const parsed = try std.json.parseFromSlice(Status, allocator, result.stdout, .{});
    defer parsed.deinit();
    if (parsed.value.schema != 1 or !std.mem.eql(u8, parsed.value.status, "success") or
        parsed.value.python.len == 0 or parsed.value.node.len == 0 or !std.mem.eql(u8, parsed.value.font, "Noto Sans CJK SC")) return error.ComponentSelftestFailed;
}

fn verifyPe(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    if (builtin.os.tag == .windows) file.flags.nonblocking = true;
    var header: [64]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len or !std.mem.eql(u8, header[0..2], "MZ")) return error.InvalidComponentPe;
    const offset = std.mem.readInt(u32, header[60..64], .little);
    if (offset < 64 or offset > 1024 * 1024) return error.InvalidComponentPe;
    var pe: [6]u8 = undefined;
    if (try file.readPositionalAll(io, &pe, offset) != pe.len or !std.mem.eql(u8, pe[0..4], "PE\x00\x00") or
        std.mem.readInt(u16, pe[4..6], .little) != 0x8664) return error.InvalidComponentPe;
}

const Fixture = struct {
    data: []const u8 = @embedFile("office_component_archive_fixtures/valid.tar.gz"),
    space: u64 = 128 * 1024 * 1024,
    validation: ValidationResult = .ready,
    validations: usize = 0,
    reject_on_validation: usize = 0,
    stop_phase: ?Phase = null,
    gate: bool = true,
    cancel_on_gate: ?*process.Cancellation = null,

    fn release() !Release {
        const Metadata = struct { archive_bytes: u64, sha256: []const u8, unpacked_bytes: u64, files: usize, target: []const u8 };
        const raw = try std.json.parseFromSlice(Metadata, std.testing.allocator, @embedFile("office_component_archive_fixtures/valid.json"), .{});
        defer raw.deinit();
        var hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash, raw.value.sha256);
        var manifest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(@embedFile("office_component_archive_fixtures/valid.manifest.json"), &manifest, .{});
        return .{ .url = "https://example.invalid/office.tar.gz", .manifest_sha256 = manifest, .expected = .{
            .sha256 = hash,
            .archive_bytes = raw.value.archive_bytes,
            .unpacked_bytes = raw.value.unpacked_bytes,
            .files = raw.value.files,
            .target = "x86_64-windows-msvc",
        } };
    }

    fn download(self: *Fixture) Download {
        return .{ .context = self, .read_fn = read };
    }
    fn platformValidation(self: *Fixture) Validation {
        return .{ .context = self, .available_fn = available, .test_fn = validate };
    }
    fn observer(self: *Fixture) Observer {
        return .{ .context = self, .observe_fn = progress, .activate_fn = activate };
    }
    fn read(context: ?*anyopaque, _: std.mem.Allocator, io: std.Io, _: Release, writer: *std.Io.Writer, _: *const process.Cancellation) !void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const file = try temporary.dir.createFile(io, "source", .{ .read = true });
        defer file.close(io);
        try file.writeStreamingAll(io, self.data);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        _ = try reader.interface.streamRemaining(writer);
    }
    fn available(context: ?*anyopaque, _: std.mem.Allocator, _: []const u8) !u64 {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        return self.space;
    }
    fn validate(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, _: Identity, path: []const u8, _: []const u8, _: *const process.Cancellation) ValidationResult {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.validations += 1;
        if (self.reject_on_validation == self.validations) return .rejected;
        const root = std.Io.Dir.cwd().openDir(io, path, .{}) catch return .rejected;
        defer root.close(io);
        const bytes = root.readFileAlloc(io, "payload.bin", allocator, .limited(16)) catch return .rejected;
        defer allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, "runtime")) return .rejected;
        return self.validation;
    }
    fn progress(context: ?*anyopaque, value: Progress) bool {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        return self.stop_phase == null or self.stop_phase.? != value.phase;
    }
    fn activate(context: ?*anyopaque) bool {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        if (self.cancel_on_gate) |cancellation| cancellation.requested.store(true, .release);
        return self.gate;
    }
};

fn fixtureStore(temporary: *std.testing.TmpDir) !Store {
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    return Store.open(std.testing.allocator, std.testing.io, root);
}

test "Office installation commits an independent version and current record only after validation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const receipt = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    try std.testing.expect(!receipt.cleanup_pending);
    try std.testing.expectEqual(@as(usize, 2), fixture.validations);
    try std.testing.expect((try store.current()).?.eql(receipt.record));
    try std.testing.expect(try store.readRecord("pending.json") == null);
    const path = try store.versionPath(receipt.record);
    defer std.testing.allocator.free(path);
    const version = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    defer version.close(std.testing.io);
    const bytes = try version.readFileAlloc(std.testing.io, "payload.bin", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("runtime", bytes);
}

test "Office retirement intents survive restart without persisting catalog references or discovering versions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    var opened = true;
    defer if (opened) store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const old = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    const updated = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    try std.testing.expect(updated.cleanup_pending);
    try std.testing.expectEqual(@as(usize, 1), (try store.retirements()).count);
    try store.versions.createDir(std.testing.io, "unregistered", .default_dir);
    try std.testing.expect(try store.cleanupRetired(&.{old.record}, .{}, &cancellation));
    var old_name: [32]u8 = undefined;
    _ = try store.versions.statFile(std.testing.io, old.record.versionName(&old_name), .{});
    store.deinit();
    opened = false;
    store = try fixtureStore(&temporary);
    opened = true;
    try store.recover();
    try std.testing.expect(!try store.cleanupRetired(&.{}, .{}, &cancellation));
    try std.testing.expectError(error.FileNotFound, store.versions.statFile(std.testing.io, &old_name, .{}));
    try std.testing.expect((try store.current()).?.eql(updated.record));
    _ = try store.versions.statFile(std.testing.io, "unregistered", .{});
}

test "Office removal commits a detached current while catalog-held bytes wait for explicit cleanup" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const installed = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    fixture.gate = false;
    try std.testing.expectError(error.Cancelled, store.removeCurrent(installed.record, fixture.observer(), &cancellation));
    try std.testing.expect((try store.current()).?.eql(installed.record));
    try std.testing.expect(!try store.cleanupRetired(&.{}, .{}, &cancellation));
    try std.testing.expectEqual(@as(usize, 0), (try store.retirements()).count);
    fixture.gate = true;
    store.fault = .before_current_delete;
    try std.testing.expectError(error.ComponentWriteFailed, store.removeCurrent(installed.record, fixture.observer(), &cancellation));
    try std.testing.expect((try store.current()).?.eql(installed.record));
    store.fault = .after_current_delete;
    try std.testing.expectError(error.ComponentCommitUnknown, store.removeCurrent(installed.record, fixture.observer(), &cancellation));
    try std.testing.expect(try store.current() == null);
    try std.testing.expect(try store.cleanupRetired(&.{installed.record}, .{}, &cancellation));
    var name: [32]u8 = undefined;
    _ = try store.versions.statFile(std.testing.io, installed.record.versionName(&name), .{});
    try store.recover();
    try std.testing.expect(!try store.cleanupRetired(&.{}, .{}, &cancellation));
    try std.testing.expectError(error.FileNotFound, store.versions.statFile(std.testing.io, &name, .{}));
}

test "Office cleanup rejects conflicting intent identities and preserves current bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const installed = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    var conflict = installed.record;
    conflict.archive_sha256[0] ^= 1;
    try store.enqueueRetirement(conflict);
    try std.testing.expectError(error.ComponentStoreCorrupt, store.hasRetired());
    try std.testing.expectError(error.ComponentStoreCorrupt, store.cleanupRetired(&.{}, .{}, &cancellation));
    try std.testing.expectError(error.ComponentStoreCorrupt, store.removeCurrent(installed.record, .{}, &cancellation));
    try std.testing.expect((try store.current()).?.eql(installed.record));
    var name: [32]u8 = undefined;
    _ = try store.versions.statFile(std.testing.io, installed.record.versionName(&name), .{});
}

test "Office cancel across download unpack validation publication and activation leaves no adopted candidate" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    const cancellation: process.Cancellation = .{};
    for ([_]Phase{ .preparing, .downloading, .unpacking, .verifying, .testing, .publishing, .finalizing, .activating }) |phase| {
        var fixture: Fixture = .{ .stop_phase = phase };
        try std.testing.expectError(error.Cancelled, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
        try std.testing.expect(try store.current() == null);
        try std.testing.expect(try store.readRecord("pending.json") == null);
    }
    var fixture: Fixture = .{ .gate = false };
    try std.testing.expectError(error.Cancelled, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expect(try store.current() == null);
}

test "Office committed installation wins a later cancel and does not roll back current truth" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var cancellation: process.Cancellation = .{};
    var fixture: Fixture = .{ .cancel_on_gate = &cancellation };
    const receipt = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    try std.testing.expect(cancellation.requested.load(.acquire));
    try std.testing.expect((try store.current()).?.eql(receipt.record));
}

test "Office download and manifest identities fail before execution or activation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    var release = try Fixture.release();
    release.expected.sha256[0] ^= 1;
    try std.testing.expectError(error.ComponentDownloadDigest, store.install(release, fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    release = try Fixture.release();
    release.manifest_sha256[0] ^= 1;
    try std.testing.expectError(error.ComponentManifestIdentity, store.install(release, fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    fixture.data = fixture.data[0 .. fixture.data.len - 1];
    try std.testing.expectError(error.ComponentDownloadSize, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    fixture.data = @embedFile("office_component_archive_fixtures/valid.tar.gz") ++ "extra";
    try std.testing.expectError(error.ComponentDownloadSize, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expectEqual(@as(usize, 0), fixture.validations);
    try std.testing.expect(try store.current() == null);
    try std.testing.expect(try store.readRecord("pending.json") == null);
}

test "Office failed update retains old version and current while unknown commit requires canonical recovery" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const old = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    store.fault = .before_current_rename;
    try std.testing.expectError(error.ComponentWriteFailed, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expect((try store.current()).?.eql(old.record));
    store.fault = .after_current_rename;
    try std.testing.expectError(error.ComponentCommitUnknown, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    const adopted = (try store.current()).?;
    try std.testing.expect(!adopted.eql(old.record));
    try std.testing.expect(try store.readRecord("pending.json") != null);
    try std.testing.expectError(error.ComponentRecoveryRequired, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    store.fault = .none;
    try store.recover();
    try std.testing.expect((try store.current()).?.eql(adopted));
    for ([_]Record{ old.record, adopted }) |record| {
        var name: [32]u8 = undefined;
        const version = try store.versions.openDir(std.testing.io, record.versionName(&name), .{});
        version.close(std.testing.io);
    }
    try std.testing.expect(try store.readRecord("pending.json") == null);
}

test "Office uncertain process cleanup preserves its journal until the caller proves quiescence" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{ .validation = .cleanup_incomplete };
    const cancellation: process.Cancellation = .{};
    try std.testing.expectError(error.ComponentProcessesOutstanding, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expect(try store.readRecord("pending.json") != null);
    try std.testing.expect(try store.current() == null);
    try store.recover();
    try std.testing.expect(try store.readRecord("pending.json") == null);
}

test "Office space and validation rejection do not adopt resources, and corrupt records freeze mutation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    const cancellation: process.Cancellation = .{};
    var fixture: Fixture = .{ .space = 1 };
    try std.testing.expectError(error.InsufficientComponentSpace, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    fixture.space = 128 * 1024 * 1024;
    fixture.validation = .rejected;
    try std.testing.expectError(error.ComponentValidationFailed, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expect(try store.readRecord("pending.json") == null);
    fixture.validation = .ready;
    fixture.reject_on_validation = fixture.validations + 2;
    try std.testing.expectError(error.ComponentValidationFailed, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expect(try store.current() == null);
    try std.testing.expect(try store.readRecord("pending.json") == null);
    try store.directory.writeFile(std.testing.io, .{ .sub_path = "current.json", .data = "{broken" });
    try std.testing.expectError(error.ComponentStoreCorrupt, store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expectError(error.ComponentStoreCorrupt, store.recover());
}

test "Office recovery refuses noncanonical record identities instead of cleaning derived paths" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    const raw = "{\"schema\":1,\"installId\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"archiveSha256\":\"" ++ "a" ** 64 ++ "\"}";
    try store.directory.writeFile(std.testing.io, .{ .sub_path = "pending.json", .data = raw });
    try std.testing.expectError(error.ComponentStoreCorrupt, store.recover());
}

test "component recovery rejects conflicting identities for the same current directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const receipt = try store.install(try Fixture.release(), fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    var conflict = receipt.record;
    conflict.archive_sha256[0] ^= 1;
    try store.writeRecord("pending", conflict);
    try std.testing.expectError(error.ComponentStoreCorrupt, store.recover());
    try std.testing.expect((try store.current()).?.eql(receipt.record));
    var name: [32]u8 = undefined;
    const preserved = try store.versions.openDir(std.testing.io, receipt.record.versionName(&name), .{});
    preserved.close(std.testing.io);
    try std.testing.expect(try store.readRecord("pending.json") != null);
}

test "current Office validation uses only main identity and journals private selftest scratch" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try fixtureStore(&temporary);
    defer store.deinit();
    var fixture: Fixture = .{};
    const cancellation: process.Cancellation = .{};
    const release = try Fixture.release();
    const installed = try store.install(release, fixture.download(), fixture.platformValidation(), fixture.observer(), &cancellation);
    const checked = try store.verifyCurrent(release.identity(), installed.record, fixture.platformValidation(), fixture.observer(), &cancellation);
    try std.testing.expect(!checked.cleanup_pending);
    try std.testing.expect(checked.record.eql(installed.record));
    try std.testing.expect((try store.current()).?.eql(installed.record));
    try std.testing.expect(try store.readRecord("pending.json") == null);
    var foreign = release.identity();
    foreign.expected.sha256[0] ^= 1;
    const previous_validations = fixture.validations;
    try std.testing.expectError(error.ComponentNotAccepted, store.verifyCurrent(foreign, installed.record, fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expectEqual(previous_validations, fixture.validations);
    fixture.validation = .cleanup_incomplete;
    try std.testing.expectError(error.ComponentProcessesOutstanding, store.verifyCurrent(release.identity(), installed.record, fixture.platformValidation(), fixture.observer(), &cancellation));
    const pending = (try store.readRecord("pending.json")).?;
    try std.testing.expect(!pending.sameDirectory(installed.record));
    // Recovery is explicitly called after the caller proves quiescence.
    try store.recover();
    try std.testing.expect((try store.current()).?.eql(installed.record));
    try std.testing.expect(try store.readRecord("pending.json") == null);
    fixture.validation = .ready;
    const path = try store.versionPath(installed.record);
    defer std.testing.allocator.free(path);
    const version = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    defer version.close(std.testing.io);
    try version.writeFile(std.testing.io, .{ .sub_path = "payload.bin", .data = "changed" });
    const validations = fixture.validations;
    try std.testing.expectError(error.ComponentManifest, store.verifyCurrent(release.identity(), installed.record, fixture.platformValidation(), fixture.observer(), &cancellation));
    try std.testing.expectEqual(validations, fixture.validations);
    try std.testing.expect(try store.readRecord("pending.json") == null);
}
