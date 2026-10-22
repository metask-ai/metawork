//! Bounded cursor over the exact text and strings that a preview may publish.
//! The Product owner supplies current credential matching for each borrowed
//! chunk; no credential or authority is captured here.
const std = @import("std");
const contract = @import("product_document_preview_contract");
pub const step_bytes = 64 * 1024;
pub const Cursor = struct {
    source_done: bool = false,
    sheet: usize = 0,
    cell: usize = 0,
    field: u3 = 5, // sheet name, then formula/value/display/format/alignment
    offset: usize = 0,
    finished: bool = false,

    /// Null means this step exhausted its budget or the whole scan finished.
    /// Check finished before publishing; a nonempty overlap preserves matches
    /// crossing source chunks. Empty/null fields still consume work budget.
    pub fn next(self: *Cursor, material: contract.Material, overlap: usize, budget: *usize) !?[]const u8 {
        if (overlap >= step_bytes / 2) return error.CredentialCapacity;
        while (!self.finished and budget.* != 0) {
            const text: []const u8 = if (!self.source_done) material.source_text else grid: {
                const grid = material.grid orelse {
                    self.finished = true;
                    return null;
                };
                if (self.sheet >= grid.sheets.len) {
                    self.finished = true;
                    return null;
                }
                const sheet = grid.sheets[self.sheet];
                if (self.field == 5) break :grid sheet.name;
                if (self.cell >= sheet.cells.len) {
                    self.nextSheet();
                    budget.* -= 1;
                    continue;
                }
                const cell = sheet.cells[self.cell];
                break :grid switch (self.field) {
                    0 => cell.formula orelse "",
                    1 => if (cell.value) |value| value.text else "",
                    2 => cell.display,
                    3 => cell.formatCode,
                    4 => cell.alignment orelse "",
                    else => unreachable,
                };
            };
            if (self.offset >= text.len) {
                self.advance();
                budget.* -= 1;
                continue;
            }
            const begin = self.offset -| overlap;
            if (budget.* <= self.offset - begin) {
                budget.* = 0;
                return null;
            }
            const end = begin + @min(text.len - begin, budget.*);
            self.offset = end;
            budget.* -= end - begin;
            return text[begin..end];
        }
        return null;
    }
    fn advance(self: *Cursor) void {
        self.offset = 0;
        if (!self.source_done) {
            self.source_done = true;
            return;
        }
        if (self.field == 5) {
            self.field = 0;
            return;
        }
        if (self.field < 4) {
            self.field += 1;
            return;
        }
        self.field = 0;
        self.cell += 1;
    }
    fn nextSheet(self: *Cursor) void {
        self.sheet += 1;
        self.cell = 0;
        self.field = 5;
        self.offset = 0;
    }
};

const manifest: contract.Manifest = .{ .schema = 1, .format = .docx, .sourceText = .{ .file = "source-text.txt", .bytes = 1, .sha256 = "1" ** 64 }, .textScope = "fixture", .omissions = &.{}, .kind = .pages };
test "source scan preserves a known credential crossing a step boundary" {
    var text: [step_bytes + 30]u8 = @splat('x');
    const secret = "cross-step-secret";
    @memcpy(text[step_bytes - 7 ..][0..secret.len], secret);
    const material: contract.Material = .{ .source = .{ .size_bytes = 1, .sha256 = @splat(1) }, .manifest = &manifest, .grid = null, .source_text = &text };
    var cursor: Cursor = .{};
    var steps: usize = 0;
    var found = false;
    while (!cursor.finished) {
        var budget: usize = step_bytes;
        while (try cursor.next(material, secret.len - 1, &budget)) |chunk| {
            found = found or std.mem.indexOf(u8, chunk, secret) != null;
        }
        steps += 1;
    }
    try std.testing.expect(found and steps >= 2);
    var budget: usize = step_bytes;
    try std.testing.expectError(error.CredentialCapacity, cursor.next(material, step_bytes / 2, &budget));
}
test "grid scan includes projected names formulas values display and formatting" {
    var cells = [_]contract.Cell{.{ .row = 1, .column = 1, .formula = "formula-secret", .value = .{ .kind = .text, .text = "value-secret" }, .display = "display-secret", .formatCode = "format-secret", .formatSupported = false, .bold = false, .italic = false, .alignment = "alignment-secret" }};
    var sheets = [_]contract.Sheet{.{ .id = "1", .name = "name-secret", .hidden = false, .rows = 1, .columns = 1, .cells = &cells }};
    const grid: contract.Grid = .{ .schema = 1, .calculation = "saved_values_only", .sheets = &sheets };
    const material: contract.Material = .{ .source = .{ .size_bytes = 1, .sha256 = @splat(1) }, .manifest = &manifest, .grid = &grid, .source_text = "source" };
    var cursor: Cursor = .{};
    var found: usize = 0;
    while (!cursor.finished) {
        var budget: usize = 64;
        while (try cursor.next(material, 5, &budget)) |chunk| if (std.mem.endsWith(u8, chunk, "-secret")) {
            found += 1;
        };
    }
    try std.testing.expectEqual(6, found);
}
