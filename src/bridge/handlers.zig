//! Strict payload records and parsing shared by Bridge handlers.

const std = @import("std");
const models_contract = @import("metawork_product_models_contract");
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
pub const UpdateDownload = struct { expectedVersion: []const u8 };

pub const WireText = struct {
    value: []const u8,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};
pub const WireId = struct {
    value: u64,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const text = try WireText.jsonParse(allocator, source, options);
        return .{ .value = parseWireId(text.value) catch return error.InvalidNumber };
    }
};
const JsonRunLimit = struct {
    value: u8,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        const token = try source.nextAllocMax(allocator, .alloc_always, options.max_value_len.?);
        const text = switch (token) {
            .number, .allocated_number => |value| value,
            else => return error.UnexpectedToken,
        };
        for (text) |byte| if (byte < '0' or byte > '9') return error.UnexpectedToken;
        return .{ .value = try std.fmt.parseInt(u8, text, 10) };
    }
};
const JsonU32 = struct {
    value: u32,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
        const token = try source.nextAllocMax(allocator, .alloc_always, options.max_value_len.?);
        const text = switch (token) {
            .number, .allocated_number => |value| value,
            else => return error.UnexpectedToken,
        };
        for (text) |byte| if (byte < '0' or byte > '9') return error.UnexpectedToken;
        return .{ .value = try std.fmt.parseInt(u32, text, 10) };
    }
};
const JsonManagement = struct {
    value: @FieldType(product_control.ViewRequest, "management"),
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse(@FieldType(@This(), "value"), allocator, source, options) };
    }
};
pub const ProductSnapshotContinue = struct { preparingSnapshotId: WireId };
pub const ProductSnapshotChunk = struct { snapshotId: WireId, offset: WireId };
pub const ViewVersions = struct {
    context: WireId,
    workspaces: WireId,
    taskIndex: WireId,
    taskPage: WireId,
    historyPage: WireId,
    management: WireId,
    searchIndex: WireId,
};
pub const ProductViewRequest = struct {
    taskId: ?WireId,
    beforeRunId: ?WireId,
    runLimit: JsonRunLimit,
    management: JsonManagement,
    search: bool,
    searchQuery: WireText,
    searchCursor: ?struct { revision: WireId, securityEpoch: WireId, task: WireId, run: WireId, part: WireId, offset: WireId },
    receipts: []const struct { taskId: WireId, operationId: WireText },
    known: struct { securityEpoch: WireId, versions: ViewVersions },

    pub fn product(self: ProductViewRequest, storage: []product_control.ViewReceiptQuery) !product_control.ViewRequest {
        if (self.receipts.len > 64 or self.receipts.len > storage.len) return error.InvalidViewRequest;
        for (self.receipts, storage[0..self.receipts.len]) |query, *target| target.* = .{ .task_id = query.taskId.value, .operation_id = query.operationId.value };
        var request: product_control.ViewRequest = .{
            .task_id = if (self.taskId) |id| id.value else null,
            .before_run_id = if (self.beforeRunId) |id| id.value else null,
            .run_limit = self.runLimit.value,
            .management = self.management.value,
            .search = self.search,
            .search_query = self.searchQuery.value,
            .search_cursor = if (self.searchCursor) |cursor| .{ .revision = cursor.revision.value, .security_epoch = cursor.securityEpoch.value, .task = std.math.cast(usize, cursor.task.value) orelse return error.InvalidViewRequest, .run = std.math.cast(usize, cursor.run.value) orelse return error.InvalidViewRequest, .part = std.math.cast(usize, cursor.part.value) orelse return error.InvalidViewRequest, .offset = std.math.cast(usize, cursor.offset.value) orelse return error.InvalidViewRequest } else null,
            .receipts = storage[0..self.receipts.len],
        };
        request.known_epoch = self.known.securityEpoch.value;
        inline for (std.meta.fields(ViewVersions)) |field| @field(request.known_versions, field.name) = @field(self.known.versions, field.name).value;
        try request.validate();
        return request;
    }
};
pub const OutputAction = struct {
    generation: WireId,
    operationId: WireId,
    taskId: WireId,
    runId: WireId,
    outputId: WireText,
    action: struct {
        value: product_control.OutputCheckKind,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const name = try WireText.jsonParse(allocator, source, options);
            return .{ .value = std.meta.stringToEnum(product_control.OutputCheckKind, name.value) orelse return error.UnexpectedToken };
        }
    },
};
pub const OutputActionCancel = struct { generation: WireId, operationId: WireId };
pub fn parseOutputId(value: []const u8) ![16]u8 {
    if (value.len != 32) return error.InvalidBridgeId;
    for (value) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return error.InvalidBridgeId;
    var id: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, value) catch return error.InvalidBridgeId;
    if (std.mem.allEqual(u8, &id, 0)) return error.InvalidBridgeId;
    return id;
}

