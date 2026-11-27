//! Product Control's ordered history migrations. No runtime or I/O ownership.
const std = @import("std");
pub const sql = @import("metawork_storage_sql");

pub const migrations: []const sql.Migration = &.{
    .{ .version = 1, .name = "product_history", .sql = @embedFile("migrations/0001_task_history.sql") },
    .{ .version = 2, .name = "run_model_error", .sql = @embedFile("migrations/0002_run_model_error.sql") },
    .{ .version = 3, .name = "workspace_project_removal", .sql = @embedFile("migrations/0003_workspace_project_removal.sql") },
    .{ .version = 4, .name = "generated_video_references", .sql = @embedFile("migrations/0004_generated_video_references.sql") },
    .{ .version = 5, .name = "input_submission_failure", .sql = @embedFile("migrations/0005_input_submission_failure.sql") },
    .{ .version = 6, .name = "input_admission_failure_categories", .sql = @embedFile("migrations/0006_input_admission_failure_categories.sql") },
    .{ .version = 7, .name = "input_failure_history_domain", .sql = @embedFile("migrations/0007_input_failure_history_domain.sql") },
    .{ .version = 8, .name = "run_cause_approval_mode_change", .sql = @embedFile("migrations/0008_run_cause_approval_mode_change.sql") },
    .{ .version = 9, .name = "attachment_media_identity", .sql = @embedFile("migrations/0009_attachment_media_identity.sql") },
    .{ .version = 10, .name = "conversation_position", .sql = @embedFile("migrations/0010_conversation_position.sql") },
    .{ .version = 11, .name = "run_output_updates", .sql = @embedFile("migrations/0011_run_output_updates.sql") },
    .{ .version = 12, .name = "task_project_membership", .sql = @embedFile("migrations/0012_task_project_membership.sql") },
    .{ .version = 13, .name = "multimodal_skill_selection", .sql = @embedFile("migrations/0013_multimodal_skill_selection.sql") },
    .{ .version = 14, .name = "unbounded_run_tools", .sql = @embedFile("migrations/0014_unbounded_run_tools.sql") },
    .{ .version = 15, .name = "task_handoff", .sql = @embedFile("migrations/0015_task_handoff.sql") },
    .{ .version = 16, .name = "run_cause_account_logout", .sql = @embedFile("migrations/0016_run_cause_account_logout.sql") },
    .{ .version = 17, .name = "attachment_original_identity", .sql = @embedFile("migrations/0017_attachment_original_identity.sql") },
};

pub const codec = @import("codec.zig");
pub const repository = @import("repository.zig");

comptime {
    @setEvalBranchQuota(4_000_000);
    if (!sql.validMigrations(migrations)) @compileError("Invalid Product history migration list");
    for (migrations) |migration| {
        if (std.mem.indexOfScalar(u8, migration.sql, '\r') != null or
            std.mem.startsWith(u8, migration.sql, "\xef\xbb\xbf") or
            !std.unicode.utf8ValidateSlice(migration.sql))
            @compileError("History migrations must be UTF-8 without BOM, with LF line endings");
    }
}
