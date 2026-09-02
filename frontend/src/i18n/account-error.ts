import type { AccountErrorCode } from "../bridge/contracts.ts";
import type { MessageId, useI18n } from "./context.ts";

export function accountErrorMessageId(code: AccountErrorCode): MessageId {
  switch (code) {
    case "deadline_exceeded":
      return "account.error.deadline";
    case "oauth_browser_open_failed":
      return "account.error.browser";
    case "oauth_callback_rejected":
    case "oauth_state_mismatch":
    case "oauth_exchange_failed":
      return "account.error.authorization";
    case "token_refresh_failed":
      return "account.error.session_expired";
    case "metask_unauthorized":
      return "account.error.metask_access";
    case "metask_rate_limited":
    case "metask_service_unavailable":
      return "account.error.service";
    case "credential_store_read_failed":
    case "credential_store_write_failed":
    case "credential_store_delete_failed":
      return "account.error.credentials";
    case "local_resource_exhausted":
      return "account.error.local";
    default:
      return "account.error.generic";
  }
}

export function accountErrorText(
  code: AccountErrorCode,
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(accountErrorMessageId(code));
}
