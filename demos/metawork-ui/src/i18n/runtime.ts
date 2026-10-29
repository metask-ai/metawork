import { enUS, type MessageId } from "./messages/en-US.ts";
import { zhCN } from "./messages/zh-CN.ts";
import { pseudoLocalize } from "./pseudo-locale.ts";

export type Locale = "en-US" | "zh-CN" | "pseudo";
export type MessageValues = Record<string, string | number | bigint>;

export function initialLocale(
  stored: string | null | undefined,
  languages: readonly string[],
  allowPseudo = false,
): Locale {
  if (stored === "en-US" || stored === "zh-CN") return stored;
  if (allowPseudo && stored === "pseudo") return stored;
  return languages.some((language) => language.toLowerCase().startsWith("zh"))
    ? "zh-CN"
    : "en-US";
}

export function translate(
  locale: Locale,
  id: MessageId,
  values: MessageValues = {},
): string {
  const source = locale === "zh-CN" ? zhCN[id] : enUS[id];
  const message = locale === "pseudo" ? pseudoLocalize(source) : source;
  return message.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name: string) =>
    Object.hasOwn(values, name) ? String(values[name]) : match,
  );
}
