import { RunDiagnostics } from "./RunDiagnostics.tsx";
import { runFileReferenceLinks } from "../../workbench/run-file-references.ts";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

import type {
  FileReferenceView,
  PendingUi,
  RunInputView,
  RunOutcome,
  RunView,
  TaskView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import {
  Activity,
  Conversation,
  Markdown,
  type MarkdownWebLink,
  Message,
} from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { CopyButton } from "../../components/ui/CopyButton.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { RunProcess } from "./RunProcess.tsx";
import { RunFileChangesSummary } from "./RunFileChanges.tsx";
import { deriveAssistantOutputParts } from "./assistant-output.ts";
import {
  deriveRunPresentation,
  formatRunTimestamp,
  observeRunProcessDisclosure,
  toggleRunProcessDisclosure,
  type RunProcessDisclosure,
  type RunTimestamp,
} from "./run-presentation.ts";
import {
  copyCodeText,
  copyResponseMarkdown,
  copyRunInput,
  latestCopyableResponseId,
  responseCopyEligible,
} from "./response-copy.ts";

type ReadingState = { scrollTop: number; followingLatest: boolean };
const emptyToolDisclosure: ReadonlySet<string> = new Set();

function formatAttachmentSize(value: string) {
  const bytes = Number(value);
  if (!Number.isSafeInteger(bytes) || bytes <= 0) return value;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function outcomeMessage(outcome: RunOutcome): MessageId {
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

function retryable(outcome: RunOutcome): boolean {
  return ["failed", "interrupted", "dependency_contract_failure"].includes(
    outcome,
  );
}

function terminalMessage(
  responseKind: RunView["output"]["responseKind"],
  outcome: RunOutcome,
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

function outcomeState(
  outcome: RunOutcome,
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
    ) : input.kind === "skill" ? (
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
    ) : (
      <div className="task-multimodal-input">
        {input.text && <p className="task-input-copy">{input.text}</p>}
        <div className="task-input-attachments" role="list">
          {input.attachments.map((attachment, index) => (
            <span
              className="task-input-attachment"
              role="listitem"
              key={`${attachment.displayName}:${index}`}
            >
              <span aria-hidden="true">
                {attachment.kind === "image" ? (
                  attachment.format.toUpperCase()
                ) : (
                  <Icon name="skill-file" />
                )}
              </span>
              <strong dir="auto">{attachment.displayName}</strong>
              <small>
                {attachment.kind === "image"
                  ? `${t("attachment.type.image")} · ${attachment.format.toUpperCase()}`
                  : t("attachment.type.file")}
                {` · ${formatAttachmentSize(attachment.sizeBytes)}`}
              </small>
            </span>
          ))}
        </div>
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

function MessageTime({
  className,
  time,
}: {
  className: string;
  time: RunTimestamp;
}) {
  return (
    <Tooltip.Root>
      <Tooltip.Trigger
        render={
          <time
            className={className}
            dateTime={time.dateTime}
            aria-label={time.absolute}
            tabIndex={0}
          />
        }
      >
        {time.relative}
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Positioner side="top">
          <Tooltip.Popup>{time.absolute}</Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

export function TaskContent({
  task,
  snapshotReceivedAt,
  synchronized,
  requestingStop,
  revision,
  composerHasDraft,
  retryAvailable,
  responseDisabled,
  fileChangesEnabled,
  webLink,
  onPrepareRetry,
  onPreviewFile,
  onReviewFileChanges,
  onRespond,
  renderPendingUi,
  renderTaskFollowup,
}: {
  task: TaskView | null;
  snapshotReceivedAt: number | null;
  synchronized: boolean;
  requestingStop: boolean;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  fileChangesEnabled: boolean;
  webLink: MarkdownWebLink;
  onPrepareRetry: (input: RunInputView) => void;
  onPreviewFile: (
    taskId: string,
    runId: string,
    reference: FileReferenceView,
    opener: HTMLButtonElement,
  ) => void;
  onReviewFileChanges: (
    taskId: string,
    runId: string,
    opener: HTMLButtonElement,
    displayPath?: string,
  ) => void;
  onRespond: (payload: UiResponsePayload) => void;
  renderPendingUi: (props: {
    taskId: string;
    task: TaskView;
    pending: PendingUi;
    busy: boolean;
    respond: (payload: UiResponsePayload) => void;
  }) => ReactNode;
  renderTaskFollowup?: (task: TaskView) => ReactNode;
}) {
  const { locale, t } = useI18n();
  const viewport = useRef<HTMLDivElement>(null);
  const reading = useRef(new Map<string, ReadingState>());
  const processDisclosure = useRef(new Map<string, RunProcessDisclosure>());
  const toolDisclosure = useRef(new Map<string, ReadonlySet<string>>());
  const [, setDisclosureRevision] = useState(0);
  const previousTaskId = useRef<string | null>(null);
  const [showJumpLatest, setShowJumpLatest] = useState(false);
  const [nowUnixMs, setNowUnixMs] = useState(() => Date.now());
  const hasRunTimes =
    task?.runs.some(
      (run) => run.submittedAtUnixMs !== null || run.finishedAtUnixMs !== null,
    ) ?? false;
  const currentRun = task
    ? (task.runs.find((run) => run.id === task.currentRunId) ??
      task.runs.at(-1) ??
      null)
    : null;
  const latestCopyableId = latestCopyableResponseId(task?.runs ?? []);
  const latestInputId = task?.runs.at(-1)?.id ?? null;
  const hasExcludedCompactHistory =
    task?.compacts.some(
      (compact) => compact.conversationCoverage === "excluded",
    ) || false;

  useEffect(() => {
    if (!hasRunTimes) return;
    setNowUnixMs(Date.now());
    const interval = window.setInterval(() => setNowUnixMs(Date.now()), 60_000);
    return () => window.clearInterval(interval);
  }, [hasRunTimes, task?.id]);

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

  const followDeferredOutput = useCallback(() => {
    const node = viewport.current;
    const taskId = task?.id;
    if (!node || !taskId) return;
    const saved = reading.current.get(taskId);
    if (saved && !saved.followingLatest) return;
    node.scrollTop = node.scrollHeight;
    reading.current.set(taskId, {
      scrollTop: node.scrollTop,
      followingLatest: true,
    });
    setShowJumpLatest(false);
  }, [task?.id]);

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
      {hasExcludedCompactHistory && (
        <p
          className="projection-notice conversation-coverage-notice"
          role="note"
        >
          {t("task.conversation_history_excluded")}
        </p>
      )}
      {task?.runs.map((run) => {
        const isCurrent = run.id === currentRun?.id;
        const terminal = run.terminal;
        const presentation = deriveRunPresentation(run);
        const outputParts = deriveAssistantOutputParts(run.id, run.output);
        const visibleOutputParts = outputParts.filter((part) => part.content);
        const responseCopyable = responseCopyEligible(run);
        const submittedTime = formatRunTimestamp(
          locale,
          run.submittedAtUnixMs,
          nowUnixMs,
        );
        const finishedTime = formatRunTimestamp(
          locale,
          run.finishedAtUnixMs,
          nowUnixMs,
        );
        const references = new Map(
          [...runFileReferenceLinks(run)].map(([text, reference]) => [
            text,
            {
              label: t("file_preview.open", { path: reference.displayPath }),
              onOpen: (opener: HTMLButtonElement) =>
                onPreviewFile(task.id, run.id, reference, opener),
            },
          ]),
        );
        const disclosureKey = `${task.id}:${run.id}`;
        const disclosure = observeRunProcessDisclosure(
          processDisclosure.current.get(disclosureKey),
        );
        processDisclosure.current.set(disclosureKey, disclosure);
        const expandedToolIds =
          toolDisclosure.current.get(disclosureKey) ?? emptyToolDisclosure;

        function setProcessExpanded(expanded: boolean) {
          processDisclosure.current.set(
            disclosureKey,
            toggleRunProcessDisclosure(expanded),
          );
          setDisclosureRevision((value) => value + 1);
        }

        function setToolExpanded(toolId: string, expanded: boolean) {
          const next = new Set(toolDisclosure.current.get(disclosureKey) ?? []);
          if (expanded) next.add(toolId);
          else next.delete(toolId);
          toolDisclosure.current.set(disclosureKey, next);
          setDisclosureRevision((value) => value + 1);
        }

        return (
          <section className="ai-exchange" key={`${task.id}:${run.id}`}>
            <Message role="user">
              <TaskInput input={run.input} />
            </Message>
            <div className="input-copy-actions">
              {submittedTime && (
                <MessageTime
                  className="input-submitted-time"
                  time={submittedTime}
                />
              )}
              <CopyButton
                className="input-copy-action"
                data-latest={run.id === latestInputId}
                copyLabel={t("copy.input")}
                copiedLabel={t("copy.copied")}
                failedLabel={t("copy.failed")}
                onCopy={() => copyRunInput(run.input)}
              />
            </div>
            {(visibleOutputParts.length > 0 ||
              run.output.provisionalRedacted ||
              run.output.redacted) && (
              <Message role="assistant" className="run-assistant-output">
                {visibleOutputParts.map((part) => {
                  const streaming = part.disposition === "provisional";
                  const response =
                    part.disposition === "final" ||
                    part.disposition === "partial";
                  return (
                    <Markdown
                      className={`assistant-output-part ${
                        response ? "agent-response" : "run-commentary-item"
                      }`}
                      data-output-identity={part.identity}
                      data-output-disposition={part.disposition}
                      key={part.identity}
                      references={streaming ? undefined : references}
                      interactive={!streaming}
                      webLink={streaming ? undefined : webLink}
                      streaming={streaming}
                      onStreamingCommit={followDeferredOutput}
                      codeCopy={
                        response && responseCopyable
                          ? {
                              label: t("copy.code"),
                              copiedLabel: t("copy.copied"),
                              failedLabel: t("copy.failed"),
                              onCopy: copyCodeText,
                            }
                          : undefined
                      }
                    >
                      {part.content}
                    </Markdown>
                  );
                })}
                {(run.output.provisionalRedacted || run.output.redacted) && (
                  <p className="projection-note">
                    {t("privacy.sensitive_hidden")}
                  </p>
                )}
              </Message>
            )}
            {presentation.active && (
              <RunProcess
                presentation={presentation}
                reviewingPermission={
                  isCurrent && task.permissionReviewState === "reviewing"
                }
                fileChanges={fileChangesEnabled ? run.fileChanges : null}
                elapsedMs={run.elapsedMs}
                snapshotReceivedAt={snapshotReceivedAt}
                synchronized={synchronized}
                requestingStop={requestingStop}
                expanded={disclosure.expanded}
                onExpandedChange={setProcessExpanded}
                expandedToolIds={expandedToolIds}
                onToolExpandedChange={setToolExpanded}
                onReviewFileChanges={(displayPath, opener) =>
                  onReviewFileChanges(task.id, run.id, opener, displayPath)
                }
              />
            )}
            {isCurrent && task.pendingUi && (
              <div className="ai-exchange-intervention">
                {renderPendingUi({
                  taskId: task.id,
                  task,
                  pending: task.pendingUi,
                  busy: responseDisabled,
                  respond: onRespond,
                })}
              </div>
            )}
            {task.uiHistory
              .filter(
                (record) =>
                  record.runId === run.id && record.answeredBy === "reviewer",
              )
              .map((record) => (
                <details
                  className="projection-note"
                  key={`review-${record.requestId}`}
                >
                  <summary>
                    {t("approval.answered_by_reviewer")} · {record.detail} ·{" "}
                    {t(`ui.state.${record.state}`)}
                  </summary>
                  <p>{record.reviewReason}</p>
                </details>
              ))}
            {fileChangesEnabled && run.fileChanges && (
              <RunFileChangesSummary
                fileChanges={run.fileChanges}
                onReview={(opener) =>
                  onReviewFileChanges(task.id, run.id, opener)
                }
              />
            )}
            {!presentation.active && presentation.processVisible && (
              <RunProcess
                presentation={presentation}
                reviewingPermission={false}
                fileChanges={fileChangesEnabled ? run.fileChanges : null}
                elapsedMs={run.elapsedMs}
                synchronized={synchronized}
                expanded={disclosure.expanded}
                onExpandedChange={setProcessExpanded}
                expandedToolIds={expandedToolIds}
                onToolExpandedChange={setToolExpanded}
                onReviewFileChanges={(displayPath, opener) =>
                  onReviewFileChanges(task.id, run.id, opener, displayPath)
                }
              />
            )}
            {presentation.showTerminalNotice && terminal && (
              <Activity
                className={
                  terminal.cause === "provider_failure"
                    ? "run-terminal-activity"
                    : undefined
                }
                state={outcomeState(terminal.outcome)}
                label={t(
                  terminal.cause === "provider_failure"
                    ? "run.provider_failure.title"
                    : terminalMessage(
                        run.output.responseKind,
                        terminal.outcome,
                      ),
                )}
                detail={
                  terminal.cause === "provider_failure" ? (
                    <span className="run-terminal-detail">
                      <span>
                        {t(
                          run.output.responseKind === "partial"
                            ? "run.provider_failure.partial_impact"
                            : "run.provider_failure.no_response_impact",
                        )}
                      </span>
                      {run.tools.length > 0 && (
                        <span>
                          {t("run.provider_failure.review_tool_effects")}
                        </span>
                      )}
                    </span>
                  ) : terminal.cause ? (
                    t(`cause.${terminal.cause}`)
                  ) : terminal.outcome === "completed" &&
                    run.output.responseKind !== "partial" ? (
                    t("run.no_final_response")
                  ) : undefined
                }
                announce={isCurrent}
                action={
                  (isCurrent &&
                    retryAvailable &&
                    retryable(terminal.outcome)) ||
                  terminal.cause === "provider_failure" ? (
                    <div className="run-terminal-actions">
                      {isCurrent &&
                        retryAvailable &&
                        retryable(terminal.outcome) && (
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
                        )}
                      <RunDiagnostics run={run} />
                    </div>
                  ) : undefined
                }
              />
            )}
            {run.conversationCoverage === "excluded" && (
              <p
                className="projection-notice run-conversation-coverage-notice"
                role="note"
              >
                {t("run.conversation_history_excluded")}
              </p>
            )}
            {responseCopyable && (
              <div className="response-copy-actions">
                <CopyButton
                  className="response-copy-action"
                  data-latest={run.id === latestCopyableId}
                  copyLabel={t("copy.response")}
                  copiedLabel={t("copy.copied")}
                  failedLabel={t("copy.failed")}
                  onCopy={() => copyResponseMarkdown(run.output.response)}
                />
                {finishedTime && (
                  <MessageTime
                    className="response-finished-time"
                    time={finishedTime}
                  />
                )}
              </div>
            )}
          </section>
        );
      })}
      {task && renderTaskFollowup?.(task)}
      {task && task.runs.length === 0 && (
        <div className="ai-conversation-empty">
          <h2>{t("task.empty_title")}</h2>
          <p>{t("task.created_empty_body")}</p>
        </div>
      )}
    </Conversation>
  );
}
