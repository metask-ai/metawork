import type { ReactNode } from "react";

import { useI18n, type MessageId } from "../../i18n/context.ts";

const newTaskExampleIds: MessageId[] = [
  "task.example.review",
  "task.example.test_failure",
  "task.example.todo",
];

export function NewTaskView({
  hasWorkspace,
  composerHasDraft,
  composer,
  onUseExample,
}: {
  hasWorkspace: boolean;
  composerHasDraft: boolean;
  composer: ReactNode;
  onUseExample: (instruction: string) => void;
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
          {!composerHasDraft && (
            <div className="task-examples" aria-label={t("task.examples")}>
              {newTaskExampleIds.map((id) => (
                <button
                  key={id}
                  className="task-example focus-ring"
                  onClick={() => onUseExample(t(id))}
                >
                  {t(id)}
                </button>
              ))}
            </div>
          )}
        </div>
      </section>
    </div>
  );
}
