import type { ReactNode } from "react";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function TaskPanel({
  title,
  children,
  attention,
  actions,
  fileTitle = false,
  onClose,
}: {
  title: string;
  children: ReactNode;
  attention: ReactNode;
  actions?: ReactNode;
  fileTitle?: boolean;
  onClose: () => void;
}) {
  const { t } = useI18n();
  return (
    <div className="task-panel-frame">
      <header className="task-panel-header">
        <h2
          id="task-panel-title"
          className={fileTitle ? "task-panel-file-title" : undefined}
          title={fileTitle ? title : undefined}
          tabIndex={-1}
        >
          {title}
        </h2>
        {attention}
        {actions}
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
