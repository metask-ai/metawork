//! Origin and command allowlists for each packaged Renderer mode.

const native_sdk = @import("native_sdk");
const commands = @import("commands.zig");

pub const Mode = enum { release, development };

const release_origins = [_][]const u8{"zero://app"};
const development_origins = [_][]const u8{ "zero://app", "http://127.0.0.1:5173" };
pub const product_command_count = commands.product.len;
pub const builtin_command_count: usize = 0;

fn commandPolicies(
    comptime names: []const []const u8,
    allowed_origins: []const []const u8,
) [names.len]native_sdk.bridge.CommandPolicy {
    var result: [names.len]native_sdk.bridge.CommandPolicy = undefined;
    for (names, 0..) |name, index| result[index] = .{ .name = name, .origins = allowed_origins };
    return result;
}

const release_commands = commandPolicies(&commands.product, &release_origins);
const development_commands = commandPolicies(&commands.product, &development_origins);

pub fn product(mode: Mode) native_sdk.BridgePolicy {
    return .{
        .enabled = true,
        .commands = switch (mode) {
            .release => &release_commands,
            .development => &development_commands,
        },
    };
}

pub fn builtin(_: Mode) native_sdk.BridgePolicy {
    return .{
        .enabled = false,
    };
}

pub fn origins(mode: Mode) []const []const u8 {
    return switch (mode) {
        .release => &release_origins,
        .development => &development_origins,
    };
}
