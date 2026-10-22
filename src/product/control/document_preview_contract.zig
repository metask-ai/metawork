//! Typed borrowed document material and an owned Application effect. No
//! filesystem root, Task pointer, credential or Renderer grant crosses it.
const std = @import("std");

pub const Format = enum { docx, pptx, xlsx };
pub const Kind = enum { pages, grid };
pub const File = struct { file: []const u8, bytes: u32, sha256: []const u8 };
pub const Page = struct { file: []const u8, bytes: u32, sha256: []const u8, width: u32, height: u32 };
pub const Manifest = struct {
    schema: u8,
    format: Format,
    sourceText: File,
    textScope: []const u8,
    omissions: []const []const u8,
    kind: Kind,
    pages: ?[]Page = null,
    grid: ?File = null,
    sheetCount: ?u16 = null,
};
pub const Value = struct { kind: enum { number, text, boolean, date, duration, @"error" }, text: []const u8 };
pub const Cell = struct {
    row: u32,
    column: u16,
    formula: ?[]const u8,
    value: ?Value,
    display: []const u8,
    formatCode: []const u8,
    formatSupported: bool,
    bold: bool,
    italic: bool,
    alignment: ?[]const u8,
};
pub const Sheet = struct { id: []const u8, name: []const u8, hidden: bool, rows: u32, columns: u16, cells: []Cell };
pub const Grid = struct { schema: u8, calculation: []const u8, sheets: []Sheet };
pub const Region = struct { sheet: u16, row: u32, column: u16, rows: u16, columns: u16 };

pub const Material = struct {
    manifest: *const Manifest,
    grid: ?*const Grid,
    source_text: []const u8,
};
pub const Request = union(enum) { page: usize, region: Region };
pub const Read = struct {
    allocator: std.mem.Allocator,
    value: union(enum) { page: []u8, region: []Cell },
    pub fn deinit(self: *Read) void {
        switch (self.value) {
            .page => |bytes| {
                std.crypto.secureZero(u8, bytes);
                self.allocator.free(bytes);
            },
            .region => |cells| self.allocator.free(cells),
        }
        self.* = undefined;
    }
};
/// Main serializes use and calls material only after worker completion. All
/// borrowed strings expire at cleanup. cancel is thread-safe and permanent.
/// prepare/read/cleanup run on a worker; release runs on main after successful
/// cleanup, or before the fresh effect was ever scheduled. A failed cleanup
/// retains the effect and physical resource.
pub const Owned = struct {
    context: *anyopaque,
    prepare_fn: *const fn (*anyopaque) anyerror!void,
    material_fn: *const fn (*anyopaque) anyerror!Material,
    read_fn: *const fn (*anyopaque, Request) anyerror!Read,
    cancel_fn: *const fn (*anyopaque) void,
    cleanup_fn: *const fn (*anyopaque) anyerror!void,
    release_fn: *const fn (*anyopaque) void,
};
