//! Application-owned compatibility seam for System WebView drag regions.
//!
//! Native SDK 0.10.1 owns the window, chrome geometry, and platform drag loop.
//! Its Windows drag-region public API only covers GPU surfaces, not the startup
//! System WebView, so
//! MetaWork keeps this bounded seam until that Runtime API is available.
//! Renderer input is constrained to one top-band candidate plus bounded
//! exclusions; it never carries native window identity.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const startup_window = @import("system_webview_startup_window.zig");
const types = @import("system_webview_drag_region/types.zig");
pub const PointerOutcome = types.PointerOutcome;

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_drag_region/windows.zig"),
    .macos => @import("system_webview_drag_region/macos.zig"),
    else => struct {
        pub const live_pointer_drag = false;
        pub const chrome_top_override: ?f64 = null;
        pub const State = struct {};

        pub fn prepareStartup(_: *State, _: *const anyopaque, _: PointIsDraggableFn) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn captureStartupWindow(_: *State, _: startup_window.Binding) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn requirePlatform(_: native_sdk.platform.PlatformServices) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn bindRoot(_: *State) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn handlePointerDown(_: *State, _: native_sdk.platform.PlatformServices, _: native_sdk.platform.WindowId, _: f64, _: f64) !PointerOutcome {
            return .ignored;
        }

        pub fn resetPointerSequence(_: *State) void {}

        pub fn deinit(_: *State) void {}
    },
};

pub const max_regions: usize = 33;
const max_coordinate: f64 = 65_536;
const geometry_epsilon: f64 = 0.5;
const PointIsDraggableFn = types.PointIsDraggableFn;

pub const Region = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    exclusion: bool,
};

pub const Environment = struct {
    top: f64,
    left: f64,
    bottom: f64,
    right: f64,
    buttons_x: f64,
    buttons_y: f64,
    buttons_width: f64,
    buttons_height: f64,
    live_pointer_drag: bool,
};

