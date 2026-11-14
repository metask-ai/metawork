import {
  GeneratedImagePreview,
  type FilePreviewLoader,
} from "./GeneratedImagePreview.tsx";
import { GeneratedVideoPreview } from "./GeneratedVideoPreview.tsx";
import { RunDiagnostics } from "./RunDiagnostics.tsx";
import { SkillMessageBody, UserInputMessage } from "./UserInputMessage.tsx";
import { AdditionalInput } from "./AdditionalInput.tsx";
import { MessageInfoBar } from "./MessageInfoBar.tsx";
import { runFileReferenceLinks } from "../../workbench/run-file-references.ts";
import { resolveWorkspaceFileLink } from "../../workbench/workspace-file-links.ts";
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
  UiRecord,
  WaitingInputView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import {
  Activity,
  Conversation,
  Markdown,
  type MarkdownLocalLinks,
  type MarkdownWebLink,
  Message,
} from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { RunProcess } from "./RunProcess.tsx";
import { RunFileChangesSummary } from "./RunFileChanges.tsx";
import { RunOutputs, type OutputEditHandler } from "./RunOutputs.tsx";
import {
  deriveTaskReadingPlan,
  type LocalReadingInput,
  type RunReadingEntry,
} from "./assistant-output.ts";
import {
  deriveRunPresentation,
  formatRunTimestamp,
  modelErrorMessageVisible,
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
  anchor?: {
    runId: string;
    offset: number;
    entryId?: string;
    neighbors?: { id: string; offset: number }[];
  };
};
function readingAnchor(viewport: HTMLDivElement): ReadingState["anchor"] {
  const bounds = viewport.getBoundingClientRect();
  const entries = [
    ...viewport.querySelectorAll<HTMLElement>("[data-reading-id]"),
  ];
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index]!;
    const rect = entry.getBoundingClientRect();
    if (rect.bottom <= bounds.top || rect.top >= bounds.bottom) continue;
    return {
      runId: entry.closest<HTMLElement>("[data-run-id]")?.dataset.runId ?? "",
      entryId: entry.dataset.readingId!,
      offset: rect.top - bounds.top,
      neighbors: entries
        .slice(Math.max(0, index - 1), index + 3)
        .filter((item) => item !== entry)
        .map((item) => ({
          id: item.dataset.readingId!,
          offset: item.getBoundingClientRect().top - bounds.top,
        })),
    };
  }
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
  const entries = [
    ...viewport.querySelectorAll<HTMLElement>("[data-reading-id]"),
  ];
  for (const candidate of [
    { id: anchor.entryId, offset: anchor.offset },
    ...(anchor.neighbors ?? []),
  ]) {
    if (!candidate.id) continue;
    const entry = entries.find(
      (item) => item.dataset.readingId === candidate.id,
    );
    if (entry) {
      viewport.scrollTop +=
        entry.getBoundingClientRect().top -
        viewport.getBoundingClientRect().top -
        candidate.offset;
      return true;
    }
  }
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
      manifest?: {
        taskId: string;
        runIds: ReadonlySet<string>;
      },
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
      <SkillMessageBody skill={input} />
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
function PermissionReviewRecord({ record }: { record: UiRecord }) {
  const { t } = useI18n();
  return (
    <details className="projection-note">
      <summary>
        {t(
          record.answeredBy === "reviewer"
            ? "approval.answered_by_reviewer"
            : "approval.review_history",
        )}
        {record.permission?.toolName && <> · {record.permission.toolName}</>} ·{" "}
        {t(`ui.state.${record.state}`)}
      </summary>
      <p>
        {record.review?.reason ??
          record.reviewReason ??
          (record.review?.cause
            ? t(`approval.handoff.${record.review.cause}`)
            : null)}
      </p>
    </details>
  );
}

