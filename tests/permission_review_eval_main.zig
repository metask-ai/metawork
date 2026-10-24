const std = @import("std");
const agent = @import("metawork_agent");
const http = @import("completion_http_backend");
const suite = @import("permission_review_evaluation");

fn required(init: std.process.Init, name: []const u8) ![]const u8 {
    const value = init.environ_map.get(name) orelse return error.MissingEvaluationConfiguration;
    if (std.mem.trim(u8, value, " \r\n\t").len == 0) return error.MissingEvaluationConfiguration;
    return value;
}

pub fn main(init: std.process.Init) !void {
    const protocol = std.meta.stringToEnum(agent.Protocol, try required(init, "METAWORK_REVIEW_EVAL_PROTOCOL")) orelse return error.InvalidEvaluationProtocol;
    const model = try required(init, "METAWORK_REVIEW_EVAL_MODEL");
    const base_url = try required(init, "METAWORK_REVIEW_EVAL_BASE_URL");
    const credential = try required(init, "METAWORK_REVIEW_EVAL_API_KEY");
    const revision = try required(init, "METAWORK_REVIEW_EVAL_REVISION");
    const repeats = if (init.environ_map.get("METAWORK_REVIEW_EVAL_REPEATS")) |value|
        try std.fmt.parseInt(usize, value, 10)
    else
        3;
    if (repeats < 1 or repeats > 5) return error.InvalidEvaluationRepeats;
    var backend: http.Backend = .{ .allocator = init.gpa, .io = init.io };
    var observed = suite.ObservedTransport{ .inner = backend.transport() };
    const completion = try agent.Completion.init(init.gpa, observed.transport(), .{
        .target = .{ .provider_id = "permission-review-evaluation", .protocol = protocol, .base_url = base_url, .model = model },
        .credential = credential,
    });
    defer completion.deinit();
    try suite.runWithCompletion(init, completion, revision, protocol, model, repeats, null, &observed);
}
