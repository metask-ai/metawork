const std = @import("std");

var original_io: std.Io = undefined;
var spawn_mutex: std.Io.Mutex = .init;

// Zig 0.16 creates inheritable pipe handles before calling CreateProcessW.
// Concurrent spawns can pass a test runner's pipes to unrelated children and
// delay EOF after that runner exits. Lock only spawn, including pipe setup and
// cleanup, so the children can still compile and run in parallel.
pub fn serialize(io: std.Io, allocator: std.mem.Allocator) std.Io {
    original_io = io;
    const vtable = allocator.create(std.Io.VTable) catch @panic("out of memory");
    vtable.* = io.vtable.*;
    vtable.processSpawn = spawn;
    return .{ .userdata = io.userdata, .vtable = vtable };
}

fn spawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    try spawn_mutex.lock(original_io);
    defer spawn_mutex.unlock(original_io);
    return original_io.vtable.processSpawn(userdata, options);
}
