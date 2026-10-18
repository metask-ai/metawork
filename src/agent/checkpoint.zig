//! Operation-specific AgentCore checkpoint consumption.
//!
//! This module owns the official ABI mapping and streaming callback contract.
//! It never owns filesystem paths or external persistence policy.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;

pub const Limits = struct {
    hard_bytes: u64,
    max_section_bytes: u64,
    max_string_bytes: u64,
    max_messages: u64,
    max_blocks_per_message: u64,
    chunk_bytes: u32,
};

pub const SinkWriteResult = enum {
    ok,
    cancelled,
    io_failed,
    contract_failed,
};

pub const Sink = struct {
    context: ?*anyopaque,
    write_fn: *const fn (?*anyopaque, []const u8) SinkWriteResult,
};

pub const Stage = enum {
    checkpoint_export,
    describe,
};

pub const FailureReason = enum {
    invalid_argument,
    out_of_memory,
    resource_limit,
    busy,
    core_error,
    invalid_state,
    cancelled,
    io_failed,
    host_out_of_memory,
    dependency_contract,
};

pub const OperationDisposition = enum {
    reusable,
    poisoned,
};

pub const Failure = struct {
    stage: Stage,
    reason: FailureReason,
    disposition: OperationDisposition,
};

pub const Export = struct {
    generation: u64,
    total_bytes: u64,
    chunk_count: u64,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub const LogicalSessionOrigin = enum {
    fresh,
    restored,
};

pub const SessionLifecycle = enum {
    idle,
    busy,
    poisoned,
};

pub const RestoreHealth = enum {
    complete,
    degraded,
};

pub const DurableBudgetOutcome = enum {
    none,
    budget_required,
    budget_exhausted,
    resource_limit,
};

pub const Description = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    origin: LogicalSessionOrigin,
    lifecycle: SessionLifecycle,
    registered: bool,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,
    permission_mode: sdk.protocol.PermissionMode,
    policy_generation: u64,
    catalog_generation: u64,
    model: []u8,
    message_count: u64,
    compact_boundary: u64,
    skill_catalog_revision: ?[]u8,
    mcp_selection_fingerprint: []u8,
    budget_hard_bytes: u64,
    budget_soft_bytes: u64,
    durable_usage_bytes: u64,
    available_bytes: u64,
    compaction_recommended: bool,
    budget_outcome: DurableBudgetOutcome,
    required_bytes: u64,
    restore_health: RestoreHealth,
    invalidated_skill_authority: u32,
    invalidated_permission_rules: u32,
    invalidated_mcp_bindings: u32,

    pub fn deinit(self: *Description) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.model);
        if (self.skill_catalog_revision) |value| self.allocator.free(value);
        self.allocator.free(self.mcp_selection_fingerprint);
        self.* = undefined;
    }
};

pub const Expectation = struct {
    checkpoint_generation: u64,
    last_run_id: u64,
    last_compact_id: u64,
    model: []const u8,
};

pub const Success = struct {
    checkpoint: Export,
    description: Description,

    pub fn deinit(self: *Success) void {
        self.description.deinit();
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    success: Success,
    failure: Failure,

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .success => |*success| success.deinit(),
            .failure => {},
        }
        self.* = undefined;
    }
};

pub fn validateLimits(limits: Limits) error{InvalidLimits}!void {
    if (limits.hard_bytes == 0 or
        limits.max_section_bytes == 0 or
        limits.max_string_bytes == 0 or
        limits.max_messages == 0 or
        limits.max_blocks_per_message == 0 or
        limits.chunk_bytes == 0 or
        limits.hard_bytes > wire.MAX_CHECKPOINT_BYTES_V1 or
        limits.chunk_bytes > wire.MAX_CHECKPOINT_CHUNK_BYTES_V1 or
        limits.max_section_bytes > limits.hard_bytes or
        limits.max_string_bytes > limits.max_section_bytes or
        limits.chunk_bytes > limits.hard_bytes)
        return error.InvalidLimits;
}