pub const Capability = struct {
    window_id: native_sdk.platform.WindowId,
    platform_ready: bool = false,
    document_attached: bool = false,
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    platform: Platform.State = .{},

    pub fn init(window_id: native_sdk.platform.WindowId) Capability {
        std.debug.assert(window_id != 0);
        return .{ .window_id = window_id };
    }

    pub fn prepareStartup(self: *Capability) !void {
        try Platform.prepareStartup(&self.platform, self, platformPointIsDraggable);
    }

    pub fn captureStartupWindow(
        self: *Capability,
        binding: startup_window.Binding,
    ) !void {
        try Platform.captureStartupWindow(&self.platform, binding);
    }

    pub fn requirePlatform(
        _: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !void {
        if (services.window_chrome_fn == null)
            return error.SystemWebViewChromeUnavailable;
        try Platform.requirePlatform(services);
    }

    pub fn bindRoot(self: *Capability) void {
        Platform.bindRoot(&self.platform) catch {
            self.platform_ready = false;
            return;
        };
        self.platform_ready = true;
    }

    pub fn connect(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !Environment {
        try self.requirePlatform(services);
        self.resetPointerSequence();
        self.clearRegions();
        self.document_attached = self.platform_ready;
        return self.environment(services);
    }

    pub fn sync(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !Environment {
        self.resetPointerSequence();
        if (!validExtent(viewport_width) or !validExtent(viewport_height))
            return error.InvalidWindowChromeGeometry;
        const chrome = services.windowChrome(self.window_id);
        if (regions.len == 0) {
            self.clearRegions();
            return self.environmentFromChrome(chrome);
        }
        try self.replaceRegions(
            self.chromeTop(chrome),
            viewport_width,
            viewport_height,
            regions,
        );
        return self.environmentFromChrome(chrome);
    }

    pub fn handlePointerDown(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        x: f64,
        y: f64,
    ) !PointerOutcome {
        if (!self.document_attached or !validCoordinate(x) or !validCoordinate(y)) {
            self.resetPointerSequence();
            return error.InvalidWindowChromeGesture;
        }
        return Platform.handlePointerDown(
            &self.platform,
            services,
            self.window_id,
            x,
            y,
        );
    }

    pub fn resetPointerSequence(self: *Capability) void {
        Platform.resetPointerSequence(&self.platform);
    }

    pub fn current(
        self: *const Capability,
        services: native_sdk.platform.PlatformServices,
    ) Environment {
        return self.environment(services);
    }

    pub fn disconnect(self: *Capability) void {
        self.resetPointerSequence();
        self.document_attached = false;
        self.clearRegions();
    }

    pub fn deinit(self: *Capability) void {
        self.disconnect();
        self.platform_ready = false;
        Platform.deinit(&self.platform);
    }

    fn environment(
        self: *const Capability,
        services: native_sdk.platform.PlatformServices,
    ) Environment {
        return self.environmentFromChrome(services.windowChrome(self.window_id));
    }

    fn environmentFromChrome(
        self: *const Capability,
        chrome: native_sdk.platform.WindowChrome,
    ) Environment {
        return .{
            .top = self.chromeTop(chrome),
            .left = chrome.insets.left,
            .bottom = chrome.insets.bottom,
            .right = chrome.insets.right,
            .buttons_x = chrome.buttons.x,
            .buttons_y = chrome.buttons.y,
            .buttons_width = chrome.buttons.width,
            .buttons_height = chrome.buttons.height,
            .live_pointer_drag = Platform.live_pointer_drag and self.document_attached,
        };
    }

    fn chromeTop(
        _: *const Capability,
        chrome: native_sdk.platform.WindowChrome,
    ) f64 {
        return Platform.chrome_top_override orelse chrome.insets.top;
    }

    fn clearRegions(self: *Capability) void {
        self.region_count = 0;
    }

    fn replaceRegions(
        self: *Capability,
        chrome_top: f64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !void {
        try self.validateRegions(
            chrome_top,
            viewport_width,
            viewport_height,
            regions,
        );
        self.region_count = regions.len;
        @memcpy(self.regions[0..regions.len], regions);
    }

    fn validateRegions(
        _: *const Capability,
        chrome_top: f64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !void {
        if (regions.len > max_regions)
            return error.InvalidWindowChromeRegions;
        const candidate = regions[0];
        if (candidate.exclusion or
            !validRegion(candidate, viewport_width, viewport_height))
            return error.InvalidWindowChromeRegions;
        if (!validExtent(chrome_top) or
            candidate.y + candidate.height > chrome_top + geometry_epsilon)
            return error.WindowChromeRegionOutsideNativeBand;
        for (regions[1..]) |region| {
            if (!region.exclusion or
                !validRegion(region, viewport_width, viewport_height) or
                !contains(candidate, region))
                return error.InvalidWindowChromeRegions;
        }
    }

    fn pointIsDraggable(self: *const Capability, x: f64, y: f64) bool {
        if (!self.document_attached or self.region_count == 0 or
            !containsPoint(self.regions[0], x, y)) return false;
        for (self.regions[1..self.region_count]) |region|
            if (containsPoint(region, x, y)) return false;
        return true;
    }

    fn platformPointIsDraggable(
        context: *const anyopaque,
        x: f64,
        y: f64,
    ) bool {
        const self: *const Capability = @ptrCast(@alignCast(context));
        return self.pointIsDraggable(x, y);
    }
};

fn validCoordinate(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= max_coordinate;
}

fn validExtent(value: f64) bool {
    return validCoordinate(value) and value > 0;
}

fn validRegion(
    region: Region,
    viewport_width: f64,
    viewport_height: f64,
) bool {
    return validCoordinate(region.x) and validCoordinate(region.y) and
        validExtent(region.width) and validExtent(region.height) and
        region.x + region.width <= viewport_width + geometry_epsilon and
        region.y + region.height <= viewport_height + geometry_epsilon;
}

fn contains(outer: Region, inner: Region) bool {
    return inner.x + geometry_epsilon >= outer.x and
        inner.y + geometry_epsilon >= outer.y and
        inner.x + inner.width <= outer.x + outer.width + geometry_epsilon and
        inner.y + inner.height <= outer.y + outer.height + geometry_epsilon;
}

fn containsPoint(region: Region, x: f64, y: f64) bool {
    return x >= region.x and y >= region.y and
        x < region.x + region.width and y < region.y + region.height;
}

test "chrome regions stay inside one native top band" {
    var capability = Capability.init(1);
    const valid = [_]Region{
        .{ .x = 0, .y = 0, .width = 500, .height = 52, .exclusion = false },
        .{ .x = 12, .y = 8, .width = 40, .height = 36, .exclusion = true },
    };
    try capability.validateRegions(52, 800, 600, &valid);
    try std.testing.expect(capability.region_count == 0);

    var outside = valid;
    outside[0].height = 60;
    try std.testing.expectError(
        error.WindowChromeRegionOutsideNativeBand,
        capability.validateRegions(52, 800, 600, &outside),
    );
    var escaped = valid;
    escaped[1].x = 700;
    try std.testing.expectError(
        error.InvalidWindowChromeRegions,
        capability.validateRegions(52, 800, 600, &escaped),
    );
}

test "chrome hit testing only accepts candidate minus exclusions" {
    var capability = Capability.init(1);
    capability.document_attached = true;
    capability.region_count = 2;
    capability.regions[0] = .{ .x = 0, .y = 0, .width = 500, .height = 52, .exclusion = false };
    capability.regions[1] = .{ .x = 12, .y = 8, .width = 40, .height = 36, .exclusion = true };
    try std.testing.expect(capability.pointIsDraggable(200, 20));
    try std.testing.expect(!capability.pointIsDraggable(20, 20));
    try std.testing.expect(!capability.pointIsDraggable(700, 20));
}

test "invalid chrome geometry cannot partially replace live regions" {
    var capability = Capability.init(1);
    const valid = [_]Region{
        .{ .x = 0, .y = 0, .width = 500, .height = 52, .exclusion = false },
        .{ .x = 12, .y = 8, .width = 40, .height = 36, .exclusion = true },
    };
    try capability.replaceRegions(52, 800, 600, &valid);

    var invalid = valid;
    invalid[1].x = 700;
    try std.testing.expectError(
        error.InvalidWindowChromeRegions,
        capability.replaceRegions(52, 800, 600, &invalid),
    );
    try std.testing.expectEqual(@as(usize, valid.len), capability.region_count);
    capability.document_attached = true;
    try std.testing.expect(capability.pointIsDraggable(200, 20));
    try std.testing.expect(!capability.pointIsDraggable(20, 20));
}

test "disconnect clears document-owned regions without owning generation" {
    var capability = Capability.init(1);
    capability.document_attached = true;
    capability.region_count = 1;
    capability.disconnect();
    try std.testing.expect(!capability.document_attached);
    try std.testing.expectEqual(@as(usize, 0), capability.region_count);
}
