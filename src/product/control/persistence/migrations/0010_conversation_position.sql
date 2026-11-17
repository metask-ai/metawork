-- Edit-and-rerun needs a way back to one turn of the Conversation. AgentCore
-- numbers its messages over the full history, counting replies, tool results
-- and runtime text, none of which Product keeps records for, so the position
-- is read from `describe` when the input is submitted and stored here. No
-- arithmetic over `runs` can reproduce it.
--
-- `superseded_by_run_id` is the Run whose rewind took this one's turn out of
-- the Conversation. The turn stays in Product history, and so do the files and
-- other effects it produced; only the Conversation lost it.
--
-- A compaction raises `tasks.compact_boundary` without changing the message
-- count, so positions never shift; at or below the boundary a position can no
-- longer be named at all, which is what hides the edit entry.
--
-- The rewind position of an unstarted edited message lives inside
-- task_input_submissions.payload, which adds no column of its own.
ALTER TABLE runs ADD COLUMN conversation_position BLOB;
ALTER TABLE runs ADD COLUMN superseded_by_run_id BLOB;
ALTER TABLE tasks ADD COLUMN compact_boundary BLOB NOT NULL DEFAULT X'0000000000000000';

-- ADD COLUMN cannot carry a CHECK, so the domain of each new column is
-- enforced the way migration 2 enforced its own.
CREATE TRIGGER runs_conversation_position_insert BEFORE INSERT ON runs
WHEN (NEW.conversation_position IS NOT NULL AND
        (typeof(NEW.conversation_position)<>'blob' OR
         length(NEW.conversation_position)<>8 OR
         NEW.conversation_position=X'0000000000000000'))
    OR (NEW.superseded_by_run_id IS NOT NULL AND
        (typeof(NEW.superseded_by_run_id)<>'blob' OR
         length(NEW.superseded_by_run_id)<>8 OR
         NEW.superseded_by_run_id=X'0000000000000000'))
BEGIN SELECT RAISE(ABORT, 'invalid run conversation position'); END;

CREATE TRIGGER runs_conversation_position_update
BEFORE UPDATE OF conversation_position, superseded_by_run_id ON runs
WHEN (NEW.conversation_position IS NOT NULL AND
        (typeof(NEW.conversation_position)<>'blob' OR
         length(NEW.conversation_position)<>8 OR
         NEW.conversation_position=X'0000000000000000'))
    OR (NEW.superseded_by_run_id IS NOT NULL AND
        (typeof(NEW.superseded_by_run_id)<>'blob' OR
         length(NEW.superseded_by_run_id)<>8 OR
         NEW.superseded_by_run_id=X'0000000000000000'))
BEGIN SELECT RAISE(ABORT, 'invalid run conversation position'); END;

CREATE TRIGGER tasks_compact_boundary_insert BEFORE INSERT ON tasks
WHEN typeof(NEW.compact_boundary)<>'blob' OR length(NEW.compact_boundary)<>8
BEGIN SELECT RAISE(ABORT, 'invalid task compact boundary'); END;

CREATE TRIGGER tasks_compact_boundary_update BEFORE UPDATE OF compact_boundary ON tasks
WHEN typeof(NEW.compact_boundary)<>'blob' OR length(NEW.compact_boundary)<>8
BEGIN SELECT RAISE(ABORT, 'invalid task compact boundary'); END;

-- An edit has to rewind the Conversation, which only an idle Task can do, so
-- it stops the Run in the way. The user did not press Stop, and history says
-- which of the two happened.
ALTER TABLE runs DROP CONSTRAINT runs_cause_domain;
ALTER TABLE runs ADD CONSTRAINT runs_cause_domain CHECK(cause IS NULL OR cause IN ('user_cancel','approval_mode_change','edit_and_rerun','timeout','session_close','app_shutdown','event_pipeline_failure','event_payload_too_large','queue_capacity_failure','ui_pipeline_failure','permission_required','agent_failure','provider_failure','tool_failure','image_input_unsupported','stale_catalog','skill_not_found','invalid_skill_arguments','skill_policy_violation','skill_unavailable','resource_limit','dependency_contract_failure'));
