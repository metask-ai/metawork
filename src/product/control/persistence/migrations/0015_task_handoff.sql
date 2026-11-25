ALTER TABLE tasks ADD COLUMN handoff_json TEXT;
ALTER TABLE tasks ADD COLUMN creation_receipt TEXT;
CREATE UNIQUE INDEX task_creation_receipts ON tasks(creation_receipt) WHERE creation_receipt IS NOT NULL;
CREATE TABLE handoff_store_identity (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    identity BLOB NOT NULL CHECK (length(identity) = 16)
) STRICT;
INSERT INTO handoff_store_identity VALUES(1, randomblob(16));
