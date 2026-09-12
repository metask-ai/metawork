//! Strict payload records and parsing shared by Bridge handlers.

const std = @import("std");
const product_control = @import("metawork_product_control");
const max_skill_argument_values: usize = 64;

pub const PermissionChoice = enum {
    allow_once,
    allow_session,
    deny_once,
    deny_session,
};

pub const RendererBridgeConnect = struct {
    contractId: []const u8,
    contractRevision: u32,
};
pub const EventDisconnect = struct { generation: []const u8 };
pub const ModelsResetStore = struct { expectedRevision: []const u8 };
pub const ProductSnapshotChunk = struct { snapshotId: []const u8, offset: []const u8 };
pub const Empty = struct {};
pub const WindowChromeRegion = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    exclusion: bool,
};
pub const WindowChromeSync = struct {
    generation: []const u8,
    viewportWidth: f64,
    viewportHeight: f64,
    regions: []const WindowChromeRegion,
};
pub const WindowChromeGesture = struct {
    generation: []const u8,
    x: f64,
    y: f64,
};
pub const WindowChromeControl = struct {
    generation: []const u8,
    action: []const u8,
};
pub const WindowChromeDisconnect = struct { generation: []const u8 };
pub const ModelDefaultSelection = struct {
    sourceId: []const u8,
    modelId: []const u8,
    expectedSelectionRevision: []const u8,
    expectedSourceGeneration: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const ConfigureMetaskSelection = struct {
    sourceId: []const u8,
    modelId: []const u8,
    expectedMetaskSelectionRevision: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const SelectMetaskApiKey = struct {
    sourceId: []const u8,
    expectedMetaskSelectionRevision: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const ModelCapabilities = struct {
    imageInput: ?bool = null,
    pdfInput: ?bool = null,
    batch: ?bool = null,
    citations: ?bool = null,
    codeExecution: ?bool = null,
    structuredOutputs: ?bool = null,
    thinking: struct {
        supported: ?bool = null,
        adaptive: ?bool = null,
        enabled: ?bool = null,
    } = .{},
    effort: struct {
        supported: ?bool = null,
        low: ?bool = null,
        medium: ?bool = null,
        high: ?bool = null,
        max: ?bool = null,
    } = .{},
    contextManagement: struct {
        supported: ?bool = null,
        clearThinking20251015: ?bool = null,
        clearToolUses20250919: ?bool = null,
        compact20260112: ?bool = null,
    } = .{},
};
pub const ModelMetadata = struct {
    maxInputTokens: ?[]const u8 = null,
    maxOutputTokens: ?[]const u8 = null,
    capabilities: ModelCapabilities = .{},
};
pub const CustomModel = struct {
    id: []const u8,
    displayName: []const u8 = "",
    metadata: ModelMetadata = .{},
};
pub const ModelRef = struct {
    sourceId: []const u8,
    modelId: []const u8,
};
pub const CustomProviderCreate = struct {
    displayName: []const u8,
    protocol: []const u8,
    normalizedBaseUrl: []const u8,
    apiKey: []const u8,
};
pub const BuiltinProviderCreate = struct {
    providerId: []const u8,
    baseUrl: []const u8,
    apiKey: []const u8,
};
pub const BuiltinProviderBaseUrlUpdate = struct {
    providerId: []const u8,
    expectedProviderRevision: []const u8,
    baseUrl: []const u8,
};
pub const CustomProviderUpdate = struct {
    providerId: []const u8,
    expectedProviderRevision: []const u8,
    displayName: []const u8,
    protocol: []const u8,
    normalizedBaseUrl: []const u8,
};
pub const CustomProviderSelection = struct {
    providerId: []const u8,
    expectedProviderRevision: []const u8,
};
pub const CustomProviderCredentialReplace = struct {
    providerId: []const u8,
    expectedProviderRevision: []const u8,
    apiKey: []const u8,
};
pub const CustomModelTest = struct {
    model: ModelRef,
    expectedProviderRevision: []const u8,
    expectedSourceGeneration: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const CustomModelAdd = struct {
    providerId: []const u8,
    expectedProviderRevision: []const u8,
    expectedCatalogGeneration: []const u8,
    model: CustomModel,
};
pub const CustomModelReplace = struct {
    selection: ModelRef,
    expectedProviderRevision: []const u8,
    expectedCatalogGeneration: []const u8,
    replacement: CustomModel,
};
pub const CustomModelRemove = struct {
    selection: ModelRef,
    expectedProviderRevision: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const WorkspaceIdentity = struct {
    workspaceId: []const u8,
    expectedWorkspaceEpoch: []const u8,
};
pub const SkillImportChoice = struct { kind: []const u8 };
pub const SkillSourceSetEnabled = struct { sourceId: std.json.Value, enabled: bool, expectedRevision: []const u8 };
pub const SkillSourceRecover = struct { action: []const u8, expectedRecoveryToken: []const u8 };
pub const SkillSetEnabled = struct {
    scope: []const u8,
    workspaceId: ?[]const u8,
    expectedWorkspaceEpoch: ?[]const u8,
    skillPolicyKey: []const u8,
    state: []const u8,
    expectedCatalogRevision: []const u8,
    expectedSelectionRevision: []const u8,
};
pub const SkillInstall = struct {
    previewId: []const u8,
    scope: []const u8,
    workspaceId: ?[]const u8,
    expectedWorkspaceEpoch: ?[]const u8,
    allowReplace: bool,
};
pub const SkillReimport = struct {
    installId: []const u8,
    previewId: []const u8,
};
pub const SkillIdentity = struct { installId: []const u8 };
pub const McpCreateStdioServer = struct {
    expectedDesiredGeneration: []const u8,
    displayName: []const u8,
    negotiation: []const u8,
    timeoutMs: u32,
    command: []const u8,
    arguments: []const []const u8,
    cwd: ?[]const u8,
    environmentNames: []const []const u8,
};
pub const McpOauthRegistration = struct {
    kind: []const u8,
    clientId: ?[]const u8 = null,
    tokenEndpointAuthMethod: ?[]const u8 = null,
};
pub const McpCreateHttpServer = struct {
    expectedDesiredGeneration: []const u8,
    displayName: []const u8,
    negotiation: []const u8,
    timeoutMs: u32,
    endpoint: []const u8,
    authMode: []const u8,
    headerNames: []const []const u8,
    registration: ?McpOauthRegistration = null,
};
pub const McpUpdateStdioConnection = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
    displayName: []const u8,
    negotiation: []const u8,
    timeoutMs: u32,
    command: []const u8,
    arguments: []const []const u8,
    cwd: ?[]const u8,
    environmentNames: []const []const u8,
};
pub const McpUpdateHttpConnection = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
    displayName: []const u8,
    negotiation: []const u8,
    timeoutMs: u32,
    endpoint: []const u8,
    authMode: []const u8,
    headerNames: []const []const u8,
    registration: ?McpOauthRegistration = null,
};
pub const McpServerRename = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
    displayName: []const u8,
};
pub const McpServerEnable = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
    enabled: bool,
};
pub const McpAllowedTools = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
    toolNames: []const []const u8,
};
pub const McpServerIdentity = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
};
pub const McpSecretSlot = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
};
pub const McpCaptureSecret = struct {
    expectedDesiredGeneration: []const u8,
    serverId: []const u8,
    slot: McpSecretSlot,
};
pub const McpCancelAuthorization = struct {
    operationId: []const u8,
};
pub const TaskWorkspaceIntent = struct {
    kind: []const u8,
    workspaceId: ?[]const u8 = null,
    expectedWorkspaceEpoch: ?[]const u8 = null,
};
pub const NewTaskModelSelection = struct {
    targetModelRef: struct {
        sourceId: []const u8,
        modelId: []const u8,
    },
    expectedSourceGeneration: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const TaskCreate = struct {
    workspace: TaskWorkspaceIntent,
    expectedExecutionGeneration: []const u8,
    expectedSelectionRevision: []const u8,
    modelSelection: ?NewTaskModelSelection,
    expectedSkillCatalogRevision: ?[]const u8,
    expectedSkillSelectionRevision: ?[]const u8,
    permissionProfile: []const u8,
};
pub const PermissionProfileSelection = struct { permissionProfile: []const u8 };
pub const TaskRun = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
    input: std.json.Value,
};
pub const TaskModelSelection = struct {
    taskId: []const u8,
    expectedModel: []const u8,
    expectedExecutionGeneration: []const u8,
    targetModelRef: struct {
        sourceId: []const u8,
        modelId: []const u8,
    },
    expectedSourceGeneration: []const u8,
    expectedCatalogGeneration: []const u8,
};
pub const TaskRestore = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
};
pub const TaskCompact = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
};
pub const TaskCompactIdentity = struct {
    taskId: []const u8,
    operationId: []const u8,
};
pub const TaskRunInput = union(enum) {
    text: []const u8,
    skill: struct {
        skill_id: []const u8,
        catalog_revision: []const u8,
        selection_revision: u64,
        argument_values: []const []const u8,
    },
    multimodal: struct {
        text: []const u8,
        attachment_tokens: []const []const u8,
    },
};
pub const ParsedTaskRunInput = struct {
    value: TaskRunInput,
    owned_argument_values: ?[][]const u8 = null,
    owned_attachment_tokens: ?[][]const u8 = null,

    pub fn deinit(self: *ParsedTaskRunInput) void {
        if (self.owned_argument_values) |values|
            std.heap.c_allocator.free(values);
        if (self.owned_attachment_tokens) |values|
            std.heap.c_allocator.free(values);
        self.* = undefined;
    }
};
pub const TaskCatalogRefresh = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
};
pub const TaskIdentity = struct { taskId: []const u8, runId: []const u8 };
pub const FilePreviewRequest = struct {
    taskId: []const u8,
    runId: []const u8,
    fileReferenceId: []const u8,
};
pub const FileChangeDiffRequest = struct {
    taskId: []const u8,
    runId: []const u8,
    fileChangeId: []const u8,
};
pub const AttachmentRelease = struct { token: []const u8 };
pub const AttachmentPaths = struct { paths: []const []const u8 };
pub const AttachmentReceiveKey = struct { generation: []const u8, batchId: []const u8 };
pub const AttachmentReceiveBegin = struct {
    generation: []const u8,
    batchId: []const u8,
    files: []const struct { name: []const u8, sizeBytes: []const u8 },
};
pub const AttachmentReceiveAppend = struct {
    generation: []const u8,
    batchId: []const u8,
    fileIndex: u32,
    offset: []const u8,
    dataBase64: []const u8,
};
pub const TaskRename = struct { taskId: []const u8, title: []const u8 };
pub const TaskArchive = struct { taskId: []const u8, archived: bool };
pub const TaskDelete = struct { taskId: []const u8 };
pub const PersistenceRecovery = struct { expectedRevision: []const u8 };
pub const ScheduledTaskMutation = struct {
    title: []const u8,
    binding: ScheduledTaskBinding,
    permissionProfile: []const u8,
    input: std.json.Value,
    recurrence: std.json.Value,
};
pub const ScheduledTaskUpdate = struct {
    scheduledTaskId: []const u8,
    expectedEpoch: []const u8,
    title: []const u8,
    binding: ScheduledTaskBinding,
    permissionProfile: []const u8,
    input: std.json.Value,
    recurrence: std.json.Value,
};
pub const ScheduledTaskBinding = struct {
    modelRef: ModelRef,
    sourceGeneration: []const u8,
    selectionRevision: []const u8,
    protocol: []const u8,
};
pub const ScheduledTaskIdentity = struct {
    scheduledTaskId: []const u8,
    expectedEpoch: []const u8,
};
pub const ScheduledTaskEnable = struct {
    scheduledTaskId: []const u8,
    expectedEpoch: []const u8,
    enabled: bool,
};
pub const UiResponseRequest = struct {
    taskId: []const u8,
    runId: []const u8,
    requestId: []const u8,
    kind: []const u8,
    permission: ?[]const u8 = null,
};

