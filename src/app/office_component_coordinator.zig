//! Application's single bounded Office management worker. Product callbacks are
//! owner-thread-only; the worker borrows only its stable atomic Attempt.
const std = @import("std");
const builtin = @import("builtin");
const ports = @import("metawork_product_control_ports");
const model = @import("product_office_component");
const store_impl = @import("office_component_store.zig");
const releases = @import("office_component_release.zig");
const versions = @import("office_component_versions.zig");
const download = @import("office_component_download.zig");
const process = @import("office_process");
const preview = @import("office_preview.zig");

pub const Notify = struct { context: *anyopaque, notify_fn: *const fn (*anyopaque) void };
const SourceAction = enum { keep, basic, verified };
const Result = struct {
    completion: ports.OfficeCompletion,
    record: ?store_impl.Record = null,
    source: SourceAction = .keep,
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    environment: *const std.process.Environ.Map,
    input: releases.Parsed,
    input_json: []u8,
    basic_root: ?[]const u8,
    notify: Notify,
    store: store_impl.Store = undefined,
    store_opened: bool = false,
    storage_cleanup_pending: bool = false,
    registry: versions.Registry = undefined,
    work: ?*Work = null,
    closing: bool = false,
    testing: if (builtin.is_test) ?struct { source: store_impl.Download, validation: store_impl.Validation } else void = if (builtin.is_test) null else {},

    /// Called after Primary authority is acquired. No filesystem or process
    /// effect runs here, nor on a normal management command's admission path.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, root: []const u8, environment: *const std.process.Environ.Map, input_json: []const u8, basic_root: ?[]const u8, notify: Notify) !*Coordinator {
        if (!std.fs.path.isAbsolute(root)) return error.InvalidComponentRoot;
        if (input_json.len > 16 * 1024) return error.InvalidComponentRelease;
        const owned_input = try allocator.dupe(u8, input_json);
        errdefer allocator.free(owned_input);
        var input = try releases.parse(allocator, owned_input);
        errdefer input.deinit();
        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);
        const self = try allocator.create(Coordinator);
        self.* = .{ .allocator = allocator, .io = io, .root = owned_root, .environment = environment, .input = input, .input_json = owned_input, .basic_root = basic_root, .notify = notify };
        self.registry = .{ .allocator = allocator, .store = &self.store };
        return self;
    }

    pub fn configuration(self: *const Coordinator) !model.Configuration {
        const offered = try self.input.release();
        return .{ .supported = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64, .available = true, .offered = if (offered) |release| .{ .identity = release.expected.sha256, .download_bytes = release.expected.archive_bytes, .installed_bytes = release.expected.unpacked_bytes } else null };
    }

    /// Main-only capture of an already verified current version. IO and
    /// process work start later on the preview lane, never during admission.
    pub fn previewResource(self: *Coordinator, product: ports.OfficeManagement, main_thread: std.Thread.Id, data_root: []const u8, input: preview.Input, operation: [16]u8) !preview.Resource {
        if (std.Thread.getCurrentId() != main_thread) return error.WrongPreviewThread;
        const current = product.view();
        const version = self.registry.current orelse return error.OfficePreviewUnavailable;
        if (self.closing or current.health != .ready or current.current == null or current.current.?.state != .ready or
            version.retired or version.removing or !std.mem.eql(u8, &current.current.?.identity, &version.record.archive_sha256))
            return error.OfficePreviewUnavailable;
        var pin = try version.pin();
        errdefer pin.deinit();
        return preview.Resource.init(self.allocator, self.io, main_thread, self.environment, data_root, .{ .root = version.directory, .identity = version.record.archive_sha256, .context = version, .release_fn = releasePreviewVersion }, input, operation);
    }

    fn releasePreviewVersion(context: *anyopaque) void {
        var pin: versions.Pin = .{ .version = @ptrCast(@alignCast(context)) };
        pin.deinit();
    }

    pub fn begin(self: *Coordinator, product: ports.OfficeManagement, kind: ports.OfficeKind, generation: u64) ports.OfficeAdmission {
        if (self.closing) return .{ .reason = .shutting_down };
        if (self.work != null) return .{ .reason = .busy };
        product.resources(self.registry.hasCapacity(), self.storage_cleanup_pending or self.registry.cleanupPending());
        const admission = product.begin(kind, generation);
        if (!admission.accepted) return admission;
        const id = admission.operation_id.?;
        const before = product.view();
        const work = self.allocator.create(Work) catch {
            _ = product.complete(id, .{ .current = before.current, .health = before.health, .cleanup_pending = before.cleanup_pending, .outcome = .failed, .reason = .resource_limit });
            return admission;
        };
        work.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .root = self.root,
            .store = &self.store,
            .opened = self.store_opened,
            .input = &self.input,
            .attempt = product.attempt(id).?,
            .kind = kind,
            .before = before,
            .notify = self.notify,
            .validation = .{ .parent_environment = self.environment },
            .result = .{ .completion = .{ .current = before.current, .health = before.health, .cleanup_pending = before.cleanup_pending, .outcome = .failed } },
        };
        if (builtin.is_test) if (self.testing) |testing| {
            work.source = testing.source;
            work.validation = testing.validation;
        };
        if (kind == .cleanup) work.collection = self.registry.claimCollection();
        work.thread = std.Thread.spawn(.{}, Work.run, .{work}) catch {
            if (kind == .cleanup) self.registry.finishCollection(&work.collection);
            self.allocator.destroy(work);
            _ = product.complete(id, .{ .current = before.current, .health = before.health, .cleanup_pending = before.cleanup_pending, .outcome = .failed, .reason = .resource_limit });
            return admission;
        };
        self.work = work;
        return admission;
    }

    pub fn cancel(self: *Coordinator, product: ports.OfficeManagement, id: u64) ports.OfficeAdmission {
        const result = product.cancel(id);
        if (result.accepted) if (self.work) |work| {
            if (work.attempt.id == id) work.cancellation.requested.store(true, .release);
        };
        return result;
    }

    /// Main-loop drain; joining happens only after finished was published.
    /// No Product pointer/port enters the worker or its mailbox.
    pub fn drain(self: *Coordinator, product: ports.OfficeManagement) bool {
        const work = self.work orelse {
            const view = product.view();
            if (self.closing or view.health != .ready or view.operation != null or !self.registry.hasCollectible()) return false;
            // Releasing a catalog is not a failed-effect retry. Only newly
            // collectible resources are scheduled on an existing owner wake;
            // explicit failures remain for user retry or restart.
            if (view.terminal) |terminal| if (terminal.outcome == .failed) return false;
            product.resources(self.registry.hasCapacity(), self.storage_cleanup_pending or self.registry.cleanupPending());
            return self.begin(product, .cleanup, product.view().generation).accepted;
        };
        if (work.takeProgress()) |progress| product.progress(work.attempt.id, progress);
        if (!work.finished.load(.acquire)) return false;
        if (!work.joined) {
            work.thread.?.join();
            work.joined = true;
            self.store_opened = work.opened;
        }
        if (!self.closing) switch (work.result.source) {
            .keep => {},
            .basic => {
                _ = product.source(self.basic_root, null) catch |failure| {
                    if (failure == error.CatalogLoading) return false;
                    work.result.completion.health = .restart_required;
                    work.result.completion.reason = .revision_exhausted;
                    work.result.completion.outcome = .failed;
                    work.result.completion.committed = false;
                    return self.finish(product, work);
                };
                self.registry.useBasic();
            },
            .verified => {
                const version = self.registry.trackValidated(work.result.record.?) catch {
                    work.result.completion = .{ .current = work.before.current, .health = .outcome_unknown, .cleanup_pending = true, .outcome = .failed, .reason = .resource_limit };
                    return self.finish(product, work);
                };
                _ = product.source(version.skill_root, version.lifetime()) catch |failure| {
                    if (failure == error.CatalogLoading) return false;
                    work.result.completion = .{ .current = work.before.current, .health = .restart_required, .cleanup_pending = true, .outcome = .failed, .reason = .revision_exhausted };
                    return self.finish(product, work);
                };
                self.registry.activate(version);
            },
        };
        return self.finish(product, work);
    }

    fn finish(self: *Coordinator, product: ports.OfficeManagement, work: *Work) bool {
        if (work.kind == .cleanup) self.registry.finishCollection(&work.collection);
        self.storage_cleanup_pending = work.result.completion.cleanup_pending;
        work.result.completion.cleanup_pending = self.storage_cleanup_pending or self.registry.cleanupPending();
        _ = product.complete(work.attempt.id, work.result.completion);
        product.resources(self.registry.hasCapacity(), work.result.completion.cleanup_pending);
        self.work = null;
        const collect = !self.closing and work.kind != .cleanup and work.result.completion.outcome == .succeeded and work.result.completion.health == .ready and work.result.completion.cleanup_pending;
        self.allocator.destroy(work);
        if (collect) _ = self.begin(product, .cleanup, product.view().generation);
        return true;
    }

    pub fn shutdown(self: *Coordinator, product: ports.OfficeManagement) void {
        self.closing = true;
        if (self.work) |work| {
            work.cancellation.requested.store(true, .release);
            if (!work.joined) {
                work.thread.?.join();
                work.joined = true;
                self.store_opened = work.opened;
            }
            _ = self.finish(product, work);
        }
    }

    /// Product and Agent must already have released catalogs before this call.
    pub fn destroy(self: *Coordinator) !void {
        std.debug.assert(self.work == null);
        try self.registry.deinit();
        if (self.store_opened) self.store.deinit();
        self.input.deinit();
        const allocator = self.allocator;
        allocator.free(self.input_json);
        allocator.free(self.root);
        allocator.destroy(self);
    }
};

