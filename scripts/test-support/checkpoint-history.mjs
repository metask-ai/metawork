// Verification-only reader for isolated desktop fixtures. Product's canonical
// column and u64 encoding contract is in control/persistence/migrations and codec.
import { stat } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";

const checkpointColumns = [
  "checkpoint_generation",
  "checkpoint_byte_size",
  "checkpoint_digest",
  "checkpoint_logical_session_id",
  "checkpoint_last_run_id",
  "checkpoint_last_compact_id",
  "checkpoint_model",
  "checkpoint_terminal_kind",
  "checkpoint_terminal_id",
  "checkpoint_binding_epoch",
];

function blob(value, length) {
  if (
    !(value instanceof Uint8Array) ||
    (length !== undefined && value.length !== length)
  )
    throw new Error("Invalid checkpoint SQL BLOB");
  return Buffer.from(value);
}
function u64(value) {
  return blob(value, 8).readBigUInt64BE().toString();
}
function text(value) {
  return new TextDecoder("utf-8", { fatal: true }).decode(blob(value));
}

export async function readFixtureCheckpoint(historyPath, taskId) {
  if (!/^[1-9][0-9]*$/.test(taskId))
    throw new Error("Invalid checkpoint Task identity");
  const id = Buffer.alloc(8);
  id.writeBigUInt64BE(BigInt(taskId));
  try {
    await stat(historyPath);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  const database = new DatabaseSync(historyPath, { readOnly: true });
  try {
    const row = database
      .prepare(
        `SELECT id, checkpoint_anchor, ${checkpointColumns.join(", ")} FROM tasks WHERE id = ?`,
      )
      .get(id);
    if (!row) return null;
    if (
      !["none", "available", "blob_missing", "blob_mismatch"].includes(
        row.checkpoint_anchor,
      )
    )
      throw new Error("Invalid checkpoint anchor");
    const empty = checkpointColumns.every((key) => row[key] === null);
    if (!empty && checkpointColumns.some((key) => row[key] === null))
      throw new Error("Incomplete checkpoint SQL field group");
    return {
      id: u64(row.id),
      checkpointAnchor: row.checkpoint_anchor,
      checkpoint: empty
        ? null
        : {
            blob: {
              generation: u64(row.checkpoint_generation),
              byte_size: u64(row.checkpoint_byte_size),
              digest: blob(row.checkpoint_digest, 32).toString("hex"),
            },
            session: {
              logical_session_id: text(row.checkpoint_logical_session_id),
              last_run_id: u64(row.checkpoint_last_run_id),
              last_compact_id: u64(row.checkpoint_last_compact_id),
              model: text(row.checkpoint_model),
            },
            anchor: {
              terminal: {
                kind: row.checkpoint_terminal_kind,
                id: u64(row.checkpoint_terminal_id),
              },
              binding_epoch: u64(row.checkpoint_binding_epoch),
            },
          },
    };
  } finally {
    database.close();
  }
}
