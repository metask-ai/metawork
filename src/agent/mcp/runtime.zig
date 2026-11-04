//! Linear Agent owner for canonical AgentCore MCP server descriptors and
//! connector adapters. AgentCore borrows descriptors during Runtime creation;
//! adapters remain alive until after Runtime destruction closes connections.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const connector = @import("agent_mcp_connector");

pub const TransportKind = enum { stdio, streamable_http };
pub const NegotiationPolicy = enum { automatic, modern_only, compat_only };

/// Serialized under the Session Runtime mutex. A single phase is also the
/// shutdown fence, so apply/refresh cannot disagree with an independent count.
pub const OperationState = struct {
    pub const Phase = enum { idle, refresh, apply };
    phase: Phase = .idle,
    current_generation: ?u64 = null,
    previous_generation: ?u64 = null,

    pub fn busy(self: OperationState) bool {
        return self.phase != .idle;
    }

    pub fn begin(self: *OperationState, phase: Phase) bool {
        std.debug.assert(phase != .idle);
        if (self.busy()) return false;
        self.phase = phase;
        self.previous_generation = null;
        return true;
    }

    pub fn completeRefresh(self: *OperationState, generation: u64) void {
        std.debug.assert(self.phase == .refresh);
        self.previous_generation = self.current_generation;
        self.current_generation = generation;
        self.phase = .idle;
    }

    pub fn completeApply(self: *OperationState) void {
        std.debug.assert(self.phase == .apply);
        self.phase = .idle;
    }

    pub fn fail(self: *OperationState, keep_catalog: bool) void {
        std.debug.assert(self.busy());
        if (!keep_catalog) {
            self.current_generation = null;
            self.previous_generation = null;
        }
        self.phase = .idle;
    }

    pub fn accepts(self: OperationState, generation: u64) bool {
        return self.current_generation == generation or self.previous_generation == generation;
    }
};

test "MCP operation fence retains published authority during apply and one refresh handoff" {
    var state = OperationState{};
    try std.testing.expect(state.begin(.refresh));
    try std.testing.expect(!state.begin(.apply));
    state.completeRefresh(7);
    try std.testing.expect(state.accepts(7));
    try std.testing.expect(state.begin(.refresh));
    try std.testing.expect(state.accepts(7));
    state.completeRefresh(8);
    try std.testing.expect(state.accepts(7) and state.accepts(8));
    try std.testing.expect(state.begin(.refresh));
    try std.testing.expect(!state.accepts(7));
    state.fail(true);
    try std.testing.expect(state.accepts(8) and !state.busy());
    try std.testing.expect(state.begin(.apply));
    try std.testing.expect(state.accepts(8));
    state.completeApply();
    try std.testing.expect(!state.busy() and state.accepts(8));
    try std.testing.expect(state.begin(.refresh));
    state.completeRefresh(9);
    try std.testing.expect(state.begin(.refresh));
    state.fail(false);
    try std.testing.expect(!state.accepts(9));
}

pub const ServerInput = struct {
    /// Stable registry identity. Agent derives the opaque AgentCore
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
    /// Non-secret Runtime Manifest identity. A changed value causes
    /// AgentCore to replace the corresponding ServerInstance during a
    /// declarative Runtime configuration apply.
    configuration_fingerprint: [32]u8,
    allowed_tools: []const []const u8 = &.{},
};

pub const ExpectedServer = struct {
    id: []const u8,
    binding_identity: [32]u8,
    namespace: []const u8,
    allowed_tools: []const []const u8,
    configuration_fingerprint: [32]u8 = [_]u8{0} ** 32,
};

pub const Error = error{InvalidConfig};

