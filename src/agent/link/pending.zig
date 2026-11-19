//! Outstanding calls, keyed by correlation.
//!
//! A forwarding stub sends a request and then claims its response. The two are
//! separate operations on purpose, and the response lands in a slot rather
//! than being handed to whoever is parked. That one decision is what makes the
//! stubs independent of which thread called them:
//!
//!   * a caller that waits is served by `claim`;
//!   * a caller that stops waiting `abandon`s its slot, and the reader still
//!     has somewhere to put the response -- it never needs a waiter to exist;
//!   * so `execute`'s terminal can reach a driver that no longer blocks, which
//!     the plan requires rather than hopes for. Without it, the split would
//!     write "one blocked UI thread per in-flight Run" into a cross-process
//!     contract, and thread stacks are a measured problem in this product.
//!
//! The thirty methods whose calling thread is not yet attributed therefore do
//! not have to pick a shape now. Attribution stays debt about call sites,
//! which is where it belongs: the same method can be reached from more than
//! one thread.
//!
//! Correlations are never reused while a slot is live, for the reason the
//! handle table carries a generation: a response matched to a reused
//! correlation would answer the wrong call, and a wrong answer that looks like
//! a right one is the failure this whole change keeps refusing.

const std = @import("std");

pub const Correlation = u64;

pub const SendError = error{
    /// The table is full of calls that still have someone waiting. The remedy
    /// is to try again shortly: the peer is answering, there are simply too
    /// many at once.
    TooManyInFlight,
    /// The table is full and some of it is held by calls nobody awaits any
    /// more -- correlations the peer still owes an answer for. The remedy is
    /// different in kind: waiting does not help, because what is missing is
    /// the peer's answers.
    ///
    /// These are two failures rather than one because the diagnostic must not
    /// name the wrong cause. Giving both the same code would say "too busy"
    /// when the truth is "the far side has stopped answering".
    TooManyUnsettled,
    /// Correlations are exhausted. Not wrapped: a wrapped correlation could
    /// match a live call.
    CorrelationExhausted,
};

/// What a claim returned.
pub const Claimed = union(enum) {
    /// The peer answered. The bytes belong to the claimer, which frees them.
    response: []u8,
    /// The link ended before an answer arrived. Not an answer, and never
    /// reported as one: the caller decides what an unanswered call means.
    link_closed,
};

/// Where a call's byte stream goes while the call is still in flight.
///
/// Opaque on purpose: this file is the correlation table and knows nothing
/// about what any call means. `false` says the bytes could not be taken, and
/// what that costs is the caller's to decide.
pub const Chunks = struct {
    context: ?*anyopaque,
    write_fn: *const fn (?*anyopaque, []const u8) bool,
};

