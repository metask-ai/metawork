//! Pure Task-owned wire structure for the approval-result pilot.
const encoding = @import("product_view_encoding");

pub const ApprovalFailureReason = enum {
    cancelled,
    busy,
    budget_required,
    mode_update_failed,
    checkpoint_failed,
    persistence_failed,
    outcome_unknown,
    recovery_failed,
    dependency_contract,
};
pub const ApprovalOutcome = enum { completed, failed };

pub const ApprovalResult = struct {
    revision: encoding.PositiveId,
    outcome: ApprovalOutcome,
    reason: ?ApprovalFailureReason,
};
