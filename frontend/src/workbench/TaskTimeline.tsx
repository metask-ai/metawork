import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ButtonHTMLAttributes,
} from "react";

import type {
  PendingUi,
  RunView,
  SessionView,
  ToolView,
  UiRecord,
  UiResponsePayload,
} from "../host/contracts.ts";
import { formatInteger, formatMilliseconds } from "../i18n/formatters.ts";
import { useI18n, type MessageId } from "../i18n/context.ts";

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
}: {
  session: SessionView | null;
  revision: string;
  responseDisabled: boolean;
  onRespond: (payload: UiResponsePayload) => void;
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
                        <UiRecordCard
                          key={`ui:${activity.value.requestId}`}
                          record={activity.value}
                        />
                      );
                    const pending = activity.value;
                    return (
                      <ApprovalPanel
                        key={`ui:${pending.requestId}`}
                        pending={pending}
                        answers={answers[pending.requestId] ?? []}
                        busy={responseDisabled}
                        setAnswers={(next) =>
                          setAnswers((current) => ({
                            ...current,
                            [pending.requestId]: next,
                          }))
                        }
                        respond={onRespond}
                      />
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

function UiRecordCard({ record }: { record: UiRecord }) {
  const { t } = useI18n();
  return (
    <section className="ui-record" data-state={record.state}>
      <div>
        <p>{t(`ui.kind.${record.kind}`)}</p>
        <strong>{t(`ui.state.${record.state}`)}</strong>
      </div>
      {record.detail && <p>{record.detail}</p>}
      {(record.detailTruncated || record.redacted) && (
        <span>
          {record.redacted
            ? t("privacy.sensitive_hidden")
            : t("tool.output_shortened")}
        </span>
      )}
    </section>
  );
}

function CodeBlock({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="mb-1 font-mono text-[9px] tracking-[0.14em] text-muted uppercase">
        {label}
      </p>
      <pre className="max-h-64 overflow-auto whitespace-pre-wrap rounded-lg bg-graphite p-3 font-mono text-[11px] leading-5 text-white/85">
        {value}
      </pre>
    </div>
  );
}

function ApprovalPanel({
  pending,
  answers,
  busy,
  setAnswers,
  respond,
}: {
  pending: PendingUi;
  answers: string[];
  busy: boolean;
  setAnswers: (answers: string[]) => void;
  respond: (payload: UiResponsePayload) => void;
}) {
  const { t } = useI18n();
  return (
    <section
      id={`ui-request-${pending.requestId}`}
      tabIndex={-1}
      className="inline-request rounded-2xl border border-amber bg-amber/8 p-5"
    >
      <p className="font-mono text-[10px] tracking-[0.14em] text-amber-ink uppercase">
        {t("approval.response_required", { id: pending.runId })}
      </p>
      {pending.redacted && (
        <p className="projection-note" role="note">
          {t("privacy.sensitive_hidden")}
        </p>
      )}
      {pending.kind === "permission" && (
        <div className="mt-4">
          <h3 className="font-semibold">
            {t("approval.allow_tool", { tool: pending.tool })}
          </h3>
          <CodeBlock label={t("approval.arguments")} value={pending.args} />
          <div className="mt-4 grid grid-cols-2 gap-2">
            <DecisionButton
              disabled={busy}
              onClick={() =>
                respond({ kind: "permission", permission: "deny_once" })
              }
            >
              {t("approval.deny")}
            </DecisionButton>
            <DecisionButton
              primary
              disabled={busy}
              onClick={() =>
                respond({ kind: "permission", permission: "allow_once" })
              }
            >
              {t("approval.allow_once")}
            </DecisionButton>
          </div>
        </div>
      )}
      {pending.kind === "ask_question" && (
        <div className="mt-4 space-y-5">
          {pending.questions.map((question, index) => (
            <div key={`${question.header}-${index}`}>
              <p className="text-sm font-semibold">{question.question}</p>
              {question.multi && question.options.length > 0 ? (
                <div className="mt-3 space-y-2">
                  {question.options.map((option) => {
                    const selected = (answers[index] ?? "")
                      .split(", ")
                      .filter(Boolean);
                    return (
                      <label
                        key={option.label}
                        className="flex items-start gap-3 rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                      >
                        <input
                          className="mt-1 accent-cobalt"
                          type="checkbox"
                          checked={selected.includes(option.label)}
                          onChange={(event) => {
                            const choices = event.target.checked
                              ? [...selected, option.label]
                              : selected.filter(
                                  (label) => label !== option.label,
                                );
                            const next = [...answers];
                            next[index] = choices.join(", ");
                            setAnswers(next);
                          }}
                        />
                        <span>
                          <span className="font-medium">{option.label}</span>
                          {option.description && (
                            <span className="mt-0.5 block text-xs leading-5 text-muted">
                              {option.description}
                            </span>
                          )}
                        </span>
                      </label>
                    );
                  })}
                </div>
              ) : question.options.length > 0 ? (
                <select
                  className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                  value={answers[index] ?? ""}
                  onChange={(event) => {
                    const next = [...answers];
                    next[index] = event.target.value;
                    setAnswers(next);
                  }}
                >
                  <option value="">{t("approval.choose")}</option>
                  {question.options.map((option) => (
                    <option key={option.label} value={option.label}>
                      {option.label}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                  value={answers[index] ?? ""}
                  onChange={(event) => {
                    const next = [...answers];
                    next[index] = event.target.value;
                    setAnswers(next);
                  }}
                />
              )}
            </div>
          ))}
          <DecisionButton
            primary
            disabled={
              busy ||
              answers.length !== pending.questions.length ||
              answers.some((answer) => !answer)
            }
            onClick={() => respond({ kind: "answers", answers })}
          >
            {t("approval.send_answers")}
          </DecisionButton>
        </div>
      )}
      {pending.kind === "plan_approval" && (
        <div className="mt-4">
          <h3 className="font-semibold">{t("approval.review_plan")}</h3>
          <p className="mt-3 whitespace-pre-wrap text-xs leading-6 text-muted">
            {pending.plan}
          </p>
          <div className="mt-4 grid grid-cols-2 gap-2">
            <DecisionButton
              disabled={busy}
              onClick={() =>
                respond({ kind: "plan_approval", planApproval: "reject" })
              }
            >
              {t("approval.reject_plan")}
            </DecisionButton>
            <DecisionButton
              primary
              disabled={busy}
              onClick={() =>
                respond({
                  kind: "plan_approval",
                  planApproval: "approve_default",
                })
              }
            >
              {t("approval.approve_plan")}
            </DecisionButton>
          </div>
        </div>
      )}
      {pending.kind === "custom" && (
        <div className="mt-4">
          <h3 className="font-semibold">{pending.customKind}</h3>
          <CodeBlock label={t("approval.request")} value={pending.payload} />
          <p className="mt-3 text-xs text-muted">
            {t("approval.custom_request")}
          </p>
        </div>
      )}
    </section>
  );
}

function DecisionButton({
  primary = false,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { primary?: boolean }) {
  return (
    <button
      {...props}
      className={`focus-ring rounded-lg px-3 py-2 text-sm font-semibold disabled:opacity-40 ${primary ? "bg-amber-ink text-white" : "border border-amber/60 text-amber-ink"}`}
    />
  );
}
