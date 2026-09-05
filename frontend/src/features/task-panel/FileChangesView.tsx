import type {
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

export type FileChangeDiffViewState = {
  observation: RunFileChanges["observation"];
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

function diffLineColor(line: string): string {
  if (line.startsWith("+++") || line.startsWith("---"))
    return "text-(--ui-content-muted)";
  if (line.startsWith("+")) return "text-(--ui-content-success)";
  if (line.startsWith("-")) return "text-(--ui-content-error)";
  if (line.startsWith("@@")) return "text-(--ui-action-selected-content)";
  return "text-(--ui-content-primary)";
}

function unavailableMessage(
  reason: Extract<FileChangeDiffResult, { status: "unavailable" }>["reason"],
): MessageId {
  return `file_changes.diff.${reason}`;
}

export function FileChangesView({
  observation,
  changes,
  onSelect,
}: {
  observation: RunFileChanges["observation"];
  changes: FileChangeView[];
  onSelect: (change: FileChangeView) => void;
}) {
  const { t } = useI18n();
  const groups = groupChanges(changes);

  return (
    <section
      className="task-panel-review"
      aria-labelledby="task-panel-review-title"
    >
      <header className="task-panel-review-header">
        <span className="task-panel-resource-kind">
          <Icon name="file-diff" />
          {t("task_panel.recorded_changes")}
        </span>
        <h3 id="task-panel-review-title">{t("file_changes.review_title")}</h3>
        <p>{t("file_changes.recorded_notice")}</p>
      </header>
      {observation === "incomplete" && (
        <div className="task-panel-review-warning" role="status">
          <Icon name="warning" />
          {t("file_changes.incomplete_notice")}
        </div>
      )}
      <nav
        className="task-panel-change-list"
        aria-label={t("file_changes.changed_files")}
      >
        {groups.map((group) => (
          <div className="task-panel-change-group" key={group.path}>
            <p title={group.path}>{group.path}</p>
            {group.changes.map((change, index) => (
              <button
                key={change.id}
                type="button"
                className="focus-ring"
                aria-label={`${group.path} ${t(kindMessage(change.kind))}${
                  group.changes.length > 1
                    ? ` ${t("file_changes.change_index", { index: index + 1 })}`
                    : ""
                }`}
                onClick={() => onSelect(change)}
              >
                <span className={kindColor(change.kind)}>
                  {t(kindMessage(change.kind))}
                  {change.status === "partial" &&
                    ` · ${t("file_changes.status.partial")}`}
                </span>
                {group.changes.length > 1 && (
                  <small>
                    {t("file_changes.change_index", { index: index + 1 })}
                  </small>
                )}
                <Icon name="chevron-right" />
              </button>
            ))}
          </div>
        ))}
      </nav>
    </section>
  );
}

export function FileChangeDiffView({
  state,
  onRefresh,
}: {
  state: FileChangeDiffViewState;
  onRefresh: () => void;
}) {
  const { t } = useI18n();
  const ready = state.phase === "settled" && state.diff?.status === "ready";
  const unavailable =
    state.phase === "settled" && state.diff?.status === "unavailable"
      ? state.diff
      : null;

  return (
    <section
      className="task-panel-resource-view"
      aria-labelledby="task-panel-resource-title"
      aria-live="polite"
      aria-busy={state.phase === "loading"}
    >
      <header className="task-panel-resource-header">
        <div className="task-panel-resource-identity">
          <span className="task-panel-resource-kind">
            <Icon name="file-diff" />
            {t("task_panel.recorded_diff")}
          </span>
          <h3 id="task-panel-resource-title" title={state.selected.displayPath}>
            {state.selected.displayPath}
          </h3>
          {state.selected.fromDisplayPath && (
            <p title={state.selected.fromDisplayPath}>
              {state.selected.fromDisplayPath} → {state.selected.displayPath}
            </p>
          )}
        </div>
        {state.selected.diffAvailable && (
          <Button
            type="button"
            variant="secondary"
            size="sm"
            disabled={state.phase === "loading"}
            onClick={onRefresh}
          >
            <Icon name="refresh" />
            {t("file_changes.refresh")}
          </Button>
        )}
      </header>
      <p className="task-panel-resource-notice">
        <span className={kindColor(state.selected.kind)}>
          {t(kindMessage(state.selected.kind))}
          {state.selected.status === "partial" &&
            ` · ${t("file_changes.status.partial")}`}
        </span>
        <span>{t("file_changes.recorded_notice")}</span>
      </p>
      {state.observation === "incomplete" && (
        <div className="task-panel-review-warning" role="status">
          <Icon name="warning" />
          {t("file_changes.incomplete_notice")}
        </div>
      )}
      <div className="task-panel-resource-body">
        {state.phase === "loading" ? (
          <div className="task-panel-resource-state">
            <span>
              <Icon name="loading" />
              {t("file_changes.loading")}
            </span>
          </div>
        ) : ready && state.diff?.status === "ready" ? (
          <>
            {(!state.diff.complete || state.diff.redacted) && (
              <div className="task-panel-resource-flags">
                {!state.diff.complete && (
                  <span>{t("file_changes.diff.incomplete")}</span>
                )}
                {state.diff.redacted && (
                  <span>{t("file_changes.diff.redacted")}</span>
                )}
              </div>
            )}
            <pre className="task-panel-code task-panel-diff">
              {state.diff.content.split("\n").map((line, index) => (
                <span className={diffLineColor(line)} key={`${index}:${line}`}>
                  {line || " "}
                </span>
              ))}
            </pre>
          </>
        ) : (
          <div className="task-panel-resource-state">
            <div>
              <p>
                {state.phase === "failed"
                  ? t("file_changes.diff.error")
                  : unavailable
                    ? t(unavailableMessage(unavailable.reason))
                    : t("file_changes.diff.not_recorded")}
              </p>
              {state.selected.diffAvailable && (
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  onClick={onRefresh}
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