pub fn parsePayload(comptime T: type, payload: []const u8) !std.json.Parsed(T) {
    return parsePayloadWithLimit(T, payload, 4096);
}

pub fn parsePayloadWithLimit(comptime T: type, payload: []const u8, limit: usize) !std.json.Parsed(T) {
    if (payload.len > limit) return error.InvalidBridgePayload;
    return std.json.parseFromSlice(T, std.heap.c_allocator, payload, .{
        .ignore_unknown_fields = false,
    }) catch error.InvalidBridgePayload;
}

pub fn parseWireId(value: []const u8) !u64 {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return error.InvalidBridgeId;
    for (value) |byte| if (byte < '0' or byte > '9') return error.InvalidBridgeId;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidBridgeId;
}

pub fn parseSkillSourceBrand(value: std.json.Value) !product_control.SkillSourceBrand {
    const name = switch (value) {
        .string => |name| name,
        else => return error.InvalidBridgePayload,
    };
    return std.meta.stringToEnum(product_control.SkillSourceBrand, name) orelse error.InvalidBridgePayload;
}

pub fn permissionProfile(value: []const u8) ?product_control.PermissionProfile {
    if (std.mem.eql(u8, value, "approval_required")) return .approval_required;
    if (std.mem.eql(u8, value, "full_access")) return .full_access;
    return null;
}

