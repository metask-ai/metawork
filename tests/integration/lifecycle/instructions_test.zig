//! #34: the user's instruction files reach the Provider through canonical
//! Core. Product reads the files, the Agent installs them, Core renders them;
//! what the Provider received is read back from a local fixture's trace.
//! Only the remote provider and the credential vault are synthetic, and
//! nothing here opens a window.
const f = @import("lifecycle_fixture");
const std = f.std;
const control_api = f.product_control;
const task_api = f.product_task;
const state = task_api.testing.state_module;
const options = @import("instructions_options");

const allocator = std.testing.allocator;
const io = std.testing.io;
const sep = std.fs.path.sep_str;

const Provider = struct {
    child: std.process.Child,
    endpoint: []u8,

    fn start(trace: []const u8, global_path: []const u8) !Provider {
        var child = try std.process.spawn(io, .{
            .argv = &.{ options.node_path, options.fixture_path, trace, global_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(io);
        var storage: [1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &storage);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (try reader.interface.takeByte() != '\n') return error.InvalidFixtureHandshake;
        const ready = try std.json.parseFromSlice(struct { endpoint: []const u8 }, allocator, line, .{});
        defer ready.deinit();
        return .{ .child = child, .endpoint = try allocator.dupe(u8, ready.value.endpoint) };
    }

    fn deinit(self: *Provider) void {
        self.child.kill(io);
        allocator.free(self.endpoint);
    }
};

const Vault = struct {
    key: [64]u8 = @splat(0),
    len: usize = 0,
    fn generate(_: *anyopaque, slot: *[f.models_ports.credential_slot_bytes]u8) anyerror!void {
        @memcpy(slot, f.models_ports.credential_slot_prefix ++ ("1" ** 32));
    }
    fn store(context: *anyopaque, _: []const u8, value: []const u8) anyerror!void {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (value.len > self.key.len) return error.CapacityReached;
        @memcpy(self.key[0..value.len], value);
        self.len = value.len;
    }
    fn get(context: *anyopaque, _: []const u8, output: []u8) anyerror!?[]const u8 {
        const self: *Vault = @ptrCast(@alignCast(context));
        if (self.len == 0) return null;
        @memcpy(output[0..self.len], self.key[0..self.len]);
        return output[0..self.len];
    }
    fn delete(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *Vault = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, &self.key);
        self.len = 0;
    }
    fn capability(self: *Vault) f.models_ports.CredentialVault {
        return .{ .context = self, .generate_slot_fn = generate, .store_fn = store, .get_fn = get, .delete_fn = delete };
    }
};

fn configureProvider(control: *control_api.Runtime, endpoint: []const u8) !void {
    try std.testing.expect(control.createCustomProviderWithCredential("instructions-synthetic-key", .{
        .display_name = "Instructions local provider fixture",
        .protocol = .anthropic_messages,
        .normalized_base_url = endpoint,
    }).accepted);
    const created = control.modelsView().custom_providers[0];
    const id = try allocator.dupe(u8, created.id);
    defer allocator.free(id);
    const model = "claude-sonnet-4-20250514";
    try std.testing.expect(control.submitCustomProviderCommand(.{ .add_custom_model = .{
        .source_id = id,
        .expected_provider_revision = created.provider_revision,
        .expected_catalog_generation = created.catalog_generation,
        .model = .{ .id = model },
    } }).accepted);
    const configured = control.modelsView().custom_providers[0];
    const command: f.models_contract.CustomModelTestCommand = .{
        .model = .{ .source_id = id, .model_id = model },
        .expected_provider_revision = configured.provider_revision,
        .expected_source_generation = configured.source_generation,
        .expected_catalog_generation = configured.catalog_generation,
    };
    var candidate = switch (control.beginCustomProviderProbe(command)) {
        .ready => |value| value,
        .rejected => return error.FixtureProviderRejected,
    };
    candidate.deinit();
    try std.testing.expect(control.completeCustomModelTest(command, true).accepted);
    try std.testing.expect(control.custom_providers.rememberPreference(.{ .source_id = id, .model_id = model }).accepted);
}

/// One Product Control over canonical Core, a framed history, a checkpoint
/// store, and the fixture provider, all under one temporary directory.
const Rig = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,
    home: [:0]u8,
    workspace: [:0]u8,
    trace: []u8,
    provider: Provider,
    runtime: *f.lifecycle.Runtime,
    vault: Vault = .{},
    history: task_api.history.FileStore,
    typed_history: f.TypedHistory,
    checkpoints: task_api.checkpoint_store.FileStore,
    automatic_root: control_api.AutomaticWorkspaceRoot,
    control: control_api.Runtime,

    fn init(self: *Rig) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(io, "home" ++ sep ++ ".metawork");
        try self.tmp.dir.createDirPath(io, "workspace");
        try self.tmp.dir.createDirPath(io, "automatic");
        try self.tmp.dir.createDirPath(io, "store");
        self.root = try self.tmp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(self.root);
        self.home = try self.tmp.dir.realPathFileAlloc(io, "home", allocator);
        errdefer allocator.free(self.home);
        self.workspace = try self.tmp.dir.realPathFileAlloc(io, "workspace", allocator);
        errdefer allocator.free(self.workspace);
        self.trace = try std.fs.path.join(allocator, &.{ self.root, "trace.jsonl" });
        errdefer allocator.free(self.trace);
        const target_path = try std.fs.path.join(allocator, &.{ self.home, ".metawork", "AGENTS.md" });
        defer allocator.free(target_path);
        self.provider = try Provider.start(self.trace, target_path);
        errdefer self.provider.deinit();
        self.runtime = try f.lifecycle.Runtime.init(io, allocator, .{ .max_sessions = 2 });
        errdefer {
            self.runtime.shutdown() catch unreachable;
            self.runtime.deinit();
        }
        const store = try std.fs.path.join(allocator, &.{ self.root, "store" });
        defer allocator.free(store);
        self.history = try task_api.history.FileStore.init(io, store);
        errdefer self.history.deinit();
        self.typed_history = .{ .file_store = &self.history };
        errdefer self.typed_history.deinit();
        self.checkpoints = try task_api.checkpoint_store.FileStore.init(io, store);
        errdefer self.checkpoints.deinit();
        const automatic = try std.fs.path.join(allocator, &.{ self.root, "automatic" });
        defer allocator.free(automatic);
        self.automatic_root = try control_api.AutomaticWorkspaceRoot.open(io, allocator, automatic);
        errdefer self.automatic_root.deinit();
        var configuration = f.productControlConfiguration();
        configuration.directories.canonical_user_home = self.home;
        configuration.directories.testing_automatic_workspace_root = &self.automatic_root;
        configuration.completion_factory = .{ .create_fn = FixtureReviewer.create };
        configuration.task_persistence = self.typed_history.capability();
        configuration.checkpoint_store = .{ .file_store = &self.checkpoints };
        self.control = try control_api.Runtime.init(allocator, io, self.runtime.runtimePort(), .{
            .worker_count = 1,
            .queue_capacity = 2,
            .max_tasks = 2,
            .max_workspaces = 2,
            .max_runs_per_task = 5,
        }, configuration);
        errdefer self.control.deinit();
        try self.control.startCustomProviders(store, self.vault.capability());
        errdefer self.control.stopCustomProviders();
        try configureProvider(&self.control, self.provider.endpoint);
    }

    fn deinit(self: *Rig) void {
        self.control.stopCustomProviders();
        self.control.shutdownExecutor();
        self.control.deinit();
        self.automatic_root.deinit();
        self.checkpoints.deinit();
        self.typed_history.deinit();
        self.history.deinit();
        self.runtime.shutdown() catch unreachable;
        self.runtime.deinit();
        std.crypto.secureZero(u8, &self.vault.key);
        self.provider.deinit();
        allocator.free(self.trace);
        allocator.free(self.workspace);
        allocator.free(self.home);
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Rig, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    }

    fn turn(self: *Rig) !void {
        try self.control.drainAgentEvents();
        self.control.syncLifecycle();
    }

    /// Runs one turn to its terminal and returns what the Provider received.
    fn run(self: *Rig, task_id: u64, text: []const u8) !Request {
        const run_id = try f.runPreparedTask(&self.control, task_id, .{ .text = text });
        const task = self.control.testTask(task_id).?;
        for (0..20_000) |_| {
            try self.turn();
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        } else return error.RunDidNotSettle;
        const record = state.findRun(task.durable.runs, run_id).?;
        try std.testing.expectEqual(task_api.RunOutcome.completed, state.productTerminalFacts(record).?.outcome);
        return self.request(text);
    }

    fn probeMutation(self: *Rig, task_id: u64, text: []const u8, deny_manually: bool) !bool {
        const run_id = try f.runPreparedTask(&self.control, task_id, .{ .text = text });
        const task = self.control.testTask(task_id).?;
        var prompted = false;
        var answered: ?u64 = null;
        for (0..20_000) |_| {
            try self.turn();
            if (deny_manually and task.runtime.hasAttachedSession()) {
                var access = try task.runtime.acquireAccess();
                defer access.deinit();
                if (access.pendingUiObservation()) |pending| {
                    if (answered != pending.request_id) {
                        var request_bytes = try access.copyPendingUiRequest(allocator);
                        defer request_bytes.deinit();
                        var parsed_pending = try f.lifecycle.decodePermissionRequest(allocator, request_bytes.json);
                        defer parsed_pending.deinit();
                        const read = std.mem.eql(u8, parsed_pending.value().tool.name, "Read");
                        prompted = prompted or !read;
                        try self.control.respondUi(task_id, run_id, pending.request_id, .{ .permission = if (read) .allow_once else .deny_once });
                        answered = pending.request_id;
                    }
                }
            }
            if (task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) {
                const run_record = state.findRun(task.durable.runs, run_id).?;
                for (run_record.tools) |entry| if (entry) |tool| {
                    std.debug.print("global instructions probe tool={s} error={} result={s}\n", .{ tool.name, tool.is_error, tool.content });
                };
                if (run_record.permission_provenance) |permission| {
                    std.debug.print("global instructions probe permission source={s} decision={s}\n", .{ @tagName(permission.source), @tagName(permission.decision) });
                }
                return prompted;
            }
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        return error.RunDidNotSettle;
    }

    /// The last request whose latest user text carried `text`.
    fn request(self: *Rig, text: []const u8) !Request {
        const bytes = try self.tmp.dir.readFileAlloc(io, "trace.jsonl", allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var found: ?Request = null;
        errdefer if (found) |*value| value.deinit();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = try std.json.parseFromSlice(struct { kind: []const u8, system: []const u8 = "", user: []const u8 = "", type: ?[]const u8 = null, reason: ?[]const u8 = null }, allocator, line, .{});
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.kind, "request")) {
                std.debug.print("instructions fixture: {s}\n", .{line});
                return error.FixtureFailed;
            }
            if (std.mem.indexOf(u8, parsed.value.user, text) == null) continue;
            if (found) |*previous| previous.deinit();
            found = .{ .system = try allocator.dupe(u8, parsed.value.system) };
        }
        return found orelse error.RequestNotFound;
    }

    /// Closes the idle Session and restores the Task from its checkpoint.
    fn restore(self: *Rig, task_id: u64) !void {
        const task = self.control.testTask(task_id).?;
        try std.testing.expect(try control_api.TestSupport.retryTaskSessionClose(&self.control, task_id));
        for (0..20_000) |_| {
            try self.turn();
            if (task.runtime.attachment == .detached and task.runtime.close_thread == null) break;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        } else return error.DetachDidNotSettle;
        _ = try self.control.restoreTaskConversation(task_id, task.durable.binding_epoch);
        for (0..20_000) |_| {
            try self.turn();
            if (task.runtime.attached() != null and task.runtime.active_operation == .none and !task.runtime.worker_leases.hasLive()) break;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        } else return error.RestoreDidNotSettle;
    }
};

