import type { ReactNode } from "react";

import type { ApprovalMode } from "../../bridge/contracts.ts";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { useI18n } from "../../i18n/context.ts";
import { ApprovalModeIcon } from "../approvals/ApprovalModeMenu.tsx";

export function NewTaskApprovalModeMenu({
  approvalModes,
  approvalMode,
  disabled,
  onApprovalModeChange,
}: {
  approvalModes: ApprovalMode[];
  approvalMode: ApprovalMode;
  disabled: boolean;
  onApprovalModeChange: (mode: ApprovalMode) => void;
}) {
  const { t } = useI18n();
  if (approvalModes.length === 0) return null;
  return (
    <SelectionMenu
      triggerId="new-task-permission-profile"
      value={approvalMode}
      options={approvalModes.map((mode) => ({
        value: mode,
        label: t(`permission.mode.${mode}`),
        leading: <ApprovalModeIcon mode={mode} />,
        description: t(`permission.mode.${mode}.help`),
        descriptionKind: "text",
      }))}
      placeholder={t("permission.new_task.label")}
      ariaLabel={t("permission.new_task.label")}
      disabled={disabled}
      leading={<ApprovalModeIcon mode={approvalMode} />}
      triggerClassName="task-approval-trigger w-auto"
      contentClassName="task-approval-menu w-72 max-w-[calc(100vw-32px)]"
      onValueChange={(value) => onApprovalModeChange(value as ApprovalMode)}
    />
  );
}

export function TaskWorkspace({
  newTask,
  hasWorkspace,
  taskContent,
  composer,
  pendingContent,
}: {
  newTask: boolean;
  hasWorkspace: boolean;
  taskContent?: ReactNode;
  composer: ReactNode;
  pendingContent?: ReactNode;
}) {
  const { t } = useI18n();
  return (
    <div className={newTask ? "new-task-scroll" : "task-workspace"}>
      <section className={newTask ? "new-task-view" : "task-workspace"}>
        <div className={newTask ? "new-task-content" : "task-workspace"}>
          {newTask ? (
            <>
              <h2>{t("task.empty_title")}</h2>
              <p>
                {t(
                  hasWorkspace
                    ? "task.empty_body_with_workspace"
                    : "task.empty_body_without_workspace",
                )}
              </p>
            </>
          ) : (
            taskContent
          )}
          {newTask && pendingContent}
          {composer}
        </div>
      </section>
    </div>
  );
}
