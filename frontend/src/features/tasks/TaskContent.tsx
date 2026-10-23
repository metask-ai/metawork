import {
  GeneratedImagePreview,
  type FilePreviewLoader,
} from "./GeneratedImagePreview.tsx";
import { RunDiagnostics } from "./RunDiagnostics.tsx";
import { AdditionalInput } from "./AdditionalInput.tsx";
import { MessageInfoBar } from "./MessageInfoBar.tsx";
import { runFileReferenceLinks } from "../../workbench/run-file-references.ts";
import {
  Fragment,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

import type {
  FileReferenceView,
  OutputActionHandler,
  PendingUi,
  RunInputView,
  RunOutcome,
  RunView,
  TaskView,
  WaitingInputView,
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
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { RunProcess } from "./RunProcess.tsx";
import { RunFileChangesSummary } from "./RunFileChanges.tsx";
import {
  RunOutputs,
  type OutputEditHandler,
  type OutputPreviewHandler,
  type OutputPreviewRenderer,
} from "./RunOutputs.tsx";
import { deriveRunReadingFlow } from "./assistant-output.ts";
import {
  deriveRunPresentation,
  formatRunTimestamp,
  observeRunProcessDisclosure,
  toggleRunProcessDisclosure,
  type RunProcessDisclosure,
} from "./run-presentation.ts";
import {
  copyCodeText,
  copyResponseMarkdown,
  copyRunInput,
  latestCopyableResponseId,
  responseCopyEligible,
} from "./response-copy.ts";

type ReadingState = {
  scrollTop: number;
  followingLatest: boolean;
  anchor?: { runId: string; offset: number };
};

function readingAnchor(viewport: HTMLDivElement): ReadingState["anchor"] {
  const bounds = viewport.getBoundingClientRect();
  for (const run of viewport.querySelectorAll<HTMLElement>("[data-run-id]")) {
    const rect = run.getBoundingClientRect();
    if (rect.bottom > bounds.top && rect.top < bounds.bottom)
      return { runId: run.dataset.runId!, offset: rect.top - bounds.top };
  }
  return undefined;
}

function restoreReadingAnchor(viewport: HTMLDivElement, saved: ReadingState) {
  const anchor = saved.anchor;
  if (!anchor) return false;
  const run = Array.from(
    viewport.querySelectorAll<HTMLElement>("[data-run-id]"),
  ).find((node) => node.dataset.runId === anchor.runId);
  if (!run) return false;
  viewport.scrollTop +=
    run.getBoundingClientRect().top -
    viewport.getBoundingClientRect().top -
    anchor.offset;
  return true;
}
export function createTaskReadingMemory() {
  const memory = {
    reading: new Map<string, ReadingState>(),
    processDisclosure: new Map<string, RunProcessDisclosure>(),
    toolDisclosure: new Map<string, ReadonlySet<string>>(),
  };
  return {
    ...memory,
    prune(
      taskIds: ReadonlySet<string>,
      manifest?: { taskId: string; runIds: ReadonlySet<string> },
    ) {
      for (const taskId of memory.reading.keys())
        if (!taskIds.has(taskId)) memory.reading.delete(taskId);
      for (const entries of [memory.processDisclosure, memory.toolDisclosure]) {
        for (const key of entries.keys()) {
          const [taskId, runId] = key.split(":");
          if (
            !taskIds.has(taskId!) ||
            (manifest?.taskId === taskId && !manifest.runIds.has(runId!))
          )
            entries.delete(key);
        }
      }
    },
  };
}

export type TaskReadingMemory = ReturnType<typeof createTaskReadingMemory>;

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
  outputsEnabled,
  onOutputAction,
  onPrepareOutputEdit,
  onPreviewOutput,
  renderOutputPreview,
  webLink,
  onPrepareRetry,
  onPreviewFile,
  loadFilePreview,
  onReviewFileChanges,
  onRespond,
  renderPendingUi,
  localSubmissions,
  history,
  memory,
}: {
  task: TaskView | null;
  memory?: TaskReadingMemory;
  history?: { available: boolean; loading: boolean; onLoad: () => void };
  localSubmissions?: ReactNode;
  snapshotReceivedAt: number | null;
  synchronized: boolean;
  requestingStop: boolean;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  fileChangesEnabled: boolean;
  outputsEnabled: boolean;
  onOutputAction?: OutputActionHandler;
  onPrepareOutputEdit?: OutputEditHandler;
  onPreviewOutput?: OutputPreviewHandler;
  renderOutputPreview?: OutputPreviewRenderer;
  webLink: MarkdownWebLink;
  onPrepareRetry: (input: RunInputView) => void;
  loadFilePreview?: FilePreviewLoader;
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
}) {
  const { locale, t } = useI18n();
  const viewport = useRef<HTMLDivElement>(null);
  const [localMemory] = useState(createTaskReadingMemory);
  const { reading, processDisclosure, toolDisclosure } = memory ?? localMemory;
  const restoringTask = useRef<string | null>(null);
  const [, setDisclosureRevision] = useState(0);
  const previousTaskId = useRef<string | null>(null);
  const previousLayout = useRef<{
    taskId: string;
    firstRunId: string | null;
    height: number;
  } | null>(null);
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
  const submissions: WaitingInputView[] = [
    ...(task?.inputSubmissions ?? []),
    ...(task?.runs.flatMap((run) =>
      run.submission?.anchorRunId
        ? [
            {
              submission: run.submission,
              input: run.input,
              state: "interrupted" as const,
              reason: null,
              executed: true,
            },
          ]
        : [],
    ) ?? []),
  ];
  function renderSubmission(record: WaitingInputView) {
    const time = formatRunTimestamp(
      locale,
      record.submission.receivedAtUnixMs,
      nowUnixMs,
    );
    const executed = task?.runs.some(
      (run) => run.submission?.operationId === record.submission.operationId,
    );
    return (
      <div
        className="additional-input"
        key={record.submission.operationId}
        data-operation-id={record.submission.operationId}
      >
        <Message role="user" tabIndex={-1} className="focus-ring">
          <TaskInput input={record.input} />
        </Message>
        <MessageInfoBar
          role="user"
          time={time}
          onCopy={() => copyRunInput(record.input)}
        />
        {!executed && (
          <p className="projection-note">
            {t(
              record.state === "waiting"
                ? "input.waiting"
                : record.state === "cancelled"
                  ? "input.cancelled"
                  : "input.unexecuted",
            )}
          </p>
        )}
        {record.reason && record.state === "failed" && (
          <p className="projection-note">
            {t(`mutation.reason.${record.reason}` as MessageId)}
          </p>
        )}
      </div>
    );
  }
  const latestCopyableId = latestCopyableResponseId(task?.runs ?? []);
  const transferredRunIds = new Set(
    task?.runs.flatMap((run) =>
      run.additionalInputs.flatMap((input) =>
        input.state === "transferred" && input.transferredToRunId
          ? [input.transferredToRunId]
          : [],
      ),
    ),
  );
  const latestInputId =
    task?.runs
      .filter(
        (run) =>
          run.additionalInputs.length > 0 || !transferredRunIds.has(run.id),
      )
      .at(-1)?.id ?? null;
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
    const before = previousLayout.current;
    const firstRunId = task?.runs[0]?.id ?? null;
    previousLayout.current = taskId
      ? { taskId, firstRunId, height: node.scrollHeight }
      : null;
    if (!taskId) {
      node.scrollTop = 0;
      setShowJumpLatest(false);
      previousTaskId.current = null;
      return;
    }
    const intervalShrank =
      before?.taskId === taskId &&
      firstRunId &&
      before.firstRunId &&
      BigInt(firstRunId) > BigInt(before.firstRunId);
    if (
      history?.loading &&
      (previousTaskId.current !== taskId || intervalShrank)
    )
      restoringTask.current = taskId;
    if (restoringTask.current === taskId && history?.loading) return;
    if (previousTaskId.current !== taskId || restoringTask.current === taskId) {
      restoringTask.current = null;
      const saved = reading.get(taskId);
      if (!saved || saved.followingLatest) node.scrollTop = node.scrollHeight;
      else if (!restoreReadingAnchor(node, saved))
        node.scrollTop = saved.scrollTop;
      setShowJumpLatest(saved ? !saved.followingLatest : false);
      previousTaskId.current = taskId;
      return;
    }
    const saved = reading.get(taskId);
    if (saved && !saved.followingLatest && restoreReadingAnchor(node, saved)) {
      reading.set(taskId, { ...saved, scrollTop: node.scrollTop });
      setShowJumpLatest(true);
      return;
    }
    if (
      before?.taskId === taskId &&
      firstRunId &&
      before.firstRunId &&
      BigInt(firstRunId) < BigInt(before.firstRunId)
    ) {
      node.scrollTop =
        (saved?.scrollTop ?? node.scrollTop) +
        node.scrollHeight -
        before.height;
      reading.set(taskId, {
        scrollTop: node.scrollTop,
        followingLatest: false,
      });
      setShowJumpLatest(true);
      return;
    }
    if (!saved || saved.followingLatest) {
      node.scrollTop = node.scrollHeight;
      reading.set(taskId, {
        scrollTop: node.scrollTop,
        followingLatest: true,
      });
      setShowJumpLatest(false);
    }
  }, [task?.id, task?.runs, revision, history?.loading]);

  function updateReadingState() {
    const node = viewport.current;
    if (!node || !task || restoringTask.current !== null) return;
    const followingLatest =
      node.scrollHeight - node.scrollTop - node.clientHeight <= 48;
    reading.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest,
      anchor: followingLatest ? undefined : readingAnchor(node),
    });
    setShowJumpLatest(!followingLatest);
  }

  function jumpToLatest() {
    const node = viewport.current;
    if (!node || !task) return;
    reading.set(task.id, {
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
    const saved = reading.get(taskId);
    if (saved && !saved.followingLatest) return;
    node.scrollTop = node.scrollHeight;
    reading.set(taskId, {
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
      {history && (history.available || history.loading) && (
        <Button
          type="button"
          variant="secondary"
          size="md"
          disabled={history.loading || !synchronized}
          aria-busy={history.loading}
          onClick={history.onLoad}
        >
          {t(history.loading ? "common.loading" : "task.load_earlier")}
        </Button>
      )}
      {hasExcludedCompactHistory && (
        <p
          className="projection-notice conversation-coverage-notice"
          role="note"
        >
          {t("task.conversation_history_excluded")}
        </p>
      )}
      {submissions
        .filter((record) => record.submission.anchorRunId === null)
        .map(renderSubmission)}
      {task?.runs.map((run) => {
        const isCurrent = run.id === currentRun?.id;
        const terminal = run.terminal;
        const presentation = deriveRunPresentation(run);
        const readingFlow = deriveRunReadingFlow(
          run.id,
          run.output,
          run.additionalInputs,
          submissions.filter(
            (record) => record.submission.anchorRunId === run.id,
          ),
        );
        const responseCopyable = responseCopyEligible(run);
        const submittedTime = formatRunTimestamp(
          locale,
          run.submission?.receivedAtUnixMs ?? run.submittedAtUnixMs,
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
          processDisclosure.get(disclosureKey),
        );
        processDisclosure.set(disclosureKey, disclosure);
        const expandedToolIds =
          toolDisclosure.get(disclosureKey) ?? emptyToolDisclosure;

        function setProcessExpanded(expanded: boolean) {
          processDisclosure.set(
            disclosureKey,
            toggleRunProcessDisclosure(expanded),
          );
          setDisclosureRevision((value) => value + 1);
        }

        function setToolExpanded(toolId: string, expanded: boolean) {
          const next = new Set(toolDisclosure.get(disclosureKey) ?? []);
          if (expanded) next.add(toolId);
          else next.delete(toolId);
          toolDisclosure.set(disclosureKey, next);
          setDisclosureRevision((value) => value + 1);
        }

        return (
          <section
            className="ai-exchange"
            data-run-id={run.id}
            key={`${task.id}:${run.id}`}
          >
            {!transferredRunIds.has(run.id) && !run.submission?.anchorRunId && (
              <>
                <Message role="user" tabIndex={-1} className="focus-ring">
                  <TaskInput input={run.input} />
                </Message>
                <MessageInfoBar
                  role="user"
                  time={submittedTime}
                  latest={
                    run.id === latestInputId &&
                    run.additionalInputs.length === 0
                  }
                  onCopy={() => copyRunInput(run.input)}
                />
              </>
            )}
            <div className="run-reading-flow">
              {readingFlow.map((entry) =>
                entry.kind === "submission" ? (
                  renderSubmission(entry.input)
                ) : entry.kind === "input" ? (
                  <AdditionalInput
                    key={entry.identity}
                    input={entry.input}
                    submittedTime={formatRunTimestamp(
                      locale,
                      entry.input.submission?.receivedAtUnixMs ?? null,
                      nowUnixMs,
                    )}
                    latest={
                      run.id === latestInputId &&
                      entry.input.id === run.additionalInputs.at(-1)?.id
                    }
                  />
                ) : entry.parts.some((part) => part.content) ||
                  entry.redacted ? (
                  <Fragment key={entry.identity}>
                    <Message role="assistant" className="run-assistant-output">
                      {entry.parts
                        .filter((part) => part.content)
                        .map((part) => {
                          const streaming = part.disposition === "provisional";
                          const response =
                            part.disposition === "final" ||
                            part.disposition === "partial";
                          return (
                            <Markdown
                              className={`assistant-output-part ${
                                response
                                  ? "agent-response"
                                  : "run-commentary-item"
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
                      {entry.redacted && (
                        <p className="projection-note">
                          {t("privacy.sensitive_hidden")}
                        </p>
                      )}
                      {responseCopyable &&
                        entry.parts.some(
                          (part) =>
                            part.disposition === "final" ||
                            part.disposition === "partial",
                        ) && (
                          <MessageInfoBar
                            role="assistant"
                            time={finishedTime}
                            model={run.execution.model}
                            latest={run.id === latestCopyableId}
                            onCopy={() =>
                              copyResponseMarkdown(run.output.response)
                            }
                          />
                        )}
                    </Message>
                  </Fragment>
                ) : null,
              )}
            </div>
            {run.tools
              .flatMap((tool) => tool.fileRefs)
              .filter((reference) => reference.generatedImage)
              .map((reference) => (
                <GeneratedImagePreview
                  key={`${task.id}:${run.id}:${reference.id}`}
                  taskId={task.id}
                  runId={run.id}
                  reference={reference}
                  enabled={Boolean(synchronized && !responseDisabled)}
                  load={loadFilePreview}
                  onOpen={(opener) =>
                    onPreviewFile(task.id, run.id, reference, opener)
                  }
                />
              ))}
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
            {isCurrent &&
              task.pendingUi &&
              task.permissionReviewState !== "reviewing" && (
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
                    {t("approval.answered_by_reviewer")}
                    {record.permission?.toolName && (
                      <> · {record.permission.toolName}</>
                    )}{" "}
                    · {t(`ui.state.${record.state}`)}
                  </summary>
                  <p>{record.reviewReason}</p>
                </details>
              ))}
            {outputsEnabled && (
              <RunOutputs
                outputs={run.outputs}
                taskId={task.id}
                runId={run.id}
                disabled={responseDisabled || !synchronized}
                onAction={onOutputAction}
                onPrepareEdit={onPrepareOutputEdit}
                onPreview={onPreviewOutput}
                renderPreview={renderOutputPreview}
              />
            )}
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
          </section>
        );
      })}
      {task &&
        task.runs.length === 0 &&
        submissions.length === 0 &&
        !localSubmissions && (
          <div className="ai-conversation-empty">
            <h2>{t("task.empty_title")}</h2>
            <p>{t("task.created_empty_body")}</p>
          </div>
        )}
      {localSubmissions}
    </Conversation>
  );
}
