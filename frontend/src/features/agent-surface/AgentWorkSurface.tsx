import {
  Fragment,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

import {
  CodeBlock,
  Conversation,
  ConversationContent,
  Message,
  MessageContent,
  MessageResponse,
  Tool,
  ToolContent,
  ToolField,
  ToolHeader,
} from "../../components/ai/index.ts";
import type {
  PendingUi,
  CompactView,
  RunInputView,
  RunView,
  TaskView,
  ToolView,
  UiRecord,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import { projectConversation } from "./conversation-projection.ts";
import { formatInteger, formatMilliseconds } from "../../i18n/formatters.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";

type AgentDetailSection = "tools" | "usage";

function tokenTotal(usage: RunView["usage"]): bigint | null {
  try {
    return BigInt(usage.input) + BigInt(usage.output);
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

function CompactConversationEvent({ compact }: { compact: CompactView }) {
  const { locale, t } = useI18n();
  const values = {
    before: formatInteger(locale, BigInt(compact.beforeContextTokens)),
    after: formatInteger(locale, BigInt(compact.afterContextTokens)),
  };
  const message =
    compact.phase === "queued" ||
    compact.phase === "compacting" ||
    compact.phase === "stopping"
      ? t(`compact.timeline.${compact.phase}`)
      : compact.phase === "compacted" || compact.phase === "degraded"
        ? t(`compact.timeline.${compact.phase}`, values)
        : t(`compact.timeline.${compact.phase}`);
  return (
    <div
      className="conversation-compaction"
      data-active={
        compact.phase === "queued" ||
        compact.phase === "compacting" ||
        compact.phase === "stopping"
      }
    >
      <span className="conversation-compaction-mark" aria-hidden="true" />
      <p>{message}</p>
    </div>
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

export function AgentWorkSurface({
  task,
  revision,
  composerHasDraft,
  retryAvailable,
  responseDisabled,
  onPrepareRetry,
  onInspect,
  onRespond,
  renderPendingUi,
  renderUiRecord,
}: {
  task: TaskView | null;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  onPrepareRetry: (input: RunInputView) => void;
  onInspect: (section: AgentDetailSection, opener: HTMLButtonElement) => void;
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
  const conversationScroll = useRef<HTMLDivElement>(null);
  const followingLatest = useRef(true);
  const entries = projectConversation(task);
  const latestRunId = task?.runs.at(-1)?.id ?? null;

  useEffect(() => {
    followingLatest.current = true;
    setShowJumpLatest(false);
  }, [task?.id]);

  useLayoutEffect(() => {
    const viewport = conversationScroll.current;
    if (!viewport) return;
    if (!task) {
      viewport.scrollTop = 0;
      setShowJumpLatest(false);
      return;
    }
    if (!followingLatest.current) return;
    viewport.scrollTop = viewport.scrollHeight;
    setShowJumpLatest(false);
  }, [task?.id, revision]);

  function updateFollowState() {
    const viewport = conversationScroll.current;
    if (!viewport) return;
    const distance =
      viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
    followingLatest.current = distance <= 48;
    setShowJumpLatest(!followingLatest.current);
  }

  function jumpToLatest() {
    const viewport = conversationScroll.current;
    if (!viewport) return;
    followingLatest.current = true;
    viewport.scrollTo({ top: viewport.scrollHeight, behavior: "smooth" });
    setShowJumpLatest(false);
  }

  return (
    <Conversation className="agent-surface">
      <div
        className="agent-surface-scroll"
        ref={conversationScroll}
        onScroll={updateFollowState}
      >
        <ConversationContent className="agent-surface-content">
          {entries.map((entry) => {
            if (entry.kind === "compact") {
              return (
                <CompactConversationEvent
                  key={entry.id}
                  compact={entry.compact}
                />
              );
            }
            const run = entry;
            const total = tokenTotal(run.usage);
            return (
              <Fragment key={run.runId}>
                <article
                  className="agent-run"
                  data-active={
                    run.phase === "queued" ||
                    run.phase === "running" ||
                    run.phase === "waiting_ui" ||
                    run.phase === "stopping"
                  }
                >
                  <header className="agent-run-header">
                    <span className="agent-run-state" aria-hidden="true" />
                    <p>{runPhaseLabel(t, run.phase)}</p>
                    <div className="agent-run-meta">
                      {total !== null && (
                        <span>
                          {t("run.tokens", {
                            count: formatInteger(locale, total),
                          })}
                        </span>
                      )}
                      {run.runId === latestRunId &&
                        total !== null &&
                        total > 0n && (
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
                  <div className="agent-run-content">
                    <RunInputMessage input={run.input} />
                    {run.activities.map((activity) => {
                      if (activity.kind === "tool")
                        return (
                          <ToolCard
                            key={`tool:${activity.id}`}
                            tool={activity.value}
                            onInspect={
                              run.runId === latestRunId
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
                      return task ? (
                        <Fragment key={`ui:${pending.requestId}`}>
                          {renderPendingUi({
                            taskId: task.id,
                            pending,
                            busy: responseDisabled,
                            respond: onRespond,
                          })}
                        </Fragment>
                      ) : null;
                    })}
                    {run.assistant && (
                      <div className="run-delivery">
                        <Message
                          from="assistant"
                          className="agent-message is-agent"
                        >
                          <MessageContent>
                            <MessageResponse
                              streaming={run.assistant.streaming}
                            >
                              {run.assistant.markdown}
                            </MessageResponse>
                          </MessageContent>
                        </Message>
                        {run.assistant.redacted && (
                          <p className="projection-note">
                            {t("privacy.sensitive_hidden")}
                          </p>
                        )}
                      </div>
                    )}
                    {!run.assistant && !isNonTerminalRun(run.phase) && (
                      <p className="run-no-final">
                        {t("run.no_final_response")}
                      </p>
                    )}
                    {!run.assistant &&
                      run.activities.length === 0 &&
                      isNonTerminalRun(run.phase) && (
                        <p className="preparing-copy">{t("run.preparing")}</p>
                      )}
                    {run.outcome && (
                      <RunOutcome
                        phase={run.phase}
                        cause={run.cause}
                        input={run.input}
                        outcome={run.outcome}
                        composerHasDraft={composerHasDraft}
                        latest={run.runId === latestRunId}
                        retryAvailable={
                          retryAvailable && run.runId === latestRunId
                        }
                        onPrepareRetry={onPrepareRetry}
                      />
                    )}
                  </div>
                </article>
              </Fragment>
            );
          })}
          {task && task.runs.length === 0 && (
            <div className="task-empty-state">
              <h2>{t("task.empty_title")}</h2>
              <p>{t("task.created_empty_body")}</p>
            </div>
          )}
        </ConversationContent>
      </div>

      {showJumpLatest && (
        <button className="jump-latest focus-ring" onClick={jumpToLatest}>
          {t("timeline.jump_latest")}
        </button>
      )}
    </Conversation>
  );
}

function RunOutcome({
  phase,
  cause,
  input,
  outcome,
  composerHasDraft,
  latest,
  retryAvailable,
  onPrepareRetry,
}: {
  phase: RunView["phase"];
  cause: RunView["cause"];
  input: RunView["input"];
  outcome: NonNullable<RunView["outcome"]>;
  composerHasDraft: boolean;
  latest: boolean;
  retryAvailable: boolean;
  onPrepareRetry: (input: RunInputView) => void;
}) {
  const { t } = useI18n();
  return (
    <section className="agent-run-outcome" data-phase={phase}>
      <div
        className="agent-run-outcome-copy"
        role={latest ? "status" : undefined}
      >
        <p>{t(terminalMessageId(outcome))}</p>
        {cause && <span>{t(`cause.${cause}`)}</span>}
      </div>
      {retryAvailable && retryableOutcome(outcome) && (
        <button
          className="agent-outcome-action focus-ring"
          title={
            composerHasDraft ? t("run.review_draft_help") : t("run.retry_help")
          }
          onClick={() => onPrepareRetry(input)}
        >
          {composerHasDraft ? t("run.review_draft") : t("run.prepare_retry")}
        </button>
      )}
    </section>
  );
}

function RunInputMessage({ input }: { input: RunInputView }) {
  const { t } = useI18n();
  if (input.kind === "text")
    return (
      <Message from="user" className="agent-user-message">
        <MessageContent>
          <p className="message-body">{input.text}</p>
        </MessageContent>
      </Message>
    );
  return (
    <Message from="user" className="agent-user-message agent-skill-message">
      <MessageContent>
        <div className="agent-skill-input">
          <span className="agent-skill-token">
            /{input.invocationName}
            <small>{t("slash.group.skills")}</small>
          </span>
          {input.argumentValues.length > 0 && (
            <span className="agent-skill-arguments">
              {input.argumentValues.map((value, index) => (
                <code key={index}>{value}</code>
              ))}
            </span>
          )}
        </div>
      </MessageContent>
    </Message>
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
    <Tool
      className="agent-tool"
      state={tool.state}
      open={tool.state === "running" || tool.state === "failed"}
    >
      <ToolHeader
        className="agent-tool-summary"
        name={tool.name}
        state={tool.state}
        status={state}
        meta={
          duration !== null && duration > 0n ? (
            <span>
              {t("tool.duration_ms", {
                count: formatMilliseconds(locale, duration),
              })}
            </span>
          ) : undefined
        }
      />
      <ToolContent className="agent-tool-body">
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
        <ToolField label={t("tool.input")}>
          <CodeBlock label={t("tool.input")} value={tool.input} />
        </ToolField>
        {tool.progress && (
          <ToolField label={t("tool.progress")}>
            <CodeBlock label={t("tool.progress")} value={tool.progress} />
          </ToolField>
        )}
        {tool.content && (
          <ToolField label={tool.isError ? t("tool.error") : t("tool.result")}>
            <CodeBlock
              label={tool.isError ? t("tool.error") : t("tool.result")}
              value={tool.content}
            />
          </ToolField>
        )}
        {onInspect && (
          <button
            className="tool-inspector-link focus-ring"
            onClick={(event) => onInspect(event.currentTarget)}
          >
            {t("inspector.view_details")}
          </button>
        )}
      </ToolContent>
    </Tool>
  );
}
