import type { AccountView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import { accountErrorText } from "./account-copy.ts";

type Props = {
  account: AccountView;
  disabled: boolean;
  onReauthenticate: () => void;
  onCancel: () => void;
  onRefresh: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
  onLogout: () => void;
};

/// Secondary account controls for an already usable Workbench. First-run
/// readiness is handled by the independent AccountGate.
export function AccountPanel({
  account,
  disabled,
  onReauthenticate,
  onCancel,
  onRefresh,
  onSelectApiKey,
  onSelectModel,
  onLogout,
}: Props) {
  const { t } = useI18n();
  const operationStatus =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);
  const selectedKey = account.apiKeys.find(
    (key) => key.selectionId === account.selectedApiKeySelectionId,
  );
  const selectedKeyLabel = selectedKey
    ? `${selectedKey.name || selectedKey.selectionId}${
        selectedKey.suffix ? ` · ${selectedKey.suffix}` : ""
      }`
    : t("account.saved_key");
  const selectedModelLabel =
    account.models.find(
      (model) => model.selectionId === account.selectedModelSelectionId,
    )?.displayName || account.selectedModelSelectionId;

  return (
    <section
      className="account-panel is-compact"
      aria-labelledby="account-title"
    >
      <div className="account-panel-heading">
        <div className="min-w-0">
          <p className="section-label">{t("account.label")}</p>
          <h2 id="account-title">
            {account.displayName || t("account.signed_in")}
          </h2>
        </div>
        <span className="account-readiness" data-ready="true">
          {t("account.ready")}
        </span>
      </div>

      <dl className="account-summary">
        <div>
          <dt>{t("account.api_key")}</dt>
          <dd>{selectedKeyLabel}</dd>
        </div>
        <div>
          <dt>{t("account.model")}</dt>
          <dd title={selectedModelLabel}>{selectedModelLabel}</dd>
        </div>
      </dl>

      {account.errorCode !== "none" &&
        account.errorCode !== "user_cancelled" && (
          <div className="account-error" role="alert">
            <strong>{t("account.action_failed")}</strong>
            <span>{accountErrorText(account.errorCode, t)}</span>
          </div>
        )}

      {operationStatus && (
        <p className="account-working" role="status">
          {operationStatus}
        </p>
      )}

      {account.operation === "selecting_key" && (
        <label className="account-settings-choice">
          <span>{t("account.api_key")}</span>
          <select
            className="focus-ring"
            value=""
            disabled={disabled}
            onChange={(event) => {
              if (event.target.value) onSelectApiKey(event.target.value);
            }}
          >
            <option value="">{t("account.choose_key")}</option>
            {account.apiKeys.map((key) => (
              <option key={key.selectionId} value={key.selectionId}>
                {key.name || key.selectionId}
                {key.suffix ? ` · ${key.suffix}` : ""}
              </option>
            ))}
          </select>
        </label>
      )}

      {account.operation === "selecting_model" && (
        <label className="account-settings-choice">
          <span>{t("account.model")}</span>
          <select
            className="focus-ring"
            value=""
            disabled={disabled}
            onChange={(event) => {
              if (event.target.value) onSelectModel(event.target.value);
            }}
          >
            <option value="">{t("account.choose_model")}</option>
            {account.models.map((model) => (
              <option key={model.selectionId} value={model.selectionId}>
                {model.displayName || model.selectionId}
              </option>
            ))}
          </select>
        </label>
      )}

      <div className="account-actions">
        {account.sessionState === "reauth_required" && (
          <button
            className="secondary-button focus-ring"
            disabled={disabled}
            onClick={onReauthenticate}
          >
            {t("account.reauthenticate")}
          </button>
        )}
        {account.canCancel ? (
          <button
            className="secondary-button focus-ring"
            disabled={disabled}
            onClick={onCancel}
          >
            {t("account.cancel")}
          </button>
        ) : (
          account.operation === "none" && (
            <button
              className="secondary-button focus-ring"
              disabled={disabled}
              onClick={onRefresh}
            >
              {t("account.refresh_catalog")}
            </button>
          )
        )}
        {account.operation === "none" && (
          <button
            className="text-button focus-ring"
            disabled={disabled}
            onClick={onLogout}
          >
            {t("account.logout")}
          </button>
        )}
      </div>
    </section>
  );
}
