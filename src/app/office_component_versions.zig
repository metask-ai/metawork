//! Process-local ownership of installed Office resources. Only the Application
//! owner thread changes this registry or performs filesystem cleanup. Catalog,
//! execution and preview references never become Task/Session persistence.
const std = @import("std");
const agent = @import("metawork_agent");
const component = @import("office_component_store.zig");

pub const Version = struct {
    record: component.Record,
    directory: []u8,
    skill_root: []u8,
    references: std.atomic.Value(usize) = .init(1),
    retired: bool = false,

    pub fn lifetime(self: *Version) agent.CatalogSourceLifetime {
        return .{ .context = self, .retain_fn = retain, .release_fn = release };
    }

    /// An execution/preview holds this pin through physical process exit and
    /// output cleanup, including failure. Copying the borrowed path is no pin.
    pub fn pin(self: *Version) error{ComponentVersionUnavailable}!Pin {
        if (!retain(self)) return error.ComponentVersionUnavailable;
        return .{ .version = self };
    }

    fn retain(context: *anyopaque) bool {
        const self: *Version = @ptrCast(@alignCast(context));
        var count = self.references.load(.acquire);
        while (count != 0 and count != std.math.maxInt(usize)) {
            count = self.references.cmpxchgWeak(count, count + 1, .acq_rel, .acquire) orelse return true;
        }
        return false; // final release is irreversible
    }

    fn release(context: *anyopaque) void {
        const self: *Version = @ptrCast(@alignCast(context));
        std.debug.assert(self.references.fetchSub(1, .acq_rel) != 0);
        // No deletion, allocation, Product callback or re-entry here.
    }

    fn retire(self: *Version) void {
        std.debug.assert(!self.retired);
        self.retired = true;
        release(self); // consume the registry's candidate/current reference
    }
};

pub const Pin = struct {
    version: ?*Version,

    pub fn deinit(self: *Pin) void {
        if (self.version) |version| Version.release(version);
        self.version = null;
    }
};

pub const Registry = struct {
    // Bounded Application resource capacity. Busy retired versions consume a
    // slot until collection; admission must reserve a slot before installation.
    pub const capacity = 128;

    allocator: std.mem.Allocator,
    store: *component.Store,
    entries: [capacity]?*Version = @splat(null),
    current: ?*Version = null,

    pub fn hasCapacity(self: *const Registry) bool {
        for (self.entries) |entry| if (entry == null) return true;
        return false;
    }

    /// Caller has already accepted this installed version against the main's
    /// release identity. Merely finding a directory is never installation proof.
    pub fn trackValidated(self: *Registry, record: component.Record) !*Version {
        var slot: ?usize = null;
        for (self.entries, 0..) |entry, index| {
            if (entry) |version| {
                if (version.record.sameDirectory(record)) return error.ComponentVersionAlreadyTracked;
            } else if (slot == null) slot = index;
        }
        const index = slot orelse return error.ComponentVersionLimit;
        const directory = try self.store.versionPath(record);
        errdefer self.allocator.free(directory);
        const skill_root = try std.fs.path.join(self.allocator, &.{ directory, "skills" });
        errdefer self.allocator.free(skill_root);
        const version = try self.allocator.create(Version);
        version.* = .{ .record = record, .directory = directory, .skill_root = skill_root };
        self.entries[index] = version;
        return version;
    }

    /// Call after Product has accepted the root/pin pair. Until then the
    /// candidate and old current each keep their own registry reference.
    pub fn activate(self: *Registry, version: *Version) void {
        std.debug.assert(self.contains(version) and !version.retired);
        if (self.current == version) return;
        if (self.current) |old| old.retire();
        self.current = version;
    }

    /// Product must first switch to the basic Skill source. A pinned Session
    /// may continue to use the old full resources until it releases its lease.
    pub fn useBasic(self: *Registry) void {
        if (self.current) |old| old.retire();
        self.current = null;
    }

    pub fn discardCandidate(self: *Registry, version: *Version) void {
        std.debug.assert(self.contains(version) and self.current != version and !version.retired);
        version.retire();
    }

    pub fn cleanupPending(self: *const Registry) bool {
        for (self.entries) |entry| if (entry) |version| {
            if (version.retired) return true;
        };
        return false;
    }

    /// Owner-thread effect, after zero references; a callback can never race a
    /// zero count back to life. Errors retain the entry for an explicit retry.
    pub fn collect(self: *Registry) !usize {
        var removed: usize = 0;
        for (&self.entries) |*entry| if (entry.*) |version| {
            if (!version.retired or version.references.load(.acquire) != 0) continue;
            try self.store.removeRetired(version.record);
            self.destroy(version);
            entry.* = null;
            removed += 1;
        };
        return removed;
    }

    /// Product/Agent jobs and processes must already have joined. Shutdown only
    /// frees in-memory bookkeeping; it never deletes the installed current.
    pub fn deinit(self: *Registry) !void {
        for (self.entries) |entry| if (entry) |version| {
            const owned: usize = if (version.retired) 0 else 1;
            if (version.references.load(.acquire) != owned) return error.ComponentReferencesOutstanding;
        };
        for (self.entries) |entry| if (entry) |version| self.destroy(version);
        self.* = undefined;
    }

    fn contains(self: *Registry, target: *Version) bool {
        for (self.entries) |entry| if (entry == target) return true;
        return false;
    }

    fn destroy(self: *Registry, version: *Version) void {
        self.allocator.free(version.skill_root);
        self.allocator.free(version.directory);
        self.allocator.destroy(version);
    }
};

