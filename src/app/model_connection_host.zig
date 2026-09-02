//! Application-owned Model Connection secure-capture sequence.
//!
//! Bridge supplies bounded, non-secret metadata. This owner captures the
//! credential through the native platform seam, submits it synchronously to
//! Models, and clears its only plaintext buffer on every terminal path.

const builtin = @import("builtin");
const std = @import("std");
const bridge = @import("metawork_bridge");
const models_contract = @import("metawork_product_models_contract");
const app_platform = @import("platform.zig");
const models_coordinator = @import("models_coordinator.zig");

const CaptureFn = *const fn (
    *anyopaque,
    []const u8,
    []const u8,
    []const u8,
    []const u8,
    []u8,
) ?app_platform.SecureInputResult;

const CreateFn = *const fn (
    *anyopaque,
    []const u8,
    models_contract.ModelConnectionSpec,
    []const u8,
    []const u8,
) models_contract.CommandResult;

pub const Host = struct {
    capture_context: *anyopaque,
    capture_available_fn: *const fn (*anyopaque) bool,
    capture_fn: CaptureFn,
    create_context: *anyopaque,
    create_fn: CreateFn,

    pub fn init(
        platform: *app_platform.Adapter,
        coordinator: *models_coordinator.Coordinator,
    ) Host {
        return .{
            .capture_context = platform,
            .capture_available_fn = platformCaptureAvailable,
            .capture_fn = platformCapture,
            .create_context = coordinator,
            .create_fn = coordinatorCreate,
        };
    }

    pub fn available(self: *const Host) bool {
        return builtin.os.tag == .windows and
            self.capture_available_fn(self.capture_context);
    }

    pub fn bridgeHost(self: *Host) ?bridge.ModelConnectionHost {
        if (!self.available()) return null;
        return .{
            .context = self,
            .create_fn = create,
        };
    }

    fn create(
        context: *anyopaque,
        spec: models_contract.ModelConnectionSpec,
        model_id: []const u8,
        model_display_name: []const u8,
    ) bridge.ModelConnectionCreateOutcome {
        const self: *Host = @ptrCast(@alignCast(context));
        var secret_storage: [models_contract.Limits.credential_bytes]u8 = undefined;
        return self.createWithStorage(
            spec,
            model_id,
            model_display_name,
            &secret_storage,
        );
    }

    fn createWithStorage(
        self: *Host,
        spec: models_contract.ModelConnectionSpec,
        model_id: []const u8,
        model_display_name: []const u8,
        secret_storage: []u8,
    ) bridge.ModelConnectionCreateOutcome {
        std.crypto.secureZero(u8, secret_storage);
        defer std.crypto.secureZero(u8, secret_storage);
        if (!self.available()) return .unavailable;
        const result = self.capture_fn(
            self.capture_context,
            "Add model connection",
            "Enter the API credential for this connection.",
            "Save connection",
            "Cancel",
            secret_storage,
        ) orelse return .unavailable;
        const captured = switch (result) {
            .submitted => |length| length,
            .cancelled => return .cancelled,
        };
        if (captured == 0 or captured > secret_storage.len)
            return .{ .submitted = .rejected(.invalid_connection) };
        return .{ .submitted = self.create_fn(
            self.create_context,
            secret_storage[0..captured],
            spec,
            model_id,
            model_display_name,
        ) };
    }
};

fn platformCaptureAvailable(context: *anyopaque) bool {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    return platform.supportsSecureInput();
}

fn platformCapture(
    context: *anyopaque,
    title: []const u8,
    message: []const u8,
    accept_label: []const u8,
    cancel_label: []const u8,
    output: []u8,
) ?app_platform.SecureInputResult {
    const platform: *app_platform.Adapter = @ptrCast(@alignCast(context));
    return platform.captureSecureInput(
        title,
        message,
        accept_label,
        cancel_label,
        output,
    );
}

fn coordinatorCreate(
    context: *anyopaque,
    secret: []const u8,
    spec: models_contract.ModelConnectionSpec,
    model_id: []const u8,
    model_display_name: []const u8,
) models_contract.CommandResult {
    const coordinator: *models_coordinator.Coordinator = @ptrCast(@alignCast(context));
    return coordinator.createWithCapturedCredential(
        secret,
        spec,
        model_id,
        model_display_name,
    );
}

