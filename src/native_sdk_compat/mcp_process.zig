//! Application-only Windows MCP process-tree lifetime. Spawn and pipe I/O
//! remain std.process/std.Io owned; this seam only assigns a suspended child
//! to a non-inheritable kill-on-close Job before allowing it to execute.
const std = @import("std");
const windows = std.os.windows;

const BasicLimits = extern struct {
    process_time: i64 = 0,
    job_time: i64 = 0,
    flags: u32 = 0,
    min_working_set: usize = 0,
    max_working_set: usize = 0,
    active_processes: u32 = 0,
    affinity: usize = 0,
    priority: u32 = 0,
    scheduling: u32 = 0,
};
const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};

extern "kernel32" fn CreateJobObjectW(?*const anyopaque, ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(windows.HANDLE, u32, *const anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(windows.HANDLE) callconv(.winapi) u32;

pub const Job = struct {
    handle: ?windows.HANDLE,

    pub fn init() error{JobUnavailable}!Job {
        const handle = CreateJobObjectW(null, null) orelse return error.JobUnavailable;
        errdefer windows.CloseHandle(handle);
        const limits: ExtendedLimits = .{ .basic = .{ .flags = 0x00002000 } }; // KILL_ON_JOB_CLOSE
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0)
            return error.JobUnavailable;
        return .{ .handle = handle };
    }

    /// Caller owns cleanup of the still-suspended child on either failure.
    pub fn attachAndResume(self: *Job, child: *std.process.Child) error{JobUnavailable}!void {
        const process = child.id orelse return error.JobUnavailable;
        if (AssignProcessToJobObject(self.handle.?, process) == 0)
            return error.JobUnavailable;
        if (ResumeThread(child.thread_handle) == std.math.maxInt(u32))
            return error.JobUnavailable;
    }

    /// No other component receives this handle. Closing its only reference
    /// terminates the assigned tree, including descendants holding pipe ends.
    pub fn deinit(self: *Job) void {
        if (self.handle) |handle| windows.CloseHandle(handle);
        self.handle = null;
    }
};
