import { useEffect, useRef, useState } from "react";

import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Input } from "../../components/ui/input.tsx";
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
  const [activeIndex, setActiveIndex] = useState(0);
  const resolvedActiveIndex =
    results.length > 0 ? Math.min(activeIndex, results.length - 1) : 0;

  useEffect(() => setActiveIndex(0), [query, results.length]);
  useEffect(() => {
    if (open) input.current?.focus();
  }, [open]);

  return (
    <Dialog.Root
      open={open}
      onOpenChange={(nextOpen) => !nextOpen && onClose()}
    >
      <Dialog.Portal>
        <Dialog.Backdrop className="search-scrim" />
        <Dialog.Popup
          className="search-dialog top-[max(72px,10vh)] bottom-auto left-1/2 -translate-x-1/2 translate-y-0 max-h-[min(76vh,680px)] w-[min(620px,100%)] gap-0 overflow-hidden rounded-[16px] p-0"
          aria-labelledby="search-title"
          initialFocus={() => input.current ?? false}
        >
          <Dialog.Title id="search-title" className="sr-only">
            {t("search.title")}
          </Dialog.Title>
          <div className="search-input-row">
            <Icon name="search" />
            <Input
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
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