pub const Empty = struct {};
pub const McpApplyConfiguration = struct { serverId: ?[]const u8 = null };
pub const WindowChromeRefresh = struct { generation: []const u8 };
pub const WindowChromeControl = struct {
    generation: []const u8,
    action: []const u8,
};
pub const WindowChromeDisconnect = struct { generation: []const u8 };
pub const ExternalLinkOpen = struct { url: []const u8 };

pub const ModelCapabilities = struct {
    textInput: ?bool = null,
    audioInput: ?bool = null,
    videoInput: ?bool = null,
    output: @FieldType(models_contract.ModelCapabilities, "output") = .{},
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
    model: ?CustomModel = null,
};
pub const BuiltinProviderCreate = struct {
    providerId: []const u8,
    baseUrl: []const u8,
    apiKey: []const u8,
    model: ?CustomModel = null,
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
pub const AutomaticWorkspaceRootMutation = struct {
    expectedGeneration: []const u8,
};
pub const SkillImportTarget = struct {
    kind: []const u8,
    workspaceId: ?[]const u8,
    expectedWorkspaceEpoch: ?[]const u8,
    installId: ?[]const u8,
};
pub const SkillImportChoice = struct { kind: []const u8, target: SkillImportTarget };
pub const SkillPrepareImport = struct { previewId: []const u8, preparationRevision: []const u8, target: ?SkillImportTarget };
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
    preparationRevision: []const u8,
    confirmation: []const u8,
};
pub const SkillReimport = SkillInstall;
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
    sensitiveEndpoint: bool = false,
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
    sensitiveEndpoint: bool = false,
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
pub const McpInstallationIdentity = struct { serverId: []const u8, installationRevision: []const u8 };
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
    secret: []const u8,
};

test "MCP credential payload requires a value and rejects unrelated fields" {
    var payload = try parsePayload(McpCaptureSecret,
        \\{"expectedDesiredGeneration":"7","serverId":"server-1","slot":{"kind":"oauth_client_secret"},"secret":"fixture-client-secret"}
    );
    defer payload.deinit();
    try std.testing.expectEqualStrings("fixture-client-secret", payload.value.secret);
    try std.testing.expectError(error.InvalidBridgePayload, parsePayload(McpCaptureSecret,
        \\{"expectedDesiredGeneration":"7","serverId":"server-1","slot":{"kind":"oauth_client_secret"}}
    ));
    try std.testing.expectError(error.InvalidBridgePayload, parsePayload(McpCaptureSecret,
        \\{"expectedDesiredGeneration":"7","serverId":"server-1","slot":{"kind":"oauth_client_secret"},"secret":"fixture","accessToken":"not-allowed"}
    ));
}
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
    modelSelection: NewTaskModelSelection,
    expectedSkillCatalogRevision: ?[]const u8,
    expectedSkillSelectionRevision: ?[]const u8,
    approvalMode: []const u8,
};
pub const TaskRun = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
    input: std.json.Value,
};
pub const TaskStop = struct { taskId: []const u8 };
pub const TaskSendInput = struct { operationId: []const u8, taskId: []const u8, input: std.json.Value };
pub fn validateInputOperationId(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidBridgePayload;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidBridgePayload;
}

