import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { useI18n } from "../../i18n/context.ts";

type WorkspaceOption = {
  id: string;
  label: string;
  description?: string;
  authorization: "available" | "removing" | "reauthorization_required";
};

export function WorkspaceContextSelector({
  accessRequired,
  missing,
  label,
  title,
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
            disabled: workspace.authorization !== "available",
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
          triggerClassName="composer-workspace-trigger"
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
        <button
          className="composer-workspace-action focus-ring"
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
        </button>
      )}
    </div>
  );
}
