import type { Locale } from "../../i18n/context.ts";

export function formatAccountDecimal(value: string) {
  const [integer, fraction] = value.split(".");
  const negative = integer.startsWith("-");
  const digits = negative ? integer.slice(1) : integer;
  const grouped = digits.replace(/\B(?=(\d{3})+(?!\d))/gu, ",");
  return `${negative ? "−" : ""}${grouped}${fraction ? `.${fraction}` : ""}`;
}

export function formatAccountSyncedAt(value: string, locale: Locale) {
  try {
    const milliseconds = BigInt(value);
    if (milliseconds > 8_640_000_000_000_000n) return null;
    const date = new Date(Number(milliseconds));
    if (Number.isNaN(date.getTime())) return null;
    return new Intl.DateTimeFormat(locale, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  } catch {
    return null;
  }
}
