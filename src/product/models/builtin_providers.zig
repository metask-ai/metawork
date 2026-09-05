//! Models-owned, application-bundled official Provider recipes.
//!
//! These values are not user-editable and never contain credentials. A recipe
//! chooses the one MetaWork-supported protocol route for a vendor; it is not a
//! list of every protocol the vendor advertises.

const contract = @import("metawork_product_models_contract");

pub const Definition = struct {
    id: contract.BuiltinProviderId,
    display_name: []const u8,
    protocol: contract.Protocol,
    completion_endpoint: []const u8,
    api_key_url: []const u8,
    documentation_url: []const u8,

    pub fn spec(self: Definition) contract.CustomProviderSpec {
        return .{
            .builtin_provider_id = self.id,
            .display_name = self.display_name,
            .protocol = self.protocol,
            .normalized_base_url = self.completion_endpoint,
        };
    }

    pub fn view(self: Definition) contract.BuiltinProviderPresetView {
        return .{
            .id = self.id,
            .display_name = self.display_name,
            .api_key_url = self.api_key_url,
            .documentation_url = self.documentation_url,
        };
    }
};

pub const definitions = [_]Definition{
    .{
        .id = .deepseek,
        .display_name = "DeepSeek",
        .protocol = .openai_chat_completions,
        .completion_endpoint = "https://api.deepseek.com/chat/completions",
        .api_key_url = "https://platform.deepseek.com/api_keys",
        .documentation_url = "https://api-docs.deepseek.com/",
    },
    .{
        .id = .kimi,
        .display_name = "Kimi",
        .protocol = .openai_chat_completions,
        .completion_endpoint = "https://api.moonshot.cn/v1/chat/completions",
        .api_key_url = "https://platform.moonshot.cn/console/api-keys",
        .documentation_url = "https://platform.kimi.com/docs/api/overview",
    },
    .{
        .id = .minimax,
        .display_name = "MiniMax",
        .protocol = .anthropic_messages,
        .completion_endpoint = "https://api.minimaxi.com/anthropic/v1/messages",
        .api_key_url = "https://platform.minimaxi.com/user-center/basic-information/interface-key",
        .documentation_url = "https://platform.minimaxi.com/docs/api-reference/api-overview",
    },
    .{
        .id = .glm,
        .display_name = "智谱 GLM",
        .protocol = .openai_chat_completions,
        .completion_endpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        .api_key_url = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys",
        .documentation_url = "https://docs.bigmodel.cn/cn/api/introduction",
    },
};

pub fn find(id: contract.BuiltinProviderId) *const Definition {
    for (&definitions) |*definition|
        if (definition.id == id) return definition;
    unreachable;
}

pub fn views() []const contract.BuiltinProviderPresetView {
    const Static = struct {
        const value = build: {
            var result: [definitions.len]contract.BuiltinProviderPresetView = undefined;
            for (definitions, 0..) |definition, index| result[index] = definition.view();
            break :build result;
        };
    };
    return &Static.value;
}

test "official Provider recipes use explicit execution routes" {
    const std = @import("std");

    try std.testing.expectEqual(@as(usize, 4), definitions.len);
    for (definitions) |definition| {
        try std.testing.expect(definition.display_name.len != 0);
        try std.testing.expect(definition.completion_endpoint.len != 0);
        try std.testing.expect(definition.api_key_url.len != 0);
        try std.testing.expect(definition.documentation_url.len != 0);
        try std.testing.expectEqual(definition.id, definition.spec().builtin_provider_id.?);
        try std.testing.expect(contract.validCustomProviderEndpoint(
            definition.protocol,
            definition.completion_endpoint,
        ));
    }
}
