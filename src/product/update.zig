//! Product-owned update facts and policy. Network, timers and browser effects
//! are supplied by Application; this aggregate has no Account or Agent input.
const std = @import("std");

pub const manifest_url = "https://metawork.metask-ai.com/manifest.json";
pub const website_url = "https://metawork.metask-ai.com";
pub const Limits = struct {
    pub const manifest_bytes = 64 * 1024;
    pub const url_bytes = 4096;
    pub const version_bytes = 32;
    pub const json_depth = 8;
    pub const initial_delay_ms = 30_000;
    pub const interval_ms = 24 * 60 * 60 * 1000;
};

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        fn init(value: []const u8) error{InvalidManifest}!@This() {
            if (value.len == 0 or value.len > capacity) return error.InvalidManifest;
            var result: @This() = .{ .len = value.len };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Url = Text(Limits.url_bytes);
pub const Version = struct {
    numbers: [3]u32,
    text: Text(Limits.version_bytes),

    pub fn parse(value: []const u8) error{InvalidManifest}!Version {
        var result: Version = .{ .numbers = undefined, .text = try .init(value) };
        var parts = std.mem.splitScalar(u8, value, '.');
        for (&result.numbers) |*number| {
            const part = parts.next() orelse return error.InvalidManifest;
            if (part.len == 0 or (part.len > 1 and part[0] == '0')) return error.InvalidManifest;
            for (part) |byte| if (byte < '0' or byte > '9') return error.InvalidManifest;
            number.* = std.fmt.parseInt(u32, part, 10) catch return error.InvalidManifest;
        }
        if (parts.next() != null) return error.InvalidManifest;
        return result;
    }

    pub fn newerThan(self: Version, other: Version) bool {
        for (self.numbers, other.numbers) |a, b| {
            if (a != b) return a > b;
        }
        return false;
    }
};

pub const Target = struct {
    os: enum { macos, windows },
    arch: enum { arm64, x64 },
};

pub const Release = struct {
    version: Version,
    download: ?Url,
};

pub fn validDownloadUrl(value: []const u8) bool {
    const prefix = "https://downloads.metask-ai.com/";
    if (value.len <= prefix.len or value.len > Limits.url_bytes or
        !std.mem.startsWith(u8, value, prefix) or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return false;
    const uri = std.Uri.parse(value) catch return false;
    return uri.user == null and uri.password == null and uri.port == null and uri.fragment == null;
}

// Bound nesting before constructing the JSON tree. The JSON parser remains
// responsible for grammar, string escapes, Unicode and duplicate-key rejection.
fn boundedJson(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len > Limits.manifest_bytes) return false;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > Limits.json_depth) return false;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return !quoted and depth == 0;
}

pub fn parseManifest(allocator: std.mem.Allocator, bytes: []const u8, target: Target) error{InvalidManifest}!Release {
    if (!boundedJson(bytes)) return error.InvalidManifest;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = Limits.manifest_bytes,
    }) catch return error.InvalidManifest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidManifest;
    const root = parsed.value.object;
    const version = root.get("version") orelse return error.InvalidManifest;
    const downloads = root.get("downloads") orelse return error.InvalidManifest;
    if (version != .string or downloads != .object) return error.InvalidManifest;
    var release: Release = .{ .version = try Version.parse(version.string), .download = null };
    inline for (.{ "macos", "windows" }) |os| {
        if (downloads.object.get(os)) |platform| {
            if (platform != .object) return error.InvalidManifest;
            inline for (.{ "arm64", "x64" }) |arch| {
                if (platform.object.get(arch)) |url| {
                    if (url != .string or !validDownloadUrl(url.string)) return error.InvalidManifest;
                    if (std.mem.eql(u8, os, @tagName(target.os)) and std.mem.eql(u8, arch, @tagName(target.arch)))
                        release.download = try .init(url.string);
                }
            }
        }
    }
    return release;
}

pub const CheckState = enum { unchecked, checking, succeeded, failed, unavailable };
pub const CheckError = enum { none, network, timeout, invalid_manifest, unavailable };
pub const DownloadState = enum { idle, checking, opened, failed };
pub const DownloadError = enum { none, stale_version, missing_download, invalid_link, network, timeout, browser_unavailable, unavailable };
pub const HeadResult = enum { accessible, unsupported, invalid_link, network, timeout };
pub const CommandOutcome = enum { accepted, rejected, unavailable };

