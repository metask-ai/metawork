import type { AccountView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

type Props = {
  account: AccountView;
  compact?: boolean;
  disabled: boolean;
  onBeginLogin: () => void;
  onReauthenticate: () => void;
  onCancel: () => void;
  onRefresh: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
  onLogout: () => void;
};

export function AccountPanel({
  account,
  compact = false,
  disabled,
  onBeginLogin,
  onReauthenticate,
  onCancel,
  onRefresh,
  onSelectApiKey,
  onSelectModel,
  onLogout,
}: Props) {
  const { t } = useI18n();
  const hasAccount =
    account.sessionState === "authenticated" ||
    account.sessionState === "refreshing" ||
    account.sessionState === "reauth_required";
  const canConfigureCatalog = account.sessionState === "authenticated";
  const working =
    account.operation !== "none" ||
    account.sessionState === "authorizing" ||
    account.sessionState === "refreshing";
  const ready = account.executionState === "ready";
  const operationStatus =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);
  const restartRequired =
    account.sessionState === "shutting_down" ||
    account.errorCode === "recovery_state_invalid";

  return (
    <section
      className={compact ? "account-panel is-compact" : "account-panel"}
      aria-labelledby={compact ? "account-title-compact" : "account-title"}
    >
      <div className="account-panel-heading">
        <div>
          <p className="section-label">{t("account.label")}</p>
          <h2 id={compact ? "account-title-compact" : "account-title"}>
            {ready
              ? account.displayName || t("account.signed_in")
              : t("account.prepare_title")}
          </h2>
        </div>
        <span
          className="account-readiness"
          data-ready={ready && account.canCreateTask}
        >
          {operationStatus ??
            (ready && account.canCreateTask
              ? t("account.ready")
              : t(`account.session.${account.sessionState}`))}
        </span>
      </div>

      {!compact && (
        <>
          <p className="account-intro">{t("account.prepare_body")}</p>
          <ol className="account-track" aria-label={t("account.progress")}>
            <Step
              index={1}
              label={t("account.step.account")}
              statusLabels={{
                waiting: t("account.step_state.waiting"),
                current: t("account.step_state.current"),
                working: t("account.step_state.working"),
                done: t("account.step_state.done"),
              }}
              state={
                hasAccount
                  ? "done"
                  : account.sessionState === "signed_out"
                    ? "current"
                    : "working"
              }
            />
            <Step
              index={2}
              label={t("account.step.key")}
              statusLabels={{
                waiting: t("account.step_state.waiting"),
                current: t("account.step_state.current"),
                working: t("account.step_state.working"),
                done: t("account.step_state.done"),
              }}
              state={
                account.selectedApiKeyId
                  ? "done"
                  : hasAccount
                    ? "current"
                    : "waiting"
              }
            />
            <Step
              index={3}
              label={t("account.step.model")}
              statusLabels={{
                waiting: t("account.step_state.waiting"),
                current: t("account.step_state.current"),
                working: t("account.step_state.working"),
                done: t("account.step_state.done"),
              }}
              state={
                account.selectedModel
                  ? "done"
                  : account.selectedApiKeyId
                    ? "current"
                    : "waiting"
              }
            />
            <Step
              index={4}
              label={t("account.step.ready")}
              statusLabels={{
                waiting: t("account.step_state.waiting"),
                current: t("account.step_state.current"),
                working: t("account.step_state.working"),
                done: t("account.step_state.done"),
              }}
              state={ready ? "done" : "waiting"}
            />
          </ol>
        </>
      )}

      {account.errorCode === "user_cancelled" ? (
        <p className="account-working" role="status">
          {t("account.cancelled")}
        </p>
      ) : (
        account.errorCode !== "none" && (
          <div className="account-error" role="alert">
            <strong>{t("account.action_failed")}</strong>
            <span>
              {account.safeDiagnostic ||
                t("account.error_code", { code: account.errorCode })}
            </span>
          </div>
        )
      )}

      {restartRequired ? (
        <p className="account-restart">{t("account.restart_required")}</p>
      ) : account.sessionState === "signed_out" ? (
        <button
          className="primary-button focus-ring"
          disabled={disabled}
          onClick={onBeginLogin}
        >
          {t("account.login")}
        </button>
      ) : account.sessionState === "restoring" ? (
        <p className="account-working" role="status">
          {t("account.restoring")}
        </p>
      ) : (
        <>
          {operationStatus && (
            <p className="account-working" role="status">
              {operationStatus}
            </p>
          )}

          {account.sessionState === "reauth_required" && (
            <button
              className="primary-button focus-ring"
              disabled={disabled}
              onClick={onReauthenticate}
            >
              {t("account.reauthenticate")}
            </button>
          )}

          {hasAccount && (
            <div className="account-fields">
              <label>
                <span>{t("account.api_key")}</span>
                <select
                  className="focus-ring"
                  value={account.selectedApiKeyId}
                  disabled={
                    disabled ||
                    working ||
                    !canConfigureCatalog ||
                    account.apiKeys.length === 0
                  }
                  onChange={(event) => onSelectApiKey(event.target.value)}
                >
                  <option value="" disabled>
                    {t("account.choose_key")}
                  </option>
                  {account.apiKeys.map((key) => (
                    <option key={key.id} value={key.id}>
                      {key.name || key.id}
                      {key.suffix ? ` · ${key.suffix}` : ""}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                <span>{t("account.model")}</span>
                <select
                  className="focus-ring"
                  value={account.selectedModel}
                  disabled={
                    disabled ||
                    working ||
                    !canConfigureCatalog ||
                    account.models.length === 0
                  }
                  onChange={(event) => onSelectModel(event.target.value)}
                >
                  <option value="" disabled>
                    {t("account.choose_model")}
                  </option>
                  {account.models.map((model) => (
                    <option key={model.id} value={model.id}>
                      {model.displayName || model.id}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          )}

          <div className="account-actions">
            {working && account.operation !== "logging_out" ? (
              <button
                className="secondary-button focus-ring"
                disabled={disabled}
                onClick={onCancel}
              >
                {t("account.cancel")}
              </button>
            ) : (
              canConfigureCatalog && (
                <button
                  className="secondary-button focus-ring"
                  disabled={disabled}
                  onClick={onRefresh}
                >
                  {account.apiKeys.length === 0
                    ? t("account.load_catalog")
                    : t("account.refresh_catalog")}
                </button>
              )
            )}
            {hasAccount && !working && (
              <button
                className="text-button focus-ring"
                disabled={disabled}
                onClick={onLogout}
              >
                {t("account.logout")}
              </button>
            )}
          </div>
        </>
      )}
    </section>
  );
}

function Step({
  index,
  label,
  state,
  statusLabels,
}: {
  index: number;
  label: string;
  state: "waiting" | "current" | "working" | "done";
  statusLabels: Record<"waiting" | "current" | "working" | "done", string>;
}) {
  return (
    <li
      data-state={state}
      aria-current={
        state === "current" || state === "working" ? "step" : undefined
      }
    >
      <span className="account-step-mark" aria-hidden="true">
        {state === "done" ? "✓" : index}
      </span>
      <strong>{label}</strong>
      <span className="sr-only">{statusLabels[state]}</span>
    </li>
  );
}
