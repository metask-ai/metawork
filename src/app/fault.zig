//! Process-wide fault capture: the half of a fatal fault that the Zig panic
//! path never sees.
//!
//! `src/app.zig` installs `std.debug.FullPanic(native_sdk.debug.capturePanic)`,
//! so a Zig panic leaves `last-panic.txt` behind. Trap-class faults take a
//! different route and leave nothing: C built with the C UBSan's trap mode
//! (`-fsanitize-trap=undefined`, which the app module turned off for the
//! vendored units but our own SQLite units keep) executes an undefined
//! instruction, `abort()` from C runs through the C runtime, and a hardware
//! fault or an exhausted stack raises a signal or an SEH exception. The Zig standard library does
//! attach its own handler over part of that surface -- `std.start` calls
//! `std.debug.maybeEnableSegfaultHandler` whenever `runtime_safety` is on,
//! which includes the shipped ReleaseSafe build -- but it prints to stderr,
//! which a GUI-subsystem process has nowhere to send, and then aborts.
//! Nothing durable, nothing a user can report, and nothing that says which
//! Task died with it.
//!
//! This module adds the missing evidence and nothing else:
//!
//! * one fixed-length record per process, written from a preallocated buffer
//!   through a handle opened at install time, so the handler can stay
//!   async-signal-safe: no allocation, no lock, no formatting;
//! * a breadcrumb ring that the thread owning a Run writes with plain atomic
//!   stores, so the handler names the interrupted Runs by copying memory
//!   instead of walking Product state;
//! * a startup/exit marker on the single-instance lease, which turns "the last
//!   exit was not clean" into a fact rather than a guess.
//!
//! Reporting is deliberately out of scope: a crash record belongs to the
//! product-wide feedback mechanism as an attachment, so this module only lands
//! bytes and states the fact at startup.
//!
//! Only `std` and `builtin` are imported, on purpose. The build identity the
//! record carries is passed in by the Application composition root, which
//! keeps this module compilable and testable on its own for both targets and
//! keeps the signal path free of anything that could allocate.

const builtin = @import("builtin");
const std = @import("std");

/// Which half of the process wrote the record. Execution isolation adds an
/// `exec` value with its own install call; the Application is the only caller
/// today and hard-codes `ui`.
pub const Role = enum(u8) { ui = 1 };

pub const ArtifactKind = enum(u8) {
    unknown = 0,
    development = 1,
    release = 2,
    automation = 3,
};

pub const OptimizeMode = enum(u8) {
    unknown = 0,
    debug = 1,
    release_safe = 2,
    release_fast = 3,
    release_small = 4,
};

pub const OsTag = enum(u8) { other = 0, windows = 1, macos = 2 };

pub const Arch = enum(u8) { other = 0, x86_64 = 1, aarch64 = 2 };

/// How a recorded address can be matched to symbols offline. A source commit
/// cannot do that job -- one commit produces different addresses per target
/// and optimize mode, and the shipped binaries are stripped -- so the record
/// carries the image's own build identity: the CodeView PDB signature of the
/// loaded PE on Windows, `LC_UUID` on macOS.
pub const DebugIdKind = enum(u8) { none = 0, pe_pdb70 = 1, macho_uuid = 2 };

pub const CaptureKind = enum(u8) {
    /// No handler ran. A record left in this state was pre-filled at install
    /// and never completed, which is itself a fact: the process died without
    /// dispatching anything (`TerminateProcess`, `__fastfail`, power loss).
    none = 0,
    windows_unhandled_exception = 1,
    windows_vectored_exception = 2,
    posix_signal = 3,
    /// `SIGABRT`, which on Windows only the C runtime's `abort()` raises.
    abort_signal = 4,
    /// The Zig panic path, recorded next to the SDK's own capture so a panic
    /// also names the Runs it interrupted.
    zig_panic = 5,
    /// `std.debug`'s own fault handler, through its documented root hook.
    standard_segfault = 6,
    _,
};

pub const BreadcrumbPhase = enum(u8) { empty = 0, running = 1, finished = 2, _ };

/// Build identity, supplied by the composition root.
pub const Identity = struct {
    /// Product version string, truncated to `version_bytes`.
    version: []const u8,
    artifact_kind: ArtifactKind,
    /// Raw digest of the AgentCore bundle manifest.
    core_manifest_sha256: [32]u8,
    core_abi_revision: u16,
};

pub const Options = struct {
    role: Role,
    /// Canonical data root. Artifacts land in `<data_root>/faults/`.
    data_root: []const u8,
    identity: Identity,
};

pub const directory_name = "faults";
pub const record_file_name = "last-fault.bin";
pub const report_file_name = "last-fault.txt";

// ---------------------------------------------------------------------------
// Record layout
//
// Three fixed blocks, little-endian, no implicit padding: an identity block
// filled once at install time, a fault block the handler fills, and the
// breadcrumb ring copied out verbatim. `recordLayout` pins every offset, and
// the decoder refuses any record whose own size fields disagree with it.
// ---------------------------------------------------------------------------

pub const record_magic = "MWFAULT1".*;
pub const record_format: u16 = 1;
pub const identity_block_bytes: usize = 160;
pub const version_bytes: usize = 32;
pub const frame_capacity: usize = 32;
pub const fault_block_bytes: usize = 72 + frame_capacity * @sizeOf(u64);
pub const breadcrumb_entry_bytes: usize = 40;
/// Two per host worker (`host_worker_count` in `src/app.zig` is 16), which is
/// the most Runs that can execute at once: every live Run is present, plus at
/// least as many that just finished, which is what separates "this Run was
/// running" from "this Run had already completed". A power of two keeps the
/// publish side a masked `fetchAdd` -- no division in the Run path, and no
/// second cursor to keep consistent with the first.
pub const breadcrumb_capacity: usize = 32;
pub const breadcrumb_block_bytes: usize = breadcrumb_entry_bytes * breadcrumb_capacity;
pub const record_bytes: usize =
    identity_block_bytes + fault_block_bytes + breadcrumb_block_bytes;

/// Byte offsets of every field in the record, as reviewed and as written.
pub const recordLayout = struct {
    pub const magic: usize = 0; // [8]u8
    pub const format: usize = 8; // u16
    pub const identity_bytes: usize = 10; // u16
    pub const fault_bytes: usize = 12; // u16
    pub const breadcrumb_bytes: usize = 14; // u16
    pub const breadcrumb_count: usize = 16; // u16
    pub const role: usize = 18; // u8
    pub const artifact_kind: usize = 19; // u8
    pub const optimize: usize = 20; // u8
    pub const os_tag: usize = 21; // u8
    pub const arch: usize = 22; // u8
    pub const debug_id_kind: usize = 23; // u8
    pub const total_bytes: usize = 24; // u32
    pub const pid: usize = 28; // u32
    pub const process_started_at_unix_ms: usize = 32; // i64
    pub const core_abi_revision: usize = 40; // u16
    // 42..44 reserved.
    pub const debug_id_age: usize = 44; // u32
    pub const debug_id: usize = 48; // [16]u8
    pub const module_base: usize = 64; // u64
    pub const module_bytes: usize = 72; // u64
    pub const core_manifest_sha256: usize = 80; // [32]u8
    pub const version: usize = 112; // [32]u8, zero padded
    // 144..160 reserved for identity growth.

    pub const capture_kind: usize = identity_block_bytes + 0; // u8
    pub const capture_attempts: usize = identity_block_bytes + 1; // u8
    pub const frame_count: usize = identity_block_bytes + 2; // u8
    // +3 reserved.
    pub const code: usize = identity_block_bytes + 4; // u32
    pub const signal_code: usize = identity_block_bytes + 8; // u32
    pub const access_kind: usize = identity_block_bytes + 12; // u32
    pub const thread_id: usize = identity_block_bytes + 16; // u64
    pub const fault_address: usize = identity_block_bytes + 24; // u64
    pub const fault_ip: usize = identity_block_bytes + 32; // u64
    pub const fault_sp: usize = identity_block_bytes + 40; // u64
    pub const fault_fp: usize = identity_block_bytes + 48; // u64
    pub const fault_at_unix_ms: usize = identity_block_bytes + 56; // i64
    pub const breadcrumb_cursor: usize = identity_block_bytes + 64; // u64
    pub const frames: usize = identity_block_bytes + 72; // [frame_capacity]u64

    pub const breadcrumbs: usize = identity_block_bytes + fault_block_bytes;

    /// Offsets inside one breadcrumb entry.
    pub const breadcrumb = struct {
        pub const task_id: usize = 0; // u64
        pub const run_id: usize = 8; // u64
        pub const started_at_unix_ms: usize = 16; // i64
        pub const thread_id: usize = 24; // u64
        pub const phase: usize = 32; // u8
        // 33..40 reserved.
    };
};

