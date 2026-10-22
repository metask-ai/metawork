//! Application-owned prepared document resources. The caller transfers an
//! already acquired current-component lease and serializes worker operations.
//! No Task pointer, credential, Renderer grant or persistent version reference
//! lives here. Product must authorize and scan content before publishing it.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("office_process");
const image = @import("image_container");
const source_file = @import("app_output_file");

pub const max_source_bytes = 100 * 1024 * 1024;
pub const max_text_bytes = 4 * 1024 * 1024;
pub const max_grid_bytes = 8 * 1024 * 1024;
pub const max_page_bytes = 10 * 1024 * 1024;
pub const max_pages_bytes = 64 * 1024 * 1024;
pub const max_pages = 100;
pub const max_cells = 100_000;
const namespace = "pv";
// The pinned engine appends registry and operation suffixes below this root.
// Keep those within its Windows legacy-path limit; no external temp fallback.
pub const max_root_windows_units = 120;
const contract = @import("product_document_preview_contract");
pub const Format = contract.Format;
pub const Kind = contract.Kind;
pub const File = contract.File;
pub const Page = contract.Page;
pub const Manifest = contract.Manifest;
pub const Value = contract.Value;
pub const Cell = contract.Cell;
pub const Sheet = contract.Sheet;
pub const Grid = contract.Grid;
pub const Region = contract.Region;

/// Narrow owned lease from Application's validated component registry. Init
/// consumes it only on success. Release runs on main after physical cleanup.
pub const Component = struct {
    root: []const u8,
    identity: [32]u8,
    context: *anyopaque,
    release_fn: *const fn (*anyopaque) void,
};
pub const Input = struct { root: []const u8, relative: []const u8, expected: source_file.Inspection };
const State = enum { fresh, prepared, failed, cleaned, poisoned };
const Root = struct {
    parent: std.Io.Dir,
    directory: ?std.Io.Dir,
    identity: ?std.Io.File.Stat,
    parent_identity: std.Io.File.Stat,
    path: []u8,
};