pub const Table = struct {
    const Slot = struct {
        correlation: Correlation = 0,
        response: ?[]u8 = null,
        /// Where bytes arriving on this correlation go before its response
        /// does, for a call whose result is a byte stream.
        ///
        /// It needs no releasing of its own: every path that frees a slot
        /// writes `slot.* = .{}`, so a destination cannot outlive the call it
        /// belongs to. That is the property worth having, because what it
        /// points at is a frame on the calling thread's stack.
        chunks: ?Chunks = null,
        /// The caller stopped waiting. The reader still deposits, then
        /// releases, so a response is never dropped on the floor silently and
        /// never leaked.
        abandoned: bool = false,
        live: bool = false,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    slots: []Slot,
    next: Correlation = 0,
    live: usize = 0,
    closed: bool = false,

    pub fn init(
        self: *Table,
        io: std.Io,
        allocator: std.mem.Allocator,
        slot_count: usize,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(slot_count > 0);
        const slots = try allocator.alloc(Slot, slot_count);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .io = io, .slots = slots };
    }

    /// Wakes every waiter and releases anything deposited but unclaimed. After
    /// this, `claim` reports `link_closed` rather than blocking for an answer
    /// that cannot come.
    pub fn close(self: *Table) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        for (self.slots) |*slot| {
            if (slot.response) |bytes| {
                self.allocator.free(bytes);
                slot.response = null;
            }
        }
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    pub fn deinit(self: *Table) void {
        self.close();
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Reserves a correlation. The caller sends under it and then either
    /// claims or abandons; doing neither leaks the slot, which `liveCount`
    /// makes visible.
    ///
    /// Capacity is the number of correlations the peer has not settled, not
    /// the number of callers waiting at once. The second is strictly smaller,
    /// so sizing by it would pick a number that is fine in ordinary use and
    /// runs out exactly when a driver abandons a batch of waits.
    pub fn open(self: *Table) SendError!Correlation {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.next == std.math.maxInt(Correlation)) return error.CorrelationExhausted;
        var abandoned: usize = 0;
        for (self.slots) |*slot| {
            if (!slot.live) {
                self.next += 1;
                slot.* = .{ .correlation = self.next, .live = true };
                self.live += 1;
                return self.next;
            }
            if (slot.abandoned) abandoned += 1;
        }
        // Which exhaustion this is, decided from the table rather than
        // guessed. A slot held by a caller that has gone is the peer owing an
        // answer; with none of those, the pressure really is concurrency.
        return if (abandoned != 0) error.TooManyUnsettled else error.TooManyInFlight;
    }

    /// Says where this call's byte stream goes, before the request is sent.
    ///
    /// Before, not after: the peer may answer the first chunk into the pipe
    /// while the sender is still inside `trySubmit`, and a chunk that arrived
    /// with nowhere to go is a lost prefix of a checkpoint.
    pub fn attachChunks(self: *Table, correlation: Correlation, chunks: Chunks) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.indexOf(correlation) orelse return;
        self.slots[index].chunks = chunks;
    }

    /// The reader's side, read out rather than used in place.
    ///
    /// Returned as a copy so the write happens with the lock released: what
    /// it writes into is a file, and holding the correlation table across
    /// that would stall every other call for the length of an export. Safe
    /// because of the ordering the stream rests on -- the peer sends every
    /// chunk before the response, and this is the thread that reads both, so
    /// the slot cannot be freed between this and the write.
    pub fn chunksFor(self: *Table, correlation: Correlation) ?Chunks {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.indexOf(correlation) orelse return null;
        return self.slots[index].chunks;
    }

    /// Blocks until the response arrives or the link ends. The slot is
    /// released either way.
    pub fn claim(self: *Table, correlation: Correlation) Claimed {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.indexOf(correlation) orelse return .link_closed;
        while (true) {
            const slot = &self.slots[index];
            if (slot.response) |bytes| {
                slot.* = .{};
                self.live -= 1;
                return .{ .response = bytes };
            }
            if (self.closed) {
                slot.* = .{};
                self.live -= 1;
                return .link_closed;
            }
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Stops waiting without ending the call. The reader may still deposit a
    /// response, and will release it; nothing requires a waiter to exist.
    pub fn abandon(self: *Table, correlation: Correlation) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.indexOf(correlation) orelse return;
        const slot = &self.slots[index];
        if (slot.response) |bytes| {
            // Already answered: release it here rather than keeping a slot
            // alive for a caller that has gone.
            self.allocator.free(bytes);
            slot.* = .{};
            self.live -= 1;
            return;
        }
        slot.abandoned = true;
    }

    /// Takes a slot back for a request that never left.
    ///
    /// Distinct from `abandon`, and the distinction is the whole point.
    /// Abandoning says "I stopped waiting, the peer may still answer", so the
    /// slot stays live until that answer arrives or the link ends -- which is
    /// right when something was sent. When nothing was sent no answer can
    /// come, so holding the slot would spend capacity on a call that never
    /// happened, and a caller that is refused repeatedly would exhaust the
    /// table on requests it never made.
    ///
    /// Only for a correlation whose bytes did not reach the peer. Calling it
    /// after a send would leave a later response with no slot -- `deposit`
    /// releases those rather than mis-filing them, so it is not a corruption,
    /// but the answer would be lost silently.
    pub fn discardUnsent(self: *Table, correlation: Correlation) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.indexOf(correlation) orelse return;
        const slot = &self.slots[index];
        if (slot.response) |bytes| self.allocator.free(bytes);
        slot.* = .{};
        self.live -= 1;
    }

    /// The reader's side. Takes ownership of `bytes` on success; on an
    /// abandoned or unknown correlation it frees them, because a response with
    /// nobody to take it is still the table's to release.
    pub fn deposit(self: *Table, correlation: Correlation, bytes: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.indexOf(correlation) orelse {
            self.allocator.free(bytes);
            return;
        };
        const slot = &self.slots[index];
        if (slot.abandoned or self.closed) {
            self.allocator.free(bytes);
            slot.* = .{};
            self.live -= 1;
            return;
        }
        if (slot.response != null) {
            // The peer answered twice under one correlation, which is a
            // protocol violation. Keep the first and release the second rather
            // than letting a later answer overwrite an earlier one.
            self.allocator.free(bytes);
            return;
        }
        slot.response = bytes;
        self.condition.broadcast(self.io);
    }

    pub fn liveCount(self: *Table) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.live;
    }

    pub fn capacity(self: *const Table) usize {
        return self.slots.len;
    }

    /// Correlations the peer still owes an answer for and nobody awaits. The
    /// number capacity has to be sized against, and the one that says the far
    /// side has stopped answering.
    pub fn unsettledCount(self: *Table) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var total: usize = 0;
        for (self.slots) |slot| {
            if (slot.live and slot.abandoned) total += 1;
        }
        return total;
    }

    fn indexOf(self: *const Table, correlation: Correlation) ?usize {
        if (correlation == 0) return null;
        for (self.slots, 0..) |slot, index| {
            if (slot.live and slot.correlation == correlation) return index;
        }
        return null;
    }
};

