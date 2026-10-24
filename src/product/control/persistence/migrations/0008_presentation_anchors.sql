-- Product owns anchor semantics; SQL preserves the typed Task header.
ALTER TABLE tasks ADD COLUMN presentation_format INTEGER;
ALTER TABLE tasks ADD COLUMN next_presentation_order BLOB;
CREATE TRIGGER task_presentation_insert BEFORE INSERT ON tasks
WHEN ((NEW.presentation_format IS NULL AND NEW.next_presentation_order IS NULL) OR
 (NEW.presentation_format=1 AND typeof(NEW.next_presentation_order)='blob' AND length(NEW.next_presentation_order)=8)) IS NOT TRUE
BEGIN SELECT RAISE(ABORT,'invalid presentation header'); END;
CREATE TRIGGER task_presentation_update BEFORE UPDATE OF presentation_format,next_presentation_order ON tasks
WHEN ((NEW.presentation_format IS NULL AND NEW.next_presentation_order IS NULL) OR
 (NEW.presentation_format=1 AND typeof(NEW.next_presentation_order)='blob' AND length(NEW.next_presentation_order)=8)) IS NOT TRUE
BEGIN SELECT RAISE(ABORT,'invalid presentation header'); END;
