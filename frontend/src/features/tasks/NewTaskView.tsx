import type { ReactNode } from "react";

import { useI18n } from "../../i18n/context.ts";

export function TaskWorkspace({
  newTask,
  taskContent,
  composer,
  pendingContent,
}: {
  newTask: boolean;
  taskContent?: ReactNode;
  composer: ReactNode;
  pendingContent?: ReactNode;
}) {
  const { t } = useI18n();
  return (
    <div className={newTask ? "new-task-scroll" : "task-workspace"}>
      <section className={newTask ? "new-task-view" : "task-workspace"}>
        <div className={newTask ? "new-task-content" : "task-workspace"}>
          {newTask ? <h2>{t("task.empty_title")}</h2> : taskContent}
          {newTask && pendingContent}
          {composer}
        </div>
      </section>
    </div>
  );
}
