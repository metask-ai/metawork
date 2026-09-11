import { useEffect, useMemo, useRef } from "react";

import type {
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import {
  parseUnifiedDiff,
  type UnifiedDiffRow,
} from "../tasks/unified-diff.ts";

export type FileChangeDiffViewState =
  | { phase: "idle"; diff: null }
  | { phase: "loading"; diff: null }
  | { phase: "settled"; diff: FileChangeDiffResult }
  | { phase: "failed"; diff: null };

function kindMessage(kind: FileChangeView["kind"]): MessageId {
  return `file_changes.kind.${kind}`;
}

function kindColor(kind: FileChangeView["kind"]): string {
  switch (kind) {
    case "created":
      return "text-(--ui-content-success)";
    case "deleted":
      return "text-(--ui-content-error)";
    case "modified":
      return "text-(--ui-action-selected-content)";
    case "moved":
      return "text-(--ui-content-muted)";
  }
}

function unavailableMessage(
  reason: Extract<FileChangeDiffResult, { status: "unavailable" }>["reason"],
): MessageId {
  return `file_changes.diff.${reason}`;
}

type Translate = ReturnType<typeof useI18n>["t"];

function DiffRow({ row, t }: { row: UnifiedDiffRow; t: Translate }) {
  if (row.kind === "gap")
    return (
      <div className="file-changes-diff-row" data-kind="gap" role="row">
        <span role="cell">
          {t("file_changes.diff.unchanged_lines", { count: row.count })}
        </span>
      </div>
    );
  if (
    row.kind === "metadata" ||
    row.kind === "hunk" ||
    row.kind === "no-newline" ||
    row.kind === "raw"
  )
    return (
      <div className="file-changes-diff-row" data-kind={row.kind} role="row">
        <code role="cell">{row.text || " "}</code>
      </div>
    );
  return (
    <div className="file-changes-diff-row" data-kind={row.kind} role="row">
      <span
        className="file-changes-diff-line-number"
        role="cell"
        aria-label={
          row.oldLine === null
            ? undefined
            : t("file_changes.diff.old_line", { line: row.oldLine })
        }
      >
        {row.oldLine ?? ""}
      </span>
      <span
        className="file-changes-diff-line-number"
        role="cell"
        aria-label={
          row.newLine === null
            ? undefined
            : t("file_changes.diff.new_line", { line: row.newLine })
        }
      >
        {row.newLine ?? ""}
      </span>
      <code role="cell">{row.text || " "}</code>
    </div>
  );
}

function UnifiedDiff({ rows }: { rows: UnifiedDiffRow[] }) {
  const { t } = useI18n();
  return (
    <div
      className="task-panel-unified-diff"
      role="table"
      aria-label={t("file_changes.diff.content")}
    >
      {rows.map((row, index) => (
        <DiffRow row={row} t={t} key={`${index}:${row.kind}`} />
      ))}
    </div>
  );
}

function useLoadWhenVisible(
  phase: FileChangeDiffViewState["phase"],
  onLoad: () => void,
) {
  const section = useRef<HTMLElement | null>(null);
  const load = useRef(onLoad);
  load.current = onLoad;

  useEffect(() => {
    const element = section.current;
    if (phase !== "idle" || !element || !window.IntersectionObserver) return;
    const root = element.closest(".task-panel-review");
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        observer.disconnect();
        load.current();
      },
      { root, rootMargin: "240px 0px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [phase]);

  return section;
}

function RecordedDiffSection({
  change,
  index,
  repeatIndex,
  repeatCount,
  state,
  onLoad,
}: {
  change: FileChangeView;
  index: number;
  repeatIndex: number;
  repeatCount: number;
  state: FileChangeDiffViewState;
  onLoad: () => void;
}) {
  const { t } = useI18n();
  const section = useLoadWhenVisible(state.phase, onLoad);
  const readyDiff =
    state.phase === "settled" && state.diff.status === "ready"
      ? state.diff
      : null;
  const rows = useMemo(
    () => (readyDiff ? parseUnifiedDiff(readyDiff.content) : []),
    [readyDiff],
  );
  const additions = rows.filter((row) => row.kind === "addition").length;
  const deletions = rows.filter((row) => row.kind === "deletion").length;
  const unavailable =
    state.phase === "settled" && state.diff.status === "unavailable"
      ? state.diff
      : null;
  const retryable =
    state.phase === "failed" || unavailable?.reason === "capacity";
  const headingId = `file-change-heading-${index}`;

  return (
    <section
      ref={section}
      className="task-panel-change-section"
      data-change-id={change.id}
      aria-labelledby={headingId}
      aria-busy={state.phase === "loading"}
    >
      <header className="task-panel-change-header">
        <div className="task-panel-change-identity">
          <h4 id={headingId} title={change.displayPath}>
            {change.displayPath}
          </h4>
          {change.fromDisplayPath && (
            <small title={change.fromDisplayPath}>
              {change.fromDisplayPath} → {change.displayPath}
            </small>
          )}
        </div>
        <div className="task-panel-change-meta">
          <span className={kindColor(change.kind)}>
            {t(kindMessage(change.kind))}
            {change.status === "partial" &&
              ` · ${t("file_changes.status.partial")}`}
          </span>
          {repeatCount > 1 && (
            <span>
              {t("file_changes.change_index", { index: repeatIndex })}
            </span>
          )}
          {readyDiff && (
            <span
              className="task-panel-change-stats"
              aria-label={t("file_changes.diff.stats", {
                additions,
                deletions,
              })}
            >
              <span>+{additions}</span>
              <span>−{deletions}</span>
            </span>
          )}
        </div>
      </header>
      <div className="task-panel-change-diff" aria-live="polite">
        {state.phase === "idle" ? (
          <div className="task-panel-change-state">
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={onLoad}
            >
              {t("file_changes.load_diff")}
            </Button>
          </div>
        ) : state.phase === "loading" ? (
          <div className="task-panel-change-state">
            <span>
              <Icon name="loading" />
              {t("file_changes.loading")}
            </span>
          </div>
        ) : readyDiff ? (
          <>
            {(!readyDiff.complete || readyDiff.redacted) && (
              <div className="task-panel-resource-flags">
                {!readyDiff.complete && (
                  <span>{t("file_changes.diff.incomplete")}</span>
                )}
                {readyDiff.redacted && (
                  <span>{t("file_changes.diff.redacted")}</span>
                )}
              </div>
            )}
            <UnifiedDiff rows={rows} />
          </>
        ) : (
          <div className="task-panel-change-state">
            <div>
              <p>
                {state.phase === "failed"
                  ? t("file_changes.diff.error")
                  : unavailable
                    ? t(unavailableMessage(unavailable.reason))
                    : t("file_changes.diff.not_recorded")}
              </p>
              {retryable && (
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  onClick={onLoad}
                >
                  {t("file_changes.retry")}
                </Button>
              )}
            </div>
          </div>
        )}
      </div>
    </section>
  );
}

export function FileChangesView({
  observation,
  changes,
  diffs,
  onLoad,
}: {
  observation: RunFileChanges["observation"];
  changes: FileChangeView[];
  diffs: Record<string, FileChangeDiffViewState>;
  onLoad: (change: FileChangeView) => void;
}) {
  const { t } = useI18n();
  const repeatCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const change of changes)
      counts.set(change.displayPath, (counts.get(change.displayPath) ?? 0) + 1);
    return counts;
  }, [changes]);
  const repeatIndexes = new Map<string, number>();

  return (
    <section
      className="task-panel-review"
      aria-label={t("file_changes.review")}
    >
      {observation === "incomplete" && (
        <div className="task-panel-review-warning" role="status">
          <Icon name="warning" />
          {t("file_changes.incomplete_notice")}
        </div>
      )}
      <div className="task-panel-review-document">
        {changes.map((change, index) => {
          const repeatIndex = (repeatIndexes.get(change.displayPath) ?? 0) + 1;
          repeatIndexes.set(change.displayPath, repeatIndex);
          return (
            <RecordedDiffSection
              key={change.id}
              change={change}
              index={index}
              repeatIndex={repeatIndex}
              repeatCount={repeatCounts.get(change.displayPath) ?? 1}
              state={diffs[change.id] ?? { phase: "idle", diff: null }}
              onLoad={() => onLoad(change)}
            />
          );
        })}
      </div>
    </section>
  );
}
