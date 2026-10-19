-- Only safe presentation and correlation are stored. Execution payloads and
-- runtime failure reasons remain owned by Task memory.
ALTER TABLE tasks ADD COLUMN input_submissions_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE runs ADD COLUMN submission_json TEXT;
CREATE TRIGGER task_input_submissions_insert BEFORE INSERT ON tasks
WHEN typeof(NEW.input_submissions_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid input submissions'); END;
CREATE TRIGGER task_input_submissions_update BEFORE UPDATE OF input_submissions_json ON tasks
WHEN typeof(NEW.input_submissions_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid input submissions'); END;
CREATE TRIGGER run_submission_insert BEFORE INSERT ON runs
WHEN NEW.submission_json IS NOT NULL AND typeof(NEW.submission_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid input submission'); END;
CREATE TRIGGER run_submission_update BEFORE UPDATE OF submission_json ON runs
WHEN NEW.submission_json IS NOT NULL AND typeof(NEW.submission_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid input submission'); END;
