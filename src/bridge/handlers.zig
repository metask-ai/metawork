//! Strict payload records and parsing shared by Bridge handlers.

const std = @import("std");
const workbench_api = @import("metawork_workbench");
const max_skill_argument_values: usize = 64;

pub const PermissionChoice = enum {
    allow_once,
    deny_once,
};

pub const RendererBridgeConnect = struct {
    contractId: []const u8,
    contractRevision: u32,
};
pub const EventDisconnect = struct { generation: []const u8 };
pub const WorkbenchSnapshotChunk = struct { snapshotId: []const u8, offset: []const u8 };
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
pub const AccountSelection = struct {
    selectionId: []const u8,
    expectedCatalogGeneration: []const u8,
    expectedExecutionGeneration: []const u8,
};
pub const WorkspaceIdentity = struct {
    workspaceId: []const u8,
    expectedWorkspaceEpoch: []const u8,
};
pub const SkillImportChoice = struct { kind: []const u8 };
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
pub const TaskCreate = struct {
    workspace: TaskWorkspaceIntent,
    expectedExecutionGeneration: []const u8,
    expectedSkillCatalogRevision: ?[]const u8,
};
pub const TaskRun = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
    input: std.json.Value,
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
        argument_values: []const []const u8,
    },
};
pub const ParsedTaskRunInput = struct {
    value: TaskRunInput,
    owned_argument_values: ?[][]const u8 = null,

    pub fn deinit(self: *ParsedTaskRunInput) void {
        if (self.owned_argument_values) |values|
            std.heap.c_allocator.free(values);
        self.* = undefined;
    }
};
pub const TaskCatalogRefresh = struct {
    taskId: []const u8,
    expectedBindingEpoch: []const u8,
};
pub const TaskIdentity = struct { taskId: []const u8, runId: []const u8 };
pub const TaskClose = struct { taskId: []const u8 };
pub const TaskRename = struct { taskId: []const u8, title: []const u8 };
pub const TaskArchive = struct { taskId: []const u8, archived: bool };
pub const TaskDelete = struct { taskId: []const u8 };
pub const ScheduledTaskMutation = struct {
    title: []const u8,
    expectedExecutionGeneration: []const u8,
    input: std.json.Value,
    recurrence: std.json.Value,
};
pub const ScheduledTaskUpdate = struct {
    scheduledTaskId: []const u8,
    expectedEpoch: []const u8,
    title: []const u8,
    expectedExecutionGeneration: []const u8,
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
    answers: ?[]const []const []const u8 = null,
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
    if (!std.mem.eql(u8, kind_text, "skill") or object.count() != 4)
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
            .argument_values = argument_values,
        } },
        .owned_argument_values = argument_values,
    };
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
) !workbench_api.ScheduledTaskRecurrence {
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
    if (std.mem.eql(u8, value, "deny_once")) return .deny_once;
    return null;
}

test "Task Run input is an exact text or skill tagged object" {
    var text_payload = try parsePayload(TaskRun,
        \\{"taskId":"1","expectedBindingEpoch":"2","input":{"kind":"text","text":"inspect"}}
    );
    defer text_payload.deinit();
    var text_input = try parseTaskRunInput(text_payload.value.input);
    defer text_input.deinit();
    try std.testing.expectEqualStrings("inspect", text_input.value.text);

    var skill_payload = try parsePayload(TaskRun,
        \\{"taskId":"1","expectedBindingEpoch":"2","input":{"kind":"skill","skillId":"builtin.review","catalogRevision":"revision","argumentValues":["src/main.zig","correctness"]}}
    );
    defer skill_payload.deinit();
    var skill_input = try parseTaskRunInput(skill_payload.value.input);
    defer skill_input.deinit();
    try std.testing.expectEqualStrings(
        "builtin.review",
        skill_input.value.skill.skill_id,
    );
    try std.testing.expectEqual(@as(usize, 2), skill_input.value.skill.argument_values.len);

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
}

test "Task creation requires an explicit nullable catalog revision" {
    var text = try parsePayload(TaskCreate,
        \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3","expectedSkillCatalogRevision":null}
    );
    defer text.deinit();
    try std.testing.expect(text.value.expectedSkillCatalogRevision == null);
    try std.testing.expectError(
        error.InvalidBridgePayload,
        parsePayload(TaskCreate,
            \\{"workspace":{"kind":"manual","workspaceId":"1","expectedWorkspaceEpoch":"2"},"expectedExecutionGeneration":"3"}
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
