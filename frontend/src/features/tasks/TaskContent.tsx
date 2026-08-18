import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

import type {
  PendingUi,
  RunInputView,
  RunView,
  TaskView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import { Markdown } from "../../components/ai/index.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";

type ReadingState = { scrollTop: number; followingLatest: boolean };

function activeRun(run: RunView): boolean {
  return ["queued", "running", "waiting_ui", "stopping"].includes(run.phase);
}

function activeRunMessage(run: RunView): MessageId {
  if (run.phase === "running") {
    switch (run.status) {
      case "Queued":
      case "Starting":
        return "run.activity.starting";
      case "Generating response":
        return "run.activity.generating_response";
      case "Thinking":
        return "run.activity.thinking";
      case "Writing response":
        return "run.activity.writing_response";
      case "Executing tools":
        return "run.activity.executing_tools";
      case "Retrying provider":
        return "run.activity.retrying_provider";
      case "Compacting context":
      case "Context compacted":
        return "run.activity.compacting_context";
      case "Finishing":
        return "run.activity.finishing";
    }
    return "run.activity.waiting_model";
  }
  return `task.phase.${run.phase}`;
}

function outcomeMessage(outcome: NonNullable<RunView["outcome"]>): MessageId {
  switch (outcome) {
    case "completed":
      return "run.terminal.completed";
    case "stopped":
    case "cancelled":
      return "run.terminal.stopped";
    case "interrupted":
      return "run.terminal.interrupted";
    case "failed":
    case "dependency_contract_failure":
      return "run.terminal.failed";
  }
}

function retryable(outcome: NonNullable<RunView["outcome"]>): boolean {
  return ["failed", "interrupted", "dependency_contract_failure"].includes(
    outcome,
  );
}

function TaskInput({ input }: { input: RunInputView }) {
  const { t } = useI18n();
  const content =
    input.kind === "text" ? (
      <p className="task-input-copy">{input.text}</p>
    ) : (
      <div className="task-skill-input">
        <span className="task-skill-token">
          /{input.invocationName}
          <small>{t("slash.group.skills")}</small>
        </span>
        {input.argumentValues.length > 0 && (
          <span className="task-skill-arguments">
            {input.argumentValues.map((value, index) => (
              <code key={index}>{value}</code>
            ))}
          </span>
        )}
      </div>
    );

  return (
    <>
      {content}
      {input.redacted && (
        <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
      )}
    </>
  );
}

export function TaskContent({
  task,
  revision,
  composerHasDraft,
  retryAvailable,
  responseDisabled,
  onPrepareRetry,
  onRespond,
  renderPendingUi,
}: {
  task: TaskView | null;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  onPrepareRetry: (input: RunInputView) => void;
  onRespond: (payload: UiResponsePayload) => void;
  renderPendingUi: (props: {
    taskId: string;
    pending: PendingUi;
    busy: boolean;
    respond: (payload: UiResponsePayload) => void;
  }) => ReactNode;
}) {
  const { t } = useI18n();
  const viewport = useRef<HTMLDivElement>(null);
  const reading = useRef(new Map<string, ReadingState>());
  const previousTaskId = useRef<string | null>(null);
  const [showJumpLatest, setShowJumpLatest] = useState(false);
  const currentRun = task
    ? (task.runs.find((run) => run.id === task.currentRunId) ??
      task.runs.at(-1) ??
      null)
    : null;

  useLayoutEffect(() => {
    const node = viewport.current;
    if (!node) return;
    const taskId = task?.id ?? null;
    if (!taskId) {
      node.scrollTop = 0;
      setShowJumpLatest(false);
      previousTaskId.current = null;
      return;
    }
    if (previousTaskId.current !== taskId) {
      const saved = reading.current.get(taskId);
      node.scrollTop = saved?.scrollTop ?? node.scrollHeight;
      setShowJumpLatest(saved ? !saved.followingLatest : false);
      previousTaskId.current = taskId;
      return;
    }
    const saved = reading.current.get(taskId);
    if (!saved || saved.followingLatest) {
      node.scrollTop = node.scrollHeight;
      reading.current.set(taskId, {
        scrollTop: node.scrollTop,
        followingLatest: true,
      });
      setShowJumpLatest(false);
    }
  }, [task?.id, revision]);

  function updateReadingState() {
    const node = viewport.current;
    if (!node || !task) return;
    const followingLatest =
      node.scrollHeight - node.scrollTop - node.clientHeight <= 48;
    reading.current.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest,
    });
    setShowJumpLatest(!followingLatest);
  }

  function jumpToLatest() {
    const node = viewport.current;
    if (!node || !task) return;
    reading.current.set(task.id, {
      scrollTop: node.scrollHeight,
      followingLatest: true,
    });
    node.scrollTo({ top: node.scrollHeight, behavior: "smooth" });
    setShowJumpLatest(false);
  }

  return (
    <section className="task-content" aria-label={task?.title}>
      <div
        ref={viewport}
        className="task-content-scroll"
        onScroll={updateReadingState}
      >
        <div className="task-content-body">
          {task?.runs.map((run) => {
            const isCurrent = run.id === currentRun?.id;
            const showOutcome =
              run.outcome !== null &&
              (run.outcome !== "completed" || run.assistant.length === 0);
            return (
              <section className="task-turn" key={run.id}>
                <div className="task-input">
                  <TaskInput input={run.input} />
                </div>
                {run.assistant.length > 0 && (
                  <div
                    className="assistant-response"
                    data-streaming={activeRun(run)}
                  >
                    <Markdown>{run.assistant}</Markdown>
                    {run.assistantRedacted && (
                      <p className="projection-note">
                        {t("privacy.sensitive_hidden")}
                      </p>
                    )}
                  </div>
                )}
                {isCurrent && activeRun(run) && (
                  <p className="task-active-status" role="status">
                    {t(activeRunMessage(run))}
                  </p>
                )}
                {isCurrent && task.pendingUi && (
                  <div className="task-attention">
                    {renderPendingUi({
                      taskId: task.id,
                      pending: task.pendingUi,
                      busy: responseDisabled,
                      respond: onRespond,
                    })}
                  </div>
                )}
                {showOutcome && run.outcome && (
                  <section className="task-outcome" data-phase={run.phase}>
                    <div role={isCurrent ? "status" : undefined}>
                      <p>{t(outcomeMessage(run.outcome))}</p>
                      {run.cause && <span>{t(`cause.${run.cause}`)}</span>}
                    </div>
                    {isCurrent && retryAvailable && retryable(run.outcome) && (
                      <button
                        className="task-outcome-action focus-ring"
                        title={
                          composerHasDraft
                            ? t("run.review_draft_help")
                            : t("run.retry_help")
                        }
                        onClick={() => onPrepareRetry(run.input)}
                      >
                        {composerHasDraft
                          ? t("run.review_draft")
                          : t("run.prepare_retry")}
                      </button>
                    )}
                  </section>
                )}
              </section>
            );
          })}
          {task && task.runs.length === 0 && (
            <div className="task-empty-state">
              <h2>{t("task.empty_title")}</h2>
              <p>{t("task.created_empty_body")}</p>
            </div>
          )}
        </div>
      </div>
      {showJumpLatest && (
        <button className="jump-latest focus-ring" onClick={jumpToLatest}>
          {t("task.jump_latest")}
        </button>
      )}
    </section>
  );
}
