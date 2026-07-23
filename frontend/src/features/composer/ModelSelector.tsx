import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { useI18n } from "../../i18n/context.ts";

export function ModelSelector({
  label,
  options,
  selectedId,
  editable,
  disabled,
  pending,
  contextTitle,
  onSelect,
}: {
  label: string;
  options: { selectionId: string; displayName: string }[];
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
      value={selectedId}
      options={options.map((model) => ({
        value: model.selectionId,
        label:
          model.displayName || model.selectionId || t("account.model_fallback"),
      }))}
      placeholder={t("account.choose_model")}
      ariaLabel={t("settings.default_model")}
      title={contextTitle}
      helper={contextTitle}
      disabled={disabled}
      busy={pending}
      leading={<Icon name="model" />}
      triggerClassName="composer-model-trigger"
      contentClassName="composer-model-menu"
      onValueChange={onSelect}
    />
  );
}
