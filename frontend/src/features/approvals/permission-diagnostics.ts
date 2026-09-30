import type { PendingUi, TaskView, UiRecord } from "../../bridge/contracts.ts";

export type RepeatedPermissionReason =
  | "allowed_once"
  | "denied_once"
  | "policy_changed"
  | "candidate_changed"
  | "session_choice_unavailable"
  | "session_rule_invalidated"
  | "session_grant_missed";

export type RepeatedPermissionDiagnostic = {
  reason: RepeatedPermissionReason;
  previous: UiRecord;
};

type PermissionDiagnosticTask = Pick<
  TaskView,
  "uiHistory" | "restorePermission"
>;

function samePermissionFingerprint(
  record: UiRecord,
  pending: PendingUi,
): boolean {
  const permission = record.permission;
  return (
    permission !== null &&
    permission.canonicalArgumentsDigest.length > 0 &&
    permission.canonicalArgumentsDigest === pending.canonicalArgumentsDigest &&
    permission.toolNamespace === pending.toolNamespace &&
    permission.toolName === pending.tool &&
    permission.toolBinding === pending.toolBinding
  );
}

function invalidatedRuleCount(task: PermissionDiagnosticTask): bigint {
  return BigInt(task.restorePermission?.invalidatedRules ?? "0");
}

export function diagnoseRepeatedPermission(
  task: PermissionDiagnosticTask,
  pending: PendingUi,
): RepeatedPermissionDiagnostic | null {
  let previous: UiRecord | undefined;
  for (let index = task.uiHistory.length - 1; index >= 0; index -= 1) {
    const record = task.uiHistory[index]!;
    if (!samePermissionFingerprint(record, pending)) continue;
    previous = record;
    break;
  }
  if (!previous?.permission) return null;

  if (previous.state === "allowed_once")
    return { reason: "allowed_once", previous };
  if (previous.state === "denied") return { reason: "denied_once", previous };
  if (previous.permission.policyGeneration !== pending.policyGeneration)
    return { reason: "policy_changed", previous };
  if (pending.candidate === null)
    return { reason: "session_choice_unavailable", previous };
  if (
    previous.permission.matchedRuleId.length > 0 &&
    previous.permission.matchedRuleId !== pending.candidate.ruleId
  )
    return { reason: "candidate_changed", previous };
  if (invalidatedRuleCount(task) > 0n)
    return { reason: "session_rule_invalidated", previous };
  if (
    previous.state === "allowed_always" &&
    previous.permission.matchedRuleId === pending.candidate.ruleId
  )
    return { reason: "session_grant_missed", previous };

  return { reason: "candidate_changed", previous };
}
