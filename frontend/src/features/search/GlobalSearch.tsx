import { useEffect, useRef, useState } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import type { SearchResult } from "../../workbench/selectors.ts";

export function GlobalSearch({
  open,
  query,
  results,
  onQuery,
  onClose,
  onSelect,
}: {
  open: boolean;
  query: string;
  results: SearchResult[];
  onQuery: (query: string) => void;
  onClose: () => void;
  onSelect: (result: SearchResult) => void;
}) {
  const { t } = useI18n();
  const input = useRef<HTMLInputElement>(null);
  const dialog = useRef<HTMLElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);
  const closeCallback = useRef(onClose);
  const [activeIndex, setActiveIndex] = useState(0);
  const resolvedActiveIndex =
    results.length > 0 ? Math.min(activeIndex, results.length - 1) : 0;

  useEffect(() => {
    closeCallback.current = onClose;
  }, [onClose]);
  useEffect(() => setActiveIndex(0), [query, results.length]);

  useEffect(() => {
    if (!open) return;
    previousFocus.current = document.activeElement as HTMLElement | null;
    input.current?.focus();
    const handleDialogKeys = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        closeCallback.current();
      }
      if (event.key !== "Tab") return;
      const focusable = dialog.current?.querySelectorAll<HTMLElement>(
        'input, button:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", handleDialogKeys);
    return () => {
      window.removeEventListener("keydown", handleDialogKeys);
      previousFocus.current?.focus();
      previousFocus.current = null;
    };
  }, [open]);

  if (!open) return null;
  return (
    <div className="search-scrim" role="presentation" onMouseDown={onClose}>
      <section
        ref={dialog}
        className="search-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="search-title"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <h2 id="search-title" className="sr-only">
          {t("search.title")}
        </h2>
        <div className="search-input-row">
          <Icon name="search" />
          <input
            ref={input}
            role="combobox"
            value={query}
            aria-label={t("search.title")}
            aria-autocomplete="list"
            aria-expanded="true"
            aria-controls="search-results"
            aria-activedescendant={
              results.length > 0
                ? `search-result-${resolvedActiveIndex}`
                : undefined
            }
            placeholder={t("search.placeholder")}
            onChange={(event) => onQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown" && results.length > 0) {
                event.preventDefault();
                setActiveIndex((index) => (index + 1) % results.length);
              } else if (event.key === "ArrowUp" && results.length > 0) {
                event.preventDefault();
                setActiveIndex(
                  (index) => (index - 1 + results.length) % results.length,
                );
              } else if (
                event.key === "Enter" &&
                results[resolvedActiveIndex]
              ) {
                event.preventDefault();
                onSelect(results[resolvedActiveIndex]);
              }
            }}
          />
          <kbd>esc</kbd>
        </div>
        <div id="search-results" className="search-results" role="listbox">
          {!query.trim() && <p>{t("search.hint")}</p>}
          {query.trim() && results.length === 0 && (
            <p>{t("search.no_results")}</p>
          )}
          {results.map((result, index) => (
            <button
              id={`search-result-${index}`}
              key={result.key}
              className="search-result focus-ring"
              role="option"
              tabIndex={-1}
              aria-selected={index === resolvedActiveIndex}
              data-active={index === resolvedActiveIndex}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => onSelect(result)}
            >
              <span className="search-result-kind">
                {t(`search.kind.${result.kind}`)}
              </span>
              <span className="search-result-copy">
                <strong>
                  {result.title || t("task.item", { id: result.taskId })}
                </strong>
                <small>{result.detail}</small>
              </span>
            </button>
          ))}
        </div>
      </section>
    </div>
  );
}
