//! Bounded MCP stdio transport. Each open owns one child process and serialized
//! pipe exchange. MCP messages remain opaque bytes; protocol handling belongs
//! to AgentCore through `mcp_connector`.

const std = @import("std");
const builtin = @import("builtin");
const connector = @import("agent_mcp_connector");

pub const Config = struct {
    /// All borrowed launch data must remain immutable until Backend.deinit.
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    /// Explicit environment capability. An empty map means no inherited
    /// variables; null/inherited process environment is not representable.
    environ_map: *const std.process.Environ.Map,
    max_frame_bytes: usize = 1024 * 1024,
    max_connections: usize = 8,
};

pub const Error = error{InvalidConfig};

pub const Backend = struct {
    config: Config,
    active_connections: std.atomic.Value(usize) = .init(0),

    pub fn init(config: Config) Error!Backend {
        if (config.argv.len == 0 or config.argv.len > max_argv_count or
            config.argv[0].len == 0 or config.max_frame_bytes == 0 or
            config.max_frame_bytes > max_frame_bytes or
            config.max_connections == 0)
            return error.InvalidConfig;
        var total: usize = 0;
        for (config.argv) |argument| {
            if (std.mem.indexOfScalar(u8, argument, 0) != null)
                return error.InvalidConfig;
            total = std.math.add(usize, total, argument.len) catch
                return error.InvalidConfig;
        }
        if (total > max_argv_bytes) return error.InvalidConfig;
        switch (config.cwd) {
            .path => |path| if (path.len == 0 or
                std.mem.indexOfScalar(u8, path, 0) != null)
                return error.InvalidConfig,
            .inherit, .dir => {},
        }
        return .{ .config = config };
    }

    pub fn transport(self: *Backend) connector.Transport {
        return .{
            .context = self,
            .open_fn = open,
            .request_fn = request,
            .notify_fn = notify,
            .close_fn = close,
        };
    }

    pub fn deinit(self: *Backend) error{ConnectionsActive}!void {
        if (self.active_connections.load(.acquire) != 0)
            return error.ConnectionsActive;
        self.* = undefined;
    }

    const Connection = struct {
        backend: *Backend,
        child: std.process.Child,
        stdin: std.Io.File,
        stdout: std.Io.File,
        stderr: std.Io.File,
        stdout_buffer: []u8,
        stdout_reader: std.Io.File.Reader,
        stderr_thread: std.Thread,
        mutex: std.Io.Mutex = .init,
        dead: std.atomic.Value(bool) = .init(false),

        fn terminate(self: *Connection) void {
            if (self.dead.swap(true, .acq_rel)) return;
            const io = self.backend.config.io;
            if (builtin.os.tag == .windows) {
                self.child.kill(io);
                return;
            }
            if (self.child.id) |pid| {
                // The child is its process-group leader. A hard group kill
                // prevents close/timeout from hanging on inherited pipe ends.
                std.posix.kill(-pid, .KILL) catch {};
                _ = self.child.wait(io) catch {};
            }
        }

        fn deinit(self: *Connection) void {
            const config = self.backend.config;
            self.mutex.lockUncancelable(config.io);
            self.terminate();
            self.mutex.unlock(config.io);
            self.stderr_thread.join();
            self.stdin.close(config.io);
            self.stdout.close(config.io);
            std.crypto.secureZero(u8, self.stdout_buffer);
            config.allocator.free(self.stdout_buffer);
            const backend = self.backend;
            config.allocator.destroy(self);
            releaseCounter(&backend.active_connections);
        }
    };

    fn open(
        context: *anyopaque,
        _: connector.Purpose,
        _: connector.Era,
        timeout_ms: u32,
    ) connector.OpenOutcome {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (timeout_ms == 0 or !incrementBounded(
            &self.active_connections,
            self.config.max_connections,
        )) return .{ .failure = .fatal };
        const connection = self.openConnection() catch |err| {
            releaseCounter(&self.active_connections);
            return .{ .failure = switch (err) {
                error.SpawnFailed => .child_exit,
                error.ResourceUnavailable => .fatal,
            } };
        };
        return .{ .connection = connection };
    }

    const OpenConnectionError = error{ SpawnFailed, ResourceUnavailable };

    fn openConnection(self: *Backend) OpenConnectionError!*Connection {
        var child = std.process.spawn(self.config.io, .{
            .argv = self.config.argv,
            .cwd = self.config.cwd,
            .environ_map = self.config.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = true,
        }) catch return error.SpawnFailed;
        errdefer child.kill(self.config.io);
        const stdin = child.stdin.?;
        const stdout = child.stdout.?;
        const stderr = child.stderr.?;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        errdefer stdin.close(self.config.io);
        errdefer stdout.close(self.config.io);
        errdefer stderr.close(self.config.io);
        const stdout_buffer = self.config.allocator.alloc(u8, io_buffer_bytes) catch
            return error.ResourceUnavailable;
        errdefer {
            std.crypto.secureZero(u8, stdout_buffer);
            self.config.allocator.free(stdout_buffer);
        }
        const connection = self.config.allocator.create(Connection) catch
            return error.ResourceUnavailable;
        errdefer self.config.allocator.destroy(connection);
        connection.* = .{
            .backend = self,
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .stdout_buffer = stdout_buffer,
            .stdout_reader = stdout.readerStreaming(
                self.config.io,
                stdout_buffer,
            ),
            .stderr_thread = undefined,
        };
        connection.stderr_thread = std.Thread.spawn(
            .{},
            drainStderr,
            .{connection},
        ) catch return error.ResourceUnavailable;
        return connection;
    }

    fn request(
        raw_connection: *anyopaque,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) connector.ExchangeOutcome {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.mutex.lockUncancelable(connection.backend.config.io);
        defer connection.mutex.unlock(connection.backend.config.io);
        if (connection.dead.load(.acquire))
            return .{ .failure = .child_exit };
        return runExchange(
            connection,
            allocator,
            bytes,
            timeout_ms,
            cancellation,
        );
    }

    fn notify(
        raw_connection: *anyopaque,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) ?connector.Failure {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.mutex.lockUncancelable(connection.backend.config.io);
        defer connection.mutex.unlock(connection.backend.config.io);
        if (connection.dead.load(.acquire)) return .child_exit;
        return runNotification(connection, bytes, timeout_ms, cancellation);
    }

    fn close(raw_connection: *anyopaque) void {
        const connection: *Connection = @ptrCast(@alignCast(raw_connection));
        connection.deinit();
    }

    const ReadResult = union(enum) {
        response: []u8,
        child_exit,
        fatal,
    };
    const WaitResult = enum { expired, cancelled };
    const ExchangeEvent = union(enum) {
        exchange: ReadResult,
        timeout: WaitResult,
        cancellation: WaitResult,
    };

    fn runExchange(
        connection: *Connection,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) connector.ExchangeOutcome {
        if (timeout_ms == 0) return .{ .failure = .fatal };
        if (cancellation.isCancelled()) return .{ .failure = .cancelled };
        var events: [3]ExchangeEvent = undefined;
        var select = std.Io.Select(ExchangeEvent).init(
            connection.backend.config.io,
            &events,
        );
        select.async(.exchange, exchange, .{ connection, allocator, bytes });
        select.async(.timeout, waitTimeout, .{
            connection.backend.config.io,
            timeout_ms,
        });
        select.async(.cancellation, waitCancellation, .{
            connection.backend.config.io,
            cancellation,
        });
        const first = select.await() catch {
            connection.terminate();
            drainExchangeSelect(&select, allocator);
            return .{ .failure = .cancelled };
        };
        const result: connector.ExchangeOutcome = switch (first) {
            .exchange => |exchange_result| switch (exchange_result) {
                .response => |response| .{ .response = response },
                .child_exit => .{ .failure = .child_exit },
                .fatal => .{ .failure = .fatal },
            },
            .timeout => |wait| switch (wait) {
                .expired => .{ .failure = .timeout },
                .cancelled => .{ .failure = .fatal },
            },
            .cancellation => |wait| switch (wait) {
                .expired => .{ .failure = .cancelled },
                .cancelled => .{ .failure = .fatal },
            },
        };
        switch (result) {
            .response => {},
            .failure => connection.terminate(),
        }
        drainExchangeSelect(&select, allocator);
        return result;
    }

    fn exchange(
        connection: *Connection,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) ReadResult {
        connection.stdin.writeStreamingAll(
            connection.backend.config.io,
            bytes,
        ) catch return .child_exit;
        connection.stdin.writeStreamingAll(
            connection.backend.config.io,
            "\n",
        ) catch return .child_exit;
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        _ = connection.stdout_reader.interface.streamDelimiterLimit(
            &output.writer,
            '\n',
            .limited(connection.backend.config.max_frame_bytes),
        ) catch |err| return switch (err) {
            error.ReadFailed => .child_exit,
            error.WriteFailed, error.StreamTooLong => .fatal,
        };
        const delimiter = connection.stdout_reader.interface.takeByte() catch
            return .child_exit;
        if (delimiter != '\n') return .fatal;
        const response = output.toOwnedSlice() catch return .fatal;
        if (response.len == 0) {
            allocator.free(response);
            return .fatal;
        }
        return .{ .response = response };
    }

    fn drainExchangeSelect(
        select: *std.Io.Select(ExchangeEvent),
        allocator: std.mem.Allocator,
    ) void {
        while (select.cancel()) |late| switch (late) {
            .exchange => |result| switch (result) {
                .response => |response| {
                    std.crypto.secureZero(u8, response);
                    allocator.free(response);
                },
                .child_exit, .fatal => {},
            },
            .timeout, .cancellation => {},
        };
    }

    const WriteResult = enum { ok, child_exit };
    const NotifyEvent = union(enum) {
        write: WriteResult,
        timeout: WaitResult,
        cancellation: WaitResult,
    };

    fn runNotification(
        connection: *Connection,
        bytes: []const u8,
        timeout_ms: u32,
        cancellation: connector.Cancellation,
    ) ?connector.Failure {
        if (timeout_ms == 0) return .fatal;
        if (cancellation.isCancelled()) return .cancelled;
        var events: [3]NotifyEvent = undefined;
        var select = std.Io.Select(NotifyEvent).init(
            connection.backend.config.io,
            &events,
        );
        select.async(.write, writeNotification, .{ connection, bytes });
        select.async(.timeout, waitTimeout, .{
            connection.backend.config.io,
            timeout_ms,
        });
        select.async(.cancellation, waitCancellation, .{
            connection.backend.config.io,
            cancellation,
        });
        const first = select.await() catch {
            connection.terminate();
            select.cancelDiscard();
            return .cancelled;
        };
        const result: ?connector.Failure = switch (first) {
            .write => |write| switch (write) {
                .ok => null,
                .child_exit => .child_exit,
            },
            .timeout => |wait| switch (wait) {
                .expired => .timeout,
                .cancelled => .fatal,
            },
            .cancellation => |wait| switch (wait) {
                .expired => .cancelled,
                .cancelled => .fatal,
            },
        };
        if (result != null) connection.terminate();
        select.cancelDiscard();
        return result;
    }

    fn writeNotification(
        connection: *Connection,
        bytes: []const u8,
    ) WriteResult {
        connection.stdin.writeStreamingAll(
            connection.backend.config.io,
            bytes,
        ) catch return .child_exit;
        connection.stdin.writeStreamingAll(
            connection.backend.config.io,
            "\n",
        ) catch return .child_exit;
        return .ok;
    }

    fn waitTimeout(io: std.Io, timeout_ms: u32) WaitResult {
        std.Io.Timeout.sleep(.{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        } }, io) catch return .cancelled;
        return .expired;
    }

    fn waitCancellation(
        io: std.Io,
        cancellation: connector.Cancellation,
    ) WaitResult {
        while (!cancellation.isCancelled())
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(5),
                .clock = .awake,
            } }, io) catch return .cancelled;
        return .expired;
    }

    fn drainStderr(connection: *Connection) void {
        defer connection.stderr.close(connection.backend.config.io);
        var buffer: [io_buffer_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &buffer);
        while (true) {
            const count = connection.stderr.readStreaming(
                connection.backend.config.io,
                &.{&buffer},
            ) catch return;
            if (count == 0) continue;
            // Diagnostics are intentionally not published. Draining through a
            // fixed buffer prevents child blockage without creating a secret-
            // bearing log or a second product data plane.
            std.crypto.secureZero(u8, buffer[0..count]);
        }
    }
};