comptime {
    std.debug.assert(recordLayout.frames + frame_capacity * @sizeOf(u64) ==
        identity_block_bytes + fault_block_bytes);
    std.debug.assert(recordLayout.breadcrumbs + breadcrumb_block_bytes == record_bytes);
    std.debug.assert(@sizeOf(Breadcrumb) == breadcrumb_entry_bytes);
    std.debug.assert(@offsetOf(Breadcrumb, "phase") == recordLayout.breadcrumb.phase);
    std.debug.assert(@offsetOf(Breadcrumb, "thread_id") == recordLayout.breadcrumb.thread_id);
    std.debug.assert(breadcrumb_capacity > 0 and
        breadcrumb_capacity & (breadcrumb_capacity - 1) == 0);
    std.debug.assert(frame_capacity <= std.math.maxInt(u8));
    std.debug.assert(record_magic.len == 8);
}

/// One live or recently finished Run, written by the worker that owns it.
pub const Breadcrumb = extern struct {
    task_id: u64 = 0,
    run_id: u64 = 0,
    started_at_unix_ms: i64 = 0,
    thread_id: u64 = 0,
    phase: u8 = @intFromEnum(BreadcrumbPhase.empty),
    reserved: [7]u8 = @splat(0),

    pub fn phaseValue(self: Breadcrumb) BreadcrumbPhase {
        return @enumFromInt(self.phase);
    }
};

// ---------------------------------------------------------------------------
// Install-time state
//
// The record buffer, the ring and the write handle are process-global because
// the handlers are: a signal or vectored handler receives no context pointer
// and must not reach for one.
// ---------------------------------------------------------------------------

var record_storage: [record_bytes]u8 align(16) = @splat(0);
var breadcrumbs: [breadcrumb_capacity]Breadcrumb = @splat(.{});
var breadcrumb_cursor: std.atomic.Value(u64) = .init(0);
var capture_attempts: std.atomic.Value(u32) = .init(0);
var record_handle: ?std.Io.File.Handle = null;
var installed: bool = false;
var frame_scratch: [frame_capacity]usize align(16) = @splat(0);

pub const InstallError = error{
    AlreadyInstalled,
    DataRootTooLong,
    DirectoryUnavailable,
    RecordFileUnavailable,
    /// A handle the handler cannot write synchronously is no use to it.
    RecordFileAsynchronous,
};

/// Installs process-wide fault capture. Call once, as early as a canonical
/// data root is known. Failure is never fatal: the caller logs it and starts.
pub fn install(io: std.Io, options: Options) InstallError!void {
    if (installed) return error.AlreadyInstalled;
    var path_storage: [4096]u8 = undefined;
    const directory = std.fmt.bufPrint(
        &path_storage,
        "{s}" ++ std.fs.path.sep_str ++ directory_name,
        .{options.data_root},
    ) catch return error.DataRootTooLong;
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, directory, .{
        .open_options = .{ .follow_symlinks = false },
        .permissions = directoryPermissions(),
    }) catch return error.DirectoryUnavailable;
    defer dir.close(io);
    // Never truncated: the previous process's record is the evidence this
    // process reports at startup, and a fault here overwrites it in place
    // with a record of identical length.
    const file = dir.createFile(io, record_file_name, .{
        .read = false,
        .truncate = false,
        .permissions = filePermissions(),
        .resolve_beneath = true,
    }) catch return error.RecordFileUnavailable;
    if (file.flags.nonblocking) {
        file.close(io);
        return error.RecordFileAsynchronous;
    }
    fillIdentity(options);
    // The handle outlives every other owner on purpose: it has to stay usable
    // from a handler during process teardown, and process exit closes it.
    record_handle = file.handle;
    installHandlers();
    installed = true;
}

pub fn isInstalled() bool {
    return installed;
}

/// Converts a 64-character hex digest into the raw bytes the record carries.
/// Comptime only: the composition root holds the digest as a string.
pub fn digestFromHex(comptime hex: []const u8) [32]u8 {
    return comptime value: {
        var out: [32]u8 = undefined;
        const decoded = std.fmt.hexToBytes(&out, hex) catch
            @compileError("AgentCore manifest digest is not hex");
        if (decoded.len != out.len) @compileError("AgentCore manifest digest is not 32 bytes");
        break :value out;
    };
}

fn fillIdentity(options: Options) void {
    @memset(record_storage[0..identity_block_bytes], 0);
    @memcpy(record_storage[recordLayout.magic..][0..record_magic.len], &record_magic);
    writeInt(u16, recordLayout.format, record_format);
    writeInt(u16, recordLayout.identity_bytes, @intCast(identity_block_bytes));
    writeInt(u16, recordLayout.fault_bytes, @intCast(fault_block_bytes));
    writeInt(u16, recordLayout.breadcrumb_bytes, @intCast(breadcrumb_entry_bytes));
    writeInt(u16, recordLayout.breadcrumb_count, @intCast(breadcrumb_capacity));
    record_storage[recordLayout.role] = @intFromEnum(options.role);
    record_storage[recordLayout.artifact_kind] = @intFromEnum(options.identity.artifact_kind);
    record_storage[recordLayout.optimize] = @intFromEnum(currentOptimizeMode());
    record_storage[recordLayout.os_tag] = @intFromEnum(currentOsTag());
    record_storage[recordLayout.arch] = @intFromEnum(currentArch());
    writeInt(u32, recordLayout.total_bytes, @intCast(record_bytes));
    writeInt(u32, recordLayout.pid, currentProcessId());
    writeInt(i64, recordLayout.process_started_at_unix_ms, currentUnixMs());
    writeInt(u16, recordLayout.core_abi_revision, options.identity.core_abi_revision);
    @memcpy(
        record_storage[recordLayout.core_manifest_sha256..][0..32],
        &options.identity.core_manifest_sha256,
    );
    const version_len = @min(options.identity.version.len, version_bytes);
    @memcpy(
        record_storage[recordLayout.version..][0..version_len],
        options.identity.version[0..version_len],
    );
    const module = moduleIdentity();
    record_storage[recordLayout.debug_id_kind] = @intFromEnum(module.kind);
    writeInt(u32, recordLayout.debug_id_age, module.age);
    @memcpy(record_storage[recordLayout.debug_id..][0..16], &module.id);
    writeInt(u64, recordLayout.module_base, module.base);
    writeInt(u64, recordLayout.module_bytes, module.bytes);
}

// ---------------------------------------------------------------------------
// Breadcrumbs
//
// Publish side: the worker that owns the Run. `beginRun` claims a slot with
// one masked `fetchAdd` and stores the identity before the phase, so a reader
// that sees `running` sees the identity with it. `finishRun` only marks the
// slot it claimed, and only while that slot still holds the same Run: once the
// ring has wrapped past it the slot belongs to a newer Run and must be left
// alone. `(task_id, run_id)` is unique per Run, so there is nothing to
// mistake it for.
// ---------------------------------------------------------------------------

/// Returns the claimed slot. Usable before `install`: without handlers the
/// ring is simply never read.
pub fn beginRun(task_id: u64, run_id: u64) u32 {
    const slot: u32 = @intCast(breadcrumb_cursor.fetchAdd(1, .monotonic) % breadcrumb_capacity);
    const entry = &breadcrumbs[slot];
    @atomicStore(u8, &entry.phase, @intFromEnum(BreadcrumbPhase.empty), .monotonic);
    @atomicStore(u64, &entry.task_id, task_id, .monotonic);
    @atomicStore(u64, &entry.run_id, run_id, .monotonic);
    @atomicStore(i64, &entry.started_at_unix_ms, currentUnixMs(), .monotonic);
    @atomicStore(u64, &entry.thread_id, currentThreadId(), .monotonic);
    @atomicStore(u8, &entry.phase, @intFromEnum(BreadcrumbPhase.running), .release);
    return slot;
}

pub fn finishRun(slot: u32, task_id: u64, run_id: u64) void {
    if (slot >= breadcrumb_capacity) return;
    const entry = &breadcrumbs[slot];
    if (@atomicLoad(u64, &entry.run_id, .monotonic) != run_id) return;
    if (@atomicLoad(u64, &entry.task_id, .monotonic) != task_id) return;
    @atomicStore(u8, &entry.phase, @intFromEnum(BreadcrumbPhase.finished), .release);
}

/// Test support: the ring and its cursor are process state that every test in
/// a binary shares.
pub fn resetBreadcrumbs() void {
    breadcrumbs = @splat(.{});
    breadcrumb_cursor.store(0, .monotonic);
}

