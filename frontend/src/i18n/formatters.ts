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

export function taskCountMessageId(
  locale: Locale,
  count: number,
): "task.count.one" | "task.count.other" {
  const rulesLocale = locale === "pseudo" ? "en-US" : locale;
  return new Intl.PluralRules(rulesLocale).select(count) === "one"
    ? "task.count.one"
    : "task.count.other";
}

export function formatMilliseconds(locale: string, milliseconds: bigint) {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(
    milliseconds,
  );
}
