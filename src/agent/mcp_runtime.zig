//! Linear Agent owner for canonical AgentCore MCP server descriptors and
//! connector adapters. AgentCore borrows descriptors during Runtime creation;
//! adapters remain alive until after Runtime destruction closes connections.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const connector = @import("agent_mcp_connector");

pub const TransportKind = enum { stdio, streamable_http };
pub const NegotiationPolicy = enum { automatic, modern_only, compat_only };

pub const ServerConfig = struct {
    /// Runtime initialization linearly consumes this adapter. The caller must
    /// provide exclusive access and keep its Transport context alive until
    /// Runtime shutdown and deinitialization complete.
    binding_identity: [32]u8,
    adapter: *connector.Adapter,
    transport: TransportKind,
    negotiation: NegotiationPolicy = .automatic,
    namespace: []const u8,
    client_name: []const u8,
    client_version: []const u8,
    timeout_ms: u32,
};

pub const ExpectedServer = struct {
    binding_identity: [32]u8,
    namespace: []const u8,
};

pub const Error = error{InvalidConfig};

pub const Servers = struct {
    arena: std.heap.ArenaAllocator,
    adapters: []connector.Adapter,
    initialized_adapters: usize,
    descriptors: []wire.McpServerV1,
    expected: []ExpectedServer,

    pub fn init(
        allocator: std.mem.Allocator,
        configs: []const ServerConfig,
    ) (Error || std.mem.Allocator.Error)!Servers {
        try validate(configs);
        var self: Servers = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .adapters = &.{},
            .initialized_adapters = 0,
            .descriptors = &.{},
            .expected = &.{},
        };
        errdefer self.deinit();
        const owned = self.arena.allocator();
        self.adapters = try owned.alloc(connector.Adapter, configs.len);
        self.descriptors = try owned.alloc(wire.McpServerV1, configs.len);
        self.expected = try owned.alloc(ExpectedServer, configs.len);
        for (configs, 0..) |config, index| {
            const namespace = try owned.dupe(u8, config.namespace);
            const client_name = try owned.dupe(u8, config.client_name);
            const client_version = try owned.dupe(u8, config.client_version);
            self.expected[index] = .{
                .binding_identity = config.binding_identity,
                .namespace = namespace,
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
                .server_binding_identity = config.binding_identity,
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
            self.adapters[index] = config.adapter.take() catch
                return error.InvalidConfig;
            self.initialized_adapters += 1;
            self.descriptors[index].connector = self.adapters[index].descriptor();
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
        self.arena.deinit();
        self.* = undefined;
    }
};

fn validate(configs: []const ServerConfig) Error!void {
    if (configs.len > wire.MAX_MCP_SERVERS_V1) return error.InvalidConfig;
    for (configs, 0..) |config, index| {
        if (config.timeout_ms == 0 or config.namespace.len == 0 or
            config.namespace.len > wire.MAX_MCP_NAMESPACE_BYTES_V1 or
            config.client_name.len == 0 or config.client_version.len == 0 or
            !std.unicode.utf8ValidateSlice(config.namespace) or
            !std.unicode.utf8ValidateSlice(config.client_name) or
            !std.unicode.utf8ValidateSlice(config.client_version) or
            !config.adapter.isQuiescent())
            return error.InvalidConfig;
        for (configs[0..index]) |previous| {
            if (previous.adapter == config.adapter or
                std.mem.eql(u8, &previous.binding_identity, &config.binding_identity) or
                std.mem.eql(u8, previous.namespace, config.namespace))
                return error.InvalidConfig;
        }
    }
}

const FakeTransport = struct {
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
};

test "Runtime server owner copies metadata and consumes adapters linearly" {
    var transport: FakeTransport = .{};
    var adapter = try connector.Adapter.init(std.testing.allocator, .{ .transport = transport.descriptor() });
    var servers = try Servers.init(std.testing.allocator, &.{.{
        .binding_identity = @splat(0x2a),
        .adapter = &adapter,
        .transport = .stdio,
        .namespace = "files",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1000,
    }});
    defer servers.deinit();
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    servers.attach(&runtime_config);
    try std.testing.expectEqual(@as(u64, 1), runtime_config.mcp_server_count);
    try std.testing.expectEqualStrings("files", try sdk.borrowedBytes(servers.descriptors[0].namespace));
    try std.testing.expectEqual(@as(usize, 1), servers.expectedServers().len);
}

test "Runtime server owner rejects duplicate authority identities" {
    var first_transport: FakeTransport = .{};
    var second_transport: FakeTransport = .{};
    var first = try connector.Adapter.init(std.testing.allocator, .{ .transport = first_transport.descriptor() });
    defer first.deinit() catch unreachable;
    var second = try connector.Adapter.init(std.testing.allocator, .{ .transport = second_transport.descriptor() });
    defer second.deinit() catch unreachable;
    const identity: [32]u8 = @splat(1);
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{
        .{ .binding_identity = identity, .adapter = &first, .transport = .stdio, .namespace = "one", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
        .{ .binding_identity = identity, .adapter = &second, .transport = .streamable_http, .namespace = "two", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
    }));
}

test "Runtime server owner rejects moving one adapter twice" {
    var transport: FakeTransport = .{};
    var adapter = try connector.Adapter.init(std.testing.allocator, .{ .transport = transport.descriptor() });
    defer adapter.deinit() catch unreachable;
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{
        .{ .binding_identity = @splat(1), .adapter = &adapter, .transport = .stdio, .namespace = "one", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
        .{ .binding_identity = @splat(2), .adapter = &adapter, .transport = .stdio, .namespace = "two", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000 },
    }));
}
