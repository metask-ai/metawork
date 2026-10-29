import type { Ref } from "react";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { useI18n } from "../../i18n/context.ts";
import { ModelVendorIcon } from "../models/ModelVendorIcon.tsx";
import type { ModelVendor } from "../models/model-vendor.ts";

export type ModelSelectorOption = {
  selectionId: string;
  displayName: string;
  triggerLabel?: string;
  group?: "custom";
  vendor?: ModelVendor;
};

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
  options: ModelSelectorOption[];
  selectedId: string;
  editable: boolean;
  disabled: boolean;
  pending: boolean;
  contextTitle: string;
  onSelect: (id: string) => void;
}) {
  const { t } = useI18n();
  const selected = options.find((model) => model.selectionId === selectedId);

  if (!editable)
    return (
      <strong className="composer-model-readonly" title={contextTitle}>
        <ModelVendorIcon vendor={selected?.vendor} />
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
        leading: <ModelVendorIcon vendor={model.vendor} />,
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
      leading={<ModelVendorIcon vendor={selected?.vendor} />}
      triggerClassName="composer-model-trigger w-auto"
      contentClassName="composer-model-menu"
      onValueChange={onSelect}
    />
  );
}
