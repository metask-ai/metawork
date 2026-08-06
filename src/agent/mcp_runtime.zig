//! Linear Agent owner for canonical AgentCore MCP server descriptors and
//! connector adapters. AgentCore borrows descriptors during Runtime creation;
//! adapters remain alive until after Runtime destruction closes connections.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const connector = @import("agent_mcp_connector");

pub const TransportKind = enum { stdio, streamable_http };
pub const NegotiationPolicy = enum { automatic, modern_only, compat_only };

pub const ServerInput = struct {
    /// Stable Workbench registry identity. Agent derives the opaque AgentCore
    /// binding identity; callers cannot supply a second authority identity.
    id: []const u8,
    /// Runtime input linearly consumes the concrete transport owner.
    transport_owner: *connector.TransportOwner,
    /// Secret copies used only to fail closed if MCP payload bytes contain a
    /// configured credential. The adapter takes and securely clears its copy.
    secrets: []const []const u8 = &.{},
    transport: TransportKind,
    negotiation: NegotiationPolicy = .automatic,
    namespace: []const u8,
    client_name: []const u8,
    client_version: []const u8,
    timeout_ms: u32,
    allowed_tools: []const []const u8 = &.{},
};

pub const ExpectedServer = struct {
    id: []const u8,
    binding_identity: [32]u8,
    namespace: []const u8,
    allowed_tools: []const []const u8,
};

pub const Error = error{InvalidConfig};

