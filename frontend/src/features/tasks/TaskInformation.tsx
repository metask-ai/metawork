import type { Ref, ReactNode } from "react";
import type {
  InstructionUse,
  ModelsView,
  TaskView,
} from "../../bridge/contracts.ts";
import { DiagnosticDisclosure } from "../../components/ui/DiagnosticDisclosure.tsx";
import { Popover } from "../../components/ui/popover.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

/** What one instruction file contributed to the Run, as the Host said. */
function instructionStatus(
  use: InstructionUse,
  source: "global" | "project",
  t: (id: MessageId, values?: Record<string, string>) => string,
) {
  switch (use.state) {
    case "applied":
      return t(
        use.truncated
          ? "task.instructions.applied_truncated"
          : "task.instructions.applied",
      );
    case "absent":
      return t(
        source === "global"
          ? "task.instructions.global_absent"
          : "task.instructions.project_absent",
      );
    case "empty":
      return t("task.instructions.empty");
    case "unreadable":
      return t("task.instructions.unreadable", {
        reason: t(`task.instructions.reason.${use.reason ?? "io_error"}`),
      });
    case "rejected":
      return t("task.instructions.rejected");
    case "update_failed":
      return t("task.instructions.update_failed");
    case "unavailable":
      return t("task.instructions.unavailable");
  }
}

export function TaskInformation({
  task,
  models,
  workspaceDirectory,
  workspaceDiagnostic,
  permissionProfilesEnabled,
  triggerRef,
  diagnostics,
}: {
  task: TaskView;
  models: ModelsView;
  workspaceDirectory?: ReactNode;
  workspaceDiagnostic?: string;
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
            {workspaceDiagnostic && (
              <DiagnosticDisclosure label={t("workspace.diagnostics")}>
                <pre className="feedback-notice-details">
                  {workspaceDiagnostic}
                </pre>
              </DiagnosticDisclosure>
            )}
            <dl className="task-facts">
              {workspaceDirectory}
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
              {executionRun?.instructions && (
                <>
                  <div>
                    <dt>
                      {t(
                        activeRun
                          ? "task.current_run_global_instructions"
                          : "task.last_run_global_instructions",
                      )}
                    </dt>
                    <dd>
                      {instructionStatus(
                        executionRun.instructions.global,
                        "global",
                        t,
                      )}
                    </dd>
                  </div>
                  {executionRun.instructions.project && (
                    <div>
                      <dt>
                        {t(
                          activeRun
                            ? "task.current_run_project_instructions"
                            : "task.last_run_project_instructions",
                        )}
                      </dt>
                      <dd className="task-instructions-fact">
                        {executionRun.instructions.project.path && (
                          <code title={executionRun.instructions.project.path}>
                            {executionRun.instructions.project.path}
                          </code>
                        )}
                        <span>
                          {instructionStatus(
                            executionRun.instructions.project,
                            "project",
                            t,
                          )}
                        </span>
                      </dd>
                    </div>
                  )}
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