pub fn breadcrumbSnapshot() [breadcrumb_capacity]Breadcrumb {
    return breadcrumbs;
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

const Facts = struct {
    kind: CaptureKind,
    code: u32 = 0,
    signal_code: u32 = 0,
    access_kind: u32 = std.math.maxInt(u32),
    address: u64 = 0,
    ip: u64 = 0,
    sp: u64 = 0,
    fp: u64 = 0,
};

/// Fills the fault block and lands the record. Async-signal-safe: no
/// allocation, no lock, no formatting, and every byte written comes from the
/// buffer the install reserved.
fn capture(facts: Facts) void {
    const attempts = capture_attempts.fetchAdd(1, .acq_rel);
    // The first fault owns the record. A second one -- another thread, or a
    // fault raised by this handler -- must neither race the writer nor
    // recurse into it.
    if (attempts != 0) return;
    record_storage[recordLayout.capture_kind] = @intFromEnum(facts.kind);
    record_storage[recordLayout.capture_attempts] = 1;
    record_storage[recordLayout.frame_count] = 0;
    writeInt(u32, recordLayout.code, facts.code);
    writeInt(u32, recordLayout.signal_code, facts.signal_code);
    writeInt(u32, recordLayout.access_kind, facts.access_kind);
    writeInt(u64, recordLayout.thread_id, currentThreadId());
    writeInt(u64, recordLayout.fault_address, facts.address);
    writeInt(u64, recordLayout.fault_ip, facts.ip);
    writeInt(u64, recordLayout.fault_sp, facts.sp);
    writeInt(u64, recordLayout.fault_fp, facts.fp);
    writeInt(i64, recordLayout.fault_at_unix_ms, currentUnixMs());
    writeInt(u64, recordLayout.breadcrumb_cursor, breadcrumb_cursor.load(.acquire));
    @memcpy(
        record_storage[recordLayout.breadcrumbs..][0..breadcrumb_block_bytes],
        std.mem.asBytes(&breadcrumbs)[0..breadcrumb_block_bytes],
    );
    @memset(record_storage[recordLayout.frames..][0 .. frame_capacity * @sizeOf(u64)], 0);
    // Land the complete record before unwinding anything. Collecting return
    // addresses means following the frame pointers or unwind tables of a
    // process that has already proved its state is wrong; if that faults, the
    // evidence is on disk already and the second fault returns above.
    writeRecord();
    const frames = captureFrames(facts);
    if (frames == 0) return;
    record_storage[recordLayout.frame_count] = @intCast(frames);
    record_storage[recordLayout.capture_attempts] =
        @intCast(@min(capture_attempts.load(.monotonic), std.math.maxInt(u8)));
    for (frame_scratch[0..frames], 0..) |address, index|
        writeInt(u64, recordLayout.frames + index * @sizeOf(u64), address);
    writeRecord();
}

/// Records the Runs a Zig panic interrupts. The SDK still owns the panic
/// path's own artifact; this adds only what that artifact cannot carry.
pub fn capturePanic(first_trace_address: ?usize) void {
    if (!installed) return;
    capture(.{ .kind = .zig_panic, .ip = first_trace_address orelse 0 });
}

/// Records a fault that `std.debug`'s own handler is about to abort on.
///
/// `std.start` attaches that handler whenever `runtime_safety` is on, which
/// includes the shipped ReleaseSafe build, and it treats every fault it
/// recognizes as fatal -- a first-chance access violation included. Capturing
/// through its root hook therefore records exactly the faults that are already
/// fatal in this process, which is why the vectored handler can stay narrow
/// and leave access violations alone: guessing which first-chance exception
/// resumes is the one thing it must not do. The vectored handler still runs
/// first for the trap codes it does recognize, so those records keep their
/// exact status code.
pub fn captureStandardSegfault(address: ?usize, ip: usize, fp: usize) void {
    if (!installed) return;
    capture(.{
        .kind = .standard_segfault,
        .address = address orelse 0,
        .ip = ip,
        .fp = fp,
    });
}

fn writeRecord() void {
    const handle = record_handle orelse return;
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var status: windows.IO_STATUS_BLOCK = undefined;
        var offset: windows.LARGE_INTEGER = 0;
        _ = windows.ntdll.NtWriteFile(
            handle,
            null,
            null,
            null,
            &status,
            &record_storage,
            @intCast(record_storage.len),
            &offset,
            null,
        );
    } else {
        _ = std.c.pwrite(handle, &record_storage, record_storage.len, 0);
    }
}

fn captureFrames(facts: Facts) usize {
    if (builtin.os.tag == .windows) {
        // Walks the unwind tables rather than a frame-pointer chain, which
        // optimized x86_64 code does not keep. The capture starts inside this
        // handler, so the first entries are the exception dispatcher's.
        const captured = std.os.windows.ntdll.RtlCaptureStackBackTrace(
            0,
            @intCast(frame_capacity),
            @ptrCast(&frame_scratch),
            null,
        );
        return @min(@as(usize, captured), frame_capacity);
    }
    // Both supported macOS architectures keep a frame-pointer chain:
    // [fp] is the caller's frame pointer, [fp + 8] its return address.
    var count: usize = 0;
    var frame: usize = std.math.cast(usize, facts.fp) orelse return 0;
    while (count < frame_capacity) {
        if (frame == 0 or frame % @alignOf(usize) != 0) break;
        const next = @as(*const usize, @ptrFromInt(frame)).*;
        const return_address = @as(*const usize, @ptrFromInt(frame + @sizeOf(usize))).*;
        if (return_address == 0) break;
        frame_scratch[count] = return_address;
        count += 1;
        // A chain must climb, and no single frame is 16 MiB deep. Anything
        // else is corruption, not a caller.
        if (next <= frame or next - frame > 16 * 1024 * 1024) break;
        frame = next;
    }
    return count;
}

fn installHandlers() void {
    if (builtin.os.tag == .windows) {
        Windows.install();
    } else {
        Posix.install();
    }
}

