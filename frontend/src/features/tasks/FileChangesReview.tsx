import { useEffect, useMemo, useRef } from "react";

import type {
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { parseUnifiedDiff, type UnifiedDiffRow } from "./unified-diff.ts";

export type FileChangesReviewState = {
  taskId: string;
  runId: string;
  observation: RunFileChanges["observation"];
  changes: FileChangeView[];
  selected: FileChangeView;
  phase: "loading" | "settled" | "failed";
  diff: FileChangeDiffResult | null;
};

type FileChangeGroup = {
  path: string;
  changes: FileChangeView[];
};

function groupChanges(changes: FileChangeView[]): FileChangeGroup[] {
  const groups = new Map<string, FileChangeView[]>();
  for (const change of changes) {
    const group = groups.get(change.displayPath);
    if (group) group.push(change);
    else groups.set(change.displayPath, [change]);
  }
  return [...groups].map(([path, grouped]) => ({ path, changes: grouped }));
}

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

function UnifiedDiff({ content }: { content: string }) {
  const { t } = useI18n();
  const rows = useMemo(() => parseUnifiedDiff(content), [content]);
  return (
    <div
      className="file-changes-review-code"
      role="table"
      aria-label={t("file_changes.diff.content")}
    >
      {rows.map((row, index) => (
        <DiffRow row={row} t={t} key={`${index}:${row.kind}`} />
      ))}
    </div>
  );
}

function ChangeIndex({
  changes,
  selected,
  onSelect,
}: {
  changes: FileChangeView[];
  selected: FileChangeView;
  onSelect: (change: FileChangeView) => void;
}) {
  const { t } = useI18n();
  const groups = groupChanges(changes);

  return (
    <nav
      className="file-changes-review-index"
      aria-label={t("file_changes.changed_files")}
    >
      {groups.map((group) => (
        <section className="file-changes-review-group" key={group.path}>
          <h3 title={group.path}>{group.path}</h3>
          {group.changes.map((change, index) => {
            const active = change.id === selected.id;
            return (
              <button
                key={change.id}
                type="button"
                className="file-changes-review-record focus-ring"
                aria-current={active ? "true" : undefined}
                aria-label={`${group.path} ${t(kindMessage(change.kind))}${
                  group.changes.length > 1
                    ? ` ${t("file_changes.change_index", { index: index + 1 })}`
                    : ""
                }`}
                onClick={() => onSelect(change)}
              >
                <Icon name="file-diff" />
                <span>
                  <strong className={kindColor(change.kind)}>
                    {t(kindMessage(change.kind))}
                    {change.status === "partial" &&
                      ` · ${t("file_changes.status.partial")}`}
                  </strong>
                  {change.fromDisplayPath && (
                    <small title={change.fromDisplayPath}>
                      {change.fromDisplayPath} → {change.displayPath}
                    </small>
                  )}
                  {group.changes.length > 1 && (
                    <small>
                      {t("file_changes.change_index", { index: index + 1 })}
                    </small>
                  )}
                </span>
              </button>
            );
          })}
        </section>
      ))}
    </nav>
  );
}

function RecordedDiff({
  state,
  onRetry,
}: {
  state: FileChangesReviewState;
  onRetry: () => void;
}) {
  const { t } = useI18n();
  const ready = state.phase === "settled" && state.diff?.status === "ready";
  const unavailable =
    state.phase === "settled" && state.diff?.status === "unavailable"
      ? state.diff
      : null;
  const retryable =
    state.phase === "failed" || unavailable?.reason === "capacity";

  return (
    <section
      className="file-changes-review-diff"
      aria-labelledby="file-changes-review-diff-title"
      aria-live="polite"
      aria-busy={state.phase === "loading"}
    >
      <header className="file-changes-review-diff-header">
        <span className="file-changes-review-eyebrow">
          <Icon name="file-diff" />
          {t("file_changes.recorded_diff")}
        </span>
        <h2
          id="file-changes-review-diff-title"
          title={state.selected.displayPath}
        >
          {state.selected.displayPath}
        </h2>
        {state.selected.fromDisplayPath && (
          <p title={state.selected.fromDisplayPath}>
            {state.selected.fromDisplayPath} → {state.selected.displayPath}
          </p>
        )}
        <div className="file-changes-review-meta">
          <span className={kindColor(state.selected.kind)}>
            {t(kindMessage(state.selected.kind))}
          </span>
          {state.selected.status === "partial" && (
            <span>{t("file_changes.status.partial")}</span>
          )}
          <span>{t("file_changes.recorded_notice")}</span>
        </div>
      </header>
      {state.observation === "incomplete" && (
        <div className="file-changes-review-warning" role="status">
          <Icon name="warning" />
          {t("file_changes.incomplete_notice")}
        </div>
      )}
      <div className="file-changes-review-diff-body">
        {state.phase === "loading" ? (
          <div className="file-changes-review-state">
            <span>
              <Icon name="loading" />
              {t("file_changes.loading")}
            </span>
          </div>
        ) : ready && state.diff?.status === "ready" ? (
          <>
            {(!state.diff.complete || state.diff.redacted) && (
              <div className="file-changes-review-flags">
                {!state.diff.complete && (
                  <span>{t("file_changes.diff.incomplete")}</span>
                )}
                {state.diff.redacted && (
                  <span>{t("file_changes.diff.redacted")}</span>
                )}
              </div>
            )}
            <UnifiedDiff content={state.diff.content} />
          </>
        ) : (
          <div className="file-changes-review-state">
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
                  onClick={onRetry}
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

export function FileChangesReview({
  state,
  onSelect,
  onRetry,
  onClose,
}: {
  state: FileChangesReviewState;
  onSelect: (change: FileChangeView) => void;
  onRetry: () => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const fileCount = new Set(state.changes.map((change) => change.displayPath))
    .size;

  useEffect(() => title.current?.focus(), []);

  return (
    <div
      id="file-changes-review"
      className="file-changes-review"
      role="dialog"
      aria-modal="true"
      aria-labelledby="file-changes-review-title"
      data-task-id={state.taskId}
      data-run-id={state.runId}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        event.preventDefault();
        event.stopPropagation();
        onClose();
      }}
    >
      <header className="file-changes-review-header">
        <div>
          <span className="file-changes-review-eyebrow">
            <Icon name="file-diff" />
            {t("file_changes.recorded_changes")}
          </span>
          <h1 id="file-changes-review-title" ref={title} tabIndex={-1}>
            {t("file_changes.review_title")}
          </h1>
          <p>
            {t("file_changes.summary", {
              fileCount,
              changeCount: state.changes.length,
            })}
          </p>
        </div>
        <button
          type="button"
          className="file-changes-review-close focus-ring"
          aria-label={t("file_changes.close")}
          onClick={onClose}
        >
          <Icon name="close" />
        </button>
      </header>
      <div className="file-changes-review-layout">
        <ChangeIndex
          changes={state.changes}
          selected={state.selected}
          onSelect={onSelect}
        />
        <RecordedDiff state={state} onRetry={onRetry} />
      </div>
    </div>
  );
}
