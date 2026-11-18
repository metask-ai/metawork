import { useEffect, useRef, useState } from "react";
import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { AlertDialog } from "../../components/ui/alert-dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";

export function WorkingDirectoriesSettings({
  workspaces,
  tasks,
  disabled,
  onChoose,
  onRevoke,
}: {
  workspaces: WorkspaceView[];
  tasks: TaskSummary[];
  disabled: boolean;
  onChoose: () => Promise<void>;
  onRevoke: (workspace: WorkspaceView) => Promise<boolean>;
}) {
  const { t } = useI18n();
  const heading = useRef<HTMLHeadingElement>(null);
  const choose = useRef<HTMLButtonElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);
  const opener = useRef<HTMLButtonElement | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [failure, setFailure] = useState<
    "workspace.directory_action_failed" | "workspace.directory_capacity" | null
  >(null);
  const selected = workspaces.find((workspace) => workspace.id === selectedId);
  const registered = workspaces.filter(
    (workspace) => workspace.kind === "manual",
  );
  const workspaceIds = new Set(workspaces.map((workspace) => workspace.id));
  const otherTasks = tasks.filter(
    (task) =>
      !task.archived &&
      task.projectId === selectedId &&
      task.workspaceId !== selectedId &&
      workspaceIds.has(task.workspaceId),
  ).length;
  useEffect(() => {
    heading.current?.focus();
  }, []);
  async function chooseDirectory() {
    if (pending || disabled) return;
    setPending(true);
    setFailure(null);
    try {
      await onChoose();
    } catch (error) {
      setFailure(
        error instanceof Error &&
          error.message.includes("WorkspaceDirectoryCapacity")
          ? "workspace.directory_capacity"
          : "workspace.directory_action_failed",
      );
    } finally {
      setPending(false);
    }
  }
  async function revoke() {
    if (
      !selected ||
      pending ||
      disabled ||
      selected.authorization === "removing"
    )
      return;
    setPending(true);
    setFailure(null);
    try {
      if (await onRevoke(selected)) setSelectedId(null);
      else setFailure("workspace.directory_action_failed");
    } catch {
      setFailure("workspace.directory_action_failed");
    } finally {
      setPending(false);
    }
  }
  return (
    <section id="settings-directories" className="settings-section">
      <div className="settings-section-heading">
        <h2 ref={heading} tabIndex={-1}>
          {t("settings.working_directories")}
        </h2>
      </div>
      <p>{t("workspace.directory_management_body")}</p>
      <Button
        ref={choose}
        variant="secondary"
        disabled={disabled || pending}
        onClick={() => void chooseDirectory()}
      >
        {t("workspace.choose_directory")}
      </Button>
      {failure && !selected && <p role="alert">{t(failure)}</p>}
      <ul className="settings-preference-list">
        {registered.map((workspace) => (
          <li className="settings-row" key={workspace.id}>
            <div>
              <strong>{workspace.displayName}</strong>
              {!workspace.redacted && (
                <p className="break-all">{workspace.canonicalRoot}</p>
              )}
              {workspace.authorization === "removing" && (
                <p role="status">{t("workspace.removing_short")}</p>
              )}
              {workspace.authorization === "reauthorization_required" && (
                <p>{t("workspace.access_required_short")}</p>
              )}
              {workspace.lastRemovalFailure && (
                <p role="alert">{t("workspace.remove_close_failed")}</p>
              )}
            </div>
            <div className="settings-row-actions">
              {workspace.authorization === "reauthorization_required" && (
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={disabled || pending}
                  onClick={() => void chooseDirectory()}
                >
                  {t("workspace.confirm_access")}
                </Button>
              )}
              <Button
                variant="secondary"
                size="sm"
                disabled={
                  disabled || pending || workspace.authorization === "removing"
                }
                onClick={(event) => {
                  opener.current = event.currentTarget;
                  setFailure(null);
                  setSelectedId(workspace.id);
                }}
              >
                {t("workspace.revoke_directory")}
              </Button>
            </div>
          </li>
        ))}
      </ul>
      {registered.length === 0 && <p>{t("workspace.no_directories")}</p>}
      <AlertDialog.Root
        open={Boolean(selected)}
        onOpenChange={(open) => {
          if (!pending && !open) setSelectedId(null);
        }}
      >
        <AlertDialog.Portal>
          <AlertDialog.Backdrop />
          <AlertDialog.Popup
            initialFocus={() => cancel.current ?? false}
            finalFocus={() =>
              opener.current?.isConnected ? opener.current : choose.current
            }
          >
            <AlertDialog.Title>
              {t("workspace.revoke_directory")}
            </AlertDialog.Title>
            <AlertDialog.Description>
              {t("workspace.revoke_directory_body", {
                title: selected?.displayName ?? "",
                count: tasks.filter((task) => task.workspaceId === selectedId)
                  .length,
              })}
            </AlertDialog.Description>
            {selected?.projectEntry && (
              <p>
                {t("workspace.revoke_project_body", {
                  title: selected.displayName,
                  count: otherTasks,
                })}
              </p>
            )}
            {failure && <p role="alert">{t(failure)}</p>}
            <div className="delete-confirmation-actions">
              <Button
                ref={cancel}
                variant="secondary"
                disabled={pending}
                onClick={() => setSelectedId(null)}
              >
                {t("common.cancel")}
              </Button>
              <Button
                disabled={disabled || pending}
                onClick={() => void revoke()}
              >
                {t("workspace.revoke_directory")}
              </Button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </section>
  );
}
