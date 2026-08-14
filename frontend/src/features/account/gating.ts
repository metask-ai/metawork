import type { AccountView } from "../../bridge/contracts.ts";

export function requiresAccountGate(
  account: Pick<AccountView, "state">,
): boolean {
  return account.state === "checking" || account.state === "authorizing";
}

/**
 * An authenticated account whose execution configuration is still being
 * prepared must use the Host-owned account settings surface. API/model
 * candidates are only actionable there; keeping the Workbench visible would
 * leave the user with a disabled Agent entry point and no next step.
 */
export function requiresAccountSetup(
  account: Pick<AccountView, "state" | "catalogState" | "canCreateTask">,
): boolean {
  return (
    account.state === "authenticated" &&
    !account.canCreateTask &&
    (account.catalogState === "loading" ||
      account.catalogState === "choosing" ||
      account.catalogState === "failed")
  );
}