const Work = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    store: *store_impl.Store,
    opened: bool,
    input: *const releases.Parsed,
    attempt: *ports.OfficeAttempt,
    kind: ports.OfficeKind,
    before: ports.OfficeView,
    notify: Notify,
    validation: store_impl.Validation,
    source: store_impl.Download = download.source(),
    cancellation: process.Cancellation = .{},
    thread: ?std.Thread = null,
    joined: bool = false,
    finished: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    progress: ?ports.OfficeProgress = null,
    last_phase: ?store_impl.Phase = null,
    last_notice: ?std.Io.Timestamp = null,
    checked_record: ?store_impl.Record = null,
    before_record: ?store_impl.Record = null,
    result: Result,
    collection: versions.Registry.Collection = .{},

    fn run(self: *Work) void {
        self.result = self.execute() catch |failure| self.failed(failure);
        self.finished.store(true, .release);
        self.notify.notify_fn(self.notify.context);
    }

    fn execute(self: *Work) !Result {
        if (self.cancellation.requested.load(.acquire) or self.attempt.cancelRequested()) return error.Cancelled;
        if (!self.opened) {
            self.store.* = try store_impl.Store.open(self.allocator, self.io, self.root);
            self.opened = true;
        }
        try self.store.recover(); // admission excludes unresolved live processes
        try self.store.bindHostScope(try process.hostScope());
        self.before_record = try self.store.current();
        const observer: store_impl.Observer = .{ .context = self, .observe_fn = observe, .activate_fn = activate };
        if (self.kind == .cleanup) {
            for (self.collection.records[0..self.collection.count], 0..) |record, index| {
                if (!observe(self, .{ .phase = .cleaning })) return error.Cancelled;
                if (self.collection.targets[index].scope) |*scope| scope.settle(self.io) catch return error.ComponentProcessesOutstanding;
                self.store.removeRetired(record) catch |failure| {
                    if (failure == error.ComponentStillCurrent) {
                        self.collection.results[index] = .still_current;
                        continue;
                    }
                    return failure;
                };
                self.collection.results[index] = .removed;
            }
            const pending = try self.store.cleanupRetired(self.collection.protected[0..self.collection.protected_count], observer, &self.cancellation, .{ .context = self, .remove_fn = removeCold });
            return .{ .completion = .{ .current = self.before.current, .health = .ready, .cleanup_pending = pending, .outcome = .succeeded } };
        }
        if (self.kind == .remove) {
            const record = self.before_record orelse return error.ComponentChanged;
            try self.store.removeCurrent(record, observer, &self.cancellation);
            return .{ .completion = .{ .current = null, .health = .ready, .cleanup_pending = true, .outcome = .succeeded, .committed = true }, .source = .basic };
        }
        const retired = try self.store.hasRetired();
        if (self.kind == .check) {
            const record = self.before_record orelse return .{ .completion = .{ .current = null, .health = .ready, .cleanup_pending = retired, .outcome = .succeeded }, .source = .basic };
            const identity = (try self.input.accepted(record.archive_sha256)) orelse return .{
                .completion = .{ .current = .{ .identity = record.archive_sha256, .state = .incompatible }, .health = .ready, .cleanup_pending = retired, .outcome = .succeeded },
                .record = record,
                .source = .basic,
            };
            self.checked_record = record;
            const receipt = try self.store.verifyCurrent(identity, record, self.validation, observer, &self.cancellation);
            return .{ .completion = .{ .current = .{ .identity = record.archive_sha256, .state = .ready }, .health = .ready, .cleanup_pending = retired or receipt.cleanup_pending, .outcome = .succeeded }, .record = record, .source = .verified };
        }
        const release = (try self.input.release()) orelse return error.ComponentNotPublished;
        const receipt = try self.store.install(release, self.source, self.validation, observer, &self.cancellation);
        return .{ .completion = .{ .current = .{ .identity = receipt.record.archive_sha256, .state = .ready }, .health = .ready, .cleanup_pending = receipt.cleanup_pending, .outcome = .succeeded, .committed = true }, .record = receipt.record, .source = .verified };
    }

    fn removeCold(context: ?*anyopaque, store: *store_impl.Store, record: store_impl.Record) !void {
        const self: *Work = @ptrCast(@alignCast(context.?));
        var reservation = try process.ResourceScope.reserveVersionDeletion(self.io, record.install_id, &self.cancellation);
        defer reservation.deinit();
        try store.removeRetired(record);
    }

    fn failed(self: *Work, failure: anyerror) Result {
        var result: Result = .{ .completion = .{ .current = self.before.current, .health = self.before.health, .cleanup_pending = self.before.cleanup_pending, .outcome = if (failure == error.Cancelled) .cancelled else .failed, .reason = if (failure == error.Cancelled) null else reason(failure) } };
        if (self.kind == .cleanup and failure != error.Cancelled) result.completion.reason = .cleanup_failed;
        if (failure == error.ComponentProcessesOutstanding) {
            result.completion.health = .restart_required;
            result.completion.cleanup_pending = true;
            return result;
        }
        if (failure == error.ComponentCommitUnknown) {
            result.completion.health = .outcome_unknown;
            result.completion.cleanup_pending = true;
            return result;
        }
        if (self.opened) {
            result.completion.cleanup_pending = (self.store.hasPending() catch true) or (self.store.hasRetired() catch true);
            if (self.checked_record) |record| {
                result.completion.current = .{ .identity = record.archive_sha256, .state = if (isContentsFailure(failure)) .damaged else .unverified };
                result.completion.health = if (isContentsFailure(failure) or failure == error.ComponentValidationFailed) .ready else .read_failed;
                result.source = .basic;
            } else if (failure == error.ComponentStoreCorrupt) {
                result.completion.health = .corrupt;
            } else {
                const current = self.store.current() catch {
                    result.completion.health = .corrupt;
                    return result;
                };
                if (!sameRecord(current, self.before_record)) result.completion.health = .outcome_unknown else result.completion.health = .ready;
            }
        } else result.completion.health = .read_failed;
        return result;
    }

    fn observe(context: ?*anyopaque, progress: store_impl.Progress) bool {
        const self: *Work = @ptrCast(@alignCast(context.?));
        if (self.attempt.cancelRequested()) self.cancellation.requested.store(true, .release);
        if (self.cancellation.requested.load(.acquire)) return false;
        const now: std.Io.Timestamp = .now(self.io, .awake);
        const wake = self.last_phase != progress.phase or self.last_notice == null or self.last_notice.?.durationTo(now).toMilliseconds() >= 100;
        self.mutex.lockUncancelable(self.io);
        self.progress = .{ .phase = progress.phase, .bytes = progress.bytes, .total = progress.total };
        self.mutex.unlock(self.io);
        if (wake) {
            self.last_phase = progress.phase;
            self.last_notice = now;
            self.notify.notify_fn(self.notify.context);
        }
        return true;
    }

    fn activate(context: ?*anyopaque) bool {
        const self: *Work = @ptrCast(@alignCast(context.?));
        return self.attempt.beginActivation();
    }

    fn takeProgress(self: *Work) ?ports.OfficeProgress {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const value = self.progress;
        self.progress = null;
        return value;
    }
};

