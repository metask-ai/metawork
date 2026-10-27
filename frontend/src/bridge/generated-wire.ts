// Generated from Host wire types. Do not edit.
import {
  object,
  stringValue,
  booleanValue,
  positiveWireId,
  positiveU64WireId,
  u64WireInteger,
  positiveNumber,
  enumValue,
} from "./wire-codec.ts";
export const maxSnapshotBytes = 67108864;
export const maxSnapshotChunkBytes = 262144;
export const maxSnapshotPreparationSteps = 2048;
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
export type SnapshotPreparing = {
  snapshotId: string;
  phase: "preparing";
};
export function decodeSnapshotPreparing(
  value: unknown,
  path: string,
): SnapshotPreparing {
  const item = object(value, path, ["snapshotId", "phase"]);
  return {
    snapshotId: positiveWireId(item.snapshotId, path + ".snapshotId"),
    phase: enumValue(item.phase, path + ".phase", ["preparing"] as const),
  };
}
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
export type UpdateViewWire = {
  checkState: "unchecked" | "checking" | "succeeded" | "failed" | "unavailable";
  checkError:
    "none" | "network" | "timeout" | "invalid_manifest" | "unavailable";
  latestVersion: string | null;
  updateAvailable: boolean;
  downloadAvailable: boolean;
  downloadState: "idle" | "checking" | "opened" | "failed";
  downloadError:
    | "none"
    | "stale_version"
    | "missing_download"
    | "invalid_link"
    | "network"
    | "timeout"
    | "browser_unavailable"
    | "unavailable";
};
export function decodeUpdateViewWire(
  value: unknown,
  path: string,
): UpdateViewWire {
  const item = object(value, path, [
    "checkState",
    "checkError",
    "latestVersion",
    "updateAvailable",
    "downloadAvailable",
    "downloadState",
    "downloadError",
  ]);
  return {
    checkState: enumValue(item.checkState, path + ".checkState", [
      "unchecked",
      "checking",
      "succeeded",
      "failed",
      "unavailable",
    ] as const),
    checkError: enumValue(item.checkError, path + ".checkError", [
      "none",
      "network",
      "timeout",
      "invalid_manifest",
      "unavailable",
    ] as const),
    latestVersion:
      item.latestVersion === null
        ? null
        : stringValue(item.latestVersion, path + ".latestVersion"),
    updateAvailable: booleanValue(
      item.updateAvailable,
      path + ".updateAvailable",
    ),
    downloadAvailable: booleanValue(
      item.downloadAvailable,
      path + ".downloadAvailable",
    ),
    downloadState: enumValue(item.downloadState, path + ".downloadState", [
      "idle",
      "checking",
      "opened",
      "failed",
    ] as const),
    downloadError: enumValue(item.downloadError, path + ".downloadError", [
      "none",
      "stale_version",
      "missing_download",
      "invalid_link",
      "network",
      "timeout",
      "browser_unavailable",
      "unavailable",
    ] as const),
  };
}