const Request = struct {
    system: []u8,

    fn deinit(self: *Request) void {
        allocator.free(self.system);
    }

    fn has(self: Request, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.system, needle) != null;
    }

    fn endsWith(self: Request, suffix: []const u8) bool {
        return std.mem.endsWith(u8, std.mem.trimEnd(u8, self.system, " \t\r\n"), suffix);
    }
};

const global_file = "home" ++ sep ++ ".metawork" ++ sep ++ "AGENTS.md";
const project_file = "workspace" ++ sep ++ "AGENTS.md";

const FixtureReviewer = struct {
    fn create(_: ?*anyopaque, a: std.mem.Allocator, binding: f.lifecycle.ModelBinding) anyerror!*f.lifecycle.Completion {
        return f.lifecycle.Completion.init(a, .{ .perform_fn = perform }, binding);
    }

    fn perform(_: ?*anyopaque, request: f.lifecycle.CompletionHttpRequest, _: *const f.lifecycle.CompletionCancellation, output: []u8) f.lifecycle.CompletionTransportError!f.lifecycle.CompletionTransportResponse {
        const is_review = std.mem.indexOf(u8, request.body, "allow_once") != null;
        var writer = std.Io.Writer.fixed(output);
        std.json.Stringify.value(.{
            .type = "message",
            .content = .{.{ .type = "text", .text = if (is_review) "{\"decision\":\"allow_once\",\"reason\":\"Fixture review approves the operation.\"}" else "Instruction fixture" }},
            .stop_reason = "end_turn",
            .usage = .{ .input_tokens = 1, .output_tokens = 1 },
        }, .{}, &writer) catch return error.ResponseTooLarge;
        return .{ .status = 200, .body = writer.buffered() };
    }
};

