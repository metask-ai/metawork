ALTER TABLE runs ADD COLUMN model_error_json TEXT;

CREATE TRIGGER runs_model_error_insert BEFORE INSERT ON runs
WHEN NEW.model_error_json IS NOT NULL AND CASE
    WHEN typeof(NEW.model_error_json)<>'text' OR NOT json_valid(NEW.model_error_json) THEN 1
    ELSE json_type(NEW.model_error_json)<>'object' END
BEGIN SELECT RAISE(ABORT, 'invalid run model error'); END;

CREATE TRIGGER runs_model_error_update BEFORE UPDATE OF model_error_json ON runs
WHEN NEW.model_error_json IS NOT NULL AND CASE
    WHEN typeof(NEW.model_error_json)<>'text' OR NOT json_valid(NEW.model_error_json) THEN 1
    ELSE json_type(NEW.model_error_json)<>'object' END
BEGIN SELECT RAISE(ABORT, 'invalid run model error'); END;