const io_buffer_bytes: usize = 4096;
const max_argv_count: usize = 129;
const max_argv_bytes: usize = 64 * 1024;
const max_frame_bytes: usize = (connector.Limits{}).max_response_bytes;

fn incrementBounded(counter: *std.atomic.Value(usize), limit: usize) bool {
    var current = counter.load(.acquire);
    while (current < limit) {
        if (counter.cmpxchgWeak(
            current,
            current + 1,
            .acq_rel,
            .acquire,
        )) |observed| {
            current = observed;
        } else return true;
    }
    return false;
}

fn releaseCounter(counter: *std.atomic.Value(usize)) void {
    const previous = counter.fetchSub(1, .acq_rel);
    if (previous == 0) @panic("MCP stdio connection reference underflow");
}

test "stdio config and connection count are bounded" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expectError(error.InvalidConfig, Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &.{"bad\x00command"},
        .cwd = .inherit,
        .environ_map = &environment,
    }));
    try std.testing.expectError(error.InvalidConfig, Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &.{"command"},
        .cwd = .inherit,
        .environ_map = &environment,
        .max_connections = 0,
    }));
}

test "stdio round trip owns one process and releases every pipe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const script =
        \\printf 'discarded-secret' >&2
        \\while IFS= read -r line; do printf '%s\n' "$line"; done
    ;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = .inherit,
        .environ_map = &environment,
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
    const request_bytes = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        request_bytes,
        1000,
        .{},
    )) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(request_bytes, response);
    transport.close_fn(connection);
    connection_open = false;
    try std.testing.expectEqual(
        @as(usize, 0),
        backend.active_connections.load(.acquire),
    );
}