const Windows = struct {
    const Filter = *const fn (*std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long;

    /// Codes the vectored fallback accepts. Every one of them is fatal by
    /// construction in this process, which is what makes a first-chance
    /// observation safe: nothing here legitimately handles them and resumes.
    /// Access violations are deliberately absent -- they are the one code
    /// real libraries do handle first-chance -- and the unhandled filter
    /// covers the ones that go unhandled.
    const trap_codes = [_]u32{
        0xc000001d, // STATUS_ILLEGAL_INSTRUCTION: what -fsanitize-trap executes.
        0xc0000096, // STATUS_PRIVILEGED_INSTRUCTION
        0xc00000fd, // STATUS_STACK_OVERFLOW
        0xc0000374, // STATUS_HEAP_CORRUPTION
        0xc0000409, // STATUS_STACK_BUFFER_OVERRUN, when it is dispatched at all.
    };

    const sigabrt: c_int = 22;

    var previous_filter: ?Filter = null;
    var vectored_registration: ?*anyopaque = null;

    extern "kernel32" fn SetUnhandledExceptionFilter(filter: ?Filter) callconv(.winapi) ?Filter;

    extern "c" fn signal(
        signal_number: c_int,
        handler: ?*const fn (c_int) callconv(.c) void,
    ) callconv(.c) ?*const anyopaque;

    fn install() void {
        // The unhandled filter is the main surface. Chaining to whatever was
        // installed before keeps the process dying exactly as it does today.
        previous_filter = SetUnhandledExceptionFilter(unhandled);
        // The vectored handler is the fallback for trap codes the unhandled
        // filter can miss, and it has to sit at the FRONT of the chain rather
        // than the back: `std.debug`'s own vectored handler aborts the process
        // for several of these codes, so a handler registered behind it would
        // never run. Returning CONTINUE_SEARCH keeps this observational -- no
        // other SEH user loses its exception.
        vectored_registration = std.os.windows.ntdll.RtlAddVectoredExceptionHandler(1, vectored);
        // Only the C runtime's abort() raises this. Zig's own abort calls
        // RtlExitUserProcess directly and never arrives here.
        _ = signal(sigabrt, abort);
    }

    fn unhandled(pointers: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        capture(facts(.windows_unhandled_exception, pointers));
        if (previous_filter) |chain| return chain(pointers);
        return std.os.windows.EXCEPTION_CONTINUE_SEARCH;
    }

    fn vectored(pointers: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
        const code = pointers.ExceptionRecord.ExceptionCode;
        for (trap_codes) |trap| {
            if (code != trap) continue;
            capture(facts(.windows_vectored_exception, pointers));
            break;
        }
        return std.os.windows.EXCEPTION_CONTINUE_SEARCH;
    }

    fn abort(signal_number: c_int) callconv(.c) void {
        capture(.{ .kind = .abort_signal, .code = @bitCast(signal_number) });
        // Returning hands control back to the C runtime's abort(), which
        // terminates the process on its own.
    }

    fn facts(kind: CaptureKind, pointers: *std.os.windows.EXCEPTION_POINTERS) Facts {
        const record = pointers.ExceptionRecord;
        const registers = pointers.ContextRecord.getRegs();
        const violation = record.ExceptionCode == std.os.windows.EXCEPTION_ACCESS_VIOLATION;
        return .{
            .kind = kind,
            .code = record.ExceptionCode,
            .access_kind = if (violation and record.NumberParameters >= 1)
                @truncate(record.ExceptionInformation[0])
            else
                std.math.maxInt(u32),
            .address = if (violation and record.NumberParameters >= 2)
                record.ExceptionInformation[1]
            else
                @intFromPtr(record.ExceptionAddress),
            .ip = registers.ip,
            .sp = registers.sp,
            .fp = registers.bp,
        };
    }
};

const Posix = struct {
    const signals = [_]std.posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT, .TRAP };
    const alternate_stack_bytes: usize = 64 * 1024;

    var previous: [signals.len]std.posix.Sigaction = undefined;
    var alternate_stack: [alternate_stack_bytes]u8 align(16) = undefined;

    fn install() void {
        // `std.start` already attaches a per-thread alternate stack whenever
        // `std.options.signal_stack_size` is set, which is the default, so an
        // exhausted stack can still deliver on every thread the Zig standard
        // library created. Install one only where there is none.
        var current: std.posix.stack_t = undefined;
        const present = if (std.posix.sigaltstack(null, &current))
            current.flags & SS_DISABLE == 0
        else |_|
            false;
        if (!present) std.posix.sigaltstack(&.{
            .sp = &alternate_stack,
            .size = alternate_stack.len,
            .flags = 0,
        }, null) catch {};
        const action: std.posix.Sigaction = .{
            .handler = .{ .sigaction = handler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK,
        };
        for (signals, 0..) |signal_number, index|
            std.posix.sigaction(signal_number, &action, &previous[index]);
    }

    const SS_DISABLE: c_int = 4;

    fn handler(
        signal_number: std.posix.SIG,
        info: *const std.posix.siginfo_t,
        context: ?*anyopaque,
    ) callconv(.c) void {
        const registers = machineRegisters(context);
        capture(.{
            .kind = if (signal_number == .ABRT) .abort_signal else .posix_signal,
            .code = @intFromEnum(signal_number),
            .signal_code = @bitCast(info.code),
            .address = @intFromPtr(info.addr),
            .ip = registers.ip,
            .sp = registers.sp,
            .fp = registers.fp,
        });
        // Hand the fault on exactly as it would have gone without this
        // module: to whatever handler was installed before (`std.debug`'s,
        // which prints and aborts), otherwise to the default action. Nothing
        // here decides how the process dies.
        chain: {
            const index = for (signals, 0..) |candidate, slot| {
                if (candidate == signal_number) break slot;
            } else break :chain;
            const previous_action = previous[index];
            std.posix.sigaction(signal_number, &previous_action, null);
            if (previous_action.flags & std.posix.SA.SIGINFO != 0) {
                if (previous_action.handler.sigaction) |handle| {
                    handle(signal_number, info, context);
                    return;
                }
            } else if (previous_action.handler.handler) |handle| {
                const address = @intFromPtr(handle);
                // SIG_DFL and SIG_IGN are not functions to call.
                if (address != 0 and address != 1) {
                    handle(signal_number);
                    return;
                }
            }
        }
        // No previous handler to hand it to: raise it again so the default
        // action produces the usual termination status and the system's own
        // crash report. Returning instead would re-execute the faulting
        // instruction with this handler still installed, which is a loop.
        std.posix.sigaction(signal_number, &.{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        _ = std.c.kill(std.c.getpid(), signal_number);
    }

    const Registers = struct { ip: u64 = 0, sp: u64 = 0, fp: u64 = 0 };

    fn machineRegisters(context: ?*anyopaque) Registers {
        const value = context orelse return .{};
        const user: *const UserContext = @ptrCast(@alignCast(value));
        const machine: *const MachineContext = @ptrCast(@alignCast(user.machine orelse return .{}));
        return switch (builtin.cpu.arch) {
            .aarch64 => .{
                .ip = machine.thread.pc,
                .sp = machine.thread.sp,
                .fp = machine.thread.fp,
            },
            .x86_64 => .{
                .ip = machine.thread.rip,
                .sp = machine.thread.rsp,
                .fp = machine.thread.rbp,
            },
            else => .{},
        };
    }

    /// `struct __darwin_ucontext`. Only the machine context pointer is read.
    const UserContext = extern struct {
        on_stack: c_int,
        signal_mask: u32,
        stack_sp: ?*anyopaque,
        stack_size: usize,
        stack_flags: c_int,
        link: ?*anyopaque,
        machine_size: usize,
        machine: ?*anyopaque,
    };

    /// `_STRUCT_MCONTEXT64` for the two supported architectures. The record's
    /// own fault address, taken from `siginfo`, cross-checks the layout: a
    /// wrong offset here shows up immediately as an instruction pointer
    /// outside the loaded image.
    const MachineContext = switch (builtin.cpu.arch) {
        .aarch64 => extern struct {
            exception: extern struct { far: u64, esr: u32, exception: u32 },
            thread: extern struct {
                x: [29]u64,
                fp: u64,
                lr: u64,
                sp: u64,
                pc: u64,
                cpsr: u32,
                padding: u32,
            },
        },
        else => extern struct {
            exception: extern struct { trapno: u16, cpu: u16, err: u32, fault_address: u64 },
            thread: extern struct {
                rax: u64,
                rbx: u64,
                rcx: u64,
                rdx: u64,
                rdi: u64,
                rsi: u64,
                rbp: u64,
                rsp: u64,
                r8: u64,
                r9: u64,
                r10: u64,
                r11: u64,
                r12: u64,
                r13: u64,
                r14: u64,
                r15: u64,
                rip: u64,
                rflags: u64,
                cs: u64,
                fs: u64,
                gs: u64,
            },
        },
    };

    comptime {
        std.debug.assert(@offsetOf(UserContext, "machine") == 48);
        std.debug.assert(@offsetOf(MachineContext, "thread") == 16);
    }
};

// ---------------------------------------------------------------------------
// Startup and exit marker
//
// The marker lives in the single-instance lease file rather than a file of its
// own: the lease is the only authority for "this data root has one owner", and
// this machine shares a data root between the installed build and the
// development build. Holding the exclusive lease is what makes a leftover
// marker conclusive -- no live process can own it -- and the pid and version
// it carries say which build failed to clear it.
// ---------------------------------------------------------------------------

pub const marker_magic = "MWMARK01".*;
pub const marker_format: u16 = 1;
pub const marker_bytes: usize = 64;

pub const markerLayout = struct {
    pub const magic: usize = 0; // [8]u8
    pub const format: usize = 8; // u16
    pub const total_bytes: usize = 10; // u16
    pub const pid: usize = 12; // u32
    pub const started_at_unix_ms: usize = 16; // i64
    pub const role: usize = 24; // u8
    pub const artifact_kind: usize = 25; // u8
    // 26..32 reserved.
    pub const version: usize = 32; // [32]u8, zero padded
};

pub const Marker = struct {
    pid: u32,
    started_at_unix_ms: i64,
    role: Role,
    artifact_kind: ArtifactKind,
    version_storage: [version_bytes]u8,

    pub fn version(self: *const Marker) []const u8 {
        return std.mem.sliceTo(&self.version_storage, 0);
    }
};

pub fn encodeMarker(output: *[marker_bytes]u8, options: Options, started_at_unix_ms: i64) void {
    @memset(output, 0);
    @memcpy(output[markerLayout.magic..][0..marker_magic.len], &marker_magic);
    std.mem.writeInt(u16, output[markerLayout.format..][0..2], marker_format, .little);
    std.mem.writeInt(u16, output[markerLayout.total_bytes..][0..2], @intCast(marker_bytes), .little);
    std.mem.writeInt(u32, output[markerLayout.pid..][0..4], currentProcessId(), .little);
    std.mem.writeInt(i64, output[markerLayout.started_at_unix_ms..][0..8], started_at_unix_ms, .little);
    output[markerLayout.role] = @intFromEnum(options.role);
    output[markerLayout.artifact_kind] = @intFromEnum(options.identity.artifact_kind);
    const version_len = @min(options.identity.version.len, version_bytes);
    @memcpy(output[markerLayout.version..][0..version_len], options.identity.version[0..version_len]);
}

pub fn decodeMarker(bytes: []const u8) ?Marker {
    if (bytes.len < marker_bytes) return null;
    if (!std.mem.eql(u8, bytes[markerLayout.magic..][0..marker_magic.len], &marker_magic)) return null;
    if (std.mem.readInt(u16, bytes[markerLayout.format..][0..2], .little) != marker_format) return null;
    if (std.mem.readInt(u16, bytes[markerLayout.total_bytes..][0..2], .little) != marker_bytes) return null;
    var result: Marker = .{
        .pid = std.mem.readInt(u32, bytes[markerLayout.pid..][0..4], .little),
        .started_at_unix_ms = std.mem.readInt(i64, bytes[markerLayout.started_at_unix_ms..][0..8], .little),
        .role = switch (bytes[markerLayout.role]) {
            @intFromEnum(Role.ui) => .ui,
            else => return null,
        },
        .artifact_kind = artifactKind(bytes[markerLayout.artifact_kind]),
        .version_storage = undefined,
    };
    @memcpy(&result.version_storage, bytes[markerLayout.version..][0..version_bytes]);
    return result;
}

/// Reads any marker the previous owner left behind and publishes this
/// process's own, in that order. Only the lease holder may call it: the
/// exclusive lease is what makes a leftover marker mean "the last exit was not
/// clean" instead of "someone else is running".
pub fn adoptInstanceMarker(lease: std.Io.File, options: Options) ?Marker {
    var storage: [marker_bytes]u8 = @splat(0);
    const read = readAt(lease.handle, &storage, 0);
    const previous = if (read == marker_bytes) decodeMarker(&storage) else null;
    const started_at = std.mem.readInt(
        i64,
        record_storage[recordLayout.process_started_at_unix_ms..][0..8],
        .little,
    );
    encodeMarker(&storage, options, if (started_at != 0) started_at else currentUnixMs());
    writeAt(lease.handle, &storage, 0);
    return previous;
}

/// Clears the marker on a clean exit. Everything that is not this is an
/// unclean exit by definition.
pub fn clearInstanceMarker(lease: std.Io.File) void {
    const zeroes: [marker_bytes]u8 = @splat(0);
    writeAt(lease.handle, &zeroes, 0);
}

/// Positional reads and writes straight on the handle, bypassing `std.Io`.
///
/// `std.Io.Threaded` opens a Windows file requested with
/// `follow_symlinks = false` as an ASYNCHRONOUS handle while reporting it as
/// blocking, and both its positional and streaming paths answer the resulting
/// PENDING status with `unreachable`. The single-instance lease is opened
/// exactly that way whenever the lock file already exists, so the marker --
/// which has to go through the handle that holds the lock, because the lock
/// covers the byte it starts at -- does its own two syscalls instead of
/// panicking inside std. Failure is never fatal here: a marker that cannot be
/// read is simply no evidence, and one that cannot be written reports a clean
/// exit next time.
fn readAt(handle: std.Io.File.Handle, buffer: []u8, offset: u64) usize {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var status: windows.IO_STATUS_BLOCK = undefined;
        var position: windows.LARGE_INTEGER = @intCast(offset);
        switch (windows.ntdll.NtReadFile(
            handle,
            null,
            null,
            null,
            &status,
            buffer.ptr,
            @intCast(buffer.len),
            &position,
            null,
        )) {
            .SUCCESS => {},
            .PENDING => {
                // Asynchronous handle: the status block stays valid for this
                // wait, and a file object with no event signals completion.
                if (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null) != .SUCCESS)
                    return 0;
                if (status.u.Status != .SUCCESS) return 0;
            },
            else => return 0,
        }
        return status.Information;
    }
    const read = std.c.pread(handle, buffer.ptr, buffer.len, @intCast(offset));
    return if (read < 0) 0 else @intCast(read);
}

fn writeAt(handle: std.Io.File.Handle, bytes: []const u8, offset: u64) void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var status: windows.IO_STATUS_BLOCK = undefined;
        var position: windows.LARGE_INTEGER = @intCast(offset);
        switch (windows.ntdll.NtWriteFile(
            handle,
            null,
            null,
            null,
            &status,
            bytes.ptr,
            @intCast(bytes.len),
            &position,
            null,
        )) {
            .PENDING => _ = windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null),
            else => {},
        }
        return;
    }
    _ = std.c.pwrite(handle, bytes.ptr, bytes.len, @intCast(offset));
}

