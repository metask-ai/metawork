import type { PendingUi, TaskView, UiRecord } from "../../bridge/contracts.ts";

export type RepeatedPermissionReason =
  | "allowed_once"
  | "denied_once"
  | "policy_changed"
  | "candidate_changed"
  | "session_choice_unavailable"
  | "session_grant_missed";

export type RepeatedPermissionDiagnostic = {
  reason: RepeatedPermissionReason;
  previous: UiRecord;
  restoreRulesInvalidated: boolean;
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
  const diagnostic = (
    reason: RepeatedPermissionReason,
  ): RepeatedPermissionDiagnostic => ({
    reason,
    previous,
    restoreRulesInvalidated: invalidatedRuleCount(task) > 0n,
  });

  if (previous.state === "allowed_once") return diagnostic("allowed_once");
  if (previous.state === "denied") return diagnostic("denied_once");
  if (previous.permission.policyGeneration !== pending.policyGeneration)
    return diagnostic("policy_changed");
  if (pending.candidate === null)
    return diagnostic("session_choice_unavailable");
  if (
    previous.permission.matchedRuleId.length > 0 &&
    previous.permission.matchedRuleId !== pending.candidate.ruleId
  )
    return diagnostic("candidate_changed");
  if (
    previous.state === "allowed_always" &&
    previous.permission.matchedRuleId === pending.candidate.ruleId
  )
    return diagnostic("session_grant_missed");

  return diagnostic("candidate_changed");
}
