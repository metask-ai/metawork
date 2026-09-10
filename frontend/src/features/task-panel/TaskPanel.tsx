import type { ReactNode } from "react";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function TaskPanel({
  title,
  children,
  attention,
  onBack,
  backLabel,
  onClose,
}: {
  title: string;
  children: ReactNode;
  attention: ReactNode;
  onBack?: () => void;
  backLabel?: string;
  onClose: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="task-panel-frame">
      <header className="task-panel-header">
        {onBack && (
          <button
            type="button"
            className="text-button focus-ring"
            onClick={onBack}
          >
            {backLabel ?? t("task_panel.back_review")}
          </button>
        )}
        <h2 id="task-panel-title" tabIndex={-1}>
          {title}
        </h2>
        {attention}
        <button
          type="button"
          className="task-panel-close focus-ring"
          aria-label={t("task_panel.close")}
          onClick={onClose}
        >
          <Icon name="close" />
        </button>
      </header>
      <div className="task-panel-content">{children}</div>
    </div>
  );
}