export function TaskContent({
  task,
  renderRunSupplement,
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
  webLink,
  onPrepareRetry,
  onRetryInput,
  onDiscardInputRetry,
  onOpenSettings,
  recharge,
  onPreviewFile,
  workspaceRoot = null,
  onPreviewWorkspaceFile,
  loadFilePreview,
  onReviewFileChanges,
  onRespond,
  renderPendingUi,
  localSubmissions,
  history,
  memory,
}: {
  task: TaskView | null;
  renderRunSupplement?: (props: {
    taskId: string;
    runId: string;
    disabled: boolean;
  }) => ReactNode;
  memory?: TaskReadingMemory;
  history?: {
    available: boolean;
    loading: boolean;
    onLoad: () => void;
  };
  localSubmissions?: readonly (LocalReadingInput & { content: ReactNode })[];
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
  webLink: MarkdownWebLink;
  onPrepareRetry: (input: RunInputView, taskId: string, runId: string) => void;
  onRetryInput?: (taskId: string, operationId: string) => void;
  onDiscardInputRetry?: (taskId: string, operationId: string) => void;
  onOpenSettings?: (target: "account" | "models") => void;
  /** Current Account recharge eligibility; never inherited from Run history. */
  recharge?: { available: boolean; busy: boolean; onOpen: () => void };
  loadFilePreview?: FilePreviewLoader;
  onPreviewFile: (
    taskId: string,
    runId: string,
    reference: FileReferenceView,
    opener: HTMLButtonElement,
  ) => void;
  /** Publishable canonical root of the Task Workspace, for absolute links. */
  workspaceRoot?: string | null;
  /** Present only while the Task Workspace files can be browsed. */
  onPreviewWorkspaceFile?: (
    taskId: string,
    path: string,
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
  const observedRunTerminals = useRef(new Map<string, boolean>());
  useEffect(() => {
    observedRunTerminals.current = new Map(
      task?.runs.map((run) => [
        `${task.id}:${run.id}`,
        run.terminal !== null,
      ]) ?? [],
    );
  }, [task]);
  const viewport = useRef<HTMLDivElement>(null);
  const [localMemory] = useState(createTaskReadingMemory);
  const { reading, processDisclosure, toolDisclosure } = memory ?? localMemory;
  const restoringTask = useRef<string | null>(null);
  const [, setDisclosureRevision] = useState(0);
  const previousTaskId = useRef<string | null>(null);
  const historyRequestPending = useRef(false);
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
  const plan = task ? deriveTaskReadingPlan(task, localSubmissions) : null;
  const localNodes = new Map(
    localSubmissions?.map((item) => [item.operationId, item.content]),
  );
  function renderOutside(entry: RunReadingEntry) {
    return entry.kind === "submission" ? (
      renderSubmission(entry.input)
    ) : entry.kind === "local" ? (
      <Fragment key={entry.identity}>
        {localNodes.get(entry.operationId)}
      </Fragment>
    ) : null;
  }
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
      <UserInputMessage
        key={record.submission.operationId}
        operationId={record.submission.operationId}
        footer={
          <MessageInfoBar
            role="user"
            time={time}
            onCopy={() => copyRunInput(record.input)}
          />
        }
        notice={
          <>
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
                {t(`mutation.reason.${record.reason}` as MessageId, {
                  task:
                    record.blockingTaskId === task?.id
                      ? (task?.title ?? "")
                      : (record.blockingTaskId ?? ""),
                })}
              </p>
            )}
            {task &&
              record.retryAvailable &&
              onRetryInput &&
              onDiscardInputRetry && (
                <>
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    disabled={
                      !synchronized ||
                      task.sessionCloseRetryAvailable ||
                      task.lifecycle === "closing"
                    }
                    onClick={() =>
                      onRetryInput(task.id, record.submission.operationId)
                    }
                  >
                    {t("input.retry_original")}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    disabled={!synchronized}
                    onClick={() =>
                      onDiscardInputRetry(
                        task.id,
                        record.submission.operationId,
                      )
                    }
                  >
                    {t("input.discard_retry")}
                  </Button>
                </>
              )}
          </>
        }
      >
        <TaskInput input={record.input} />
      </UserInputMessage>
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
    const interval = window.setInterval(() => setNowUnixMs(Date.now()), 60000);
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
      if (saved) reading.set(taskId, { ...saved, scrollTop: node.scrollTop });
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
  useLayoutEffect(() => {
    historyRequestPending.current = history?.loading ?? false;
  }, [task?.id, task?.runs[0]?.id, history?.loading, synchronized]);
  function updateReadingState() {
    const node = viewport.current;
    if (!node || !task || restoringTask.current !== null) return;
    const scrollingUp =
      node.scrollTop < (reading.get(task.id)?.scrollTop ?? node.scrollTop);
    const followingLatest =
      node.scrollHeight - node.scrollTop - node.clientHeight <= 48;
    reading.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest,
      anchor: followingLatest ? undefined : readingAnchor(node),
    });
    setShowJumpLatest(!followingLatest);
    if (
      scrollingUp &&
      !followingLatest &&
      node.scrollTop < 100 &&
      history?.available &&
      !history.loading &&
      synchronized
    )
      loadEarlierHistory();
  }
  function loadEarlierHistory() {
    const node = viewport.current;
    if (
      !node ||
      node.scrollTop >= 100 ||
      !task ||
      !history?.available ||
      history.loading ||
      !synchronized ||
      historyRequestPending.current
    )
      return;
    historyRequestPending.current = true;
    reading.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest: false,
      anchor: readingAnchor(node),
    });
    history.onLoad();
  }
  function canScrollHistoryAtTop(target: EventTarget | null) {
    const node = viewport.current;
    if (!node || node.scrollTop > 0) return false;
    // Let nested code/tool viewports consume their own upward scrolling first.
    for (
      let element = target instanceof Element ? target : null;
      element && element !== node;
      element = element.parentElement
    ) {
      if (element.scrollTop > 0 && element.scrollHeight > element.clientHeight)
        return false;
    }
    return true;
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
  useEffect(() => {
    const node = viewport.current;
    const content = node?.firstElementChild;
    if (!node || !content || !task || typeof ResizeObserver === "undefined")
      return;
    const observer = new ResizeObserver(() => {
      const saved = reading.get(task.id);
      if (restoringTask.current !== null) return;
      if (!saved || saved.followingLatest) node.scrollTop = node.scrollHeight;
      else {
        restoreReadingAnchor(node, saved);
        reading.set(task.id, { ...saved, scrollTop: node.scrollTop });
      }
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, [task?.id, reading]);
  return (
    <Conversation
      aria-label={task?.title}
      viewportRef={viewport}
      onViewportScroll={updateReadingState}
      onViewportWheel={(event) => {
        if (
          !event.defaultPrevented &&
          event.deltaY < 0 &&
          canScrollHistoryAtTop(event.target)
        )
          loadEarlierHistory();
      }}
      onViewportKeyDown={(event) => {
        if (
          !event.defaultPrevented &&
          ["ArrowUp", "PageUp", "Home"].includes(event.key) &&
          !(
            event.target instanceof Element &&
            event.target.closest(
              "input, textarea, select, [contenteditable=true]",
            )
          ) &&
          canScrollHistoryAtTop(event.target)
        )
          loadEarlierHistory();
      }}
      jumpToLatest={
        showJumpLatest
          ? { label: t("task.jump_latest"), onClick: jumpToLatest }
          : undefined
      }
    >
      {history?.loading && synchronized && (
        <p className="conversation-history-loading" role="status">
          <span className="conversation-history-spinner">
            <Icon name="loading" />
          </span>
          <span className="sr-only">{t("common.loading")}</span>
        </p>
      )}
      {hasExcludedCompactHistory && (
        <p
          className="projection-notice conversation-coverage-notice"
          role="note"
        >
          {t("task.conversation_history_excluded")}
        </p>
      )}
      {plan?.before.map(renderOutside)}
      {plan?.runs.map(
        ({ run, presentation, entries: readingFlow, showRoot }) => {
          const task = plan.task;
          const isCurrent = run.id === currentRun?.id;
          const terminal = run.terminal;
          const modelError = terminal?.modelError;
          const guidance = terminal?.feedback.guidance;
          const providerReason = terminal?.feedback.reason ?? null;
          const rechargeAction =
            guidance === "recharge" && recharge?.available ? recharge : null;
          const settingsTarget =
            guidance === "account_settings" ||
            (guidance === "recharge" && !rechargeAction)
              ? "account"
              : guidance === "model_settings"
                ? "models"
                : null;
          const primarySettingsAction =
            rechargeAction !== null ||
            (settingsTarget !== null && onOpenSettings !== undefined);
          const canPrepareInput =
            isCurrent &&
            synchronized &&
            retryAvailable &&
            terminal?.feedback.offerInputPreparation &&
            !run.input.redacted;
          const prepareInput = () => onPrepareRetry(run.input, task.id, run.id);
          const guidanceText =
            guidance &&
            guidance !== "none" &&
            guidance !== "account_settings" &&
            guidance !== "model_settings" &&
            guidance !== "recharge"
              ? t(`run.guidance.${guidance}`)
              : undefined;
          const reason =
            terminal?.cause === "provider_failure"
              ? t(
                  providerReason
                    ? `run.model_error.reason.${providerReason}`
                    : modelError
                      ? `run.model_error.category.${modelError.category}`
                      : "run.provider_failure.title",
                )
              : terminal?.cause
                ? t(`cause.${terminal.cause}`)
                : null;
          const outcomeLabel = reason
            ? run.output.responseKind === "partial"
              ? t("run.terminal.partial_reason", { reason })
              : reason
            : terminal?.outcome === "completed" &&
                run.output.responseKind !== "partial"
              ? t("run.no_final_response")
              : terminal
                ? t(terminalMessage(run.output.responseKind, terminal.outcome))
                : "";
          // A recognized first-party reason replaces, not repeats, upstream text.
          const upstreamMessage =
            terminal?.cause === "provider_failure" &&
            modelError &&
            providerReason === null &&
            modelErrorMessageVisible(modelError)
              ? modelError.message
              : undefined;
          const terminalLabel = terminal?.recordingIncomplete
            ? terminal.outcome === "completed"
              ? t("run.recording_incomplete")
              : `${outcomeLabel} ${t("run.recording_incomplete")}`
            : outcomeLabel;
          const visibleTerminalLabel =
            terminal?.outcome === "stopped" && reason
              ? t("run.terminal.with_reason", {
                  outcome: t("run.terminal.stopped"),
                  reason: terminalLabel,
                })
              : terminalLabel;
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
          const videoPreviewLoader =
            synchronized && !responseDisabled ? loadFilePreview : undefined;
          const responseIndex = responseCopyable
            ? readingFlow.findIndex(
                (entry) =>
                  entry.kind === "assistant" &&
                  entry.parts.some(
                    (part) =>
                      part.disposition === "final" ||
                      part.disposition === "partial",
                  ),
              )
            : -1;
          let responseInfoAt = readingFlow[responseIndex]?.identity;
          if (responseInfoAt) {
            for (const entry of readingFlow.slice(responseIndex + 1)) {
              if (
                entry.kind === "image" ||
                (entry.kind === "video" && videoPreviewLoader)
              )
                responseInfoAt = entry.identity;
              else if (entry.kind !== "video") break;
            }
          }
          const responseInfo = responseInfoAt && (
            <MessageInfoBar
              role="assistant"
              time={finishedTime}
              model={run.execution.model}
              latest={run.id === latestCopyableId}
              onCopy={() => copyResponseMarkdown(run.output.response)}
            />
          );
          const runLinks = runFileReferenceLinks(run);
          const referenceLink = (reference: FileReferenceView) => ({
            label: t("file_preview.open", { path: reference.displayPath }),
            onOpen: (opener: HTMLButtonElement) =>
              onPreviewFile(task.id, run.id, reference, opener),
          });
          const references = new Map(
            [...runLinks].map(([text, reference]) => [
              text,
              referenceLink(reference),
            ]),
          );
          const localLinks: MarkdownLocalLinks = (destination) => {
            const link = resolveWorkspaceFileLink(destination, workspaceRoot);
            if (link.kind === "unavailable")
              return {
                unavailable: t(`file_preview.link_unavailable.${link.reason}`),
              };
            // The Run reference remains the identity for its exact path.
            const reference = runLinks.get(link.path);
            if (reference?.displayPath === link.path)
              return referenceLink(reference);
            if (!onPreviewWorkspaceFile)
              return {
                unavailable: t(
                  "file_preview.link_unavailable.workspace_unavailable",
                ),
              };
            return {
              label: t("file_preview.open", { path: link.path }),
              onOpen: (opener) =>
                onPreviewWorkspaceFile(task.id, link.path, opener),
            };
          };
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
          const reviewRecords = task.uiHistory.filter(
            (record) =>
              record.runId === run.id &&
              (record.answeredBy === "reviewer" || record.review != null),
          );
          const approvedReviews = reviewRecords.filter(
            (record) =>
              record.state === "allowed_once" &&
              record.answeredBy === "reviewer",
          );
          const approvalHistory =
            approvedReviews.length > 0 ? (
              <details className="projection-note">
                <summary>
                  {t("approval.review_approved_count", {
                    count: formatInteger(locale, approvedReviews.length),
                  })}
                </summary>
                {approvedReviews.map((record) => (
                  <PermissionReviewRecord
                    key={record.requestId}
                    record={record}
                  />
                ))}
              </details>
            ) : null;
          const deliveredVideos = [];
          const otherOutputs = [];
          for (const output of outputsEnabled ? run.outputs : []) {
            if (
              !output.redacted &&
              readingFlow.some(
                (entry) =>
                  entry.kind === "video" &&
                  entry.reference.displayPath === output.displayPath,
              )
            ) {
              deliveredVideos.push(output);
            } else {
              otherOutputs.push(output);
            }
          }
          const deliveryActions = outputsEnabled &&
            onOutputAction &&
            deliveredVideos.length > 0 && (
              <RunOutputs
                outputs={deliveredVideos}
                taskId={task.id}
                runId={run.id}
                disabled={responseDisabled || !synchronized}
                onAction={onOutputAction}
                layout="file-actions"
              />
            );
          const supplement = (
            <>
              {renderRunSupplement?.({
                taskId: task.id,
                runId: run.id,
                disabled: !synchronized || requestingStop,
              })}
              {presentation.active && (
                <RunProcess
                  presentation={presentation}
                  approvalHistory={approvalHistory}
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
              {reviewRecords
                .filter(
                  (record) =>
                    record.state !== "allowed_once" ||
                    record.answeredBy !== "reviewer",
                )
                .map((record) => (
                  <PermissionReviewRecord
                    key={record.requestId}
                    record={record}
                  />
                ))}
              {outputsEnabled && (
                <RunOutputs
                  outputs={otherOutputs}
                  taskId={task.id}
                  runId={run.id}
                  disabled={responseDisabled || !synchronized}
                  onAction={onOutputAction}
                  onPrepareEdit={onPrepareOutputEdit}
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
              {!presentation.active && (
                <RunProcess
                  presentation={presentation}
                  approvalHistory={approvalHistory}
                  deliveryActions={deliveryActions}
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
              <div className="run-terminal-feedback">
                {presentation.showTerminalNotice && terminal && (
                  <Activity
                    className={
                      terminal.cause === "provider_failure"
                        ? "run-terminal-activity"
                        : undefined
                    }
                    state={outcomeState(terminal.outcome)}
                    label={visibleTerminalLabel}
                    quote={upstreamMessage}
                    detail={guidanceText}
                    announce={
                      isCurrent &&
                      observedRunTerminals.current.get(
                        `${task.id}:${run.id}`,
                      ) === false
                    }
                    action={
                      primarySettingsAction || canPrepareInput ? (
                        <div className="run-terminal-actions">
                          {rechargeAction ? (
                            <button
                              className="ai-activity-retry ai-activity-external focus-ring"
                              data-primary="true"
                              disabled={
                                responseDisabled ||
                                !synchronized ||
                                rechargeAction.busy
                              }
                              title={t(
                                "settings.account_recharge_browser_hint",
                              )}
                              onClick={rechargeAction.onOpen}
                            >
                              <Icon name="external-link" />
                              {t("settings.account_recharge")}
                            </button>
                          ) : settingsTarget && onOpenSettings ? (
                            <button
                              className="ai-activity-retry focus-ring"
                              data-primary="true"
                              disabled={responseDisabled || !synchronized}
                              onClick={() => onOpenSettings(settingsTarget)}
                            >
                              {t(
                                settingsTarget === "account"
                                  ? "run.model_error.open_account"
                                  : "run.model_error.open_models",
                              )}
                            </button>
                          ) : (
                            <button
                              className="ai-activity-retry focus-ring"
                              data-primary={guidance === "prepare_retry"}
                              title={t(
                                composerHasDraft
                                  ? "run.review_draft_help"
                                  : "run.retry_help",
                              )}
                              onClick={prepareInput}
                            >
                              {t(
                                composerHasDraft
                                  ? "run.review_draft"
                                  : "run.prepare_retry",
                              )}
                            </button>
                          )}
                        </div>
                      ) : undefined
                    }
                  />
                )}
                <RunDiagnostics
                  key={`diagnostics:${task.id}:${run.id}`}
                  run={run}
                  composerHasDraft={composerHasDraft}
                  onPrepareRetry={
                    primarySettingsAction && canPrepareInput
                      ? prepareInput
                      : undefined
                  }
                />
              </div>
              {run.conversationCoverage === "excluded" && (
                <p
                  className="projection-notice run-conversation-coverage-notice"
                  role="note"
                >
                  {t("run.conversation_history_excluded")}
                </p>
              )}
            </>
          );
          return (
            <section
              className="ai-exchange"
              data-run-id={run.id}
              key={`${task.id}:${run.id}`}
            >
              {showRoot && (
                <>
                  <Message
                    role="user"
                    tabIndex={-1}
                    className="focus-ring"
                    data-reading-id={
                      run.submission
                        ? `submission:${run.submission.operationId}`
                        : `${run.id}:root`
                    }
                  >
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
                      resend={
                        entry.input.retryAvailable &&
                        onRetryInput &&
                        onDiscardInputRetry
                          ? {
                              retryDisabled:
                                !synchronized ||
                                task.sessionCloseRetryAvailable ||
                                task.lifecycle === "closing",
                              discardDisabled: !synchronized,
                              onRetry: () =>
                                onRetryInput(task.id, entry.input.operationId),
                              onDiscard: () =>
                                onDiscardInputRetry(
                                  task.id,
                                  entry.input.operationId,
                                ),
                            }
                          : undefined
                      }
                    />
                  ) : entry.kind === "local" ? (
                    <Fragment key={entry.identity}>
                      {localNodes.get(entry.operationId)}
                    </Fragment>
                  ) : entry.kind === "image" ? (
                    <Message
                      role="assistant"
                      key={entry.identity}
                      data-reading-id={entry.identity}
                    >
                      <GeneratedImagePreview
                        taskId={task.id}
                        runId={run.id}
                        reference={entry.reference}
                        enabled={Boolean(synchronized && !responseDisabled)}
                        load={loadFilePreview}
                        onOpen={(opener) =>
                          onPreviewFile(
                            task.id,
                            run.id,
                            entry.reference,
                            opener,
                          )
                        }
                      />
                      {entry.identity === responseInfoAt && responseInfo}
                    </Message>
                  ) : entry.kind === "video" ? (
                    videoPreviewLoader && (
                      <Message
                        role="assistant"
                        key={entry.identity}
                        data-reading-id={entry.identity}
                      >
                        <GeneratedVideoPreview
                          taskId={task.id}
                          runId={run.id}
                          referenceId={entry.reference.id}
                          load={videoPreviewLoader}
                        />
                        {entry.identity === responseInfoAt && responseInfo}
                      </Message>
                    )
                  ) : entry.kind === "supplement" ? (
                    <Fragment key={entry.identity}>{supplement}</Fragment>
                  ) : entry.parts.some((part) => part.content) ||
                    entry.redacted ? (
                    <Fragment key={entry.identity}>
                      <Message
                        role="assistant"
                        className="run-assistant-output"
                      >
                        {entry.parts
                          .filter((part) => part.content)
                          .map((part) => {
                            const streaming =
                              part.disposition === "provisional";
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
                                data-reading-id={part.identity}
                                data-output-identity={part.identity}
                                data-output-disposition={part.disposition}
                                key={part.identity}
                                references={streaming ? undefined : references}
                                localLinks={streaming ? undefined : localLinks}
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
                        {entry.identity === responseInfoAt && responseInfo}
                      </Message>
                    </Fragment>
                  ) : null,
                )}
              </div>
            </section>
          );
        },
      )}
      {task &&
        task.runs.length === 0 &&
        (plan?.before.length ?? 0) === 0 &&
        (plan?.after.length ?? 0) === 0 &&
        !localSubmissions?.length && (
          <div className="ai-conversation-empty">
            <h2>{t("task.empty_title")}</h2>
            <p>{t("task.created_empty_body")}</p>
          </div>
        )}
      {plan?.after.map(renderOutside)}
      {!task &&
        localSubmissions?.map((entry) => (
          <Fragment key={`submission:${entry.operationId}`}>
            {entry.content}
          </Fragment>
        ))}
    </Conversation>
  );
}
