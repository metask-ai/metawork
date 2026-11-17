//! What each port type becomes on the wire, and the request and response
//! payloads that follow from it.
//!
//! The 52 forwarding stubs' *payloads* are derived rather than written: a
//! method's request is its parameters after the context pointer, each mapped
//! through `Wire`, and its response is its return type with the error union
//! stripped and mapped the same way. So a parameter that changes type changes
//! the wire shape with it, where fifty-two hand-written encoders would keep
//! sending the old one.
//!
//! The stub *functions* are written out, one per method, and an earlier
//! commit message of mine said otherwise. Zig 0.16 removed `@Type`, so a
//! function whose signature is computed cannot be synthesised; each stub
//! declares its vtable signature by hand and forwards through one generic
//! call. What the derivation removes is the per-method encoder, which is where
//! the drift would have been -- not the fifty-two signatures, which the
//! compiler checks against the vtable anyway.
//!
//! `Wire` is the only hand-maintained part, and it is closed: a type that is
//! not listed must classify as structural, or the build fails naming it. That
//! is the same discipline as the method and payload registries, and it is what
//! makes "every method's payload can be carried" a fact the compiler checks
//! rather than a claim about code nobody has written yet.
//!
//! Two kinds of parameter do not travel at all. An allocator belongs to the
//! caller and is used on the response, never sent. A byte callback is replaced
//! by a descriptor the far side acts on. Both are `dropped` here, which is a
//! decision recorded per type rather than a silent omission.

const std = @import("std");
const contract = @import("agent_contract");
const payload = @import("payload.zig");
const shapes = @import("shapes.zig");
const handle_table = @import("handle_table.zig");
const method = @import("method.zig");

const surface = contract.surface;
const control = contract.control;
const port = contract.port;
const catalog = @import("agent_catalog");
const mcp_catalog = @import("agent_mcp_catalog");
const checkpoint = @import("agent_checkpoint");

/// A parameter that is not sent, and why.
pub const Dropped = struct {
    reason: []const u8,
};

/// The wire form of one port type.
///
/// `void` means the value does not travel. Anything else is the type the
/// structural codec carries, which `requireStructural` checks below.
pub fn Wire(comptime T: type) type {
    comptime {
        // The caller's allocator is the caller's: a response is decoded into
        // it locally, so it never crosses.
        if (T == std.mem.Allocator) return void;

        // Borrowed handles that live in the execution half.
        if (T == ?*catalog.Lease or T == *catalog.Lease) return handle_table.Id;
        if (T == ?*const mcp_catalog.Selection or T == *const mcp_catalog.Selection)
            return handle_table.Id;
        if (T == *const mcp_catalog.RestoreSelection) return handle_table.Id;
        if (T == *const mcp_catalog.Activation) return handle_table.Id;
        if (T == *mcp_catalog.Selection) return handle_table.Id;
        if (T == *port.SkillRestoreInputs or T == *const port.SkillRestoreInputs)
            return handle_table.Id;
        if (T == *port.SessionRestoreInputs) return handle_table.Id;
        if (T == port.SessionPort) return handle_table.Id;

        // Byte callbacks: the far side performs the I/O against a descriptor.
        if (T == checkpoint.Sink) return shapes.CheckpointDestination;
        if (T == contract.McpInstallationInput) return shapes.McpInstallationTarget;
        if (T == ?contract.McpInstallationInput) return ?shapes.McpInstallationTarget;
        if (T == contract.FileDeliveryInput) return shapes.FileDeliveryRoot;
        if (T == ?contract.FileDeliveryInput) return ?shapes.FileDeliveryRoot;
        if (T == contract.VideoGenerationRunInput) return shapes.VideoGenerationBinding;
        if (T == ?contract.VideoGenerationRunInput) return ?shapes.VideoGenerationBinding;

        // Types whose plain-data mirror `shapes.zig` already defines.
        if (T == surface.SessionOpenOptions) return shapes.SessionOpenOptions;
        if (T == surface.SessionRestoreOptions) return shapes.SessionRestoreOptions;
        if (T == surface.CloseOutcome) return shapes.CloseOutcome;
        if (T == surface.BeginRunFailure) return shapes.BeginRunFailure;
        if (T == surface.PendingUiRequest) return shapes.PendingUiRequest;
        if (T == surface.McpActivationOutcome) return shapes.McpActivationOutcome;
        if (T == ?surface.ImageGenerationRunInput) return ?shapes.ImageGenerationBinding;
        if (T == surface.ImageGenerationRunInput) return shapes.ImageGenerationBinding;
        if (T == control.TerminalResult) return shapes.TerminalResult;
        if (T == control.CompactTerminalResult) return shapes.CompactTerminalResult;
        if (T == catalog.Acquisition) return shapes.CatalogAcquisition;
        if (T == catalog.Query) return shapes.CatalogQuery;
        if (T == catalog.Projection) return shapes.CatalogProjection;
        if (T == checkpoint.Outcome) return shapes.CheckpointOutcome;
        if (T == port.SessionRoute) return shapes.SessionRoute;
        if (T == port.SessionRestoreRoute) return shapes.SessionRestoreRoute;
        if (T == port.BeginRunOutcome) return shapes.BeginRunOutcome;
        if (T == port.SkillRestoreBorrow) return shapes.SkillRestoreBorrow;
        if (T == port.SessionRestoreInputs) return shapes.SessionRestoreInputs;
        // Across the link the Runtime is the link, so naming it carries nothing.
        if (T == port.RuntimePort) return void;

        // Optionals and errors unwrap to the same question one level down.
        switch (@typeInfo(T)) {
            .optional => |info| {
                const inner = Wire(info.child);
                return if (inner == void) void else ?inner;
            },
            .error_union => @compileError(
                "strip the error union before asking for a wire type: " ++ @typeName(T),
            ),
            else => {},
        }

        // Everything else must already be carriable, and says so loudly if not.
        payload.requireStructural(T);
        return T;
    }
}

