// Generated from Host wire types. Do not edit.
import {
  object,
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
export type OfficeComponentView = {
  generation: string;
  supported: boolean;
  health:
    | "unavailable"
    | "ready"
    | "read_failed"
    | "corrupt"
    | "outcome_unknown"
    | "restart_required";
  offered: {
    downloadBytes: string;
    installedBytes: string;
  } | null;
  current: {
    state: "ready" | "damaged" | "incompatible" | "unverified";
  } | null;
  updateAvailable: boolean;
  operation: {
    id: string;
    kind: "check" | "install" | "repair" | "remove" | "cleanup";
    phase:
      | "preparing"
      | "downloading"
      | "unpacking"
      | "verifying"
      | "testing"
      | "publishing"
      | "finalizing"
      | "activating"
      | "cleaning";
    bytes: string;
    total: string;
    cancelling: boolean;
  } | null;
  terminal: {
    id: string;
    kind: "check" | "install" | "repair" | "remove" | "cleanup";
    outcome: "succeeded" | "cancelled" | "failed";
    reason:
      | "unsupported_platform"
      | "unavailable"
      | "unpublished"
      | "stale_generation"
      | "busy"
      | "recovery_required"
      | "not_installed"
      | "already_installed"
      | "not_needed"
      | "nothing_to_clean"
      | "too_late"
      | "shutting_down"
      | "revision_exhausted"
      | "download_failed"
      | "invalid_component"
      | "insufficient_space"
      | "resource_limit"
      | "process_cleanup_incomplete"
      | "write_failed"
      | "outcome_unknown"
      | "cleanup_failed"
      | null;
  } | null;
  cleanupPending: boolean;
  actions: {
    install: boolean;
    repair: boolean;
    remove: boolean;
    retry: boolean;
    cleanup: boolean;
    cancel: boolean;
  };
};
export function decodeOfficeComponentView(
  value: unknown,
  path: string,
): OfficeComponentView {
  const item = object(value, path, [
    "generation",
    "supported",
    "health",
    "offered",
    "current",
    "updateAvailable",
    "operation",
    "terminal",
    "cleanupPending",
    "actions",
  ]);
  return {
    generation: positiveU64WireId(item.generation, path + ".generation"),
    supported: booleanValue(item.supported, path + ".supported"),
    health: enumValue(item.health, path + ".health", [
      "unavailable",
      "ready",
      "read_failed",
      "corrupt",
      "outcome_unknown",
      "restart_required",
    ] as const),
    offered:
      item.offered === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, [
              "downloadBytes",
              "installedBytes",
            ]);
            return {
              downloadBytes: u64WireInteger(
                item.downloadBytes,
                path + ".downloadBytes",
              ),
              installedBytes: u64WireInteger(
                item.installedBytes,
                path + ".installedBytes",
              ),
            };
          })(item.offered, path + ".offered"),
    current:
      item.current === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, ["state"]);
            return {
              state: enumValue(item.state, path + ".state", [
                "ready",
                "damaged",
                "incompatible",
                "unverified",
              ] as const),
            };
          })(item.current, path + ".current"),
    updateAvailable: booleanValue(
      item.updateAvailable,
      path + ".updateAvailable",
    ),
    operation:
      item.operation === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, [
              "id",
              "kind",
              "phase",
              "bytes",
              "total",
              "cancelling",
            ]);
            return {
              id: positiveU64WireId(item.id, path + ".id"),
              kind: enumValue(item.kind, path + ".kind", [
                "check",
                "install",
                "repair",
                "remove",
                "cleanup",
              ] as const),
              phase: enumValue(item.phase, path + ".phase", [
                "preparing",
                "downloading",
                "unpacking",
                "verifying",
                "testing",
                "publishing",
                "finalizing",
                "activating",
                "cleaning",
              ] as const),
              bytes: u64WireInteger(item.bytes, path + ".bytes"),
              total: u64WireInteger(item.total, path + ".total"),
              cancelling: booleanValue(item.cancelling, path + ".cancelling"),
            };
          })(item.operation, path + ".operation"),
    terminal:
      item.terminal === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, [
              "id",
              "kind",
              "outcome",
              "reason",
            ]);
            return {
              id: positiveU64WireId(item.id, path + ".id"),
              kind: enumValue(item.kind, path + ".kind", [
                "check",
                "install",
                "repair",
                "remove",
                "cleanup",
              ] as const),
              outcome: enumValue(item.outcome, path + ".outcome", [
                "succeeded",
                "cancelled",
                "failed",
              ] as const),
              reason:
                item.reason === null
                  ? null
                  : enumValue(item.reason, path + ".reason", [
                      "unsupported_platform",
                      "unavailable",
                      "unpublished",
                      "stale_generation",
                      "busy",
                      "recovery_required",
                      "not_installed",
                      "already_installed",
                      "not_needed",
                      "nothing_to_clean",
                      "too_late",
                      "shutting_down",
                      "revision_exhausted",
                      "download_failed",
                      "invalid_component",
                      "insufficient_space",
                      "resource_limit",
                      "process_cleanup_incomplete",
                      "write_failed",
                      "outcome_unknown",
                      "cleanup_failed",
                    ] as const),
            };
          })(item.terminal, path + ".terminal"),
    cleanupPending: booleanValue(item.cleanupPending, path + ".cleanupPending"),
    actions: ((value: unknown, path: string) => {
      const item = object(value, path, [
        "install",
        "repair",
        "remove",
        "retry",
        "cleanup",
        "cancel",
      ]);
      return {
        install: booleanValue(item.install, path + ".install"),
        repair: booleanValue(item.repair, path + ".repair"),
        remove: booleanValue(item.remove, path + ".remove"),
        retry: booleanValue(item.retry, path + ".retry"),
        cleanup: booleanValue(item.cleanup, path + ".cleanup"),
        cancel: booleanValue(item.cancel, path + ".cancel"),
      };
    })(item.actions, path + ".actions"),
  };
}
export type OfficeComponentResult = {
  accepted: boolean;
  generation: string;
  operationId: string | null;
  reason:
    | "unsupported_platform"
    | "unavailable"
    | "unpublished"
    | "stale_generation"
    | "busy"
    | "recovery_required"
    | "not_installed"
    | "already_installed"
    | "not_needed"
    | "nothing_to_clean"
    | "too_late"
    | "shutting_down"
    | "revision_exhausted"
    | "download_failed"
    | "invalid_component"
    | "insufficient_space"
    | "resource_limit"
    | "process_cleanup_incomplete"
    | "write_failed"
    | "outcome_unknown"
    | "cleanup_failed"
    | null;
};
export function decodeOfficeComponentResult(
  value: unknown,
  path: string,
): OfficeComponentResult {
  const item = object(value, path, [
    "accepted",
    "generation",
    "operationId",
    "reason",
  ]);
  return {
    accepted: booleanValue(item.accepted, path + ".accepted"),
    generation: positiveU64WireId(item.generation, path + ".generation"),
    operationId:
      item.operationId === null
        ? null
        : positiveU64WireId(item.operationId, path + ".operationId"),
    reason:
      item.reason === null
        ? null
        : enumValue(item.reason, path + ".reason", [
            "unsupported_platform",
            "unavailable",
            "unpublished",
            "stale_generation",
            "busy",
            "recovery_required",
            "not_installed",
            "already_installed",
            "not_needed",
            "nothing_to_clean",
            "too_late",
            "shutting_down",
            "revision_exhausted",
            "download_failed",
            "invalid_component",
            "insufficient_space",
            "resource_limit",
            "process_cleanup_incomplete",
            "write_failed",
            "outcome_unknown",
            "cleanup_failed",
          ] as const),
  };
}
