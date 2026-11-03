import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Popover } from "../../components/ui/popover.tsx";
import { useI18n } from "../../i18n/context.ts";

type WorkspaceOption = {
  id: string;
  label: string;
  description?: string;
  authorization: "available" | "removing" | "reauthorization_required";
  disabled?: boolean;
};

export function WorkspaceContextSelector({
  accessRequired,
  missing,
  label,
  title,
  diagnostic,
  options,
  selectedId,
  editable,
  disabled,
  onConfirmAccess,
  onSelect,
}: {
  accessRequired: boolean;
  missing: boolean;
  label: string;
  title: string;
  diagnostic?: string;
  options: WorkspaceOption[];
  selectedId: string;
  editable: boolean;
  disabled: boolean;
  onConfirmAccess: () => void;
  onSelect: (workspaceId: string) => void;
}) {
  const { t } = useI18n();

  return (
    <div
      className="composer-workspace-context"
      data-state={
        missing
          ? "missing"
          : accessRequired
            ? "reauthorization-required"
            : "ready"
      }
      role="group"
      aria-label={t("workspace.label")}
    >
      {editable ? (
        <SelectionMenu
          value={selectedId}
          options={options.map((workspace) => ({
            value: workspace.id,
            label: workspace.label,
            description: workspace.description,
            disabled:
              workspace.disabled || workspace.authorization !== "available",
            trailing:
              workspace.authorization === "removing"
                ? t("workspace.removing_short")
                : workspace.authorization === "reauthorization_required"
                  ? t("workspace.access_required_short")
                  : undefined,
          }))}
          placeholder={t("workspace.select")}
          ariaLabel={t("workspace.switch")}
          title={title}
          disabled={disabled || options.length === 0}
          leading={<Icon name="workspace" />}
          triggerClassName="composer-workspace-trigger w-auto"
          contentClassName="composer-workspace-menu"
          onValueChange={onSelect}
        />
      ) : (
        <strong className="composer-workspace-readonly" title={title}>
          <Icon name="workspace" />
          <span>{label}</span>
        </strong>
      )}
      {editable && (
        <Button
          variant="ghost"
          size="sm"
          className="composer-workspace-action"
          data-emphasis={accessRequired}
          aria-label={
            accessRequired ? t("workspace.confirm_access") : t("workspace.add")
          }
          title={
            accessRequired ? t("workspace.confirm_access") : t("workspace.add")
          }
          disabled={disabled}
          onClick={onConfirmAccess}
        >
          <Icon name={accessRequired ? "warning" : "plus"} />
          {accessRequired && <span>{t("workspace.confirm_access")}</span>}
        </Button>
      )}
      {diagnostic && (
        <Popover.Root>
          <Popover.Trigger
            className="icon-button"
            aria-label={t("workspace.diagnostics")}
            title={t("workspace.diagnostics")}
          >
            <Icon name="more" />
          </Popover.Trigger>
          <Popover.Portal>
            <Popover.Positioner>
              <Popover.Popup className="p-4 max-w-[min(32rem,calc(100vw-2rem))]">
                <Popover.Title>{t("workspace.diagnostics")}</Popover.Title>
                <pre className="feedback-notice-details">{diagnostic}</pre>
              </Popover.Popup>
            </Popover.Positioner>
          </Popover.Portal>
        </Popover.Root>
      )}
    </div>
  );
}
