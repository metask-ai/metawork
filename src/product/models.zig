//! Public surface of the Product Models aggregate.
//!
//! The aggregate remains owned by Product Control. Consumers that only need
//! model values should import the pure Models contract instead of this root.

const runtime_module = @import("product_models_runtime");

pub const Runtime = runtime_module.Runtime;
pub const StartError = runtime_module.StartError;
pub const TestSupport = runtime_module.TestSupport;
pub const Expect = runtime_module.Expect;
pub const Lookup = runtime_module.Lookup;
pub const Present = runtime_module.Present;

test {
    _ = runtime_module;
}