fn fixtureVersion(store: *component.Store, identity: u8) !component.Record {
    const record: component.Record = .{ .install_id = @splat(identity), .archive_sha256 = @splat(7) };
    var name: [32]u8 = undefined;
    try store.versions.createDirPath(std.testing.io, record.versionName(&name));
    const directory = try store.versions.openDir(std.testing.io, &name, .{});
    defer directory.close(std.testing.io);
    try directory.createDirPath(std.testing.io, "skills/office-pin");
    try directory.writeFile(std.testing.io, .{ .sub_path = "skills/office-pin/SKILL.md", .data = "---\nname: office-pin\ndescription: Verify installed Office source ownership.\n---\nKeep the version while its catalog is in use.\n" });
    return record;
}

fn fixtureCurrent(store: *component.Store, record: component.Record) !void {
    var buffer: [512]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    const id = std.fmt.bytesToHex(record.install_id, .lower);
    const digest = std.fmt.bytesToHex(record.archive_sha256, .lower);
    try std.json.Stringify.value(.{ .schema = 1, .installId = @as([]const u8, &id), .archiveSha256 = @as([]const u8, &digest) }, .{}, &output);
    try store.directory.writeFile(std.testing.io, .{ .sub_path = "current.json", .data = output.buffered() });
}

test "canonical Session restore capture and execution pin protect the old physical component" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try component.Store.open(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    var registry: Registry = .{ .allocator = std.testing.allocator, .store = &store };
    defer registry.deinit() catch unreachable;
    const first_record = try fixtureVersion(&store, 1);
    const second_record = try fixtureVersion(&store, 2);
    try fixtureCurrent(&store, first_record);
    const first = try registry.trackValidated(first_record);
    const second = try registry.trackValidated(second_record);
    registry.activate(first);
    const first_path = try std.testing.allocator.dupe(u8, first.directory);
    defer std.testing.allocator.free(first_path);
    try temporary.dir.createDirPath(std.testing.io, "home");
    try temporary.dir.createDirPath(std.testing.io, "workspace");
    const home = try temporary.dir.realPathFileAlloc(std.testing.io, "home", std.testing.allocator);
    defer std.testing.allocator.free(home);
    const workspace = try temporary.dir.realPathFileAlloc(std.testing.io, "workspace", std.testing.allocator);
    defer std.testing.allocator.free(workspace);
    const runtime = try agent.Runtime.init(std.testing.io, std.testing.allocator, .{ .max_sessions = 1 });
    defer {
        runtime.shutdown() catch unreachable;
        runtime.deinit();
    }
    var acquisition = try runtime.querySkillCatalog(.{
        .canonical_user_home = home,
        .target = .{ .workspace = .{ .canonical_root = workspace, .epoch = "component-pin" } },
        .additional_sources = &.{.{ .canonical_root = first.skill_root, .scope = .user, .source_instance_id = "metawork.builtin" }},
        .source_lifetime = first.lifetime(),
    });
    defer acquisition.projection.deinit();
    var catalog_owned = true;
    defer if (catalog_owned) runtime.releaseSkillCatalog(acquisition.lease) catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), acquisition.projection.skills.len);
    const session = try runtime.createSession(.{
        .model_binding = .{ .target = .{ .provider_id = "fixture", .protocol = .anthropic_messages, .base_url = "", .model = "fixture" }, .credential = "fixture-not-sent" },
        .permission_mode = .default,
        .shell_policy = .unrestricted,
        .workspace = .{ .canonical_root = workspace, .trust = .explicitly_trusted },
        .canonical_user_home = home,
        .workspace_epoch = "component-pin",
        .skill_catalog = acquisition.lease,
        .skill_policy = .{ .granted_skill_ids = &.{acquisition.projection.skills[0].skill_id} },
    });
    var session_owned = true;
    defer if (session_owned) {
        session.close(.session_close) catch unreachable;
        runtime.releaseClosedSession(session) catch unreachable;
    };
    var captured = try session.captureRestoreInputs();
    var captured_owned = true;
    defer if (captured_owned) captured.deinit() catch unreachable;
    var execution = try first.pin();
    defer execution.deinit();
    try fixtureCurrent(&store, second_record);
    registry.activate(second);
    try std.testing.expect(registry.cleanupPending());
    try std.testing.expectEqual(@as(usize, 0), try registry.collect());
    try runtime.releaseSkillCatalog(acquisition.lease);
    catalog_owned = false;
    try session.close(.session_close);
    try runtime.releaseClosedSession(session);
    session_owned = false;
    try std.testing.expectEqual(@as(usize, 0), try registry.collect());
    try std.testing.expectError(error.CatalogLeasesOutstanding, runtime.shutdown());
    try captured.deinit();
    captured_owned = false;
    try std.testing.expectEqual(@as(usize, 0), try registry.collect());
    execution.deinit();
    try std.testing.expectError(error.CatalogResourceLimit, first.lifetime().retain());
    try std.testing.expectEqual(@as(usize, 1), try registry.collect());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, first_path, .{}));
    try std.testing.expect(!registry.cleanupPending());
    const kept = try std.Io.Dir.cwd().openDir(std.testing.io, second.directory, .{});
    kept.close(std.testing.io);
}

