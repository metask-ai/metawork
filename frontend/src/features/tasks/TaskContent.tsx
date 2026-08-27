import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

import type {
  FileReferenceView,
  PendingUi,
  RunInputView,
  RunView,
  TaskView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import {
  Activity,
  Conversation,
  Markdown,
  Message,
} from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
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

export function runFileReferences(run: RunView): FileReferenceView[] {
  const seen = new Set<string>();
  const references: FileReferenceView[] = [];
  const tools = [...run.tools].sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
  for (const tool of tools) {
    for (const reference of tool.fileRefs) {
      if (seen.has(reference.id)) continue;
      seen.add(reference.id);
      references.push(reference);
    }
  }
  return references;
}

function outcomeState(
  outcome: NonNullable<RunView["outcome"]>,
): "completed" | "stopped" | "failed" | "interrupted" {
  switch (outcome) {
    case "completed":
      return "completed";
    case "stopped":
    case "cancelled":
      return "stopped";
    case "interrupted":
      return "interrupted";
    case "failed":
    case "dependency_contract_failure":
      return "failed";
  }
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
  onPreviewFile,
  onRespond,
  renderPendingUi,
}: {
  task: TaskView | null;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  onPrepareRetry: (input: RunInputView) => void;
  onPreviewFile: (
    taskId: string,
    runId: string,
    reference: FileReferenceView,
  ) => void;
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
    <Conversation
      aria-label={task?.title}
      viewportRef={viewport}
      onViewportScroll={updateReadingState}
      jumpToLatest={
        showJumpLatest
          ? { label: t("task.jump_latest"), onClick: jumpToLatest }
          : undefined
      }
    >
      {task?.runs.map((run) => {
        const isCurrent = run.id === currentRun?.id;
        const fileReferences = runFileReferences(run);
        const showOutcome =
          run.outcome !== null &&
          (run.outcome !== "completed" || run.assistant.length === 0);
        return (
          <section className="ai-exchange" key={run.id}>
            <Message role="user">
              <TaskInput input={run.input} />
            </Message>
            {run.assistant.length > 0 && (
              <Message role="assistant" streaming={activeRun(run)}>
                <Markdown>{run.assistant}</Markdown>
                {run.assistantRedacted && (
                  <p className="projection-note">
                    {t("privacy.sensitive_hidden")}
                  </p>
                )}
              </Message>
            )}
            {fileReferences.length > 0 && (
              <footer className="ml-11 flex flex-wrap items-center gap-2 border-l-2 border-(--ui-border) py-1 pl-3">
                <span className="text-xs font-medium text-(--ui-content-muted)">
                  {t("file_preview.references")}
                </span>
                {fileReferences.map((reference) => (
                  <button
                    key={reference.id}
                    type="button"
                    className="focus-ring inline-flex min-h-11 max-w-full items-center gap-1.5 rounded-lg border border-(--ui-border) bg-(--ui-surface-panel) px-3 py-2 text-xs text-(--ui-content-primary) hover:bg-(--ui-action-hover-surface)"
                    title={reference.displayPath}
                    aria-label={t("file_preview.open", {
                      path: reference.displayPath,
                    })}
                    onClick={() => onPreviewFile(task.id, run.id, reference)}
                  >
                    <Icon name="skill-file" />
                    <span className="max-w-72 truncate font-mono">
                      {reference.displayPath}
                    </span>
                  </button>
                ))}
              </footer>
            )}
            {isCurrent && activeRun(run) && (
              <Activity state="live" label={t(activeRunMessage(run))} />
            )}
            {isCurrent && task.pendingUi && (
              <div className="ai-exchange-intervention">
                {renderPendingUi({
                  taskId: task.id,
                  pending: task.pendingUi,
                  busy: responseDisabled,
                  respond: onRespond,
                })}
              </div>
            )}
            {showOutcome && run.outcome && (
              <Activity
                state={outcomeState(run.outcome)}
                label={t(outcomeMessage(run.outcome))}
                detail={run.cause ? t(`cause.${run.cause}`) : undefined}
                announce={isCurrent}
                action={
                  isCurrent && retryAvailable && retryable(run.outcome) ? (
                    <button
                      className="ai-activity-retry focus-ring"
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
                  ) : undefined
                }
              />
            )}
          </section>
        );
      })}
      {task && task.runs.length === 0 && (
        <div className="ai-conversation-empty">
          <h2>{t("task.empty_title")}</h2>
          <p>{t("task.created_empty_body")}</p>
        </div>
      )}
    </Conversation>
  );
}
