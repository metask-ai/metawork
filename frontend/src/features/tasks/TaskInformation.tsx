import type { Ref } from "react";
import type { TaskView } from "../../bridge/contracts.ts";
import { Popover } from "../../components/ui/popover.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function TaskInformation({
  task,
  permissionProfilesEnabled,
  triggerRef,
}: {
  task: TaskView;
  permissionProfilesEnabled: boolean;
  triggerRef?: Ref<HTMLButtonElement>;
}) {
  const { t } = useI18n();
  return (
    <Popover.Root>
      <Popover.Trigger
        ref={triggerRef}
        className="icon-button focus-ring"
        aria-label={t("task.information")}
        title={t("task.information")}
      >
        <Icon name="info" />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner align="end">
          <Popover.Popup className="task-information">
            <Popover.Title>{t("task.information")}</Popover.Title>
            <dl className="task-facts">
              <div>
                <dt>{t("inspector.mcp_authority")}</dt>
                <dd>
                  {t(
                    task.mcpAuthority.kind === "unavailable"
                      ? "inspector.mcp_unavailable"
                      : task.mcpAuthority.selection === "selected"
                        ? "inspector.mcp_selected"
                        : "inspector.mcp_none",
                  )}
                </dd>
              </div>
              {permissionProfilesEnabled && (
                <div>
                  <dt>{t("permission.task.label")}</dt>
                  <dd>{t(`permission.profile.${task.permissionProfile}`)}</dd>
                </div>
              )}
            </dl>
            <p className="projection-note">{t("task.information_scope")}</p>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}