pub fn parseTaskRunInput(value: std.json.Value) !ParsedTaskRunInput {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidBridgePayload,
    };
    const kind = object.get("kind") orelse return error.InvalidBridgePayload;
    const kind_text = switch (kind) {
        .string => |text| text,
        else => return error.InvalidBridgePayload,
    };
    if (std.mem.eql(u8, kind_text, "text")) {
        if (object.count() != 2) return error.InvalidBridgePayload;
        const text_value = object.get("text") orelse
            return error.InvalidBridgePayload;
        const text = switch (text_value) {
            .string => |text| text,
            else => return error.InvalidBridgePayload,
        };
        return .{ .value = .{ .text = text } };
    }
    if (std.mem.eql(u8, kind_text, "multimodal")) {
        if (object.count() != 3) return error.InvalidBridgePayload;
        const text = switch (object.get("text") orelse return error.InvalidBridgePayload) {
            .string => |text| text,
            else => return error.InvalidBridgePayload,
        };
        const token_values = switch (object.get("attachmentTokens") orelse
            return error.InvalidBridgePayload) {
            .array => |values| values,
            else => return error.InvalidBridgePayload,
        };
        if (token_values.items.len == 0 or token_values.items.len > 8)
            return error.InvalidBridgePayload;
        const tokens = try std.heap.c_allocator.alloc([]const u8, token_values.items.len);
        errdefer std.heap.c_allocator.free(tokens);
        for (token_values.items, tokens) |token_value, *token| token.* = switch (token_value) {
            .string => |token_text| if (validAttachmentToken(token_text)) token_text else return error.InvalidBridgePayload,
            else => return error.InvalidBridgePayload,
        };
        return .{
            .value = .{ .multimodal = .{
                .text = text,
                .attachment_tokens = tokens,
            } },
            .owned_attachment_tokens = tokens,
        };
    }
    if (!std.mem.eql(u8, kind_text, "skill") or object.count() != 5)
        return error.InvalidBridgePayload;
    const skill_id = switch (object.get("skillId") orelse
        return error.InvalidBridgePayload) {
        .string => |text| text,
        else => return error.InvalidBridgePayload,
    };
    const catalog_revision = switch (object.get("catalogRevision") orelse
        return error.InvalidBridgePayload) {
        .string => |text| text,
        else => return error.InvalidBridgePayload,
    };
    const selection_revision = switch (object.get("selectionRevision") orelse
        return error.InvalidBridgePayload) {
        .string => |text| try parseWireId(text),
        else => return error.InvalidBridgePayload,
    };
    const argument_array = switch (object.get("argumentValues") orelse
        return error.InvalidBridgePayload) {
        .array => |items| items,
        else => return error.InvalidBridgePayload,
    };
    if (argument_array.items.len > max_skill_argument_values)
        return error.InvalidBridgePayload;
    const argument_values = try std.heap.c_allocator.alloc(
        []const u8,
        argument_array.items.len,
    );
    errdefer std.heap.c_allocator.free(argument_values);
    for (argument_array.items, argument_values) |item, *target|
        target.* = switch (item) {
            .string => |text| text,
            else => return error.InvalidBridgePayload,
        };
    return .{
        .value = .{ .skill = .{
            .skill_id = skill_id,
            .catalog_revision = catalog_revision,
            .selection_revision = selection_revision,
            .argument_values = argument_values,
        } },
        .owned_argument_values = argument_values,
    };
}