pub fn create(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    raw_session: *wire.SessionHandle,
    limits: Limits,
    sink: Sink,
    expected_last_run_id: u64,
    expected_last_compact_id: u64,
    expected_model: []const u8,
) Outcome {
    validateLimits(limits) catch return .{ .failure = dependencyFailure(.checkpoint_export) };

    const exported = exportCheckpoint(api, raw_session, limits, sink);
    const export_result = switch (exported) {
        .success => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    const description = describe(
        allocator,
        api,
        raw_session,
        .{
            .checkpoint_generation = export_result.generation,
            .last_run_id = expected_last_run_id,
            .last_compact_id = expected_last_compact_id,
            .model = expected_model,
        },
    );
    return switch (description) {
        .success => |value| .{ .success = .{
            .checkpoint = export_result,
            .description = value,
        } },
        .failure => |failure| .{ .failure = failure },
    };
}

const ExportOutcome = union(enum) {
    success: Export,
    failure: Failure,
};

const LocalSinkFailure = enum {
    none,
    cancelled,
    io_failed,
    contract_failed,
};

const SinkAdapter = struct {
    sink: Sink,
    limits: Limits,
    total_bytes: u64 = 0,
    chunk_count: u64 = 0,
    digest: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    failure: LocalSinkFailure = .none,

    fn write(context: ?*anyopaque, raw_chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *SinkAdapter = @ptrCast(@alignCast(context orelse
            return wire.CHECKPOINT_IO_FATAL));
        if (self.failure != .none) {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        }
        const chunk = sdk.borrowedBytes(raw_chunk) catch {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        };
        const chunk_len = std.math.cast(u64, chunk.len) orelse {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        };
        if (chunk_len > self.limits.chunk_bytes or
            chunk_len > self.limits.hard_bytes or
            self.total_bytes > self.limits.hard_bytes - chunk_len or
            self.chunk_count == std.math.maxInt(u64))
        {
            self.failure = .contract_failed;
            return wire.CHECKPOINT_IO_FATAL;
        }
        switch (self.sink.write_fn(self.sink.context, chunk)) {
            .ok => {
                self.total_bytes += chunk_len;
                self.chunk_count += 1;
                self.digest.update(chunk);
                return wire.CHECKPOINT_IO_OK;
            },
            .cancelled => {
                self.failure = .cancelled;
                return wire.CHECKPOINT_IO_FAILED;
            },
            .io_failed => {
                self.failure = .io_failed;
                return wire.CHECKPOINT_IO_FAILED;
            },
            .contract_failed => {
                self.failure = .contract_failed;
                return wire.CHECKPOINT_IO_FATAL;
            },
        }
    }
};

fn exportCheckpoint(
    api: sdk.Api,
    raw_session: *wire.SessionHandle,
    limits: Limits,
    sink: Sink,
) ExportOutcome {
    var adapter = SinkAdapter{ .sink = sink, .limits = limits };
    var raw_limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    raw_limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    raw_limits.hard_bytes = limits.hard_bytes;
    raw_limits.max_section_bytes = limits.max_section_bytes;
    raw_limits.max_string_bytes = limits.max_string_bytes;
    raw_limits.max_messages = limits.max_messages;
    raw_limits.max_blocks_per_message = limits.max_blocks_per_message;
    raw_limits.chunk_bytes = limits.chunk_bytes;
    var raw_sink = std.mem.zeroes(wire.CheckpointSinkV1);
    raw_sink.struct_size = @sizeOf(wire.CheckpointSinkV1);
    raw_sink.ctx = &adapter;
    raw_sink.write = SinkAdapter.write;
    var config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    config.limits = &raw_limits;
    config.sink = &raw_sink;
    var result = std.mem.zeroes(wire.CheckpointExportResultV1);
    var diagnostic = emptyOwnedBytes();
    const status_code = api.sessionControl().exportCheckpoint()(
        raw_session,
        &config,
        &result,
        &diagnostic,
    );
    const diagnostic_valid = validOwnedBytes(diagnostic);
    releaseOwned(api, &diagnostic);
    if (!diagnostic_valid) return .{ .failure = dependencyFailure(.checkpoint_export) };
    const status = sdk.Status.fromCode(status_code) catch
        return .{ .failure = dependencyFailure(.checkpoint_export) };

    if (status == .ok) {
        var observed_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        adapter.digest.final(&observed_digest);
        if (adapter.failure != .none or
            result.struct_size != @sizeOf(wire.CheckpointExportResultV1) or
            result.reserved0 != 0 or
            !allZero(&result.reserved) or
            result.total_bytes != adapter.total_bytes or
            result.chunk_count != adapter.chunk_count or
            result.total_bytes > limits.hard_bytes)
        {
            return .{ .failure = dependencyFailure(.checkpoint_export) };
        }
        return .{
            .success = .{
                .generation = result.checkpoint_generation,
                .total_bytes = result.total_bytes,
                .chunk_count = result.chunk_count,
                // The ABI exposes a fixed-width `digest` field but does not
                // define its algorithm. Checkpoint integrity therefore uses the
                // independently observed SHA-256 of the streamed bytes.
                .digest = observed_digest,
            },
        };
    }

    if (status != .checkpoint_io and adapter.failure != .none)
        return .{ .failure = dependencyFailure(.checkpoint_export) };
    return .{ .failure = switch (status) {
        .invalid_argument => reusableFailure(.checkpoint_export, .invalid_argument),
        .resource_limit => reusableFailure(.checkpoint_export, .resource_limit),
        .busy => reusableFailure(.checkpoint_export, .busy),
        .out_of_memory => poisonedFailure(.checkpoint_export, .out_of_memory),
        .core_error => poisonedFailure(.checkpoint_export, .core_error),
        .invalid_state => poisonedFailure(.checkpoint_export, .invalid_state),
        .checkpoint_io => switch (adapter.failure) {
            .cancelled => reusableFailure(.checkpoint_export, .cancelled),
            .io_failed => reusableFailure(.checkpoint_export, .io_failed),
            .none, .contract_failed => dependencyFailure(.checkpoint_export),
        },
        .checkpoint_budget_required,
        .checkpoint_corrupt,
        .checkpoint_unsupported,
        .checkpoint_incompatible,
        .logical_session_conflict,
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
        .mcp_not_refreshed,
        .invalid_mcp_selection,
        .skill_catalog_incomplete,
        .image_input_unsupported,
        .image_input_capability_unknown,
        .goal_conflict,
        .ok,
        => dependencyFailure(.checkpoint_export),
    } };
}

pub const DescriptionOutcome = union(enum) {
    success: Description,
    failure: Failure,
};

pub fn describe(
    allocator: std.mem.Allocator,
    api: sdk.Api,
    raw_session: *wire.SessionHandle,
    expectation: Expectation,
) DescriptionOutcome {
    var encoded = emptyOwnedBytes();
    var diagnostic = emptyOwnedBytes();
    const status_code = api.sessionControl().describe()(raw_session, &encoded, &diagnostic);
    const diagnostic_valid = validOwnedBytes(diagnostic);
    defer releaseOwned(api, &diagnostic);
    const status = sdk.Status.fromCode(status_code) catch {
        releaseOwned(api, &encoded);
        return .{ .failure = dependencyFailure(.describe) };
    };
    if (!diagnostic_valid) {
        releaseOwned(api, &encoded);
        return .{ .failure = dependencyFailure(.describe) };
    }
    if (status != .ok) {
        const output_is_empty = encoded.ptr == null and encoded.len == 0;
        releaseOwned(api, &encoded);
        if (!output_is_empty) return .{ .failure = dependencyFailure(.describe) };
        return .{ .failure = switch (status) {
            .invalid_argument => reusableFailure(.describe, .invalid_argument),
            .resource_limit => reusableFailure(.describe, .resource_limit),
            .busy => reusableFailure(.describe, .busy),
            .out_of_memory => poisonedFailure(.describe, .out_of_memory),
            .core_error => poisonedFailure(.describe, .core_error),
            .invalid_state => poisonedFailure(.describe, .invalid_state),
            .ok,
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
            .checkpoint_budget_required,
            .checkpoint_corrupt,
            .checkpoint_unsupported,
            .checkpoint_incompatible,
            .checkpoint_io,
            .logical_session_conflict,
            .mcp_not_refreshed,
            .invalid_mcp_selection,
            .skill_catalog_incomplete,
            .image_input_unsupported,
            .image_input_capability_unknown,
            .goal_conflict,
            => dependencyFailure(.describe),
        } };
    }

    const bytes = sdk.borrowedBytes(.{ .ptr = encoded.ptr, .len = encoded.len }) catch {
        releaseOwned(api, &encoded);
        return .{ .failure = dependencyFailure(.describe) };
    };
    var parsed = sdk.decodeSessionDescription(allocator, bytes) catch {
        releaseOwned(api, &encoded);
        return .{ .failure = dependencyFailure(.describe) };
    };
    releaseOwned(api, &encoded);
    defer parsed.deinit();
    const value = parsed.value;
    if (value.checkpoint_generation != expectation.checkpoint_generation or
        value.last_run_id != expectation.last_run_id or
        value.last_compact_id != expectation.last_compact_id or
        !std.mem.eql(u8, value.model, expectation.model))
    {
        return .{ .failure = dependencyFailure(.describe) };
    }

    const session_id = allocator.dupe(u8, value.session_id) catch
        return .{ .failure = reusableFailure(.describe, .host_out_of_memory) };
    const model = allocator.dupe(u8, value.model) catch {
        allocator.free(session_id);
        return .{ .failure = reusableFailure(.describe, .host_out_of_memory) };
    };
    const skill_catalog_revision = if (value.skill.catalog_revision) |revision|
        allocator.dupe(u8, revision) catch {
            allocator.free(model);
            allocator.free(session_id);
            return .{ .failure = reusableFailure(.describe, .host_out_of_memory) };
        }
    else
        null;
    const mcp_selection_fingerprint = allocator.dupe(
        u8,
        value.mcp.selection_fingerprint,
    ) catch {
        if (skill_catalog_revision) |revision| allocator.free(revision);
        allocator.free(model);
        allocator.free(session_id);
        return .{ .failure = reusableFailure(.describe, .host_out_of_memory) };
    };

    return .{ .success = .{
        .allocator = allocator,
        .session_id = session_id,
        .origin = switch (value.origin) {
            .fresh => .fresh,
            .restored => .restored,
        },
        .lifecycle = switch (value.lifecycle) {
            .idle => .idle,
            .busy => .busy,
            .poisoned => .poisoned,
        },
        .registered = value.registered,
        .last_run_id = value.last_run_id,
        .last_compact_id = value.last_compact_id,
        .checkpoint_generation = value.checkpoint_generation,
        .permission_mode = value.permission_mode,
        .policy_generation = value.policy_generation,
        .catalog_generation = value.catalog_generation,
        .model = model,
        .message_count = value.conversation.message_count,
        .compact_boundary = value.conversation.compact_boundary,
        .skill_catalog_revision = skill_catalog_revision,
        .mcp_selection_fingerprint = mcp_selection_fingerprint,
        .budget_hard_bytes = value.budget.hard_bytes,
        .budget_soft_bytes = value.budget.soft_bytes,
        .durable_usage_bytes = value.budget.durable_usage_bytes,
        .available_bytes = value.budget.available_bytes,
        .compaction_recommended = value.budget.compaction_recommended,
        .budget_outcome = switch (value.budget.last_outcome) {
            .none => .none,
            .budget_required => .budget_required,
            .budget_exhausted => .budget_exhausted,
            .resource_limit => .resource_limit,
        },
        .required_bytes = value.budget.required_bytes,
        .restore_health = switch (value.restore.health) {
            .complete => .complete,
            .degraded => .degraded,
        },
        .invalidated_skill_authority = value.restore.invalidated_skill_authority,
        .invalidated_permission_rules = value.restore.invalidated_permission_rules,
        .invalidated_mcp_bindings = value.restore.invalidated_mcp_bindings,
    } };
}

fn reusableFailure(stage: Stage, reason: FailureReason) Failure {
    return .{ .stage = stage, .reason = reason, .disposition = .reusable };
}

fn poisonedFailure(stage: Stage, reason: FailureReason) Failure {
    return .{ .stage = stage, .reason = reason, .disposition = .poisoned };
}

fn dependencyFailure(stage: Stage) Failure {
    return poisonedFailure(stage, .dependency_contract);
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

fn allZero(values: []const u64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

test "checkpoint limits stay below the official ABI ceilings" {
    try validateLimits(.{
        .hard_bytes = 64 * 1024 * 1024,
        .max_section_bytes = 16 * 1024 * 1024,
        .max_string_bytes = 1024 * 1024,
        .max_messages = 4096,
        .max_blocks_per_message = 256,
        .chunk_bytes = 256 * 1024,
    });
    try std.testing.expectError(error.InvalidLimits, validateLimits(.{
        .hard_bytes = wire.MAX_CHECKPOINT_BYTES_V1 + 1,
        .max_section_bytes = 1,
        .max_string_bytes = 1,
        .max_messages = 1,
        .max_blocks_per_message = 1,
        .chunk_bytes = 1,
    }));
    try std.testing.expectError(error.InvalidLimits, validateLimits(.{
        .hard_bytes = 1024,
        .max_section_bytes = 1024,
        .max_string_bytes = 1024,
        .max_messages = 1,
        .max_blocks_per_message = 1,
        .chunk_bytes = 2048,
    }));
}
