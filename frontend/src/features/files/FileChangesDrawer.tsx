import type {
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Drawer } from "../../components/ui/drawer.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

export type FileChangesDrawerState = {
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

export function FileChangesDrawer({
  state,
  onSelect,
  onRefresh,
  onClose,
}: {
  state: FileChangesDrawerState;
  onSelect: (change: FileChangeView) => void;
  onRefresh: () => void;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const groups = groupChanges(state.changes);
  const ready = state.phase === "settled" && state.diff?.status === "ready";
  const unavailable =
    state.phase === "settled" && state.diff?.status === "unavailable"
      ? state.diff
      : null;

  return (
    <Drawer.Root open onOpenChange={(open) => !open && onClose()}>
      <Drawer.Portal>
        <Drawer.Backdrop />
        <Drawer.Popup
          className="w-[min(980px,calc(100vw-28px))] bg-(--ui-surface-canvas) max-[620px]:w-full"
          aria-labelledby="file-changes-title"
          aria-describedby="file-changes-description"
        >
          <Drawer.Header className="items-center px-5 py-4">
            <div className="min-w-0">
              <Drawer.Title id="file-changes-title">
                {t("file_changes.review_title")}
              </Drawer.Title>
              <Drawer.Description
                id="file-changes-description"
                className="mt-1"
              >
                {t("file_changes.recorded_notice")}
              </Drawer.Description>
            </div>
            <Drawer.Close
              className="grid size-11 shrink-0 place-items-center rounded-lg text-(--ui-content-muted) hover:bg-(--ui-action-hover-surface) hover:text-(--ui-content-primary)"
              aria-label={t("file_changes.close")}
            >
              <Icon name="close" />
            </Drawer.Close>
          </Drawer.Header>

          {state.observation === "incomplete" && (
            <div
              className="flex items-center gap-2 border-b border-(--ui-border) px-5 py-3 text-xs text-(--ui-content-muted)"
              role="status"
            >
              <Icon name="warning" />
              {t("file_changes.incomplete_notice")}
            </div>
          )}

          <Drawer.Body className="min-h-0 overflow-hidden p-0">
            <div className="grid h-full min-h-0 grid-cols-[260px_minmax(0,1fr)] max-[620px]:grid-cols-1 max-[620px]:grid-rows-[minmax(160px,34vh)_minmax(0,1fr)]">
              <nav
                className="min-h-0 overflow-y-auto border-r border-(--ui-border) bg-(--ui-surface-panel) p-2 max-[620px]:border-r-0 max-[620px]:border-b"
                aria-label={t("file_changes.changed_files")}
              >
                {groups.map((group) => {
                  const groupSelected = group.changes.some(
                    (change) => change.id === state.selected.id,
                  );
                  return (
                    <div className="mb-1" key={group.path}>
                      <button
                        type="button"
                        className="focus-ring flex min-h-11 w-full items-center gap-2 rounded-lg px-3 py-2 text-left aria-current:bg-(--ui-action-selected-surface)"
                        aria-current={groupSelected ? "true" : undefined}
                        onClick={() => onSelect(group.changes[0])}
                      >
                        <span
                          className="min-w-0 flex-1 truncate font-mono text-xs text-(--ui-content-primary)"
                          title={group.path}
                        >
                          {group.path}
                        </span>
                        {group.changes.length > 1 && (
                          <span className="rounded-full border border-(--ui-border) px-1.5 py-0.5 text-[11px] text-(--ui-content-muted)">
                            {group.changes.length}
                          </span>
                        )}
                      </button>
                      {group.changes.length > 1 && groupSelected && (
                        <div className="ml-3 border-l border-(--ui-border) pl-2">
                          {group.changes.map((change, index) => (
                            <button
                              key={change.id}
                              type="button"
                              className="focus-ring flex min-h-9 w-full items-center justify-between rounded-md px-2 text-left text-xs text-(--ui-content-muted) aria-current:bg-(--ui-action-selected-surface) aria-current:text-(--ui-action-selected-content)"
                              aria-current={
                                change.id === state.selected.id
                                  ? "true"
                                  : undefined
                              }
                              onClick={() => onSelect(change)}
                            >
                              <span>
                                {t("file_changes.change_index", {
                                  index: index + 1,
                                })}
                              </span>
                              <span className={kindColor(change.kind)}>
                                {t(kindMessage(change.kind))}
                              </span>
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  );
                })}
              </nav>

              <section
                className="flex min-h-0 min-w-0 flex-col"
                aria-live="polite"
                aria-busy={state.phase === "loading"}
              >
                <header className="border-b border-(--ui-border) px-5 py-3">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p
                        className={`m-0 text-xs font-semibold ${kindColor(state.selected.kind)}`}
                      >
                        {t(kindMessage(state.selected.kind))}
                        {state.selected.status === "partial" &&
                          ` · ${t("file_changes.status.partial")}`}
                      </p>
                      <p
                        className="mt-1 mb-0 truncate font-mono text-sm text-(--ui-content-primary)"
                        title={state.selected.displayPath}
                      >
                        {state.selected.displayPath}
                      </p>
                      {state.selected.fromDisplayPath && (
                        <p
                          className="mt-1 mb-0 truncate font-mono text-xs text-(--ui-content-muted)"
                          title={state.selected.fromDisplayPath}
                        >
                          {state.selected.fromDisplayPath} →{" "}
                          {state.selected.displayPath}
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
                  </div>
                </header>

                {state.phase === "loading" ? (
                  <div className="grid flex-1 place-items-center p-8 text-sm text-(--ui-content-muted)">
                    <span className="flex items-center gap-2">
                      <Icon name="loading" />
                      {t("file_changes.loading")}
                    </span>
                  </div>
                ) : ready && state.diff?.status === "ready" ? (
                  <>
                    {(!state.diff.complete || state.diff.redacted) && (
                      <div className="flex flex-wrap gap-x-4 gap-y-1 border-b border-(--ui-border) px-5 py-2 text-xs text-(--ui-content-muted)">
                        {!state.diff.complete && (
                          <span>{t("file_changes.diff.incomplete")}</span>
                        )}
                        {state.diff.redacted && (
                          <span>{t("file_changes.diff.redacted")}</span>
                        )}
                      </div>
                    )}
                    <pre className="min-h-0 flex-1 overflow-auto bg-(--ui-surface-canvas) p-0 font-mono text-[13px] leading-6 [tab-size:4]">
                      {state.diff.content.split("\n").map((line, index) => (
                        <span
                          className={`block min-h-6 px-5 whitespace-pre ${diffLineColor(line)}`}
                          key={`${index}:${line}`}
                        >
                          {line || " "}
                        </span>
                      ))}
                    </pre>
                  </>
                ) : (
                  <div className="grid flex-1 place-items-center p-8 text-center">
                    <div className="max-w-sm">
                      <p className="m-0 text-sm font-medium text-(--ui-content-primary)">
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
                          className="mt-4"
                          onClick={onRefresh}
                        >
                          {t("file_changes.retry")}
                        </Button>
                      )}
                    </div>
                  </div>
                )}
              </section>
            </div>
          </Drawer.Body>
        </Drawer.Popup>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
