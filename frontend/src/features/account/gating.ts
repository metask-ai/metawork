import type { AccountView } from "../../bridge/contracts.ts";

export function requiresAccountGate(
  account: Pick<AccountView, "state">,
): boolean {
  return account.state === "checking" || account.state === "authorizing";
}
