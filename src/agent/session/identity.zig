//! Fixed MetaWork identity; borrowed ABI views remain alive for each synchronous call.
const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const name = @import("app_manifest_zon").display_name;

const sections = [_]wire.PromptSectionV1{
    replacement("metacodes:identity", "你是 " ++ name ++ " 内的 AI 助手。" ++ name ++ " 是 Metask 的产品，你帮助用户完成当前工作空间中的任务。你的执行内核是 Metask AgentCore，具体模型由当前会话配置决定。介绍自己时使用 " ++ name ++ " AI 助手这一产品身份；模型信息和可用能力以当前运行环境提供的事实为准。"),
    replacement("metacodes:subagent", "你是 " ++ name ++ " 内执行当前委派任务的子代理。完成分配的任务，返回清晰的结果与必要证据。你的产品归属是 " ++ name ++ "，执行内核是 Metask AgentCore；模型信息和可用能力以当前运行环境提供的事实为准。"),
};

pub const profile: wire.PromptProfileV1 = blk: {
    var value = std.mem.zeroes(wire.PromptProfileV1);
    value.struct_size = @sizeOf(wire.PromptProfileV1);
    value.sections = &sections;
    value.section_count = sections.len;
    break :blk value;
};

fn replacement(id: []const u8, text: []const u8) wire.PromptSectionV1 {
    var value = std.mem.zeroes(wire.PromptSectionV1);
    value.struct_size = @sizeOf(wire.PromptSectionV1);
    value.op_code = wire.PROMPT_OP_REPLACE;
    value.id = sdk.bytesView(id);
    value.text = sdk.bytesView(text);
    return value;
}

/// The candidate is unpublished and fenced by Runtime's restore reservation.
pub fn apply(api: sdk.Api, candidate: *wire.SessionHandle) error{ RestoreFailed, RestoreContractFailed }!void {
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    const code = api.sessionControl().setPromptProfile()(candidate, &profile, &diagnostic);
    defer if (diagnostic.ptr != null or diagnostic.len != 0) api.bufferRelease()(&diagnostic);
    _ = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch
        return error.RestoreContractFailed;
    const status = sdk.Status.fromCode(code) catch return error.RestoreContractFailed;
    switch (status) {
        .ok => {},
        .invalid_argument, .out_of_memory, .busy, .invalid_state, .core_error, .internal_error, .resource_limit, .checkpoint_budget_required => return error.RestoreFailed,
        else => return error.RestoreContractFailed,
    }
}
