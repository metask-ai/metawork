import type { AccountErrorCode, AccountView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

type Props = {
  account: AccountView;
  disabled: boolean;
  cancelDisabled?: boolean;
  onBeginLogin: () => void;
  onReopenLogin: () => void;
  onReauthenticate: () => void;
  onCancel: () => void;
  onRetry: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
};

export function AccountPrerequisite({
  account,
  disabled,
  cancelDisabled = disabled,
  onBeginLogin,
  onReopenLogin,
  onReauthenticate,
  onCancel,
  onRetry,
  onSelectApiKey,
  onSelectModel,
}: Props) {
  const { t } = useI18n();
  if (account.readiness === "ready") return null;

  const operation =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);
  const error =
    account.readiness !== "restart_required" &&
    account.errorCode !== "none" &&
    account.errorCode !== "user_cancelled";

  return (
    <section
      className="account-prerequisite"
      aria-labelledby="account-prerequisite-title"
      data-readiness={account.readiness}
    >
      <div className="account-prerequisite-copy">
        <span className="account-prerequisite-mark" aria-hidden="true">
          {account.readiness === "preparing" || account.readiness === "checking"
            ? "···"
            : "M"}
        </span>
        <div>
          <strong id="account-prerequisite-title">
            {t(`account.readiness.${account.readiness}.title`)}
          </strong>
          <p
            aria-live={error ? "assertive" : "polite"}
            role={error ? "alert" : "status"}
          >
            {error
              ? accountErrorText(account.errorCode, t)
              : operation ||
                (account.errorCode === "user_cancelled"
                  ? t("account.cancelled")
                  : t(`account.readiness.${account.readiness}.body`))}
          </p>
        </div>
      </div>

      {account.primaryAction === "choose_api_key" && (
        <label className="account-prerequisite-choice">
          <span>{t("account.api_key")}</span>
          <select
            className="focus-ring"
            value=""
            disabled={disabled || account.apiKeys.length === 0}
            onChange={(event) => {
              if (event.target.value) onSelectApiKey(event.target.value);
            }}
          >
            <option value="">{t("account.choose_key")}</option>
            {account.apiKeys.map((key) => (
              <option key={key.id} value={key.id}>
                {key.name || key.id}
                {key.suffix ? ` · ${key.suffix}` : ""}
              </option>
            ))}
          </select>
        </label>
      )}

      {account.primaryAction === "choose_model" && (
        <label className="account-prerequisite-choice">
          <span>{t("account.model")}</span>
          <select
            className="focus-ring"
            value=""
            disabled={disabled || account.models.length === 0}
            onChange={(event) => {
              if (event.target.value) onSelectModel(event.target.value);
            }}
          >
            <option value="">{t("account.choose_model")}</option>
            {account.models.map((model) => (
              <option key={model.id} value={model.id}>
                {model.displayName || model.id}
              </option>
            ))}
          </select>
        </label>
      )}

      <div className="account-prerequisite-actions">
        {account.primaryAction === "sign_in" && (
          <button
            className="primary-button focus-ring"
            disabled={disabled}
            onClick={onBeginLogin}
          >
            {t("account.login")}
          </button>
        )}
        {account.primaryAction === "reopen_login" && (
          <button
            className="primary-button focus-ring"
            disabled={disabled}
            onClick={onReopenLogin}
          >
            {t("account.reopen_login")}
          </button>
        )}
        {account.primaryAction === "retry_catalog" && (
          <button
            className="primary-button focus-ring"
            disabled={disabled}
            onClick={onRetry}
          >
            {t("account.retry_preparation")}
          </button>
        )}
        {account.primaryAction === "reauthenticate" && (
          <button
            className="primary-button focus-ring"
            disabled={disabled}
            onClick={onReauthenticate}
          >
            {t("account.reauthenticate")}
          </button>
        )}
        {account.canCancel && (
          <button
            className="text-button focus-ring"
            disabled={cancelDisabled}
            onClick={onCancel}
          >
            {t("account.cancel")}
          </button>
        )}
      </div>
    </section>
  );
}

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
