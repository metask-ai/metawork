const native_sdk = @import("native_sdk");

pub const max_path_bytes = 16 * 1024;

const Grant = struct {
    token: u64,
    generation: u64,
    window_id: native_sdk.platform.WindowId,
    path: [max_path_bytes]u8,
    path_len: usize,

    fn canonicalPath(self: *const Grant) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Owns the single outstanding workspace trust capability. A capability is
/// bound to one Renderer window and connection generation, and every consume
/// attempt invalidates it so rejected tokens cannot be replayed.
pub const State = struct {
    next_token: u64 = 1,
    grant: ?Grant = null,

    pub fn invalidate(self: *State) void {
        self.grant = null;
    }

    pub fn issue(
        self: *State,
        generation: u64,
        window_id: native_sdk.platform.WindowId,
        canonical: []const u8,
    ) error{PathTooLong}!u64 {
        if (canonical.len > max_path_bytes) return error.PathTooLong;
        const token = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        var grant = Grant{
            .token = token,
            .generation = generation,
            .window_id = window_id,
            .path = undefined,
            .path_len = canonical.len,
        };
        @memcpy(grant.path[0..canonical.len], canonical);
        self.grant = grant;
        return token;
    }

    pub fn consume(
        self: *State,
        token: u64,
        window_id: native_sdk.platform.WindowId,
        generation: u64,
        output: []u8,
    ) error{ WorkspaceNotTrusted, NoSpaceLeft }![]const u8 {
        const grant = self.grant orelse return error.WorkspaceNotTrusted;
        self.grant = null;
        if (grant.token != token or grant.window_id != window_id or grant.generation != generation)
            return error.WorkspaceNotTrusted;
        if (grant.path_len > output.len) return error.NoSpaceLeft;
        @memcpy(output[0..grant.path_len], grant.canonicalPath());
        return output[0..grant.path_len];
    }
};
