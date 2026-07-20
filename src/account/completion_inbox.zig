const std = @import("std");
const contract = @import("metawork_account_contract");
const state = @import("account_state");

pub const WakeSink = struct {
    context: *anyopaque,
    notify_fn: *const fn (context: *anyopaque) bool,

    pub fn notify(self: WakeSink) bool {
        return self.notify_fn(self.context);
    }
};

pub const PublishResult = enum {
    published,
    ignored_stale,
    terminal_overflow,
    fatal_wake_failure,
};

/// Bounded MPSC completion queue for one active attempt. Producers may publish
/// concurrently. The owner must quiesce all producers before `deinit`.
pub fn CompletionInbox(comptime capacity: usize) type {
    if (capacity == 0) @compileError("CompletionInbox capacity must be positive");
    return struct {
        io: std.Io,
        mutex: std.Io.Mutex = .init,
        entries: [capacity]?state.WorkerCompletion = @splat(null),
        head: usize = 0,
        len: usize = 0,
        attempt_id: u64,
        terminal: ?state.WorkerFailure = null,
        terminal_written: bool = false,
        fatal_wake_failure: bool = false,

        const Self = @This();

        pub fn init(io: std.Io, attempt_id: u64) Self {
            std.debug.assert(attempt_id != 0);
            return .{ .io = io, .attempt_id = attempt_id };
        }

        /// Consumes `completion` on every return path.
        pub fn publish(
            self: *Self,
            completion_value: state.WorkerCompletion,
            wake: WakeSink,
        ) PublishResult {
            var completion = completion_value;
            var needs_wake = false;
            self.lock();
            var result: PublishResult = .published;
            if (self.fatal_wake_failure) {
                completion.deinit();
                self.unlock();
                return .fatal_wake_failure;
            }
            if (completion.attempt_id != self.attempt_id) {
                completion.deinit();
                result = .ignored_stale;
            } else if (self.len == capacity) {
                completion.deinit();
                if (!self.terminal_written) {
                    self.terminal = state.WorkerFailure.fromCode(
                        .completion_queue_overflow,
                    );
                    self.terminal_written = true;
                }
                result = .terminal_overflow;
                needs_wake = true;
            } else {
                const tail = (self.head + self.len) % capacity;
                std.debug.assert(self.entries[tail] == null);
                self.entries[tail] = completion;
                self.len += 1;
                needs_wake = true;
            }
            self.unlock();

            if (!needs_wake) return result;
            if (!wake.notify()) {
                self.lock();
                self.fatal_wake_failure = true;
                if (!self.terminal_written) {
                    self.terminal = state.WorkerFailure.fromCode(
                        .main_loop_wake_failed,
                    );
                    self.terminal_written = true;
                }
                self.unlock();
                return .fatal_wake_failure;
            }
            return result;
        }

        pub fn pop(self: *Self) ?state.WorkerCompletion {
            self.lock();
            defer self.unlock();
            if (self.len == 0) return null;
            const entry = self.entries[self.head].?;
            self.entries[self.head] = null;
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return entry;
        }

        pub fn takeTerminal(self: *Self) ?state.WorkerFailure {
            self.lock();
            defer self.unlock();
            const terminal = self.terminal;
            self.terminal = null;
            return terminal;
        }

        pub fn isFatal(self: *Self) bool {
            self.lock();
            defer self.unlock();
            return self.fatal_wake_failure;
        }

        pub fn deinit(self: *Self) void {
            while (self.pop()) |value| {
                var completion = value;
                completion.deinit();
            }
            _ = self.takeTerminal();
        }

        fn lock(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
        }

        fn unlock(self: *Self) void {
            self.mutex.unlock(self.io);
        }
    };
}

test "completion inbox keeps first terminal overflow and fails closed on wake loss" {
    const Wake = struct {
        available: bool = true,
        count: usize = 0,

        fn notify(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            return self.available;
        }
    };

    var wake_state: Wake = .{};
    const wake: WakeSink = .{
        .context = &wake_state,
        .notify_fn = Wake.notify,
    };
    var inbox = CompletionInbox(1).init(std.testing.io, 9);
    defer inbox.deinit();

    try std.testing.expectEqual(PublishResult.ignored_stale, inbox.publish(.{
        .attempt_id = 8,
        .payload = .models_loaded,
    }, wake));
    try std.testing.expectEqual(@as(usize, 0), wake_state.count);
    try std.testing.expectEqual(PublishResult.published, inbox.publish(.{
        .attempt_id = 9,
        .payload = .api_keys_loaded,
    }, wake));
    try std.testing.expectEqual(PublishResult.terminal_overflow, inbox.publish(.{
        .attempt_id = 9,
        .payload = .models_loaded,
    }, wake));
    try std.testing.expectEqual(PublishResult.terminal_overflow, inbox.publish(.{
        .attempt_id = 9,
        .payload = .logged_out,
    }, wake));
    const terminal = inbox.takeTerminal().?;
    try std.testing.expectEqual(
        contract.ErrorCode.completion_queue_overflow,
        terminal.error_code,
    );
    try std.testing.expectEqual(PublishResult.terminal_overflow, inbox.publish(.{
        .attempt_id = 9,
        .payload = .models_loaded,
    }, wake));
    try std.testing.expectEqual(
        @as(?state.WorkerFailure, null),
        inbox.takeTerminal(),
    );

    var queued = inbox.pop().?;
    queued.deinit();
    wake_state.available = false;
    try std.testing.expectEqual(PublishResult.fatal_wake_failure, inbox.publish(.{
        .attempt_id = 9,
        .payload = .models_loaded,
    }, wake));
    try std.testing.expect(inbox.isFatal());
}

test "completion inbox accepts concurrent producers without losing ownership" {
    const Inbox = CompletionInbox(8);
    const Wake = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn notify(raw: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.count.fetchAdd(1, .monotonic);
            return true;
        }
    };
    const Producer = struct {
        inbox: *Inbox,
        wake: WakeSink,

        fn run(self: *@This()) void {
            const result = self.inbox.publish(.{
                .attempt_id = 21,
                .payload = .api_keys_loaded,
            }, self.wake);
            std.debug.assert(result == .published);
        }
    };

    var wake_state: Wake = .{};
    const wake: WakeSink = .{
        .context = &wake_state,
        .notify_fn = Wake.notify,
    };
    var inbox = Inbox.init(std.testing.io, 21);
    defer inbox.deinit();
    var producers = [_]Producer{
        .{ .inbox = &inbox, .wake = wake },
        .{ .inbox = &inbox, .wake = wake },
        .{ .inbox = &inbox, .wake = wake },
        .{ .inbox = &inbox, .wake = wake },
    };
    var threads: [producers.len]std.Thread = undefined;
    for (&threads, &producers) |*thread, *producer|
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
    for (threads) |thread| thread.join();

    var popped: usize = 0;
    while (inbox.pop()) |value| {
        var completion = value;
        completion.deinit();
        popped += 1;
    }
    try std.testing.expectEqual(producers.len, popped);
    try std.testing.expectEqual(producers.len, wake_state.count.load(.monotonic));
}