pub fn validAttachmentToken(token: []const u8) bool {
    if (token.len != 48) return false;
    for (token) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

pub fn parseScheduledTaskInstruction(value: std.json.Value) ![]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidBridgePayload,
    };
    if (object.count() != 2) return error.InvalidBridgePayload;
    const kind = switch (object.get("kind") orelse
        return error.InvalidBridgePayload) {
        .string => |text| text,
        else => return error.InvalidBridgePayload,
    };
    if (!std.mem.eql(u8, kind, "text")) return error.InvalidBridgePayload;
    return switch (object.get("text") orelse
        return error.InvalidBridgePayload) {
        .string => |text| text,
        else => return error.InvalidBridgePayload,
    };
}

pub fn parseScheduledTaskRecurrence(
    value: std.json.Value,
) !product_control.ScheduledTaskRecurrence {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidBridgePayload,
    };
    const kind = switch (object.get("kind") orelse
        return error.InvalidBridgePayload) {
        .string => |text| text,
        else => return error.InvalidBridgePayload,
    };
    if (std.mem.eql(u8, kind, "once")) {
        if (object.count() != 2) return error.InvalidBridgePayload;
        const at = switch (object.get("atUnixSeconds") orelse
            return error.InvalidBridgePayload) {
            .string => |text| try parseWireId(text),
            else => return error.InvalidBridgePayload,
        };
        return .{ .once = .{ .at_unix_seconds = at } };
    }
    if (!std.mem.eql(u8, kind, "interval") or object.count() != 3)
        return error.InvalidBridgePayload;
    const start = switch (object.get("startAtUnixSeconds") orelse
        return error.InvalidBridgePayload) {
        .string => |text| try parseWireId(text),
        else => return error.InvalidBridgePayload,
    };
    const every = switch (object.get("everySeconds") orelse
        return error.InvalidBridgePayload) {
        .string => |text| try parseWireId(text),
        else => return error.InvalidBridgePayload,
    };
    return .{ .interval = .{
        .start_at_unix_seconds = start,
        .every_seconds = every,
    } };
}