pub const TaskApprovalMode = struct {
    taskId: []const u8,
    targetMode: product_control.ApprovalMode,
    expectedBindingEpoch: []const u8,
    expectedApprovalRevision: []const u8,
};
pub const TaskModelSelection = struct {
    taskId: []const u8,
    expectedSelectionRevision: []const u8,
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
pub const FilePreviewKey = struct { generation: []const u8, previewId: []const u8 };
pub const WorkspaceFileRequest = struct {
    generation: []const u8,
    previewId: []const u8,
    taskId: []const u8,
    workspaceId: []const u8,
    workspaceEpoch: []const u8,
    path: []const u8,
};
pub const FilePreviewChunkRequest = struct { generation: []const u8, previewId: []const u8, token: []const u8, offset: []const u8, securityEpoch: []const u8 };
pub const FilePreviewRequest = struct {
    generation: []const u8,
    previewId: []const u8,
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
pub const AttachmentAddBegin = struct {
    generation: []const u8,
    batchId: []const u8,
    remainingFiles: JsonU32 = .{ .value = product_control.max_attachment_batch_files },
    source: struct {
        kind: enum { picker, native_paths, file_bytes },
        paths: ?[]const []const u8 = null,
        files: ?[]const struct { name: []const u8, sizeBytes: []const u8 } = null,
    },
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
    modelSelection: NewTaskModelSelection,
    permissionProfile: []const u8,
    input: std.json.Value,
    recurrence: std.json.Value,
};
pub const ScheduledTaskUpdate = struct {
    scheduledTaskId: []const u8,
    expectedEpoch: []const u8,
    title: []const u8,
    modelSelection: ?NewTaskModelSelection,
    permissionProfile: []const u8,
    input: std.json.Value,
    recurrence: std.json.Value,
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

pub fn approvalMode(value: []const u8) ?product_control.ApprovalMode {
    return std.meta.stringToEnum(product_control.ApprovalMode, value);
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
        \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"modelSelection":{"targetModelRef":{"sourceId":"metask","modelId":"model-1"},"expectedSourceGeneration":"3","expectedCatalogGeneration":"4"},"expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"approvalMode":"manual"}
    );
    defer text.deinit();
    try std.testing.expect(text.value.expectedSkillCatalogRevision == null);
    try std.testing.expect(text.value.expectedSkillSelectionRevision == null);
    try std.testing.expectEqualStrings("model-1", text.value.modelSelection.targetModelRef.modelId);
    try std.testing.expectEqualStrings("4", text.value.modelSelection.expectedCatalogGeneration);
    try std.testing.expectEqual(
        product_control.ApprovalMode.manual,
        approvalMode(text.value.approvalMode).?,
    );
    try std.testing.expect(permissionProfile("full_access") != null);
    try std.testing.expect(permissionProfile("accept_edits") == null);
    var selected = try parsePayload(TaskCreate,
        \\{"workspace":{"kind":"automatic"},"modelSelection":{"targetModelRef":{"sourceId":"metask","modelId":"model-2"},"expectedSourceGeneration":"5","expectedCatalogGeneration":"6"},"expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"approvalMode":"full_access"}
    );
    defer selected.deinit();
    try std.testing.expectEqualStrings(
        "metask",
        selected.value.modelSelection.targetModelRef.sourceId,
    );
    try std.testing.expectEqualStrings(
        "model-2",
        selected.value.modelSelection.targetModelRef.modelId,
    );
    try std.testing.expectEqualStrings(
        "5",
        selected.value.modelSelection.expectedSourceGeneration,
    );
    try std.testing.expectEqualStrings(
        "6",
        selected.value.modelSelection.expectedCatalogGeneration,
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3","expectedSelectionRevision":"4","expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"approvalMode":"manual"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3","expectedSkillCatalogRevision":null,"expectedSkillSelectionRevision":null,"approvalMode":"manual"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3"}
        ),
    );
}

test "Custom Provider create accepts an optional typed first model and rejects malformed input" {
    var provider = try parsePayload(CustomProviderCreate,
        \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses","apiKey":"secret"}
    );
    defer provider.deinit();
    try std.testing.expectEqualStrings("Provider", provider.value.displayName);
    try std.testing.expectEqualStrings("secret", provider.value.apiKey);
    var initial_model = try parsePayload(CustomProviderCreate,
        \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses","apiKey":"secret","model":{"id":"gpt-5"}}
    );
    defer initial_model.deinit();
    try std.testing.expectEqualStrings("gpt-5", initial_model.value.model.?.id);
    var builtin_model = try parsePayload(BuiltinProviderCreate,
        \\{"providerId":"deepseek","baseUrl":"https://api.deepseek.com","apiKey":"secret","model":{"id":"deepseek-flash"}}
    );
    defer builtin_model.deinit();
    try std.testing.expectEqualStrings("deepseek-flash", builtin_model.value.model.?.id);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(CustomProviderCreate,
            \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses"}
        ),
    );
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(CustomProviderCreate,
            \\{"displayName":"Provider","protocol":"openai_responses","normalizedBaseUrl":"https://api.example.com/v1/responses","apiKey":"secret","model":"gpt-5"}
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
        \\{"generation":"1","previewId":"3","taskId":"1","runId":"2","fileReferenceId":"task:1:run:2:file:3"}
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
            \\{"generation":"1","previewId":"3","taskId":"1","runId":"2","fileReferenceId":"task:1:run:2:file:3","path":"src/main.zig"}
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
        \\{"title":"Current","modelSelection":{"targetModelRef":{"sourceId":"metask","modelId":"model-1"},"expectedSourceGeneration":"7","expectedCatalogGeneration":"9"},"permissionProfile":"approval_required","input":{"kind":"text","text":"inspect"},"recurrence":{"kind":"once","atUnixSeconds":"2"}}
    );
    defer current.deinit();
    try std.testing.expectEqualStrings(
        "metask",
        current.value.modelSelection.targetModelRef.sourceId,
    );
    try std.testing.expectEqualStrings("model-1", current.value.modelSelection.targetModelRef.modelId);
    try std.testing.expectEqualStrings("7", current.value.modelSelection.expectedSourceGeneration);
    try std.testing.expectEqualStrings("9", current.value.modelSelection.expectedCatalogGeneration);

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

test "expanded Run wire decodes escaped UTF-8 beyond the old payload budget" {
    const prefix = "{\"taskId\":\"1\",\"expectedBindingEpoch\":\"1\",\"input\":{\"kind\":\"text\",\"text\":\"";
    const suffix = "\"}}";
    const count = 52428;
    const unit = "界\\n\\\"";
    const payload = try std.testing.allocator.alloc(u8, prefix.len + unit.len * count + 4 + suffix.len);
    defer std.testing.allocator.free(payload);
    @memcpy(payload[0..prefix.len], prefix);
    for (0..count) |index| @memcpy(payload[prefix.len + index * unit.len ..][0..unit.len], unit);
    @memcpy(payload[prefix.len + count * unit.len ..][0..4], "xxxx");
    @memcpy(payload[payload.len - suffix.len ..], suffix);
    var parsed = try parsePayloadWithLimit(TaskRun, payload, 1024 * 1024);
    defer parsed.deinit();
    var input = try parseTaskRunInput(parsed.value.input);
    defer input.deinit();
    try std.testing.expectEqual(@as(usize, 256 * 1024), input.value.text.len);
    try std.testing.expect(std.mem.startsWith(u8, input.value.text, "界\n\""));
    try std.testing.expect(std.mem.endsWith(u8, input.value.text, "xxxx"));
}

test "Task approval mode payload is typed and requires both exact CAS identities" {
    var parsed = try parsePayload(TaskApprovalMode,
        \\{"taskId":"3","targetMode":"auto_review","expectedBindingEpoch":"7","expectedApprovalRevision":"18446744073709551615"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(product_control.ApprovalMode.auto_review, parsed.value.targetMode);
    try std.testing.expectEqual(@as(u64, 7), try parseWireId(parsed.value.expectedBindingEpoch));
    try std.testing.expectEqual(std.math.maxInt(u64), try parseWireId(parsed.value.expectedApprovalRevision));
    const invalid = [_][]const u8{
        \\{"taskId":"3","targetMode":"accept_edits","expectedBindingEpoch":"7","expectedApprovalRevision":"1"},
        \\{"taskId":"3","targetMode":"manual","expectedBindingEpoch":"7"},
        \\{"taskId":"3","targetMode":"manual","expectedBindingEpoch":"7","expectedApprovalRevision":1},
        \\{"taskId":"3","targetMode":"full_access","expectedBindingEpoch":"7","expectedApprovalRevision":"1","sessionId":"9"},
    };
    for (invalid) |payload| try std.testing.expectError(error.InvalidBridgePayload, parsePayload(TaskApprovalMode, payload));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("01"));
}

test "Task model selection payload uses independent intent revision and exact source-qualified target" {
    var parsed = try parsePayload(TaskModelSelection,
        \\{"taskId":"3","expectedSelectionRevision":"0","targetModelRef":{"sourceId":"provider-b","modelId":"model"},"expectedSourceGeneration":"7","expectedCatalogGeneration":"9"}
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 0), try parseWireId(parsed.value.expectedSelectionRevision));
    try std.testing.expectEqualStrings("provider-b", parsed.value.targetModelRef.sourceId);
    const invalid = [_][]const u8{
        \\{"taskId":"3","expectedModel":"model","expectedExecutionGeneration":"1","targetModelRef":{"sourceId":"metask","modelId":"model"},"expectedSourceGeneration":"7","expectedCatalogGeneration":"9"}
        ,
        \\{"taskId":"3","expectedSelectionRevision":"0","targetModelRef":{"modelId":"model"},"expectedSourceGeneration":"7","expectedCatalogGeneration":"9"}
        ,
        \\{"taskId":"3","expectedSelectionRevision":"0","targetModelRef":{"sourceId":"provider-b","modelId":"model","apiKey":"forbidden"},"expectedSourceGeneration":"7","expectedCatalogGeneration":"9"}
        ,
    };
    for (invalid) |payload| try std.testing.expectError(error.InvalidBridgePayload, parsePayload(TaskModelSelection, payload));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("01"));
    try std.testing.expectError(error.InvalidBridgeId, parseWireId("18446744073709551616"));
}

