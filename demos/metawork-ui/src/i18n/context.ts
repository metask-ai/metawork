import { createContext, useContext } from "react";

import type { MessageId } from "./messages/en-US.ts";
import type { Locale, MessageValues } from "./runtime.ts";

export type I18nValue = {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: (id: MessageId, values?: MessageValues) => string;
};

export const I18nContext = createContext<I18nValue | null>(null);

export function useI18n(): I18nValue {
  const value = useContext(I18nContext);
  if (!value) throw new Error("useI18n must be used inside I18nProvider");
  return value;
}

export type { Locale, MessageId };
