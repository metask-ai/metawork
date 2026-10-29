import type { Locale } from "./runtime.ts";

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
