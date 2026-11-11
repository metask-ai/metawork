//! Workspace output effect for a streamed GenerateVideo response.
const std = @import("std");
const builtin = @import("builtin");
const agent = @import("metawork_agent");
const workspace = @import("metawork_product_workspace");
const output_file = @import("app_output_file");

pub const Output = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    main_thread_id: std.Thread.Id,
    root: []u8,

    const directory_name = "generated-videos";

    pub fn init(allocator: std.mem.Allocator, io: std.Io, main_thread_id: std.Thread.Id, authority: workspace.TaskAuthority) !Output {
        if (authority.id == 0 or authority.epoch == 0 or authority.canonical_root.len > std.Io.Dir.max_path_bytes or
            !std.fs.path.isAbsolute(authority.canonical_root) or !std.unicode.utf8ValidateSlice(authority.canonical_root)) return error.InvalidAuthority;
        for (authority.canonical_root) |byte| if (std.ascii.isControl(byte)) return error.InvalidAuthority;
        return .{ .allocator = allocator, .io = io, .main_thread_id = main_thread_id, .root = try allocator.dupe(u8, authority.canonical_root) };
    }

    pub fn port(self: *Output) agent.VideoGenerationOutput {
        return .{ .context = self, .commit_fn = commit };
    }

    pub fn deinit(self: *Output) void {
        self.allocator.free(self.root);
        self.* = undefined;
    }

    fn commit(context: *anyopaque, reader: *std.Io.Reader, expected_bytes: ?u64, cancellation: *const agent.CompletionCancellation) agent.VideoGenerationOutcome {
        const self: *Output = @ptrCast(@alignCast(context));
        if (std.Thread.getCurrentId() == self.main_thread_id) return .{ .failed = .unavailable };
        const receipt = self.save(reader, expected_bytes, cancellation) catch |err| return .{ .failed = switch (err) {
            error.CleanupIncomplete => .cleanup_incomplete,
            error.Cancelled => .cancelled,
            error.VideoReadFailed => if (cancellation.isRequested()) .cancelled else .download_failed,
            error.InvalidVideoSize => .invalid_response,
            else => .output_failed,
        } };
        return .{ .saved = receipt };
    }

    fn save(self: *Output, reader: *std.Io.Reader, expected_bytes: ?u64, cancellation: *const agent.CompletionCancellation) !agent.VideoGenerationReceipt {
        if (cancellation.isRequested()) return error.Cancelled;
        var root = try output_file.openRoot(self.io, self.root);
        defer root.close(self.io);
        const root_identity = try root.stat(self.io);
        root.createDir(self.io, directory_name, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700)) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        var directory = try root.openDir(self.io, directory_name, .{ .access_sub_paths = true, .follow_symlinks = false });
        defer directory.close(self.io);
        const directory_identity = try directory.stat(self.io);
        if (directory_identity.kind != .directory) return error.DirectoryChanged;
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(self.io, &random);
        var name_storage: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_storage, "video-{x}.mp4", .{random});
        var temp_storage: [72]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_storage, "{s}.partial", .{name});
        var path_storage: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_storage, "{s}/{s}", .{ directory_name, name });

        const file = try directory.createFile(self.io, temp, .{ .read = true, .exclusive = true, .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
        const created = file.stat(self.io) catch {
            file.close(self.io);
            return error.CleanupIncomplete;
        };
        const written = self.write(file, reader, expected_bytes, cancellation);
        file.close(self.io);
        const size = written catch |err| return self.cleanup(directory, temp, created, err);
        const receipt = agent.VideoGenerationReceipt.init(path, size) catch |err| return self.cleanup(directory, temp, created, err);
        self.publish(directory, root_identity, directory_identity, temp, name, created, size, cancellation) catch |err|
            return self.cleanup(directory, temp, created, err);
        return receipt;
    }

    fn write(self: *Output, file: std.Io.File, reader: *std.Io.Reader, expected_bytes: ?u64, cancellation: *const agent.CompletionCancellation) !u64 {
        var buffer: [64 * 1024]u8 = undefined;
        var size: u64 = 0;
        while (!cancellation.isRequested()) {
            const count = reader.readSliceShort(&buffer) catch return error.VideoReadFailed;
            if (count == 0) break;
            size += count;
            if (size > agent.max_generated_video_bytes or (expected_bytes != null and size > expected_bytes.?)) return error.InvalidVideoSize;
            try file.writeStreamingAll(self.io, buffer[0..count]);
        }
        if (cancellation.isRequested()) return error.Cancelled;
        if (expected_bytes) |expected| if (size < expected) return error.VideoReadFailed;
        if (size < 16) return error.InvalidVideoSize;
        try file.sync(self.io);
        return size;
    }

    fn publish(self: *Output, directory: std.Io.Dir, root_identity: std.Io.File.Stat, directory_identity: std.Io.File.Stat, temp: []const u8, name: []const u8, created: std.Io.File.Stat, size: u64, cancellation: *const agent.CompletionCancellation) !void {
        var current_root = try output_file.openRoot(self.io, self.root);
        defer current_root.close(self.io);
        if ((try current_root.stat(self.io)).inode != root_identity.inode) return error.DirectoryChanged;
        const current_directory = try current_root.statFile(self.io, directory_name, .{ .follow_symlinks = false });
        if (current_directory.kind != .directory or current_directory.inode != directory_identity.inode) return error.DirectoryChanged;
        const current_file = try directory.statFile(self.io, temp, .{ .follow_symlinks = false });
        if (current_file.kind != .file or current_file.inode != created.inode or current_file.size != size) return error.FileChanged;
        if (cancellation.isRequested()) return error.Cancelled;
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);
        if (cancellation.isRequested()) return error.Cancelled;
        try directory.renamePreserve(temp, directory, name, self.io);
    }

    fn cleanup(self: *Output, directory: std.Io.Dir, temp: []const u8, created: std.Io.File.Stat, failure: anyerror) anyerror {
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);
        const current = directory.statFile(self.io, temp, .{ .follow_symlinks = false }) catch return error.CleanupIncomplete;
        if (current.kind != .file or current.inode != created.inode) return error.CleanupIncomplete;
        directory.deleteFile(self.io, temp) catch return error.CleanupIncomplete;
        return failure;
    }
};