pub const Resource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread: std.Thread.Id,
    environment: *const std.process.Environ.Map,
    component: Component,
    data_root: []u8,
    source: Input,
    operation: [16]u8,
    name: [32]u8,
    format: Format,
    state: State = .fresh,
    root: ?Root = null,
    manifest: ?std.json.Parsed(Manifest) = null,
    grid: ?std.json.Parsed(Grid) = null,
    source_text: []u8 = &.{},

    /// Main only; allocation and pure validation, never filesystem/process IO.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, main_thread: std.Thread.Id, environment: *const std.process.Environ.Map, data_root: []const u8, component: Component, input: Input, operation: [16]u8) !Resource {
        if (std.Thread.getCurrentId() != main_thread) return error.WrongPreviewThread;
        try source_file.validatePath(input.relative);
        for ([_][]const u8{ data_root, component.root, input.root }) |path|
            if (!validRoot(path)) return error.InvalidPreviewRoot;
        if (input.expected.size_bytes == 0 or input.expected.size_bytes > max_source_bytes or
            std.mem.allEqual(u8, &input.expected.sha256, 0) or
            std.mem.allEqual(u8, &component.identity, 0) or std.mem.allEqual(u8, &operation, 0))
            return error.InvalidPreviewInput;
        const extension = std.fs.path.extension(input.relative);
        const format: Format = if (std.ascii.eqlIgnoreCase(extension, ".docx")) .docx else if (std.ascii.eqlIgnoreCase(extension, ".pptx")) .pptx else if (std.ascii.eqlIgnoreCase(extension, ".xlsx")) .xlsx else return error.UnsupportedPreview;
        const data = try allocator.dupe(u8, data_root);
        errdefer allocator.free(data);
        const component_root = try allocator.dupe(u8, component.root);
        errdefer allocator.free(component_root);
        const source_root = try allocator.dupe(u8, input.root);
        errdefer allocator.free(source_root);
        const relative = try allocator.dupe(u8, input.relative);
        return .{ .allocator = allocator, .io = io, .main_thread = main_thread, .environment = environment, .component = .{ .root = component_root, .identity = component.identity, .context = component.context, .release_fn = component.release_fn }, .data_root = data, .source = .{ .root = source_root, .relative = relative, .expected = input.expected }, .operation = operation, .name = std.fmt.bytesToHex(operation, .lower), .format = format };
    }

    /// Transfer into a narrow owned worker effect. Failure leaves self owned
    /// by the caller; success invalidates self and keeps the same component pin.
    pub fn intoOwned(self: *Resource) !contract.Owned {
        if (std.Thread.getCurrentId() != self.main_thread) return error.WrongPreviewThread;
        if (self.state != .fresh) return error.InvalidPreviewState;
        const holder = try self.allocator.create(OwnedResource);
        holder.* = .{ .resource = self.* };
        self.* = undefined;
        return .{ .context = holder, .prepare_fn = OwnedResource.prepare, .material_fn = OwnedResource.material, .read_fn = OwnedResource.read, .cancel_fn = OwnedResource.cancel, .cleanup_fn = OwnedResource.cleanup, .release_fn = OwnedResource.release };
    }

    pub fn prepare(self: *Resource, cancellation: *const process.Cancellation) !void {
        try self.worker();
        if (self.state != .fresh) return error.InvalidPreviewState;
        self.state = .failed;
        try cancelled(cancellation);
        try self.createRoot();
        const root = &self.root.?;
        const input_name = try std.fmt.allocPrint(self.allocator, "input.{s}", .{@tagName(self.format)});
        defer self.allocator.free(input_name);
        {
            var file = try root.directory.?.createFile(self.io, input_name, .{ .read = true, .exclusive = true });
            defer file.close(self.io);
            if (builtin.os.tag == .windows) file.flags.nonblocking = true;
            try source_file.copyVerified(self.io, self.sourceRequest(), &cancellation.requested, self.source.expected, file);
            try file.sync(self.io);
        }
        const input_path = try std.fs.path.join(self.allocator, &.{ root.path, input_name });
        defer self.allocator.free(input_path);
        const output_path = try std.fs.path.join(self.allocator, &.{ root.path, "prepared" });
        defer self.allocator.free(output_path);
        var output = switch (process.run(self.allocator, self.io, self.component.root, .{ .preview = .{ .input = input_path, .output = output_path } }, .{ .parent_environment = self.environment, .scratch_root = root.path, .operation_identity = self.operation }, 120_000, cancellation)) {
            .completed => |result| result,
            .failed => |failure| {
                if (!failure.quiescent) self.state = .poisoned;
                return if (failure.quiescent) failure.cause else error.PreviewRestartRequired;
            },
        };
        defer output.deinit(self.allocator);
        if (output.term != .exited or output.term.exited != 0) return error.PreviewPreparationFailed;
        try self.verifyRoot();
        const frozen = try source_file.inspect(self.io, .{ .workspace_root = root.path, .relative_path = input_name, .main_thread_id = self.main_thread }, &cancellation.requested);
        if (frozen.size_bytes != self.source.expected.size_bytes or !std.mem.eql(u8, &frozen.sha256, &self.source.expected.sha256)) return error.PreviewResourceChanged;
        try self.checkSource(cancellation);
        const directory = try root.directory.?.openDir(self.io, "prepared", .{ .follow_symlinks = false });
        defer directory.close(self.io);
        const bytes = try self.readFile(directory, "preview.json", 128 * 1024, null);
        defer self.allocator.free(bytes);
        self.manifest = try std.json.parseFromSlice(Manifest, self.allocator, bytes, .{
            .allocate = .alloc_always,
            .max_value_len = 32 * 1024,
            .duplicate_field_behavior = .@"error",
        });
        const metadata = &self.manifest.?.value;
        try validateManifest(metadata, self.format);
        self.source_text = try self.readFile(directory, "source-text.txt", max_text_bytes, metadata.sourceText);
        if (!std.unicode.utf8ValidateSlice(self.source_text)) return error.InvalidPreviewText;
        if (metadata.kind == .grid) {
            const grid_bytes = try self.readFile(directory, "grid.json", max_grid_bytes, metadata.grid.?);
            defer {
                std.crypto.secureZero(u8, grid_bytes);
                self.allocator.free(grid_bytes);
            }
            self.grid = try std.json.parseFromSlice(Grid, self.allocator, grid_bytes, .{
                .allocate = .alloc_always,
                .max_value_len = 32 * 1024,
                .duplicate_field_behavior = .@"error",
            });
            try validateGrid(&self.grid.?.value, metadata.sheetCount.?);
        } else {
            for (metadata.pages.?) |page_metadata| {
                try cancelled(cancellation);
                const pixels = try self.checkedPage(directory, page_metadata);
                self.allocator.free(pixels);
            }
        }
        try self.checkSource(cancellation);
        self.state = .prepared;
    }

    /// Borrowed until cleanup. Product scans these and projected grid strings
    /// under the current security epoch; raw text never goes to Renderer.
    pub fn prepared(self: *const Resource) !*const Manifest {
        if (self.state != .prepared) return error.InvalidPreviewState;
        return &self.manifest.?.value;
    }

    pub fn page(self: *Resource, index: usize, cancellation: *const process.Cancellation) ![]u8 {
        try self.worker();
        const metadata = try self.prepared();
        if (metadata.kind != .pages or index >= metadata.pages.?.len) return error.InvalidPreviewRegion;
        try self.checkSource(cancellation);
        try self.verifyRoot();
        const directory = try self.root.?.directory.?.openDir(self.io, "prepared", .{ .follow_symlinks = false });
        defer directory.close(self.io);
        const bytes = try self.checkedPage(directory, metadata.pages.?[index]);
        errdefer self.allocator.free(bytes);
        try self.checkSource(cancellation);
        return bytes;
    }

    /// Returns only existing cells in a bounded requested rectangle. Empty
    /// cells remain implicit. Strings borrow the once-parsed grid until cleanup.
    pub fn region(self: *Resource, request: Region, cancellation: *const process.Cancellation) ![]Cell {
        try self.worker();
        _ = try self.prepared();
        if (self.grid == null or request.sheet == 0 or request.sheet > self.grid.?.value.sheets.len or
            request.row == 0 or request.column == 0 or request.rows == 0 or request.columns == 0 or
            request.rows > 100 or request.columns > 20 or @as(u32, request.rows) * request.columns > 500 or
            request.row + @as(u64, request.rows) > 10_001 or @as(u32, request.column) + request.columns > 257)
            return error.InvalidPreviewRegion;
        try self.checkSource(cancellation);
        try self.verifyRoot();
        var cells: std.ArrayList(Cell) = .empty;
        errdefer cells.deinit(self.allocator);
        for (self.grid.?.value.sheets[request.sheet - 1].cells) |cell| {
            if (cell.row >= request.row and cell.row < request.row + request.rows and
                cell.column >= request.column and cell.column < request.column + request.columns)
                try cells.append(self.allocator, cell);
        }
        try self.checkSource(cancellation);
        return cells.toOwnedSlice(self.allocator);
    }

    /// Worker only. An uncertain process scope cannot be retried into cleanup
    /// authority in this process. A normal cleanup acquires a sealed operation
    /// reservation and verifies both the owned directory and its current name.
    pub fn cleanup(self: *Resource) !void {
        try self.worker();
        if (self.state == .poisoned) return error.PreviewRestartRequired;
        self.state = .failed;
        if (self.root) |*root| {
            try self.verifyRoot();
            const cancellation: process.Cancellation = .{};
            var scope = process.ResourceScope.reserveOperationDeletion(self.io, self.operation, &cancellation) catch {
                self.state = .poisoned;
                return error.PreviewRestartRequired;
            };
            defer scope.deinit();
            scope.settle(self.io) catch {
                self.state = .poisoned;
                return error.PreviewRestartRequired;
            };
            if (root.directory) |directory| directory.close(self.io);
            root.directory = null;
            try root.parent.deleteTree(self.io, &self.name);
            root.parent.close(self.io);
            self.allocator.free(root.path);
            self.root = null;
        }
        self.clearPrepared();
        self.state = .cleaned;
    }

    /// Main only, after physical cleanup. The lease is never consumed on a
    /// failed release attempt, including an uncertain/poisoned process scope.
    pub fn deinit(self: *Resource) !void {
        if (std.Thread.getCurrentId() != self.main_thread) return error.WrongPreviewThread;
        if (self.root != null or self.state == .poisoned) return error.PreviewResourcesOutstanding;
        self.clearPrepared();
        self.component.release_fn(self.component.context);
        self.allocator.free(self.component.root);
        self.allocator.free(self.source.root);
        self.allocator.free(self.source.relative);
        self.allocator.free(self.data_root);
        self.* = undefined;
    }

    fn worker(self: *const Resource) !void {
        if (std.Thread.getCurrentId() == self.main_thread) return error.MainThreadFileEffect;
    }
    fn sourceRequest(self: *const Resource) source_file.Request {
        return .{ .workspace_root = self.source.root, .relative_path = self.source.relative, .main_thread_id = self.main_thread };
    }
    fn checkSource(self: *const Resource, cancellation: *const process.Cancellation) !void {
        const actual = try source_file.inspect(self.io, self.sourceRequest(), &cancellation.requested);
        if (actual.size_bytes != self.source.expected.size_bytes or !std.mem.eql(u8, &actual.sha256, &self.source.expected.sha256))
            return error.OutputChanged;
    }
    fn createRoot(self: *Resource) !void {
        const data = try source_file.openRoot(self.io, self.data_root);
        defer data.close(self.io);
        const parent = try data.createDirPathOpen(self.io, namespace, .{
            .open_options = .{ .follow_symlinks = false },
            .permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700),
        });
        var transferred = false;
        errdefer if (!transferred) parent.close(self.io);
        const path = try std.fs.path.join(self.allocator, &.{ self.data_root, namespace, &self.name });
        errdefer if (!transferred) self.allocator.free(path);
        if (builtin.os.tag == .windows) {
            const wide = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, path);
            defer self.allocator.free(wide);
            if (wide.len > max_root_windows_units) return error.PreviewPathTooLong;
        }
        const parent_identity = try parent.stat(self.io);
        if (parent_identity.kind != .directory) return error.PreviewRootChanged;
        try parent.createDir(self.io, &self.name, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        // Ownership is established before any later fallible open/stat. Keep a
        // failed root for explicit cleanup rather than silently discarding it.
        self.root = .{ .parent = parent, .directory = null, .path = path, .identity = null, .parent_identity = parent_identity };
        transferred = true;
        const directory = parent.openDir(self.io, &self.name, .{ .follow_symlinks = false }) catch |failure| {
            self.state = .poisoned;
            return failure;
        };
        self.root.?.directory = directory;
        self.root.?.identity = directory.stat(self.io) catch |failure| {
            self.state = .poisoned;
            return failure;
        };
    }
    fn verifyRoot(self: *Resource) !void {
        const root = self.root orelse return error.InvalidPreviewState;
        const identity = root.identity orelse return error.PreviewRestartRequired;
        const parent_path = try std.fs.path.join(self.allocator, &.{ self.data_root, namespace });
        defer self.allocator.free(parent_path);
        const parent = try source_file.openRoot(self.io, parent_path);
        defer parent.close(self.io);
        if ((try parent.stat(self.io)).inode != root.parent_identity.inode) return error.PreviewRootChanged;
        const named = try root.parent.openDir(self.io, &self.name, .{ .follow_symlinks = false });
        defer named.close(self.io);
        const named_identity = try named.stat(self.io);
        if (named_identity.kind != .directory or named_identity.inode != identity.inode) return error.PreviewRootChanged;
        if (root.directory) |directory| {
            const opened_identity = try directory.stat(self.io);
            if (opened_identity.kind != .directory or opened_identity.inode != identity.inode) return error.PreviewRootChanged;
        }
    }
    fn readFile(self: *Resource, directory: std.Io.Dir, name: []const u8, maximum: usize, expected: ?File) ![]u8 {
        var file = try directory.openFile(self.io, name, .{ .follow_symlinks = false, .allow_directory = false, .resolve_beneath = true });
        defer file.close(self.io);
        if (builtin.os.tag == .windows) file.flags.nonblocking = true;
        const before = try file.stat(self.io);
        if (before.kind != .file or before.size == 0 or before.size > maximum) return error.PreviewResourceLimit;
        const bytes = try self.allocator.alloc(u8, @intCast(before.size));
        errdefer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.PreviewResourceChanged;
        const after = try file.stat(self.io);
        if (!stable(before, after)) return error.PreviewResourceChanged;
        var named = try directory.openFile(self.io, name, .{ .follow_symlinks = false, .allow_directory = false });
        defer named.close(self.io);
        if (builtin.os.tag == .windows) named.flags.nonblocking = true;
        if (!stable(after, try named.stat(self.io))) return error.PreviewResourceChanged;
        if (expected) |value| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const expected_digest = try hexDigest(value.sha256);
            if (value.bytes != bytes.len or !std.mem.eql(u8, &expected_digest, &digest))
                return error.PreviewResourceDigest;
        }
        return bytes;
    }
    fn checkedPage(self: *Resource, directory: std.Io.Dir, metadata: Page) ![]u8 {
        const bytes = try self.readFile(directory, metadata.file, max_page_bytes, .{ .file = metadata.file, .bytes = metadata.bytes, .sha256 = metadata.sha256 });
        errdefer self.allocator.free(bytes);
        const info = try image.inspect(bytes);
        if (info.format != .png or info.animated or info.trailingBytes(bytes.len) != 0 or
            info.width != metadata.width or info.height != metadata.height or info.pixels() > 4_000_000)
            return error.InvalidPreviewImage;
        return bytes;
    }
    fn clearPrepared(self: *Resource) void {
        std.crypto.secureZero(u8, self.source_text);
        self.allocator.free(self.source_text);
        self.source_text = &.{};
        if (self.grid) |*parsed| {
            for (parsed.value.sheets) |sheet| {
                for (sheet.cells) |cell| {
                    for ([_]?[]const u8{ cell.formula, cell.display, cell.formatCode, cell.alignment }) |value| if (value) |text| std.crypto.secureZero(u8, @constCast(text));
                    if (cell.value) |value| std.crypto.secureZero(u8, @constCast(value.text));
                }
                std.crypto.secureZero(u8, @constCast(sheet.name));
            }
            parsed.deinit();
        }
        self.grid = null;
        if (self.manifest) |*parsed| parsed.deinit();
        self.manifest = null;
    }
};

