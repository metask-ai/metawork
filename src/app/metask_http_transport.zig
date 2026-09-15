const std = @import("std");
const oauth = @import("account_oauth");
const account_metask = @import("metask_client");
const metask_transport = @import("metask_transport");
const models_metask = @import("product_models_metask");

/// Application-owned HTTP execution shared by Account's narrow transport port
/// and the Models Metask provider transport leaf. Account owns OAuth and
/// identity request policy; Models owns catalog request policy. This adapter
/// only maps their request kinds to network effects.
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    const default_request_timeout: std.Io.Clock.Duration = .{
        .raw = .fromSeconds(30),
        .clock = .boot,
    };

    const FetchResult = union(enum) {
        completed: struct {
            status: u16,
            body_len: usize,
        },
        network_failed,
        response_too_large,
        protocol_failed,
    };

    const Outcome = union(enum) {
        fetch: FetchResult,
        deadline,
        cancelled,
    };

    pub fn accountTransport(self: *Adapter) account_metask.Transport {
        return .{
            .context = self,
            .perform_fn = performAccount,
        };
    }

    pub fn modelsTransport(self: *Adapter) metask_transport.Transport {
        return .{
            .context = self,
            .perform_fn = performModels,
        };
    }

    fn performAccount(
        context: *anyopaque,
        request: account_metask.Request,
        response_buffer: []u8,
    ) account_metask.TransportError!account_metask.Response {
        return perform(
            context,
            .{
                .kind = switch (request.kind) {
                    .exchange_code => .exchange_code,
                    .refresh_token => .refresh_token,
                    .current_user => .current_user,
                    .usage_dashboard => .usage_dashboard,
                    .usage_history => .usage_history,
                },
                .body = request.body,
                .bearer = request.bearer,
                .control = request.control,
                .usage_history_range = if (request.usage_history_range) |range| .{
                    .start_date = range.start_date,
                    .end_date = range.end_date,
                } else null,
            },
            response_buffer,
        );
    }

    fn performModels(
        context: *anyopaque,
        request: metask_transport.Request,
        response_buffer: []u8,
    ) metask_transport.TransportError!metask_transport.Response {
        return perform(context, request, response_buffer);
    }

    fn perform(
        context: *anyopaque,
        request: metask_transport.Request,
        response_buffer: []u8,
    ) metask_transport.TransportError!metask_transport.Response {
        const self: *Adapter = @ptrCast(@alignCast(context));
        const deadline = if (request.control) |control|
            control.deadline
        else
            std.Io.Clock.Timestamp.fromNow(
                self.io,
                default_request_timeout,
            );
        var outcome_storage: [3]Outcome = undefined;
        var selection = std.Io.Select(Outcome).init(
            self.io,
            &outcome_storage,
        );
        selection.async(
            .fetch,
            fetch,
            .{ self, request, response_buffer },
        );
        selection.async(
            .deadline,
            waitDeadline,
            .{ self.io, deadline },
        );
        if (request.control) |control| {
            selection.async(
                .cancelled,
                waitCancellation,
                .{control.cancellation},
            );
        }
        const outcome = selection.await() catch {
            selection.cancelDiscard();
            return error.NetworkFailed;
        };
        switch (outcome) {
            .fetch => |result| {
                selection.cancelDiscard();
                if (request.control) |control| {
                    if (control.cancellation.isCancelled())
                        return error.Cancelled;
                }
                return switch (result) {
                    .completed => |completed| .{
                        .status = completed.status,
                        .body = response_buffer[0..completed.body_len],
                    },
                    .network_failed => error.NetworkFailed,
                    .response_too_large => error.ResponseTooLarge,
                    .protocol_failed => error.ProtocolFailed,
                };
            },
            .deadline => {
                selection.cancelDiscard();
                return error.DeadlineExceeded;
            },
            .cancelled => {
                selection.cancelDiscard();
                return error.Cancelled;
            },
        }
    }

    fn fetch(
        self: *Adapter,
        request: metask_transport.Request,
        response_buffer: []u8,
    ) FetchResult {
        var response_writer = std.Io.Writer.fixed(response_buffer);
        var client: std.http.Client = .{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer client.deinit();

        var authorization_storage: [oauth.Limits.secret_bytes + "Bearer ".len]u8 =
            undefined;
        defer std.crypto.secureZero(u8, &authorization_storage);
        var authorization: []const u8 = "";
        if (request.bearer) |bearer| {
            if (bearer.len == 0 or
                bearer.len > oauth.Limits.secret_bytes or
                std.mem.indexOfAny(u8, bearer, "\r\n") != null)
                return .protocol_failed;
            @memcpy(authorization_storage[0.."Bearer ".len], "Bearer ");
            @memcpy(
                authorization_storage["Bearer ".len .. "Bearer ".len + bearer.len],
                bearer,
            );
            authorization = authorization_storage[0 .. "Bearer ".len + bearer.len];
        }

        var endpoint_storage: [256]u8 = undefined;
        const endpoint, const method: std.http.Method = switch (request.kind) {
            .exchange_code, .refresh_token => .{ oauth.token_url, .POST },
            .current_user => .{ account_metask.current_user_url, .GET },
            .usage_dashboard => .{ account_metask.usage_dashboard_url, .GET },
            .usage_history => blk: {
                const range = request.usage_history_range orelse
                    return .protocol_failed;
                const endpoint = std.fmt.bufPrint(
                    &endpoint_storage,
                    "{s}?start_date={s}&end_date={s}&granularity=day&timezone={s}",
                    .{
                        account_metask.usage_history_url,
                        range.start_date,
                        range.end_date,
                        account_metask.usage_history_timezone,
                    },
                ) catch return .protocol_failed;
                break :blk .{ endpoint, .GET };
            },
            .keys => .{ models_metask.api_keys_url, .GET },
            .models => .{ models_metask.models_url, .GET },
        };
        var headers: [4]std.http.Header = undefined;
        var header_count: usize = 0;
        headers[header_count] = .{
            .name = "Accept",
            .value = "application/json",
        };
        header_count += 1;
        if (method == .POST) {
            headers[header_count] = .{
                .name = "Content-Type",
                .value = "application/x-www-form-urlencoded",
            };
            header_count += 1;
        }
        if (method == .GET) {
            if (authorization.len == 0) return .protocol_failed;
            headers[header_count] = .{
                .name = "Authorization",
                .value = authorization,
            };
            header_count += 1;
        } else if (request.bearer != null) {
            return .protocol_failed;
        }
        const result = client.fetch(.{
            .location = .{ .url = endpoint },
            .method = method,
            .payload = if (method == .POST) request.body else null,
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
            .extra_headers = headers[0..header_count],
        }) catch |err| switch (err) {
            error.StreamTooLong => return .response_too_large,
            else => return .network_failed,
        };
        return .{ .completed = .{
            .status = @intFromEnum(result.status),
            .body_len = response_writer.buffered().len,
        } };
    }

    fn waitDeadline(
        io: std.Io,
        deadline: std.Io.Clock.Timestamp,
    ) void {
        deadline.wait(io) catch {};
    }

    fn waitCancellation(cancellation: *const metask_transport.Cancellation) void {
        cancellation.wait();
    }
};