pub fn acknowledgementSequence(payload: []const u8) !u64 {
    const prefix = "{\"sequence\":";
    if (!std.mem.startsWith(u8, payload, prefix) or !std.mem.endsWith(u8, payload, "}"))
        return error.InvalidAcknowledgement;
    const digits = payload[prefix.len .. payload.len - 1];
    return parseWireId(digits) catch error.InvalidAcknowledgement;
}

pub fn permissionChoice(value: []const u8) ?PermissionChoice {
    if (std.mem.eql(u8, value, "allow_once")) return .allow_once;
    if (std.mem.eql(u8, value, "allow_session")) return .allow_session;
    if (std.mem.eql(u8, value, "deny_once")) return .deny_once;
    if (std.mem.eql(u8, value, "deny_session")) return .deny_session;
    return null;
}

test "Skill source payloads reject free paths coercion and mixed recovery intent" {
    inline for (.{ product_control.SkillSourceBrand.claude, product_control.SkillSourceBrand.codex }) |brand| {
        var settings = try parsePayload(SkillSourceSetEnabled, "{\"sourceId\":\"" ++ @tagName(brand) ++ "\",\"enabled\":true,\"expectedRevision\":\"1\"}");
        defer settings.deinit();
        try std.testing.expect(settings.value.enabled);
        try std.testing.expectEqual(brand, try parseSkillSourceBrand(settings.value.sourceId));
    }
    inline for (.{ "0", "1", "compat.claude.user", "compat.claude.workspace", "compat.codex.user", "compat.codex.workspace", "agents", "unknown", "Claude", "codex ", "", "/tmp" }) |id| {
        var settings = try parsePayload(SkillSourceSetEnabled, "{\"sourceId\":\"" ++ id ++ "\",\"enabled\":true,\"expectedRevision\":\"1\"}");
        defer settings.deinit();
        try std.testing.expectError(error.InvalidBridgePayload, parseSkillSourceBrand(settings.value.sourceId));
    }
    inline for (.{ "0", "1", "true", "false", "null", "[]", "[99,108,97,117,100,101]", "{}" }) |value| {
        var settings = try parsePayload(SkillSourceSetEnabled, "{\"sourceId\":" ++ value ++ ",\"enabled\":true,\"expectedRevision\":\"1\"}");
        defer settings.deinit();
        try std.testing.expectError(error.InvalidBridgePayload, parseSkillSourceBrand(settings.value.sourceId));
    }
    var recovery = try parsePayload(SkillSourceRecover, "{\"action\":\"reread\",\"expectedRecoveryToken\":\"2\"}");
    defer recovery.deinit();
    try std.testing.expectEqualStrings("reread", recovery.value.action);
    inline for (.{
        "{\"sourceId\":\"claude\",\"enabled\":true,\"expectedRevision\":\"1\",\"path\":\"/tmp\"}",
        "{\"sourceId\":\"claude\",\"enabled\":1,\"expectedRevision\":\"1\"}",
        "{\"sourceId\":\"claude\",\"enabled\":true,\"expectedRevision\":1}",
        "{\"sourceId\":\"claude\",\"enabled\":true}",
    }) |payload| try std.testing.expectError(error.InvalidBridgePayload, parsePayload(SkillSourceSetEnabled, payload));
    inline for (.{
        "{\"action\":\"reset\",\"expectedRecoveryToken\":\"2\",\"sources\":{}}",
        "{\"action\":\"reset\",\"expectedRecoveryToken\":2}",
        "{\"action\":\"reset\",\"expectedRecoveryToken\":\"2\",\"workspaceId\":\"1\"}",
    }) |payload| try std.testing.expectError(error.InvalidBridgePayload, parsePayload(SkillSourceRecover, payload));
}