fn validRoot(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) return false;
    for (path) |byte| if (std.ascii.isControl(byte)) return false;
    return true;
}
fn cancelled(cancellation: *const process.Cancellation) !void {
    if (cancellation.requested.load(.acquire)) return error.Cancelled;
}
fn stable(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.inode == b.inode and a.size == b.size and std.meta.eql(a.mtime, b.mtime) and std.meta.eql(a.ctime, b.ctime);
}
fn hexDigest(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidPreviewManifest;
    for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidPreviewManifest;
    var result: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, text);
    if (std.mem.allEqual(u8, &result, 0)) return error.InvalidPreviewManifest;
    return result;
}
fn validateManifest(value: *const Manifest, format: Format) !void {
    if (value.schema != 1 or value.format != format or value.omissions.len > 16 or
        !std.mem.eql(u8, value.textScope, "ooxml_xml_text_and_attributes_without_ocr") or
        !std.mem.eql(u8, value.sourceText.file, "source-text.txt") or value.sourceText.bytes == 0 or value.sourceText.bytes > max_text_bytes)
        return error.InvalidPreviewManifest;
    _ = try hexDigest(value.sourceText.sha256);
    const known = [_][]const u8{ "external_hyperlinks", "merged_cells", "conditional_formatting", "data_validation", "charts", "images", "pivot_tables", "comments" };
    for (value.omissions, 0..) |item, index| {
        var found = false;
        for (known) |allowed| if (std.mem.eql(u8, item, allowed)) {
            found = true;
        };
        if (!found) return error.InvalidPreviewManifest;
        for (value.omissions[0..index]) |before| if (std.mem.eql(u8, before, item)) return error.InvalidPreviewManifest;
    }
    if (format == .xlsx) {
        if (value.kind != .grid or value.pages != null or value.grid == null or value.sheetCount == null or value.sheetCount.? > 64 or
            !std.mem.eql(u8, value.grid.?.file, "grid.json") or value.grid.?.bytes == 0 or value.grid.?.bytes > max_grid_bytes)
            return error.InvalidPreviewManifest;
        _ = try hexDigest(value.grid.?.sha256);
    } else {
        if (value.kind != .pages or value.grid != null or value.sheetCount != null or value.pages == null or value.pages.?.len == 0 or value.pages.?.len > max_pages)
            return error.InvalidPreviewManifest;
        var total: u64 = 0;
        for (value.pages.?, 0..) |page, index| {
            var buffer: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&buffer, "page-{d:0>4}.png", .{index + 1});
            total += page.bytes;
            if (!std.mem.eql(u8, page.file, name) or page.bytes == 0 or page.bytes > max_page_bytes or total > max_pages_bytes or
                page.width != 1280 or page.height == 0 or @as(u64, page.width) * page.height > 4_000_000)
                return error.InvalidPreviewManifest;
            _ = try hexDigest(page.sha256);
        }
    }
}
fn validateGrid(value: *const Grid, sheet_count: u16) !void {
    if (value.schema != 1 or !std.mem.eql(u8, value.calculation, "saved_values_only") or value.sheets.len != sheet_count or value.sheets.len > 64)
        return error.InvalidPreviewGrid;
    var total: usize = 0;
    for (value.sheets, 0..) |sheet, index| {
        var buffer: [8]u8 = undefined;
        if (!std.mem.eql(u8, sheet.id, try std.fmt.bufPrint(&buffer, "{d}", .{index + 1})) or
            sheet.name.len == 0 or sheet.name.len > 32 * 1024 or sheet.rows > 10_000 or sheet.columns > 256)
            return error.InvalidPreviewGrid;
        total += sheet.cells.len;
        if (total > max_cells) return error.PreviewResourceLimit;
        var position: u64 = 0;
        for (sheet.cells) |cell| {
            const next = @as(u64, cell.row) * 257 + cell.column;
            if (cell.row == 0 or cell.row > sheet.rows or cell.column == 0 or cell.column > sheet.columns or next <= position)
                return error.InvalidPreviewGrid;
            position = next;
            for ([_]?[]const u8{ cell.formula, cell.display, cell.formatCode, cell.alignment }) |text| if (text) |bytes|
                if (bytes.len > 32 * 1024 or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidPreviewGrid;
            if (cell.value) |item| if (item.text.len > 32 * 1024 or !std.unicode.utf8ValidateSlice(item.text)) return error.InvalidPreviewGrid;
        }
    }
}

test "preview metadata never turns a component filename into arbitrary path authority" {
    var pages = [_]Page{.{ .file = "page-0001.png", .bytes = 10, .sha256 = "1" ** 64, .width = 1280, .height = 1656 }};
    var metadata: Manifest = .{ .schema = 1, .format = .docx, .sourceText = .{ .file = "source-text.txt", .bytes = 1, .sha256 = "1" ** 64 }, .textScope = "ooxml_xml_text_and_attributes_without_ocr", .omissions = &.{}, .kind = .pages, .pages = &pages };
    try validateManifest(&metadata, .docx);
    pages[0].file = "../page-0001.png";
    try std.testing.expectError(error.InvalidPreviewManifest, validateManifest(&metadata, .docx));
    pages[0].file = "page-0001.png";
    pages[0].height = 10000;
    try std.testing.expectError(error.InvalidPreviewManifest, validateManifest(&metadata, .docx));
    pages[0].height = 1656;
    metadata.grid = .{ .file = "grid.json", .bytes = 1, .sha256 = "1" ** 64 };
    try std.testing.expectError(error.InvalidPreviewManifest, validateManifest(&metadata, .docx));
}

test "grid normalization rejects duplicate cells and cannot imply recalculation" {
    var cells = [_]Cell{.{ .row = 1, .column = 1, .formula = "=1+1", .value = null, .display = "", .formatCode = "General", .formatSupported = true, .bold = false, .italic = false, .alignment = null }};
    var sheets = [_]Sheet{.{ .id = "1", .name = "Sheet", .hidden = false, .rows = 1, .columns = 1, .cells = &cells }};
    var grid: Grid = .{ .schema = 1, .calculation = "saved_values_only", .sheets = &sheets };
    try validateGrid(&grid, 1);
    grid.calculation = "recalculated";
    try std.testing.expectError(error.InvalidPreviewGrid, validateGrid(&grid, 1));
    grid.calculation = "saved_values_only";
    const duplicate = [_]Cell{ cells[0], cells[0] };
    sheets[0].cells = @constCast(&duplicate);
    try std.testing.expectError(error.InvalidPreviewGrid, validateGrid(&grid, 1));
}

const OwnedResource = struct {
    resource: Resource,
    cancellation: process.Cancellation = .{},
    fn get(context: *anyopaque) *OwnedResource {
        return @ptrCast(@alignCast(context));
    }
    fn prepare(context: *anyopaque) !void {
        const self = get(context);
        try self.resource.prepare(&self.cancellation);
    }
    fn material(context: *anyopaque) !contract.Material {
        const self = get(context);
        if (std.Thread.getCurrentId() != self.resource.main_thread) return error.WrongPreviewThread;
        return .{ .manifest = try self.resource.prepared(), .grid = if (self.resource.grid) |*value| &value.value else null, .source_text = self.resource.source_text };
    }
    fn read(context: *anyopaque, request: contract.Request) !contract.Read {
        const self = get(context);
        return .{ .allocator = self.resource.allocator, .value = switch (request) {
            .page => |index| .{ .page = try self.resource.page(index, &self.cancellation) },
            .region => |region| .{ .region = try self.resource.region(region, &self.cancellation) },
        } };
    }
    fn cancel(context: *anyopaque) void {
        get(context).cancellation.requested.store(true, .release);
    }
    fn cleanup(context: *anyopaque) !void {
        try get(context).resource.cleanup();
    }
    fn release(context: *anyopaque) void {
        const self = get(context);
        const allocator = self.resource.allocator;
        // The sole caller is the lane after successful physical cleanup.
        self.resource.deinit() catch @panic("preview effect released before cleanup");
        allocator.destroy(self);
    }
};