test "retired component cleanup never deletes canonical current and shutdown refuses live pins" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try component.Store.open(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    var registry: Registry = .{ .allocator = std.testing.allocator, .store = &store };
    defer registry.deinit() catch unreachable;
    const record = try fixtureVersion(&store, 3);
    const version = try registry.trackValidated(record);
    var preview = try version.pin();
    defer preview.deinit();
    try std.testing.expectError(error.ComponentReferencesOutstanding, registry.deinit());
    try std.testing.expectError(error.ComponentVersionAlreadyTracked, registry.trackValidated(record));
    registry.activate(version);
    registry.useBasic();
    preview.deinit();
    try fixtureCurrent(&store, record);
    try std.testing.expectError(error.ComponentStillCurrent, registry.collect());
    var inconsistent = record;
    inconsistent.archive_sha256[0] ^= 1;
    try fixtureCurrent(&store, inconsistent);
    try std.testing.expectError(error.ComponentStillCurrent, registry.collect());
    try std.testing.expect(registry.cleanupPending());
    try store.directory.deleteFile(std.testing.io, "current.json");
    try std.testing.expectEqual(@as(usize, 1), try registry.collect());
}

test "concurrent component consumers release without callback cleanup or zero-count resurrection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var store = try component.Store.open(std.testing.allocator, std.testing.io, root);
    defer store.deinit();
    var registry: Registry = .{ .allocator = std.testing.allocator, .store = &store };
    defer registry.deinit() catch unreachable;
    const version = try registry.trackValidated(try fixtureVersion(&store, 4));
    registry.activate(version);
    const Consumer = struct {
        fn run(owned: Pin, gate: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
            var outer = owned;
            defer outer.deinit();
            while (!gate.load(.acquire)) std.atomic.spinLoopHint();
            for (0..1000) |_| {
                var inner = outer.version.?.pin() catch {
                    failed.store(true, .release);
                    return;
                };
                inner.deinit();
            }
        }
    };
    var gate: std.atomic.Value(bool) = .init(false);
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer {
        gate.store(true, .release);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        var owned = try version.pin();
        thread.* = std.Thread.spawn(.{}, Consumer.run, .{ owned, &gate, &failed }) catch |failure| {
            owned.deinit();
            return failure;
        };
        started += 1;
    }
    registry.useBasic();
    try std.testing.expectEqual(@as(usize, 0), try registry.collect());
    gate.store(true, .release);
    var removed: usize = 0;
    for (0..100) |_| removed += try registry.collect();
    for (threads) |thread| thread.join();
    started = 0;
    removed += try registry.collect();
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(!registry.cleanupPending());
}
