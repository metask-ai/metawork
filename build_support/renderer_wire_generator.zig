//! Emits only the existing public wire structures selected below.
const std = @import("std");
const snapshot = @import("snapshot_contract");
const task_view = @import("task_view_contract");
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("// Generated from Host wire types. Do not edit.\n");
    try writer.writeAll("import { object, positiveWireId, positiveNumber, enumValue } from './wire-codec.ts';\n");
    try writer.print("export const maxSnapshotBytes = {d};\nexport const maxSnapshotChunkBytes = {d};\n", .{ snapshot.max_snapshot_bytes, snapshot.chunk_bytes });
    try writer.print("export const maxSnapshotPreparationSteps = {d};\n", .{snapshot.max_preparation_steps});
    try emitEnumValues(task_view.ApprovalFailureReason, "approvalFailureReasons", writer);
    try emit(snapshot.SnapshotPreparing, "SnapshotPreparing", writer);
    try emit(snapshot.SnapshotDescriptor, "SnapshotDescriptor", writer);
    try emit(task_view.ApprovalResult, "TaskApprovalResultWire", writer);
    try writer.flush();
}

fn emitEnumValues(comptime T: type, comptime name: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("export const {s} = [", .{name});
    inline for (@typeInfo(T).@"enum".fields) |field|
        try writer.print("'{s}',", .{field.name});
    try writer.writeAll("] as const;\n");
}

fn tsType(comptime T: type, writer: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (!@hasDecl(T, "wire_scalar")) {
                if (@hasDecl(T, "jsonStringify")) @compileError("Custom JSON encoding requires an explicit wire declaration");
                try writer.writeAll("{\n");
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    try writer.print("{s}: ", .{field.name});
                    try tsType(field.type, writer);
                    try writer.writeAll(";\n");
                }
                try writer.writeAll("}");
            } else if (comptime std.mem.eql(u8, T.wire_scalar, "positiveWireId")) {
                try writer.writeAll("string");
            } else if (comptime std.mem.eql(u8, T.wire_scalar, "positiveNumber")) {
                try writer.writeAll("number");
            } else @compileError("Unsupported wire scalar");
        },
        .@"enum" => |info| {
            inline for (info.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(" | ");
                try writer.print("'{s}'", .{field.name});
            }
        },
        .optional => |info| {
            try tsType(info.child, writer);
            try writer.writeAll(" | null");
        },
        else => @compileError("Unsupported wire type"),
    }
}

fn decode(comptime T: type, comptime value: []const u8, comptime path: []const u8, writer: *std.Io.Writer) anyerror!void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasDecl(T, "wire_scalar")) {
                try writer.print("{s}({s}, {s})", .{ T.wire_scalar, value, path });
            } else {
                try writer.writeAll("((value: unknown, path: string) => {\n");
                try decodeFields(T, writer);
                try writer.print("}})({s}, {s})", .{ value, path });
            }
        },
        .@"enum" => |info| {
            try writer.print("enumValue({s}, {s}, [", .{ value, path });
            inline for (info.fields) |field| try writer.print("'{s}',", .{field.name});
            try writer.writeAll("] as const)");
        },
        .optional => |info| {
            try writer.print("{s} === null ? null : ", .{value});
            try decode(info.child, value, path, writer);
        },
        else => @compileError("Unsupported wire decoder"),
    }
}

fn emit(comptime T: type, comptime name: []const u8, writer: *std.Io.Writer) !void {
    try writer.print("export type {s} = ", .{name});
    try tsType(T, writer);
    try writer.print(";\nexport function decode{s}(value: unknown, path: string): {s} {{\n", .{ name, name });
    try decodeFields(T, writer);
    try writer.writeAll("}\n");
}

fn decodeFields(comptime T: type, writer: *std.Io.Writer) anyerror!void {
    const fields = @typeInfo(T).@"struct".fields;
    try writer.writeAll("const item = object(value, path, [");
    inline for (fields) |field| try writer.print("'{s}',", .{field.name});
    try writer.writeAll("]);\nreturn {\n");
    inline for (fields) |field| {
        try writer.print("{s}: ", .{field.name});
        try decode(field.type, "item." ++ field.name, "path + '." ++ field.name ++ "'", writer);
        try writer.writeAll(",\n");
    }
    try writer.writeAll("};\n");
}
