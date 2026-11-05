ALTER TABLE workspaces ADD COLUMN project_removed INTEGER NOT NULL DEFAULT 0;

CREATE TRIGGER workspaces_project_removed_insert BEFORE INSERT ON workspaces
WHEN typeof(NEW.project_removed)<>'integer' OR NEW.project_removed NOT IN (0,1)
BEGIN SELECT RAISE(ABORT, 'invalid project removal state'); END;

CREATE TRIGGER workspaces_project_removed_update BEFORE UPDATE OF project_removed ON workspaces
WHEN typeof(NEW.project_removed)<>'integer' OR NEW.project_removed NOT IN (0,1)
BEGIN SELECT RAISE(ABORT, 'invalid project removal state'); END;
