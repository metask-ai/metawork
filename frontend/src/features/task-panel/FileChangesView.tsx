import { useEffect, useMemo, useRef, useState } from "react";

import type {
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { parseUnifiedDiff, type UnifiedDiffRow } from "./unified-diff.ts";

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

function kindLetter(kind: FileChangeView["kind"]): "A" | "M" | "D" | "R" {
  switch (kind) {
    case "created":
      return "A";
    case "modified":
      return "M";
    case "deleted":
      return "D";
    case "moved":
      return "R";
  }
}

function unavailableMessage(
  reason: Extract<FileChangeDiffResult, { status: "unavailable" }>["reason"],
): MessageId {
  return `file_changes.diff.${reason}`;
}

type Translate = ReturnType<typeof useI18n>["t"];

function DiffRow({ row, t }: { row: UnifiedDiffRow; t: Translate }) {
  if (row.kind === "hunk") return null;
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

type FileChangeGroup = {
  displayPath: string;
  changes: FileChangeView[];
};

function groupFileChanges(changes: FileChangeView[]): FileChangeGroup[] {
  const groups = new Map<string, FileChangeGroup>();
  for (const change of changes) {
    const group = groups.get(change.displayPath);
    if (group) group.changes.push(change);
    else
      groups.set(change.displayPath, {
        displayPath: change.displayPath,
        changes: [change],
      });
  }
  return [...groups.values()];
}

function groupedKind(changes: FileChangeView[]): FileChangeView["kind"] {
  const first = changes[0]!;
  const last = changes.at(-1)!;
  if (last.kind === "deleted") return "deleted";
  if (first.kind === "created") return "created";
  if (changes.some((change) => change.kind === "moved")) return "moved";
  return "modified";
}

function RecordedFileSection({
  group,
  index,
  diffs,
  onLoad,
}: {
  group: FileChangeGroup;
  index: number;
  diffs: Record<string, FileChangeDiffViewState>;
  onLoad: (change: FileChangeView) => void;
}) {
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(true);
  const records = group.changes.map((change) => ({
    change,
    state: diffs[change.id] ?? ({ phase: "idle", diff: null } as const),
  }));
  const loading = records.some(({ state }) => state.phase === "loading");
  const nextIdle = loading
    ? undefined
    : records.find(({ state }) => state.phase === "idle");
  const section = useLoadWhenVisible(
    expanded && nextIdle ? "idle" : "settled",
    () => {
      if (nextIdle) onLoad(nextIdle.change);
    },
  );
  const readyDiffs = records.flatMap(({ state }) =>
    state.phase === "settled" && state.diff.status === "ready"
      ? [state.diff]
      : [],
  );
  const rows = readyDiffs.flatMap((diff) => parseUnifiedDiff(diff.content));
  const additions = rows.filter((row) => row.kind === "addition").length;
  const deletions = rows.filter((row) => row.kind === "deletion").length;
  const failures = records.filter(
    ({ state }) =>
      state.phase === "failed" ||
      (state.phase === "settled" && state.diff.status === "unavailable"),
  );
  const retryable = failures.find(
    ({ state }) =>
      state.phase === "failed" ||
      (state.phase === "settled" &&
        state.diff.status === "unavailable" &&
        state.diff.reason === "capacity"),
  );
  const failureMessage = (() => {
    if (failures.length !== 1) return t("file_changes.diff.group_unavailable");
    const [{ state }] = failures;
    if (state.phase === "failed") return t("file_changes.diff.error");
    if (state.phase === "settled" && state.diff.status === "unavailable")
      return t(unavailableMessage(state.diff.reason));
    return t("file_changes.diff.group_unavailable");
  })();
  const kind = groupedKind(group.changes);
  const partial = group.changes.some((change) => change.status === "partial");
  const fromDisplayPath = group.changes.find(
    (change) => change.fromDisplayPath,
  )?.fromDisplayPath;
  const headingId = `file-change-heading-${index}`;
  const diffId = `file-change-diff-${index}`;
  const kindId = `file-change-kind-${index}`;
  const partialId = `file-change-partial-${index}`;

  return (
    <section
      ref={section}
      className="task-panel-change-section"
      data-change-id={group.changes[0]!.id}
      data-file-path={group.displayPath}
      aria-labelledby={headingId}
      aria-busy={loading}
    >
      <header className="task-panel-change-header">
        <button
          type="button"
          className="task-panel-change-toggle"
          aria-expanded={expanded}
          aria-controls={diffId}
          aria-labelledby={headingId}
          aria-describedby={`${kindId}${partial ? ` ${partialId}` : ""}`}
          onClick={() => setExpanded((current) => !current)}
        >
          <span
            id={kindId}
            className={`task-panel-change-kind ${kindColor(kind)}`}
            data-kind={kind}
          >
            <span aria-hidden="true">{kindLetter(kind)}</span>
            <span className="sr-only">{t(kindMessage(kind))}</span>
          </span>
          <span className="task-panel-change-identity">
            <span className="task-panel-change-title-line">
              <span
                id={headingId}
                className="task-panel-change-title"
                title={group.displayPath}
              >
                {group.displayPath}
              </span>
              {partial && (
                <span
                  id={partialId}
                  className="task-panel-change-partial"
                  title={t("file_changes.status.partial_warning")}
                >
                  <Icon name="warning" />
                  <span className="sr-only">
                    {t("file_changes.status.partial_warning")}
                  </span>
                </span>
              )}
            </span>
            {fromDisplayPath && (
              <small title={fromDisplayPath}>
                {fromDisplayPath} → {group.displayPath}
              </small>
            )}
          </span>
          {readyDiffs.length > 0 && (
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
          <span className="task-panel-change-chevron" aria-hidden="true">
            <Icon name="chevron" />
          </span>
        </button>
      </header>
      <div
        id={diffId}
        className="task-panel-change-diff"
        aria-live="polite"
        hidden={!expanded}
      >
        {readyDiffs.some((diff) => !diff.complete || diff.redacted) && (
          <div className="task-panel-resource-flags">
            {readyDiffs.some((diff) => !diff.complete) && (
              <span>{t("file_changes.diff.incomplete")}</span>
            )}
            {readyDiffs.some((diff) => diff.redacted) && (
              <span>{t("file_changes.diff.redacted")}</span>
            )}
          </div>
        )}
        {rows.length > 0 && <UnifiedDiff rows={rows} />}
        {loading ? (
          <div className="task-panel-change-state">
            <span>
              <Icon name="loading" />
              {t("file_changes.loading")}
            </span>
          </div>
        ) : nextIdle ? (
          <div className="task-panel-change-state">
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={() => onLoad(nextIdle.change)}
            >
              {t("file_changes.load_diff")}
            </Button>
          </div>
        ) : null}
        {failures.length > 0 && (
          <div className="task-panel-change-state">
            <div>
              <p>{failureMessage}</p>
              {retryable && (
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  onClick={() => onLoad(retryable.change)}
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
  const groups = useMemo(() => groupFileChanges(changes), [changes]);

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
        {groups.map((group, index) => (
          <RecordedFileSection
            key={group.displayPath}
            group={group}
            index={index}
            diffs={diffs}
            onLoad={onLoad}
          />
        ))}
      </div>
    </section>
  );
}
