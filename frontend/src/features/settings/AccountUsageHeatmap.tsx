import {
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type KeyboardEvent,
} from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { accountErrorText } from "../../i18n/account-error.ts";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { formatAccountDecimal } from "./account-summary-format.ts";

type History = AccountView["summary"]["history"];
type HistoryDay = History["days"][number];
type CalendarDay = HistoryDay & {
  column: number;
  row: number;
  level: number;
};

const narrowQuery = "(max-width: 619px)";

function subscribeNarrow(listener: () => void) {
  const query = window.matchMedia(narrowQuery);
  query.addEventListener("change", listener);
  return () => query.removeEventListener("change", listener);
}

function isNarrowSnapshot() {
  return window.matchMedia(narrowQuery).matches;
}

function serverNarrowSnapshot() {
  return false;
}

function dayNumber(date: string) {
  return Math.floor(Date.parse(`${date}T00:00:00Z`) / 86_400_000);
}

function calendarDate(day: number) {
  return new Date(day * 86_400_000).toISOString().slice(0, 10);
}

function mondayRow(date: string) {
  return (new Date(`${date}T12:00:00Z`).getUTCDay() + 6) % 7;
}

function emptyDay(date: string): HistoryDay {
  return {
    date,
    inputTokens: "0",
    outputTokens: "0",
    cacheCreationTokens: "0",
    cacheReadTokens: "0",
    totalTokens: "0",
    actualCostU: "0",
  };
}

function intensityLevels(days: HistoryDay[]) {
  const nonzero = days
    .map((day) => BigInt(day.totalTokens))
    .filter((value) => value > 0n)
    .sort((left, right) => (left < right ? -1 : left > right ? 1 : 0));
  if (nonzero.length === 0) return days.map(() => 0);
  const threshold = (fraction: number) =>
    nonzero[Math.floor((nonzero.length - 1) * fraction)]!;
  const thresholds = [threshold(0.25), threshold(0.5), threshold(0.75)];
  return days.map((day) => {
    const value = BigInt(day.totalTokens);
    if (value === 0n) return 0;
    if (value <= thresholds[0]!) return 1;
    if (value <= thresholds[1]!) return 2;
    if (value <= thresholds[2]!) return 3;
    return 4;
  });
}

export function buildUsageCalendar(history: History, visibleDays: number) {
  if (history.startDate === null || history.endDate === null) return [];
  const byDate = new Map(history.days.map((day) => [day.date, day]));
  const rangeStart = dayNumber(history.startDate);
  const rangeEnd = dayNumber(history.endDate);
  const visibleStart = Math.max(rangeStart, rangeEnd - visibleDays + 1);
  const days: HistoryDay[] = [];
  for (let day = visibleStart; day <= rangeEnd; day += 1) {
    const date = calendarDate(day);
    days.push(byDate.get(date) ?? emptyDay(date));
  }
  const leading = mondayRow(days[0]!.date);
  const levels = intensityLevels(days);
  return days.map<CalendarDay>((day, index) => ({
    ...day,
    column: Math.floor((leading + index) / 7) + 1,
    row: ((leading + index) % 7) + 1,
    level: levels[index]!,
  }));
}

function displayLocale(locale: Locale) {
  return locale === "pseudo" ? "en-US" : locale;
}

function formatDate(date: string, locale: Locale) {
  return new Intl.DateTimeFormat(displayLocale(locale), {
    month: "long",
    day: "numeric",
    weekday: "short",
    timeZone: "UTC",
  }).format(new Date(`${date}T12:00:00Z`));
}

function monthLabels(days: CalendarDay[], locale: Locale) {
  const labels: Array<{ column: number; label: string }> = [];
  const seen = new Set<string>();
  const occupiedColumns = new Set<number>();
  for (const day of days) {
    const month = day.date.slice(0, 7);
    if (seen.has(month)) continue;
    seen.add(month);
    if (occupiedColumns.has(day.column)) continue;
    occupiedColumns.add(day.column);
    labels.push({
      column: day.column,
      label: new Intl.DateTimeFormat(displayLocale(locale), {
        month: "short",
        timeZone: "UTC",
      }).format(new Date(`${day.date}T12:00:00Z`)),
    });
  }
  return labels;
}

function latestActiveDate(days: CalendarDay[]) {
  for (let index = days.length - 1; index >= 0; index -= 1) {
    if (days[index]!.totalTokens !== "0") return days[index]!.date;
  }
  return days.at(-1)?.date ?? null;
}

