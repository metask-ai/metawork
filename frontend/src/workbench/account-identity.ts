import type { AccountView } from "../bridge/contracts.ts";

type IdentityFields = Pick<
  AccountView,
  "displayName" | "emailHint" | "phoneHint"
>;

export function accountIdentityLabel(
  account: IdentityFields,
  signedInLabel: string,
): string {
  return (
    account.displayName ||
    account.emailHint ||
    account.phoneHint ||
    signedInLabel
  );
}

export function accountIdentityInitial(account: IdentityFields): string {
  return [...account.displayName.trim()][0]?.toLocaleUpperCase() || "M";
}

/** A stored login the Host is still trying to confirm after a failure. */
export function accountUnconfirmed(account: AccountView): boolean {
  return account.state === "checking" && account.errorCode !== "none";
}
