-- Preserve the v1 Run/compact checkpoint group and all prior migration bytes.
-- A distinct approval union case keeps its exact u64 anchor relational; its
-- bounded payload follows the existing typed JSON convention. Ordinary ADD
-- COLUMN and triggers use the Storage migration capabilities already supported.
ALTER TABLE tasks ADD COLUMN approval_revision BLOB NOT NULL DEFAULT X'0000000000000001';
ALTER TABLE tasks ADD COLUMN checkpoint_approval_revision BLOB;
ALTER TABLE tasks ADD COLUMN checkpoint_approval_json TEXT;
CREATE TRIGGER task_approval_anchor_insert BEFORE INSERT ON tasks
WHEN typeof(NEW.approval_revision)<>'blob' OR length(NEW.approval_revision)<>8 OR NEW.approval_revision=X'0000000000000000' OR
    (NEW.checkpoint_approval_revision IS NULL)<>(NEW.checkpoint_approval_json IS NULL) OR
    (NEW.checkpoint_approval_revision IS NOT NULL AND
      (typeof(NEW.checkpoint_approval_revision)<>'blob' OR length(NEW.checkpoint_approval_revision)<>8 OR
       NEW.checkpoint_approval_revision=X'0000000000000000' OR NEW.checkpoint_approval_revision>NEW.approval_revision OR
       typeof(NEW.checkpoint_approval_json)<>'text' OR NOT json_valid(NEW.checkpoint_approval_json) OR
       NEW.checkpoint_generation IS NOT NULL))
BEGIN SELECT RAISE(ABORT,'invalid approval checkpoint anchor'); END;
CREATE TRIGGER task_approval_anchor_update BEFORE UPDATE ON tasks
WHEN typeof(NEW.approval_revision)<>'blob' OR length(NEW.approval_revision)<>8 OR NEW.approval_revision=X'0000000000000000' OR
    (NEW.checkpoint_approval_revision IS NULL)<>(NEW.checkpoint_approval_json IS NULL) OR
    (NEW.checkpoint_approval_revision IS NOT NULL AND
      (typeof(NEW.checkpoint_approval_revision)<>'blob' OR length(NEW.checkpoint_approval_revision)<>8 OR
       NEW.checkpoint_approval_revision=X'0000000000000000' OR NEW.checkpoint_approval_revision>NEW.approval_revision OR
       typeof(NEW.checkpoint_approval_json)<>'text' OR NOT json_valid(NEW.checkpoint_approval_json) OR
       NEW.checkpoint_generation IS NOT NULL))
BEGIN SELECT RAISE(ABORT,'invalid approval checkpoint anchor'); END;