// ---------------------------------------------------------------------------
// Reading what the previous process left
// ---------------------------------------------------------------------------

pub const Record = struct {
    role: Role,
    artifact_kind: ArtifactKind,
    optimize: OptimizeMode,
    os_tag: OsTag,
    arch: Arch,
    pid: u32,
    process_started_at_unix_ms: i64,
    version_storage: [version_bytes]u8,
    core_manifest_sha256: [32]u8,
    core_abi_revision: u16,
    debug_id_kind: DebugIdKind,
    debug_id: [16]u8,
    debug_id_age: u32,
    module_base: u64,
    module_bytes: u64,
    fault: ?Fault,
    breadcrumb_cursor: u64,
    breadcrumbs: [breadcrumb_capacity]Breadcrumb,

    pub const Fault = struct {
        kind: CaptureKind,
        attempts: u8,
        code: u32,
        signal_code: u32,
        access_kind: ?u32,
        thread_id: u64,
        address: u64,
        ip: u64,
        sp: u64,
        fp: u64,
        at_unix_ms: i64,
        frame_count: u8,
        frames: [frame_capacity]u64,
    };

    pub fn version(self: *const Record) []const u8 {
        return std.mem.sliceTo(&self.version_storage, 0);
    }

    /// The Runs this record says were still executing.
    pub fn interruptedRuns(self: *const Record, output: []Breadcrumb) []Breadcrumb {
        var count: usize = 0;
        for (self.breadcrumbs) |entry| {
            if (entry.phaseValue() != .running) continue;
            if (count == output.len) break;
            output[count] = entry;
            count += 1;
        }
        return output[0..count];
    }
};

pub const DecodeError = error{ Malformed, UnsupportedFormat };

/// Strict by contract: a record whose own size fields disagree with this build
/// is undecodable evidence, not a record to interpret partially.
pub fn decodeRecord(bytes: []const u8) DecodeError!Record {
    if (bytes.len < record_bytes) return error.Malformed;
    if (!std.mem.eql(u8, bytes[recordLayout.magic..][0..record_magic.len], &record_magic))
        return error.Malformed;
    if (readInt(u16, bytes, recordLayout.format) != record_format) return error.UnsupportedFormat;
    if (readInt(u16, bytes, recordLayout.identity_bytes) != identity_block_bytes or
        readInt(u16, bytes, recordLayout.fault_bytes) != fault_block_bytes or
        readInt(u16, bytes, recordLayout.breadcrumb_bytes) != breadcrumb_entry_bytes or
        readInt(u16, bytes, recordLayout.breadcrumb_count) != breadcrumb_capacity or
        readInt(u32, bytes, recordLayout.total_bytes) != record_bytes)
        return error.UnsupportedFormat;
    var result: Record = .{
        .role = switch (bytes[recordLayout.role]) {
            @intFromEnum(Role.ui) => .ui,
            else => return error.Malformed,
        },
        .artifact_kind = artifactKind(bytes[recordLayout.artifact_kind]),
        .optimize = optimizeMode(bytes[recordLayout.optimize]),
        .os_tag = osTag(bytes[recordLayout.os_tag]),
        .arch = arch(bytes[recordLayout.arch]),
        .pid = readInt(u32, bytes, recordLayout.pid),
        .process_started_at_unix_ms = readInt(i64, bytes, recordLayout.process_started_at_unix_ms),
        .version_storage = undefined,
        .core_manifest_sha256 = undefined,
        .core_abi_revision = readInt(u16, bytes, recordLayout.core_abi_revision),
        .debug_id_kind = switch (bytes[recordLayout.debug_id_kind]) {
            @intFromEnum(DebugIdKind.pe_pdb70) => .pe_pdb70,
            @intFromEnum(DebugIdKind.macho_uuid) => .macho_uuid,
            else => .none,
        },
        .debug_id = undefined,
        .debug_id_age = readInt(u32, bytes, recordLayout.debug_id_age),
        .module_base = readInt(u64, bytes, recordLayout.module_base),
        .module_bytes = readInt(u64, bytes, recordLayout.module_bytes),
        .fault = null,
        .breadcrumb_cursor = readInt(u64, bytes, recordLayout.breadcrumb_cursor),
        .breadcrumbs = undefined,
    };
    @memcpy(&result.version_storage, bytes[recordLayout.version..][0..version_bytes]);
    @memcpy(&result.core_manifest_sha256, bytes[recordLayout.core_manifest_sha256..][0..32]);
    @memcpy(&result.debug_id, bytes[recordLayout.debug_id..][0..16]);
    const kind: CaptureKind = @enumFromInt(bytes[recordLayout.capture_kind]);
    if (kind != .none) {
        const access = readInt(u32, bytes, recordLayout.access_kind);
        var fault: Record.Fault = .{
            .kind = kind,
            .attempts = bytes[recordLayout.capture_attempts],
            .code = readInt(u32, bytes, recordLayout.code),
            .signal_code = readInt(u32, bytes, recordLayout.signal_code),
            .access_kind = if (access == std.math.maxInt(u32)) null else access,
            .thread_id = readInt(u64, bytes, recordLayout.thread_id),
            .address = readInt(u64, bytes, recordLayout.fault_address),
            .ip = readInt(u64, bytes, recordLayout.fault_ip),
            .sp = readInt(u64, bytes, recordLayout.fault_sp),
            .fp = readInt(u64, bytes, recordLayout.fault_fp),
            .at_unix_ms = readInt(i64, bytes, recordLayout.fault_at_unix_ms),
            .frame_count = bytes[recordLayout.frame_count],
            .frames = undefined,
        };
        if (fault.frame_count > frame_capacity) return error.Malformed;
        for (&fault.frames, 0..) |*frame, index|
            frame.* = readInt(u64, bytes, recordLayout.frames + index * @sizeOf(u64));
        result.fault = fault;
    }
    for (&result.breadcrumbs, 0..) |*entry, index| {
        const base = recordLayout.breadcrumbs + index * breadcrumb_entry_bytes;
        entry.* = .{
            .task_id = readInt(u64, bytes, base + recordLayout.breadcrumb.task_id),
            .run_id = readInt(u64, bytes, base + recordLayout.breadcrumb.run_id),
            .started_at_unix_ms = readInt(i64, bytes, base + recordLayout.breadcrumb.started_at_unix_ms),
            .thread_id = readInt(u64, bytes, base + recordLayout.breadcrumb.thread_id),
            .phase = bytes[base + recordLayout.breadcrumb.phase],
        };
    }
    return result;
}

