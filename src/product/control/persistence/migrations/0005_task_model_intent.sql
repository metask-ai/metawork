-- Task selection is independent of the installed binding. Legacy rows have no
-- explicit intent; the typed Product codec owns the bounded record semantics.
ALTER TABLE tasks ADD COLUMN model_intent_json TEXT;
CREATE TRIGGER task_model_intent_insert BEFORE INSERT ON tasks
WHEN NEW.model_intent_json IS NOT NULL AND typeof(NEW.model_intent_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid Task model intent'); END;
CREATE TRIGGER task_model_intent_update BEFORE UPDATE OF model_intent_json ON tasks
WHEN NEW.model_intent_json IS NOT NULL AND typeof(NEW.model_intent_json)<>'text'
BEGIN SELECT RAISE(ABORT,'invalid Task model intent'); END;