fn sameRecord(left: ?store_impl.Record, right: ?store_impl.Record) bool {
    if (left) |value| return if (right) |other| value.sameDirectory(other) and std.mem.eql(u8, &value.archive_sha256, &other.archive_sha256) else false;
    return right == null;
}

fn isContentsFailure(failure: anyerror) bool {
    return switch (failure) {
        error.ComponentManifestIdentity, error.ComponentManifest, error.ComponentContents, error.ComponentMember, error.ComponentPath, error.ComponentPathCollision, error.ComponentLink, error.ComponentDebugResource, error.ComponentChanged => true,
        else => false,
    };
}

fn reason(failure: anyerror) ports.OfficeReason {
    if (isContentsFailure(failure)) return .invalid_component;
    return switch (failure) {
        error.InsufficientComponentSpace => .insufficient_space,
        error.ComponentProcessesOutstanding => .process_cleanup_incomplete,
        error.ComponentCommitUnknown => .outcome_unknown,
        error.ComponentValidationFailed, error.ComponentDownloadDigest, error.ComponentManifestIdentity, error.ComponentDownloadSize => .invalid_component,
        error.ComponentNotPublished => .unpublished,
        error.OutOfMemory, error.ComponentRetirementLimit => .resource_limit,
        error.ComponentWriteFailed => .write_failed,
        error.ComponentStoreCorrupt, error.ComponentChanged => .unavailable,
        else => .download_failed,
    };
}

