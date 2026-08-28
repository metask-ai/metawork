//! Stateless Product Workspace projection.
//! View borrows Registry facts plus callback-scoped Task signals, Skill
//! catalog and credential-aware text writers. It owns no aggregate state or
//! external capability.

const std = @import("std");
const workspace = @import("product_workspace_runtime");

pub const Error = error{SnapshotTooLarge};

pub const Projection = struct {
    id: u64,
    epoch: u64,
    kind: workspace.Kind,
    canonical_root: []const u8,
    display_name: []const u8,
    authorization: workspace.Authorization,
    last_removal_failure: workspace.RemovalFailure,
    recent_order: u64,
    signals: workspace.Signals,
};

/// Callback-scoped projection mechanics retained by Product Control. View
/// never stores this provider or obtains Task, Skill, credential, or Control
/// identities from it.
pub const Provider = struct {
    context: *const anyopaque,
    signals_fn: *const fn (*const anyopaque, u64) workspace.Signals,
    contains_sensitive_fn: *const fn (*const anyopaque, []const u8) bool,
    write_json_fn: *const fn (*const anyopaque, *std.Io.Writer, []const u8) Error!void,
    write_catalog_fn: *const fn (*const anyopaque, *std.Io.Writer, u64, u64) Error!void,

    fn signals(self: Provider, workspace_id: u64) workspace.Signals {
        return self.signals_fn(self.context, workspace_id);
    }

    fn containsSensitive(self: Provider, value: []const u8) bool {
        return self.contains_sensitive_fn(self.context, value);
    }

    fn writeJson(self: Provider, writer: *std.Io.Writer, value: []const u8) Error!void {
        return self.write_json_fn(self.context, writer, value);
    }

    fn writeCatalog(
        self: Provider,
        writer: *std.Io.Writer,
        workspace_id: u64,
        workspace_epoch: u64,
    ) Error!void {
        return self.write_catalog_fn(
            self.context,
            writer,
            workspace_id,
            workspace_epoch,
        );
    }
};

pub fn copyProjections(
    runtime: *const workspace.Runtime,
    output: []Projection,
    provider: Provider,
) error{WorkspaceCapacity}![]const Projection {
    var count: usize = 0;
    for (0..runtime.slotCount()) |index| {
        const fact = runtime.factsAt(index) orelse continue;
        if (fact.kind == .manual and !fact.visible) continue;
        if (count == output.len) return error.WorkspaceCapacity;
        output[count] = .{
            .id = fact.id,
            .epoch = fact.epoch,
            .kind = fact.kind,
            .canonical_root = fact.projected_root,
            .display_name = fact.display_name,
            .authorization = fact.authorization,
            .last_removal_failure = fact.last_removal_failure,
            .recent_order = fact.recent_order,
            .signals = provider.signals(fact.id),
        };
        count += 1;
    }
    std.mem.sort(
        Projection,
        output[0..count],
        {},
        struct {
            fn lessThan(_: void, left: Projection, right: Projection) bool {
                return left.recent_order > right.recent_order;
            }
        }.lessThan,
    );
    return output[0..count];
}

pub fn writeProjectionList(
    writer: *std.Io.Writer,
    runtime: *const workspace.Runtime,
    provider: Provider,
) Error!void {
    writer.writeByte('[') catch return error.SnapshotTooLarge;
    var count: usize = 0;
    for (0..runtime.slotCount()) |index| {
        const fact = runtime.factsAt(index) orelse continue;
        if (fact.kind == .manual and !fact.visible) continue;
        if (count != 0) writer.writeByte(',') catch return error.SnapshotTooLarge;
        count += 1;
        try writeObject(writer, fact, provider);
    }
    writer.writeByte(']') catch return error.SnapshotTooLarge;
}

fn writeObject(
    writer: *std.Io.Writer,
    fact: workspace.Facts,
    provider: Provider,
) Error!void {
    const signals = provider.signals(fact.id);
    writer.print("{{\"id\":\"{d}\",\"epoch\":\"{d}\",\"kind\":\"{s}\",\"displayName\":", .{
        fact.id,
        fact.epoch,
        @tagName(fact.kind),
    }) catch return error.SnapshotTooLarge;
    try provider.writeJson(writer, fact.display_name);
    writer.writeAll(",\"canonicalRoot\":") catch return error.SnapshotTooLarge;
    try provider.writeJson(writer, fact.projected_root);
    writer.print(",\"redacted\":{},\"authorization\":\"{s}\",\"lastRemovalFailure\":", .{
        fact.projection_redacted or
            provider.containsSensitive(fact.display_name) or
            provider.containsSensitive(fact.projected_root),
        @tagName(fact.authorization),
    }) catch return error.SnapshotTooLarge;
    if (fact.last_removal_failure == .none)
        writer.writeAll("null") catch return error.SnapshotTooLarge
    else
        writer.print("\"{s}\"", .{@tagName(fact.last_removal_failure)}) catch
            return error.SnapshotTooLarge;
    writer.writeAll(",\"skillCatalog\":") catch return error.SnapshotTooLarge;
    try provider.writeCatalog(writer, fact.id, fact.epoch);
    writer.print(",\"recentOrder\":\"{d}\",\"signals\":{{\"running\":{},\"attention\":{},\"failedOrInterrupted\":{}}}}}", .{
        fact.recent_order,
        signals.running,
        signals.attention,
        signals.failed_or_interrupted,
    }) catch return error.SnapshotTooLarge;
}
