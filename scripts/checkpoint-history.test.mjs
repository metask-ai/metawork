import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { readFixtureCheckpoint } from "./test-support/checkpoint-history.mjs";

function integer(value) {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64BE(BigInt(value));
  return bytes;
}

async function fixture(t) {
  const directory = await mkdtemp(
    join(tmpdir(), "metawork-checkpoint-reader-"),
  );
  const path = join(directory, "history.sqlite");
  const database = new DatabaseSync(path);
  t.after(async () => {
    database.close();
    await rm(directory, { recursive: true, force: true });
  });
  // This deliberately permissive input table tests the independent reader's
  // rejection; the real schema/writer is exercised by the desktop vertical.
  database.exec(`CREATE TABLE tasks (
    id BLOB PRIMARY KEY, checkpoint_anchor TEXT,
    checkpoint_generation BLOB, checkpoint_byte_size BLOB, checkpoint_digest BLOB,
    checkpoint_logical_session_id BLOB, checkpoint_last_run_id BLOB,
    checkpoint_last_compact_id BLOB, checkpoint_model BLOB,
    checkpoint_terminal_kind TEXT, checkpoint_terminal_id BLOB,
    checkpoint_binding_epoch BLOB
  )`);
  return { path, database };
}

test("checkpoint probe preserves full u64 metadata and never writes its input", async (t) => {
  const { path, database } = await fixture(t);
  const id = "18446744073709551615";
  database
    .prepare("INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    .run(
      integer(id),
      "available",
      integer(id),
      integer(123),
      Buffer.alloc(32, 0xab),
      Buffer.from("session"),
      integer(id),
      integer(0),
      Buffer.from("model"),
      "run",
      integer(id),
      integer(id),
    );
  const before = createHash("sha256")
    .update(await readFile(path))
    .digest("hex");
  const row = await readFixtureCheckpoint(path, id);
  assert.equal(row.id, id);
  assert.equal(row.checkpoint.blob.generation, id);
  assert.equal(row.checkpoint.blob.byte_size, "123");
  assert.equal(row.checkpoint.blob.digest, "ab".repeat(32));
  assert.equal(row.checkpoint.anchor.terminal.id, id);
  assert.equal(row.checkpoint.anchor.binding_epoch, id);
  assert.equal(row.checkpoint.session.logical_session_id, "session");
  assert.equal(
    createHash("sha256")
      .update(await readFile(path))
      .digest("hex"),
    before,
  );
  assert.equal(await readFixtureCheckpoint(path, "1"), null);
  await assert.rejects(readFixtureCheckpoint(path, "1 OR 1"), /identity/);
});

test("checkpoint probe rejects partial, malformed and invalid UTF-8 metadata", async (t) => {
  const { path, database } = await fixture(t);
  database
    .prepare("INSERT INTO tasks (id, checkpoint_anchor) VALUES (?, 'none')")
    .run(integer(1));
  assert.equal((await readFixtureCheckpoint(path, "1")).checkpoint, null);
  database
    .prepare("UPDATE tasks SET checkpoint_generation = ?")
    .run(integer(1));
  await assert.rejects(readFixtureCheckpoint(path, "1"), /Incomplete/);
  database
    .prepare(
      `UPDATE tasks SET checkpoint_anchor='available', checkpoint_generation=?,
    checkpoint_byte_size=?, checkpoint_digest=?, checkpoint_logical_session_id=?,
    checkpoint_last_run_id=?, checkpoint_last_compact_id=?, checkpoint_model=?,
    checkpoint_terminal_kind='run', checkpoint_terminal_id=?, checkpoint_binding_epoch=?`,
    )
    .run(
      Buffer.alloc(7),
      integer(1),
      Buffer.alloc(32),
      Buffer.from("session"),
      integer(1),
      integer(0),
      Buffer.from("model"),
      integer(1),
      integer(1),
    );
  await assert.rejects(readFixtureCheckpoint(path, "1"), /BLOB/);
  database
    .prepare("UPDATE tasks SET checkpoint_generation=?, checkpoint_model=?")
    .run(integer(1), Buffer.from([0xff]));
  await assert.rejects(
    readFixtureCheckpoint(path, "1"),
    /encoded data|encoding|UTF-8/,
  );
});

test("checkpoint probe does not create a missing database", async (t) => {
  const directory = await mkdtemp(
    join(tmpdir(), "metawork-checkpoint-absent-"),
  );
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "absent.sqlite");
  assert.equal(await readFixtureCheckpoint(path, "1"), null);
  await assert.rejects(readFile(path), { code: "ENOENT" });
});
