ALTER TABLE tasks ADD COLUMN project_id BLOB REFERENCES workspaces(id) DEFERRABLE INITIALLY DEFERRED;

UPDATE tasks SET project_id=workspace_id
WHERE workspace_id IN (SELECT id FROM workspaces WHERE kind='manual');

CREATE TRIGGER tasks_project_id_insert BEFORE INSERT ON tasks
WHEN NEW.project_id IS NOT NULL AND
 (typeof(NEW.project_id)<>'blob' OR length(NEW.project_id)<>8 OR NEW.project_id=X'0000000000000000')
BEGIN SELECT RAISE(ABORT, 'invalid project identity'); END;

CREATE TRIGGER tasks_project_id_update BEFORE UPDATE OF project_id ON tasks
WHEN NEW.project_id IS NOT NULL AND
 (typeof(NEW.project_id)<>'blob' OR length(NEW.project_id)<>8 OR NEW.project_id=X'0000000000000000')
BEGIN SELECT RAISE(ABORT, 'invalid project identity'); END;

CREATE TABLE project_workspace_copy AS
SELECT id,epoch,kind,visible,recent_order,canonical_root,display_name,
 CASE WHEN kind='manual' AND visible=1 AND project_removed=0 THEN 1 ELSE 0 END AS project_entry
FROM workspaces;
DROP TABLE workspaces;
CREATE TABLE workspaces (
    id BLOB NOT NULL,
    epoch BLOB NOT NULL,
    kind TEXT NOT NULL,
    visible INTEGER NOT NULL,
    recent_order BLOB NOT NULL,
    canonical_root BLOB NOT NULL,
    display_name BLOB NOT NULL,
    project_entry INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(id),
    CONSTRAINT workspaces_id_type CHECK(typeof(id)='blob'),
    CONSTRAINT workspaces_id_length CHECK(length(id)=8),
    CONSTRAINT workspaces_id_domain CHECK(id<>X'0000000000000000'),
    CONSTRAINT workspaces_epoch_type CHECK(typeof(epoch)='blob'),
    CONSTRAINT workspaces_epoch_length CHECK(length(epoch)=8),
    CONSTRAINT workspaces_epoch_domain CHECK(epoch<>X'0000000000000000'),
    CONSTRAINT workspaces_kind_type CHECK(typeof(kind)='text'),
    CONSTRAINT workspaces_kind_domain CHECK(kind IN ('manual','automatic')),
    CONSTRAINT workspaces_canonical_root_type CHECK(typeof(canonical_root)='blob'),
    CONSTRAINT workspaces_canonical_root_length CHECK(length(canonical_root)>0),
    CONSTRAINT workspaces_display_name_type CHECK(typeof(display_name)='blob'),
    CONSTRAINT workspaces_display_name_length CHECK(length(display_name)>0),
    CONSTRAINT workspaces_visible_type CHECK(typeof(visible)='integer'),
    CONSTRAINT workspaces_visible_domain CHECK(visible IN (0,1)),
    CONSTRAINT workspaces_recent_order_type CHECK(typeof(recent_order)='blob'),
    CONSTRAINT workspaces_recent_order_length CHECK(length(recent_order)=8)
);
INSERT INTO workspaces(id,epoch,kind,visible,recent_order,canonical_root,display_name,project_entry)
SELECT id,epoch,kind,visible,recent_order,canonical_root,display_name,project_entry FROM project_workspace_copy;
DROP TABLE project_workspace_copy;
CREATE UNIQUE INDEX workspaces_canonical_root_unique ON workspaces(canonical_root);

CREATE TRIGGER workspaces_project_entry_insert BEFORE INSERT ON workspaces
WHEN typeof(NEW.project_entry)<>'integer' OR NEW.project_entry NOT IN (0,1)
 OR (NEW.project_entry=1 AND (NEW.kind<>'manual' OR NEW.visible<>1))
BEGIN SELECT RAISE(ABORT, 'invalid project entry'); END;

CREATE TRIGGER workspaces_project_entry_update BEFORE UPDATE OF project_entry,visible,kind ON workspaces
WHEN typeof(NEW.project_entry)<>'integer' OR NEW.project_entry NOT IN (0,1)
 OR (NEW.project_entry=1 AND (NEW.kind<>'manual' OR NEW.visible<>1))
BEGIN SELECT RAISE(ABORT, 'invalid project entry'); END;