const TestPort = if (builtin.is_test) struct {
    state: model.State,
    source_calls: usize = 0,
    source_blocked: bool = false,
    source_root: [1024]u8 = undefined,
    source_root_len: usize = 0,

    fn port(self: *@This()) ports.OfficeManagement {
        return .{ .context = self, .view_fn = view, .begin_fn = begin, .attempt_fn = attempt, .cancel_fn = cancel, .progress_fn = progress, .complete_fn = complete, .resources_fn = resources, .source_fn = source };
    }
    fn cast(context: *anyopaque) *@This() {
        return @ptrCast(@alignCast(context));
    }
    fn view(context: *anyopaque) ports.OfficeView {
        return cast(context).state.view();
    }
    fn begin(context: *anyopaque, kind: ports.OfficeKind, generation: u64) ports.OfficeAdmission {
        return cast(context).state.begin(kind, generation);
    }
    fn attempt(context: *anyopaque, id: u64) ?*ports.OfficeAttempt {
        const self = cast(context);
        return if (self.state.operation != null and self.state.operation.?.id == id) &self.state.attempt else null;
    }
    fn cancel(context: *anyopaque, id: u64) ports.OfficeAdmission {
        return cast(context).state.cancel(id);
    }
    fn progress(context: *anyopaque, id: u64, value: ports.OfficeProgress) void {
        _ = cast(context).state.progress(id, value);
    }
    fn complete(context: *anyopaque, id: u64, value: ports.OfficeCompletion) bool {
        return cast(context).state.finish(id, value);
    }
    fn resources(context: *anyopaque, capacity: bool, pending: bool) void {
        _ = cast(context).state.setInstallationCapacity(capacity);
        _ = cast(context).state.setCleanupPending(pending);
    }
    fn source(context: *anyopaque, root: ?[]const u8, _: ?@import("metawork_agent").CatalogSourceLifetime) !bool {
        const self = cast(context);
        if (self.source_blocked) return error.CatalogLoading;
        self.source_calls += 1;
        if (root) |value| {
            if (value.len > self.source_root.len) return error.CatalogUnavailable;
            @memcpy(self.source_root[0..value.len], value);
            self.source_root_len = value.len;
        } else self.source_root_len = 0;
        return true;
    }
} else struct {};

