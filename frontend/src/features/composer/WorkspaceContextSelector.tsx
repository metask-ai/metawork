import { Icon } from "../../components/ui/Icon.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { Popover } from "../../components/ui/popover.tsx";
import { useI18n } from "../../i18n/context.ts";

export const automaticWorkspaceOptionId = "automatic";
const openLocalFolder = "open-local-folder";

type WorkspaceOption = {
  id: string;
  label: string;
  triggerLabel?: string;
  authorization: "available" | "removing" | "reauthorization_required";
  disabled?: boolean;
};

export function WorkspaceContextSelector({
  accessRequired,
  label,
  title,
  diagnostic,
  options,
  selectedId,
  disabled,
  onConfirmAccess,
  onSelect,
}: {
  accessRequired: boolean;
  label: string;
  title: string;
  diagnostic?: string;
  options: WorkspaceOption[];
  selectedId: string;
  disabled: boolean;
  onConfirmAccess: () => void;
  onSelect: (workspaceId: string) => void;
}) {
  const { t } = useI18n();
  const menuOptions: SelectionMenuOption[] = options.map((workspace) => ({
    value: workspace.id,
    label: workspace.label,
    triggerLabel: workspace.triggerLabel,
    leading: (
      <Icon
        name={
          workspace.id === automaticWorkspaceOptionId ? "folder-x" : "workspace"
        }
      />
    ),
    disabled: workspace.disabled || workspace.authorization !== "available",
    trailing:
      workspace.authorization === "removing"
        ? t("workspace.removing_short")
        : workspace.authorization === "reauthorization_required"
          ? t("workspace.access_required_short")
          : undefined,
  }));
  const automaticIndex = menuOptions.findIndex(
    (option) => option.value === automaticWorkspaceOptionId,
  );
  const [automaticOption] =
    automaticIndex >= 0 ? menuOptions.splice(automaticIndex, 1) : [];
  menuOptions.push({
    value: openLocalFolder,
    label: t(accessRequired ? "workspace.confirm_access" : "workspace.add"),
    leading: (
      <span className="composer-workspace-picker-icon">
        <Icon name="folder-open" />
      </span>
    ),
  });
  if (automaticOption) {
    menuOptions.push(automaticOption);
  }

  return (
    <div
      className="composer-workspace-context"
      data-state={accessRequired ? "reauthorization-required" : "ready"}
      role="group"
      aria-label={t("workspace.label")}
    >
      <SelectionMenu
        value={selectedId}
        options={menuOptions}
        placeholder={label}
        ariaLabel={t("workspace.select")}
        title={title}
        disabled={disabled}
        compact
        leading={<Icon name={accessRequired ? "warning" : "workspace"} />}
        triggerClassName="composer-workspace-trigger w-auto"
        contentClassName="composer-workspace-menu"
        onValueChange={(value) => {
          if (value === openLocalFolder) onConfirmAccess();
          else onSelect(value);
        }}
      />
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