test "complete model metadata incoming declarations retain capabilities and token fields" {
    var parsed = try parsePayload(ModelMetadata,
        \\{"maxInputTokens":"1000000","maxOutputTokens":"131072","capabilities":{"textInput":true,"audioInput":false,"videoInput":true,"output":{"text":true,"image":false,"audio":false,"video":false,"embedding":false}}}
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("1000000", parsed.value.maxInputTokens.?);
    try std.testing.expectEqualStrings("131072", parsed.value.maxOutputTokens.?);
    try std.testing.expectEqual(@as(?bool, true), parsed.value.capabilities.output.text);
    inline for (.{ "{\"limits\":{}}", "{\"capabilities\":{\"output\":{\"audio\":\"true\"}}}" }) |invalid|
        try std.testing.expectError(error.InvalidBridgePayload, parsePayload(ModelMetadata, invalid));
}

test "Product view request is closed and validates stable history identity" {
    var parsed = try parsePayload(ProductViewRequest,
        \\{"taskId":"7","beforeRunId":"9","runLimit":4,"management":"skills","search":false,"searchQuery":"","searchCursor":null,"receipts":[],"known":{"securityEpoch":"0","versions":{"context":"0","workspaces":"0","taskIndex":"0","taskPage":"0","historyPage":"0","management":"0","searchIndex":"0"}}}
    );
    defer parsed.deinit();
    var query_storage: [64]product_control.ViewReceiptQuery = undefined;
    const request = try parsed.value.product(&query_storage);
    try std.testing.expectEqual(@as(?u64, 7), request.task_id);
    try std.testing.expectEqual(@as(?u64, 9), request.before_run_id);
    try std.testing.expectEqual(.skills, request.management);
    const invalid = [_][]const u8{
        \\{}
        ,
        \\{"taskId":null,"beforeRunId":null,"runLimit":4,"management":"unknown"}
        ,
        \\{"taskId":null,"beforeRunId":null,"runLimit":4,"management":"none","search":false,"searchQuery":"","searchCursor":null,"receipts":[],"fields":["tasks"]}
    };
    for (invalid) |payload| try std.testing.expectError(error.InvalidBridgePayload, parsePayload(ProductViewRequest, payload));
    parsed.value.taskId = null;
    parsed.value.beforeRunId = .{ .value = 2 };
    try std.testing.expectError(error.InvalidViewRequest, parsed.value.product(&query_storage));
    parsed.value.taskId = .{ .value = 0 };
    parsed.value.beforeRunId = null;
    try std.testing.expectError(error.InvalidViewRequest, parsed.value.product(&query_storage));
}

test "snapshot request scalars reject JSON coercions and accept only canonical wire forms" {
    const valid = "{\"taskId\":\"7\",\"beforeRunId\":null,\"runLimit\":4,\"management\":\"none\",\"search\":false,\"searchQuery\":\"\",\"searchCursor\":null,\"receipts\":[],\"known\":{\"securityEpoch\":\"0\",\"versions\":{\"context\":\"0\",\"workspaces\":\"0\",\"taskIndex\":\"0\",\"taskPage\":\"0\",\"historyPage\":\"0\",\"management\":\"0\",\"searchIndex\":\"0\"}}}";
    for ([_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "\"runLimit\":4", .to = "\"runLimit\":\"4\"" },
        .{ .from = "\"runLimit\":4", .to = "\"runLimit\":4.0" },
        .{ .from = "\"runLimit\":4", .to = "\"runLimit\":4e0" },
        .{ .from = "\"management\":\"none\"", .to = "\"management\":0" },
        .{ .from = "\"taskId\":\"7\"", .to = "\"taskId\":[55]" },
        .{ .from = "\"taskId\":\"7\"", .to = "\"taskId\":7" },
        .{ .from = "\"securityEpoch\":\"0\"", .to = "\"securityEpoch\":[48]" },
    }) |case| {
        const input = try std.mem.replaceOwned(u8, std.testing.allocator, valid, case.from, case.to);
        defer std.testing.allocator.free(input);
        try std.testing.expectError(error.InvalidBridgePayload, parsePayload(ProductViewRequest, input));
    }
    inline for (.{ "{\"preparingSnapshotId\":[49]}", "{\"preparingSnapshotId\":1}", "{\"preparingSnapshotId\":\"01\"}", "{\"preparingSnapshotId\":\"1\",\"extra\":true}" }) |input|
        try std.testing.expectError(error.InvalidBridgePayload, parsePayload(ProductSnapshotContinue, input));
    inline for (.{ "{\"snapshotId\":[49],\"offset\":\"0\"}", "{\"snapshotId\":\"1\",\"offset\":[48]}", "{\"snapshotId\":\"1\",\"offset\":\"+0\"}", "{\"snapshotId\":\"1\",\"offset\":\"00\"}" }) |input|
        try std.testing.expectError(error.InvalidBridgePayload, parsePayload(ProductSnapshotChunk, input));
    var continuation = try parsePayload(ProductSnapshotContinue, "{\"preparingSnapshotId\":\"1\"}");
    defer continuation.deinit();
    try std.testing.expectEqual(@as(u64, 1), continuation.value.preparingSnapshotId.value);
    var chunk = try parsePayload(ProductSnapshotChunk, "{\"snapshotId\":\"1\",\"offset\":\"0\"}");
    defer chunk.deinit();
    try std.testing.expectEqual(@as(u64, 0), chunk.value.offset.value);
}

