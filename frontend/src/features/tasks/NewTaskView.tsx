import type { ReactNode } from "react";

import type { PermissionProfile } from "../../bridge/contracts.ts";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function NewTaskView({
  hasWorkspace,
  composer,
  setup,
  permissionProfiles,
  permissionProfile,
  onPermissionProfileChange,
}: {
  hasWorkspace: boolean;
  composer: ReactNode;
  setup: {
    title: string;
    body: string;
    actions?: ReactNode;
  } | null;
  permissionProfiles: PermissionProfile[];
  permissionProfile: PermissionProfile;
  onPermissionProfileChange: (profile: PermissionProfile) => void;
}) {
  const { t } = useI18n();
  const permissionOptions: SelectionMenuOption[] = permissionProfiles.map(
    (profile) => ({
      value: profile,
      label: t(`permission.profile.${profile}`),
      description: t(`permission.profile.${profile}.help`),
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
          {setup ? (
            <div className="new-task-setup">
              <span className="new-task-setup-symbol" aria-hidden="true">
                <Icon name="model" />
              </span>
              <div role="status" aria-live="polite">
                <h2>{setup.title}</h2>
                <p>{setup.body}</p>
              </div>
              {setup.actions && (
                <div className="new-task-setup-actions">{setup.actions}</div>
              )}
            </div>
          ) : (
            <>
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
                    value={permissionProfile}
                    options={permissionOptions}
                    placeholder={t("permission.new_task.label")}
                    ariaLabel={t("permission.new_task.label")}
                    helper={t("permission.menu_help")}
                    disabled={false}
                    valueLayout="detailed"
                    triggerClassName="permission-profile-trigger"
                    contentClassName="permission-profile-menu"
                    onValueChange={(value) =>
                      onPermissionProfileChange(value as PermissionProfile)
                    }
                  />
                  {permissionProfile === "full_access" && (
                    <p className="permission-policy-boundary">
                      <Icon name="warning" />
                      {t("permission.full_access.boundary")}
                    </p>
                  )}
                </div>
              )}
              {composer}
            </>
          )}
        </div>
      </section>
    </div>
  );
}
