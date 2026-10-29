import type { Ref } from "react";
import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { useI18n } from "../../i18n/context.ts";

export function ModelSelector({
  label,
  triggerRef,
  options,
  selectedId,
  editable,
  disabled,
  pending,
  contextTitle,
  onSelect,
}: {
  label: string;
  triggerRef?: Ref<HTMLButtonElement>;
  options: {
    selectionId: string;
    displayName: string;
    triggerLabel?: string;
    group?: "custom";
  }[];
  selectedId: string;
  editable: boolean;
  disabled: boolean;
  pending: boolean;
  contextTitle: string;
  onSelect: (id: string) => void;
}) {
  const { t } = useI18n();

  if (!editable)
    return (
      <strong className="composer-model-readonly" title={contextTitle}>
        <Icon name="model" />
        <span>{label}</span>
      </strong>
    );

  return (
    <SelectionMenu
      triggerRef={triggerRef}
      value={selectedId}
      options={options.map((model, index) => ({
        value: model.selectionId,
        label:
          model.displayName || model.selectionId || t("account.model_fallback"),
        triggerLabel:
          model.selectionId === selectedId ? label : model.triggerLabel,
        groupLabel:
          model.group === "custom" && options[index - 1]?.group !== "custom"
            ? t("settings.custom_models")
            : undefined,
      }))}
      placeholder={label || t("account.choose_model")}
      ariaLabel={t("account.model")}
      title={contextTitle}
      helper={contextTitle}
      disabled={disabled}
      busy={pending}
      leading={<Icon name="model" />}
      triggerClassName="composer-model-trigger w-auto"
      contentClassName="composer-model-menu"
      onValueChange={onSelect}
    />
  );
}
