//! The facts an HTTP call returns. Pure data: no state, no effect, no `Io`,
//! and nothing that can start a request. Any owner may import this module;
//! only Application may import the engine that produces these facts.

/// Where a call stopped.
pub const Phase = enum { admission, resolve, connect, send, head, body, complete };

/// Why a call stopped. The data projection of the engine's error set, so a
/// domain owner can store and publish the reason without naming the engine.
pub const Cause = enum {
    invalid_request,
    dns_failed,
    connect_failed,
    tls_failed,
    write_failed,
    read_failed,
    invalid_response,
    response_too_large,
    out_of_memory,
    resource_limit,
    cancelled,
    deadline_exceeded,
};

/// Whether any byte of the request may have reached the server.
pub const Send = enum { not_sent, may_have_been_sent };

/// A failed call's typed facts: never a URL, host, address, header, body or
/// credential. The phase separates name resolution, connection, sending and
/// reading; the elapsed time separates a refused connection from a silent one.
pub const Diagnostic = struct {
    phase: Phase,
    cause: Cause,
    /// The whole call, from admission to the failure.
    elapsed_ms: u32,
};

comptime {
    // Structurally incapable of carrying text, so no caller can leak an
    // endpoint or a credential through a diagnostic.
    for (@typeInfo(Diagnostic).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .@"enum", .int => {},
        else => @compileError("Diagnostic fields must be typed facts, never text"),
    };
}
