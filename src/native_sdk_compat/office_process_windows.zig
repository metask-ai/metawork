//! Application-owned Windows Office process-tree lifetime only. The current
//! Native SDK has no public Job API. No arbitrary process or desktop capability
//! is exposed to Product, Agent or Renderer by this seam.
const std = @import("std");

const HANDLE = ?*anyopaque;
const BOOL = i32;
const BasicLimits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: u32 = 0,
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
const Accounting = extern struct {
    times: [4]i64 = @splat(0),
    page_faults: u32 = 0,
    total_processes: u32 = 0,
    active_processes: u32 = 0,
    terminated_processes: u32 = 0,
};

extern "kernel32" fn CreateJobObjectW(?*anyopaque, [*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetInformationJobObject(HANDLE, u32, *const anyopaque, u32) callconv(.winapi) BOOL;
extern "kernel32" fn QueryInformationJobObject(HANDLE, u32, *anyopaque, u32, ?*u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(HANDLE, u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;

pub const Error = error{ JobUnavailable, JobObservationFailed, JobTerminationFailed, JobDidNotSettle, RootObservationFailed };

pub const Job = struct {
    handle: HANDLE,
    name_buffer: [64]u8,
    name_len: usize,

    pub fn init(io: std.Io) !Job {
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(io, &random);
        var name_buffer: [64]u8 = undefined;
        const job_name = try std.fmt.bufPrint(&name_buffer, "Local\\MetaWork.Office.{s}", .{std.fmt.bytesToHex(random, .lower)});
        var wide: [64:0]u16 = @splat(0);
        for (job_name, 0..) |character, index| wide[index] = character;
        const handle = CreateJobObjectW(null, &wide) orelse return error.JobUnavailable;
        errdefer _ = CloseHandle(handle);
        if (GetLastError() == 183) return error.JobUnavailable; // never adopt an existing named job
        var limits: ExtendedLimits = .{};
        limits.basic.flags = 0x2000 | 0x0400; // KILL_ON_JOB_CLOSE, DIE_ON_UNHANDLED_EXCEPTION
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return error.JobUnavailable;
        return .{ .handle = handle, .name_buffer = name_buffer, .name_len = job_name.len };
    }

    pub fn name(self: *const Job) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// Closes the sole Host lifetime handle; OS termination is automatic even
    /// on Host hard kill. Callers must observe quiet before deleting resources.
    pub fn deinit(self: *Job) void {
        if (self.handle != null) _ = CloseHandle(self.handle);
        self.handle = null;
    }

    /// Observes a std.process-owned Windows handle without waiting on or
    /// closing it. The caller remains its sole wait/kill owner.
    pub fn rootExited(_: *const Job, child: *const std.process.Child) Error!bool {
        const handle = child.id orelse return true;
        return switch (WaitForSingleObject(handle, 0)) {
            0 => true,
            258 => false,
            else => error.RootObservationFailed,
        };
    }

    pub fn active(self: *const Job) Error!u32 {
        var information: Accounting = .{};
        if (QueryInformationJobObject(self.handle, 1, &information, @sizeOf(Accounting), null) == 0)
            return error.JobObservationFailed;
        return information.active_processes;
    }

    /// The root must already have been joined by its std.process child owner.
    /// This prevents a late join after kill.
    pub fn terminateAndWait(self: *Job, io: std.Io) !void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        if (TerminateJobObject(self.handle, 1) == 0) return error.JobTerminationFailed;
        const start: std.Io.Timestamp = .now(io, .awake);
        while (try self.active() != 0) {
            if (start.durationTo(.now(io, .awake)).toMilliseconds() >= 5000) return error.JobDidNotSettle;
            try std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, io);
        }
    }
};

test "Office job starts empty, names are fresh, and empty termination is observable" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var first = try Job.init(std.testing.io);
    defer first.deinit();
    var second = try Job.init(std.testing.io);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.name(), second.name()));
    try std.testing.expectEqual(@as(u32, 0), try first.active());
    try first.terminateAndWait(std.testing.io);
}