export function AccountUsageHeatmap({ history }: { history: History }) {
  const { locale, t } = useI18n();
  const narrow = useSyncExternalStore(
    subscribeNarrow,
    isNarrowSnapshot,
    serverNarrowSnapshot,
  );
  const visibleDays = narrow ? 91 : 365;
  const days = useMemo(
    () => buildUsageCalendar(history, visibleDays),
    [history, visibleDays],
  );
  const defaultDate = useMemo(() => latestActiveDate(days), [days]);
  const [selectedDate, setSelectedDate] = useState<string | null>(defaultDate);
  const dayRefs = useRef(new Map<string, HTMLButtonElement>());

  useEffect(() => {
    if (!selectedDate || !days.some((day) => day.date === selectedDate)) {
      setSelectedDate(defaultDate);
    }
  }, [days, defaultDate, selectedDate]);

  if (history.availability === "loading") {
    return (
      <section
        className="settings-account-heatmap"
        aria-labelledby="account-history-title"
      >
        <h4 id="account-history-title">
          {t("settings.account_history_title")}
        </h4>
        <p role="status">{t("settings.account_usage_syncing")}</p>
      </section>
    );
  }

  if (history.availability === "unavailable") {
    return (
      <section
        className="settings-account-heatmap"
        aria-labelledby="account-history-title"
      >
        <h4 id="account-history-title">
          {t("settings.account_history_title")}
        </h4>
        <p role={history.errorCode === "none" ? "status" : "alert"}>
          {history.safeDiagnostic ||
            (history.errorCode === "none"
              ? t("settings.account_usage_unavailable")
              : accountErrorText(history.errorCode, t))}
        </p>
      </section>
    );
  }

  const selected =
    days.find((day) => day.date === selectedDate) ?? days.at(-1) ?? null;
  const columns = days.at(-1)?.column ?? 1;
  const labels = monthLabels(days, locale);
  const gridStyle = { "--account-history-columns": columns } as CSSProperties;

  const moveFocus = (
    event: KeyboardEvent<HTMLButtonElement>,
    index: number,
  ) => {
    const offsets: Partial<Record<string, number>> = {
      ArrowLeft: -1,
      ArrowRight: 1,
      ArrowUp: -7,
      ArrowDown: 7,
    };
    const offset = offsets[event.key];
    if (offset === undefined) return;
    const target = days[index + offset];
    if (!target) return;
    event.preventDefault();
    setSelectedDate(target.date);
    dayRefs.current.get(target.date)?.focus();
  };

  return (
    <section
      className="settings-account-heatmap"
      data-availability={history.availability}
      aria-labelledby="account-history-title"
    >
      <header className="settings-account-heatmap-header">
        <div>
          <h4 id="account-history-title">
            {t("settings.account_history_title")}
          </h4>
          <p>
            {narrow
              ? t("settings.account_history_range_compact")
              : t("settings.account_history_range_year")}
          </p>
        </div>
        {history.availability === "stale" ? (
          <span className="settings-account-usage-stale" role="status">
            {t("settings.account_usage_stale")}
          </span>
        ) : null}
      </header>

      <div className="settings-account-calendar-wrap">
        <div className="settings-account-weekdays" aria-hidden="true">
          {t("settings.account_history_weekdays")
            .split("|")
            .map((weekday) => (
              <span key={weekday}>{weekday}</span>
            ))}
        </div>
        <div className="settings-account-calendar-main">
          <div
            className="settings-account-months"
            style={gridStyle}
            aria-hidden="true"
          >
            {labels.map((label) => (
              <span
                key={`${label.column}-${label.label}`}
                style={{ gridColumn: label.column }}
              >
                {label.label}
              </span>
            ))}
          </div>
          <div
            className="settings-account-calendar"
            style={gridStyle}
            role="grid"
            aria-label={t("settings.account_history_grid_label")}
            aria-rowcount={7}
            aria-colcount={columns}
          >
            {days.map((day, index) => (
              <button
                key={day.date}
                ref={(element) => {
                  if (element) dayRefs.current.set(day.date, element);
                  else dayRefs.current.delete(day.date);
                }}
                type="button"
                className="settings-account-calendar-day"
                data-level={day.level}
                data-selected={day.date === selected?.date ? "true" : "false"}
                role="gridcell"
                aria-rowindex={day.row}
                aria-colindex={day.column}
                aria-label={t("settings.account_history_day_label", {
                  date: formatDate(day.date, locale),
                  tokens: formatAccountDecimal(day.totalTokens),
                })}
                style={{ gridColumn: day.column, gridRow: day.row }}
                tabIndex={day.date === selected?.date ? 0 : -1}
                onMouseEnter={() => setSelectedDate(day.date)}
                onFocus={() => setSelectedDate(day.date)}
                onClick={() => setSelectedDate(day.date)}
                onKeyDown={(event) => moveFocus(event, index)}
              />
            ))}
          </div>
        </div>
      </div>

      <footer className="settings-account-calendar-footer">
        {selected ? (
          <p className="settings-account-calendar-detail" aria-live="polite">
            <strong>
              {t("settings.account_history_day_label", {
                date: formatDate(selected.date, locale),
                tokens: formatAccountDecimal(selected.totalTokens),
              })}
            </strong>
            <span>
              {t("settings.account_history_day_detail", {
                input: formatAccountDecimal(selected.inputTokens),
                output: formatAccountDecimal(selected.outputTokens),
                cacheCreation: formatAccountDecimal(
                  selected.cacheCreationTokens,
                ),
                cacheRead: formatAccountDecimal(selected.cacheReadTokens),
                cost: formatAccountDecimal(selected.actualCostU),
              })}
            </span>
          </p>
        ) : null}
        <div
          className="settings-account-calendar-legend"
          aria-label={t("settings.account_history_legend_label")}
        >
          <span>{t("settings.account_history_less")}</span>
          {[0, 1, 2, 3, 4].map((level) => (
            <i key={level} data-level={level} />
          ))}
          <span>{t("settings.account_history_more")}</span>
        </div>
      </footer>
    </section>
  );
}
