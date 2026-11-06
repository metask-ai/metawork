import {
  approvalModes,
  type ApprovalMode,
  type TaskView,
} from "../../bridge/contracts.ts";
import type { ApprovalRequest } from "./mode-state.ts";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

const approvalModeIcons = {
  manual: "account",
  auto_review: "shield",
  full_access: "shield-alert",
} as const;

export function ApprovalModeIcon({ mode }: { mode: ApprovalMode }) {
  return <Icon name={approvalModeIcons[mode]} />;
}

export function ApprovalModeMenu({
  task,
  request,
  disabled,
  onSelect,
  onRefresh,
}: {
  task: TaskView;
  request: ApprovalRequest | null;
  disabled: boolean;
  onSelect: (mode: ApprovalMode) => void;
  onRefresh: () => void;
}) {
  const { t } = useI18n();
  const change = task.approvalChange;
  const busy = Boolean(change || request);
  const syncRequired =
    request?.phase === "sync_required" || change?.state === "outcome_unknown";
  const failed =
    task.approvalResult?.outcome === "failed" ? task.approvalResult : null;
  return (
    <div className="task-approval-mode">
      <SelectionMenu
        triggerId={`task-approval-mode-${task.id}`}
        value={task.approvalMode}
        options={approvalModes.map((mode) => ({
          value: mode,
          label: t(`permission.mode.${mode}`),
          leading: <ApprovalModeIcon mode={mode} />,
          description:
            t(`permission.mode.${mode}.help`) +
            (task.activeOperation?.kind === "run" &&
            (mode === "full_access") !== (task.approvalMode === "full_access")
              ? ` ${t("permission.change.stop_help")}`
              : ""),
          descriptionKind: "text",
          disabled: !task.availableApprovalModes.includes(mode),
        }))}
        placeholder={t("permission.task.label")}
        ariaLabel={t("permission.task.label")}
        helper={t("permission.task.menu_help")}
        disabled={
          disabled ||
          busy ||
          !task.availableApprovalModes.some(
            (mode) => mode !== task.approvalMode,
          )
        }
        busy={busy}
        leading={<ApprovalModeIcon mode={task.approvalMode} />}
        triggerClassName="task-approval-trigger"
        contentClassName="permission-profile-menu task-approval-menu"
        onValueChange={(mode) => onSelect(mode as ApprovalMode)}
      />
      {(busy || failed) && (
        <span
          className="task-approval-feedback"
          role="status"
          aria-live="polite"
        >
          {syncRequired
            ? t("permission.change.sync_required")
            : change?.state === "recovering"
              ? t("permission.change.recovering")
              : busy
                ? t("permission.change.pending")
                : failed
                  ? t(`permission.change.failure.${failed.reason}`)
                  : null}
          {syncRequired && (
            <Button
              type="button"
              variant="secondary"
              size="sm"
              disabled={disabled}
              onClick={onRefresh}
            >
              {t("permission.change.refresh")}
            </Button>
          )}
        </span>
      )}
    </div>
  );
}
