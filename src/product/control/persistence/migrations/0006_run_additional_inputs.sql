-- Typed history owns message validation. Use the same ordinary ADD COLUMN and
-- trigger pattern as prior migrations, without SQLite's CHECK backfill pragma.
ALTER TABLE runs ADD COLUMN additional_inputs_json TEXT NOT NULL DEFAULT '[]';
CREATE TRIGGER run_additional_inputs_insert BEFORE INSERT ON runs
WHEN typeof(NEW.additional_inputs_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid additional inputs'); END;
CREATE TRIGGER run_additional_inputs_update BEFORE UPDATE OF additional_inputs_json ON runs
WHEN typeof(NEW.additional_inputs_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid additional inputs'); END;
