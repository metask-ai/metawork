import type { PersistenceRecoveryOutcome } from "../bridge/contracts.ts";
import type { MessageId } from "./context.ts";

export function persistenceRecoveryErrorMessageId(
  outcome: Exclude<PersistenceRecoveryOutcome, "recovered">,
): MessageId {
  switch (outcome) {
    case "stale_revision":
      return "persistence.recovery.stale_revision";
    case "outcome_unknown":
      return "persistence.recovery.outcome_unknown";
    case "shutting_down":
      return "persistence.recovery.shutting_down";
    case "not_required":
    case "unavailable":
    case "failed":
      return "persistence.recovery.failed";
  }
}
