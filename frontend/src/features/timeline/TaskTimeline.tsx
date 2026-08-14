import {
  Fragment,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

import { CodeBlock } from "../../components/ui/CodeBlock.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import type {
  PendingUi,
  CompactView,
  RunInputView,
  RunView,
  TaskView,
  ToolView,
  FilePreview,
  UiRecord,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import { formatInteger, formatMilliseconds } from "../../i18n/formatters.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";

type TimelineDetailSection = "tools" | "usage";

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

function CompactTimelineEvent({ compact }: { compact: CompactView }) {
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
      className="timeline-system-event"
      data-active={
        compact.phase === "queued" ||
        compact.phase === "compacting" ||
        compact.phase === "stopping"
      }
    >
      <span className="timeline-system-mark" aria-hidden="true" />
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
  revision,
  composerHasDraft,
  retryAvailable,
  responseDisabled,
  onPrepareRetry,
  onInspect,
  onRespond,
  renderPendingUi,
  renderUiRecord,
  previewFile,
}: {
  task: TaskView | null;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  onPrepareRetry: (input: RunInputView) => void;
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
  previewFile: (fileReferenceId: string) => Promise<FilePreview>;
}) {
  const { locale, t } = useI18n();
  const [showJumpLatest, setShowJumpLatest] = useState(false);
  const [filePreview, setFilePreview] = useState<FilePreview | null>(null);
  const [filePreviewBusy, setFilePreviewBusy] = useState(false);
  const timelineScroll = useRef<HTMLDivElement>(null);
  const followingLatest = useRef(true);
  const latestRunId = task?.runs.at(-1)?.id ?? null;

  useEffect(() => {
    followingLatest.current = true;
    setShowJumpLatest(false);
    setFilePreview(null);
  }, [task?.id]);

  useLayoutEffect(() => {
    const viewport = timelineScroll.current;
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

  async function openFilePreview(fileReferenceId: string) {
    setFilePreviewBusy(true);
    try {
      setFilePreview(await previewFile(fileReferenceId));
    } finally {
      setFilePreviewBusy(false);
    }
  }

  return (
    <div className="timeline-region">
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
              <Fragment key={run.id}>
                <article
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
                      {run.id === latestRunId &&
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
                  <div className="run-content">
                    <RunInputMessage input={run.input} />
                    {activities.map((activity) => {
                      if (activity.kind === "tool")
                        return (
                          <ToolCard
                            key={`tool:${activity.value.id}`}
                            tool={activity.value}
                            onPreviewFile={openFilePreview}
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
                        <section className="timeline-message is-agent">
                          <p className="message-body">{run.assistant}</p>
                        </section>
                        {run.assistantRedacted && (
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
                        retryAvailable={
                          retryAvailable && run.id === latestRunId
                        }
                        onPrepareRetry={onPrepareRetry}
                      />
                    )}
                  </div>
                </article>
                {task.compacts
                  .filter((compact) => compact.afterRunId === run.id)
                  .map((compact) => (
                    <CompactTimelineEvent
                      key={compact.operationId}
                      compact={compact}
                    />
                  ))}
              </Fragment>
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
      {(filePreviewBusy || filePreview) && (
        <aside className="file-preview-pane" aria-label="File preview">
          <header className="file-preview-header">
            <strong>{filePreview?.displayPath ?? "Loading preview..."}</strong>
            <button
              className="file-preview-close focus-ring"
              type="button"
              onClick={() => setFilePreview(null)}
              aria-label="Close file preview"
            >
              x
            </button>
          </header>
          {filePreviewBusy ? (
            <p className="file-preview-status">Loading...</p>
          ) : filePreview?.state === "ready" ||
            filePreview?.state === "truncated" ? (
            <pre className="file-preview-content">{filePreview.content}</pre>
          ) : (
            <p className="file-preview-status">
              {filePreview?.state ?? "error"}
            </p>
          )}
        </aside>
      )}

      {showJumpLatest && (
        <button className="jump-latest focus-ring" onClick={jumpToLatest}>
          {t("timeline.jump_latest")}
        </button>
      )}
    </div>
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
  onPrepareRetry: (input: RunInputView) => void;
}) {
  const { t } = useI18n();
  return (
    <section className="run-outcome" data-phase={run.phase}>
      <div className="run-outcome-copy" role={latest ? "status" : undefined}>
        <p>{t(terminalMessageId(outcome))}</p>
        {run.cause && <span>{t(`cause.${run.cause}`)}</span>}
      </div>
      {retryAvailable && retryableOutcome(outcome) && (
        <button
          className="outcome-action focus-ring"
          title={
            composerHasDraft ? t("run.review_draft_help") : t("run.retry_help")
          }
          onClick={() => onPrepareRetry(run.input)}
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
      <section className="timeline-message is-user">
        <p className="message-body">{input.text}</p>
      </section>
    );
  return (
    <section className="timeline-message is-user is-skill">
      <div className="timeline-skill-input">
        <span className="timeline-skill-token">
          /{input.invocationName}
          <small>{t("slash.group.skills")}</small>
        </span>
        {input.argumentValues.length > 0 && (
          <span className="timeline-skill-arguments">
            {input.argumentValues.map((value, index) => (
              <code key={index}>{value}</code>
            ))}
          </span>
        )}
      </div>
    </section>
  );
}

function ToolCard({
  tool,
  onInspect,
  onPreviewFile,
}: {
  tool: ToolView;
  onInspect: ((opener: HTMLButtonElement) => void) | null;
  onPreviewFile: (fileReferenceId: string) => void;
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
      className="tool-card"
      data-state={tool.state}
      open={tool.state === "running" || tool.state === "failed"}
    >
      <summary className="tool-card-summary">
        <span className="tool-card-identity">
          <span
            className="tool-state-dot"
            data-state={tool.state}
            aria-hidden="true"
          />
          <span className="tool-card-name">{tool.name}</span>
        </span>
        <span className="tool-card-meta">
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
          <span className="tool-disclosure" aria-hidden="true">
            <Icon name="chevron" />
          </span>
        </span>
      </summary>
      <div className="tool-card-body">
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
        {tool.fileRefs.length > 0 && (
          <div className="tool-file-references" aria-label="Referenced files">
            {tool.fileRefs.map((reference) => (
              <button
                key={reference.id}
                type="button"
                className="tool-file-chip focus-ring"
                onClick={() => onPreviewFile(reference.id)}
              >
                <span aria-hidden="true">📄</span>
                <span>{reference.displayPath || reference.title}</span>
                {reference.range && (
                  <small>:{reference.range.start.line}</small>
                )}
              </button>
            ))}
          </div>
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