test "Task Run input is an exact text skill or multimodal tagged object" {
    var text_payload = try parsePayload(TaskRun,
        \\{"taskId":"1","expectedBindingEpoch":"2","input":{"kind":"text","text":"inspect"}}
    );
    defer text_payload.deinit();
    var text_input = try parseTaskRunInput(text_payload.value.input);
    defer text_input.deinit();
    try std.testing.expectEqualStrings("inspect", text_input.value.text);

    var skill_payload = try parsePayload(TaskRun,
        \\{"taskId":"1","expectedBindingEpoch":"2","input":{"kind":"skill","skillId":"builtin.review","catalogRevision":"revision","selectionRevision":"1","argumentValues":["src/main.zig","correctness"]}}
    );
    defer skill_payload.deinit();
    var skill_input = try parseTaskRunInput(skill_payload.value.input);
    defer skill_input.deinit();
    try std.testing.expectEqualStrings(
        "builtin.review",
        skill_input.value.skill.skill_id,
    );
    try std.testing.expectEqual(@as(usize, 2), skill_input.value.skill.argument_values.len);

    var multimodal_payload = try parsePayload(TaskRun,
        \\{"taskId":"1","expectedBindingEpoch":"2","input":{"kind":"multimodal","text":"","attachmentTokens":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}}
    );
    defer multimodal_payload.deinit();
    var multimodal_input = try parseTaskRunInput(multimodal_payload.value.input);
    defer multimodal_input.deinit();
    try std.testing.expectEqualStrings("", multimodal_input.value.multimodal.text);
    try std.testing.expectEqual(@as(usize, 2), multimodal_input.value.multimodal.attachment_tokens.len);
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        multimodal_input.value.multimodal.attachment_tokens[0],
    );

    var legacy = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"kind":"text","prompt":"inspect"}
    , .{});
    defer legacy.deinit();
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parseTaskRunInput(legacy.value),
    );

    var mixed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"kind":"text","text":"inspect","skillId":"builtin.review"}
    , .{});
    defer mixed.deinit();
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parseTaskRunInput(mixed.value),
    );

    const invalid_multimodal = [_][]const u8{
        \\{"kind":"multimodal","text":"","attachmentTokens":[]}
        ,
        \\{"kind":"multimodal","text":"","attachmentTokens":["physical/path.png"]}
        ,
        \\{"kind":"multimodal","text":"","attachmentTokens":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"skillId":"review"}
        ,
    };
    for (invalid_multimodal) |encoded| {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            encoded,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidBridgePayload,
            parseTaskRunInput(parsed.value),
        );
    }
}

