import { useEffect, useMemo, useRef, useState } from "react";

import type {
  TaskView,
  WorkspaceMutationReason,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";

export type WorkspaceChoiceIntent =
  { kind: "add" } | { kind: "reauthorize"; workspaceId: string };
export type WorkspaceChoiceResult =
  | { kind: "selected"; workspaceId: string }
  | { kind: "target_mismatch"; selectedWorkspaceId: string }
  | { kind: "cancelled" }
  | { kind: "failed" };
export type WorkspaceRemovalResult =
  | { kind: "accepted" }
  | { kind: "rejected"; reason: WorkspaceMutationReason }
  | { kind: "failed" };

type WorkspaceActionErrorCode =
  | WorkspaceMutationReason
  | "selection_failed"
  | "operation_failed"
  | "reauthorization_mismatch";
type WorkspaceActionError = {
  workspaceId: string | null;
  code: WorkspaceActionErrorCode;
};

export function WorkspaceSettings({
  userWorkspaces,
  tasks,
  disabled,
  busy,
  onChooseWorkspace,
  onRemoveWorkspace,
}: {
  userWorkspaces: WorkspaceView[];
  tasks: TaskView[];
  disabled: boolean;
  busy: boolean;
  onChooseWorkspace: (
    intent: WorkspaceChoiceIntent,
  ) => Promise<WorkspaceChoiceResult>;
  onRemoveWorkspace: (workspaceId: string) => Promise<WorkspaceRemovalResult>;
}) {
  const { locale, t } = useI18n();
  const [confirmRemovalId, setConfirmRemovalId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<WorkspaceActionError | null>(
    null,
  );
  const heading = useRef<HTMLHeadingElement>(null);
  const removalCancel = useRef<HTMLButtonElement>(null);
  const removalTriggers = useRef(new Map<string, HTMLButtonElement>());
  const taskCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const task of tasks)
      counts.set(task.workspaceId, (counts.get(task.workspaceId) ?? 0) + 1);
    return counts;
  }, [tasks]);

  useEffect(() => {
    if (confirmRemovalId === null) return;
    const frame = window.requestAnimationFrame(() =>
      removalCancel.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [confirmRemovalId]);

  useEffect(() => {
    if (confirmRemovalId === null) return;
    const workspace = userWorkspaces.find(
      (item) => item.id === confirmRemovalId,
    );
    if (workspace && workspace.authorization !== "removing") return;
    setConfirmRemovalId(null);
    window.requestAnimationFrame(() => heading.current?.focus());
  }, [confirmRemovalId, userWorkspaces]);

  useEffect(() => {
    if (!actionError || actionError.workspaceId === null) return;
    const workspace = userWorkspaces.find(
      (item) => item.id === actionError.workspaceId,
    );
    const resolvedReauthorization =
      actionError.code === "reauthorization_mismatch" &&
      workspace?.authorization === "available";
    if (
      !workspace ||
      workspace.authorization === "removing" ||
      resolvedReauthorization
    )
      setActionError(null);
  }, [actionError, userWorkspaces]);

  function closeRemovalConfirmation(returnToTrigger: boolean) {
    const workspaceId = confirmRemovalId;
    setConfirmRemovalId(null);
    window.requestAnimationFrame(() => {
      if (returnToTrigger && workspaceId)
        removalTriggers.current.get(workspaceId)?.focus();
      else heading.current?.focus();
    });
  }

  async function chooseWorkspace(intent: WorkspaceChoiceIntent) {
    setActionError(null);
    const result = await onChooseWorkspace(intent);
    const workspaceId =
      intent.kind === "reauthorize" ? intent.workspaceId : null;
    if (result.kind === "failed") {
      setActionError({ workspaceId, code: "selection_failed" });
      return;
    }
    if (result.kind === "target_mismatch" && intent.kind === "reauthorize")
      setActionError({
        workspaceId: intent.workspaceId,
        code: "reauthorization_mismatch",
      });
  }

  async function removeWorkspace(workspaceId: string) {
    setActionError(null);
    const result = await onRemoveWorkspace(workspaceId);
    if (result.kind === "accepted") {
      closeRemovalConfirmation(false);
      return;
    }
    if (result.kind === "rejected")
      setActionError({ workspaceId, code: result.reason });
    else setActionError({ workspaceId, code: "operation_failed" });
  }

  function beginRemoval(workspaceId: string) {
    setActionError(null);
    setConfirmRemovalId(workspaceId);
  }

  return (
    <>
      <div className="settings-section-heading settings-workspace-heading">
        <div>
          <p>{t("settings.section_label")}</p>
          <h2 ref={heading} tabIndex={-1}>
            {t("settings.workspaces")}
          </h2>
        </div>
        <button
          className="secondary-button focus-ring"
          disabled={disabled || busy}
          onClick={() => void chooseWorkspace({ kind: "add" })}
        >
          <Icon name="plus" />
          {t("settings.workspace_add")}
        </button>
      </div>
      <p className="settings-workspace-intro">
        {t("settings.workspaces_help")}
      </p>

      {actionError?.workspaceId === null && (
        <WorkspaceActionErrorNotice code={actionError.code} />
      )}

      {userWorkspaces.length === 0 ? (
        <div className="settings-workspace-empty">
          <Icon name="workspace" />
          <div>
            <strong>{t("settings.workspace_empty_title")}</strong>
            <p>{t("settings.workspace_empty_help")}</p>
          </div>
        </div>
      ) : (
        <div className="settings-workspace-list">
          {userWorkspaces.map((workspace) => {
            const count = taskCounts.get(workspace.id) ?? 0;
            const removalFailed = workspace.lastRemovalFailure !== null;
            const confirming = confirmRemovalId === workspace.id;
            const rowError =
              actionError?.workspaceId === workspace.id
                ? actionError.code
                : null;
            return (
              <div
                className="settings-workspace-row"
                key={workspace.id}
                data-authorization={workspace.authorization}
              >
                <span className="settings-workspace-mark" aria-hidden="true">
                  <Icon name="workspace" />
                </span>
                <div className="settings-workspace-copy">
                  <strong title={workspace.displayName}>
                    {workspace.displayName || workspace.canonicalRoot}
                  </strong>
                  <code title={workspace.canonicalRoot}>
                    {workspace.canonicalRoot}
                  </code>
                  <span>{t(taskCountMessageId(locale, count), { count })}</span>
                </div>

                {confirming ? (
                  <div
                    className="settings-workspace-confirmation"
                    role="group"
                    aria-labelledby={`workspace-remove-title-${workspace.id}`}
                    aria-describedby={`workspace-remove-copy-${workspace.id}`}
                    onKeyDown={(event) => {
                      if (event.key !== "Escape") return;
                      event.preventDefault();
                      closeRemovalConfirmation(true);
                    }}
                  >
                    <strong id={`workspace-remove-title-${workspace.id}`}>
                      {t("settings.workspace_remove_confirm_title")}
                    </strong>
                    <p id={`workspace-remove-copy-${workspace.id}`}>
                      {t("settings.workspace_remove_confirm_body", { count })}
                    </p>
                    <span>
                      <button
                        ref={removalCancel}
                        className="secondary-button focus-ring"
                        onClick={() => closeRemovalConfirmation(true)}
                      >
                        {t("common.cancel")}
                      </button>
                      <button
                        className="danger-button focus-ring"
                        disabled={disabled || busy}
                        onClick={() => void removeWorkspace(workspace.id)}
                      >
                        {t("settings.workspace_remove_confirm_action")}
                      </button>
                    </span>
                  </div>
                ) : (
                  <div className="settings-workspace-actions">
                    <span
                      className="settings-workspace-status"
                      data-state={
                        removalFailed
                          ? "removal_failed"
                          : workspace.authorization
                      }
                    >
                      {t(
                        `settings.workspace_status.${
                          removalFailed
                            ? "removal_failed"
                            : workspace.authorization
                        }`,
                      )}
                    </span>
                    {workspace.authorization === "reauthorization_required" && (
                      <button
                        className="text-button focus-ring"
                        disabled={disabled || busy}
                        onClick={() =>
                          void chooseWorkspace({
                            kind: "reauthorize",
                            workspaceId: workspace.id,
                          })
                        }
                      >
                        {t("settings.workspace_reauthorize")}
                      </button>
                    )}
                    {workspace.authorization !== "removing" && (
                      <button
                        ref={(node) => {
                          if (node)
                            removalTriggers.current.set(workspace.id, node);
                          else removalTriggers.current.delete(workspace.id);
                        }}
                        className="text-button is-danger focus-ring"
                        disabled={disabled || busy}
                        onClick={() => beginRemoval(workspace.id)}
                      >
                        {removalFailed
                          ? t("settings.workspace_retry_removal")
                          : t("settings.workspace_remove")}
                      </button>
                    )}
                  </div>
                )}
                {rowError && (
                  <WorkspaceActionErrorNotice
                    code={rowError}
                    className="settings-workspace-row-error"
                  />
                )}
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}

function WorkspaceActionErrorNotice({
  code,
  className = "",
}: {
  code: WorkspaceActionErrorCode;
  className?: string;
}) {
  const { t } = useI18n();
  return (
    <div className={`settings-error ${className}`.trim()} role="alert">
      <Icon name="warning" />
      <span className="settings-error-copy">
        <strong>{t("settings.workspace_action_failed")}</strong>
        <span>
          {code === "selection_failed"
            ? t("workspace.selection_failed")
            : code === "operation_failed"
              ? t("mutation.transport_failed")
              : code === "reauthorization_mismatch"
                ? t("settings.workspace_reauthorize_mismatch")
                : t(`mutation.reason.${code}`)}
        </span>
      </span>
    </div>
  );
}