pub fn headResult(status: u16) HeadResult {
    return switch (status) {
        200...299 => .accessible,
        405, 501 => .unsupported,
        404, 410 => .invalid_link,
        else => .network,
    };
}

/// Borrowed, URL-free projection; serialize synchronously from the main thread.
pub const View = struct {
    checkState: CheckState,
    checkError: CheckError,
    latestVersion: ?[]const u8,
    updateAvailable: bool,
    downloadAvailable: bool,
    downloadState: DownloadState,
    downloadError: DownloadError,
};
pub const DownloadPreparation = struct { id: u64, version: Version, url: Url };
pub const CheckCompletion = union(enum) { release: Release, failed: CheckError };
pub const CheckPreparation = struct { id: u64, target: Target };

/// Application receives only update lifecycle capabilities, never the Control
/// owner or a mutable aggregate pointer. All callbacks execute on its thread.
pub const Management = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, u64, bool) void,
    next_check_fn: *const fn (*anyopaque) ?u64,
    begin_check_fn: *const fn (*anyopaque, u64) ?CheckPreparation,
    complete_check_fn: *const fn (*anyopaque, u64, CheckCompletion) void,
    begin_download_fn: *const fn (*anyopaque, []const u8) ?DownloadPreparation,
    complete_download_fn: *const fn (*anyopaque, u64, HeadResult) ?Url,
    browser_result_fn: *const fn (*anyopaque, bool) void,
    cancel_download_fn: *const fn (*anyopaque) void,
    stop_fn: *const fn (*anyopaque) void,
};

pub const Runtime = struct {
    current: Version,
    target: Target,
    available: bool = false,
    automatic: bool = false,
    next_check_ms: ?u64 = null,
    sequence: u64 = 0,
    check_id: ?u64 = null,
    download: ?DownloadPreparation = null,
    release: ?Release = null,
    check_state: CheckState = .unavailable,
    check_error: CheckError = .none,
    download_state: DownloadState = .idle,
    download_error: DownloadError = .none,

    pub fn init(current: []const u8, target: Target) error{InvalidManifest}!Runtime {
        return .{ .current = try Version.parse(current), .target = target };
    }

    pub fn start(self: *Runtime, now_ms: u64, automatic: bool) void {
        self.available = true;
        self.automatic = automatic;
        self.next_check_ms = if (automatic) now_ms +| Limits.initial_delay_ms else null;
        self.check_state = .unchecked;
        self.check_error = .none;
    }

    pub fn due(self: *const Runtime, now_ms: u64) bool {
        return self.available and self.check_id == null and if (self.next_check_ms) |at| now_ms >= at else false;
    }

    pub fn beginCheck(self: *Runtime, now_ms: u64) ?u64 {
        if (!self.available or self.check_id != null or self.sequence == std.math.maxInt(u64)) return null;
        self.sequence += 1;
        self.check_id = self.sequence;
        self.check_state = .checking;
        self.check_error = .none;
        if (self.automatic) self.next_check_ms = now_ms +| Limits.interval_ms;
        return self.sequence;
    }

    pub fn completeCheck(self: *Runtime, id: u64, completion: CheckCompletion) bool {
        if (!self.available or self.check_id != id) return false;
        self.check_id = null;
        switch (completion) {
            .release => |release| {
                self.release = release;
                self.check_state = .succeeded;
                self.check_error = .none;
                self.download_error = .none;
                if (self.download == null) self.download_state = .idle;
            },
            .failed => |failure| {
                std.debug.assert(failure != .none);
                self.check_state = .failed;
                self.check_error = failure;
            },
        }
        return true;
    }

    pub fn view(self: *const Runtime) View {
        const newer = if (self.release) |release| release.version.newerThan(self.current) else false;
        return .{
            .checkState = self.check_state,
            .checkError = self.check_error,
            .latestVersion = if (self.release) |*release| release.version.text.slice() else null,
            .updateAvailable = self.available and newer,
            .downloadAvailable = self.available and newer and self.release.?.download != null,
            .downloadState = self.download_state,
            .downloadError = self.download_error,
        };
    }

    pub fn beginDownload(self: *Runtime, expected_version: []const u8) ?DownloadPreparation {
        if (!self.available or self.download != null) return null;
        self.download_state = .failed;
        self.download_error = .stale_version;
        const release = self.release orelse return null;
        if (!release.version.newerThan(self.current) or !std.mem.eql(u8, expected_version, release.version.text.slice())) return null;
        self.download_error = .missing_download;
        const url = release.download orelse return null;
        self.download_error = .invalid_link;
        if (!validDownloadUrl(url.slice())) return null;
        self.download_error = .unavailable;
        if (self.sequence == std.math.maxInt(u64)) return null;
        self.sequence += 1;
        const preparation: DownloadPreparation = .{ .id = self.sequence, .version = release.version, .url = url };
        self.download = preparation;
        self.download_state = .checking;
        self.download_error = .none;
        return preparation;
    }

    /// Consumes a preflight exactly once. A returned URL authorizes only the
    /// current main-thread browser handoff, never a queued or replayed effect.
    pub fn completeDownload(self: *Runtime, id: u64, result: HeadResult) ?Url {
        const pending = self.download orelse return null;
        if (!self.available or pending.id != id) return null;
        self.download = null;
        self.download_state = .failed;
        self.download_error = .stale_version;
        const release = self.release orelse return null;
        const url = release.download orelse return null;
        if (!release.version.newerThan(self.current) or
            !std.mem.eql(u8, pending.version.text.slice(), release.version.text.slice()) or
            !std.mem.eql(u8, pending.url.slice(), url.slice())) return null;
        self.download_error = switch (result) {
            .accessible, .unsupported => .none,
            .invalid_link => .invalid_link,
            .network => .network,
            .timeout => .timeout,
        };
        if (self.download_error != .none) return null;
        // The caller must record the actual handler result before publishing.
        self.download_error = .browser_unavailable;
        return url;
    }

    pub fn browserResult(self: *Runtime, opened: bool) void {
        self.download_state = if (opened) .opened else .failed;
        self.download_error = if (opened) .none else .browser_unavailable;
    }

    pub fn cancelDownload(self: *Runtime) void {
        self.download = null;
        self.download_state = .idle;
        self.download_error = .none;
    }

    pub fn stop(self: *Runtime) void {
        self.available = false;
        self.next_check_ms = null;
        self.check_id = null;
        self.check_state = .unavailable;
        self.check_error = .none;
        self.cancelDownload();
    }
};

