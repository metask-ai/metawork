import type { AccountErrorCode } from "../bridge/contracts.ts";
import type { useI18n } from "./context.ts";

export function accountErrorText(
  code: AccountErrorCode,
  t: ReturnType<typeof useI18n>["t"],
) {
  switch (code) {
    case "no_api_keys":
      return t("account.error.no_api_keys");
    case "no_models":
      return t("account.error.no_models");
    case "deadline_exceeded":
      return t("account.error.deadline");
    case "oauth_browser_open_failed":
      return t("account.error.browser");
    case "oauth_callback_rejected":
    case "oauth_state_mismatch":
    case "oauth_exchange_failed":
      return t("account.error.authorization");
    case "metask_rate_limited":
    case "metask_service_unavailable":
      return t("account.error.service");
    case "credential_store_read_failed":
    case "credential_store_write_failed":
    case "credential_store_delete_failed":
      return t("account.error.credentials");
    case "local_resource_exhausted":
    case "execution_in_use":
      return t("account.error.local");
    default:
      return t("account.error.generic");
  }
}
