import {
  McpInstallationCard,
  type McpInstallationActions,
} from "../mcp/McpInstallationCard.tsx";
import {
  GeneratedImagePreview,
  type FilePreviewLoader,
} from "./GeneratedImagePreview.tsx";
import { RunDiagnostics } from "./RunDiagnostics.tsx";
import { UserInputMessage } from "./UserInputMessage.tsx";
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
  McpInstallationOperation,
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
  mcpInstallations = [],
  mcpInstallationNotice = null,
  onCancelInstallation,
  onCaptureInstallation,
  installationSecretMaxBytes = 2560,
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
  onOpenSettings,
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
  mcpInstallations?: McpInstallationOperation[];
  mcpInstallationNotice?: { taskId: string; runId: string } | null;
  onCancelInstallation?: McpInstallationActions["onCancelInstallation"];
  onCaptureInstallation?: McpInstallationActions["onCaptureInstallation"];
  installationSecretMaxBytes?: number;
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
  onPrepareRetry: (input: RunInputView) => void;
  onOpenSettings?: (target: "account" | "models") => void;
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
                  task: record.blockingTaskId ?? "",
                })}
              </p>
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
          const recovery = modelError?.recovery;
          const settingsRecovery =
            terminal?.cause === "provider_failure" &&
            (recovery === "account_settings" || recovery === "model_settings");
          const reason =
            terminal?.cause === "provider_failure"
              ? t(
                  modelError
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
          const terminalLabel = terminal?.recordingIncomplete
            ? terminal.outcome === "completed"
              ? t("run.recording_incomplete")
              : `${outcomeLabel} ${t("run.recording_incomplete")}`
            : outcomeLabel;
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
          const supplement = (
            <>
              {mcpInstallations
                .filter(
                  (operation) =>
                    operation.taskId === task.id && operation.runId === run.id,
                )
                .map((operation) => (
                  <McpInstallationCard
                    key={operation.serverId}
                    operation={operation}
                    disabled={!synchronized || requestingStop}
                    secretMaxBytes={installationSecretMaxBytes}
                    onCancelInstallation={onCancelInstallation}
                    onCaptureInstallation={onCaptureInstallation}
                  />
                ))}
              {mcpInstallationNotice?.taskId === task.id &&
                mcpInstallationNotice.runId === run.id && (
                  <p role="status">{t("mcp.install.rejected")}</p>
                )}
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
                  outputs={run.outputs}
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
                    label={terminalLabel}
                    announce={
                      isCurrent &&
                      observedRunTerminals.current.get(
                        `${task.id}:${run.id}`,
                      ) === false
                    }
                    action={
                      (isCurrent &&
                        retryAvailable &&
                        retryable(terminal.outcome)) ||
                      settingsRecovery ? (
                        <div className="run-terminal-actions">
                          {onOpenSettings &&
                            terminal.cause === "provider_failure" &&
                            (terminal.modelError?.recovery ===
                              "account_settings" ||
                              terminal.modelError?.recovery ===
                                "model_settings") && (
                              <button
                                className="ai-activity-retry focus-ring"
                                data-primary="true"
                                disabled={responseDisabled || !synchronized}
                                onClick={() =>
                                  onOpenSettings(
                                    terminal.modelError?.recovery ===
                                      "account_settings"
                                      ? "account"
                                      : "models",
                                  )
                                }
                              >
                                {t(
                                  terminal.modelError.recovery ===
                                    "account_settings"
                                    ? "run.model_error.open_account"
                                    : "run.model_error.open_models",
                                )}
                              </button>
                            )}
                          {isCurrent &&
                            retryAvailable &&
                            !settingsRecovery &&
                            retryable(terminal.outcome) && (
                              <button
                                className="ai-activity-retry focus-ring"
                                data-primary={
                                  terminal.cause !== "provider_failure" ||
                                  recovery === "prepare_retry"
                                }
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
                    settingsRecovery &&
                    isCurrent &&
                    retryAvailable &&
                    terminal &&
                    retryable(terminal.outcome)
                      ? () => onPrepareRetry(run.input)
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
                    </Message>
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