test "stdio timeout poisons and closes an indeterminate connection" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &.{
            "/bin/sh",
            "-c",
            "while IFS= read -r line; do sleep 5; done",
        },
        .cwd = .inherit,
        .environ_map = &environment,
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .compat_2025_11_25,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
    const result = transport.request_fn(
        connection,
        std.testing.allocator,
        "{}",
        20,
        .{},
    );
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.timeout,
            failure,
        ),
        .response => |response| {
            std.testing.allocator.free(response);
            return error.TestUnexpectedResult;
        },
    }
    transport.close_fn(connection);
    connection_open = false;
}

test "stdio cancellation poisons the connection and bounded open rejects overflow" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &.{
            "/bin/sh",
            "-c",
            "while IFS= read -r line; do sleep 5; done",
        },
        .cwd = .inherit,
        .environ_map = &environment,
        .max_connections = 1,
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
    switch (transport.open_fn(
        transport.context,
        .disposable_probe,
        .modern_2026_07_28,
        1000,
    )) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.fatal,
            failure,
        ),
        .connection => |extra| {
            transport.close_fn(extra);
            return error.TestUnexpectedResult;
        },
    }

    const CancellationState = struct {
        requested: std.atomic.Value(bool) = .init(false),

        fn isCancelled(context: ?*const anyopaque) bool {
            const self: *const @This() = @ptrCast(@alignCast(context.?));
            return self.requested.load(.acquire);
        }

        fn trigger(self: *@This()) void {
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(20),
                .clock = .awake,
            } }, std.testing.io) catch {};
            self.requested.store(true, .release);
        }
    };
    var cancellation: CancellationState = .{};
    const trigger = try std.Thread.spawn(
        .{},
        CancellationState.trigger,
        .{&cancellation},
    );
    const result = transport.request_fn(
        connection,
        std.testing.allocator,
        "{}",
        1000,
        .{
            .context = &cancellation,
            .is_cancelled_fn = CancellationState.isCancelled,
        },
    );
    trigger.join();
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(
            connector.Failure.cancelled,
            failure,
        ),
        .response => |response| {
            std.testing.allocator.free(response);
            return error.TestUnexpectedResult;
        },
    }
    transport.close_fn(connection);
    connection_open = false;
}

test "stdio notification is written without consuming a response" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const script =
        \\IFS= read -r notification
        \\IFS= read -r request
        \\printf '%s\n' "$request"
    ;
    var backend = try Backend.init(.{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = .inherit,
        .environ_map = &environment,
    });
    defer backend.deinit() catch unreachable;
    const transport = backend.transport();
    const connection = switch (transport.open_fn(
        transport.context,
        .actual,
        .modern_2026_07_28,
        1000,
    )) {
        .connection => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    var connection_open = true;
    defer if (connection_open) transport.close_fn(connection);
    try std.testing.expectEqual(
        @as(?connector.Failure, null),
        transport.notify_fn(connection, "{\"method\":\"ready\"}", 1000, .{}),
    );
    const request_bytes = "{\"id\":2}";
    const response = switch (transport.request_fn(
        connection,
        std.testing.allocator,
        request_bytes,
        1000,
        .{},
    )) {
        .response => |value| value,
        .failure => return error.TestUnexpectedResult,
    };
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings(request_bytes, response);
    transport.close_fn(connection);
    connection_open = false;
}