const Member = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    references: std.atomic.Value(usize) = .init(1),
    transport_owner: ?connector.TransportOwner = null,
    adapter: connector.Adapter,
    descriptor: wire.McpServerV1,
    expected: ExpectedServer,

    fn prepare(allocator: std.mem.Allocator, config: ServerInput) (Error || std.mem.Allocator.Error)!*Member {
        const member = try allocator.create(Member);
        errdefer allocator.destroy(member);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const id = try owned.dupe(u8, config.id);
        const namespace = try owned.dupe(u8, config.namespace);
        const client_name = try owned.dupe(u8, config.client_name);
        const client_version = try owned.dupe(u8, config.client_version);
        const allowed_tools = try owned.alloc([]const u8, config.allowed_tools.len);
        for (config.allowed_tools, allowed_tools) |tool, *target|
            target.* = try owned.dupe(u8, tool);
        const adapter = connector.Adapter.init(allocator, .{
            .transport = config.transport_owner.transport,
            .secrets = config.secrets,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
        };
        member.* = .{
            .allocator = allocator,
            .arena = arena,
            .adapter = adapter,
            .expected = .{
                .id = id,
                .binding_identity = bindingIdentity(id),
                .namespace = namespace,
                .allowed_tools = allowed_tools,
                .configuration_fingerprint = config.configuration_fingerprint,
            },
            .descriptor = .{
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
                .server_binding_identity = bindingIdentity(id),
                .namespace = sdk.bytesView(namespace),
                .client_name = sdk.bytesView(client_name),
                .client_version = sdk.bytesView(client_version),
                .timeout_ms = config.timeout_ms,
                .reserved1 = 0,
                .connector = undefined,
                .protocol_limits = null,
                .configuration_fingerprint = config.configuration_fingerprint,
            },
        };
        member.descriptor.connector = member.adapter.descriptor();
        return member;
    }

    fn retain(self: *Member) void {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
    }

    fn release(self: *Member) void {
        const previous = self.references.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        self.adapter.deinit() catch |err| switch (err) {
            error.ConnectionsActive => @panic("MCP member released with live connections"),
            error.ConnectorRetained => @panic("MCP member still retained by AgentCore"),
        };
        if (self.transport_owner) |*owner| owner.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Each configuration owns a list of member references. Shared unchanged
/// members keep one stable connector; retiring a list never pins its siblings.
pub const Servers = struct {
    arena: std.heap.ArenaAllocator,
    members: []*Member = &.{},
    initialized_members: usize = 0,
    descriptors: []wire.McpServerV1 = &.{},
    expected: []ExpectedServer = &.{},

    fn allocate(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Servers {
        var self: Servers = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.arena.deinit();
        const owned = self.arena.allocator();
        self.members = try owned.alloc(*Member, count);
        self.descriptors = try owned.alloc(wire.McpServerV1, count);
        self.expected = try owned.alloc(ExpectedServer, count);
        return self;
    }

    pub fn init(allocator: std.mem.Allocator, configs: []const ServerInput) (Error || std.mem.Allocator.Error)!Servers {
        try validate(configs);
        var self = try allocate(allocator, configs.len);
        errdefer self.deinit();
        for (configs, 0..) |config, index| {
            const member = try Member.prepare(allocator, config);
            self.members[index] = member;
            self.initialized_members += 1;
            self.descriptors[index] = member.descriptor;
            self.expected[index] = member.expected;
        }
        // No ownership moves until every allocation and adapter is prepared.
        for (configs, self.members) |config, member|
            member.transport_owner = config.transport_owner.take();
        return self;
    }

    pub fn compose(allocator: std.mem.Allocator, current: *const Servers, additions: ?*const Servers, ids: []const []const u8) (Error || std.mem.Allocator.Error)!Servers {
        if (ids.len > wire.MAX_MCP_SERVERS_V1) return error.InvalidConfig;
        var self = try allocate(allocator, ids.len);
        errdefer self.deinit();
        var tool_count: usize = 0;
        for (ids, 0..) |id, index| {
            const member = (if (additions) |value| value.find(id) else null) orelse current.find(id) orelse return error.InvalidConfig;
            tool_count = std.math.add(usize, tool_count, member.expected.allowed_tools.len) catch return error.InvalidConfig;
            if (tool_count > wire.MAX_MCP_TOOLS_V1) return error.InvalidConfig;
            for (self.members[0..index]) |previous| {
                if (std.mem.eql(u8, previous.expected.id, id) or
                    std.mem.eql(u8, previous.expected.namespace, member.expected.namespace)) return error.InvalidConfig;
            }
            member.retain();
            self.members[index] = member;
            self.initialized_members += 1;
            self.descriptors[index] = member.descriptor;
            self.expected[index] = member.expected;
        }
        return self;
    }

    fn find(self: *const Servers, id: []const u8) ?*Member {
        for (self.members) |member|
            if (std.mem.eql(u8, member.expected.id, id)) return member;
        return null;
    }

    pub fn attach(self: *const Servers, config: *wire.RuntimeConfigV1) void {
        config.mcp_servers = if (self.descriptors.len == 0) null else self.descriptors.ptr;
        config.mcp_server_count = self.descriptors.len;
        config.mcp_catalog_limits = null;
    }

    pub fn configuration(self: *const Servers, desired_revision: u64) wire.McpConfigurationV1 {
        std.debug.assert(desired_revision != 0);
        return .{
            .struct_size = @sizeOf(wire.McpConfigurationV1),
            .reserved0 = 0,
            .desired_revision = desired_revision,
            .servers = if (self.descriptors.len == 0) null else self.descriptors.ptr,
            .server_count = self.descriptors.len,
            .reserved = [_]u64{0} ** 4,
        };
    }

    pub fn expectedServers(self: *const Servers) []const ExpectedServer {
        return self.expected;
    }

    pub fn isQuiescent(self: *const Servers) bool {
        for (self.members[0..self.initialized_members]) |member| {
            if (member.references.load(.acquire) == 1 and !member.adapter.isQuiescent()) return false;
        }
        return true;
    }

    pub fn deinit(self: *Servers) void {
        for (self.members[0..self.initialized_members]) |member| member.release();
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

    pub fn compose(allocator: std.mem.Allocator, generation: u64, current: *const Servers, additions: ?*const Input, ids: []const []const u8) (Error || std.mem.Allocator.Error)!Input {
        if (generation == 0) return error.InvalidConfig;
        const added = if (additions) |input| &(input.servers orelse return error.InvalidConfig) else null;
        return .{ .generation = generation, .servers = try Servers.compose(allocator, current, added, ids) };
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
            config.timeout_ms == 0 or !validNamespace(config.namespace) or
            config.client_name.len == 0 or config.client_version.len == 0 or
            std.mem.allEqual(u8, &config.configuration_fingerprint, 0) or
            config.allowed_tools.len > wire.MAX_MCP_TOOLS_V1 or
            !std.unicode.utf8ValidateSlice(config.id) or
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

fn validNamespace(value: []const u8) bool {
    if (value.len == 0 or value.len > wire.MAX_MCP_NAMESPACE_BYTES_V1 or
        !std.ascii.isAlphabetic(value[0]))
        return false;
    for (value[1..]) |byte|
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
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
        .configuration_fingerprint = [_]u8{1} ** 32,
        .allowed_tools = &.{"read_file"},
    }});
    defer input.deinit();
    var servers = try input.take();
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    servers.attach(&runtime_config);
    try std.testing.expectEqual(@as(u64, 1), runtime_config.mcp_server_count);
    const configuration = servers.configuration(9);
    try std.testing.expectEqual(@as(u64, 9), configuration.desired_revision);
    try std.testing.expectEqual(@as(u64, 1), configuration.server_count);
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

test "shared MCP members release old configuration lists without retiring a live connector" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    var input = try Input.init(std.testing.allocator, 1, &.{.{
        .id = "retained",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "retained",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1000,
        .configuration_fingerprint = @splat(1),
    }});
    defer input.deinit();
    var current = try input.take();
    const descriptor = current.descriptors[0].connector;
    descriptor.retain_connector.?(descriptor.ctx);
    try std.testing.expect(!current.isQuiescent());
    for (0..150) |_| {
        const next = try Servers.compose(std.testing.allocator, &current, null, &.{"retained"});
        try std.testing.expect(current.isQuiescent());
        current.deinit();
        try std.testing.expect(!transport.deinitialized);
        try std.testing.expectEqual(descriptor.ctx, next.descriptors[0].connector.ctx);
        current = next;
    }
    try std.testing.expect(!current.isQuiescent());
    descriptor.release_connector.?(descriptor.ctx);
    try std.testing.expect(current.isQuiescent());
    current.deinit();
    try std.testing.expect(transport.deinitialized);
}

test "MCP membership composition rejects duplicate members without consuming the source" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    var input = try Input.init(std.testing.allocator, 1, &.{.{
        .id = "one",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "one",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1000,
        .configuration_fingerprint = @splat(1),
    }});
    defer input.deinit();
    try std.testing.expectError(error.InvalidConfig, Servers.compose(std.testing.allocator, &input.servers.?, null, &.{ "one", "one" }));
    try std.testing.expect(!transport.deinitialized);
    try std.testing.expectEqual(@as(usize, 1), input.servers.?.members[0].references.load(.acquire));
}

test "Runtime input rejects duplicate stable authority identities" {
    var first_transport: FakeTransport = .{};
    var second_transport: FakeTransport = .{};
    var first = connector.TransportOwner.init(first_transport.descriptor(), FakeTransport.deinit);
    defer first.deinit();
    var second = connector.TransportOwner.init(second_transport.descriptor(), FakeTransport.deinit);
    defer second.deinit();
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{
        .{ .id = "same", .transport_owner = &first, .transport = .stdio, .namespace = "one", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000, .configuration_fingerprint = [_]u8{1} ** 32 },
        .{ .id = "same", .transport_owner = &second, .transport = .streamable_http, .namespace = "two", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000, .configuration_fingerprint = [_]u8{2} ** 32 },
    }));
}