const fixture =
    \\{"version":"0.2.10","downloads":{"macos":{"arm64":"https://downloads.metask-ai.com/metawork/v0.2.10/arm.dmg?release=0.2.10","x64":"https://downloads.metask-ai.com/metawork/intel.dmg"},"windows":{"arm64":"https://downloads.metask-ai.com/metawork/arm.exe","x64":"https://downloads.metask-ai.com/metawork/x64.exe"}}}
;

test "updates compare canonical numeric versions without downgrade or prerelease" {
    try std.testing.expect((try Version.parse("0.2.10")).newerThan(try Version.parse("0.2.9")));
    try std.testing.expect(!(try Version.parse("0.2.7")).newerThan(try Version.parse("0.2.7")));
    try std.testing.expect(!(try Version.parse("0.1.99")).newerThan(try Version.parse("0.2.7")));
    for ([_][]const u8{ "", "0.2", "0.2.7.1", "00.2.7", "0.02.7", "0.2.7-beta", "0.2.7+build", "+0.2.7", "0.2.4294967296", "0.2. 7" }) |version|
        try std.testing.expectError(error.InvalidManifest, Version.parse(version));
}

test "updates manifest selects all four exact targets and preserves query bytes" {
    inline for (.{ .macos, .windows }) |os| inline for (.{ .arm64, .x64 }) |arch| {
        const target: Target = .{ .os = os, .arch = arch };
        const release = try parseManifest(std.testing.allocator, fixture, target);
        try std.testing.expectEqualStrings("0.2.10", release.version.text.slice());
        const expected = if (os == .macos) (if (arch == .arm64) "https://downloads.metask-ai.com/metawork/v0.2.10/arm.dmg?release=0.2.10" else "https://downloads.metask-ai.com/metawork/intel.dmg") else (if (arch == .arm64) "https://downloads.metask-ai.com/metawork/arm.exe" else "https://downloads.metask-ai.com/metawork/x64.exe");
        try std.testing.expectEqualStrings(expected, release.download.?.slice());
    };
}