/// Reads the record the previous process left, if any. Call before `install`:
/// install keeps the file's contents, but a fault in this process overwrites
/// them.
pub fn readRecord(io: std.Io, data_root: []const u8, storage: *[record_bytes]u8) ?Record {
    var path_storage: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_storage,
        "{s}" ++ std.fs.path.sep_str ++ directory_name ++ std.fs.path.sep_str ++ record_file_name,
        .{data_root},
    ) catch return null;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false }) catch
        return null;
    defer file.close(io);
    if (readAt(file.handle, storage, 0) < record_bytes) return null;
    return decodeRecord(storage) catch null;
}

pub const PreviousRun = struct {
    /// The marker the previous owner of the lease failed to clear. Present
    /// means the last exit was not clean.
    marker: ?Marker,
    record: ?Record,

    /// A record only describes this marker's process when both agree on who
    /// wrote them. The data root is shared between builds, and a record
    /// outlives the run that wrote it.
    pub fn faultOfLastExit(self: *const PreviousRun) ?Record {
        const marker = self.marker orelse return null;
        const record = self.record orelse return null;
        if (record.fault == null) return null;
        if (record.pid != marker.pid) return null;
        if (record.process_started_at_unix_ms != marker.started_at_unix_ms) return null;
        return record;
    }
};

/// Writes the human-readable summary next to the record and returns it. The
/// summary is the whole of C1's user-facing surface: the product-wide feedback
/// mechanism owns putting it in front of the user, and this module refuses to
/// grow a reporting channel of its own.
pub fn reportPreviousRun(
    io: std.Io,
    data_root: []const u8,
    previous: PreviousRun,
    storage: []u8,
) []const u8 {
    if (previous.marker == null) return "";
    const summary = describePreviousRun(previous, storage);
    var path_storage: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_storage,
        "{s}" ++ std.fs.path.sep_str ++ directory_name ++ std.fs.path.sep_str ++ report_file_name,
        .{data_root},
    ) catch return summary;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{
        .read = false,
        .truncate = true,
        .permissions = filePermissions(),
    }) catch return summary;
    defer file.close(io);
    file.writeStreamingAll(io, summary) catch {};
    return summary;
}

/// Formats what the previous process left into `storage`, newest fact first.
pub fn describePreviousRun(previous: PreviousRun, storage: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(storage);
    const marker = previous.marker orelse {
        writer.writeAll("The previous exit was clean.\n") catch {};
        return writer.buffered();
    };
    writer.print(
        "The previous run did not exit cleanly.\n" ++
            "  build: {s} {s} (pid {d}, started at unix ms {d})\n",
        .{ marker.version(), @tagName(marker.artifact_kind), marker.pid, marker.started_at_unix_ms },
    ) catch {};
    if (previous.faultOfLastExit()) |record| {
        const fault = record.fault.?;
        writer.print(
            "  fault: {s} code 0x{x} at unix ms {d}\n" ++
                "  thread: {d}  address: 0x{x}  ip: 0x{x}  module base: 0x{x}\n" ++
                "  frames:",
            .{
                @tagName(fault.kind),
                fault.code,
                fault.at_unix_ms,
                fault.thread_id,
                fault.address,
                fault.ip,
                record.module_base,
            },
        ) catch {};
        for (fault.frames[0..fault.frame_count]) |frame|
            writer.print(" 0x{x}", .{frame}) catch {};
        writer.writeAll("\n") catch {};
        var interrupted_storage: [breadcrumb_capacity]Breadcrumb = undefined;
        const interrupted = record.interruptedRuns(&interrupted_storage);
        if (interrupted.len == 0) {
            writer.writeAll("  no Task was executing a Run.\n") catch {};
        } else {
            writer.print("  {d} interrupted Run(s):\n", .{interrupted.len}) catch {};
            for (interrupted) |entry| writer.print(
                "    Task {d} Run {d} started at unix ms {d} on thread {d}{s}\n",
                .{
                    entry.task_id,
                    entry.run_id,
                    entry.started_at_unix_ms,
                    entry.thread_id,
                    if (entry.thread_id == fault.thread_id) " (the faulting thread)" else "",
                },
            ) catch {};
        }
    } else {
        writer.writeAll(
            "  no fault record for this exit: the process died without " ++
                "dispatching a fault, so the Runs it interrupted are unknown.\n",
        ) catch {};
    }
    return writer.buffered();
}

// ---------------------------------------------------------------------------
// Platform facts the record carries
// ---------------------------------------------------------------------------

const Module = struct {
    base: u64 = 0,
    bytes: u64 = 0,
    kind: DebugIdKind = .none,
    id: [16]u8 = @splat(0),
    age: u32 = 0,
};

fn moduleIdentity() Module {
    if (builtin.os.tag == .windows) return windowsModule();
    if (builtin.os.tag == .macos) return macosModule();
    return .{};
}

/// Reads the loaded image's CodeView debug directory. Install-time only, and
/// every offset is bounds-checked against the image's own `SizeOfImage`.
fn windowsModule() Module {
    const base = @intFromPtr(std.os.windows.peb().ImageBaseAddress);
    var result: Module = .{ .base = base };
    if (base == 0) return result;
    if (imageRead(u16, base, 0) != 0x5a4d) return result; // "MZ"
    const headers = imageRead(u32, base, 0x3c);
    if (headers == 0 or headers > 0x400) return result;
    if (imageRead(u32, base, headers) != 0x0000_4550) return result; // "PE\0\0"
    const optional = headers + 24;
    const directories = switch (imageRead(u16, base, optional)) {
        0x20b => optional + 112, // PE32+
        0x10b => optional + 96, // PE32
        else => return result,
    };
    const image_bytes = imageRead(u32, base, optional + 56);
    result.bytes = image_bytes;
    const debug_address = imageRead(u32, base, directories + 6 * 8);
    const debug_bytes = imageRead(u32, base, directories + 6 * 8 + 4);
    if (debug_address == 0 or debug_bytes < 28) return result;
    if (debug_address + debug_bytes > image_bytes) return result;
    var entry = debug_address;
    while (entry + 28 <= debug_address + debug_bytes) : (entry += 28) {
        if (imageRead(u32, base, entry + 12) != 2) continue; // IMAGE_DEBUG_TYPE_CODEVIEW
        const data_bytes = imageRead(u32, base, entry + 16);
        const data = imageRead(u32, base, entry + 20);
        if (data == 0 or data_bytes < 24 or data + data_bytes > image_bytes) continue;
        if (imageRead(u32, base, data) != 0x5344_5352) continue; // "RSDS"
        const source: [*]const u8 = @ptrFromInt(base + data + 4);
        @memcpy(&result.id, source[0..16]);
        result.age = imageRead(u32, base, data + 20);
        result.kind = .pe_pdb70;
        return result;
    }
    return result;
}

