import type { ReactNode } from "react";

import { useI18n } from "../../i18n/context.ts";

export function NewTaskView({
  hasWorkspace,
  composer,
}: {
  hasWorkspace: boolean;
  composer: ReactNode;
}) {
  const { t } = useI18n();

  return (
    <div className="new-task-scroll">
      <section className="new-task-view">
        <div className="new-task-content">
          <h2>{t("task.empty_title")}</h2>
          <p>
            {t(
              hasWorkspace
                ? "task.empty_body_with_workspace"
                : "task.empty_body_without_workspace",
            )}
          </p>
          {composer}
        </div>
      </section>
    </div>
  );
}
