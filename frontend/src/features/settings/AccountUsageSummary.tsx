import type { AccountView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatAccountSyncedAt } from "./account-summary-format.ts";
import { AccountUsageHeatmap } from "./AccountUsageHeatmap.tsx";

type AccountSummary = AccountView["summary"];

export function AccountRecharge({
  disabled,
  onRecharge,
}: {
  disabled: boolean;
  onRecharge: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="settings-identity-wallet">
      <Button
        variant="primary"
        size="lg"
        disabled={disabled}
        title={t("settings.account_recharge_browser_hint")}
        onClick={onRecharge}
      >
        <Icon name="external-link" />
        {t("settings.account_recharge")}
      </Button>
    </div>
  );
}

export function AccountUsageSummary({
  summary,
  disabled,
  onRefresh,
}: {
  summary: AccountSummary;
  disabled: boolean;
  onRefresh: () => void;
}) {
  const { locale, t } = useI18n();
  if (summary.usageEligibility === "disabled") return null;

  const refreshing = summary.operation === "refreshing";
  const syncedAt = summary.history.syncedAt;
  const formattedSyncedAt = syncedAt
    ? formatAccountSyncedAt(syncedAt, locale)
    : null;

  return (
    <div className="settings-group">
      <h3 id="settings-account-usage-title" className="settings-group-label">
        {t("settings.account_usage")}
      </h3>
      <p className="settings-account-usage-scope">
        {t("settings.account_usage_scope")}
      </p>
      <div
        className="settings-account-usage"
        aria-labelledby="settings-account-usage-title"
      >
        {summary.usageEligibility === "unknown" ? (
          <div className="settings-account-usage-unknown" role="status">
            <Icon name="info" />
            <span>{t("settings.account_usage_mode_unknown")}</span>
          </div>
        ) : (
          <AccountUsageHeatmap history={summary.history} />
        )}

        <div className="settings-account-usage-footer">
          <span role="status">
            {refreshing
              ? t("settings.account_usage_refreshing")
              : formattedSyncedAt
                ? t("settings.account_usage_synced_at", {
                    value: formattedSyncedAt,
                  })
                : t("settings.account_usage_not_synced")}
          </span>
          <Button
            variant="secondary"
            size="sm"
            disabled={disabled || refreshing}
            onClick={onRefresh}
          >
            <span
              className="settings-account-usage-refresh-icon"
              data-refreshing={refreshing ? "true" : "false"}
            >
              <Icon name="refresh" />
            </span>
            {t("settings.account_usage_refresh")}
          </Button>
        </div>
      </div>
    </div>
  );
}
