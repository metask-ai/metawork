const std = @import("std");
const storage = @import("storage");

const migrations = [_]storage.sql.Migration{.{
    .version = 1,
    .name = "create storage conformance table",
    .sql =
    \\CREATE TABLE storage_conformance(
    \\  id INTEGER PRIMARY KEY,
    \\  integer_value INTEGER,
    \\  real_value REAL,
    \\  text_value TEXT,
    \\  blob_value BLOB,
    \\  nullable TEXT
    \\);
    ,
}};

pub fn main(init: std.process.Init) !void {
    const path = init.environ_map.get("METAWORK_STORAGE_CRASH_DB") orelse
        return error.MissingDatabasePath;
    const database = try storage.sqlite.Database.create(
        init.io,
        init.gpa,
        .{ .file = path },
        &migrations,
    );
    const outcome = database.capability().mutate(&.{.{
        .statement = .{
            .sql =
            \\INSERT INTO storage_conformance(id, blob_value)
            \\VALUES(77, zeroblob(1048576))
            ,
        },
        .expected_changes = .{ .exactly = 1 },
    }});
    if (outcome != .committed) return error.MutationNotCommitted;

    // Deliberately bypass Database.shutdown/destroy and every defer. The OS
    // tears down the process with a committed, uncheckpointed WAL.
    std.process.exit(86);
}
