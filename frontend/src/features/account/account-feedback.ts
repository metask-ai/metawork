import type { AccountView } from "../../bridge/contracts.ts";
import type { MessageId } from "../../i18n/context.ts";
import { accountErrorMessageId } from "../../i18n/account-error.ts";

/** A recent observation, neither current service health nor an attempt result. */
export function accountFeedback(
  account: AccountView,
): { id: MessageId; diagnostic?: string } | null {
  const code = account.errorCode;
  if (code === "none" || code === "user_cancelled") return null;
  const specific: Partial<Record<AccountView["errorCode"], MessageId>> = {
    metask_rate_limited: "account.feedback.rate_limited",
    metask_service_unavailable: "account.feedback.service_unavailable",
    credential_store_read_failed: "account.feedback.credential_read",
    credential_store_write_failed: "account.feedback.credential_write",
    credential_store_delete_failed: "account.feedback.credential_delete",
  };
  return {
    id: specific[code] ?? accountErrorMessageId(code),
    diagnostic: account.safeDiagnostic || undefined,
  };
}