test "Output action strict payload accepts only scoped identities and known actions" {
    const valid = "{\"generation\":\"1\",\"operationId\":\"1\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"check\"}";
    var parsed = try parsePayload(OutputAction, valid);
    defer parsed.deinit();
    _ = try parseOutputId(parsed.value.outputId.value);
    for ([_][]const u8{ "", "00000000000000000000000000000000", "ABCDEFABCDEFABCDEFABCDEFABCDEFAB", "030303" }) |id|
        try std.testing.expectError(error.InvalidBridgeId, parseOutputId(id));
    for ([_][]const u8{
        "{\"generation\":[49],\"operationId\":\"1\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"check\"}",
        "{\"generation\":\"1\",\"operationId\":\"1\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"shell\"}",
        "{\"generation\":\"1\",\"operationId\":\"1\",\"taskId\":\"3\",\"runId\":\"7\",\"outputId\":\"03030303030303030303030303030303\",\"action\":\"check\",\"path\":\"C:/secret\"}",
    }) |invalid| {
        if (parsePayload(OutputAction, invalid)) |value| {
            var owned = value;
            owned.deinit();
            return error.InvalidPayloadAccepted;
        } else |_| {}
    }
}

test "Skill import payloads accept only typed target and exact preparation confirmation" {
    var choice = try parsePayload(SkillImportChoice, "{\"kind\":\"directory\",\"target\":{\"kind\":\"personal\",\"workspaceId\":null,\"expectedWorkspaceEpoch\":null,\"installId\":null}}");
    defer choice.deinit();
    try std.testing.expectEqualStrings("personal", choice.value.target.kind);
    var confirmation = try parsePayload(SkillInstall, "{\"previewId\":\"7\",\"preparationRevision\":\"2\",\"confirmation\":\"update\"}");
    defer confirmation.deinit();
    try std.testing.expectEqualStrings("2", confirmation.value.preparationRevision);
    for ([_][]const u8{
        "{\"previewId\":\"7\",\"scope\":\"personal\",\"workspaceId\":null,\"expectedWorkspaceEpoch\":null,\"allowReplace\":true}",
        "{\"previewId\":\"7\",\"preparationRevision\":\"2\",\"confirmation\":\"update\",\"sourcePath\":\"/tmp/source\"}",
        "{\"previewId\":\"7\",\"preparationRevision\":2,\"confirmation\":\"update\"}",
    }) |payload| try std.testing.expectError(error.InvalidBridgePayload, parsePayload(SkillInstall, payload));
}