test "dropped attachment paths use one exact bounded payload" {
    var parsed = try parsePayloadWithLimit(
        AttachmentPaths,
        \\{"paths":["C:\\work\\notes.txt","C:\\work\\image.png"]}
    ,
        256,
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.paths.len);
    try std.testing.expectEqualStrings("C:\\work\\notes.txt", parsed.value.paths[0]);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayloadWithLimit(
            AttachmentPaths,
            \\{"paths":["C:\\work\\notes.txt"],"source":"renderer"}
        ,
            256,
        ),
    );
}

test "Task creation requires explicit nullable model and skill selections" {
    var text = try parsePayload(TaskCreate,
        \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3","expectedSelectionRevision":"4","modelSelection":null,"expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"permissionProfile":"approval_required"}
    );
    defer text.deinit();
    try std.testing.expect(text.value.expectedSkillCatalogRevision == null);
    try std.testing.expect(text.value.expectedSkillSelectionRevision == null);
    try std.testing.expect(text.value.modelSelection == null);
    try std.testing.expectEqualStrings("4", text.value.expectedSelectionRevision);
    try std.testing.expectEqual(
        product_control.PermissionProfile.approval_required,
        permissionProfile(text.value.permissionProfile).?,
    );
    try std.testing.expect(permissionProfile("full_access") != null);
    try std.testing.expect(permissionProfile("accept_edits") == null);
    var selected = try parsePayload(TaskCreate,
        \\{"workspace":{"kind":"automatic"},"expectedExecutionGeneration":"3","expectedSelectionRevision":"4","modelSelection":{"targetModelRef":{"sourceId":"metask:key-1","modelId":"model-2"},"expectedSourceGeneration":"5","expectedCatalogGeneration":"6"},"expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"permissionProfile":"full_access"}
    );
    defer selected.deinit();
    try std.testing.expectEqualStrings(
        "metask:key-1",
        selected.value.modelSelection.?.targetModelRef.sourceId,
    );
    try std.testing.expectEqualStrings(
        "model-2",
        selected.value.modelSelection.?.targetModelRef.modelId,
    );
    try std.testing.expectEqualStrings(
        "5",
        selected.value.modelSelection.?.expectedSourceGeneration,
    );
    try std.testing.expectEqualStrings(
        "6",
        selected.value.modelSelection.?.expectedCatalogGeneration,
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3","expectedSelectionRevision":"4","expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"permissionProfile":"approval_required"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3","expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"permissionProfile":"approval_required"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3"}
        ),
    );
}

test "Custom Provider create accepts Provider metadata with an API key and rejects the retired model field" {
    var provider = try parsePayload(CustomProviderCreate,
        \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses","apiKey":"secret"}
    );
    defer provider.deinit();
    try std.testing.expectEqualStrings("Provider", provider.value.displayName);
    try std.testing.expectEqualStrings("secret", provider.value.apiKey);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(CustomProviderCreate,
            \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(CustomProviderCreate,
            \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses","apiKey":"secret","model":{"id":"gpt-5"}}
        ),
    );
}