pub const Servers = struct {
    arena: std.heap.ArenaAllocator,
    transport_owners: []connector.TransportOwner,
    initialized_transport_owners: usize,
    adapters: []connector.Adapter,
    initialized_adapters: usize,
    descriptors: []wire.McpServerV1,
    expected: []ExpectedServer,

    pub fn init(
        allocator: std.mem.Allocator,
        configs: []const ServerInput,
    ) (Error || std.mem.Allocator.Error)!Servers {
        try validate(configs);
        var self: Servers = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .transport_owners = &.{},
            .initialized_transport_owners = 0,
            .adapters = &.{},
            .initialized_adapters = 0,
            .descriptors = &.{},
            .expected = &.{},
        };
        errdefer self.deinit();
        const owned = self.arena.allocator();
        self.transport_owners = try owned.alloc(connector.TransportOwner, configs.len);
        self.adapters = try owned.alloc(connector.Adapter, configs.len);
        self.descriptors = try owned.alloc(wire.McpServerV1, configs.len);
        self.expected = try owned.alloc(ExpectedServer, configs.len);
        for (configs, 0..) |config, index| {
            const id = try owned.dupe(u8, config.id);
            const namespace = try owned.dupe(u8, config.namespace);
            const client_name = try owned.dupe(u8, config.client_name);
            const client_version = try owned.dupe(u8, config.client_version);
            const allowed_tools = try owned.alloc([]const u8, config.allowed_tools.len);
            for (config.allowed_tools, allowed_tools) |tool, *target|
                target.* = try owned.dupe(u8, tool);
            self.expected[index] = .{
                .id = id,
                .binding_identity = bindingIdentity(id),
                .namespace = namespace,
                .allowed_tools = allowed_tools,
            };
            self.descriptors[index] = .{
                .struct_size = @sizeOf(wire.McpServerV1),
                .transport_code = switch (config.transport) {
                    .stdio => wire.MCP_TRANSPORT_STDIO,
                    .streamable_http => wire.MCP_TRANSPORT_STREAMABLE_HTTP,
                },
                .negotiation_policy_code = switch (config.negotiation) {
                    .automatic => wire.MCP_NEGOTIATION_AUTO,
                    .modern_only => wire.MCP_NEGOTIATION_MODERN_ONLY,
                    .compat_only => wire.MCP_NEGOTIATION_LEGACY_ONLY,
                },
                .reserved0 = 0,
                .server_binding_identity = self.expected[index].binding_identity,
                .namespace = sdk.bytesView(namespace),
                .client_name = sdk.bytesView(client_name),
                .client_version = sdk.bytesView(client_version),
                .timeout_ms = config.timeout_ms,
                .reserved1 = 0,
                .connector = std.mem.zeroes(wire.McpConnectorV1),
                .protocol_limits = null,
                .reserved = [_]u64{0} ** 4,
            };
        }
        for (configs, 0..) |config, index| {
            self.adapters[index] = connector.Adapter.init(allocator, .{
                .transport = config.transport_owner.transport,
                .secrets = config.secrets,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidConfig, error.ConnectionsActive => return error.InvalidConfig,
            };
            self.initialized_adapters += 1;
            self.descriptors[index].connector = self.adapters[index].descriptor();
        }
        // All fallible work is complete. Transport ownership moves as one
        // commit so an initialization failure never partially consumes input.
        for (configs, 0..) |config, index| {
            self.transport_owners[index] = config.transport_owner.take();
            self.initialized_transport_owners += 1;
        }
        return self;
    }

    pub fn attach(self: *const Servers, config: *wire.RuntimeConfigV1) void {
        config.mcp_servers = if (self.descriptors.len == 0) null else self.descriptors.ptr;
        config.mcp_server_count = self.descriptors.len;
        config.mcp_catalog_limits = null;
    }

    pub fn expectedServers(self: *const Servers) []const ExpectedServer {
        return self.expected;
    }

    pub fn deinit(self: *Servers) void {
        var index = self.initialized_adapters;
        while (index != 0) {
            index -= 1;
            self.adapters[index].deinit() catch
                @panic("MCP Runtime released an adapter with live connections");
        }
        index = self.initialized_transport_owners;
        while (index != 0) {
            index -= 1;
            self.transport_owners[index].deinit();
        }
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Single-use, fully owned MCP input. Construction may fail as an attributable
/// MCP preparation error; once constructed, Runtime takes it without building
/// or opening a transport.
pub const Input = struct {
    generation: u64,
    servers: ?Servers,

    pub fn init(
        allocator: std.mem.Allocator,
        generation: u64,
        configs: []const ServerInput,
    ) (Error || std.mem.Allocator.Error)!Input {
        if (generation == 0) return error.InvalidConfig;
        return .{
            .generation = generation,
            .servers = try Servers.init(allocator, configs),
        };
    }

    pub fn take(self: *Input) Error!Servers {
        const servers = self.servers orelse return error.InvalidConfig;
        self.servers = null;
        return servers;
    }

    pub fn deinit(self: *Input) void {
        if (self.servers) |*servers| servers.deinit();
        self.* = undefined;
    }
};

pub fn bindingIdentity(id: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("metawork.mcp.server-binding/v1\x00");
    hash.update(id);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn validate(configs: []const ServerInput) Error!void {
    if (configs.len > wire.MAX_MCP_SERVERS_V1) return error.InvalidConfig;
    var total_allowed_tools: usize = 0;
    for (configs, 0..) |config, index| {
        total_allowed_tools = std.math.add(
            usize,
            total_allowed_tools,
            config.allowed_tools.len,
        ) catch return error.InvalidConfig;
        if (config.id.len == 0 or config.id.len > 128 or
            config.timeout_ms == 0 or config.namespace.len == 0 or
            config.namespace.len > wire.MAX_MCP_NAMESPACE_BYTES_V1 or
            config.client_name.len == 0 or config.client_version.len == 0 or
            config.allowed_tools.len > wire.MAX_MCP_TOOLS_V1 or
            !std.unicode.utf8ValidateSlice(config.id) or
            !std.unicode.utf8ValidateSlice(config.namespace) or
            !std.unicode.utf8ValidateSlice(config.client_name) or
            !std.unicode.utf8ValidateSlice(config.client_version))
            return error.InvalidConfig;
        if (total_allowed_tools > wire.MAX_MCP_TOOLS_V1)
            return error.InvalidConfig;
        for (config.allowed_tools, 0..) |tool, tool_index| {
            if (tool.len == 0 or !std.unicode.utf8ValidateSlice(tool))
                return error.InvalidConfig;
            for (config.allowed_tools[0..tool_index]) |previous|
                if (std.mem.eql(u8, previous, tool)) return error.InvalidConfig;
        }
        for (configs[0..index]) |previous| {
            if (previous.transport_owner == config.transport_owner or
                std.mem.eql(u8, previous.id, config.id) or
                std.mem.eql(u8, previous.namespace, config.namespace))
                return error.InvalidConfig;
        }
    }
}

const FakeTransport = struct {
    deinitialized: bool = false,

    fn descriptor(self: *FakeTransport) connector.Transport {
        return .{ .context = self, .open_fn = open, .request_fn = request, .notify_fn = notify, .close_fn = close };
    }
    fn open(context: *anyopaque, _: connector.Purpose, _: connector.Era, _: u32) connector.OpenOutcome {
        return .{ .connection = context };
    }
    fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: u32, _: connector.Cancellation) connector.ExchangeOutcome {
        return .{ .failure = .fatal };
    }
    fn notify(_: *anyopaque, _: []const u8, _: u32, _: connector.Cancellation) ?connector.Failure {
        return .fatal;
    }
    fn close(_: *anyopaque) void {}
    fn deinit(context: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(context));
        self.deinitialized = true;
    }
};

test "Runtime input derives authority and consumes transport ownership linearly" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    var input = try Input.init(std.testing.allocator, 7, &.{.{
        .id = "local-files",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "files",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1000,
        .allowed_tools = &.{"read_file"},
    }});
    defer input.deinit();
    var servers = try input.take();
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    servers.attach(&runtime_config);
    try std.testing.expectEqual(@as(u64, 1), runtime_config.mcp_server_count);
    try std.testing.expectEqualStrings("files", try sdk.borrowedBytes(servers.descriptors[0].namespace));
    try std.testing.expectEqual(@as(usize, 1), servers.expectedServers().len);
    try std.testing.expectEqualStrings("local-files", servers.expectedServers()[0].id);
    try std.testing.expectEqualDeep(
        bindingIdentity("local-files"),
        servers.descriptors[0].server_binding_identity,
    );
    try std.testing.expectError(error.InvalidConfig, input.take());
    servers.deinit();
    try std.testing.expect(transport.deinitialized);
}

test "Runtime input rejects duplicate stable authority identities" {
    var first_transport: FakeTransport = .{};
    var second_transport: FakeTransport = .{};
    var first = connector.TransportOwner.init(first_transport.descriptor(), FakeTransport.deinit);
    defer first.deinit();
    var second = connector.TransportOwner.init(second_transport.descriptor(), FakeTransport.deinit);
    defer second.deinit();
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{
        .{ .id = "same", .transport_owner = &first, .transport = .stdio, .namespace = "one", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
        .{ .id = "same", .transport_owner = &second, .transport = .streamable_http, .namespace = "two", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
    }));
}

test "Runtime input rejects moving one transport owner twice" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    defer owner.deinit();
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{
        .{ .id = "one", .transport_owner = &owner, .transport = .stdio, .namespace = "one", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
        .{ .id = "two", .transport_owner = &owner, .transport = .stdio, .namespace = "two", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
    }));
}

test "Runtime input failure consumes no transport ownership" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{.{
        .id = "invalid-secrets",
        .transport_owner = &owner,
        .secrets = &.{ "duplicate", "duplicate" },
        .transport = .stdio,
        .namespace = "invalid",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1000,
    }}));
    try std.testing.expect(!transport.deinitialized);
    owner.deinit();
    try std.testing.expect(transport.deinitialized);
}
