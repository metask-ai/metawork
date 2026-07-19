//! Origin and command allowlists for each packaged Renderer mode.

const native_sdk = @import("native_sdk");
const commands = @import("commands.zig");

pub const Mode = enum { release, development };

const release_origins = [_][]const u8{"zero://app"};
const development_origins = [_][]const u8{ "zero://app", "http://127.0.0.1:5173" };
pub const window_permissions = [_][]const u8{native_sdk.security.permission_window};
const builtin_names = [_][]const u8{
    "native-sdk.window.list",
    "native-sdk.window.create",
    "native-sdk.window.close",
};

fn commandPolicies(
    comptime names: []const []const u8,
    allowed_origins: []const []const u8,
) [names.len]native_sdk.bridge.CommandPolicy {
    var result: [names.len]native_sdk.bridge.CommandPolicy = undefined;
    for (names, 0..) |name, index| result[index] = .{ .name = name, .origins = allowed_origins };
    return result;
}

fn builtinPolicies(allowed_origins: []const []const u8) [builtin_names.len]native_sdk.bridge.CommandPolicy {
    var result: [builtin_names.len]native_sdk.bridge.CommandPolicy = undefined;
    for (builtin_names, 0..) |name, index|
        result[index] = .{ .name = name, .permissions = &window_permissions, .origins = allowed_origins };
    return result;
}

const release_commands = commandPolicies(&commands.product, &release_origins);
const development_commands = commandPolicies(&commands.product, &development_origins);
const release_builtins = builtinPolicies(&release_origins);
const development_builtins = builtinPolicies(&development_origins);

pub fn product(mode: Mode) native_sdk.BridgePolicy {
    return .{
        .enabled = true,
        .commands = switch (mode) {
            .release => &release_commands,
            .development => &development_commands,
        },
    };
}

pub fn builtin(mode: Mode) native_sdk.BridgePolicy {
    return .{
        .enabled = true,
        .permissions = &window_permissions,
        .commands = switch (mode) {
            .release => &release_builtins,
            .development => &development_builtins,
        },
    };
}

pub fn origins(mode: Mode) []const []const u8 {
    return switch (mode) {
        .release => &release_origins,
        .development => &development_origins,
    };
}