const TestEffects = if (builtin.is_test) struct {
    entered: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    reject: std.atomic.Value(bool) = .init(false),
    downloads: std.atomic.Value(usize) = .init(0),

    fn read(context: ?*anyopaque, _: std.mem.Allocator, io: std.Io, _: store_impl.Release, writer: *std.Io.Writer, cancellation: *const process.Cancellation) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        _ = self.downloads.fetchAdd(1, .monotonic);
        self.entered.store(true, .release);
        while (self.blocked.load(.acquire)) {
            if (cancellation.requested.load(.acquire)) return error.Cancelled;
            try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }, io);
        }
        try writer.writeAll(@embedFile("office_component_archive_fixtures/valid.tar.gz"));
    }
    fn available(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) !u64 {
        return 1024 * 1024 * 1024;
    }
    fn validate(context: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: store_impl.ValidationStage, _: store_impl.Identity, _: []const u8, _: []const u8, _: *const process.Cancellation) store_impl.ValidationResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return if (self.reject.load(.acquire)) .rejected else .ready;
    }
    fn notify(_: *anyopaque) void {}
};

const test_input = "{\"schema\":1,\"protocolRevision\":1,\"target\":\"x86_64-windows-msvc\",\"retained\":[],\"release\":{\"url\":\"https://example.invalid/office.tar.gz\",\"archiveSha256\":\"ee27f062faeac5b8cc3a974340fee11b0b40fb65d9c7779df98f3b9c3b4de63a\",\"manifestSha256\":\"601ad3ddad7e6b488b60849c7a8b367316cf569f3061d4b461734289913b115b\",\"archiveBytes\":268,\"unpackedBytes\":186,\"files\":2}}";