const testing = std.testing;

fn owned(text: []const u8) []u8 {
    return testing.allocator.dupe(u8, text) catch unreachable;
}

test "a response reaches the caller that waited for it" {
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 4);
    defer table.deinit();

    const a = try table.open();
    const b = try table.open();
    try testing.expect(a != b);
    table.deposit(b, owned("second"));
    table.deposit(a, owned("first"));

    const first = table.claim(a);
    try testing.expectEqualStrings("first", first.response);
    testing.allocator.free(first.response);
    const second = table.claim(b);
    try testing.expectEqualStrings("second", second.response);
    testing.allocator.free(second.response);
    try testing.expectEqual(@as(usize, 0), table.liveCount());
}

test "a response still has somewhere to go when the caller stopped waiting" {
    // The property the whole file exists for: the reader never needs a waiter.
    // Without it, a terminal could only be delivered to a parked thread, and
    // "one blocked thread per in-flight Run" would become a wire contract.
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 2);
    defer table.deinit();

    const correlation = try table.open();
    table.abandon(correlation);
    // Depositing after the caller left is legal and leaks nothing: the table
    // owns the bytes and releases them.
    table.deposit(correlation, owned("terminal nobody is waiting for"));
    try testing.expectEqual(@as(usize, 0), table.liveCount());

    // And the reverse order: answered first, abandoned after.
    const second = try table.open();
    table.deposit(second, owned("answered"));
    table.abandon(second);
    try testing.expectEqual(@as(usize, 0), table.liveCount());
}

test "a claim on a closed link is not an answer" {
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 2);
    defer table.deinit();
    const correlation = try table.open();
    table.close();
    try testing.expectEqual(Claimed.link_closed, table.claim(correlation));
    // An unknown correlation reads the same way rather than blocking forever.
    try testing.expectEqual(Claimed.link_closed, table.claim(9999));
    try testing.expectEqual(Claimed.link_closed, table.claim(0));
}

