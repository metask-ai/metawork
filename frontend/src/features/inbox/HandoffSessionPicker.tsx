import { useState } from "react";
import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { SearchField } from "../../components/ui/search-field.tsx";
import { useI18n } from "../../i18n/context.ts";

export function HandoffSessionPicker({
  taskNumber,
  tasks,
  workspaces,
  busy,
  failed,
  onBack,
  onConfirm,
}: {
  taskNumber: string;
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  busy: boolean;
  failed: boolean;
  onBack(): void;
  onConfirm(id: string): void;
}) {
  const { t } = useI18n();
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState("");
  const term = query.trim().toLowerCase();
  const byWorkspace = new Map(workspaces.map((w) => [w.id, w]));
  const names = new Map<string, number>();
  for (const workspace of workspaces) {
    names.set(
      workspace.displayName,
      (names.get(workspace.displayName) ?? 0) + 1,
    );
  }
  const rows = tasks
    .map((task) => ({ task, workspace: byWorkspace.get(task.workspaceId) }))
    .filter(({ task, workspace }) =>
      [task.title, workspace?.displayName, workspace?.canonicalRoot].some(
        (value) => value?.toLowerCase().includes(term),
      ),
    )
    .sort((a, b) =>
      Number(BigInt(b.task.recentOrder) - BigInt(a.task.recentOrder)),
    );
  const chosen = rows.find(({ task }) => task.id === selected);
  const searchLabel = t("handoff.search");
  return (
    <div className="handoff-picker">
      <div className="handoff-picker-heading">
        <Button
          size="icon"
          variant="ghost"
          aria-label={t("inbox.detail_back")}
          onClick={onBack}
          disabled={busy}
        >
          <Icon name="arrow-left" />
        </Button>
        <h3>{t("handoff.pick")}</h3>
        <small>{t("inbox.item_number", { id: taskNumber })}</small>
      </div>
      <SearchField
        autoFocus
        label={searchLabel}
        placeholder={searchLabel}
        value={query}
        onChange={(event) => {
          setQuery(event.target.value);
          setSelected("");
        }}
        disabled={busy}
      />
      <div
        className="handoff-picker-list"
        role="radiogroup"
        aria-label={t("handoff.pick")}
      >
        {rows.map(({ task, workspace }) => (
          <label className="handoff-choice" key={task.id}>
            <input
              type="radio"
              name="handoff-session"
              className="sr-only"
              checked={selected === task.id}
              disabled={busy}
              onChange={() => setSelected(task.id)}
            />
            <span className="handoff-choice-text">
              <strong>{task.title}</strong>
              <small title={workspace?.canonicalRoot}>
                {workspace && (names.get(workspace.displayName) ?? 0) > 1
                  ? workspace.canonicalRoot
                  : workspace?.displayName ||
                    workspace?.canonicalRoot ||
                    t("workspace.automatic_directory")}
              </small>
            </span>
            {selected === task.id && <Icon name="check" />}
          </label>
        ))}
        {!rows.length && (
          <p role="status">
            {t(term ? "handoff.no_matches" : "handoff.no_candidates")}
          </p>
        )}
      </div>
      {failed && <p role="alert">{t("handoff.change_failed")}</p>}
      <div className="handoff-picker-footer">
        <small title={chosen?.workspace?.canonicalRoot}>
          {chosen?.workspace?.canonicalRoot}
        </small>
        <Button
          className="handoff-primary"
          size="sm"
          disabled={busy || !chosen}
          onClick={() => chosen && onConfirm(chosen.task.id)}
        >
          {t("handoff.confirm_open")}
        </Button>
      </div>
    </div>
  );
}
