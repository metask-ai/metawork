import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

import {
  readLocalPreference,
  writeLocalPreference,
} from "../platform/local-preferences.ts";
import { I18nContext, type I18nValue } from "./context.ts";
import { initialLocale, translate, type Locale } from "./runtime.ts";

const storageKey = "metawork.locale";
const allowPseudoLocale = import.meta.env.DEV;

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, updateLocale] = useState<Locale>(() =>
    initialLocale(
      readLocalPreference(storageKey),
      typeof navigator === "undefined" ? [] : navigator.languages,
      allowPseudoLocale,
    ),
  );
  useEffect(() => {
    document.documentElement.lang = locale === "pseudo" ? "en-XA" : locale;
  }, [locale]);
  const setLocale = useCallback((next: Locale) => {
    updateLocale(next);
    writeLocalPreference(storageKey, next);
  }, []);
  const value = useMemo<I18nValue>(
    () => ({
      locale,
      setLocale,
      t: (id, values) => translate(locale, id, values),
    }),
    [locale, setLocale],
  );
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}