test "updates reject malformed manifests including unknown duplicate keys and nesting" {
    const target: Target = .{ .os = .macos, .arch = .arm64 };
    for ([_][]const u8{
        "{}",                                                                    "[]",                                                     "{\"version\":7,\"downloads\":{}}",                                "{\"version\":\"0.2.8\"}",
        "{\"version\":\"0.2.8\",\"downloads\":[]}",                              "{\"version\":\"0.2.8\",\"downloads\":{\"macos\":null}}", "{\"version\":\"0.2.8\",\"downloads\":{\"macos\":{\"arm64\":7}}}", "{\"version\":\"0.2.8\",\"downloads\":{},\"extra\":1,\"extra\":2}",
        "{\"version\":\"0.2.8\",\"downloads\":{},\"extra\":[[[[[[[[[]]]]]]]]]}",
    }) |bytes| try std.testing.expectError(error.InvalidManifest, parseManifest(std.testing.allocator, bytes, target));
    const too_large = try std.testing.allocator.alloc(u8, Limits.manifest_bytes + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, ' ');
    try std.testing.expectError(error.InvalidManifest, parseManifest(std.testing.allocator, too_large, target));
    const release = try parseManifest(std.testing.allocator, "{\"version\":\"0.2.8\",\"downloads\":{},\"notes\":\"escaped \\\" { [\"}", target);
    try std.testing.expect(release.download == null);
}

test "updates official URL boundary rejects protocol host authority and injection" {
    try std.testing.expect(validDownloadUrl("https://downloads.metask-ai.com/a.exe?release=0.2.8"));
    for ([_][]const u8{
        "http://downloads.metask-ai.com/a",           "https://downloads.metask-ai.com.evil/a",
        "https://downloads.metask-ai.com@evil/a",     "https://user@downloads.metask-ai.com/a",
        "https://downloads.metask-ai.com:443/a",      "https://downloads.metask-ai.com/",
        "https://downloads.metask-ai.com/a#fragment", "https://downloads.metask-ai.com/a\nb",
        "https://downloads.metask-ai.com/a b",        "https://downloads.metask-ai.com/a\\b",
    }) |url| try std.testing.expect(!validDownloadUrl(url));
}

fn startedRuntime(automatic: bool) !Runtime {
    var runtime = try Runtime.init("0.2.7", .{ .os = .macos, .arch = .arm64 });
    runtime.start(1000, automatic);
    return runtime;
}

fn installFixture(runtime: *Runtime) !void {
    const id = runtime.beginCheck(40_000).?;
    try std.testing.expect(runtime.completeCheck(id, .{ .release = try parseManifest(std.testing.allocator, fixture, runtime.target) }));
}

test "updates coalesce checks and schedule from attempts without persistence or retry loops" {
    var runtime = try startedRuntime(true);
    try std.testing.expect(!runtime.due(30_999));
    try std.testing.expect(runtime.due(31_000));
    const id = runtime.beginCheck(31_000).?;
    try std.testing.expect(runtime.beginCheck(31_001) == null);
    try std.testing.expect(!runtime.due(32_000));
    try std.testing.expect(runtime.completeCheck(id, .{ .failed = .network }));
    try std.testing.expectEqual(CheckState.failed, runtime.view().checkState);
    try std.testing.expect(!runtime.view().updateAvailable);
    try std.testing.expect(!runtime.due(31_001));
    try std.testing.expect(runtime.due(31_000 + Limits.interval_ms));
    try std.testing.expect(runtime.beginCheck(32_000) != null); // explicit retry
    var manual = try startedRuntime(false);
    try std.testing.expect(!manual.due(std.math.maxInt(u64)));
    try std.testing.expect(manual.beginCheck(1) != null);
    const restarted = try startedRuntime(true);
    try std.testing.expect(restarted.due(31_000));
}

