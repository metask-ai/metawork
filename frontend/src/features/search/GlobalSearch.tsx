import { useEffect, useLayoutEffect, useRef, useState } from "react";

import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Input } from "../../components/ui/input.tsx";
import { controlFocus } from "../../components/ui/utils.ts";
import { useI18n } from "../../i18n/context.ts";
import { isInputMethodKey } from "../../platform/keyboard.ts";
import type { SearchResult } from "../../workbench/selectors.ts";

export function GlobalSearch({
  open,
  query,
  results,
  loading,
  hasMore,
  selectionUnavailable,
  onClosed,
  onMore,
  onFirst,
  onQuery,
  onClose,
  onSelect,
}: {
  open: boolean;
  query: string;
  results: SearchResult[];
  loading?: boolean;
  hasMore?: boolean;
  selectionUnavailable?: boolean;
  onClosed?: () => void;
  onMore?: () => void;
  onFirst?: () => void;
  onQuery: (query: string) => void;
  onClose: () => void;
  onSelect: (result: SearchResult) => void;
}) {
  const { t } = useI18n();
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const composing = useRef(false);
  const [active, setActive] = useState<{ query: string; key: string } | null>(
    null,
  );
  const matchingIndex =
    active?.query === query
      ? results.findIndex((result) => result.key === active.key)
      : -1;
  const activeIndex = Math.max(matchingIndex, 0);
  const activeResult = results[activeIndex];

  useEffect(() => {
    if (active && (!open || matchingIndex < 0)) setActive(null);
    if (!open) composing.current = false;
  }, [active, matchingIndex, open]);

  useLayoutEffect(() => {
    const container = list.current;
    const option = container?.children.item(activeIndex);
    if (!open || !container || !option) return;
    const viewport = container.getBoundingClientRect();
    const row = option.getBoundingClientRect();
    if (row.top < viewport.top) container.scrollTop += row.top - viewport.top;
    else if (row.bottom > viewport.bottom)
      container.scrollTop += row.bottom - viewport.bottom;
  }, [activeIndex, activeResult?.key, open]);

  return (
    <Dialog.Root
      open={open}
      onOpenChange={(nextOpen) => !nextOpen && onClose()}
      onOpenChangeComplete={(nextOpen) => !nextOpen && onClosed?.()}
    >
      <Dialog.Portal>
        <Dialog.Backdrop className="search-scrim" />
        <Dialog.Popup
          className="search-dialog top-[max(72px,10vh)] bottom-auto left-1/2 -translate-x-1/2 translate-y-0 max-h-[min(76vh,680px)] w-[min(620px,100%)] gap-0 overflow-hidden rounded-[16px] p-0"
          aria-labelledby="search-title"
          initialFocus={() => input.current ?? false}
          finalFocus={onClosed ? false : undefined}
        >
          <Dialog.Title id="search-title" className="sr-only">
            {t("search.title")}
          </Dialog.Title>
          <div className="search-input-row">
            <div className={`search-query ${controlFocus}`}>
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
                  activeResult ? `search-result-${activeIndex}` : undefined
                }
                placeholder={t("search.placeholder")}
                onChange={(event) => onQuery(event.target.value)}
                onCompositionStart={() => (composing.current = true)}
                onCompositionEnd={() => (composing.current = false)}
                onBlur={() => (composing.current = false)}
                onKeyDown={(event) => {
                  if (
                    event.defaultPrevented ||
                    isInputMethodKey(event.nativeEvent, composing.current) ||
                    event.altKey ||
                    event.ctrlKey ||
                    event.metaKey ||
                    event.shiftKey ||
                    !activeResult
                  )
                    return;
                  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                    event.preventDefault();
                    const step = event.key === "ArrowDown" ? 1 : -1;
                    const next =
                      (activeIndex + step + results.length) % results.length;
                    setActive({ query, key: results[next].key });
                  } else if (event.key === "Enter") {
                    event.preventDefault();
                    onSelect(activeResult);
                  }
                }}
              />
            </div>
            <Dialog.Close
              className="icon-button"
              aria-label={t("common.close")}
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          <div className="search-status" role="status">
            {selectionUnavailable && <p>{t("search.result_unavailable")}</p>}
            {!query.trim() && <p>{t("search.hint")}</p>}
            {query.trim() && !loading && results.length === 0 && !hasMore && (
              <p>{t(onFirst ? "search.no_more" : "search.no_results")}</p>
            )}
            {loading && <p>{t("search.loading")}</p>}
          </div>
          <div
            ref={list}
            id="search-results"
            className="search-results"
            role="listbox"
            aria-label={t("search.title")}
            tabIndex={-1}
            hidden={results.length === 0}
          >
            {results.map((result, index) => (
              <button
                id={`search-result-${index}`}
                key={result.key}
                className="search-result focus-ring"
                role="option"
                tabIndex={-1}
                aria-selected={index === activeIndex}
                data-active={index === activeIndex}
                onClick={() => onSelect(result)}
              >
                <span className="search-result-kind">
                  {t(`search.kind.${result.kind}`)}
                </span>
                <span className="search-result-copy">
                  <strong>
                    {result.title || t("task.item", { id: result.taskId })}
                  </strong>
                  {result.archived && (
                    <span className="search-archived-label">
                      {t("task.archived")}
                    </span>
                  )}
                  <small>{result.detail}</small>
                </span>
              </button>
            ))}
          </div>
          {(hasMore || onFirst) && (
            <div className="flex gap-3 px-4 py-3">
              {hasMore && (
                <button
                  type="button"
                  className="focus-ring"
                  disabled={loading}
                  onClick={onMore}
                >
                  {t("search.more")}
                </button>
              )}
              {onFirst && (
                <button type="button" className="focus-ring" onClick={onFirst}>
                  {t("search.first")}
                </button>
              )}
            </div>
          )}
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
