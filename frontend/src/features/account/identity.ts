import type { AccountView } from "../../bridge/contracts.ts";

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