test "updates keep last confirmed release on failure and replace it on valid checks" {
    var runtime = try startedRuntime(false);
    try installFixture(&runtime);
    const id = runtime.beginCheck(50_000).?;
    try std.testing.expect(runtime.completeCheck(id, .{ .failed = .timeout }));
    try std.testing.expect(runtime.view().updateAvailable);
    try std.testing.expectEqual(CheckError.timeout, runtime.view().checkError);
    try std.testing.expectEqualStrings("0.2.10", runtime.view().latestVersion.?);
    const retry = runtime.beginCheck(60_000).?;
    try std.testing.expect(runtime.completeCheck(retry, .{ .release = .{ .version = try Version.parse("0.2.7"), .download = null } }));
    try std.testing.expect(!runtime.view().updateAvailable);
    try std.testing.expect(runtime.beginDownload("0.2.10") == null);
}

test "updates reject stale download intent and consume browser authorization once" {
    var runtime = try startedRuntime(false);
    try installFixture(&runtime);
    try std.testing.expect(runtime.beginDownload("0.2.9") == null);
    const pending = runtime.beginDownload("0.2.10").?;
    try std.testing.expect(runtime.beginDownload("0.2.10") == null);
    try std.testing.expect(runtime.completeDownload(pending.id + 1, .accessible) == null);
    try std.testing.expect(runtime.completeDownload(pending.id, .accessible) != null);
    try std.testing.expect(runtime.completeDownload(pending.id, .accessible) == null);
    runtime.browserResult(true);
    try std.testing.expectEqual(DownloadState.opened, runtime.view().downloadState);
    try std.testing.expect(runtime.view().updateAvailable); // handoff is not installation
    const changed = runtime.beginDownload("0.2.10").?;
    const check = runtime.beginCheck(60_000).?;
    try std.testing.expect(runtime.completeCheck(check, .{ .release = .{ .version = try Version.parse("0.2.11"), .download = null } }));
    try std.testing.expect(runtime.completeDownload(changed.id, .accessible) == null);
    try std.testing.expectEqual(DownloadError.stale_version, runtime.view().downloadError);
}

test "updates classify HEAD failures without mistaking unsupported HEAD for a dead link" {
    try std.testing.expectEqual(HeadResult.invalid_link, headResult(404));
    try std.testing.expectEqual(HeadResult.invalid_link, headResult(410));
    try std.testing.expectEqual(HeadResult.network, headResult(503));
    try std.testing.expectEqual(HeadResult.network, headResult(302));
    for ([_]u16{ 200, 204, 405, 501 }) |status| {
        var runtime = try startedRuntime(false);
        try installFixture(&runtime);
        const pending = runtime.beginDownload("0.2.10").?;
        try std.testing.expect(runtime.completeDownload(pending.id, headResult(status)) != null);
        runtime.browserResult(false);
        try std.testing.expectEqual(DownloadError.browser_unavailable, runtime.view().downloadError);
    }
    for ([_]HeadResult{ .invalid_link, .network, .timeout }) |failure| {
        var runtime = try startedRuntime(false);
        try installFixture(&runtime);
        const pending = runtime.beginDownload("0.2.10").?;
        try std.testing.expect(runtime.completeDownload(pending.id, failure) == null);
        try std.testing.expectEqual(DownloadState.failed, runtime.view().downloadState);
    }
}

test "updates disconnect and shutdown revoke pending browser effects and stale completions" {
    var runtime = try startedRuntime(true);
    try installFixture(&runtime);
    const pending = runtime.beginDownload("0.2.10").?;
    runtime.cancelDownload();
    try std.testing.expect(runtime.completeDownload(pending.id, .accessible) == null);
    const check = runtime.beginCheck(70_000).?;
    runtime.stop();
    try std.testing.expect(!runtime.completeCheck(check, .{ .failed = .network }));
    try std.testing.expect(runtime.beginCheck(80_000) == null);
    try std.testing.expect(runtime.beginDownload("0.2.10") == null);
    try std.testing.expect(!runtime.due(std.math.maxInt(u64)));
}

test "updates actual Host encoding matches the independent URL-free Renderer fixture" {
    var runtime = try startedRuntime(false);
    try installFixture(&runtime);
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, runtime.view(), .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(std.mem.trim(u8, @embedFile("update.fixture"), "\r\n"), json);
}