fn testDrain(coordinator: *Coordinator, product: ports.OfficeManagement) !void {
    const started: std.Io.Timestamp = .now(std.testing.io, .awake);
    while (coordinator.work != null) {
        _ = coordinator.drain(product);
        if (started.durationTo(.now(std.testing.io, .awake)).toMilliseconds() > 10_000) return error.TestWorkerTimeout;
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }, std.testing.io);
    }
}

test "Office worker publishes only joined verified receipts after owner-thread source handoff" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const store_root = try std.fs.path.join(std.testing.allocator, &.{ root, "office" });
    defer std.testing.allocator.free(store_root);
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var effects: TestEffects = .{};
    const coordinator = try Coordinator.create(std.testing.allocator, std.testing.io, store_root, &environment, test_input, root, .{ .context = &effects, .notify_fn = TestEffects.notify });
    defer coordinator.destroy() catch unreachable;
    coordinator.testing = .{ .source = .{ .context = &effects, .read_fn = TestEffects.read }, .validation = .{ .context = &effects, .available_fn = TestEffects.available, .test_fn = TestEffects.validate } };
    var product: TestPort = .{ .state = model.State.init(try coordinator.configuration()) };
    defer coordinator.shutdown(product.port());
    try std.testing.expect(coordinator.begin(product.port(), .check, product.state.generation).accepted);
    try testDrain(coordinator, product.port());
    try std.testing.expect(product.state.current == null and product.state.view().actions.install);
    try std.testing.expectEqual(@as(usize, 0), effects.downloads.load(.acquire));
    product.source_blocked = true;
    try std.testing.expect(coordinator.begin(product.port(), .install, product.state.generation).accepted);
    const started: std.Io.Timestamp = .now(std.testing.io, .awake);
    while (!coordinator.work.?.finished.load(.acquire)) {
        if (started.durationTo(.now(std.testing.io, .awake)).toMilliseconds() > 10_000) return error.TestWorkerTimeout;
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }, std.testing.io);
    }
    // A committed filesystem receipt is not yet a published usable source.
    try std.testing.expect(!coordinator.drain(product.port()));
    try std.testing.expect(!coordinator.drain(product.port()));
    try std.testing.expect(product.state.current == null);
    product.source_blocked = false;
    try testDrain(coordinator, product.port());
    try std.testing.expectEqual(model.InstalledState.ready, product.state.current.?.state);
    try std.testing.expectEqual(model.Outcome.succeeded, product.state.terminal.?.outcome);
    const installed = (try coordinator.store.current()).?;
    const pointer = coordinator.registry.current.?;
    const references = pointer.references.load(.acquire);
    const preview_input: preview.Input = .{ .root = root, .relative = "not-created.docx", .expected = .{ .size_bytes = 3, .sha256 = @splat(1) } };
    var resource = try coordinator.previewResource(product.port(), std.Thread.getCurrentId(), root, preview_input, @splat(4));
    try std.testing.expectEqual(references + 1, pointer.references.load(.acquire));
    try resource.deinit(); // no IO occurred; the deliberately absent source is not opened
    try std.testing.expectEqual(references, pointer.references.load(.acquire));
    var unsupported = preview_input;
    unsupported.relative = "input.pdf";
    try std.testing.expectError(error.UnsupportedPreview, coordinator.previewResource(product.port(), std.Thread.getCurrentId(), root, unsupported, @splat(4)));
    try std.testing.expectEqual(references, pointer.references.load(.acquire));
    product.state.current.?.identity[0] ^= 1;
    try std.testing.expectError(error.OfficePreviewUnavailable, coordinator.previewResource(product.port(), std.Thread.getCurrentId(), root, preview_input, @splat(4)));
    product.state.current.?.identity[0] ^= 1;
    effects.reject.store(true, .release);
    try std.testing.expect(coordinator.begin(product.port(), .repair, product.state.generation).accepted);
    try testDrain(coordinator, product.port());
    try std.testing.expectEqual(model.Outcome.failed, product.state.terminal.?.outcome);
    try std.testing.expectEqual(model.InstalledState.ready, product.state.current.?.state);
    try std.testing.expect(coordinator.registry.current == pointer);
    try std.testing.expect((try coordinator.store.current()).?.sameDirectory(installed));
}