test "Runtime input rejects moving one transport owner twice" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    defer owner.deinit();
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{
        .{ .id = "one", .transport_owner = &owner, .transport = .stdio, .namespace = "one", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000, .configuration_fingerprint = [_]u8{1} ** 32 },
        .{ .id = "two", .transport_owner = &owner, .transport = .stdio, .namespace = "two", .client_name = "MetaWork", .client_version = "1", .timeout_ms = 1000, .configuration_fingerprint = [_]u8{2} ** 32 },
    }));
}

test "Runtime input rejects namespaces outside the AgentCore identifier grammar" {
    for ([_][]const u8{ "mcp-server", "1server", "server.name" }) |namespace| {
        var transport: FakeTransport = .{};
        var owner = connector.TransportOwner.init(
            transport.descriptor(),
            FakeTransport.deinit,
        );
        try std.testing.expectError(
            error.InvalidConfig,
            Servers.init(std.testing.allocator, &.{.{
                .id = "server-id",
                .transport_owner = &owner,
                .transport = .stdio,
                .namespace = namespace,
                .client_name = "MetaWork",
                .client_version = "1",
                .timeout_ms = 1000,
                .configuration_fingerprint = [_]u8{1} ** 32,
            }}),
        );
        try std.testing.expect(!transport.deinitialized);
        owner.deinit();
        try std.testing.expect(transport.deinitialized);
    }
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
        .configuration_fingerprint = [_]u8{1} ** 32,
    }}));
    try std.testing.expect(!transport.deinitialized);
    owner.deinit();
    try std.testing.expect(transport.deinitialized);
}

test "Runtime input rejects an absent configuration fingerprint" {
    var transport: FakeTransport = .{};
    var owner = connector.TransportOwner.init(transport.descriptor(), FakeTransport.deinit);
    try std.testing.expectError(error.InvalidConfig, Servers.init(std.testing.allocator, &.{.{
        .id = "server-id",
        .transport_owner = &owner,
        .transport = .stdio,
        .namespace = "server",
        .client_name = "MetaWork",
        .client_version = "1",
        .timeout_ms = 1000,
        .configuration_fingerprint = [_]u8{0} ** 32,
    }}));
    try std.testing.expect(!transport.deinitialized);
    owner.deinit();
    try std.testing.expect(transport.deinitialized);
}
