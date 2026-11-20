import {
  memo,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type KeyboardEvent,
} from "react";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";
import {
  railKeyTarget,
  railScrollForRow,
  sameRailEntries,
  type RailEntry,
  type RailPosition,
} from "./conversation-rail.ts";
import { formatRunTimestamp } from "./run-presentation.ts";

/** Fixed row pitch and the padding before the first row; CSS owns the same. */
export const railRowHeight = 10;
const railInset = 8;

type ConversationRailProps = {
  entries: readonly RailEntry[];
  position: RailPosition;
  /** Index of the oldest loaded Run; rows before it need history first. */
  loadedFrom: number;
  /** Whether rows before `loadedFrom` can ask for history now. */
  canLoad: boolean;
  pendingRunId: string | null;
  onJump: (runId: string) => void;
};

/**
 * One row per projected Run, fixed height, scrolling inside its own bounded
 * column. A single listbox stop: arrows move a highlighted row, Enter jumps.
 */
function ConversationRailView({
  entries,
  position,
  loadedFrom,
  canLoad,
  pendingRunId,
  onJump,
}: ConversationRailProps) {
  const { locale, t } = useI18n();
  const baseId = useId();
  const list = useRef<HTMLDivElement>(null);
  const pressed = useRef(false);
  const current = useSyncExternalStore(position.subscribe, position.get);
  const currentIndex = entries.findIndex((entry) => entry.runId === current);
  const [active, setActive] = useState<number | null>(null);
  const [hover, setHover] = useState<number | null>(null);
  const [keyboardTip, setKeyboardTip] = useState(false);
  const jumpable = (index: number) => canLoad || index >= loadedFrom;
  const optionId = (index: number) => `${baseId}-run-${entries[index]!.runId}`;

  const reveal = (index: number) => {
    const node = list.current;
    if (!node || index < 0) return;
    const next = railScrollForRow(index, {
      rowHeight: railRowHeight,
      inset: railInset,
      viewHeight: node.clientHeight,
      scrollTop: node.scrollTop,
    });
    if (next !== null) node.scrollTop = next;
  };
  const markOverflow = () => {
    const node = list.current;
    if (!node) return;
    node.dataset.fadeTop = String(node.scrollTop > 0);
    node.dataset.fadeBottom = String(
      node.scrollTop + node.clientHeight < node.scrollHeight - 1,
    );
  };
  // The reading position keeps its row in view inside the rail.
  useLayoutEffect(() => {
    reveal(currentIndex);
    markOverflow();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentIndex, entries.length]);
  useLayoutEffect(() => {
    if (active !== null) reveal(active);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active]);
  useEffect(() => {
    const node = list.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(markOverflow);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  // A row that disappeared (an edit replaced its Run) takes its highlight.
  useEffect(() => {
    if (active !== null && active >= entries.length) setActive(null);
    if (hover !== null && hover >= entries.length) setHover(null);
  }, [active, hover, entries.length]);

  const tipIndex = hover ?? (keyboardTip ? active : null);
  const tipEntry = tipIndex === null ? undefined : entries[tipIndex];
  // The popup stays mounted and keeps its last row while it animates closed.
  const shownTip = useRef<{ index: number; entry: RailEntry } | null>(null);
  if (tipIndex !== null && tipEntry)
    shownTip.current = { index: tipIndex, entry: tipEntry };
  const tip = shownTip.current;
  // The tooltip follows its row as an element: a function anchor is read
  // once when the popup mounts, so moving between rows would leave it behind.
  const tipRow = tip?.index ?? null;
  const [tipAnchor, setTipAnchor] = useState<Element | null>(null);
  useLayoutEffect(() => {
    setTipAnchor(
      tipRow === null
        ? null
        : (list.current?.querySelector(`[data-rail-index="${tipRow}"]`) ??
            null),
    );
  }, [tipRow, entries.length]);
  const time = (entry: RailEntry) =>
    formatRunTimestamp(locale, entry.submittedAtUnixMs, Date.now())?.absolute ??
    null;
  // Every row's accessible name formats a date. The rail re-renders on each
  // history page while its rows stay the same, so names are kept until the
  // rows or the locale change rather than rebuilt for hundreds of rows a page.
  const names = useRef<{
    entries: readonly RailEntry[];
    locale: string;
    labels: string[];
  } | null>(null);
  if (
    names.current === null ||
    names.current.locale !== locale ||
    !sameRailEntries(names.current.entries, entries)
  )
    names.current = {
      entries,
      locale,
      labels: entries.map((entry) =>
        [
          t("task.rail.turn", { turn: String(entry.turn) }),
          time(entry),
          entry.excerpt ?? t("privacy.sensitive_hidden"),
        ]
          .filter(Boolean)
          .join(t("task.rail.separator")),
      ),
    };
  const labels = names.current.labels;

  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.altKey || event.ctrlKey || event.metaKey) return;
    const from =
      active ?? (currentIndex >= 0 ? currentIndex : entries.length - 1);
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      const entry = entries[from];
      if (entry && jumpable(from)) onJump(entry.runId);
      return;
    }
    if (event.key === "Escape") {
      if (keyboardTip) {
        event.preventDefault();
        setKeyboardTip(false);
      }
      return;
    }
    const next = railKeyTarget(event.key, from, entries.length);
    if (next === null) return;
    event.preventDefault();
    setActive(next);
    setKeyboardTip(true);
  }

  return (
    <>
      <div
        ref={list}
        role="listbox"
        tabIndex={0}
        aria-label={t("task.rail.label")}
        aria-activedescendant={
          entries.length
            ? optionId(
                active ??
                  (currentIndex >= 0 ? currentIndex : entries.length - 1),
              )
            : undefined
        }
        className="conversation-rail"
        onScroll={markOverflow}
        onKeyDown={onKeyDown}
        onPointerDown={() => {
          pressed.current = true;
        }}
        onFocus={(event) => {
          if (event.target !== event.currentTarget) return;
          const byPointer = pressed.current;
          pressed.current = false;
          // A press focuses the rail on its way to a click: highlighting the
          // reading row then would scroll a long rail out from under the
          // pointer before the click lands. Only keyboard focus highlights.
          if (byPointer) return;
          setActive(currentIndex >= 0 ? currentIndex : entries.length - 1);
          setKeyboardTip(true);
        }}
        onBlur={() => {
          pressed.current = false;
          setActive(null);
          setKeyboardTip(false);
        }}
        onPointerMove={(event) => {
          const row = (event.target as Element).closest<HTMLElement>(
            "[data-rail-index]",
          );
          setHover(row ? Number(row.dataset.railIndex) : null);
        }}
        onPointerLeave={() => setHover(null)}
      >
        {entries.map((entry, index) => (
          <div
            key={entry.runId}
            id={optionId(index)}
            role="option"
            aria-label={labels[index]}
            aria-selected={index === currentIndex}
            aria-disabled={jumpable(index) ? undefined : true}
            className="conversation-rail-row"
            data-rail-index={index}
            data-current={index === currentIndex || undefined}
            data-active={index === active || index === hover || undefined}
            data-pending={entry.runId === pendingRunId || undefined}
            onClick={() => {
              if (jumpable(index)) onJump(entry.runId);
            }}
          >
            <span className="conversation-rail-tick" aria-hidden="true" />
          </div>
        ))}
      </div>
      <Tooltip.Root open={tipEntry !== undefined}>
        <Tooltip.Portal>
          <Tooltip.Positioner side="right" anchor={tipAnchor}>
            <Tooltip.Popup className="conversation-rail-tip">
              {tip && (
                <>
                  <span
                    className="conversation-rail-tip-excerpt"
                    data-withheld={tip.entry.excerpt === null || undefined}
                  >
                    {tip.entry.excerpt ?? t("privacy.sensitive_hidden")}
                  </span>
                  <span className="conversation-rail-tip-meta">
                    {[
                      t("task.rail.turn", { turn: String(tip.entry.turn) }),
                      time(tip.entry),
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                </>
              )}
            </Tooltip.Popup>
          </Tooltip.Positioner>
        </Tooltip.Portal>
      </Tooltip.Root>
    </>
  );
}

export const ConversationRail = memo(
  ConversationRailView,
  (previous, next) =>
    previous.position === next.position &&
    previous.loadedFrom === next.loadedFrom &&
    previous.canLoad === next.canLoad &&
    previous.pendingRunId === next.pendingRunId &&
    previous.onJump === next.onJump &&
    sameRailEntries(previous.entries, next.entries),
);
