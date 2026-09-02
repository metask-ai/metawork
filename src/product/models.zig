//! Public surface of the Product Models aggregate.
//!
//! The aggregate remains owned by Product Control. Consumers that only need
//! model values should import the pure Models contract instead of this root.

const contract_module = @import("metawork_product_models_contract");
const ports_module = @import("product_models_ports");
const runtime_module = @import("product_models_runtime");

pub const contract = contract_module;

pub const Runtime = runtime_module.Runtime;
pub const StartError = runtime_module.StartError;
pub const DefaultBinding = runtime_module.DefaultBinding;
pub const Preparation = runtime_module.Preparation;

pub const CredentialVault = ports_module.CredentialVault;
pub const credential_slot_prefix = ports_module.credential_slot_prefix;
pub const credential_slot_bytes = ports_module.credential_slot_bytes;
pub const validCredentialSlot = ports_module.validCredentialSlot;

test {
    _ = contract_module;
    _ = ports_module;
    _ = runtime_module;
}