test "Office cancellation joins a blocked transfer before clearing its exact staging journal" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var effects: TestEffects = .{ .blocked = .init(true) };
    const coordinator = try Coordinator.create(std.testing.allocator, std.testing.io, root, &environment, test_input, null, .{ .context = &effects, .notify_fn = TestEffects.notify });
    defer coordinator.destroy() catch unreachable;
    coordinator.testing = .{ .source = .{ .context = &effects, .read_fn = TestEffects.read }, .validation = .{ .context = &effects, .available_fn = TestEffects.available, .test_fn = TestEffects.validate } };
    var product: TestPort = .{ .state = model.State.init(try coordinator.configuration()) };
    defer coordinator.shutdown(product.port());
    _ = coordinator.begin(product.port(), .check, product.state.generation);
    try testDrain(coordinator, product.port());
    const install = coordinator.begin(product.port(), .install, product.state.generation);
    try std.testing.expect(install.accepted);
    const started: std.Io.Timestamp = .now(std.testing.io, .awake);
    while (!effects.entered.load(.acquire)) {
        if (started.durationTo(.now(std.testing.io, .awake)).toMilliseconds() > 10_000) return error.TestWorkerTimeout;
        try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }, std.testing.io);
    }
    try std.testing.expect(coordinator.cancel(product.port(), install.operation_id.?).accepted);
    try testDrain(coordinator, product.port());
    try std.testing.expectEqual(model.Outcome.cancelled, product.state.terminal.?.outcome);
    try std.testing.expect(try coordinator.store.current() == null);
    try std.testing.expect(!try coordinator.store.hasPending());
}

test "Office update and removal keep catalog-pinned versions until the independent cleanup worker joins" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var effects: TestEffects = .{};
    const coordinator = try Coordinator.create(std.testing.allocator, std.testing.io, root, &environment, test_input, root, .{ .context = &effects, .notify_fn = TestEffects.notify });
    defer coordinator.destroy() catch unreachable;
    coordinator.testing = .{ .source = .{ .context = &effects, .read_fn = TestEffects.read }, .validation = .{ .context = &effects, .available_fn = TestEffects.available, .test_fn = TestEffects.validate } };
    var product: TestPort = .{ .state = model.State.init(try coordinator.configuration()) };
    defer coordinator.shutdown(product.port());
    _ = coordinator.begin(product.port(), .check, product.state.generation);
    try testDrain(coordinator, product.port());
    try std.testing.expect(coordinator.begin(product.port(), .install, product.state.generation).accepted);
    try testDrain(coordinator, product.port());
    const old = coordinator.registry.current.?;
    var pin = try old.pin();
    defer pin.deinit();
    const old_record = old.record;
    try std.testing.expect(coordinator.begin(product.port(), .repair, product.state.generation).accepted);
    try testDrain(coordinator, product.port());
    try std.testing.expect(product.state.cleanup_pending);
    var old_name: [32]u8 = undefined;
    _ = try coordinator.store.versions.statFile(std.testing.io, old_record.versionName(&old_name), .{});
    const current_record = coordinator.registry.current.?.record;
    try std.testing.expect(!current_record.sameDirectory(old_record));
    try std.testing.expect(coordinator.begin(product.port(), .remove, product.state.generation).accepted);
    try testDrain(coordinator, product.port());
    try std.testing.expect(product.state.current == null);
    try std.testing.expectEqualStrings(root, product.source_root[0..product.source_root_len]);
    try std.testing.expect(try coordinator.store.current() == null);
    var current_name: [32]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, coordinator.store.versions.statFile(std.testing.io, current_record.versionName(&current_name), .{}));
    try std.testing.expect(product.state.cleanup_pending);
    _ = try coordinator.store.versions.statFile(std.testing.io, &old_name, .{});
    pin.deinit();
    try std.testing.expect(coordinator.drain(product.port()));
    try testDrain(coordinator, product.port());
    try std.testing.expect(!product.state.cleanup_pending);
    try std.testing.expect(!coordinator.registry.cleanupPending());
    try std.testing.expectError(error.FileNotFound, coordinator.store.versions.statFile(std.testing.io, &old_name, .{}));
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.store.retirements()).count);
}

