import type { AccountView } from "../../bridge/contracts.ts";

export function requiresAccountGate(
  account: Pick<AccountView, "state">,
): boolean {
  return account.state === "checking" || account.state === "authorizing";
}

/**
 * An authenticated account that needs a user decision must use the Host-owned
 * account settings surface: `choosing` requires an API/model pick and `failed`
 * owns the retry action. `loading` is deliberately excluded — post-login
 * continuation resolves it automatically, and redirecting on a transient
 * state flashes the settings page on every startup while the catalog loads.
 */
export function requiresAccountSetup(
  account: Pick<AccountView, "state" | "catalogState" | "canCreateTask">,
): boolean {
  return (
    account.state === "authenticated" &&
    !account.canCreateTask &&
    (account.catalogState === "choosing" ||
      account.catalogState === "failed")
  );
}
