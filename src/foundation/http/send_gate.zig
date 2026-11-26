//! Holds one request between its connection and its first byte until its
//! owner decides, on its own thread, that it may still be sent. A request
//! leaves only after that decision, and a decision taken back before it left
//! is honoured: whichever of the two moves first wins, and the loser knows.

const std = @import("std");
const Io = std.Io;

pub const SendGate = struct {
    pub const State = enum(u32) {
        /// Nothing asked yet.
        idle,
        /// The request has its connection and waits for the decision.
        requested,
        /// The owner let it go; it has not left yet.
        released,
        /// It left: from here its bytes may reach the server.
        sending,
        /// The owner refused it, or it stopped waiting: nothing was sent.
        refused,
        /// The owner took the release back before it left: nothing was sent.
        withdrawn,
    };

    /// Tells the owner a request asks. Called on the request's thread.
    pub const Wake = struct {
        context: *anyopaque,
        notify_fn: *const fn (*anyopaque) void,
    };

    state: std.atomic.Value(u32) = .init(@intFromEnum(State.idle)),
    wake: ?Wake = null,
    /// How long a request waits for the decision before it gives up.
    limit: Io.Duration = .fromSeconds(5),

    pub fn load(self: *const SendGate) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    fn move(self: *SendGate, io: Io, from: State, to: State) bool {
        if (self.state.cmpxchgStrong(@intFromEnum(from), @intFromEnum(to), .acq_rel, .acquire) != null) return false;
        io.futexWake(u32, &self.state.raw, std.math.maxInt(u32));
        return true;
    }

    /// The owner lets a request that asked go. False when none is asking.
    pub fn release(self: *SendGate, io: Io) bool {
        return self.move(io, .requested, .released);
    }

    /// The owner refuses a request that was not let go. False once it was.
    pub fn refuse(self: *SendGate, io: Io) bool {
        return self.move(io, .idle, .refused) or self.move(io, .requested, .refused);
    }

    /// The owner takes a release back. False when the request already left.
    pub fn withdraw(self: *SendGate, io: Io) bool {
        return self.move(io, .released, .withdrawn);
    }

    /// The request asks and waits for the decision. True when it may send
    /// now; false when it was refused, taken back, or waited too long.
    pub fn pass(self: *SendGate, io: Io) Io.Cancelable!bool {
        if (!self.move(io, .idle, .requested)) return false;
        if (self.wake) |wake| wake.notify_fn(wake.context);
        const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = self.limit, .clock = .awake });
        while (true) {
            switch (self.load()) {
                .released => if (self.move(io, .released, .sending)) return true,
                .requested => {
                    if (deadline.raw.nanoseconds <= deadline.clock.now(io).nanoseconds) {
                        if (self.move(io, .requested, .refused)) return false;
                        continue;
                    }
                    try io.futexWaitTimeout(u32, &self.state.raw, @intFromEnum(State.requested), .{ .deadline = deadline });
                },
                .idle, .sending => unreachable,
                .refused, .withdrawn => return false,
            }
        }
    }
};
