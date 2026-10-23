//! Public Office management projection. Runtime identities, URLs, paths,
//! catalog leases and process handles remain with their Host owners.
const model = @import("product_office_component");
const encoding = @import("product_view_encoding");

pub const View = struct {
    generation: encoding.PositiveU64,
    supported: bool,
    health: model.Health,
    offered: ?struct { downloadBytes: encoding.U64, installedBytes: encoding.U64 },
    current: ?struct { state: model.InstalledState },
    updateAvailable: bool,
    operation: ?struct {
        id: encoding.PositiveU64,
        kind: model.Kind,
        phase: model.Phase,
        bytes: encoding.U64,
        total: encoding.U64,
        cancelling: bool,
    },
    terminal: ?struct { id: encoding.PositiveU64, kind: model.Kind, outcome: model.Outcome, reason: ?model.Reason },
    cleanupPending: bool,
    actions: model.Actions,

    pub fn from(value: model.View) View {
        return .{
            .generation = .{ .value = value.generation },
            .supported = value.supported,
            .health = value.health,
            .offered = if (value.offered) |offered| .{ .downloadBytes = .{ .value = offered.download_bytes }, .installedBytes = .{ .value = offered.installed_bytes } } else null,
            .current = if (value.current) |current| .{ .state = current.state } else null,
            .updateAvailable = value.update_available,
            .operation = if (value.operation) |operation| .{ .id = .{ .value = operation.id }, .kind = operation.kind, .phase = operation.phase, .bytes = .{ .value = operation.bytes }, .total = .{ .value = operation.total }, .cancelling = operation.cancelling } else null,
            .terminal = if (value.terminal) |terminal| .{ .id = .{ .value = terminal.id }, .kind = terminal.kind, .outcome = terminal.outcome, .reason = terminal.reason } else null,
            .cleanupPending = value.cleanup_pending,
            .actions = value.actions,
        };
    }
};

pub const Result = struct {
    accepted: bool,
    generation: encoding.PositiveU64,
    operationId: ?encoding.PositiveU64,
    reason: ?model.Reason,

    pub fn from(value: model.Admission, generation: u64) Result {
        return .{
            .accepted = value.accepted,
            .generation = .{ .value = generation },
            .operationId = if (value.operation_id) |id| .{ .value = id } else null,
            .reason = value.reason,
        };
    }
};
