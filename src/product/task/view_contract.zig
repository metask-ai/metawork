//! Pure Task-owned contract types, with no Task state behind them.
const encoding = @import("product_view_encoding");

/// The one identity a message has, from acceptance through the Run that takes
/// it and across a restart: the submission it was accepted with, or its Run
/// when nothing accepted it first. A Run that took a submission is not a second
/// name for the same message.
pub const MessageIdentity = union(enum) { submission: []const u8, run: u64 };

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