fn sourceLine(path_parts: []const []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, path_parts);
    defer allocator.free(path);
    return std.fmt.allocPrint(allocator, "Source: {s}\n", .{path});
}

test "the user's instruction files reach the Provider last, change between turns and come back after restore" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const task_id = try rig.control.createTask(.{ .workspace_root = rig.workspace, .trust = .explicitly_trusted }, try control_api.TestSupport.fixtureModelSelection(&rig.control));
    const global_source = try sourceLine(&.{ rig.home, ".metawork", "AGENTS.md" });
    defer allocator.free(global_source);
    const project_source = try sourceLine(&.{ rig.workspace, "AGENTS.md" });
    defer allocator.free(project_source);

    // A global file over the limit, with a three-byte character across it.
    const limit = f.lifecycle.max_instruction_text_bytes;
    const large = try allocator.alloc(u8, limit + 64);
    defer allocator.free(large);
    @memset(large, 'g');
    @memcpy(large[0.."GLOBAL-ONE ".len], "GLOBAL-ONE ");
    @memcpy(large[limit - 1 ..][0.."\xe4\xb8\xad".len], "\xe4\xb8\xad");
    @memcpy(large[large.len - "TAIL-NOT-SENT".len ..], "TAIL-NOT-SENT");
    try rig.write(global_file, large);
    try rig.write(project_file, "PROJECT-ONE Mention {{model}} only when asked.");

    var first = try rig.run(task_id, "Instruction turn one.");
    defer first.deinit();
    try std.testing.expect(first.has("Settings → Global instructions"));
    try std.testing.expect(first.has("# User instructions: global\n"));
    try std.testing.expect(first.has(global_source));
    try std.testing.expect(first.has(project_source));
    // Global before project, and the project text last of everything: the
    // two sections render after every kernel section.
    try std.testing.expect(std.mem.indexOf(u8, first.system, "# User instructions: global").? <
        std.mem.indexOf(u8, first.system, "# User instructions: project").?);
    try std.testing.expect(first.endsWith("PROJECT-ONE Mention {{model}} only when asked."));
    // Cut just before the character that crossed the limit, and said so.
    try std.testing.expect(first.has("gg\n\n[Truncated: this file exceeds 32 KiB; only its first 32767 bytes are included.]"));
    try std.testing.expect(!first.has("TAIL-NOT-SENT"));
    const task = rig.control.testTask(task_id).?;
    const first_use = task.durable.runs[0].?.instructions.?;
    try std.testing.expect(first_use.global.truncated);
    try std.testing.expectEqual(state.product_instructions.State.applied, first_use.project.?.state);

    // A changed file replaces the old text at the next turn.
    try rig.write(global_file, "GLOBAL-TWO Keep replies short.");
    var second = try rig.run(task_id, "Instruction turn two.");
    defer second.deinit();
    try std.testing.expect(second.has("GLOBAL-TWO Keep replies short."));
    try std.testing.expect(!second.has("GLOBAL-ONE"));
    try std.testing.expect(!second.has("[Truncated"));
    try std.testing.expect(second.endsWith("PROJECT-ONE Mention {{model}} only when asked."));

    // An unreadable project file stops nothing and costs only itself.
    try rig.write(project_file, "\xff\xfe not text");
    var third = try rig.run(task_id, "Instruction turn three.");
    defer third.deinit();
    try std.testing.expect(!third.has("# User instructions: project"));
    try std.testing.expect(third.endsWith("GLOBAL-TWO Keep replies short."));
    const third_use = task.durable.runs[2].?.instructions.?;
    try std.testing.expectEqual(state.product_instructions.State.applied, third_use.global.state);
    try std.testing.expectEqual(state.product_instructions.Unreadable.not_utf8, third_use.project.?.reason.?);

    // Restore installs only the base profile. With the files unchanged, the
    // next turn must install them again rather than trust the closed
    // Session's record.
    try rig.restore(task_id);
    var fourth = try rig.run(task_id, "Instruction turn four.");
    defer fourth.deinit();
    try std.testing.expect(fourth.has("Settings → Global instructions"));
    try std.testing.expect(fourth.endsWith("GLOBAL-TWO Keep replies short."));
    try std.testing.expect(!fourth.has("# User instructions: project"));

    // And a restored Session follows later changes: a missing global file,
    // which stops nothing either, and a readable project file again.
    try rig.tmp.dir.deleteFile(io, global_file);
    try rig.write(project_file, "PROJECT-TWO After restore.");
    var fifth = try rig.run(task_id, "Instruction turn five.");
    defer fifth.deinit();
    try std.testing.expect(fifth.has("~/.metawork/AGENTS.md"));
    try std.testing.expect(fifth.has("~/.claude"));
    try std.testing.expect(fifth.has("~/.codex"));
    try std.testing.expect(fifth.has("write them directly into `~/.metawork/AGENTS.md`"));
    try std.testing.expect(fifth.has("replace that whole section instead of appending another copy"));
    try std.testing.expect(!fifth.has("Save rules only when"));
    try std.testing.expect(!fifth.has("GLOBAL-TWO"));
    try std.testing.expect(!fifth.has("# User instructions: global"));
    try std.testing.expect(fifth.endsWith("PROJECT-TWO After restore."));
    const fifth_use = task.durable.runs[4].?.instructions.?;
    try std.testing.expectEqual(state.product_instructions.State.absent, fifth_use.global.state);
    try std.testing.expectEqual(state.product_instructions.State.applied, fifth_use.project.?.state);
}

