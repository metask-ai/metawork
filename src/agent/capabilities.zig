//! MetaWork's productized Agent capability definition.
//!
//! AgentCore owns the general-purpose capability superset. This module owns
//! MetaWork's narrower Agent capability surface. Built-in tool selection and
//! widening remain private to Agent and cannot vary per Session.

const sdk = @import("metask_agentcore");

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
