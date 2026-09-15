import type { AccountView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { accountErrorText } from "../../i18n/account-error.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  formatAccountDecimal,
  formatAccountSyncedAt,
} from "./account-summary-format.ts";
import { AccountUsageHeatmap } from "./AccountUsageHeatmap.tsx";

type AccountSummary = AccountView["summary"];

function oldestSyncedAt(summary: AccountSummary) {
  const values = [
    summary.wallet.syncedAt,
    summary.usage.syncedAt,
    summary.history.syncedAt,
  ].filter((value): value is string => value !== null);
  return values.reduce<string | null>(
    (oldest, value) =>
      oldest === null || BigInt(value) < BigInt(oldest) ? value : oldest,
    null,
  );
}

function SummaryState({
  availability,
  errorCode,
  safeDiagnostic,
}: {
  availability: AccountSummary["wallet"]["availability"];
  errorCode: AccountSummary["wallet"]["errorCode"];
  safeDiagnostic: string;
}) {
  const { t } = useI18n();
  if (availability === "loading") {
    return <span role="status">{t("settings.account_usage_syncing")}</span>;
  }
  if (availability === "stale") {
    return (
      <span className="settings-account-usage-stale" role="status">
        {t("settings.account_usage_stale")}
      </span>
    );
  }
  if (availability === "unavailable") {
    return (
      <span role={errorCode === "none" ? "status" : "alert"}>
        {safeDiagnostic ||
          (errorCode === "none"
            ? t("settings.account_usage_unavailable")
            : accountErrorText(errorCode, t))}
      </span>
    );
  }
  return null;
}

export function AccountBalance({
  wallet,
  disabled,
  onRecharge,
}: {
  wallet: AccountSummary["wallet"];
  disabled: boolean;
  onRecharge: () => void;
}) {
  const { t } = useI18n();
  const ready =
    (wallet.availability === "ready" || wallet.availability === "stale") &&
    wallet.balanceU !== null;

  return (
    <div className="settings-identity-wallet">
      <div
        className="settings-identity-balance"
        data-availability={wallet.availability}
      >
        <span className="settings-identity-balance-label">
          {t("settings.account_usage_balance")}
        </span>
        {ready ? (
          <strong>
            {t("settings.account_usage_cost", {
              value: formatAccountDecimal(wallet.balanceU!),
            })}
          </strong>
        ) : (
          <strong aria-label={t("settings.account_usage_unavailable")}>—</strong>
        )}
        <SummaryState {...wallet} />
      </div>
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
  const syncedAt = oldestSyncedAt(summary);
  const formattedSyncedAt = syncedAt
    ? formatAccountSyncedAt(syncedAt, locale)
    : null;
  const usageReady =
    (summary.usage.availability === "ready" ||
      summary.usage.availability === "stale") &&
    summary.usage.total !== null;

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
          <>
            <div
              className="settings-account-usage-row"
              data-availability={summary.usage.availability}
            >
              <div className="settings-account-usage-copy">
                <span>{t("settings.account_usage_total")}</span>
                {usageReady ? <SummaryState {...summary.usage} /> : null}
              </div>
              <div className="settings-account-usage-values">
                {usageReady ? (
                  <>
                    <strong>
                      {t("settings.account_usage_tokens", {
                        value: formatAccountDecimal(
                          summary.usage.total!.totalTokens,
                        ),
                      })}
                    </strong>
                    <span>
                      {t("settings.account_usage_cost", {
                        value: formatAccountDecimal(
                          summary.usage.total!.actualCostU,
                        ),
                      })}
                    </span>
                  </>
                ) : (
                  <strong aria-label={t("settings.account_usage_unavailable")}>
                    —
                  </strong>
                )}
              </div>
            </div>

            <AccountUsageHeatmap history={summary.history} />
          </>
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