const TestContext = struct {
    capture: enum { submitted, cancelled, unavailable, invalid_length } = .submitted,
    reject_create: bool = false,
    create_called: bool = false,
    observed_secret: [16]u8 = @splat(0),
    observed_secret_len: usize = 0,

    fn captureAvailable(context: *anyopaque) bool {
        const self: *TestContext = @ptrCast(@alignCast(context));
        return self.capture != .unavailable;
    }

    fn captureSecret(
        context: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        output: []u8,
    ) ?app_platform.SecureInputResult {
        const self: *TestContext = @ptrCast(@alignCast(context));
        return switch (self.capture) {
            .submitted => submitted: {
                @memcpy(output[0..6], "secret");
                break :submitted .{ .submitted = 6 };
            },
            .cancelled => .cancelled,
            .unavailable => null,
            .invalid_length => .{ .submitted = output.len + 1 },
        };
    }

    fn createConnection(
        context: *anyopaque,
        secret: []const u8,
        _: models_contract.ModelConnectionSpec,
        _: []const u8,
        _: []const u8,
    ) models_contract.CommandResult {
        const self: *TestContext = @ptrCast(@alignCast(context));
        self.create_called = true;
        self.observed_secret_len = secret.len;
        @memcpy(self.observed_secret[0..secret.len], secret);
        return if (self.reject_create)
            .rejected(.persistence_unavailable)
        else
            .acceptedResult();
    }

    fn host(self: *TestContext) Host {
        return .{
            .capture_context = self,
            .capture_available_fn = captureAvailable,
            .capture_fn = captureSecret,
            .create_context = self,
            .create_fn = createConnection,
        };
    }
};

const test_spec: models_contract.ModelConnectionSpec = .{
    .display_name = "Local",
    .protocol = .openai_chat_completions,
    .normalized_base_url = "http://127.0.0.1:8080/v1",
};

test "Model Connection host clears captured plaintext after submission" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var context: TestContext = .{};
    var host = context.host();
    var storage: [32]u8 = @splat(0xa5);
    const result = host.createWithStorage(
        test_spec,
        "model",
        "Model",
        &storage,
    );
    try std.testing.expect(result == .submitted);
    try std.testing.expect(result.submitted.accepted);
    try std.testing.expect(context.create_called);
    try std.testing.expectEqualStrings(
        "secret",
        context.observed_secret[0..context.observed_secret_len],
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** storage.len), &storage);
}

test "Model Connection host clears capture on cancellation and unavailability" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var context: TestContext = .{ .capture = .cancelled };
    var host = context.host();
    var storage: [32]u8 = @splat(0xa5);
    try std.testing.expect(host.createWithStorage(
        test_spec,
        "model",
        "Model",
        &storage,
    ) == .cancelled);
    try std.testing.expect(!context.create_called);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** storage.len), &storage);

    context.capture = .unavailable;
    @memset(&storage, 0xa5);
    try std.testing.expect(host.createWithStorage(
        test_spec,
        "model",
        "Model",
        &storage,
    ) == .unavailable);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** storage.len), &storage);

    context.capture = .invalid_length;
    @memset(&storage, 0xa5);
    const invalid = host.createWithStorage(
        test_spec,
        "model",
        "Model",
        &storage,
    );
    try std.testing.expect(invalid == .submitted);
    try std.testing.expect(!invalid.submitted.accepted);
    try std.testing.expect(!context.create_called);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** storage.len), &storage);
}

test "Model Connection host clears plaintext after Models rejects create" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var context: TestContext = .{ .reject_create = true };
    var host = context.host();
    var storage: [32]u8 = @splat(0xa5);
    const result = host.createWithStorage(
        test_spec,
        "model",
        "Model",
        &storage,
    );
    try std.testing.expect(result == .submitted);
    try std.testing.expect(!result.submitted.accepted);
    try std.testing.expect(context.create_called);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** storage.len), &storage);
}