test "abandoning keeps the slot until the peer answers, and never reuses the correlation" {
    // Abandoning does not free capacity, and that is the right trade rather
    // than an oversight: the correlation has to stay reserved so a late
    // response is matched to the call that asked for it and released, instead
    // of being matched to whatever call took the slot next. Capacity is
    // bounded and recoverable; a response delivered to the wrong call is a
    // wrong answer that looks like a right one.
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 1);
    defer table.deinit();

    const first = try table.open();
    try testing.expectError(error.TooManyInFlight, table.open());
    table.abandon(first);
    // Still occupied: nobody is waiting, but the peer may still answer.
    try testing.expectEqual(@as(usize, 1), table.liveCount());
    try testing.expectError(error.TooManyUnsettled, table.open());

    // The peer's late answer releases the slot, and is not handed to anyone.
    table.deposit(first, owned("late answer to a call nobody awaits"));
    try testing.expectEqual(@as(usize, 0), table.liveCount());

    // The next call gets a different correlation, so the old one can never
    // match it.
    const second = try table.open();
    try testing.expect(second != first);
    table.deposit(first, owned("answer to the call that is gone"));
    try testing.expectEqual(@as(usize, 1), table.liveCount());
    table.abandon(second);
}

test "a peer that answers twice does not overwrite the first answer" {
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 2);
    defer table.deinit();
    const correlation = try table.open();
    table.deposit(correlation, owned("first"));
    table.deposit(correlation, owned("second"));
    const claimed = table.claim(correlation);
    try testing.expectEqualStrings("first", claimed.response);
    testing.allocator.free(claimed.response);
}

test "closing releases what was deposited but never claimed" {
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 2);
    defer table.deinit();
    table.deposit(try table.open(), owned("unclaimed"));
    // `deinit` closes, and the leak checker is what proves the release: if
    // closing dropped the bytes instead of freeing them, this test fails.
}

test "exhaustion by abandonment is reported as unsettled, not as concurrency" {
    // A driver cancelling a batch of Runs abandons a run of waits. Those slots
    // stay occupied until the peer answers, so the table can be exhausted with
    // nobody waiting on anything. The refusal has to say which of the two it
    // is, because the remedies differ: retry shortly, or the far side has
    // stopped answering and waiting will not help.
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 3);
    defer table.deinit();

    var abandoned: [3]Correlation = undefined;
    for (&abandoned) |*slot| {
        slot.* = try table.open();
        table.abandon(slot.*);
    }
    try testing.expectEqual(@as(usize, 3), table.unsettledCount());
    try testing.expectError(error.TooManyUnsettled, table.open());

    // Once the peer settles one, a call fits again, and with no abandoned
    // slots left the next exhaustion is concurrency rather than liveness.
    for (abandoned) |correlation| table.deposit(correlation, owned("settled"));
    try testing.expectEqual(@as(usize, 0), table.unsettledCount());
    const live = [_]Correlation{ try table.open(), try table.open(), try table.open() };
    try testing.expectError(error.TooManyInFlight, table.open());
    for (live) |correlation| table.abandon(correlation);
}

test "capacity counts what the peer has not settled, not who is waiting" {
    // The sizing rule, asserted so it cannot be read the other way: with one
    // caller waiting and two answers still owed, three slots are in use.
    var table: Table = undefined;
    try table.init(testing.io, testing.allocator, 3);
    defer table.deinit();
    const waiting = try table.open();
    const owed_one = try table.open();
    const owed_two = try table.open();
    table.abandon(owed_one);
    table.abandon(owed_two);
    try testing.expectEqual(@as(usize, 1), 3 - table.unsettledCount());
    try testing.expectEqual(@as(usize, 3), table.liveCount());
    try testing.expectError(error.TooManyUnsettled, table.open());
    table.abandon(waiting);
}