fn imageRead(comptime T: type, base: usize, offset: usize) T {
    return @as(*align(1) const T, @ptrFromInt(base + offset)).*;
}

/// Reads `LC_UUID` and the mapped size of `__TEXT` from the main executable's
/// Mach-O header. The header's own `vmaddr` is the pre-slide address, so the
/// base comes from dyld and only the size is taken from the segment.
fn macosModule() Module {
    const header = std.c._dyld_get_image_header(0) orelse return .{};
    const base = @intFromPtr(header);
    var result: Module = .{ .base = base };
    if (imageRead(u32, base, 0) != 0xfeed_facf) return result; // MH_MAGIC_64
    const command_count = imageRead(u32, base, 16);
    if (command_count > 1024) return result;
    var offset: usize = 32; // sizeof(mach_header_64)
    for (0..command_count) |_| {
        const command = imageRead(u32, base, offset);
        const command_bytes = imageRead(u32, base, offset + 4);
        if (command_bytes < 8) break;
        if (command == 0x1b and command_bytes >= 24) { // LC_UUID
            const source: [*]const u8 = @ptrFromInt(base + offset + 8);
            @memcpy(&result.id, source[0..16]);
            result.kind = .macho_uuid;
        }
        // LC_SEGMENT_64: cmd, cmdsize, segname[16], vmaddr, vmsize, ...
        if (command == 0x19 and command_bytes >= 48 and std.mem.eql(
            u8,
            @as([*]const u8, @ptrFromInt(base + offset + 8))[0..16],
            "__TEXT" ++ [_]u8{0} ** 10,
        )) result.bytes = imageRead(u64, base, offset + 32);
        offset += command_bytes;
    }
    return result;
}

fn currentProcessId() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @bitCast(std.c.getpid());
}

fn currentThreadId() u64 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentThreadId();
    return std.Thread.getCurrentId();
}

/// Wall clock, readable from a handler. Windows reads the shared kernel page
/// the same way `GetSystemTimeAsFileTime` does; POSIX uses `clock_gettime`,
/// which POSIX itself lists as async-signal-safe.
fn currentUnixMs() i64 {
    if (builtin.os.tag == .windows) {
        const shared: *const volatile std.os.windows.KUSER_SHARED_DATA =
            std.os.windows.SharedUserData;
        while (true) {
            const high = shared.SystemTime.High1Time;
            const low = shared.SystemTime.LowPart;
            if (shared.SystemTime.High2Time != high) continue;
            const ticks: i64 = (@as(i64, high) << 32) | @as(i64, low);
            // 100 ns ticks since 1601-01-01; 11644473600 s to the Unix epoch.
            return @divFloor(ticks - 116_444_736_000_000_000, 10_000);
        }
    }
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &now) != 0) return 0;
    return @as(i64, now.sec) * 1000 + @divFloor(@as(i64, now.nsec), 1_000_000);
}

fn currentOptimizeMode() OptimizeMode {
    return switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .release_safe,
        .ReleaseFast => .release_fast,
        .ReleaseSmall => .release_small,
    };
}

fn currentOsTag() OsTag {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .other,
    };
}

fn currentArch() Arch {
    return switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => .other,
    };
}

fn artifactKind(value: u8) ArtifactKind {
    return switch (value) {
        @intFromEnum(ArtifactKind.development) => .development,
        @intFromEnum(ArtifactKind.release) => .release,
        @intFromEnum(ArtifactKind.automation) => .automation,
        else => .unknown,
    };
}

fn optimizeMode(value: u8) OptimizeMode {
    return switch (value) {
        @intFromEnum(OptimizeMode.debug) => .debug,
        @intFromEnum(OptimizeMode.release_safe) => .release_safe,
        @intFromEnum(OptimizeMode.release_fast) => .release_fast,
        @intFromEnum(OptimizeMode.release_small) => .release_small,
        else => .unknown,
    };
}

fn osTag(value: u8) OsTag {
    return switch (value) {
        @intFromEnum(OsTag.windows) => .windows,
        @intFromEnum(OsTag.macos) => .macos,
        else => .other,
    };
}

fn arch(value: u8) Arch {
    return switch (value) {
        @intFromEnum(Arch.x86_64) => .x86_64,
        @intFromEnum(Arch.aarch64) => .aarch64,
        else => .other,
    };
}

fn writeInt(comptime T: type, offset: usize, value: T) void {
    std.mem.writeInt(T, record_storage[offset..][0..@divExact(@bitSizeOf(T), 8)], value, .little);
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}

fn directoryPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

fn filePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_identity: Identity = .{
    .version = "0.2.13",
    .artifact_kind = .development,
    .core_manifest_sha256 = @splat(0xab),
    .core_abi_revision = 28,
};

test "the record layout is exactly the reviewed byte layout" {
    try std.testing.expectEqual(@as(usize, 160), identity_block_bytes);
    try std.testing.expectEqual(@as(usize, 328), fault_block_bytes);
    try std.testing.expectEqual(@as(usize, 40), breadcrumb_entry_bytes);
    try std.testing.expectEqual(@as(usize, 1280), breadcrumb_block_bytes);
    try std.testing.expectEqual(@as(usize, 1768), record_bytes);
    try std.testing.expectEqual(@as(usize, 160), recordLayout.capture_kind);
    try std.testing.expectEqual(@as(usize, 232), recordLayout.frames);
    try std.testing.expectEqual(@as(usize, 488), recordLayout.breadcrumbs);
    try std.testing.expectEqual(@as(usize, 64), marker_bytes);
}

test "an installed identity block decodes with no fault and no breadcrumbs" {
    resetBreadcrumbs();
    capture_attempts.store(0, .monotonic);
    fillIdentity(.{ .role = .ui, .data_root = "", .identity = test_identity });
    const decoded = try decodeRecord(&record_storage);
    try std.testing.expectEqual(Role.ui, decoded.role);
    try std.testing.expectEqual(ArtifactKind.development, decoded.artifact_kind);
    try std.testing.expectEqual(currentOptimizeMode(), decoded.optimize);
    try std.testing.expectEqual(currentOsTag(), decoded.os_tag);
    try std.testing.expectEqual(currentArch(), decoded.arch);
    try std.testing.expectEqualStrings("0.2.13", decoded.version());
    try std.testing.expectEqual(@as(u16, 28), decoded.core_abi_revision);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xab)), &decoded.core_manifest_sha256);
    try std.testing.expectEqual(currentProcessId(), decoded.pid);
    try std.testing.expect(decoded.process_started_at_unix_ms > 1_700_000_000_000);
    try std.testing.expect(decoded.fault == null);
    // Both supported platforms publish an image identity; nothing else does.
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) {
        try std.testing.expect(decoded.module_base != 0);
        try std.testing.expect(decoded.debug_id_kind != .none);
        try std.testing.expect(!std.mem.allEqual(u8, &decoded.debug_id, 0));
    }
}

test "a captured fault carries the live Runs and leaves finished ones behind" {
    resetBreadcrumbs();
    capture_attempts.store(0, .monotonic);
    fillIdentity(.{ .role = .ui, .data_root = "", .identity = test_identity });
    const finished = beginRun(7, 1);
    finishRun(finished, 7, 1);
    const live = beginRun(7, 2);
    _ = beginRun(9, 1);
    // No handle: capture fills the buffer and the write is a no-op.
    record_handle = null;
    capture(.{ .kind = .posix_signal, .code = 11, .address = 0x1234, .ip = 0x5678 });
    const decoded = try decodeRecord(&record_storage);
    const fault = decoded.fault orelse return error.MissingFault;
    try std.testing.expectEqual(CaptureKind.posix_signal, fault.kind);
    try std.testing.expectEqual(@as(u32, 11), fault.code);
    try std.testing.expectEqual(@as(u64, 0x1234), fault.address);
    try std.testing.expectEqual(@as(u64, 0x5678), fault.ip);
    try std.testing.expectEqual(currentThreadId(), fault.thread_id);
    try std.testing.expectEqual(@as(u64, 3), decoded.breadcrumb_cursor);
    var storage: [breadcrumb_capacity]Breadcrumb = undefined;
    const interrupted = decoded.interruptedRuns(&storage);
    try std.testing.expectEqual(@as(usize, 2), interrupted.len);
    try std.testing.expectEqual(@as(u64, 7), interrupted[0].task_id);
    try std.testing.expectEqual(@as(u64, 2), interrupted[0].run_id);
    try std.testing.expectEqual(@as(u64, 9), interrupted[1].task_id);
    try std.testing.expectEqual(currentThreadId(), interrupted[0].thread_id);
    try std.testing.expectEqual(
        BreadcrumbPhase.finished,
        decoded.breadcrumbs[finished].phaseValue(),
    );
    _ = live;
    // A second fault must not overwrite the first record.
    capture(.{ .kind = .abort_signal, .code = 6 });
    const after = try decodeRecord(&record_storage);
    try std.testing.expectEqual(CaptureKind.posix_signal, after.fault.?.kind);
}

