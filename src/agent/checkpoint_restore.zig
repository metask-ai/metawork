//! Operation-specific AgentCore checkpoint restore adapter.
//!
//! This module owns the official restore ABI mapping, source callback, report
//! decoding, and post-restore description cross-check. It does not know about
//! filesystem layout, credentials, or recovery policy outside Agent.

const std = @import("std");
const checkpoint = @import("agent_checkpoint");
const sdk = @import("metask_agentcore");
const wire = sdk.types;

pub const SourceReadResult = union(enum) {
    bytes: usize,
    eof,
    cancelled,
    io_failed,
    contract_failed,
};

pub const Source = struct {
    context: ?*anyopaque,
    read_fn: *const fn (?*anyopaque, []u8) SourceReadResult,
};

pub const Expectation = struct {
    logical_session_id: []const u8,
    checkpoint_generation: u64,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
};

pub const Stage = enum {
    restore,
    report,
    describe,
    cleanup,
};

pub const FailureReason = enum {
    invalid_argument,
    out_of_memory,
    resource_limit,
    busy,
    core_error,
    invalid_state,
    checkpoint_corrupt,
    checkpoint_unsupported,
    checkpoint_incompatible,
    logical_session_conflict,
    mcp_not_refreshed,
    cancelled,
    io_failed,
    host_out_of_memory,
    dependency_contract,
};

pub const Failure = struct {
    stage: Stage,
    reason: FailureReason,
    retained_candidate: ?*wire.SessionHandle = null,
};

pub const Report = struct {
    health: checkpoint.RestoreHealth,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    invalidated_skill_authority: u32,
    restored_permission_rules: u32,
    invalidated_permission_rules: u32,
    invalidated_mcp_bindings: u32,
};