/// `Error!T` becomes `T`. The error travels as its registered number, which
/// `error_code.zig` owns, so it is not part of the payload.
pub fn Payload(comptime T: type) type {
    comptime {
        return switch (@typeInfo(T)) {
            .error_union => |info| info.payload,
            else => T,
        };
    }
}

/// The request payload for one vtable method: its parameters after the
/// context, each mapped through `Wire`, with the dropped ones left out.
///
/// A tuple rather than a named struct, because the parameters are already
/// positional and inventing names would be a second place for them to drift.
pub fn Request(comptime Fn: type) type {
    comptime {
        var types: []const type = &.{};
        for (@typeInfo(Fn).@"fn".params, 0..) |param, position| {
            if (position == 0) continue; // the context pointer
            const Mapped = Wire(param.type.?);
            if (Mapped == void) continue;
            types = types ++ [_]type{Mapped};
        }
        return std.meta.Tuple(types);
    }
}

/// The response payload for one vtable method.
pub fn Response(comptime Fn: type) type {
    comptime {
        return Wire(Payload(@typeInfo(Fn).@"fn".return_type.?));
    }
}

comptime {
    @setEvalBranchQuota(1_000_000);
    // Every method that travels as a call has a request and a response the
    // wire can carry. This is what lets the stubs be generated rather than
    // written: an unshippable payload fails here, not at the first call.
    //
    // `stream` methods are skipped because they are not calls. The derivation
    // found that out the hard way and it is worth recording: `take_event`
    // returns an `OwnedCoreEvent`, which owns its JSON through an allocator
    // and holds parsed pointers into it, so it could never have been a
    // response. The event's own bytes travel as `event` frames and the pump
    // builds that value locally -- which is what the classification already
    // said, now checked rather than trusted.
    for (method.entries) |entry| {
        if (entry.transport == .stream) continue;
        switch (entry.owner) {
            inline else => |tag| {
                const Fn = @typeInfo(@FieldType(tag.VTable(), entry.name)).pointer.child;
                payload.requireStructural(Request(Fn));
                const Out = Response(Fn);
                if (Out != void) payload.requireStructural(Out);
            },
        }
    }
}

const testing = std.testing;

test "a request drops what must not travel and keeps what must" {
    // `copy_pending_ui_request` takes an allocator, which is the caller's and
    // is used on the response: the request carries nothing but the handle the
    // method is called on, so its payload is empty.
    const Copy = @typeInfo(@FieldType(port.SessionPort.VTable, "copy_pending_ui_request")).pointer.child;
    try testing.expectEqual(@as(usize, 0), @typeInfo(Request(Copy)).@"struct".fields.len);

    // `set_model` takes a model name, which does travel.
    const SetModel = @typeInfo(@FieldType(port.SessionPort.VTable, "set_model")).pointer.child;
    const set_model_fields = @typeInfo(Request(SetModel)).@"struct".fields;
    try testing.expectEqual(@as(usize, 1), set_model_fields.len);
    try testing.expectEqual([]const u8, set_model_fields[0].type);
}

test "a borrowed handle becomes an id, not a pointer" {
    const Refresh = @typeInfo(@FieldType(port.SessionPort.VTable, "refresh_skill_catalog")).pointer.child;
    const fields = @typeInfo(Request(Refresh)).@"struct".fields;
    // The lease and the policy, with the lease as an id.
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqual(handle_table.Id, fields[0].type);
    try testing.expectEqual(contract.SkillPolicyInput, fields[1].type);
}

test "a byte sink becomes a descriptor and the bytes stay put" {
    const Export = @typeInfo(@FieldType(port.SessionPort.VTable, "export_checkpoint")).pointer.child;
    const fields = @typeInfo(Request(Export)).@"struct".fields;
    var saw_destination = false;
    inline for (fields) |field| {
        if (field.type == shapes.CheckpointDestination) saw_destination = true;
        // Nothing in the request is a callback or a pointer into the caller.
        try testing.expectEqual(
            payload.Classification.structural,
            payload.classify(field.type),
        );
    }
    try testing.expect(saw_destination);
}

test "an error union never reaches the payload" {
    const SetModel = @typeInfo(@FieldType(port.SessionPort.VTable, "set_model")).pointer.child;
    // `Error!void` has a void payload, so the response carries nothing: the
    // error itself travels as its registered number.
    try testing.expectEqual(void, Response(SetModel));
}

test "every registered method has a carriable request and response" {
    // The comptime block above already failed the build if not. This records
    // the count so the claim is visible in the suite rather than only in a
    // compile that happened to succeed.
    var methods: usize = 0;
    inline for (comptime std.enums.values(method.Owner)) |owner| {
        methods += @typeInfo(owner.VTable()).@"struct".fields.len;
    }
    try testing.expectEqual(method.entries.len, methods);
}
