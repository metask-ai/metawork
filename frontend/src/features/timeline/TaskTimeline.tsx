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
  SessionView,
  ToolView,
  UiRecord,
  UiResponsePayload,
} from "../../host/contracts.ts";
import { formatInteger, formatMilliseconds } from "../../i18n/formatters.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";

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

type RunActivity =
  | { kind: "tool"; order: string; value: ToolView }
  | { kind: "resolved_ui"; order: string; value: UiRecord }
  | { kind: "pending_ui"; order: string; value: PendingUi };

function orderedActivity(run: RunView, session: SessionView): RunActivity[] {
  const items: RunActivity[] = [
    ...run.tools.map((value) => ({
      kind: "tool" as const,
      order: value.order,
      value,
    })),
    ...session.uiHistory
      .filter((record) => record.runId === run.id)
      .map((value) => ({
        kind: "resolved_ui" as const,
        order: value.order,
        value,
      })),
  ];
  if (session.pendingUi?.runId === run.id)
    items.push({
      kind: "pending_ui",
      order: session.pendingUi.order,
      value: session.pendingUi,
    });
  return items.sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
}

export function TaskTimeline({
  session,
  revision,
  responseDisabled,
  onRespond,
  renderPendingUi,
  renderUiRecord,
}: {
  session: SessionView | null;
  revision: string;
  responseDisabled: boolean;
  onRespond: (payload: UiResponsePayload) => void;
  renderPendingUi: (props: {
    pending: PendingUi;
    answers: string[];
    busy: boolean;
    setAnswers: (answers: string[]) => void;
    respond: (payload: UiResponsePayload) => void;
  }) => ReactNode;
  renderUiRecord: (record: UiRecord) => ReactNode;
}) {
  const { locale, t } = useI18n();
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const [showJumpLatest, setShowJumpLatest] = useState(false);
  const timelineScroll = useRef<HTMLDivElement>(null);
  const followingLatest = useRef(true);

  useEffect(() => {
    followingLatest.current = true;
    setShowJumpLatest(false);
  }, [session?.id]);

  useEffect(() => {
    const requestId = session?.pendingUi?.requestId;
    setAnswers((current) => {
      if (!requestId) return {};
      const retained = current[requestId];
      return retained ? { [requestId]: retained } : {};
    });
  }, [session?.pendingUi?.requestId]);

  useLayoutEffect(() => {
    const viewport = timelineScroll.current;
    if (!viewport || !followingLatest.current) return;
    viewport.scrollTop = viewport.scrollHeight;
    setShowJumpLatest(false);
  }, [session?.id, revision]);

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
          {session?.runs.map((run) => {
            const total = tokenTotal(run);
            const activities = orderedActivity(run, session);
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
                  <p>
                    {t("run.label", { id: run.id })} ·{" "}
                    {runPhaseLabel(t, run.phase)}
                  </p>
                  {total !== null && (
                    <span>
                      {t("run.tokens", {
                        count: formatInteger(locale, total),
                      })}
                    </span>
                  )}
                </header>
                <div className="run-content">
                  <Message role={t("message.you")} text={run.user} />
                  {run.assistant && (
                    <div>
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
                  {activities.map((activity) => {
                    if (activity.kind === "tool")
                      return (
                        <ToolCard
                          key={`tool:${activity.value.id}`}
                          tool={activity.value}
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
                          pending,
                          answers: answers[pending.requestId] ?? [],
                          busy: responseDisabled,
                          setAnswers: (next) =>
                            setAnswers((current) => ({
                              ...current,
                              [pending.requestId]: next,
                            })),
                          respond: onRespond,
                        })}
                      </Fragment>
                    );
                  })}
                  {!run.assistant && run.tools.length === 0 && (
                    <p className="preparing-copy">{t("run.preparing")}</p>
                  )}
                  {run.outcome && (
                    <div className="run-outcome" data-phase={run.phase}>
                      <p>
                        {t("run.outcome", {
                          outcome: t(`outcome.${run.outcome}`),
                        })}
                      </p>
                      {run.cause && (
                        <span>
                          {t("run.cause", {
                            cause: t(`cause.${run.cause}`),
                          })}
                        </span>
                      )}
                    </div>
                  )}
                </div>
              </article>
            );
          })}
          {session && session.runs.length === 0 && (
            <div className="task-empty-state">
              <h2>{t("task.empty_title")}</h2>
              <p>{t("task.empty_body")}</p>
            </div>
          )}
          {!session && (
            <div className="task-empty-state">
              <h2>{t("task.new")}</h2>
              <p>{t("task.no_tasks")}</p>
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

function ToolCard({ tool }: { tool: ToolView }) {
  const { locale, t } = useI18n();
  let duration: bigint | null = null;
  try {
    duration = BigInt(tool.elapsedMs);
  } catch {
    duration = null;
  }
  return (
    <details
      className="group rounded-xl border border-rule bg-canvas"
      open={tool.state === "running" || tool.state === "failed"}
    >
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 px-4 py-3">
        <span className="flex items-center gap-3">
          <span
            className={`h-2 w-2 rounded-full ${tool.state === "failed" ? "bg-danger" : tool.state === "running" ? "bg-cobalt" : "bg-live"}`}
          />
          <span className="font-mono text-xs font-semibold">{tool.name}</span>
        </span>
        <span className="font-mono text-[10px] text-muted">
          {duration === null || duration === 0n
            ? runPhaseLabel(
                t,
                tool.state === "completed" ? "completed" : tool.state,
              )
            : t("tool.duration_ms", {
                count: formatMilliseconds(locale, duration),
              })}
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
      </div>
    </details>
  );
}