test "attachment remainingFiles is optional and accepts only JSON u32 integer literals" {
    var old = try parsePayload(AttachmentAddBegin, "{\"generation\":\"1\",\"batchId\":\"2\",\"source\":{\"kind\":\"picker\"}}");
    defer old.deinit();
    try std.testing.expectEqual(product_control.max_attachment_batch_files, old.value.remainingFiles.value);
    for ([_][]const u8{ "0", "1", "8", "4294967295" }) |value| {
        var buffer: [256]u8 = undefined;
        const input = try std.fmt.bufPrint(&buffer, "{{\"generation\":\"1\",\"batchId\":\"2\",\"remainingFiles\":{s},\"source\":{{\"kind\":\"picker\"}}}}", .{value});
        var parsed = try parsePayload(AttachmentAddBegin, input);
        defer parsed.deinit();
        try std.testing.expectEqual(try std.fmt.parseInt(u32, value, 10), parsed.value.remainingFiles.value);
    }
    for ([_][]const u8{ "null", "-1", "1.0", "1e0", "\"1\"", "true", "4294967296" }) |value| {
        var buffer: [256]u8 = undefined;
        const input = try std.fmt.bufPrint(&buffer, "{{\"generation\":\"1\",\"batchId\":\"2\",\"remainingFiles\":{s},\"source\":{{\"kind\":\"picker\"}}}}", .{value});
        try std.testing.expectError(error.InvalidBridgePayload, parsePayload(AttachmentAddBegin, input));
    }
}
