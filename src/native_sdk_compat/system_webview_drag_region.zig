//! Desktop Host compatibility seam for System WebView drag regions.
//!
//! Native SDK 0.8.0 owns the window, chrome geometry, controls, close policy,
//! and platform drag loop. It does not yet expose drag regions for the startup
//! System WebView, so MetaWork keeps this single-capability seam until the
//! Runtime API is available. Renderer input is constrained to one top-band
//! candidate plus bounded exclusions and never carries native window identity.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

const Platform = switch (builtin.os.tag) {
    .windows => @import("system_webview_drag_region/windows.zig"),
    .macos => @import("system_webview_drag_region/macos.zig"),
    else => struct {
        pub const live_pointer_drag = false;
        pub const State = struct {};

        pub fn prepareStartup(_: *State, _: *const anyopaque, _: PointIsDraggableFn) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn captureStartupWindow(_: *State, _: native_sdk.platform.WindowId) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn requirePlatform(_: native_sdk.platform.PlatformServices) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn install(_: *State, _: native_sdk.platform.PlatformServices, _: native_sdk.platform.WindowId) !void {
            return error.SystemWebViewChromeUnavailable;
        }

        pub fn beginLivePointerDrag(_: *State, _: native_sdk.platform.PlatformServices, _: native_sdk.platform.WindowId) !void {
            return error.UnsupportedWindowChromeGesture;
        }

        pub fn deinit(_: *State) void {}
    },
};

pub const max_regions: usize = 33;
const max_coordinate: f64 = 65_536;
const geometry_epsilon: f64 = 0.5;
const PointIsDraggableFn = *const fn (*const anyopaque, f64, f64) bool;

pub const Region = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    exclusion: bool,
};

pub const Environment = struct {
    generation: u64,
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
    generation: u64 = 0,
    connected: bool = false,
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

    pub fn captureStartupWindow(self: *Capability) !void {
        try Platform.captureStartupWindow(&self.platform, self.window_id);
    }

    pub fn requirePlatform(
        _: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !void {
        if (services.window_chrome_fn == null)
            return error.SystemWebViewChromeUnavailable;
        try Platform.requirePlatform(services);
    }

    pub fn connect(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !Environment {
        try self.requirePlatform(services);
        try self.installPlatformOrDisconnect(services);
        self.clearRegions();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.connected = true;
        return self.environment(services);
    }

    pub fn sync(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        generation: u64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !Environment {
        try self.requireCurrent(generation);
        if (!validExtent(viewport_width) or !validExtent(viewport_height))
            return error.InvalidWindowChromeGeometry;
        const chrome = services.windowChrome(self.window_id);
        if (regions.len == 0) {
            self.clearRegions();
            try self.installPlatformOrDisconnect(services);
            return environmentFromChrome(self.generation, chrome);
        }
        try self.replaceRegions(
            chrome.insets.top,
            viewport_width,
            viewport_height,
            regions,
        );
        try self.installPlatformOrDisconnect(services);
        return environmentFromChrome(self.generation, chrome);
    }

    pub fn beginLivePointerDrag(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        generation: u64,
        x: f64,
        y: f64,
    ) !Environment {
        try self.requireCurrent(generation);
        if (!validCoordinate(x) or !validCoordinate(y) or
            !self.pointIsDraggable(x, y))
            return error.InvalidWindowChromeGesture;
        try Platform.beginLivePointerDrag(
            &self.platform,
            services,
            self.window_id,
        );
        return self.environment(services);
    }

    pub fn disconnect(self: *Capability, generation: u64) !void {
        try self.requireCurrent(generation);
        self.connected = false;
        self.clearRegions();
    }

    pub fn deinit(self: *Capability) void {
        self.connected = false;
        self.clearRegions();
        Platform.deinit(&self.platform);
    }

    fn environment(
        self: *const Capability,
        services: native_sdk.platform.PlatformServices,
    ) Environment {
        return environmentFromChrome(
            self.generation,
            services.windowChrome(self.window_id),
        );
    }

    fn requireCurrent(self: *const Capability, generation: u64) !void {
        if (!self.connected or generation == 0 or generation != self.generation)
            return error.StaleWindowChromeDocument;
    }

    fn clearRegions(self: *Capability) void {
        self.region_count = 0;
    }

    fn installPlatformOrDisconnect(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !void {
        Platform.install(&self.platform, services, self.window_id) catch |err| {
            self.connected = false;
            self.clearRegions();
            Platform.deinit(&self.platform);
            return err;
        };
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
        if (!self.connected or self.region_count == 0 or
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

fn environmentFromChrome(
    generation: u64,
    chrome: native_sdk.platform.WindowChrome,
) Environment {
    return .{
        .generation = generation,
        .top = chrome.insets.top,
        .left = chrome.insets.left,
        .bottom = chrome.insets.bottom,
        .right = chrome.insets.right,
        .buttons_x = chrome.buttons.x,
        .buttons_y = chrome.buttons.y,
        .buttons_width = chrome.buttons.width,
        .buttons_height = chrome.buttons.height,
        .live_pointer_drag = Platform.live_pointer_drag,
    };
}

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
    capability.connected = true;
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
    capability.connected = true;
    try std.testing.expect(capability.pointIsDraggable(200, 20));
    try std.testing.expect(!capability.pointIsDraggable(20, 20));
}

test "chrome document generations fail closed" {
    var capability = Capability.init(1);
    capability.connected = true;
    capability.generation = 7;
    try capability.requireCurrent(7);
    try std.testing.expectError(
        error.StaleWindowChromeDocument,
        capability.requireCurrent(6),
    );
    try capability.disconnect(7);
    try std.testing.expectError(
        error.StaleWindowChromeDocument,
        capability.requireCurrent(7),
    );
}
