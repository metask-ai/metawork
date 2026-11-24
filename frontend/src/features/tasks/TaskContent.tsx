import {
  GeneratedImagePreview,
  type FilePreviewLoader,
} from "./GeneratedImagePreview.tsx";
import { GeneratedVideoPreview } from "./GeneratedVideoPreview.tsx";
import { RunDiagnostics } from "./RunDiagnostics.tsx";
import { SkillMessageBody, UserInputMessage } from "./UserInputMessage.tsx";
import { AdditionalInput } from "./AdditionalInput.tsx";
import { MessageInfoBar } from "./MessageInfoBar.tsx";
import {
  AttachmentThumbnail,
  type AttachmentThumbnailLoader,
} from "../../components/AttachmentThumbnail.tsx";
import { runFileReferenceLinks } from "../../workbench/run-file-references.ts";
import { resolveWorkspaceFileLink } from "../../workbench/workspace-file-links.ts";
import {
  Fragment,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { maxPreviewImageBytes } from "../../bridge/contracts.ts";
import { ConversationRail } from "./ConversationRail.tsx";
import {
  createRailPosition,
  pendingRailJumpValid,
  railCurrentRun,
  railEntries,
  railScrollBehavior,
  railVisible,
  runMessageReadingId,
} from "./conversation-rail.ts";
import type {
  FileReferenceView,
  MediaTarget,
  FileActionHandler,
  PendingUi,
  RunInputView,
  RunManifest,
  RunOutcome,
  RunView,
  TaskView,
  UiRecord,
  WaitingInputView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import {
  Activity,
  Composer,
  Conversation,
  Markdown,
  type MarkdownLocalLinks,
  type MarkdownWebLink,
  Message,
} from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useAutosizeTextarea } from "../../components/ui/textarea.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { RunProcess } from "./RunProcess.tsx";
import { RunToolsCache, type RunToolsLoader } from "./run-tools.ts";
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
const emptyManifest: readonly RunManifest[] = [];
/** Space left above a message a rail jump lands on. */
const railJumpOffset = 16;
/** A rail jump that waits for its Run to join the loaded interval. */
type PendingJump = {
  taskId: string;
  runId: string;
  /** Oldest loaded Run when the jump started; cancelling keeps history here. */
  keepFrom: string;
};
const viewportScrollKeys = new Set([
  "ArrowUp",
  "ArrowDown",
  "PageUp",
  "PageDown",
  "Home",
  "End",
  " ",
]);
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
/// Addresses the attachments of one sent message. A message that has already
/// become a Run is addressed by that Run; one still waiting for its turn is
/// addressed by its submission, because it does not have a Run yet.
type SentInputMedia =
  { taskId: string; runId: string } | { taskId: string; operationId: string };

function sentAttachmentTarget(
  media: SentInputMedia,
  index: number,
): MediaTarget {
  return "runId" in media
    ? { kind: "runAttachment", taskId: media.taskId, runId: media.runId, index }
    : {
        kind: "submissionAttachment",
        taskId: media.taskId,
        operationId: media.operationId,
        index,
      };
}

/**
 * The text of a run's own input, when there is text of ours to edit. A Skill
 * invocation is not free text, a message with attachments cannot have them
 * reattached from history, and redacted text is not the message the user
 * wrote, so none of those offers an edit entry. What this returns is always
 * Product's own record: Core stores a user message wrapped in its Host
 * context block, so the message at a conversation position is not what
 * MetaWork sent, and nothing reads it back from there.
 */
function editableRunText(input: RunInputView): string | null {
  return input.kind === "text" && !input.redacted ? input.text : null;
}

function RunInputEditor({
  readingId,
  text,
  disabled,
  onChange,
  onCancel,
  onSend,
}: {
  readingId: string;
  text: string;
  disabled: boolean;
  onChange: (text: string) => void;
  onCancel: () => void;
  onSend: (text: string) => Promise<void>;
}) {
  const { t } = useI18n();
  const [sending, setSending] = useState(false);
  const editInput = useRef<HTMLTextAreaElement>(null);
  const focusEditInput = useCallback((input: HTMLTextAreaElement | null) => {
    editInput.current = input;
    if (!input) return;
    const end = input.value.length;
    input.focus({ preventScroll: true });
    input.setSelectionRange(end, end);
    input.scrollTop = input.scrollHeight;
  }, []);
  const noticeId = useId();
  useAutosizeTextarea(editInput, text);
  const trimmed = text.trim();
  const locked = disabled || sending;
  return (
    <form
      className="run-input-edit"
      data-reading-id={readingId}
      onSubmit={async (event) => {
        event.preventDefault();
        if (locked || !trimmed) return;
        setSending(true);
        try {
          await onSend(trimmed);
        } finally {
          setSending(false);
        }
      }}
    >
      <Composer>
        <textarea
          ref={focusEditInput}
          value={text}
          readOnly={locked}
          rows={1}
          aria-label={t("input.edit")}
          aria-describedby={noticeId}
          onChange={(event) => onChange(event.target.value)}
        />
        <div className="run-input-edit-actions">
          <Button type="button" size="sm" variant="ghost" onClick={onCancel}>
            {t("input.edit_cancel")}
          </Button>
          <Button
            type="submit"
            size="sm"
            variant="primary"
            className="run-input-edit-send"
            disabled={locked || !trimmed}
          >
            {t("run.submit")}
          </Button>
        </div>
      </Composer>
      <p id={noticeId} className="run-input-edit-notice">
        {t("input.edit_notice")}
      </p>
    </form>
  );
}

function TaskInput({
  input,
  media,
  loadThumbnail,
  onOpenAttachment,
}: {
  input: RunInputView;
  /// Absent for a message Product cannot address media for, which keeps every
  /// chip in it at the metadata form it has always had.
  media?: SentInputMedia;
  loadThumbnail?: AttachmentThumbnailLoader<MediaTarget>;
  onOpenAttachment?: (
    target: MediaTarget,
    name: string,
    opener: HTMLButtonElement,
  ) => void;
}) {
  const { t } = useI18n();
  const content =
    input.kind === "text" ? (
      <p className="task-input-copy">{input.text}</p>
    ) : input.kind === "skill" ? (
      <SkillMessageBody skill={input} />
    ) : (
      <div className="task-multimodal-input">
        {input.skill ? (
          <SkillMessageBody
            skill={{
              ...input.skill,
              argumentValues: input.text ? [input.text] : [],
            }}
          />
        ) : (
          input.text && <p className="task-input-copy">{input.text}</p>
        )}
        <div className="task-input-attachments" role="list">
          {input.attachments.map((attachment, index) => {
            // A chip becomes interactive only where the Host still has media
            // for it: a file attachment, a redacted record and an image sent
            // before its identity was recorded all keep the static chip rather
            // than offering an entry that cannot answer.
            const target =
              attachment.kind === "image" &&
              attachment.media &&
              !attachment.redacted &&
              media
                ? sentAttachmentTarget(media, index)
                : null;
            return (
              <span
                className="task-input-attachment"
                role="listitem"
                key={`${attachment.displayName}:${index}`}
              >
                {target && attachment.kind === "image" ? (
                  <AttachmentThumbnail
                    target={target}
                    label={attachment.displayName}
                    formatLabel={attachment.format.toUpperCase()}
                    load={loadThumbnail}
                    onOpen={
                      onOpenAttachment &&
                      BigInt(attachment.sizeBytes) <=
                        BigInt(maxPreviewImageBytes)
                        ? (opener) =>
                            onOpenAttachment(
                              target,
                              attachment.displayName,
                              opener,
                            )
                        : undefined
                    }
                  />
                ) : (
                  <span aria-hidden="true">
                    {attachment.kind === "image" ? (
                      attachment.format.toUpperCase()
                    ) : (
                      <Icon name="skill-file" />
                    )}
                  </span>
                )}
                <strong dir="auto">{attachment.displayName}</strong>
                <small>
                  {attachment.kind === "image"
                    ? `${t("attachment.type.image")} · ${attachment.format.toUpperCase()}`
                    : t("attachment.type.file")}
                  {` · ${formatAttachmentSize(attachment.sizeBytes)}`}
                </small>
              </span>
            );
          })}
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
  onFileAction,
  onShowOutputs,
  onPrepareOutputEdit,
  webLink,
  onPrepareRetry,
  onRetryInput,
  onDiscardInputRetry,
  onEditInput,
  onOpenSettings,
  recharge,
  onPreviewFile,
  loadRunTools,
  securityEpoch,
  runToolsCache,
  workspaceRoot = null,
  onPreviewWorkspaceFile,
  loadFilePreview,
  loadAttachmentThumbnail,
  onOpenSentAttachment,
  onReviewFileChanges,
  onRespond,
  renderPendingUi,
  localSubmissions,
  history,
  runManifest = emptyManifest,
  memory,
}: {
  task: TaskView | null;
  /** Every projected Run of `task`, loaded or not, in Run order. */
  runManifest?: readonly RunManifest[];
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
    /** Keeps loading contiguous history until this Run is included. */
    onRequest?: (runId: string) => void;
    /** Stops a request: history is kept down to `runId` and no further. */
    onRelease?: (taskId: string, runId: string) => void;
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
  onFileAction?: FileActionHandler;
  onShowOutputs?: (opener: HTMLButtonElement) => void;
  onPrepareOutputEdit?: OutputEditHandler;
  webLink: MarkdownWebLink;
  onPrepareRetry: (input: RunInputView, taskId: string, runId: string) => void;
  onRetryInput?: (taskId: string, operationId: string) => void;
  onDiscardInputRetry?: (taskId: string, operationId: string) => void;
  /**
   * Replaces one earlier message and reruns the conversation from it. The
   * text is this run's own recorded input as the user edited it; nothing here
   * reads the conversation back from Core.
   */
  onEditInput?: (
    taskId: string,
    runId: string,
    text: string,
  ) => Promise<boolean>;
  onOpenSettings?: (target: "account" | "models") => void;
  /** Current Account recharge eligibility; never inherited from Run history. */
  recharge?: { available: boolean; busy: boolean; onOpen: () => void };
  loadFilePreview?: FilePreviewLoader;
  loadAttachmentThumbnail?: AttachmentThumbnailLoader<MediaTarget>;
  /** Opens the image a message was sent with in the media viewer. */
  onOpenSentAttachment?: (
    target: MediaTarget,
    name: string,
    opener: HTMLButtonElement,
  ) => void;
  onPreviewFile: (
    taskId: string,
    runId: string,
    reference: FileReferenceView,
    opener: HTMLButtonElement,
  ) => void;
  /** Reads a Run's Tool records page by page for its execution details. */
  loadRunTools?: RunToolsLoader;
  /** The snapshot's security epoch; Tool pages from another one are dropped. */
  securityEpoch?: string;
  /** Pages already read; this view owns a fresh one when none is given. */
  runToolsCache?: RunToolsCache;
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
  const [toolsCache] = useState(() => runToolsCache ?? new RunToolsCache());
  // Run ids restart in every Task: pages of another Task or security epoch
  // are dropped as soon as this view shows a different one.
  useEffect(() => {
    toolsCache.retain(task?.id, securityEpoch);
  }, [toolsCache, task?.id, securityEpoch]);
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
  const [railPosition] = useState(createRailPosition);
  const [pendingJump, setPendingJump] = useState<PendingJump | null>(null);
  const [scrollable, setScrollable] = useState(false);
  const rail = useMemo(() => railEntries(runManifest), [runManifest]);
  const [editing, setEditing] = useState<{
    taskId: string;
    runId: string;
    text: string;
  } | null>(null);
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
    // The reading plan places later Run inputs at their submission anchors.
    const executed = task?.runs.find(
      (run) => run.submission?.operationId === record.submission.operationId,
    );
    if (task && executed)
      return renderRunInput(task, executed, record.submission.operationId);

    const time = formatRunTimestamp(
      locale,
      record.submission.receivedAtUnixMs,
      nowUnixMs,
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
            <p className="projection-note">
              {t(
                record.state === "waiting"
                  ? "input.waiting"
                  : record.state === "cancelled"
                    ? "input.cancelled"
                    : "input.unexecuted",
              )}
            </p>
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
        <TaskInput
          input={record.input}
          media={
            task
              ? {
                  taskId: task.id,
                  operationId: record.submission.operationId,
                }
              : undefined
          }
          loadThumbnail={loadAttachmentThumbnail}
          onOpenAttachment={onOpenSentAttachment}
        />
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
  function renderRunInput(
    task: TaskView,
    run: RunView,
    anchoredOperationId?: string,
  ) {
    const readingId = run.submission
      ? `submission:${run.submission.operationId}`
      : `${run.id}:root`;
    const editText =
      onEditInput &&
      run.editAdmitted &&
      synchronized &&
      task.activeOperation === null &&
      task.approvalChange === null &&
      task.lifecycle !== "closing" &&
      !task.sessionCloseRetryAvailable
        ? editableRunText(run.input)
        : null;

    if (editing?.taskId === task.id && editing.runId === run.id) {
      return (
        <RunInputEditor
          key={anchoredOperationId}
          readingId={readingId}
          text={editing.text}
          disabled={editText === null}
          onChange={(text) => setEditing({ ...editing, text })}
          onCancel={() => setEditing(null)}
          onSend={async (text) => {
            if (await onEditInput?.(task.id, run.id, text)) {
              setEditing((current) => (current === editing ? null : current));
            }
          }}
        />
      );
    }

    const footer = (
      <MessageInfoBar
        role="user"
        time={formatRunTimestamp(
          locale,
          run.submission?.receivedAtUnixMs ?? run.submittedAtUnixMs,
          nowUnixMs,
        )}
        latest={run.id === latestInputId && run.additionalInputs.length === 0}
        onCopy={() => copyRunInput(run.input)}
        onEdit={
          editText === null
            ? undefined
            : () =>
                setEditing({ taskId: task.id, runId: run.id, text: editText })
        }
      />
    );
    const input = (
      <TaskInput
        input={run.input}
        media={
          anchoredOperationId
            ? { taskId: task.id, operationId: anchoredOperationId }
            : { taskId: task.id, runId: run.id }
        }
        loadThumbnail={loadAttachmentThumbnail}
        onOpenAttachment={onOpenSentAttachment}
      />
    );
    return anchoredOperationId ? (
      <UserInputMessage
        key={anchoredOperationId}
        operationId={anchoredOperationId}
        footer={footer}
      >
        {input}
      </UserInputMessage>
    ) : (
      <>
        <Message
          role="user"
          tabIndex={-1}
          className="focus-ring"
          data-reading-id={readingId}
        >
          {input}
        </Message>
        {footer}
      </>
    );
  }

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
  // Runs after the reading position above is restored for this commit: a
  // waiting jump lands once its Run is in the loaded interval, and ends when
  // its Task or its Run is gone.
  useLayoutEffect(() => {
    if (!pendingJump) return;
    if (!pendingRailJumpValid(pendingJump, task?.id ?? null, runManifest)) {
      setPendingJump(null);
      history?.onRelease?.(pendingJump.taskId, pendingJump.keepFrom);
      return;
    }
    if (restoringTask.current !== null) return;
    if (scrollToRun(pendingJump.runId)) setPendingJump(null);
  });
  // The rail follows the reading position without re-rendering the
  // conversation; only a change of overflow re-renders this component.
  useLayoutEffect(() => {
    const node = viewport.current;
    if (!task || !node) {
      railPosition.set(null);
      return;
    }
    const saved = reading.get(task.id);
    const following = saved?.followingLatest ?? true;
    // The saved anchor is the reading position this commit restored; only a
    // position saved without one is measured again.
    railPosition.set(
      railCurrentRun(
        rail,
        following
          ? null
          : (saved?.anchor?.runId ?? readingAnchor(node)?.runId ?? null),
        following,
      ),
    );
    const overflow = node.scrollHeight > node.clientHeight + 1;
    if (overflow !== scrollable) setScrollable(overflow);
  });
  function updateReadingState() {
    const node = viewport.current;
    if (!node || !task || restoringTask.current !== null) return;
    const scrollingUp =
      node.scrollTop < (reading.get(task.id)?.scrollTop ?? node.scrollTop);
    const followingLatest =
      node.scrollHeight - node.scrollTop - node.clientHeight <= 48;
    const anchor = followingLatest ? undefined : readingAnchor(node);
    reading.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest,
      anchor,
    });
    railPosition.set(
      railCurrentRun(rail, anchor?.runId ?? null, followingLatest),
    );
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
    cancelPendingJump();
    reading.set(task.id, {
      scrollTop: node.scrollHeight,
      followingLatest: true,
    });
    railPosition.set(railCurrentRun(rail, null, true));
    node.scrollTo({ top: node.scrollHeight, behavior: "smooth" });
    setShowJumpLatest(false);
  }
  /** Ends a waiting rail jump and stops the history it asked for. */
  function cancelPendingJump() {
    if (!pendingJump) return;
    setPendingJump(null);
    history?.onRelease?.(pendingJump.taskId, pendingJump.keepFrom);
  }
  /**
   * Scrolls a loaded Run's own message to the top of the viewport and saves
   * that as the reading position, so a re-render or resize during a smooth
   * scroll restores the destination instead of the place it started from.
   */
  function scrollToRun(runId: string) {
    const node = viewport.current;
    const run = task?.runs.find((candidate) => candidate.id === runId);
    if (!node || !task || !run) return false;
    const readingId = runMessageReadingId(run);
    const target =
      node.querySelector<HTMLElement>(
        `[data-reading-id="${CSS.escape(readingId)}"]`,
      ) ??
      node.querySelector<HTMLElement>(`[data-run-id="${CSS.escape(runId)}"]`);
    if (!target) return false;
    const distance =
      target.getBoundingClientRect().top -
      node.getBoundingClientRect().top -
      railJumpOffset;
    const top = Math.max(
      0,
      Math.min(
        node.scrollTop + distance,
        node.scrollHeight - node.clientHeight,
      ),
    );
    const followingLatest = node.scrollHeight - top - node.clientHeight <= 48;
    reading.set(task.id, {
      scrollTop: top,
      followingLatest,
      anchor: followingLatest
        ? undefined
        : {
            runId,
            entryId: target.dataset.readingId,
            offset: railJumpOffset,
          },
    });
    railPosition.set(railCurrentRun(rail, runId, followingLatest));
    setShowJumpLatest(!followingLatest);
    node.scrollTo({
      top,
      behavior: railScrollBehavior(
        distance,
        node.clientHeight,
        window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ??
          false,
      ),
    });
    // The landing message takes focus so assistive technology reads where
    // the jump went; it is already a programmatic focus target.
    const message = target.matches("[tabindex]")
      ? target
      : target.querySelector<HTMLElement>("[tabindex='-1']");
    message?.focus({ preventScroll: true });
    return true;
  }
  function jumpToRun(runId: string) {
    const node = viewport.current;
    if (!task || !node) return;
    if (scrollToRun(runId)) {
      // A loaded choice replaces any jump still waiting for history.
      cancelPendingJump();
      return;
    }
    const keepFrom = task.runs[0]?.id;
    if (!synchronized || !history?.onRequest || !keepFrom) return;
    const earlier = pendingJump?.taskId === task.id ? pendingJump : null;
    // A new target replaces the waiting one: release its request first so a
    // later target does not keep loading toward the earlier one.
    if (earlier) history.onRelease?.(task.id, earlier.keepFrom);
    // Loading prepends pages above the reader; hold the current place until
    // the target arrives instead of following the latest output.
    reading.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest: false,
      anchor: readingAnchor(node),
    });
    setShowJumpLatest(true);
    setPendingJump({
      taskId: task.id,
      runId,
      keepFrom: earlier ? earlier.keepFrom : keepFrom,
    });
    history.onRequest(runId);
  }
  const jumpRef = useRef(jumpToRun);
  jumpRef.current = jumpToRun;
  const onRailJump = useCallback((runId: string) => jumpRef.current(runId), []);
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
        // Scrolling by hand ends a rail jump that is still waiting.
        if (event.deltaY !== 0) cancelPendingJump();
        if (
          !event.defaultPrevented &&
          event.deltaY < 0 &&
          canScrollHistoryAtTop(event.target)
        )
          loadEarlierHistory();
      }}
      onViewportPointerDown={(event) => {
        // A press on the viewport itself is its scrollbar.
        if (event.target === event.currentTarget) cancelPendingJump();
      }}
      onViewportKeyDown={(event) => {
        const editable =
          event.target instanceof Element &&
          event.target.closest(
            "input, textarea, select, [contenteditable=true]",
          );
        if (!editable && viewportScrollKeys.has(event.key)) cancelPendingJump();
        if (
          !event.defaultPrevented &&
          ["ArrowUp", "PageUp", "Home"].includes(event.key) &&
          !editable &&
          canScrollHistoryAtTop(event.target)
        )
          loadEarlierHistory();
      }}
      rail={
        task &&
        railVisible({
          runCount: rail.length,
          olderHistory: Boolean(history?.available),
          scrollable,
        }) ? (
          <ConversationRail
            entries={rail}
            position={railPosition}
            loadedFrom={Math.max(
              0,
              rail.findIndex((entry) => entry.runId === task.runs[0]?.id),
            )}
            canLoad={synchronized && Boolean(history?.onRequest)}
            pendingRunId={
              pendingJump?.taskId === task.id ? pendingJump.runId : null
            }
            onJump={onRailJump}
          />
        ) : undefined
      }
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
            onFileAction &&
            deliveredVideos.length > 0 && (
              <RunOutputs
                outputs={deliveredVideos}
                taskId={task.id}
                runId={run.id}
                disabled={responseDisabled || !synchronized}
                onAction={onFileAction}
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
                  toolSource={{
                    loader: loadRunTools,
                    taskId: task.id,
                    runId: run.id,
                    securityEpoch,
                    toolLog: run.toolLog,
                    cache: toolsCache,
                  }}
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
                  onAction={onFileAction}
                  onPrepareEdit={onPrepareOutputEdit}
                  onPreview={onPreviewWorkspaceFile}
                  officeOpen={task.officeOutputsOpen}
                  browserOpen={task.browserOutputsOpen}
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
              {outputsEnabled &&
                !presentation.active &&
                onShowOutputs &&
                task.conversationOutputs?.some(
                  (output) => BigInt(output.runId) <= BigInt(run.id),
                ) && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    className="self-start"
                    onClick={(event) => onShowOutputs(event.currentTarget)}
                  >
                    {t("outputs.view")}
                  </Button>
                )}
              {!presentation.active && (
                <RunProcess
                  presentation={presentation}
                  toolSource={{
                    loader: loadRunTools,
                    taskId: task.id,
                    runId: run.id,
                    securityEpoch,
                    toolLog: run.toolLog,
                    cache: toolsCache,
                  }}
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
              {showRoot && renderRunInput(task, run)}
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
