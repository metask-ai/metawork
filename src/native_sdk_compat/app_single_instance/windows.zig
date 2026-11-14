//! Windows app-instance transport: current-user Named Pipe and fixed prompt.

const std = @import("std");
const builtin = @import("builtin");
const thread_stack = @import("metawork_thread_stack");
const contract = @import("../app_single_instance.zig");

const HANDLE = ?*anyopaque;
const HLOCAL = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;
const ULONG = u32;
const PSID = ?*anyopaque;

const SecurityAttributes = extern struct {
    length: DWORD,
    security_descriptor: ?*anyopaque,
    inherit_handle: BOOL,
};

const SidAndAttributes = extern struct {
    sid: PSID,
    attributes: DWORD,
};

const TokenUser = extern struct {
    user: SidAndAttributes,
};

const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const token_query: DWORD = 0x0008;
const token_user_class: DWORD = 1;
const error_insufficient_buffer: DWORD = 122;
const error_pipe_connected: DWORD = 535;
const error_pipe_busy: DWORD = 231;
const error_file_not_found: DWORD = 2;
const error_no_data: DWORD = 232;
const error_operation_aborted: DWORD = 995;
const generic_read: DWORD = 0x8000_0000;
const generic_write: DWORD = 0x4000_0000;
const open_existing: DWORD = 3;
const pipe_access_duplex: DWORD = 0x0000_0003;
const file_flag_first_pipe_instance: DWORD = 0x0008_0000;
const pipe_type_message: DWORD = 0x0000_0004;
const pipe_readmode_message: DWORD = 0x0000_0002;
const pipe_nowait: DWORD = 0x0000_0001;
const pipe_wait: DWORD = 0;
const pipe_reject_remote_clients: DWORD = 0x0000_0008;
const sddl_revision_1: DWORD = 1;
const mb_ok: u32 = 0;
const mb_iconerror: u32 = 0x10;
const mb_setforeground: u32 = 0x0001_0000;
const response_timeout_ms: u64 = 3000;
const retry_interval_ms: u64 = 20;

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "advapi32" fn OpenProcessToken(HANDLE, DWORD, *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(HANDLE, DWORD, ?*anyopaque, DWORD, *DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn GetLengthSid(PSID) callconv(.winapi) DWORD;
extern "advapi32" fn ConvertSidToStringSidW(PSID, *?[*:0]u16) callconv(.winapi) BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, DWORD, *?*anyopaque, ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(HLOCAL) callconv(.winapi) HLOCAL;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateNamedPipeW([*:0]const u16, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, *const SecurityAttributes) callconv(.winapi) HANDLE;
extern "kernel32" fn ConnectNamedPipe(HANDLE, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn DisconnectNamedPipe(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn FlushFileBuffers(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, *DWORD, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, *DWORD, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW([*:0]const u16, DWORD, DWORD, ?*const SecurityAttributes, DWORD, DWORD, HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn SetNamedPipeHandleState(HANDLE, ?*const DWORD, ?*const DWORD, ?*const DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(HANDLE, *ULONG) callconv(.winapi) BOOL;
extern "kernel32" fn CancelSynchronousIo(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "user32" fn AllowSetForegroundWindow(DWORD) callconv(.winapi) BOOL;
extern "user32" fn MessageBoxW(HANDLE, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;

const OwnedSid = struct {
    allocator: std.mem.Allocator,
    buffer: []align(@alignOf(TokenUser)) u8,
    sid: PSID,

    fn deinit(self: *OwnedSid) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
};

const Security = struct {
    descriptor: ?*anyopaque,
    sid_digest: [32]u8,

    fn deinit(self: *Security) void {
        _ = LocalFree(self.descriptor);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    pipe_name: [:0]u16,
    pipe: HANDLE,
    handler: contract.Handler,
    stopping: std.atomic.Value(bool) = .init(false),
    test_joining: if (builtin.is_test) std.atomic.Value(bool) else void = if (builtin.is_test) .init(false) else {},
    thread: ?std.Thread = null,
    request: [contract.max_transport_request_bytes]u8 = undefined,
    response: [contract.max_transport_response_bytes]u8 = undefined,

    fn run(self: *State) void {
        defer {
            _ = DisconnectNamedPipe(self.pipe);
            _ = CloseHandle(self.pipe);
            self.pipe = null;
        }
        while (!self.stopping.load(.acquire)) {
            const connected = ConnectNamedPipe(self.pipe, null) != 0 or
                GetLastError() == error_pipe_connected;
            if (!connected) {
                if (self.stopping.load(.acquire) or
                    GetLastError() == error_operation_aborted) break;
                continue;
            }
            if (self.stopping.load(.acquire)) break;

            var request_len: DWORD = 0;
            if (ReadFile(
                self.pipe,
                &self.request,
                @intCast(self.request.len),
                &request_len,
                null,
            ) != 0 and request_len != 0) {
                const response_len = self.handler.handle(
                    self.request[0..request_len],
                    &self.response,
                );
                if (response_len > 0 and response_len <= self.response.len) {
                    var written: DWORD = 0;
                    _ = WriteFile(
                        self.pipe,
                        &self.response,
                        @intCast(response_len),
                        &written,
                        null,
                    );
                    _ = FlushFileBuffers(self.pipe);
                }
            }
            _ = DisconnectNamedPipe(self.pipe);
        }
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    state: *State,

    pub fn init(
        allocator: std.mem.Allocator,
        canonical_data_root: []const u8,
        handler: contract.Handler,
    ) !Server {
        var security = try currentUserSecurity(allocator);
        defer security.deinit();
        const pipe_name = try pipeName(allocator, security.sid_digest, canonical_data_root);
        errdefer allocator.free(pipe_name);
        var attributes = SecurityAttributes{
            .length = @sizeOf(SecurityAttributes),
            .security_descriptor = security.descriptor,
            .inherit_handle = 0,
        };
        const pipe = CreateNamedPipeW(
            pipe_name.ptr,
            pipe_access_duplex | file_flag_first_pipe_instance,
            pipe_type_message | pipe_readmode_message | pipe_wait | pipe_reject_remote_clients,
            1,
            contract.max_transport_response_bytes,
            contract.max_transport_request_bytes,
            0,
            &attributes,
        );
        if (pipe == invalid_handle) return error.EndpointUnavailable;
        errdefer _ = CloseHandle(pipe);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .pipe_name = pipe_name,
            .pipe = pipe,
            .handler = handler,
        };
        state.thread = try std.Thread.spawn(thread_stack.config, State.run, .{state});
        return .{ .allocator = allocator, .state = state };
    }

    pub fn stop(self: *Server) void {
        const state = self.state;
        if (state.stopping.swap(true, .acq_rel)) return;
        if (state.thread) |thread| {
            // A wake client covers the gap before ConnectNamedPipe becomes a
            // pending synchronous operation. Cancellation separately covers
            // a listener already blocked in Connect/Read/Write.
            const wake_pipe = CreateFileW(
                state.pipe_name.ptr,
                generic_read | generic_write,
                0,
                null,
                open_existing,
                0,
                null,
            );
            if (wake_pipe != invalid_handle) _ = CloseHandle(wake_pipe);
            _ = CancelSynchronousIo(thread.getHandle());
            if (builtin.is_test) state.test_joining.store(true, .release);
            thread.join();
            state.thread = null;
        }
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        const state = self.state;
        self.allocator.free(state.pipe_name);
        self.allocator.destroy(state);
        self.* = undefined;
    }

    pub const joiningForTest = if (builtin.is_test) struct {
        fn read(self: *const Server) bool {
            return self.state.test_joining.load(.acquire);
        }
    }.read else {};
};

pub fn forward(
    allocator: std.mem.Allocator,
    canonical_data_root: []const u8,
    request: []const u8,
    response: []u8,
) !usize {
    var sid = try currentSid(allocator);
    defer sid.deinit();
    var sid_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        @as([*]const u8, @ptrCast(sid.sid))[0..GetLengthSid(sid.sid)],
        &sid_digest,
        .{},
    );
    const name = try pipeName(allocator, sid_digest, canonical_data_root);
    defer allocator.free(name);

    const pipe = CreateFileW(
        name.ptr,
        generic_read | generic_write,
        0,
        null,
        open_existing,
        0,
        null,
    );
    if (pipe == invalid_handle) return switch (GetLastError()) {
        error_pipe_busy, error_file_not_found => error.EndpointUnavailable,
        else => error.TransferFailed,
    };
    defer _ = CloseHandle(pipe);

    var mode: DWORD = pipe_readmode_message | pipe_nowait;
    if (SetNamedPipeHandleState(pipe, &mode, null, null) == 0)
        return error.EndpointUnavailable;
    var primary_pid: ULONG = 0;
    if (GetNamedPipeServerProcessId(pipe, &primary_pid) != 0)
        _ = AllowSetForegroundWindow(primary_pid);

    var written: DWORD = 0;
    if (WriteFile(pipe, request.ptr, @intCast(request.len), &written, null) == 0 or
        written != request.len)
        return error.TransferFailed;

    const response_deadline = GetTickCount64() + response_timeout_ms;
    while (GetTickCount64() < response_deadline) {
        var read: DWORD = 0;
        if (ReadFile(pipe, response.ptr, @intCast(response.len), &read, null) != 0)
            return read;
        const err = GetLastError();
        if (err != error_no_data) return error.TransferFailed;
        Sleep(@intCast(retry_interval_ms));
    }
    return error.ResponseTimeout;
}

pub fn reportFailure(failure: contract.Failure) void {
    @setEvalBranchQuota(5000);
    const text = switch (failure) {
        .startup_failed => std.unicode.utf8ToUtf16LeStringLiteral(
            contract.failure_messages.startup_failed,
        ),
        .incompatible => std.unicode.utf8ToUtf16LeStringLiteral(
            contract.failure_messages.incompatible,
        ),
        .primary_unresponsive => std.unicode.utf8ToUtf16LeStringLiteral(
            contract.failure_messages.primary_unresponsive,
        ),
        .rejected => std.unicode.utf8ToUtf16LeStringLiteral(
            contract.failure_messages.rejected,
        ),
    };
    _ = MessageBoxW(
        null,
        text,
        std.unicode.utf8ToUtf16LeStringLiteral("MetaWork"),
        mb_ok | mb_iconerror | mb_setforeground,
    );
}

fn currentUserSecurity(allocator: std.mem.Allocator) !Security {
    var sid = try currentSid(allocator);
    defer sid.deinit();
    var sid_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        @as([*]const u8, @ptrCast(sid.sid))[0..GetLengthSid(sid.sid)],
        &sid_digest,
        .{},
    );
    var sid_string: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(sid.sid, &sid_string) == 0)
        return error.SecurityUnavailable;
    defer _ = LocalFree(@ptrCast(sid_string));

    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(")");
    const sid_length = std.mem.len(sid_string.?);
    var sddl: [512:0]u16 = undefined;
    if (prefix.len + sid_length + suffix.len >= sddl.len)
        return error.SecurityUnavailable;
    var cursor: usize = 0;
    @memcpy(sddl[cursor..][0..prefix.len], prefix);
    cursor += prefix.len;
    @memcpy(sddl[cursor..][0..sid_length], sid_string.?[0..sid_length]);
    cursor += sid_length;
    @memcpy(sddl[cursor..][0..suffix.len], suffix);
    cursor += suffix.len;
    sddl[cursor] = 0;

    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
        &sddl,
        sddl_revision_1,
        &descriptor,
        null,
    ) == 0) return error.SecurityUnavailable;
    return .{ .descriptor = descriptor, .sid_digest = sid_digest };
}

fn currentSid(allocator: std.mem.Allocator) !OwnedSid {
    var token: HANDLE = null;
    if (OpenProcessToken(GetCurrentProcess(), token_query, &token) == 0)
        return error.SecurityUnavailable;
    defer _ = CloseHandle(token);
    var required: DWORD = 0;
    _ = GetTokenInformation(token, token_user_class, null, 0, &required);
    if (required == 0 or GetLastError() != error_insufficient_buffer)
        return error.SecurityUnavailable;
    const buffer = try allocator.alignedAlloc(
        u8,
        std.mem.Alignment.of(TokenUser),
        required,
    );
    errdefer allocator.free(buffer);
    if (GetTokenInformation(
        token,
        token_user_class,
        buffer.ptr,
        required,
        &required,
    ) == 0) return error.SecurityUnavailable;
    const token_user: *const TokenUser = @ptrCast(@alignCast(buffer.ptr));
    if (token_user.user.sid == null or GetLengthSid(token_user.user.sid) == 0)
        return error.SecurityUnavailable;
    return .{ .allocator = allocator, .buffer = buffer, .sid = token_user.user.sid };
}

fn pipeName(
    allocator: std.mem.Allocator,
    sid_digest: [32]u8,
    canonical_data_root: []const u8,
) ![:0]u16 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&sid_digest);
    hash.update(canonical_data_root);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var utf8: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&utf8, "\\\\.\\pipe\\metawork-{s}", .{hex});
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
}
