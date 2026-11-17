//! MetaWork's productized Agent capability definition.
//!
//! AgentCore owns the general-purpose capability superset. This module owns
//! MetaWork's narrower Agent capability surface. Built-in tool selection and
//! widening remain private to Agent and cannot vary per Session.

const std = @import("std");
const sdk = @import("metask_agentcore");
const generate_image = @import("generate_image.zig");
const generate_video = @import("generate_video.zig");
const deliver_file = @import("agent_file_delivery");
const mcp_install = @import("mcp_install.zig");

/// Trusted effects for the fixed Host tool, independent of model arguments.
/// A same-named MCP or built-in tool does not inherit this description.
pub fn hostToolPermissionContext(namespace: sdk.protocol.PermissionToolNamespace, name: []const u8) ?[]const u8 {
    if (namespace != .host) return null;
    if (std.mem.eql(u8, name, generate_image.name)) return generate_image.description;
    if (std.mem.eql(u8, name, generate_video.name)) return generate_video.description;
    if (std.mem.eql(u8, name, deliver_file.name)) return deliver_file.description;
    if (std.mem.eql(u8, name, mcp_install.name)) return mcp_install.description;
    return null;
}

pub const Builtin = enum {
    read,
    write,
    edit,
    glob,
    grep,
    bash,
    bash_output,
    kill_shell,
    web_search,
    web_fetch,
};

pub const builtins = [_]Builtin{
    .read,
    .write,
    .edit,
    .glob,
    .grep,
    .bash,
    .bash_output,
    .kill_shell,
    .web_search,
    .web_fetch,
};

pub fn wireName(value: Builtin) []const u8 {
    return switch (value) {
        .read => "Read",
        .write => "Write",
        .edit => "Edit",
        .glob => "Glob",
        .grep => "Grep",
        .bash => "Bash",
        .bash_output => "BashOutput",
        .kill_shell => "KillShell",
        .web_search => "WebSearch",
        .web_fetch => "WebFetch",
    };
}

pub fn allowsUiRequest(request: sdk.UiRequest) bool {
    return switch (request) {
        .permission => true,
        .ask_question => false,
    };
}
