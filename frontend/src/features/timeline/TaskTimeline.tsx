import {
  Fragment,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

import { CodeBlock } from "../../components/ui/CodeBlock.tsx";
import type {
  PendingUi,
  RunView,
  TaskView,
  ToolView,
  UiRecord,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import { runInputDisplay } from "../../workbench/run-input.ts";
import { formatInteger, formatMilliseconds } from "../../i18n/formatters.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";

type TimelineDetailSection = "tools" | "usage";

const newTaskExampleIds: MessageId[] = [
  "task.example.review",
  "task.example.test_failure",
  "task.example.todo",
];

function tokenTotal(run: RunView): bigint | null {
  try {
    return BigInt(run.usage.input) + BigInt(run.usage.output);
  } catch {
    return null;
  }
}

function runPhaseLabel(
  t: (
    id: MessageId,
    values?: Record<string, string | number | bigint>,
  ) => string,
  phase: RunView["phase"],
) {
  switch (phase) {
    case "queued":
    case "running":
    case "waiting_ui":
    case "stopping":
      return t(`task.phase.${phase}`);
    case "completed":
    case "stopped":
    case "cancelled":
    case "interrupted":
    case "failed":
      return t(`outcome.${phase}`);
  }
}

function isNonTerminalRun(phase: RunView["phase"]): boolean {
  return (
    phase === "queued" ||
    phase === "running" ||
    phase === "waiting_ui" ||
    phase === "stopping"
  );
}

function terminalMessageId(
  outcome: NonNullable<RunView["outcome"]>,
): MessageId {
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

function retryableOutcome(outcome: NonNullable<RunView["outcome"]>): boolean {
  return (
    outcome === "failed" ||
    outcome === "interrupted" ||
    outcome === "dependency_contract_failure"
  );
}

type RunActivity =
  | { kind: "tool"; order: string; value: ToolView }
  | { kind: "resolved_ui"; order: string; value: UiRecord }
  | { kind: "pending_ui"; order: string; value: PendingUi };

function orderedActivity(run: RunView, task: TaskView): RunActivity[] {
  const items: RunActivity[] = [
    ...run.tools.map((value) => ({
      kind: "tool" as const,
      order: value.order,
      value,
    })),
    ...task.uiHistory
      .filter((record) => record.runId === run.id)
      .map((value) => ({
        kind: "resolved_ui" as const,
        order: value.order,
        value,
      })),
  ];
  if (task.pendingUi?.runId === run.id)
    items.push({
      kind: "pending_ui",
      order: task.pendingUi.order,
      value: task.pendingUi,
    });
  return items.sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
}

export function TaskTimeline({
  task,
  draft,
  draftHasWorkspace,
  revision,
  composerHasDraft,
  retryAvailable,
  responseDisabled,
  onUseExample,
  onPrepareRetry,
  onInspect,
  onRespond,
  renderPendingUi,
  renderUiRecord,
}: {
  task: TaskView | null;
  draft: boolean;
  draftHasWorkspace: boolean;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  onUseExample: (instruction: string) => void;
  onPrepareRetry: (instruction: string) => void;
  onInspect: (
    section: TimelineDetailSection,
    opener: HTMLButtonElement,
  ) => void;
  onRespond: (payload: UiResponsePayload) => void;
  renderPendingUi: (props: {
    taskId: string;
    pending: PendingUi;
    busy: boolean;
    respond: (payload: UiResponsePayload) => void;
  }) => ReactNode;
  renderUiRecord: (record: UiRecord) => ReactNode;
}) {
  const { locale, t } = useI18n();
  const [showJumpLatest, setShowJumpLatest] = useState(false);
  const timelineScroll = useRef<HTMLDivElement>(null);
  const followingLatest = useRef(true);
  const latestRunId = task?.runs.at(-1)?.id ?? null;

  useEffect(() => {
    followingLatest.current = true;
    setShowJumpLatest(false);
  }, [task?.id]);

  useLayoutEffect(() => {
    const viewport = timelineScroll.current;
    if (!viewport || !followingLatest.current) return;
    viewport.scrollTop = viewport.scrollHeight;
    setShowJumpLatest(false);
  }, [task?.id, revision]);

  function updateFollowState() {
    const viewport = timelineScroll.current;
    if (!viewport) return;
    const distance =
      viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
    followingLatest.current = distance <= 48;
    setShowJumpLatest(!followingLatest.current);
  }

  function jumpToLatest() {
    const viewport = timelineScroll.current;
    if (!viewport) return;
    followingLatest.current = true;
    viewport.scrollTo({ top: viewport.scrollHeight, behavior: "smooth" });
    setShowJumpLatest(false);
  }

  return (
    <>
      <div
        className="timeline-scroll"
        ref={timelineScroll}
        onScroll={updateFollowState}
      >
        <div className="timeline">
          {task?.runs.map((run) => {
            const total = tokenTotal(run);
            const activities = orderedActivity(run, task);
            return (
              <article
                key={run.id}
                className="timeline-run"
                data-active={
                  run.phase === "queued" ||
                  run.phase === "running" ||
                  run.phase === "waiting_ui" ||
                  run.phase === "stopping"
                }
              >
                <div className="workline-node" aria-hidden="true" />
                <header className="run-heading">
                  <p>{runPhaseLabel(t, run.phase)}</p>
                  <div className="run-heading-meta">
                    {total !== null && (
                      <span>
                        {t("run.tokens", {
                          count: formatInteger(locale, total),
                        })}
                      </span>
                    )}
                    {run.id === latestRunId && total !== null && total > 0n && (
                      <button
                        className="run-inspector-link focus-ring"
                        onClick={(event) =>
                          onInspect("usage", event.currentTarget)
                        }
                      >
                        {t("inspector.view_details")}
                      </button>
                    )}
                  </div>
                </header>
                <div className="run-content">
                  <Message
                    role={t("message.you")}
                    text={runInputDisplay(run.input)}
                  />
                  {activities.map((activity) => {
                    if (activity.kind === "tool")
                      return (
                        <ToolCard
                          key={`tool:${activity.value.id}`}
                          tool={activity.value}
                          onInspect={
                            run.id === latestRunId
                              ? (opener) => onInspect("tools", opener)
                              : null
                          }
                        />
                      );
                    if (activity.kind === "resolved_ui")
                      return (
                        <Fragment key={`ui:${activity.value.requestId}`}>
                          {renderUiRecord(activity.value)}
                        </Fragment>
                      );
                    const pending = activity.value;
                    return (
                      <Fragment key={`ui:${pending.requestId}`}>
                        {renderPendingUi({
                          taskId: task.id,
                          pending,
                          busy: responseDisabled,
                          respond: onRespond,
                        })}
                      </Fragment>
                    );
                  })}
                  {run.assistant && (
                    <div className="run-delivery">
                      <Message
                        role={t("message.agent")}
                        text={run.assistant}
                        agent
                      />
                      {run.assistantRedacted && (
                        <p className="projection-note">
                          {t("privacy.sensitive_hidden")}
                        </p>
                      )}
                    </div>
                  )}
                  {!run.assistant && !isNonTerminalRun(run.phase) && (
                    <p className="run-no-final">{t("run.no_final_response")}</p>
                  )}
                  {!run.assistant &&
                    run.tools.length === 0 &&
                    isNonTerminalRun(run.phase) && (
                      <p className="preparing-copy">{t("run.preparing")}</p>
                    )}
                  {run.outcome && (
                    <RunOutcome
                      run={run}
                      outcome={run.outcome}
                      composerHasDraft={composerHasDraft}
                      latest={run.id === latestRunId}
                      retryAvailable={retryAvailable && run.id === latestRunId}
                      onPrepareRetry={onPrepareRetry}
                    />
                  )}
                </div>
              </article>
            );
          })}
          {task && task.runs.length === 0 && (
            <div className="task-empty-state">
              <h2>{t("task.empty_title")}</h2>
              <p>{t("task.created_empty_body")}</p>
            </div>
          )}
          {!task && (
            <div className="task-empty-state is-new-task">
              <h2>{t(draft ? "task.empty_title" : "task.new")}</h2>
              <p>
                {t(
                  draft
                    ? draftHasWorkspace
                      ? "task.empty_body_with_workspace"
                      : "task.empty_body_without_workspace"
                    : "task.no_tasks",
                )}
              </p>
              {draft && !composerHasDraft && (
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
          )}
        </div>
      </div>

      {showJumpLatest && (
        <button className="jump-latest focus-ring" onClick={jumpToLatest}>
          {t("timeline.jump_latest")}
        </button>
      )}
    </>
  );
}

function RunOutcome({
  run,
  outcome,
  composerHasDraft,
  latest,
  retryAvailable,
  onPrepareRetry,
}: {
  run: RunView;
  outcome: NonNullable<RunView["outcome"]>;
  composerHasDraft: boolean;
  latest: boolean;
  retryAvailable: boolean;
  onPrepareRetry: (instruction: string) => void;
}) {
  const { t } = useI18n();
  const retryText = run.input.kind === "text" ? run.input.text : null;
  return (
    <section
      className="run-outcome"
      data-phase={run.phase}
      role={latest ? "status" : undefined}
    >
      <div className="run-outcome-copy">
        <p>{t(terminalMessageId(outcome))}</p>
        {run.cause && <span>{t(`cause.${run.cause}`)}</span>}
      </div>
      {retryAvailable && retryText !== null && retryableOutcome(outcome) && (
        <button
          className="outcome-action focus-ring"
          title={
            composerHasDraft ? t("run.review_draft_help") : t("run.retry_help")
          }
          onClick={() => onPrepareRetry(retryText)}
        >
          {composerHasDraft ? t("run.review_draft") : t("run.prepare_retry")}
        </button>
      )}
    </section>
  );
}

function Message({
  role,
  text,
  agent = false,
}: {
  role: string;
  text: string;
  agent?: boolean;
}) {
  return (
    <section className={`timeline-message ${agent ? "is-agent" : "is-user"}`}>
      <p className="message-role">{role}</p>
      <p className="message-body">{text}</p>
    </section>
  );
}

function ToolCard({
  tool,
  onInspect,
}: {
  tool: ToolView;
  onInspect: ((opener: HTMLButtonElement) => void) | null;
}) {
  const { locale, t } = useI18n();
  let duration: bigint | null = null;
  try {
    duration = BigInt(tool.elapsedMs);
  } catch {
    duration = null;
  }
  const state = runPhaseLabel(
    t,
    tool.state === "completed" ? "completed" : tool.state,
  );
  return (
    <details
      className="group rounded-xl border border-rule bg-canvas"
      open={tool.state === "running" || tool.state === "failed"}
    >
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 px-4 py-3">
        <span className="flex items-center gap-3">
          <span
            className={`h-2 w-2 rounded-full ${tool.state === "failed" ? "bg-danger" : tool.state === "running" ? "bg-cobalt" : "bg-live"}`}
            aria-hidden="true"
          />
          <span className="font-mono text-xs font-semibold">{tool.name}</span>
        </span>
        <span className="tool-summary-state" data-state={tool.state}>
          <strong>{state}</strong>
          {duration !== null && duration > 0n && (
            <span>
              {t("tool.duration_ms", {
                count: formatMilliseconds(locale, duration),
              })}
            </span>
          )}
        </span>
      </summary>
      <div className="grid gap-3 border-t border-rule px-4 py-4 text-xs">
        {(tool.redacted ||
          tool.inputTruncated ||
          tool.progressTruncated ||
          tool.contentTruncated) && (
          <div className="projection-notice" role="note">
            {tool.redacted && <span>{t("privacy.sensitive_hidden")}</span>}
            {(tool.inputTruncated ||
              tool.progressTruncated ||
              tool.contentTruncated) && (
              <span>{t("tool.output_shortened")}</span>
            )}
          </div>
        )}
        <CodeBlock label={t("tool.input")} value={tool.input} />
        {tool.progress && (
          <CodeBlock label={t("tool.progress")} value={tool.progress} />
        )}
        {tool.content && (
          <CodeBlock
            label={tool.isError ? t("tool.error") : t("tool.result")}
            value={tool.content}
          />
        )}
        {onInspect && (
          <button
            className="tool-inspector-link focus-ring"
            onClick={(event) => onInspect(event.currentTarget)}
          >
            {t("inspector.view_details")}
          </button>
        )}
      </div>
    </details>
  );
}
