// Generated from Host wire types. Do not edit.
import {
  object,
  stringValue,
  booleanValue,
  arrayValue,
  positiveWireId,
  positiveU64WireId,
  u64WireInteger,
  positiveNumber,
  enumValue,
} from "./wire-codec.ts";
export const maxSnapshotBytes = 67108864;
export const maxSnapshotChunkBytes = 262144;
export const maxSnapshotPreparationSteps = 8;
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
  checkDiagnostic: {
    phase:
      | "admission"
      | "resolve"
      | "connect"
      | "send"
      | "head"
      | "body"
      | "complete";
    cause:
      | "invalid_request"
      | "dns_failed"
      | "connect_failed"
      | "tls_failed"
      | "write_failed"
      | "read_failed"
      | "invalid_response"
      | "response_too_large"
      | "out_of_memory"
      | "resource_limit"
      | "cancelled"
      | "deadline_exceeded";
    elapsed: "under_1s" | "under_5s" | "under_15s" | "over_15s";
  } | null;
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
    "checkDiagnostic",
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
    checkDiagnostic:
      item.checkDiagnostic === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, ["phase", "cause", "elapsed"]);
            return {
              phase: enumValue(item.phase, path + ".phase", [
                "admission",
                "resolve",
                "connect",
                "send",
                "head",
                "body",
                "complete",
              ] as const),
              cause: enumValue(item.cause, path + ".cause", [
                "invalid_request",
                "dns_failed",
                "connect_failed",
                "tls_failed",
                "write_failed",
                "read_failed",
                "invalid_response",
                "response_too_large",
                "out_of_memory",
                "resource_limit",
                "cancelled",
                "deadline_exceeded",
              ] as const),
              elapsed: enumValue(item.elapsed, path + ".elapsed", [
                "under_1s",
                "under_5s",
                "under_15s",
                "over_15s",
              ] as const),
            };
          })(item.checkDiagnostic, path + ".checkDiagnostic"),
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
export type InboxViewWire = {
  binding: string;
  state: "unavailable" | "checking" | "ready" | "reauthorize" | "unreachable";
  unreadTotal: string | null;
  syncedAtMs: string | null;
  conversations: readonly {
    peerId: string;
    name: string;
    unread: string;
    latest: {
      id: string;
      direction: "in" | "out" | "self";
      preview: string;
      sentAtMs: string;
    } | null;
    lastAtMs: string | null;
  }[];
  conversationsLoaded: boolean;
  loadingConversations: boolean;
  hasEarlier: boolean;
  diagnostic: {
    phase:
      | "admission"
      | "resolve"
      | "connect"
      | "send"
      | "head"
      | "body"
      | "complete";
    cause:
      | "invalid_request"
      | "dns_failed"
      | "connect_failed"
      | "tls_failed"
      | "write_failed"
      | "read_failed"
      | "invalid_response"
      | "response_too_large"
      | "out_of_memory"
      | "resource_limit"
      | "cancelled"
      | "deadline_exceeded";
    elapsed: "under_1s" | "under_5s" | "under_15s" | "over_15s";
  } | null;
};
export function decodeInboxViewWire(
  value: unknown,
  path: string,
): InboxViewWire {
  const item = object(value, path, [
    "binding",
    "state",
    "unreadTotal",
    "syncedAtMs",
    "conversations",
    "conversationsLoaded",
    "loadingConversations",
    "hasEarlier",
    "diagnostic",
  ]);
  return {
    binding: u64WireInteger(item.binding, path + ".binding"),
    state: enumValue(item.state, path + ".state", [
      "unavailable",
      "checking",
      "ready",
      "reauthorize",
      "unreachable",
    ] as const),
    unreadTotal:
      item.unreadTotal === null
        ? null
        : u64WireInteger(item.unreadTotal, path + ".unreadTotal"),
    syncedAtMs:
      item.syncedAtMs === null
        ? null
        : u64WireInteger(item.syncedAtMs, path + ".syncedAtMs"),
    conversations: arrayValue(
      item.conversations,
      path + ".conversations",
      (entry: unknown, entryPath: string) =>
        ((value: unknown, path: string) => {
          const item = object(value, path, [
            "peerId",
            "name",
            "unread",
            "latest",
            "lastAtMs",
          ]);
          return {
            peerId: stringValue(item.peerId, path + ".peerId"),
            name: stringValue(item.name, path + ".name"),
            unread: u64WireInteger(item.unread, path + ".unread"),
            latest:
              item.latest === null
                ? null
                : ((value: unknown, path: string) => {
                    const item = object(value, path, [
                      "id",
                      "direction",
                      "preview",
                      "sentAtMs",
                    ]);
                    return {
                      id: stringValue(item.id, path + ".id"),
                      direction: enumValue(
                        item.direction,
                        path + ".direction",
                        ["in", "out", "self"] as const,
                      ),
                      preview: stringValue(item.preview, path + ".preview"),
                      sentAtMs: u64WireInteger(
                        item.sentAtMs,
                        path + ".sentAtMs",
                      ),
                    };
                  })(item.latest, path + ".latest"),
            lastAtMs:
              item.lastAtMs === null
                ? null
                : u64WireInteger(item.lastAtMs, path + ".lastAtMs"),
          };
        })(entry, entryPath),
    ),
    conversationsLoaded: booleanValue(
      item.conversationsLoaded,
      path + ".conversationsLoaded",
    ),
    loadingConversations: booleanValue(
      item.loadingConversations,
      path + ".loadingConversations",
    ),
    hasEarlier: booleanValue(item.hasEarlier, path + ".hasEarlier"),
    diagnostic:
      item.diagnostic === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, ["phase", "cause", "elapsed"]);
            return {
              phase: enumValue(item.phase, path + ".phase", [
                "admission",
                "resolve",
                "connect",
                "send",
                "head",
                "body",
                "complete",
              ] as const),
              cause: enumValue(item.cause, path + ".cause", [
                "invalid_request",
                "dns_failed",
                "connect_failed",
                "tls_failed",
                "write_failed",
                "read_failed",
                "invalid_response",
                "response_too_large",
                "out_of_memory",
                "resource_limit",
                "cancelled",
                "deadline_exceeded",
              ] as const),
              elapsed: enumValue(item.elapsed, path + ".elapsed", [
                "under_1s",
                "under_5s",
                "under_15s",
                "over_15s",
              ] as const),
            };
          })(item.diagnostic, path + ".diagnostic"),
  };
}
export type InboxConversationPageWire = {
  binding: string;
  requestId: string;
  state:
    | "ready"
    | "stale_binding"
    | "unknown_peer"
    | "superseded"
    | "unavailable"
    | "forbidden"
    | "not_found"
    | "failed";
  peerId: string;
  messages: readonly {
    id: string;
    direction: "in" | "out" | "self";
    fromPeerId: string;
    fromName: string;
    fromAgent: string | null;
    isNew: boolean;
    recipients: readonly {
      peerId: string;
      name: string;
      read: boolean;
      readAtMs: string | null;
    }[];
    text: string;
    truncated: boolean;
    sentAtMs: string;
    taskIds: readonly string[];
  }[];
  hasEarlier: boolean;
  complete: boolean;
};
export function decodeInboxConversationPageWire(
  value: unknown,
  path: string,
): InboxConversationPageWire {
  const item = object(value, path, [
    "binding",
    "requestId",
    "state",
    "peerId",
    "messages",
    "hasEarlier",
    "complete",
  ]);
  return {
    binding: u64WireInteger(item.binding, path + ".binding"),
    requestId: u64WireInteger(item.requestId, path + ".requestId"),
    state: enumValue(item.state, path + ".state", [
      "ready",
      "stale_binding",
      "unknown_peer",
      "superseded",
      "unavailable",
      "forbidden",
      "not_found",
      "failed",
    ] as const),
    peerId: stringValue(item.peerId, path + ".peerId"),
    messages: arrayValue(
      item.messages,
      path + ".messages",
      (entry: unknown, entryPath: string) =>
        ((value: unknown, path: string) => {
          const item = object(value, path, [
            "id",
            "direction",
            "fromPeerId",
            "fromName",
            "fromAgent",
            "isNew",
            "recipients",
            "text",
            "truncated",
            "sentAtMs",
            "taskIds",
          ]);
          return {
            id: stringValue(item.id, path + ".id"),
            direction: enumValue(item.direction, path + ".direction", [
              "in",
              "out",
              "self",
            ] as const),
            fromPeerId: stringValue(item.fromPeerId, path + ".fromPeerId"),
            fromName: stringValue(item.fromName, path + ".fromName"),
            fromAgent:
              item.fromAgent === null
                ? null
                : stringValue(item.fromAgent, path + ".fromAgent"),
            isNew: booleanValue(item.isNew, path + ".isNew"),
            recipients: arrayValue(
              item.recipients,
              path + ".recipients",
              (entry: unknown, entryPath: string) =>
                ((value: unknown, path: string) => {
                  const item = object(value, path, [
                    "peerId",
                    "name",
                    "read",
                    "readAtMs",
                  ]);
                  return {
                    peerId: stringValue(item.peerId, path + ".peerId"),
                    name: stringValue(item.name, path + ".name"),
                    read: booleanValue(item.read, path + ".read"),
                    readAtMs:
                      item.readAtMs === null
                        ? null
                        : u64WireInteger(item.readAtMs, path + ".readAtMs"),
                  };
                })(entry, entryPath),
            ),
            text: stringValue(item.text, path + ".text"),
            truncated: booleanValue(item.truncated, path + ".truncated"),
            sentAtMs: u64WireInteger(item.sentAtMs, path + ".sentAtMs"),
            taskIds: arrayValue(
              item.taskIds,
              path + ".taskIds",
              (entry: unknown, entryPath: string) =>
                stringValue(entry, entryPath),
            ),
          };
        })(entry, entryPath),
    ),
    hasEarlier: booleanValue(item.hasEarlier, path + ".hasEarlier"),
    complete: booleanValue(item.complete, path + ".complete"),
  };
}
export type InboxTaskDetailWire = {
  binding: string;
  requestId: string;
  state:
    | "ready"
    | "stale_binding"
    | "superseded"
    | "unavailable"
    | "forbidden"
    | "not_found"
    | "failed";
  task: {
    id: string;
    name: string;
    progress: string | null;
    state: string | null;
    path: string | null;
    description: string | null;
    assignees: readonly string[];
    createdBy: string | null;
    updatedAtMs: string | null;
    lastNote: {
      text: string;
      atMs: string | null;
      by: string | null;
    } | null;
    notes: readonly {
      text: string;
      atMs: string | null;
      by: string | null;
    }[];
    children: readonly {
      id: string;
      name: string;
      progress: string | null;
    }[];
  } | null;
  file: {
    id: string;
    name: string;
    tag: string | null;
    sizeBytes: string | null;
    mime: string | null;
    description: string | null;
    by: string | null;
    updatedAtMs: string | null;
    path: string | null;
    content: string | null;
    contentTruncated: boolean;
    downloadable: boolean;
  } | null;
  project: {
    id: string;
    name: string;
    description: string | null;
    path: string | null;
    updatedAtMs: string | null;
    files: readonly {
      id: string;
      name: string;
      tag: string | null;
      sizeBytes: string | null;
      mime: string | null;
      by: string | null;
      updatedAtMs: string | null;
    }[];
    filesTruncated: boolean;
    fileTags: readonly {
      tag: string;
      count: string;
    }[];
  } | null;
};
export function decodeInboxTaskDetailWire(
  value: unknown,
  path: string,
): InboxTaskDetailWire {
  const item = object(value, path, [
    "binding",
    "requestId",
    "state",
    "task",
    "file",
    "project",
  ]);
  return {
    binding: u64WireInteger(item.binding, path + ".binding"),
    requestId: u64WireInteger(item.requestId, path + ".requestId"),
    state: enumValue(item.state, path + ".state", [
      "ready",
      "stale_binding",
      "superseded",
      "unavailable",
      "forbidden",
      "not_found",
      "failed",
    ] as const),
    task:
      item.task === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, [
              "id",
              "name",
              "progress",
              "state",
              "path",
              "description",
              "assignees",
              "createdBy",
              "updatedAtMs",
              "lastNote",
              "notes",
              "children",
            ]);
            return {
              id: stringValue(item.id, path + ".id"),
              name: stringValue(item.name, path + ".name"),
              progress:
                item.progress === null
                  ? null
                  : stringValue(item.progress, path + ".progress"),
              state:
                item.state === null
                  ? null
                  : stringValue(item.state, path + ".state"),
              path:
                item.path === null
                  ? null
                  : stringValue(item.path, path + ".path"),
              description:
                item.description === null
                  ? null
                  : stringValue(item.description, path + ".description"),
              assignees: arrayValue(
                item.assignees,
                path + ".assignees",
                (entry: unknown, entryPath: string) =>
                  stringValue(entry, entryPath),
              ),
              createdBy:
                item.createdBy === null
                  ? null
                  : stringValue(item.createdBy, path + ".createdBy"),
              updatedAtMs:
                item.updatedAtMs === null
                  ? null
                  : u64WireInteger(item.updatedAtMs, path + ".updatedAtMs"),
              lastNote:
                item.lastNote === null
                  ? null
                  : ((value: unknown, path: string) => {
                      const item = object(value, path, ["text", "atMs", "by"]);
                      return {
                        text: stringValue(item.text, path + ".text"),
                        atMs:
                          item.atMs === null
                            ? null
                            : u64WireInteger(item.atMs, path + ".atMs"),
                        by:
                          item.by === null
                            ? null
                            : stringValue(item.by, path + ".by"),
                      };
                    })(item.lastNote, path + ".lastNote"),
              notes: arrayValue(
                item.notes,
                path + ".notes",
                (entry: unknown, entryPath: string) =>
                  ((value: unknown, path: string) => {
                    const item = object(value, path, ["text", "atMs", "by"]);
                    return {
                      text: stringValue(item.text, path + ".text"),
                      atMs:
                        item.atMs === null
                          ? null
                          : u64WireInteger(item.atMs, path + ".atMs"),
                      by:
                        item.by === null
                          ? null
                          : stringValue(item.by, path + ".by"),
                    };
                  })(entry, entryPath),
              ),
              children: arrayValue(
                item.children,
                path + ".children",
                (entry: unknown, entryPath: string) =>
                  ((value: unknown, path: string) => {
                    const item = object(value, path, [
                      "id",
                      "name",
                      "progress",
                    ]);
                    return {
                      id: stringValue(item.id, path + ".id"),
                      name: stringValue(item.name, path + ".name"),
                      progress:
                        item.progress === null
                          ? null
                          : stringValue(item.progress, path + ".progress"),
                    };
                  })(entry, entryPath),
              ),
            };
          })(item.task, path + ".task"),
    file:
      item.file === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, [
              "id",
              "name",
              "tag",
              "sizeBytes",
              "mime",
              "description",
              "by",
              "updatedAtMs",
              "path",
              "content",
              "contentTruncated",
              "downloadable",
            ]);
            return {
              id: stringValue(item.id, path + ".id"),
              name: stringValue(item.name, path + ".name"),
              tag:
                item.tag === null ? null : stringValue(item.tag, path + ".tag"),
              sizeBytes:
                item.sizeBytes === null
                  ? null
                  : u64WireInteger(item.sizeBytes, path + ".sizeBytes"),
              mime:
                item.mime === null
                  ? null
                  : stringValue(item.mime, path + ".mime"),
              description:
                item.description === null
                  ? null
                  : stringValue(item.description, path + ".description"),
              by: item.by === null ? null : stringValue(item.by, path + ".by"),
              updatedAtMs:
                item.updatedAtMs === null
                  ? null
                  : u64WireInteger(item.updatedAtMs, path + ".updatedAtMs"),
              path:
                item.path === null
                  ? null
                  : stringValue(item.path, path + ".path"),
              content:
                item.content === null
                  ? null
                  : stringValue(item.content, path + ".content"),
              contentTruncated: booleanValue(
                item.contentTruncated,
                path + ".contentTruncated",
              ),
              downloadable: booleanValue(
                item.downloadable,
                path + ".downloadable",
              ),
            };
          })(item.file, path + ".file"),
    project:
      item.project === null
        ? null
        : ((value: unknown, path: string) => {
            const item = object(value, path, [
              "id",
              "name",
              "description",
              "path",
              "updatedAtMs",
              "files",
              "filesTruncated",
              "fileTags",
            ]);
            return {
              id: stringValue(item.id, path + ".id"),
              name: stringValue(item.name, path + ".name"),
              description:
                item.description === null
                  ? null
                  : stringValue(item.description, path + ".description"),
              path:
                item.path === null
                  ? null
                  : stringValue(item.path, path + ".path"),
              updatedAtMs:
                item.updatedAtMs === null
                  ? null
                  : u64WireInteger(item.updatedAtMs, path + ".updatedAtMs"),
              files: arrayValue(
                item.files,
                path + ".files",
                (entry: unknown, entryPath: string) =>
                  ((value: unknown, path: string) => {
                    const item = object(value, path, [
                      "id",
                      "name",
                      "tag",
                      "sizeBytes",
                      "mime",
                      "by",
                      "updatedAtMs",
                    ]);
                    return {
                      id: stringValue(item.id, path + ".id"),
                      name: stringValue(item.name, path + ".name"),
                      tag:
                        item.tag === null
                          ? null
                          : stringValue(item.tag, path + ".tag"),
                      sizeBytes:
                        item.sizeBytes === null
                          ? null
                          : u64WireInteger(item.sizeBytes, path + ".sizeBytes"),
                      mime:
                        item.mime === null
                          ? null
                          : stringValue(item.mime, path + ".mime"),
                      by:
                        item.by === null
                          ? null
                          : stringValue(item.by, path + ".by"),
                      updatedAtMs:
                        item.updatedAtMs === null
                          ? null
                          : u64WireInteger(
                              item.updatedAtMs,
                              path + ".updatedAtMs",
                            ),
                    };
                  })(entry, entryPath),
              ),
              filesTruncated: booleanValue(
                item.filesTruncated,
                path + ".filesTruncated",
              ),
              fileTags: arrayValue(
                item.fileTags,
                path + ".fileTags",
                (entry: unknown, entryPath: string) =>
                  ((value: unknown, path: string) => {
                    const item = object(value, path, ["tag", "count"]);
                    return {
                      tag: stringValue(item.tag, path + ".tag"),
                      count: u64WireInteger(item.count, path + ".count"),
                    };
                  })(entry, entryPath),
              ),
            };
          })(item.project, path + ".project"),
  };
}
export type InboxFileOpenWire = {
  binding: string;
  requestId: string;
  state:
    | "opened"
    | "stale_binding"
    | "superseded"
    | "unavailable"
    | "forbidden"
    | "not_found"
    | "not_downloadable"
    | "failed";
};
export function decodeInboxFileOpenWire(
  value: unknown,
  path: string,
): InboxFileOpenWire {
  const item = object(value, path, ["binding", "requestId", "state"]);
  return {
    binding: u64WireInteger(item.binding, path + ".binding"),
    requestId: u64WireInteger(item.requestId, path + ".requestId"),
    state: enumValue(item.state, path + ".state", [
      "opened",
      "stale_binding",
      "superseded",
      "unavailable",
      "forbidden",
      "not_found",
      "not_downloadable",
      "failed",
    ] as const),
  };
}
export type InboxSendResultWire = {
  binding: string;
  requestId: string;
  state:
    | "sent"
    | "stale_binding"
    | "unknown_peer"
    | "busy"
    | "superseded"
    | "unavailable"
    | "forbidden"
    | "not_found"
    | "rejected"
    | "failed";
  sent: readonly string[];
};
export function decodeInboxSendResultWire(
  value: unknown,
  path: string,
): InboxSendResultWire {
  const item = object(value, path, ["binding", "requestId", "state", "sent"]);
  return {
    binding: u64WireInteger(item.binding, path + ".binding"),
    requestId: u64WireInteger(item.requestId, path + ".requestId"),
    state: enumValue(item.state, path + ".state", [
      "sent",
      "stale_binding",
      "unknown_peer",
      "busy",
      "superseded",
      "unavailable",
      "forbidden",
      "not_found",
      "rejected",
      "failed",
    ] as const),
    sent: arrayValue(
      item.sent,
      path + ".sent",
      (entry: unknown, entryPath: string) => stringValue(entry, entryPath),
    ),
  };
}