pub const Success = struct {
    raw_session: *wire.SessionHandle,
    report: Report,
    description: checkpoint.Description,

    pub fn deinitMetadata(self: *Success) void {
        self.description.deinit();
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    success: Success,
    failure: Failure,
};

const LocalSourceFailure = enum {
    none,
    cancelled,
    io_failed,
    contract_failed,
};

const SourceAdapter = struct {
    source: Source,
    hard_bytes: u64,
    failure: LocalSourceFailure = .none,
    calls: u64 = 0,
    total_bytes: u64 = 0,
    eof_seen: bool = false,

    fn read(
        context: ?*anyopaque,
        destination: ?[*]u8,
        capacity: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *SourceAdapter = @ptrCast(@alignCast(context orelse
            return wire.CHECKPOINT_IO_FATAL));
        const output = out_len orelse {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        };
        output.* = 0;
        if (self.failure != .none or self.eof_seen or self.calls == std.math.maxInt(u64)) {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        }
        if (capacity > self.hard_bytes) {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        }
        const destination_capacity = std.math.cast(usize, capacity) orelse {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        };
        if (destination_capacity == 0) {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        }
        const destination_pointer = destination orelse {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        };
        self.calls += 1;
        return switch (self.source.read_fn(
            self.source.context,
            destination_pointer[0..destination_capacity],
        )) {
            .bytes => |count| bytes: {
                if (count == 0 or count > destination_capacity or
                    count > self.hard_bytes or
                    self.total_bytes > self.hard_bytes - count)
                {
                    self.failure = .contract_failed;
                    break :bytes wire.CHECKPOINT_IO_FATAL;
                }
                self.total_bytes += count;
                output.* = count;
                break :bytes wire.CHECKPOINT_IO_OK;
            },
            .eof => eof: {
                self.eof_seen = true;
                break :eof wire.CHECKPOINT_IO_OK;
            },
            .cancelled => failure: {
                self.failure = .cancelled;
                break :failure wire.CHECKPOINT_IO_FAILED;
            },
            .io_failed => failure: {
                self.failure = .io_failed;
                break :failure wire.CHECKPOINT_IO_FAILED;
            },
            .contract_failed => failure: {
                self.failure = .contract_failed;
                break :failure wire.CHECKPOINT_IO_FATAL;
            },
        };
    }
};

pub fn restore(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    host: *const wire.SessionHostConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
    limits: checkpoint.Limits,
    source: Source,
    expectation: Expectation,
) Outcome {
    checkpoint.validateLimits(limits) catch
        return .{ .failure = dependencyFailure(.restore) };
    if (expectation.logical_session_id.len == 0 or
        expectation.checkpoint_generation == 0 or
        expectation.model.len == 0)
        return .{ .failure = dependencyFailure(.restore) };

    var adapter = SourceAdapter{ .source = source, .hard_bytes = limits.hard_bytes };
    var raw_source = std.mem.zeroes(wire.CheckpointSourceV1);
    raw_source.struct_size = @sizeOf(wire.CheckpointSourceV1);
    raw_source.ctx = &adapter;
    raw_source.read = SourceAdapter.read;
    var raw_limits = makeLimits(limits);
    var config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    config.host = host;
    config.source = &raw_source;
    config.limits = &raw_limits;

    var raw_session: ?*wire.SessionHandle = null;
    var encoded_report = emptyOwnedBytes();
    var diagnostic = emptyOwnedBytes();
    const status_code = api.sessionControl().restore()(
        runtime,
        &config,
        callbacks,
        &raw_session,
        &encoded_report,
        &diagnostic,
    );
    const diagnostic_valid = validOwnedBytes(diagnostic);
    releaseOwned(api, &diagnostic);
    const status = sdk.Status.fromCode(status_code) catch {
        releaseOwned(api, &encoded_report);
        return failWithCandidate(api, raw_session, dependencyFailure(.restore));
    };
    if (!diagnostic_valid) {
        releaseOwned(api, &encoded_report);
        return failWithCandidate(api, raw_session, dependencyFailure(.restore));
    }
    if (status != .ok) {
        const report_empty = encoded_report.ptr == null and encoded_report.len == 0;
        releaseOwned(api, &encoded_report);
        const candidate_clean = destroyCandidate(api, raw_session);
        if (!report_empty or raw_session != null or !candidate_clean or
            (adapter.failure != .none and status != .checkpoint_io))
        {
            var failure = dependencyFailure(.restore);
            if (!candidate_clean) {
                failure.stage = .cleanup;
                failure.retained_candidate = raw_session;
            }
            return .{ .failure = failure };
        }
        return .{ .failure = failureForStatus(status, adapter.failure) };
    }
    const candidate = raw_session orelse {
        releaseOwned(api, &encoded_report);
        return .{ .failure = dependencyFailure(.restore) };
    };
    if (adapter.failure != .none or !validOwnedBytes(encoded_report) or
        encoded_report.ptr == null or encoded_report.len == 0)
    {
        releaseOwned(api, &encoded_report);
        return failWithCandidate(api, candidate, dependencyFailure(.restore));
    }

    const report_bytes = sdk.borrowedBytes(.{
        .ptr = encoded_report.ptr,
        .len = encoded_report.len,
    }) catch {
        releaseOwned(api, &encoded_report);
        return failWithCandidate(api, candidate, dependencyFailure(.report));
    };
    var parsed_report = sdk.decodeRestoreReport(allocator, report_bytes) catch |err| {
        releaseOwned(api, &encoded_report);
        return failWithCandidate(api, candidate, if (err == error.OutOfMemory)
            reusableFailure(.report, .host_out_of_memory)
        else
            dependencyFailure(.report));
    };
    releaseOwned(api, &encoded_report);
    defer parsed_report.deinit();
    const report = parsed_report.value;
    if (!std.mem.eql(u8, report.session_id, expectation.logical_session_id) or
        report.checkpoint_generation != expectation.checkpoint_generation)
    {
        return failWithCandidate(api, candidate, dependencyFailure(.report));
    }

    const described = checkpoint.describe(
        allocator,
        api,
        candidate,
        .{
            .checkpoint_generation = expectation.checkpoint_generation,
            .last_run_id = expectation.last_run_id,
            .last_compact_id = expectation.last_compact_id,
            .model = expectation.model,
        },
    );
    var description = switch (described) {
        .success => |value| value,
        .failure => |failure| {
            return failWithCandidate(api, candidate, mapDescriptionFailure(failure));
        },
    };
    if (!std.mem.eql(u8, description.session_id, expectation.logical_session_id) or
        description.origin != .restored or
        description.lifecycle != .idle or
        !description.registered or
        description.restore_health != switch (report.health) {
            .complete => checkpoint.RestoreHealth.complete,
            .degraded => checkpoint.RestoreHealth.degraded,
        } or
        description.policy_generation != report.policy_generation or
        description.catalog_generation != report.catalog_generation or
        description.invalidated_skill_authority != report.skill.invalidated or
        description.invalidated_permission_rules != report.permission.invalidated_rules or
        description.invalidated_mcp_bindings != report.mcp.invalidated_bindings)
    {
        description.deinit();
        return failWithCandidate(api, candidate, dependencyFailure(.describe));
    }

    return .{ .success = .{
        .raw_session = candidate,
        .report = .{
            .health = switch (report.health) {
                .complete => .complete,
                .degraded => .degraded,
            },
            .checkpoint_generation = report.checkpoint_generation,
            .policy_generation = report.policy_generation,
            .catalog_generation = report.catalog_generation,
            .invalidated_skill_authority = report.skill.invalidated,
            .restored_permission_rules = report.permission.restored_rules,
            .invalidated_permission_rules = report.permission.invalidated_rules,
            .invalidated_mcp_bindings = report.mcp.invalidated_bindings,
        },
        .description = description,
    } };
}

fn makeLimits(limits: checkpoint.Limits) wire.CheckpointLimitsV1 {
    var raw = std.mem.zeroes(wire.CheckpointLimitsV1);
    raw.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    raw.hard_bytes = limits.hard_bytes;
    raw.max_section_bytes = limits.max_section_bytes;
    raw.max_string_bytes = limits.max_string_bytes;
    raw.max_messages = limits.max_messages;
    raw.max_blocks_per_message = limits.max_blocks_per_message;
    raw.chunk_bytes = limits.chunk_bytes;
    return raw;
}

fn failureForStatus(status: sdk.Status, local: LocalSourceFailure) Failure {
    return switch (status) {
        .invalid_argument => reusableFailure(.restore, .invalid_argument),
        .resource_limit => reusableFailure(.restore, .resource_limit),
        .busy => reusableFailure(.restore, .busy),
        .out_of_memory => reusableFailure(.restore, .out_of_memory),
        .core_error => reusableFailure(.restore, .core_error),
        .invalid_state => reusableFailure(.restore, .invalid_state),
        .checkpoint_corrupt => reusableFailure(.restore, .checkpoint_corrupt),
        .checkpoint_unsupported => reusableFailure(.restore, .checkpoint_unsupported),
        .checkpoint_incompatible => reusableFailure(.restore, .checkpoint_incompatible),
        .logical_session_conflict => reusableFailure(.restore, .logical_session_conflict),
        .mcp_not_refreshed => reusableFailure(.restore, .mcp_not_refreshed),
        .checkpoint_io => switch (local) {
            .cancelled => reusableFailure(.restore, .cancelled),
            .io_failed => reusableFailure(.restore, .io_failed),
            .none, .contract_failed => dependencyFailure(.restore),
        },
        .checkpoint_budget_required,
        .stale_run,
        .too_late,
        .callback_failed,
        .internal_error,
        .skill_catalog_invalid,
        .stale_catalog,
        .skill_not_found,
        .invalid_skill_arguments,
        .skill_policy_violation,
        .skill_unavailable,
        .stale_compact,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .document_input_unsupported,
        .ok,
        => dependencyFailure(.restore),
    };
}

fn mapDescriptionFailure(failure: checkpoint.Failure) Failure {
    return .{
        .stage = .describe,
        .reason = switch (failure.reason) {
            .invalid_argument => .invalid_argument,
            .out_of_memory => .out_of_memory,
            .resource_limit => .resource_limit,
            .busy => .busy,
            .core_error => .core_error,
            .invalid_state => .invalid_state,
            .host_out_of_memory => .host_out_of_memory,
            .dependency_contract => .dependency_contract,
            .cancelled, .io_failed => .dependency_contract,
        },
    };
}

pub fn destroyCandidate(api: sdk.Api, candidate: ?*wire.SessionHandle) bool {
    const session = candidate orelse return true;
    var diagnostic = emptyOwnedBytes();
    const status_code = api.session().destroy()(session, &diagnostic);
    _ = validOwnedBytes(diagnostic);
    releaseOwned(api, &diagnostic);
    const status = sdk.Status.fromCode(status_code) catch return false;
    return status == .ok;
}

fn failWithCandidate(
    api: sdk.Api,
    candidate: ?*wire.SessionHandle,
    initial: Failure,
) Outcome {
    var failure = initial;
    if (!destroyCandidate(api, candidate)) {
        failure.stage = .cleanup;
        failure.reason = .dependency_contract;
        failure.retained_candidate = candidate;
    }
    return .{ .failure = failure };
}

fn reusableFailure(stage: Stage, reason: FailureReason) Failure {
    return .{ .stage = stage, .reason = reason };
}

fn dependencyFailure(stage: Stage) Failure {
    return reusableFailure(stage, .dependency_contract);
}

fn validOwnedBytes(buffer: wire.OwnedBytesV1) bool {
    _ = sdk.borrowedBytes(.{ .ptr = buffer.ptr, .len = buffer.len }) catch return false;
    return true;
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: sdk.Api, buffer: *wire.OwnedBytesV1) void {
    if (buffer.ptr != null or buffer.len != 0) api.bufferRelease()(buffer);
}

test "source adapter preserves short reads EOF and local failures" {
    const Harness = struct {
        bytes: []const u8,
        offset: usize = 0,

        fn read(context: ?*anyopaque, destination: []u8) SourceReadResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.offset == self.bytes.len) return .eof;
            const count = @min(@min(destination.len, @as(usize, 3)), self.bytes.len - self.offset);
            @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
            self.offset += count;
            return .{ .bytes = count };
        }
    };
    var harness = Harness{ .bytes = "checkpoint" };
    var adapter = SourceAdapter{
        .source = .{ .context = &harness, .read_fn = Harness.read },
        .hard_bytes = 64,
    };
    var storage: [16]u8 = undefined;
    var count: u64 = 0;
    while (!adapter.eof_seen) {
        try std.testing.expectEqual(
            wire.CHECKPOINT_IO_OK,
            SourceAdapter.read(&adapter, &storage, storage.len, &count),
        );
        try std.testing.expect(count <= 3);
    }
    try std.testing.expectEqualStrings("checkpoint", harness.bytes[0..harness.offset]);
    try std.testing.expectEqual(@as(u64, harness.bytes.len), adapter.total_bytes);
}

test "restore status mapping keeps checkpoint failures retryable" {
    const cases = [_]struct {
        status: sdk.Status,
        reason: FailureReason,
    }{
        .{ .status = .checkpoint_corrupt, .reason = .checkpoint_corrupt },
        .{ .status = .checkpoint_unsupported, .reason = .checkpoint_unsupported },
        .{ .status = .checkpoint_incompatible, .reason = .checkpoint_incompatible },
        .{ .status = .logical_session_conflict, .reason = .logical_session_conflict },
        .{ .status = .mcp_not_refreshed, .reason = .mcp_not_refreshed },
    };
    for (cases) |case| {
        const failure = failureForStatus(case.status, .none);
        try std.testing.expectEqual(Stage.restore, failure.stage);
        try std.testing.expectEqual(case.reason, failure.reason);
        try std.testing.expect(failure.retained_candidate == null);
    }

    const cancelled = failureForStatus(.checkpoint_io, .cancelled);
    try std.testing.expectEqual(FailureReason.cancelled, cancelled.reason);
    const io_failed = failureForStatus(.checkpoint_io, .io_failed);
    try std.testing.expectEqual(FailureReason.io_failed, io_failed.reason);
}