test "an Automatic Workspace sends only the global file, even with an AGENTS.md at its root" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try rig.write(global_file, "GLOBAL-AUTOMATIC Keep replies short.");
    const task_id = try rig.control.createTaskForWorkspace(.automatic, null, try control_api.TestSupport.fixtureModelSelection(&rig.control), null, null, .{ .interactive = null });
    const root = rig.control.testTask(task_id).?.durable.workspace_root;
    const project = try std.fs.path.join(allocator, &.{ root, "AGENTS.md" });
    defer allocator.free(project);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = project, .data = "PROJECT-AUTOMATIC must not be sent." });
    var request = try rig.run(task_id, "Automatic instruction turn.");
    defer request.deinit();
    try std.testing.expect(request.endsWith("GLOBAL-AUTOMATIC Keep replies short."));
    try std.testing.expect(!request.has("# User instructions: project"));
    try std.testing.expect(!request.has("PROJECT-AUTOMATIC"));
    try std.testing.expect(rig.control.testTask(task_id).?.durable.runs[0].?.instructions.?.project == null);
}

test "ordinary tools on the global instructions path use the existing Core permission modes" {
    for ([_]control_api.ApprovalMode{ .manual, .auto_review, .full_access }) |mode| {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const task_id = try rig.control.createTask(.{
            .workspace_root = rig.workspace,
            .trust = .explicitly_trusted,
            .approval_mode = mode,
        }, try control_api.TestSupport.fixtureModelSelection(&rig.control));
        for ([_][]const u8{ "Write", "Edit", "Bash" }) |tool| {
            try rig.write(global_file, "initial");
            const prompt = try std.fmt.allocPrint(allocator, "Instructions boundary probe {s}.", .{tool});
            defer allocator.free(prompt);
            const prompted = try rig.probeMutation(task_id, prompt, mode != .auto_review);
            const bytes = try rig.tmp.dir.readFileAlloc(io, global_file, allocator, .limited(1024));
            defer allocator.free(bytes);
            std.debug.print("global instructions boundary mode={s} tool={s} prompted={} content={s}\n", .{ @tagName(mode), tool, prompted, bytes });
            const expected = try std.fmt.allocPrint(allocator, "ordinary {s}", .{tool});
            defer allocator.free(expected);
            if (mode == .manual) {
                try std.testing.expect(prompted);
                try std.testing.expectEqualStrings("initial", bytes);
            } else {
                try std.testing.expect(std.mem.eql(u8, bytes, "initial") or std.mem.eql(u8, bytes, expected));
            }
        }
    }
}
