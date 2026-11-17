//! The Agent's contract surface: declarations, limits and codecs that cross
//! the Product boundary, with no path to the AgentCore ABI entry point.
//!
//! Everything reachable from here is pure data or a pure codec. None of it
//! calls `metask_agentcore_get_api`, so no compilation that stops at this
//! module needs the AgentCore static archive on its link line. The Session and
//! Runtime implementations that do reach the entry point live in
//! `agent_session` and import this module; a value decoded here therefore
//! keeps one type across both sides of that split.
//!
//! The file namespaces below exist so the implementation can keep naming these
//! declarations exactly as it did when they were its own files. Product-facing
//! flat re-exports stay in `src/agent.zig`.

pub const control = @import("session/control.zig");
pub const surface = @import("session/surface.zig");
pub const wire = @import("session/wire.zig");
pub const multimodal = @import("session/multimodal.zig");
pub const model_error = @import("session/model_error.zig");
pub const capabilities = @import("capabilities.zig");
pub const image_generation = @import("image_generation.zig");
pub const generate_image = @import("generate_image.zig");
pub const generate_video = @import("generate_video.zig");
pub const mcp_install = @import("mcp_install.zig");

test {
    _ = control;
    _ = surface;
    _ = wire;
    _ = multimodal;
    _ = model_error;
    _ = capabilities;
    _ = image_generation;
    _ = generate_image;
    _ = generate_video;
    _ = mcp_install;
}
