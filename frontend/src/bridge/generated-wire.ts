// Generated from Host wire types. Do not edit.
import {
  object,
  positiveWireId,
  positiveNumber,
  enumValue,
} from "./wire-codec.ts";
export const maxSnapshotBytes = 67108864;
export const maxSnapshotChunkBytes = 262144;
export const approvalFailureReasons = [
  "cancelled",
  "busy",
  "budget_required",
  "mode_update_failed",
  "checkpoint_failed",
  "persistence_failed",
  "outcome_unknown",
  "recovery_failed",
  "dependency_contract",
] as const;
export type SnapshotDescriptor = {
  snapshotId: string;
  bytes: number;
  chunkBytes: number;
};
export function decodeSnapshotDescriptor(
  value: unknown,
  path: string,
): SnapshotDescriptor {
  const item = object(value, path, ["snapshotId", "bytes", "chunkBytes"]);
  return {
    snapshotId: positiveWireId(item.snapshotId, path + ".snapshotId"),
    bytes: positiveNumber(item.bytes, path + ".bytes"),
    chunkBytes: positiveNumber(item.chunkBytes, path + ".chunkBytes"),
  };
}
export type TaskApprovalResultWire = {
  revision: string;
  outcome: "completed" | "failed";
  reason:
    | "cancelled"
    | "busy"
    | "budget_required"
    | "mode_update_failed"
    | "checkpoint_failed"
    | "persistence_failed"
    | "outcome_unknown"
    | "recovery_failed"
    | "dependency_contract"
    | null;
};
export function decodeTaskApprovalResultWire(
  value: unknown,
  path: string,
): TaskApprovalResultWire {
  const item = object(value, path, ["revision", "outcome", "reason"]);
  return {
    revision: positiveWireId(item.revision, path + ".revision"),
    outcome: enumValue(item.outcome, path + ".outcome", [
      "completed",
      "failed",
    ] as const),
    reason:
      item.reason === null
        ? null
        : enumValue(item.reason, path + ".reason", [
            "cancelled",
            "busy",
            "budget_required",
            "mode_update_failed",
            "checkpoint_failed",
            "persistence_failed",
            "outcome_unknown",
            "recovery_failed",
            "dependency_contract",
          ] as const),
  };
}
