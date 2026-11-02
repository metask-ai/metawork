import type { Ref, ReactNode } from "react";
import type { ModelsView, TaskView } from "../../bridge/contracts.ts";
import { Popover } from "../../components/ui/popover.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function TaskInformation({
  task,
  models,
  permissionProfilesEnabled,
  triggerRef,
  diagnostics,
}: {
  task: TaskView;
  models: ModelsView;
  permissionProfilesEnabled: boolean;
  triggerRef?: Ref<HTMLButtonElement>;
  diagnostics?: ReactNode;
}) {
  const { t } = useI18n();
  const activeRun = task.activeOperation?.kind === "run";
  const executionRun = activeRun
    ? task.runs.find((run) => run.id === task.activeOperation?.id)
    : task.runs.at(-1);
  const sourceId = task.modelIntent?.modelRef.sourceId;
  const provider =
    models.providers.find((candidate) => candidate.id === sourceId) ??
    models.customProviders.find((candidate) => candidate.id === sourceId);
  const providerLabel =
    provider?.displayName ||
    (sourceId === "metask" ? "Metask" : sourceId) ||
    t("account.unknown_provider");
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
            {diagnostics}
            <dl className="task-facts">
              <div>
                <dt>{t("task.selected_provider")}</dt>
                <dd>{providerLabel}</dd>
              </div>
              {executionRun && (
                <>
                  <div>
                    <dt>
                      {t(
                        activeRun
                          ? "task.current_run_model"
                          : "task.last_run_model",
                      )}
                    </dt>
                    <dd>{executionRun.execution.model}</dd>
                  </div>
                  <div>
                    <dt>
                      {t(
                        activeRun
                          ? "task.current_run_protocol"
                          : "task.last_run_protocol",
                      )}
                    </dt>
                    <dd>
                      {t(
                        `settings.custom_provider_protocol.${executionRun.execution.protocol}`,
                      )}
                    </dd>
                  </div>
                </>
              )}
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
                  <dd className="task-permission-fact">
                    <span data-profile={task.permissionProfile}>
                      {task.permissionProfile === "full_access" && (
                        <Icon name="warning" />
                      )}
                      {t(`permission.mode.${task.approvalMode}`)}
                    </span>
                    <small>
                      {t(
                        task.permissionProfile === "full_access"
                          ? "permission.task.full_access.help"
                          : "permission.task.help",
                      )}
                    </small>
                  </dd>
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
