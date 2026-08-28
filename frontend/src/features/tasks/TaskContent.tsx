import {
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

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
import { useI18n, type I18nValue, type MessageId } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";

type ReadingState = { scrollTop: number; followingLatest: boolean };

function activeRun(run: RunView): boolean {
  return ["queued", "running", "waiting_ui", "stopping"].includes(run.phase);
}

function activeRunMessage(run: RunView): MessageId {
  if (run.phase === "running") {
    switch (run.activity?.kind) {
      case "queued":
      case "starting":
        return "run.activity.starting";
      case "thinking":
        return "run.activity.thinking";
      case "writing_response":
        return "run.activity.writing_response";
      case "executing_tools":
        return "run.activity.executing_tools";
      case "retrying_provider":
        return "run.activity.retrying_provider";
      case "compacting_context":
        return "run.activity.compacting_context";
      case "finalizing":
        return "run.activity.finishing";
      case "waiting_user":
        return "task.phase.waiting_ui";
      case "stopping":
        return "task.phase.stopping";
      case "waiting_model":
      case undefined:
        return "run.activity.waiting_model";
    }
  }
  return `task.phase.${run.phase}`;
}

function activeRunDetail(
  run: RunView,
  locale: I18nValue["locale"],
  t: I18nValue["t"],
): string | undefined {
  if (run.activity?.kind === "executing_tools" && run.activity.inFlight) {
    const count = BigInt(run.activity.inFlight);
    return t(
      count === 1n
        ? "run.activity.tool_running_one"
        : "run.activity.tool_running_many",
      { count: formatInteger(locale, count) },
    );
  }
  if (
    run.activity?.kind === "retrying_provider" &&
    run.activity.attempt &&
    run.activity.max &&
    run.activity.delayMs
  ) {
    const values = {
      attempt: formatInteger(locale, BigInt(run.activity.attempt)),
      max: formatInteger(locale, BigInt(run.activity.max)),
      delay: formatInteger(locale, BigInt(run.activity.delayMs)),
    };
    return t(
      run.activity.delayMs === "0"
        ? "run.activity.retry_detail_now"
        : "run.activity.retry_detail",
      values,
    );
  }
  return undefined;
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

function terminalMessage(
  responseKind: RunView["output"]["responseKind"],
  outcome: NonNullable<RunView["outcome"]>,
): MessageId {
  if (responseKind !== "partial") return outcomeMessage(outcome);
  switch (outcome) {
    case "completed":
      return "run.terminal.partial_completed";
    case "stopped":
    case "cancelled":
      return "run.terminal.partial_stopped";
    case "interrupted":
      return "run.terminal.partial_interrupted";
    case "failed":
    case "dependency_contract_failure":
      return "run.terminal.partial_failed";
  }
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

function AgentCommentary({
  storageKey,
  content,
  active,
  memory,
}: {
  storageKey: string;
  content: string;
  active: boolean;
  memory: Map<string, boolean>;
}) {
  const { t } = useI18n();
  const regionId = useId();
  const [open, setOpen] = useState(() => {
    const remembered = memory.get(storageKey);
    if (remembered !== undefined) return remembered;
    memory.set(storageKey, active);
    return active;
  });

  function toggle() {
    const next = !open;
    memory.set(storageKey, next);
    setOpen(next);
  }

  return (
    <section className="agent-commentary" data-open={open}>
      <button
        type="button"
        className="agent-commentary-toggle focus-ring"
        aria-expanded={open}
        aria-controls={open ? regionId : undefined}
        onClick={toggle}
      >
        <span>{t("run.output.agent_updates")}</span>
        <Icon name="chevron" />
      </button>
      {open && (
        <div className="agent-commentary-body" id={regionId}>
          <Markdown>{content}</Markdown>
        </div>
      )}
    </section>
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
  const { locale, t } = useI18n();
  const viewport = useRef<HTMLDivElement>(null);
  const reading = useRef(new Map<string, ReadingState>());
  const commentaryDisclosure = useRef(new Map<string, boolean>());
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
        const hasAssistantOutput = Boolean(
          run.output.commentary ||
          run.output.response ||
          run.output.provisional,
        );
        const showStreamingCaret =
          activeRun(run) &&
          (run.output.provisional.length > 0 ||
            run.activity?.kind === "writing_response");
        const showOutcome =
          run.outcome !== null &&
          !(
            run.outcome === "completed" &&
            run.output.responseKind === "final" &&
            run.output.response.length > 0
          );
        return (
          <section className="ai-exchange" key={run.id}>
            <Message role="user">
              <TaskInput input={run.input} />
            </Message>
            {hasAssistantOutput && (
              <Message role="assistant" streaming={showStreamingCaret}>
                {run.output.commentary && (
                  <AgentCommentary
                    key={`${task.id}:${run.id}`}
                    storageKey={`${task.id}:${run.id}`}
                    content={run.output.commentary}
                    active={activeRun(run)}
                    memory={commentaryDisclosure.current}
                  />
                )}
                {run.output.response && (
                  <Markdown className="agent-response">
                    {run.output.response}
                  </Markdown>
                )}
                {run.output.provisional && (
                  <div
                    className="agent-provisional"
                    aria-label={t("run.output.in_progress")}
                  >
                    <span>{t("run.output.in_progress")}</span>
                    <p>{run.output.provisional}</p>
                  </div>
                )}
                {(run.output.redacted || run.output.provisionalRedacted) && (
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
              <Activity
                state="live"
                label={t(activeRunMessage(run))}
                detail={activeRunDetail(run, locale, t)}
              />
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
                label={t(terminalMessage(run.output.responseKind, run.outcome))}
                detail={
                  run.cause
                    ? t(`cause.${run.cause}`)
                    : run.outcome === "completed" &&
                        run.output.responseKind !== "partial"
                      ? t("run.no_final_response")
                      : undefined
                }
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
