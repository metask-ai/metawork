//! Dependency-free MCP Streamable HTTP request-header facts shared with
//! product configuration validation. Runtime transport behavior remains in
//! `http.zig`.

const std = @import("std");

pub const HeaderName = struct {
    pub const accept = "Accept";
    pub const content_type = "Content-Type";
    pub const protocol_version = "MCP-Protocol-Version";
    pub const session_id = "Mcp-Session-Id";
};

pub const reserved_request_header_names = [_][]const u8{
    HeaderName.accept,
    HeaderName.content_type,
    HeaderName.protocol_version,
    HeaderName.session_id,
};

pub fn isReservedRequestHeader(name: []const u8) bool {
    inline for (reserved_request_header_names) |reserved|
        if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    return false;
}
