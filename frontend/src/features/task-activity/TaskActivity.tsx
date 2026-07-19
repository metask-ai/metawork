import type { TaskView, ToolView } from "../../bridge/contracts.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { taskActivity } from "../../workbench/selectors.ts";

function toolStateMessage(tool: ToolView): MessageId {
  if (tool.state === "running") return "task.phase.running";
  return tool.state === "failed" ? "outcome.failed" : "outcome.completed";
}

function currentActivityMessage(
  task: TaskView | null,
  draft: boolean,
): MessageId {
  if (!task) return draft ? "activity.current_draft" : "activity.current_empty";
  if (task.currentRunPhase === "waiting_ui") return "activity.current_waiting";
  if (task.currentRunPhase !== null) return "activity.current_working";
  if (task.lifecycle !== "open") return "activity.current_closed";
  if (!task.continuationAvailable) return "activity.current_unavailable";
  if (task.archived) return "activity.current_archived";
  if (
    task.lastRunOutcome === "failed" ||
    task.lastRunOutcome === "interrupted" ||
    task.lastRunOutcome === "dependency_contract_failure"
  )
    return "activity.current_recover";
  return "activity.current_ready";
}

export function TaskActivity({
  task,
  draft,
  currentStatus,
  onFocusPending,
}: {
  task: TaskView | null;
  draft: boolean;
  currentStatus: string;
  onFocusPending: () => void;
}) {
  const { locale, t } = useI18n();
  const activity = taskActivity(task);
  const activeTools = activity.currentRun?.tools ?? [];

  return (
    <>
      {task?.pendingUi && (
        <section className="activity-section">
          <p className="section-label">{t("activity.needs_attention")}</p>
          <button
            className="attention-link focus-ring"
            onClick={onFocusPending}
          >
            <span>{t("activity.response_required")}</span>
            <strong>{t("activity.view_request")}</strong>
          </button>
        </section>
      )}

      <section className="activity-section">
        <p className="section-label">{t("activity.current")}</p>
        <div className="current-activity">
          <span
            className={`activity-dot ${task?.currentRunPhase ? "is-live" : ""}`}
          />
          <div>
            <p>{currentStatus}</p>
            <span>{t(currentActivityMessage(task, draft))}</span>
          </div>
        </div>
      </section>

      {activeTools.length > 0 && (
        <section className="activity-section">
          <p className="section-label">{t("activity.tools")}</p>
          <ul className="activity-list">
            {activeTools.map((tool) => (
              <li key={tool.id}>
                <span
                  className={`activity-dot ${tool.state === "running" ? "is-live" : ""}`}
                />
                <span>{tool.name}</span>
                <small>{t(toolStateMessage(tool))}</small>
              </li>
            ))}
          </ul>
        </section>
      )}

      {activity.tokenTotal > 0n && (
        <section className="activity-section">
          <p className="section-label">{t("activity.context")}</p>
          <p className="activity-metric">
            {formatInteger(locale, activity.tokenTotal)}
          </p>
          <span className="activity-detail">{t("activity.tokens_used")}</span>
        </section>
      )}
    </>
  );
}
