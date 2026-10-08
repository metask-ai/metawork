-- Nullable for pre-mode records; the legacy profile remains readable.
ALTER TABLE history_state ADD COLUMN default_approval_mode TEXT;
CREATE TRIGGER history_approval_mode_insert BEFORE INSERT ON history_state
WHEN NEW.default_approval_mode IS NOT NULL AND (typeof(NEW.default_approval_mode)<>'text' OR NEW.default_approval_mode NOT IN ('manual','auto_review','full_access'))
BEGIN SELECT RAISE(ABORT,'invalid approval mode'); END;
CREATE TRIGGER history_approval_mode_update BEFORE UPDATE OF default_approval_mode ON history_state
WHEN NEW.default_approval_mode IS NOT NULL AND (typeof(NEW.default_approval_mode)<>'text' OR NEW.default_approval_mode NOT IN ('manual','auto_review','full_access'))
BEGIN SELECT RAISE(ABORT,'invalid approval mode'); END;