test "cold Office cleanup preserves its intent while a version job is unresolved and succeeds after restart" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var effects: TestEffects = .{};
    var retired: store_impl.Record = undefined;
    // Keep an old version through update, then simulate process exit without
    // replaying or persisting any of its catalog references.
    {
        const coordinator = try Coordinator.create(std.testing.allocator, std.testing.io, root, &environment, test_input, root, .{ .context = &effects, .notify_fn = TestEffects.notify });
        defer coordinator.destroy() catch unreachable;
        coordinator.testing = .{ .source = .{ .context = &effects, .read_fn = TestEffects.read }, .validation = .{ .context = &effects, .available_fn = TestEffects.available, .test_fn = TestEffects.validate } };
        var product: TestPort = .{ .state = model.State.init(try coordinator.configuration()) };
        defer coordinator.shutdown(product.port());
        _ = coordinator.begin(product.port(), .check, product.state.generation);
        try testDrain(coordinator, product.port());
        _ = coordinator.begin(product.port(), .install, product.state.generation);
        try testDrain(coordinator, product.port());
        retired = coordinator.registry.current.?.record;
        var pin = try coordinator.registry.current.?.pin();
        defer pin.deinit();
        _ = coordinator.begin(product.port(), .repair, product.state.generation);
        try testDrain(coordinator, product.port());
        try std.testing.expect(product.state.cleanup_pending);
    }
    // Even an empty job with an outstanding owner must not be adopted or taken
    // as proof of quiescence by a cold worker. It keeps both bytes and intent.
    var unresolved = try process.ResourceScope.initVersion(retired.install_id);
    defer unresolved.deinit();
    for ([_]bool{ true, false }) |blocked| {
        const coordinator = try Coordinator.create(std.testing.allocator, std.testing.io, root, &environment, test_input, root, .{ .context = &effects, .notify_fn = TestEffects.notify });
        defer coordinator.destroy() catch unreachable;
        coordinator.testing = .{ .source = .{ .context = &effects, .read_fn = TestEffects.read }, .validation = .{ .context = &effects, .available_fn = TestEffects.available, .test_fn = TestEffects.validate } };
        var product: TestPort = .{ .state = model.State.init(try coordinator.configuration()) };
        defer coordinator.shutdown(product.port());
        _ = coordinator.begin(product.port(), .check, product.state.generation);
        try testDrain(coordinator, product.port());
        var name: [32]u8 = undefined;
        if (blocked) {
            try std.testing.expectEqual(model.Health.restart_required, product.state.health);
            try std.testing.expect(product.state.cleanup_pending);
            try std.testing.expectEqual(@as(usize, 1), (try coordinator.store.retirements()).count);
            _ = try coordinator.store.versions.statFile(std.testing.io, retired.versionName(&name), .{});
            unresolved.deinit();
        } else {
            try std.testing.expectEqual(model.Health.ready, product.state.health);
            try std.testing.expect(!product.state.cleanup_pending);
            try std.testing.expectEqual(@as(usize, 0), (try coordinator.store.retirements()).count);
            try std.testing.expectError(error.FileNotFound, coordinator.store.versions.statFile(std.testing.io, retired.versionName(&name), .{}));
        }
    }
}
