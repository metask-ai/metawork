import type { AccountView } from "../../bridge/contracts.ts";

export function requiresAccountGate(
  hasEnteredWorkbench: boolean,
  account: Pick<
    AccountView,
    "sessionState" | "readiness" | "executionState" | "executionGeneration"
  >,
): boolean {
  const hasCommittedExecution =
    (account.executionState === "ready" ||
      account.executionState === "reconfiguring") &&
    account.executionGeneration !== "0";
  if (
    account.sessionState === "signed_out" ||
    account.sessionState === "shutting_down" ||
    account.readiness === "restart_required"
  )
    return true;
  return (
    !hasEnteredWorkbench &&
    account.readiness !== "ready" &&
    !hasCommittedExecution
  );
}