test "Custom Provider credential replacement requires the exact API key field" {
    var replacement = try parsePayload(CustomProviderCredentialReplace,
        \\{"providerId":"provider-1","expectedProviderRevision":"7","apiKey":"  opaque secret  "}
    );
    defer replacement.deinit();
    try std.testing.expectEqualStrings("provider-1", replacement.value.providerId);
    try std.testing.expectEqualStrings("  opaque secret  ", replacement.value.apiKey);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(CustomProviderCredentialReplace,
            \\{"providerId":"provider-1","expectedProviderRevision":"7"}
        ),
    );
}

test "file preview payload requires exact Task Run and reference identity" {
    var request = try parsePayload(FilePreviewRequest,
        \\{"taskId":"1","runId":"2","fileReferenceId":"task:1:run:2:file:3"}
    );
    defer request.deinit();
    try std.testing.expectEqualStrings("1", request.value.taskId);
    try std.testing.expectEqualStrings("2", request.value.runId);
    try std.testing.expectEqualStrings(
        "task:1:run:2:file:3",
        request.value.fileReferenceId,
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(FilePreviewRequest,
            \\{"fileReferenceId":"task:1:run:2:file:3"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(FilePreviewRequest,
            \\{"taskId":"1","runId":"2","fileReferenceId":"task:1:run:2:file:3","path":"src/main.zig"}
        ),
    );
}

test "file change diff payload requires exact Task Run and change identity" {
    var request = try parsePayload(FileChangeDiffRequest,
        \\{"taskId":"1","runId":"2","fileChangeId":"change-1-1-3"}
    );
    defer request.deinit();
    try std.testing.expectEqualStrings("change-1-1-3", request.value.fileChangeId);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(FileChangeDiffRequest,
            \\{"taskId":"1","runId":"2","fileChangeId":"change-1-1-3","path":"src/main.zig"}
        ),
    );
}

test "Scheduled Task recurrence is exact and uses wire integers" {
    var once = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"kind":"once","atUnixSeconds":"1700000000"}
    ,
        .{},
    );
    defer once.deinit();
    try std.testing.expectEqual(
        @as(u64, 1_700_000_000),
        (try parseScheduledTaskRecurrence(once.value)).once.at_unix_seconds,
    );
    var interval = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"kind":"interval","startAtUnixSeconds":"1700000000","everySeconds":"3600"}
    ,
        .{},
    );
    defer interval.deinit();
    try std.testing.expectEqual(
        @as(u64, 3600),
        (try parseScheduledTaskRecurrence(interval.value)).interval.every_seconds,
    );
    var extra = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"kind":"once","atUnixSeconds":"1700000000","cron":"* * * * *"}
    ,
        .{},
    );
    defer extra.deinit();
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parseScheduledTaskRecurrence(extra.value),
    );
}

test "Scheduled Task payload rejects Workspace and Skill configuration" {
    var current = try parsePayload(ScheduledTaskMutation,
        \\{"title":"Current","binding":{"modelRef":{"sourceId":"metask:key-1","modelId":"model-1"},"sourceGeneration":"7","selectionRevision":"9","protocol":"anthropic_messages"},"permissionProfile":"approval_required","input":{"kind":"text","text":"inspect"},"recurrence":{"kind":"once","atUnixSeconds":"2"}}
    );
    defer current.deinit();
    try std.testing.expectEqualStrings(
        "metask:key-1",
        current.value.binding.modelRef.sourceId,
    );
    try std.testing.expectEqualStrings("model-1", current.value.binding.modelRef.modelId);
    try std.testing.expectEqualStrings("7", current.value.binding.sourceGeneration);
    try std.testing.expectEqualStrings("9", current.value.binding.selectionRevision);
    try std.testing.expectEqualStrings("anthropic_messages", current.value.binding.protocol);

    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(ScheduledTaskMutation,
            \\{"title":"Legacy","target":{"kind":"default"},"expectedExecutionGeneration":"1","input":{"kind":"text","text":"inspect"},"recurrence":{"kind":"once","atUnixSeconds":"2"}}
        ),
    );

    var skill_input = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"kind":"skill","skillId":"builtin.summary","catalogRevision":"4","argumentValues":[]}
    ,
        .{},
    );
    defer skill_input.deinit();
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parseScheduledTaskInstruction(skill_input.value),
    );
}
