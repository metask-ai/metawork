import type { TaskActionBlocker } from "../bridge/contracts.ts";
import type { MessageId } from "./context.ts";
import type { Locale } from "./runtime.ts";

const taskActionBlockerMessages: Record<TaskActionBlocker, MessageId> = {
  busy: "slash.disabled_task_busy",
  closing: "slash.disabled_task_busy",
  deleting: "operation.task_delete",
  history_read_only: "archive.history_read_only",
  no_history: "slash.disabled_no_history",
  unavailable: "slash.disabled_unavailable",
};

export function taskActionBlockerMessageId(blocker: TaskActionBlocker) {
  return taskActionBlockerMessages[blocker];
}

export function formatInteger(locale: string, value: bigint | number): string {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(
    value,
  );
}

const sizeUnits = ["B", "KB", "MB", "GB", "TB"];

/** A file size in powers of 1024 with one decimal, as file managers show it. */
export function formatFileSize(locale: string, bytes: string): string {
  let value = Number(bytes);
  let unit = 0;
  // The next unit starts where one decimal would already read as 1024.0.
  while (value >= 1023.95 && unit < sizeUnits.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = unit === 0 ? 0 : 1;
  return `${new Intl.NumberFormat(locale, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value)} ${sizeUnits[unit]}`;
}

export function taskCountMessageId(
  locale: Locale,
  count: number,
): "task.count.one" | "task.count.other" {
  const rulesLocale = locale === "pseudo" ? "en-US" : locale;
  return new Intl.PluralRules(rulesLocale).select(count) === "one"
    ? "task.count.one"
    : "task.count.other";
}

export function signOutStopsMessageId(
  locale: Locale,
  count: number,
): "account.logout_stops_tasks.one" | "account.logout_stops_tasks.other" {
  const rulesLocale = locale === "pseudo" ? "en-US" : locale;
  return new Intl.PluralRules(rulesLocale).select(count) === "one"
    ? "account.logout_stops_tasks.one"
    : "account.logout_stops_tasks.other";
}

export function formatMilliseconds(locale: string, milliseconds: bigint) {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(
    milliseconds,
  );
}