test "a finish after the ring wraps leaves the newer Run alone" {
    resetBreadcrumbs();
    const slot = beginRun(1, 1);
    for (0..breadcrumb_capacity) |index| _ = beginRun(2, index + 1);
    try std.testing.expectEqual(BreadcrumbPhase.running, breadcrumbSnapshot()[slot].phaseValue());
    finishRun(slot, 1, 1);
    const entry = breadcrumbSnapshot()[slot];
    try std.testing.expectEqual(BreadcrumbPhase.running, entry.phaseValue());
    try std.testing.expectEqual(@as(u64, 2), entry.task_id);
}

test "the ring holds every Run the host pool can execute at once" {
    // Sized against the Application's own worker count, which bounds how many
    // Runs can be live: see the constant's comment.
    try std.testing.expect(breadcrumb_capacity >= 2 * 16);
}

test "record decoding refuses foreign and short records" {
    fillIdentity(.{ .role = .ui, .data_root = "", .identity = test_identity });
    var bytes = record_storage;
    try std.testing.expectError(error.Malformed, decodeRecord(bytes[0 .. record_bytes - 1]));
    bytes[0] = 'X';
    try std.testing.expectError(error.Malformed, decodeRecord(&bytes));
    bytes = record_storage;
    std.mem.writeInt(u16, bytes[recordLayout.format..][0..2], record_format + 1, .little);
    try std.testing.expectError(error.UnsupportedFormat, decodeRecord(&bytes));
    bytes = record_storage;
    std.mem.writeInt(u16, bytes[recordLayout.breadcrumb_count..][0..2], 8, .little);
    try std.testing.expectError(error.UnsupportedFormat, decodeRecord(&bytes));
    bytes = record_storage;
    bytes[recordLayout.role] = 0;
    try std.testing.expectError(error.Malformed, decodeRecord(&bytes));
}

test "a leftover marker on a held lease is the unclean exit, and clearing it is the clean one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const lease = try tmp.dir.createFile(std.testing.io, "lease", .{ .read = true, .truncate = false });
    defer lease.close(std.testing.io);
    const options: Options = .{ .role = .ui, .data_root = root, .identity = test_identity };

    fillIdentity(options);
    try std.testing.expect(adoptInstanceMarker(lease, options) == null);
    const leftover = adoptInstanceMarker(lease, options) orelse
        return error.MissingMarker;
    try std.testing.expectEqual(currentProcessId(), leftover.pid);
    try std.testing.expectEqualStrings("0.2.13", leftover.version());
    try std.testing.expectEqual(ArtifactKind.development, leftover.artifact_kind);
    clearInstanceMarker(lease);
    try std.testing.expect(adoptInstanceMarker(lease, options) == null);
}

test "the marker survives the asynchronous handle the real lease is opened with" {
    // `app_single_instance.openOrCreateLock` opens an existing lock file with
    // `follow_symlinks = false`, and on Windows `std.Io.Threaded` turns that
    // into an ASYNCHRONOUS handle whose positional and streaming paths in std
    // answer PENDING with `unreachable`. This is the handle the marker is
    // written through on every launch after the first, so it has to be the
    // handle the test uses.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const created = try tmp.dir.createFile(std.testing.io, "lease", .{ .truncate = false });
    created.close(std.testing.io);
    const lease = try tmp.dir.openFile(std.testing.io, "lease", .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer lease.close(std.testing.io);
    const options: Options = .{ .role = .ui, .data_root = root, .identity = test_identity };
    fillIdentity(options);
    try std.testing.expect(adoptInstanceMarker(lease, options) == null);
    const leftover = adoptInstanceMarker(lease, options) orelse return error.MissingMarker;
    try std.testing.expectEqual(currentProcessId(), leftover.pid);
    clearInstanceMarker(lease);
    try std.testing.expect(adoptInstanceMarker(lease, options) == null);
}

test "a fault record is only attributed to the exit that wrote it" {
    resetBreadcrumbs();
    capture_attempts.store(0, .monotonic);
    record_handle = null;
    fillIdentity(.{ .role = .ui, .data_root = "", .identity = test_identity });
    _ = beginRun(4, 9);
    capture(.{ .kind = .windows_vectored_exception, .code = 0xc000001d });
    const record = try decodeRecord(&record_storage);
    const matching: PreviousRun = .{
        .marker = .{
            .pid = record.pid,
            .started_at_unix_ms = record.process_started_at_unix_ms,
            .role = .ui,
            .artifact_kind = .development,
            .version_storage = @splat(0),
        },
        .record = record,
    };
    try std.testing.expect(matching.faultOfLastExit() != null);
    var report_storage: [4096]u8 = undefined;
    const described = describePreviousRun(matching, &report_storage);
    try std.testing.expect(std.mem.indexOf(u8, described, "did not exit cleanly") != null);
    try std.testing.expect(std.mem.indexOf(u8, described, "Task 4 Run 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, described, "the faulting thread") != null);

    var stale = matching;
    stale.marker.?.pid = record.pid + 1;
    try std.testing.expect(stale.faultOfLastExit() == null);
    const unknown = describePreviousRun(stale, &report_storage);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "no fault record for this exit") != null);

    const clean: PreviousRun = .{ .marker = null, .record = record };
    try std.testing.expect(clean.faultOfLastExit() == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        describePreviousRun(clean, &report_storage),
        "exit was clean",
    ) != null);
}

test "install opens one record file, keeps the previous record, and reports it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const options: Options = .{ .role = .ui, .data_root = root, .identity = test_identity };

    // No record yet.
    var storage: [record_bytes]u8 = undefined;
    try std.testing.expect(readRecord(std.testing.io, root, &storage) == null);

    // Install writes nothing by itself, so a record only appears once a fault
    // lands one. Drive that without installing handlers in the test process.
    resetBreadcrumbs();
    capture_attempts.store(0, .monotonic);
    fillIdentity(options);
    var directory_storage: [4096]u8 = undefined;
    const dir = try std.Io.Dir.cwd().createDirPathOpen(std.testing.io, try std.fmt.bufPrint(
        &directory_storage,
        "{s}" ++ std.fs.path.sep_str ++ directory_name,
        .{root},
    ), .{ .permissions = directoryPermissions() });
    defer dir.close(std.testing.io);
    const file = try dir.createFile(std.testing.io, record_file_name, .{ .truncate = false });
    record_handle = file.handle;
    _ = beginRun(11, 3);
    capture(.{ .kind = .windows_unhandled_exception, .code = 0xc0000005, .address = 8 });
    record_handle = null;
    file.close(std.testing.io);

    const previous = readRecord(std.testing.io, root, &storage) orelse return error.MissingRecord;
    try std.testing.expectEqual(@as(u32, 0xc0000005), previous.fault.?.code);
    var report_storage: [4096]u8 = undefined;
    const summary = reportPreviousRun(std.testing.io, root, .{
        .marker = .{
            .pid = previous.pid,
            .started_at_unix_ms = previous.process_started_at_unix_ms,
            .role = .ui,
            .artifact_kind = .development,
            .version_storage = @splat(0),
        },
        .record = previous,
    }, &report_storage);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Task 11 Run 3") != null);
    var report_path: [4096]u8 = undefined;
    const written = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        try std.fmt.bufPrint(
            &report_path,
            "{s}" ++ std.fs.path.sep_str ++ directory_name ++ std.fs.path.sep_str ++ report_file_name,
            .{root},
        ),
        std.testing.allocator,
        .limited(8 * 1024),
    );
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(summary, written);
}

test "the digest helper decodes the manifest hex the composition root holds" {
    const digest = digestFromHex("00" ++ "ff" ** 31);
    try std.testing.expectEqual(@as(u8, 0), digest[0]);
    try std.testing.expectEqual(@as(u8, 0xff), digest[31]);
}
