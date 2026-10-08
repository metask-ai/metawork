import type { ReactNode } from "react";

import type { ApprovalMode } from "../../bridge/contracts.ts";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function NewTaskView({
  hasWorkspace,
  composer,
  approvalModes,
  approvalMode,
  onApprovalModeChange,
}: {
  hasWorkspace: boolean;
  composer: ReactNode;
  approvalModes: ApprovalMode[];
  approvalMode: ApprovalMode;
  onApprovalModeChange: (profile: ApprovalMode) => void;
}) {
  const { t } = useI18n();
  const permissionOptions: SelectionMenuOption[] = approvalModes.map(
    (profile) => ({
      value: profile,
      label: t(`permission.mode.${profile}`),
      description: t(`permission.mode.${profile}.help`),
      descriptionKind: "text",
      trailing:
        profile === "full_access" ? (
          <span className="permission-profile-risk" aria-hidden="true">
            <Icon name="warning" />
          </span>
        ) : undefined,
    }),
  );

  return (
    <div className="new-task-scroll">
      <section className="new-task-view">
        <div className="new-task-content">
          <h2>{t("task.empty_title")}</h2>
          <p>
            {t(
              hasWorkspace
                ? "task.empty_body_with_workspace"
                : "task.empty_body_without_workspace",
            )}
          </p>
          {permissionOptions.length > 0 && (
            <div className="new-task-permission">
              <div>
                <span>{t("permission.new_task.label")}</span>
                <small>{t("permission.new_task.help")}</small>
              </div>
              <SelectionMenu
                triggerId="new-task-permission-profile"
                value={approvalMode}
                options={permissionOptions}
                placeholder={t("permission.new_task.label")}
                ariaLabel={t("permission.new_task.label")}
                helper={t("permission.menu_help")}
                disabled={false}
                valueLayout="detailed"
                triggerClassName="permission-profile-trigger"
                contentClassName="permission-profile-menu"
                onValueChange={(value) =>
                  onApprovalModeChange(value as ApprovalMode)
                }
              />
              {approvalMode === "full_access" && (
                <p className="permission-policy-boundary">
                  <Icon name="warning" />
                  {t("permission.full_access.boundary")}
                </p>
              )}
              {approvalMode === "auto_review" && (
                <p className="permission-policy-boundary" role="note">
                  {t("permission.auto_review.boundary")}
                </p>
              )}
            </div>
          )}
          {composer}
        </div>
      </section>
    </div>
  );
}
