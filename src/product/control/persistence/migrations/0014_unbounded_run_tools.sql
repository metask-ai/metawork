-- Version history in which a Run keeps every Tool record: the per-Run
-- record count limit is gone. Builds that still enforce it must not read
-- or write such a store, so this adds no column and changes no constraint.
SELECT 1;
