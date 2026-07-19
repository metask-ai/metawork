//! Compile-time automation composition selected by Native SDK build options.
//! The inactive implementation is never referenced by generated application
//! code, so fixture handlers, origins, workers, and diagnostics do not enter
//! the release artifact.

const build_options = @import("build_options");
const implementation = if (build_options.automation)
    @import("automation_enabled")
else
    @import("automation_disabled");

pub const enabled = implementation.enabled;
pub const handler_count = implementation.handler_count;
pub const Hooks = implementation.Hooks;
pub const Runtime = implementation.Runtime;
