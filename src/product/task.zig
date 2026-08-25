//! Product Task state and supporting kernels.
//! Physical Product placement does not create an independent owner.

pub const persistence = @import("product_task_persistence");
pub const checkpoint_record = @import("product_task_checkpoint_record");
pub const checkpoint_store = @import("product_task_checkpoint_store");
pub const execution_binding = @import("product_task_execution_binding");
pub const agent_session = @import("product_task_agent_session");
pub const attachment = @import("product_task_attachment");
pub const runtime = @import("product_task_runtime");
pub const deletion = @import("product_task_deletion");
pub const recovery = @import("product_task_recovery");
pub const recovery_job = @import("product_task_recovery_job");
pub const state = @import("product_task_state");
pub const policy = @import("product_task_policy");
pub const execution = @import("product_task_execution");
pub const view = @import("product_task_view");
