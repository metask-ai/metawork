import {
  localReadingAnchor,
  type LocalReadingInput,
} from "../features/tasks/assistant-output.ts";
import { UserInputMessage } from "../features/tasks/UserInputMessage.tsx";
import type { OutputEditResult } from "../features/tasks/RunOutputs.tsx";
import { BrandLogo } from "../components/ui/BrandLogo.tsx";
import {
  historyProgress,
  earlierHistoryGoal,
  type HistoryGoal,
} from "../workbench/history.ts";
import { Message } from "../components/ai/Message.tsx";
import { newComposerOperationId } from "../features/composer/drafts.ts";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import { AppShell } from "./AppShell.tsx";
import {
  documentHasAttention,
  subscribeDocumentAttention,
} from "./document-attention.ts";
import {
  completionAcknowledgementCandidate,
  completionReminderSuppressionTaskId,
} from "./completion-receipt.ts";
import {
  attentionStatus,
  publishStatus,
  quietStatus,
  selectCommandBarStatus,
  type ShellStatus,
  type ShellRoute,
  type ShellStatusState,
  type StatusAudience,
} from "./command-bar-status.ts";
import {
  connectionFailurePresentation,
  connectionStatus,
} from "./connection-status.ts";
import { Icon } from "../components/ui/Icon.tsx";
import { ConfirmationNotice } from "../components/ConfirmationNotice.tsx";
import { AlertDialog } from "../components/ui/alert-dialog.tsx";
import { Button } from "../components/ui/button.tsx";
import { Dialog } from "../components/ui/dialog.tsx";
import { Input } from "../components/ui/input.tsx";
import { AccountIdentity } from "../features/account/AccountIdentity.tsx";
import { ConnectionFailureScreen } from "../features/connection/ConnectionFailureScreen.tsx";
import { accountErrorMessageId } from "../i18n/account-error.ts";
import { persistenceRecoveryErrorMessageId } from "../i18n/persistence-recovery.ts";
import {
  SettingsPage,
  type SettingsFocusTarget,
} from "../features/settings/SettingsPage.tsx";
import {
  TaskApprovalRequests,
  type ApprovalObservation,
} from "../features/approvals/mode-state.ts";
import { ApprovalModeMenu } from "../features/approvals/ApprovalModeMenu.tsx";
import { ComposerFooter } from "../features/composer/ComposerFooter.tsx";
import { ApprovalPanel } from "../features/approvals/ApprovalPanel.tsx";
import {
  uiRequestIdentity,
  uiResponsePhase,
} from "../features/approvals/response-state.ts";
import { useUiResponseStates } from "../features/approvals/useUiResponseStates.ts";
import { GlobalSearch } from "../features/search/GlobalSearch.tsx";
import {
  SkillsPage,
  skillRefreshKey,
  type SkillRefreshTarget,
  type SkillRefreshRequests,
} from "../features/skills/SkillsPage.tsx";
import { McpPage } from "../features/mcp/McpPage.tsx";
import { ScheduledTasksPage } from "../features/scheduled-tasks/ScheduledTasksPage.tsx";
import { TaskInformation } from "../features/tasks/TaskInformation.tsx";
import { ConversationContext } from "../features/composer/ConversationContext.tsx";
import { findRunFileReference } from "../workbench/run-file-references.ts";
import { TaskPanel } from "../features/task-panel/TaskPanel.tsx";
import {
  FilePreviewRefreshAction,
  FilePreviewView,
  type FilePreviewViewState,
} from "../features/task-panel/FilePreviewView.tsx";
import {
  FileChangesView,
  type FileChangeFocus,
} from "../features/task-panel/FileChangesView.tsx";
import { sidePanelFocusReturnTarget } from "./side-panel-interaction.ts";
import { useTaskPanelTarget } from "../features/task-panel/useTaskPanelTarget.ts";
import { useFilePreviewTabs } from "../features/task-panel/useFilePreviewTabs.ts";
import { useTaskPanelViewStates } from "../features/task-panel/useTaskPanelViewStates.ts";
import {
  createTaskPanelPreviewTab,
  createTaskPanelReviewTab,
} from "../features/task-panel/task-panel-state.ts";
import { TaskList, type TaskMenuAction } from "../features/tasks/TaskList.tsx";
import {
  NewTaskApprovalModeMenu,
  TaskWorkspace,
} from "../features/tasks/NewTaskView.tsx";
import {
  TaskContent,
  createTaskReadingMemory,
} from "../features/tasks/TaskContent.tsx";
import {
  useNewTaskDrafts,
  useTaskDrafts,
} from "../features/composer/useTaskDrafts.ts";
import {
  newTaskDraftStorageId,
  prepareRetryDraft,
  prepareOutputEditDraft,
  unscopedNewTaskDraftId,
} from "../features/composer/drafts.ts";
import {
  maxLocalTaskSubmissions,
  TaskSubmissionSession,
  taskHasSubmission,
} from "../features/composer/submitTaskInstruction.ts";
import {
  modelDisplayLabel,
  newTaskModelSelectionState,
} from "./new-task-model-selection.ts";
import {
  composerDraftHasContent,
  composerDraftToRunInput,
  composerDraftWithinLimits,
  emptyComposerDraft,
  isSkillDraftCurrent,
  maxSkillArguments,
  resolveSlashCommandStates,
  skillCatalogRefreshTarget,
  type ComposerDraft,
  type SlashCommandName,
  type SlashCommandState,
} from "../features/composer/slash.ts";
import {
  BridgeClient,
  BridgeCommandTimeoutError,
  RendererBridgeContractError,
} from "../bridge/client.ts";
import { WorkbenchConnection } from "../bridge/connection.ts";
import {
  AttachmentCleanupError,
  type AttachmentAddOperation,
  type AddView,
} from "../bridge/attachment-receive.ts";
import type {
  TaskCreateReason,
  TaskCompactReason,
  TaskRestoreReason,
  RunInputView,
  McpMutationResult,
  McpRefreshResult,
  McpConfigurationApplyResult,
  McpConnectionTestResult,
  SkillMutationResult,
  SkillEnablementResult,
  TaskRunReason,
  SendInputReason,
  TaskModelSelectionReason,
  TaskModelSelectionAvailability,
  ModelRef,
  TaskView,
  TaskSummary,
  FileReferenceView,
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
  ApprovalMode,
  WorkbenchSnapshot,
  UiResponsePayload,
} from "../bridge/contracts.ts";
import { useI18n, type MessageId } from "../i18n/context.ts";
import {
  searchWorkbench,
  boundedSearchQuery,
  selectActiveTask,
  pendingInputContinuation,
  taskDisplayState,
  taskSignals,
  workspaceDirectoryLabel,
  type SearchResult,
} from "../workbench/selectors.ts";
import { chooseWorkspaceAndMigrateDraft } from "../features/workspaces/chooseWorkspace.ts";
import { initialWorkbenchState, workbenchReducer } from "../workbench/store.ts";
import { navigableTasks } from "../workbench/task-visibility.ts";
import { PendingScopes } from "../workbench/pendingScopes.ts";
import {
  readyModelOptions,
  modelOptionId,
} from "./new-task-model-selection.ts";
import { taskModelSelectionPolicy } from "./task-model-selection.ts";
import { AttachmentRemovalCoordinator } from "./attachment-removal.ts";
import {
  modelSetupNotice,
  supportsCustomProviders,
  type ModelSetupAction,
} from "../workbench/model-setup.ts";
import {
  ModelSetupDialog,
  ModelSetupNotice,
  modelSetupMessage,
} from "../features/models/ModelSetup.tsx";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../platform/local-preferences.ts";
const modelSetupPreferenceKey = "metawork.model-setup-handled";
function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
function taskModelSelectionMessageId(
  availability: TaskModelSelectionAvailability | undefined,
): MessageId {
  switch (availability) {
    case "available":
      return "settings.task_model_help";
    case "catalog_loading":
      return "settings.task_model_catalog_loading";
    case "catalog_unavailable":
      return "settings.task_model_catalog_unavailable";
    case "task_unavailable":
    default:
      return "settings.task_model_task_unavailable";
  }
}
type MutationReason =
  | TaskCreateReason
  | TaskCompactReason
  | TaskRestoreReason
  | TaskRunReason
  | SendInputReason
  | TaskModelSelectionReason;
function mutationReasonMessageId(reason: MutationReason): MessageId {
  return `mutation.reason.${reason}`;
}
const automaticWorkspaceOptionId = "automatic";
type FileChangeDiffUiState =
  | {
      phase: "idle";
      diff: null;
      requestGeneration?: undefined;
    }
  | {
      phase: "loading";
      diff: null;
      requestGeneration: number;
    }
  | {
      phase: "settled";
      diff: FileChangeDiffResult;
      requestGeneration: number;
    }
  | {
      phase: "failed";
      diff: null;
      requestGeneration: number;
    };
type FileChangesIdentity = {
  taskId: string;
  runId: string;
  observation: RunFileChanges["observation"];
  changes: FileChangeView[];
  sessionGeneration: number;
  diffs: Record<string, FileChangeDiffUiState>;
  focus: FileChangeFocus | null;
};
type FileChangesUiState =
  | {
      kind: "closed";
    }
  | (FileChangesIdentity & {
      kind: "open";
    });
function orderedFileChanges(changes: FileChangeView[]): FileChangeView[] {
  return [...changes].sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
}
type LocalTaskSubmission = {
  anchor: LocalReadingInput["anchor"];
  operationId: string;
  taskId: string | null;
  scope: string;
  generation: string;
  draft: ComposerDraft;
  state: "submitting" | "accepted" | "unknown" | "failed" | "cancelled";
  reason?: MutationReason;
  blockingTaskId?: string;
};
import {
  ArchiveNotice,
  type ArchiveNoticeValue,
} from "../features/tasks/ArchiveNotice.tsx";

export default function App() {
  const { t } = useI18n();
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [archivedQuery, setArchivedQuery] = useState("");
  const archiveView = useRef<{ scrollTop: number; focusTaskId: string | null }>(
    { scrollTop: 0, focusTaskId: null },
  );
  const [archiveNotice, setArchiveNotice] = useState<ArchiveNoticeValue | null>(
    null,
  );
  const archiveNoticeId = useRef(0);
  const deleteOpener = useRef<HTMLElement | null>(null);
  const deleteCancel = useRef<HTMLButtonElement>(null);
  const [taskArchiveErrors, setTaskArchiveErrors] = useState<
    Record<string, string>
  >({});
  const [route, setRoute] = useState<ShellRoute>("workbench");
  const [rightPanelOpen, setRightPanelOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [modelSetupOpen, setModelSetupOpen] = useState(false);
  const [modelSetupHandled, setModelSetupHandled] = useState(
    () => readLocalPreference(modelSetupPreferenceKey) === "true",
  );
  const modelSetupReturnFocus = useRef<HTMLElement | null>(null);
  const [modelSetupComposing, setModelSetupComposing] = useState(false);
  const settingsRestoreFocus = useRef<HTMLElement | null>(null);
  const [settingsFocus, setSettingsFocus] =
    useState<SettingsFocusTarget>("title");
  const [searchOpen, setSearchOpen] = useState(false);
  const [taskStageExposed, setTaskStageExposed] = useState(false);
  const [documentAttention, setDocumentAttention] = useState(() =>
    typeof document === "undefined" ? false : documentHasAttention(document),
  );
  const [
    completionAcknowledgementFailure,
    setCompletionAcknowledgementFailure,
  ] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchHostQuery, setSearchHostQuery] = useState("");
  const [searchCursor, setSearchCursor] = useState<
    import("../bridge/contracts.ts").SearchCursor | null
  >(null);
  useEffect(() => {
    const timer = setTimeout(() => {
      setSearchHostQuery(searchQuery.trim());
      setSearchCursor(null);
    }, 180);
    return () => clearTimeout(timer);
  }, [searchQuery]);

  const [skillsQuery, setSkillsQuery] = useState("");
  const [mcpQuery, setMcpQuery] = useState("");
  const [renameEditor, setRenameEditor] = useState<{
    taskId: string;
    draft: string;
    message: MessageId | null;
  } | null>(null);
  const renameInput = useRef<HTMLInputElement>(null);
  const renameComposing = useRef(false);
  const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null);
  const confirmDelete = deleteTargetId !== null;
  const [fileChanges, setFileChanges] = useState<FileChangesUiState>({
    kind: "closed",
  });
  const fileChangesGeneration = useRef(0);
  const fileChangeRequestGeneration = useRef(0);
  const fileChangeFocusRequest = useRef(0);
  const fileChangeRequestsInFlight = useRef(new Set<string>());
  const [statuses, setStatuses] = useState<ShellStatusState>(() =>
    publishStatus(
      {},
      quietStatus("connection.connecting", { scope: "connection" }),
    ),
  );
  const [accountBusy, setAccountBusy] = useState(false);
  const [executionBusy, setExecutionBusy] = useState(false);
  const [workspaceBusy, setWorkspaceBusy] = useState(false);
  const [newTaskApprovalOverride, setNewTaskApprovalOverride] =
    useState<ApprovalMode | null>(null);
  const [newTaskRequestedModel, setNewTaskRequestedModel] =
    useState<ModelRef | null>(null);
  const [skillCatalogBusy, setSkillCatalogBusy] = useState(false);
  const skillRefreshPending = useRef(new Set<string>());
  const [skillRefreshRequests, setSkillRefreshRequests] =
    useState<SkillRefreshRequests>({});
  const sourceMutationPending = useRef(false);
  const [sourceMutationBusy, setSourceMutationBusy] = useState(false);
  const [sourceMutationError, setSourceMutationError] = useState<string | null>(
    null,
  );
  const [attachmentView, setAttachmentView] = useState<AddView | null>(null);
  const [attachmentRemoving, setAttachmentRemoving] = useState(false);
  const attachmentRemoval = useRef(
    new AttachmentRemovalCoordinator(setAttachmentRemoving),
  );
  const attachmentBusy = attachmentView !== null || attachmentRemoving;
  const [attachmentError, setAttachmentError] = useState<string | null>(null);
  const attachmentBusyRef = useRef(false);
  const attachmentOperation = useRef<{
    cancelled: boolean;
    add: AttachmentAddOperation;
  } | null>(null);
  const droppedAttachmentHandlerRef = useRef<(paths: string[]) => void>(
    () => undefined,
  );
  const [taskPending, setTaskPending] = useState<Record<string, string>>({});
  const approvalRequestsRef = useRef(new TaskApprovalRequests());
  const [approvalRequests, setApprovalRequests] = useState(
    approvalRequestsRef.current.view(),
  );
  const latestSnapshotRef = useRef<WorkbenchSnapshot | null>(null);
  const [cancelPending, setCancelPending] = useState<Record<string, true>>({});
  const [connectionBusy, setConnectionBusy] = useState(false);
  const [accountCancelBusy, setAccountCancelBusy] = useState(false);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [bridgeGeneration, setBridgeGeneration] = useState("0");
  const bridgeGenerationRef = useRef("0");
  const [viewSyncFailed, setViewSyncFailed] = useState(false);
  const [rootRenderBlockReason, setRootRenderBlockReason] = useState<
    "bootstrap_failed" | null
  >(null);
  const {
    states: uiResponseStates,
    begin: beginUiResponse,
    accepted: acceptUiResponse,
    failed: failUiResponse,
    observeSnapshot: observeUiResponseSnapshot,
  } = useUiResponseStates();
  const client = useMemo(() => new BridgeClient(), []);
  const connection = useRef<WorkbenchConnection | null>(null);
  const pendingTaskSelection = useRef<string | null>(null);
  const pendingTaskDraftSource = useRef<{
    taskId: string;
    draftId: string;
    generation: string;
  } | null>(null);
  const pendingTaskDraftRetention = useRef(new Set<string>());
  const taskPendingScopes = useRef(new PendingScopes());
  const cancelPendingTasks = useRef(new PendingScopes());
  const accountBusyRef = useRef(false);
  const executionBusyRef = useRef(false);
  const accountCancelBusyRef = useRef(false);
  const workspaceBusyRef = useRef(false);
  const connectionBusyRef = useRef(false);
  const connectionRetryRef = useRef<{
    promise: Promise<void>;
    replace: boolean;
  } | null>(null);
  const taskPanelToggle = useRef<HTMLButtonElement>(null);
  const taskInformationTrigger = useRef<HTMLButtonElement>(null);
  const taskPanelOpeners = useRef(new Map<string, HTMLButtonElement>());
  const composer = useRef<HTMLTextAreaElement>(null);
  const submissionSessions = useRef(new Map<string, TaskSubmissionSession>());
  const newTaskSubmissionInstance = useRef(0);
  const localSubmissionSequence = useRef(0);
  const [localSubmissions, setLocalSubmissions] = useState<
    LocalTaskSubmission[]
  >([]);
  const localSubmissionsRef = useRef(localSubmissions);
  localSubmissionsRef.current = localSubmissions;
  const submissionReconciliation = useRef<{
    running: boolean;
    pending: { snapshot: WorkbenchSnapshot; generation: string } | null;
    attempted: Map<string, string>;
  }>({ running: false, pending: null, attempted: new Map() });
  function reconcileSubmissionProjection(
    next: WorkbenchSnapshot,
    generation: string,
  ) {
    const queue = submissionReconciliation.current;
    queue.pending = { snapshot: next, generation };
    if (queue.running) return;
    queue.running = true;
    void (async () => {
      try {
        while (queue.pending) {
          const request = queue.pending;
          queue.pending = null;
          const pending = localSubmissionsRef.current;
          const ids = new Set(
            pending.flatMap((entry) =>
              entry.taskId &&
              !taskHasSubmission(
                request.snapshot.tasks.find((task) => task.id === entry.taskId),
                entry.operationId,
              ) &&
              request.snapshot.receipts.some(
                (r) =>
                  r.observed &&
                  r.taskId === entry.taskId &&
                  r.operationId === entry.operationId,
              )
                ? [entry.taskId]
                : [],
            ),
          );
          for (const id of queue.attempted.keys())
            if (!pending.some((entry) => entry.taskId === id))
              queue.attempted.delete(id);
          for (const taskId of ids) {
            const key = `${request.generation}:${request.snapshot.securityEpoch}:${request.snapshot.revision}`;
            if (queue.attempted.get(taskId) === key) continue;
            queue.attempted.set(taskId, key);
            let beforeRunId: string | null = null;
            const matched = new Set<string>();
            let oldestMatchedRun: string | null = null;
            try {
              // One read at a time, at most four bounded pages per Task/revision.
              for (let page = 0; page < 4; page++) {
                if (bridgeGenerationRef.current !== request.generation) break;
                const canonical = await client.fetchSnapshot({
                  taskId,
                  beforeRunId,
                  runLimit: 4,
                  management: "none",
                  search: false,
                  searchQuery: "",
                  searchCursor: null,
                  receipts: [],
                });
                if (
                  bridgeGenerationRef.current !== request.generation ||
                  canonical.securityEpoch !== request.snapshot.securityEpoch ||
                  canonical.securityEpoch !==
                    latestSnapshotRef.current?.securityEpoch ||
                  canonical.historyEpoch !== request.snapshot.historyEpoch ||
                  canonical.historyEpoch !==
                    latestSnapshotRef.current?.historyEpoch
                )
                  break;
                const task = canonical.tasks.find((item) => item.id === taskId);
                if (!task) break;
                const visible = {
                  ...task,
                  runs: [...(canonical.historyPage?.runs ?? []), ...task.runs],
                };
                for (const entry of pending)
                  if (
                    entry.taskId === taskId &&
                    taskHasSubmission(visible, entry.operationId)
                  ) {
                    matched.add(entry.operationId);
                    const source = visible.runs.find(
                      (run) =>
                        run.submission?.operationId === entry.operationId ||
                        run.additionalInputs.some(
                          (input) => input.operationId === entry.operationId,
                        ),
                    );
                    if (
                      source &&
                      (!oldestMatchedRun ||
                        BigInt(source.id) < BigInt(oldestMatchedRun))
                    )
                      oldestMatchedRun = source.id;
                  }
                if (
                  pending
                    .filter((entry) => entry.taskId === taskId)
                    .every((entry) => matched.has(entry.operationId))
                )
                  break;
                const cursor =
                  canonical.historyPage?.nextBeforeRunId ??
                  canonical.taskPage?.nextBeforeRunId ??
                  null;
                if (!cursor || cursor === beforeRunId) break;
                beforeRunId = cursor;
              }
              if (
                matched.size &&
                bridgeGenerationRef.current === request.generation &&
                latestSnapshotRef.current?.securityEpoch ===
                  request.snapshot.securityEpoch &&
                latestSnapshotRef.current?.historyEpoch ===
                  request.snapshot.historyEpoch
              ) {
                if (activeTaskIdRef.current === taskId) {
                  if (oldestMatchedRun)
                    retainTaskHistory(taskId, oldestMatchedRun);
                  void refreshSnapshot().catch(() => undefined);
                }
                setLocalSubmissions((entries) =>
                  entries.filter(
                    (entry) =>
                      entry.taskId !== taskId ||
                      !matched.has(entry.operationId) ||
                      (activeTaskIdRef.current === taskId &&
                        !taskHasSubmission(
                          latestSnapshotRef.current?.tasks.find(
                            (task) => task.id === taskId,
                          ),
                          entry.operationId,
                        )),
                  ),
                );
              }
            } catch {
              // A failed adjunct read leaves the only display copy intact.
            }
          }
        }
      } finally {
        queue.running = false;
      }
    })();
  }
  function setStatus(status: ShellStatus) {
    setStatuses((current) => publishStatus(current, status));
  }
  const snapshot = workbench.snapshot;
  const deleteTarget =
    snapshot.taskIndex.find((task) => task.id === deleteTargetId) ?? null;
  useEffect(() => {
    if (deleteTargetId && !deleteTarget) setDeleteTargetId(null);
  }, [deleteTargetId, deleteTarget]);
  const noticeTask = snapshot.taskIndex.find(
    (task) => task.id === archiveNotice?.taskId,
  );
  const newTaskApprovalMode =
    newTaskApprovalOverride ?? snapshot.permissions.defaultMode;
  const activeTask = useMemo(() => selectActiveTask(workbench), [workbench]);
  const [taskReadingMemory] = useState(createTaskReadingMemory);
  useEffect(() => {
    // Reclaim after TaskContent's unmount cleanup has saved its last position.
    taskReadingMemory.prune(
      new Set(snapshot.taskIndex.map((task) => task.id)),
      snapshot.taskPage?.task
        ? {
            taskId: snapshot.taskPage.task.id,
            runIds: new Set(snapshot.taskPage.runManifest.map((run) => run.id)),
          }
        : undefined,
    );
  }, [snapshot.taskIndex, snapshot.taskPage, taskReadingMemory]);
  function retainTaskHistory(taskId: string, runId: string) {
    setHistoryRequests((goals) => {
      const previous = goals[taskId];
      return previous && BigInt(previous.oldestRunId) <= BigInt(runId)
        ? goals
        : { ...goals, [taskId]: { taskId, oldestRunId: runId } };
    });
  }
  const [historyRequests, setHistoryRequests] = useState<
    Record<string, HistoryGoal>
  >({});
  const history = historyProgress(
    snapshot,
    workbench.activeTaskId,
    historyRequests[workbench.activeTaskId ?? ""] ?? null,
  );
  const historyCursor = history.beforeRunId;
  const historyLoading =
    history.loading || snapshot.scope.taskId !== workbench.activeTaskId;
  const nextHistoryCursor = history.nextBeforeRunId;
  const selectedTaskSummary = snapshot.taskIndex.find(
    (task) => task.id === workbench.activeTaskId,
  );
  const activeTaskIdRef = useRef<string | null>(null);
  activeTaskIdRef.current = workbench.activeTaskId;
  function focusTaskPanelTab(tabId: string) {
    window.requestAnimationFrame(() => {
      const tab = [
        ...document.querySelectorAll<HTMLButtonElement>(
          "[data-task-panel-tab-id]",
        ),
      ].find((candidate) => candidate.dataset.taskPanelTabId === tabId);
      (tab ?? taskPanelToggle.current)?.focus({
        preventScroll: true,
      });
    });
  }
  function openFilePreview(
    taskId: string,
    runId: string,
    reference: FileReferenceView,
    opener: HTMLButtonElement,
  ) {
    const task = snapshot.tasks.find((candidate) => candidate.id === taskId);
    const run = task?.runs.find((candidate) => candidate.id === runId);
    if (!task || !run || activeTaskIdRef.current !== taskId) return;
    const selected = findRunFileReference(run, reference.id);
    if (!selected) return;
    const tab = createTaskPanelPreviewTab(taskId, runId, selected);
    setRightPanelOpen(true);
    taskPanelOpeners.current.set(tab.tabId, opener);
    retainTaskHistory(taskId, runId);
    taskPanel.openPreview(taskId, runId, selected);
    filePreviewTabs.open(taskId, runId, selected);
    focusTaskPanelTab(tab.tabId);
  }
  function refreshFilePreview() {
    const active = taskPanel.activeTab;
    if (!active || active.kind !== "preview") return;
    filePreviewTabs.refresh(active.taskId, active.runId, {
      id: active.referenceId,
      title: active.title,
      displayPath: active.displayPath,
    });
  }
  function clearFileChanges() {
    fileChangesGeneration.current += 1;
    fileChangeRequestsInFlight.current.clear();
    setFileChanges({ kind: "closed" });
  }
  function requestFileChangeDiff(
    taskId: string,
    runId: string,
    change: FileChangeView,
    sessionGeneration: number,
  ) {
    if (fileChangesGeneration.current !== sessionGeneration) return;
    const requestKey = `${sessionGeneration}:${change.id}`;
    if (fileChangeRequestsInFlight.current.has(requestKey)) return;
    const requestGeneration = fileChangeRequestGeneration.current + 1;
    fileChangeRequestGeneration.current = requestGeneration;
    const updateDiff = (next: FileChangeDiffUiState) =>
      setFileChanges((current) => {
        if (
          current.kind === "closed" ||
          current.taskId !== taskId ||
          current.runId !== runId ||
          current.sessionGeneration !== sessionGeneration ||
          !current.changes.some((candidate) => candidate.id === change.id)
        )
          return current;
        return {
          ...current,
          diffs: { ...current.diffs, [change.id]: next },
        };
      });
    if (!change.diffAvailable) {
      updateDiff({
        phase: "settled",
        requestGeneration,
        diff: {
          status: "unavailable",
          reason: "not_recorded",
          content: "",
        },
      });
      return;
    }
    fileChangeRequestsInFlight.current.add(requestKey);
    updateDiff({ phase: "loading", diff: null, requestGeneration });
    void client
      .fileChangeDiff(taskId, runId, change.id)
      .then((diff) => {
        if (
          fileChangesGeneration.current !== sessionGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setFileChanges((current) => {
          if (
            current.kind === "closed" ||
            current.taskId !== taskId ||
            current.runId !== runId ||
            current.sessionGeneration !== sessionGeneration ||
            current.diffs[change.id]?.requestGeneration !== requestGeneration
          )
            return current;
          return {
            ...current,
            diffs: {
              ...current.diffs,
              [change.id]: { phase: "settled", requestGeneration, diff },
            },
          };
        });
      })
      .catch(() => {
        if (
          fileChangesGeneration.current !== sessionGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setFileChanges((current) => {
          if (
            current.kind === "closed" ||
            current.taskId !== taskId ||
            current.runId !== runId ||
            current.sessionGeneration !== sessionGeneration ||
            current.diffs[change.id]?.requestGeneration !== requestGeneration
          )
            return current;
          return {
            ...current,
            diffs: {
              ...current.diffs,
              [change.id]: { phase: "failed", diff: null, requestGeneration },
            },
          };
        });
      })
      .finally(() => {
        fileChangeRequestsInFlight.current.delete(requestKey);
      });
  }
  function openFileChanges(
    taskId: string,
    runId: string,
    opener: HTMLButtonElement,
    displayPath?: string,
  ) {
    if (!snapshot.capabilities.typedFileChanges) return;
    const task = snapshot.tasks.find((candidate) => candidate.id === taskId);
    const run = task?.runs.find((candidate) => candidate.id === runId);
    const recorded = run?.fileChanges;
    if (
      !task ||
      !run ||
      !recorded ||
      recorded.changes.length === 0 ||
      activeTaskIdRef.current !== taskId
    )
      return;
    const focus =
      displayPath &&
      recorded.changes.some((change) => change.displayPath === displayPath)
        ? {
            displayPath,
            requestId: ++fileChangeFocusRequest.current,
          }
        : null;
    const changes = orderedFileChanges(recorded.changes);
    const tab = createTaskPanelReviewTab(taskId, runId);
    setRightPanelOpen(true);
    taskPanelOpeners.current.set(tab.tabId, opener);
    const existingReview = taskPanel.session.tabs.find(
      (tab) => tab.kind === "review",
    );
    if (existingReview?.runId !== runId) taskPanelViews.reset(tab.tabId);
    retainTaskHistory(taskId, runId);
    taskPanel.openReview(taskId, runId);
    if (focus)
      taskPanelViews.setFileExpanded(tab.tabId, focus.displayPath, true);
    if (
      existingReview?.runId === runId &&
      fileChanges.kind === "open" &&
      fileChanges.taskId === taskId &&
      fileChanges.runId === runId
    ) {
      setFileChanges((current) =>
        current.kind === "open" &&
        current.taskId === taskId &&
        current.runId === runId
          ? { ...current, focus }
          : current,
      );
      if (focus) {
        const focusedChange = changes.find(
          (change) => change.displayPath === focus.displayPath,
        );
        if (focusedChange) loadFileChangeDiff(focusedChange);
      }
      if (!focus) focusTaskPanelTab(tab.tabId);
      return;
    }
    const sessionGeneration = fileChangesGeneration.current + 1;
    fileChangesGeneration.current = sessionGeneration;
    fileChangeRequestsInFlight.current.clear();
    setFileChanges({
      kind: "open",
      taskId,
      runId,
      observation: recorded.observation,
      changes,
      sessionGeneration,
      focus,
      diffs: Object.fromEntries(
        changes.map((change) => [change.id, { phase: "idle", diff: null }]),
      ),
    });
    requestFileChangeDiff(
      taskId,
      runId,
      (focus
        ? changes.find((change) => change.displayPath === focus.displayPath)
        : null) ?? changes[0]!,
      sessionGeneration,
    );
    if (!focus) focusTaskPanelTab(tab.tabId);
  }
  function loadFileChangeDiff(change: FileChangeView) {
    if (fileChanges.kind === "closed") return;
    const current = fileChanges.diffs[change.id];
    if (
      !current ||
      current.phase === "loading" ||
      (current.phase === "settled" &&
        !(
          current.diff.status === "unavailable" &&
          current.diff.reason === "capacity"
        ))
    )
      return;
    requestFileChangeDiff(
      fileChanges.taskId,
      fileChanges.runId,
      change,
      fileChanges.sessionGeneration,
    );
  }
  useEffect(() => {
    clearFileChanges();
  }, [workbench.activeTaskId]);
  useEffect(() => {
    setFileChanges((current) => {
      if (current.kind === "closed") return current;
      const task = snapshot.tasks.find(
        (candidate) => candidate.id === current.taskId,
      );
      if (
        !task &&
        snapshot.taskIndex.some((entry) => entry.id === current.taskId)
      )
        return current;
      const run = task?.runs.find(
        (candidate) => candidate.id === current.runId,
      );
      if (
        !run &&
        snapshot.taskPage?.task.id === current.taskId &&
        snapshot.taskPage.runManifest.some(
          (entry) => entry.id === current.runId,
        )
      )
        return current;
      const recorded = run?.fileChanges;
      if (!task || !run || !recorded || recorded.changes.length === 0) {
        fileChangesGeneration.current += 1;
        fileChangeRequestsInFlight.current.clear();
        return { kind: "closed" };
      }
      const changes = orderedFileChanges(recorded.changes);
      const diffs = Object.fromEntries(
        changes.map((change) => [
          change.id,
          current.diffs[change.id] ?? { phase: "idle", diff: null },
        ]),
      );
      return {
        ...current,
        observation: recorded.observation,
        changes,
        diffs,
      };
    });
  }, [snapshot.revision, snapshot.tasks, snapshot.taskIndex]);
  const panelTask = route === "workbench" ? activeTask : null;
  const taskPanel = useTaskPanelTarget(
    panelTask,
    snapshot.capabilities.typedFileChanges,
    snapshot.taskPage?.runManifest,
  );
  const previewTabIds = useMemo(
    () =>
      new Set(
        taskPanel.session.tabs.flatMap((tab) =>
          tab.kind === "preview" ? [tab.tabId] : [],
        ),
      ),
    [taskPanel.session.tabs],
  );
  const taskPanelTabIds = useMemo(
    () => new Set(taskPanel.session.tabs.map((tab) => tab.tabId)),
    [taskPanel.session.tabs],
  );
  const loadFilePreview = useCallback(
    (
      taskId: string,
      runId: string,
      referenceId: string,
      options?: import("../bridge/contracts.ts").FilePreviewLoadOptions,
    ) => client.previewFile(taskId, runId, referenceId, options),
    [client],
  );
  const filePreviewTabs = useFilePreviewTabs(
    route === "workbench" ? workbench.activeTaskId : null,
    previewTabIds,
    loadFilePreview,
  );
  const taskPanelViews = useTaskPanelViewStates(taskPanelTabIds);
  useEffect(() => {
    for (const tabId of taskPanelOpeners.current.keys())
      if (!taskPanelTabIds.has(tabId)) taskPanelOpeners.current.delete(tabId);
  }, [taskPanelTabIds]);
  const panelTarget = taskPanel.target;
  const reviewTab = taskPanel.session.tabs.find((tab) => tab.kind === "review");
  useEffect(() => {
    if (
      !reviewTab ||
      (fileChanges.kind === "open" &&
        (fileChanges.taskId !== reviewTab.taskId ||
          fileChanges.runId !== reviewTab.runId))
    )
      clearFileChanges();
  }, [reviewTab?.taskId, reviewTab?.runId]);
  const manualWorkspaces = useMemo(
    () =>
      snapshot.workspaces.filter((workspace) => workspace.kind === "manual"),
    [snapshot.workspaces],
  );
  const navigableTaskItems = useMemo(
    () => navigableTasks(snapshot),
    [snapshot],
  );
  useEffect(() => {
    setSearchCursor(null);
  }, [snapshot.securityEpoch, bridgeGeneration]);
  useEffect(() => {
    if (snapshot.searchIndex?.stale) setSearchCursor(null);
  }, [snapshot.searchIndex]);
  const searchCurrent =
    snapshot.scope.searchQuery === searchHostQuery &&
    searchQuery.trim() === searchHostQuery &&
    JSON.stringify(snapshot.scope.searchCursor) ===
      JSON.stringify(searchCursor);
  const searchResults = useMemo(
    () => (searchCurrent ? searchWorkbench(snapshot, searchHostQuery) : []),
    [searchHostQuery, snapshot, searchCurrent],
  );
  // Empty work quanta continue automatically; only pages with visible hits
  // require a user's next-page action. No result corpus accumulates here.
  useEffect(() => {
    if (
      searchOpen &&
      searchCurrent &&
      snapshot.searchIndex &&
      !snapshot.searchIndex.stale &&
      snapshot.searchIndex.results.length === 0 &&
      snapshot.searchIndex.nextCursor
    )
      setSearchCursor(snapshot.searchIndex.nextCursor);
  }, [searchOpen, searchCurrent, snapshot.searchIndex]);
  const taskDrafts = useTaskDrafts(workbench.activeTaskId);
  const newTaskDraftActive =
    workbench.draftOpen || workbench.activeTaskId === null;
  const newTaskDraftId = newTaskDraftStorageId(
    newTaskDraftActive,
    workbench.draftWorkspaceId,
  );
  const newTaskDrafts = useNewTaskDrafts(newTaskDraftId);
  const composerDraft = newTaskDraftActive
    ? newTaskDrafts.draft
    : taskDrafts.draft;
  const updateComposerDraft = newTaskDraftActive
    ? newTaskDrafts.updateDraft
    : taskDrafts.updateDraft;
  const composerDraftRef = useRef(composerDraft);
  composerDraftRef.current = composerDraft;
  const composerDraftScope = newTaskDraftActive
    ? `new-task:${newTaskDraftId ?? unscopedNewTaskDraftId}:${newTaskSubmissionInstance.current}`
    : `task:${workbench.activeTaskId ?? "missing"}`;
  const composerDraftScopeRef = useRef(composerDraftScope);
  composerDraftScopeRef.current = composerDraftScope;
  const attachmentAudience = useRef({
    scope: composerDraftScope,
    generation: bridgeGeneration,
    route,
    settingsOpen,
    searchOpen,
  });
  const audience = attachmentAudience.current;
  if (
    audience.scope !== composerDraftScope ||
    audience.generation !== bridgeGeneration ||
    audience.route !== route ||
    audience.settingsOpen !== settingsOpen ||
    audience.searchOpen !== searchOpen
  )
    attachmentAudience.current = {
      scope: composerDraftScope,
      generation: bridgeGeneration,
      route,
      settingsOpen,
      searchOpen,
    };
  useLayoutEffect(() => {
    attachmentRemoval.current.resetGeneration(bridgeGeneration);
  }, [bridgeGeneration]);
  useLayoutEffect(() => {
    const removal = attachmentRemoval.current;
    return () => removal.dispose();
  }, []);
  useEffect(() => setAttachmentError(null), [composerDraftScope]);
  useLayoutEffect(
    () => () => {
      const operation = attachmentOperation.current;
      if (!operation) return;
      operation.cancelled = true;
      void operation.add.cancel().catch(() => undefined);
    },
    [composerDraftScope, bridgeGeneration, route, settingsOpen, searchOpen],
  );
  const previousBridgeGeneration = useRef(bridgeGeneration);
  useEffect(() => {
    const previous = previousBridgeGeneration.current;
    previousBridgeGeneration.current = bridgeGeneration;
    if (previous === "0" || previous === bridgeGeneration) return;
    taskPanel.clearTarget();
    filePreviewTabs.clear();
    clearFileChanges();
    taskPanelOpeners.current.clear();
    taskDrafts.invalidateAttachments();
    newTaskDrafts.invalidateAttachments();
    setAttachmentError(null);
  }, [
    bridgeGeneration,
    newTaskDrafts.invalidateAttachments,
    taskDrafts.invalidateAttachments,
  ]);
  const bridgeUnavailable = viewSyncFailed || !bridgeReady;
  const openExternalLink = useCallback(
    async (url: string) => {
      if (viewSyncFailed || !bridgeReady) return false;
      try {
        return (await client.openExternalLink(url)).outcome === "opened";
      } catch {
        return false;
      }
    },
    [bridgeReady, client, viewSyncFailed],
  );
  const markdownWebLink = useMemo(
    () => ({ failedLabel: t("link.open_failed"), onOpen: openExternalLink }),
    [openExternalLink, t],
  );
  const completionAcknowledgement = completionAcknowledgementCandidate({
    task: newTaskDraftActive ? null : activeTask,
    workbenchRoute: route === "workbench",
    settingsOpen,
    searchOpen,
    modalOpen: confirmDelete,
    taskStageExposed,
    documentAttention,
    bridgeAvailable: !bridgeUnavailable,
  });
  const suppressedCompletionTaskId = completionReminderSuppressionTaskId(
    completionAcknowledgement,
    completionAcknowledgementFailure,
  );
  useEffect(() => {
    if (typeof document === "undefined" || typeof window === "undefined")
      return;
    return subscribeDocumentAttention(document, window, setDocumentAttention);
  }, []);
  useEffect(() => {
    if (completionAcknowledgement === null) return;
    const { taskId, runId, key } = completionAcknowledgement;
    let current = true;
    setCompletionAcknowledgementFailure((failure) =>
      failure === key ? null : failure,
    );
    void client
      .markTaskCompletionSeen(taskId, runId)
      .then(({ marked }) => {
        if (current && !marked) setCompletionAcknowledgementFailure(key);
      })
      .catch(() => {
        if (current) setCompletionAcknowledgementFailure(key);
      });
    return () => {
      current = false;
    };
  }, [client, completionAcknowledgement?.key]);
  const workbenchMutationDisabled = bridgeUnavailable;
  const currentTaskScope = activeTask ? `task:${activeTask.id}` : "new-task";
  const taskMutationPending =
    currentTaskScope in taskPending ||
    Boolean(
      activeTask &&
      (activeTask.approvalChange || approvalRequests[activeTask.id]),
    );
  const taskMutationDisabled = workbenchMutationDisabled || taskMutationPending;
  const renameTarget = renameEditor
    ? snapshot.taskIndex.find((task) => task.id === renameEditor.taskId)
    : null;
  const renamePending = renameEditor
    ? `task:${renameEditor.taskId}` in taskPending
    : false;
  useEffect(() => {
    if (
      renameEditor &&
      (!renameTarget ||
        renameTarget.archived ||
        renameTarget.historyReadOnly ||
        renameTarget.deletionStatus === "deleting" ||
        settingsOpen ||
        route !== "workbench")
    )
      setRenameEditor(null);
  }, [renameEditor, renameTarget, settingsOpen, route]);
  const refreshSnapshot = useCallback(() => {
    const current = connection.current;
    return current
      ? current.refresh()
      : Promise.reject(new Error("Workbench connection is unavailable"));
  }, []);
  const inputContinuation = pendingInputContinuation(activeTask);
  const taskCanCompose =
    newTaskDraftActive || Boolean(activeTask?.inputAcceptance.available);
  const outputEditContext = useRef({
    task: activeTask,
    allowed: taskCanCompose && !newTaskDraftActive && !bridgeUnavailable,
    audience: attachmentAudience.current,
  });
  outputEditContext.current = {
    task: activeTask,
    allowed: taskCanCompose && !newTaskDraftActive && !bridgeUnavailable,
    audience: attachmentAudience.current,
  };
  const taskOperationInFlight = Boolean(
    activeTask?.activeOperation ||
    inputContinuation ||
    activeTask?.inputSubmissions.some((input) => input.state === "waiting"),
  );
  const composerWorkspaceId =
    activeTask?.workspaceId ??
    selectedTaskSummary?.workspaceId ??
    workbench.draftWorkspaceId;
  const composerWorkspace = snapshot.workspaces.find(
    (workspace) => workspace.id === composerWorkspaceId,
  );
  const newTaskWorkspaceReady = workbench.draftWorkspaceId
    ? composerWorkspace?.authorization === "available"
    : snapshot.capabilities.automaticWorkspaces;
  const skillCatalog = newTaskDraftActive
    ? (composerWorkspace?.skillCatalog ?? {
        availability: "unavailable" as const,
        redacted: false,
        revision: null,
        selectionRevision: null,
        skills: [],
        issues: [],
      })
    : (activeTask?.skillCatalog ?? {
        availability: "unavailable" as const,
        redacted: false,
        revision: null,
        selectionRevision: null,
        skills: [],
        issues: [],
      });
  const skillDraftCurrent =
    composerDraft.kind !== "skill" ||
    isSkillDraftCurrent(composerDraft, skillCatalog);
  const composerRunInput = composerDraftToRunInput(composerDraft);
  const newTaskModelState = newTaskModelSelectionState(
    snapshot.models,
    snapshot.newTaskAdmission,
    newTaskRequestedModel,
  );
  const composerContentReady =
    composerDraftHasContent(composerDraft) &&
    composerRunInput !== null &&
    composerDraftWithinLimits(composerDraft) &&
    skillDraftCurrent &&
    (composerDraft.kind !== "skill" || !skillCatalogBusy);
  // Unknown results still own their local record, including in other Tasks.
  const localSubmissionCount = localSubmissions.filter(
    (entry) =>
      entry.scope !== composerDraftScope ||
      entry.state === "submitting" ||
      entry.state === "accepted" ||
      entry.state === "unknown",
  ).length;
  const taskIdentityPending =
    newTaskDraftActive &&
    submissionSessions.current.has(
      `${bridgeGenerationRef.current}:${composerDraftScope}`,
    );
  const canCreateTask =
    (snapshot.newTaskAdmission.available ||
      newTaskModelState.intent !== null) &&
    newTaskWorkspaceReady &&
    newTaskModelState.valid;
  const canSubmit =
    taskCanCompose &&
    composerContentReady &&
    !attachmentBusy &&
    !bridgeUnavailable &&
    !workspaceBusy &&
    localSubmissionCount < maxLocalTaskSubmissions &&
    (!newTaskDraftActive || taskIdentityPending || canCreateTask);
  const inputDisabledReason: MessageId | undefined =
    localSubmissionCount >= maxLocalTaskSubmissions
      ? "input.local_capacity"
      : undefined;
  const metaskProvider = snapshot.models.providers.find(
    (provider) => provider.id === "metask",
  );
  const taskIntent = activeTask?.modelIntent;
  const taskModelOptions = readyModelOptions(
    snapshot.models,
    taskIntent?.modelRef.sourceId ?? null,
  );
  const displayedTaskModelId = taskIntent
    ? modelOptionId(taskIntent.modelRef)
    : "";
  const taskModelOption = taskModelOptions.find(
    (option) => option.selectionId === displayedTaskModelId,
  );
  const composerModelMetadata = newTaskDraftActive
    ? newTaskModelState.selectedMetadata
    : (taskModelOption?.metadata ?? null);
  const imageDeclaredUnsupported =
    composerDraft.kind === "multimodal" &&
    composerModelMetadata?.capabilities.imageInput === false &&
    composerDraft.attachments.some((attachment) => attachment.kind === "image");
  const attachmentModelWarning = imageDeclaredUnsupported
    ? ("image" as const)
    : null;
  const selectedModelLabel =
    newTaskModelState.selectedModelLabel || t("account.choose_model");
  const hasReadyModels = useMemo(
    () =>
      [...snapshot.models.providers, ...snapshot.models.customProviders].some(
        (provider) =>
          readyModelOptions(snapshot.models, provider.id).length > 0,
      ),
    [snapshot.models],
  );
  const customProvidersAvailable = supportsCustomProviders({
    management: snapshot.capabilities.customProviderManagement,
    secretCapture: snapshot.capabilities.customProviderSecretCapture,
    modelTest: snapshot.capabilities.customModelTest,
  });
  const setupNotice =
    bridgeUnavailable || !newTaskDraftActive
      ? null
      : modelSetupNotice({
          account: snapshot.account,
          models: snapshot.models,
          admission: snapshot.newTaskAdmission,
          selected:
            newTaskRequestedModel ??
            snapshot.newTaskAdmission.activeModelRef ??
            snapshot.models.defaultSelection,
          valid: newTaskModelState.valid,
          hasReadyModels,
          customProvidersAvailable,
          schedulesAvailable:
            snapshot.capabilities.scheduledTasks ||
            snapshot.capabilities.scheduledTaskRecoveryAvailable,
        });
  function rememberModelSetupIntroduction() {
    if (modelSetupHandled) return;
    setModelSetupHandled(true);
    writeLocalPreference(modelSetupPreferenceKey, "true");
  }
  function finishModelSetupIntroduction() {
    rememberModelSetupIntroduction();
    setModelSetupOpen(false);
  }
  function openModelSetup() {
    modelSetupReturnFocus.current =
      document.activeElement instanceof HTMLElement &&
      document.activeElement !== document.body
        ? document.activeElement
        : composer.current;
    setModelSetupOpen(true);
  }
  useEffect(() => {
    const start = () => setModelSetupComposing(true);
    const end = () => setModelSetupComposing(false);
    document.addEventListener("compositionstart", start);
    document.addEventListener("compositionend", end);
    return () => {
      document.removeEventListener("compositionstart", start);
      document.removeEventListener("compositionend", end);
    };
  }, []);
  useEffect(() => {
    if (bridgeUnavailable) return;
    if (hasReadyModels || newTaskModelState.valid) {
      rememberModelSetupIntroduction();
      // Available alternatives suppress automatic onboarding; they do not
      // dismiss a dialog the user opened to resolve an unusable selection.
      if (newTaskModelState.valid && modelSetupOpen) setModelSetupOpen(false);
      return;
    }
    if (
      modelSetupHandled ||
      modelSetupOpen ||
      route !== "workbench" ||
      !newTaskDraftActive ||
      settingsOpen ||
      searchOpen ||
      confirmDelete ||
      accountBusy ||
      executionBusy ||
      modelSetupComposing ||
      composerDraftHasContent(composerDraft) ||
      document.querySelector(
        '[role="dialog"], [role="alertdialog"], [role="menu"]',
      ) ||
      snapshot.account.state !== "signed_out" ||
      (snapshot.account.errorCode !== "none" &&
        snapshot.account.errorCode !== "user_cancelled") ||
      snapshot.models.customProviders.length > 0 ||
      newTaskRequestedModel !== null ||
      (setupNotice?.action !== "start" && setupNotice?.action !== "login")
    )
      return;
    openModelSetup();
  }, [
    bridgeUnavailable,
    hasReadyModels,
    newTaskModelState.valid,
    modelSetupHandled,
    modelSetupOpen,
    route,
    newTaskDraftActive,
    settingsOpen,
    searchOpen,
    confirmDelete,
    accountBusy,
    executionBusy,
    modelSetupComposing,
    composerDraft,
    snapshot.account.state,
    snapshot.account.errorCode,
    snapshot.models.customProviders.length,
    newTaskRequestedModel,
    setupNotice?.action,
  ]);
  function runModelSetupAction(action: ModelSetupAction) {
    switch (action) {
      case "start":
        openModelSetup();
        break;
      case "login":
        finishModelSetupIntroduction();
        void runAccountCommand(() => client.beginLogin());
        break;
      case "cancel":
        void cancelAccountOperation();
        break;
      case "refresh":
        void runExecutionCommand(() => client.refreshModelsCatalog());
        break;
      case "providers":
        if (customProvidersAvailable) openSettings("providers");
        break;
      case "models":
        openSettings("models");
        break;
      case "schedules":
        setRoute("scheduled-tasks");
        break;
    }
  }
  const taskModelLabel = taskIntent
    ? modelDisplayLabel(snapshot.models, taskIntent.modelRef)
    : activeTask
      ? activeTask.binding.model
      : selectedModelLabel;
  const taskModelPolicy = taskModelSelectionPolicy(activeTask);
  // The Host result is already committed. A failed follow-up refresh is
  // published by the connection owner, never reported as a failed operation.
  async function refreshCommittedView() {
    await refreshSnapshot().catch(() => undefined);
  }
  useEffect(() => {
    const errorCode = snapshot.account.errorCode;
    if (errorCode === "none" || errorCode === "user_cancelled") return;
    setStatus(
      attentionStatus(
        accountErrorMessageId(errorCode),
        { scope: "account" },
        {
          diagnostic: snapshot.account.safeDiagnostic || undefined,
        },
      ),
    );
  }, [snapshot.account.errorCode, snapshot.account.safeDiagnostic]);
  useEffect(() => {
    let cancelled = false;
    const current = new WorkbenchConnection(client, {
      onSnapshot: (next, generation) => {
        if (!cancelled) {
          observeUiResponseSnapshot(next);
          if (
            latestSnapshotRef.current &&
            latestSnapshotRef.current.securityEpoch !== next.securityEpoch
          )
            setHistoryRequests({});
          latestSnapshotRef.current = next;
          publishApprovalObservations(
            approvalRequestsRef.current.observe(next, generation),
          );
          setApprovalRequests(approvalRequestsRef.current.view());
          setLocalSubmissions((entries) =>
            entries.flatMap((entry) => {
              if (
                taskHasSubmission(
                  next.tasks.find((task) => task.id === entry.taskId),
                  entry.operationId,
                )
              )
                return [];
              const observed = next.receipts.some(
                (receipt) =>
                  receipt.taskId === entry.taskId &&
                  receipt.operationId === entry.operationId &&
                  receipt.observed,
              );
              return [
                {
                  ...entry,
                  state:
                    observed &&
                    (entry.state === "unknown" || entry.state === "submitting")
                      ? ("accepted" as const)
                      : entry.state,
                },
              ];
            }),
          );
          reconcileSubmissionProjection(next, generation);
          const projectedTaskIds = next.taskIndex.map((task) => task.id);
          setHistoryRequests((goals) => {
            if (Object.keys(goals).every((id) => projectedTaskIds.includes(id)))
              return goals;
            return Object.fromEntries(
              Object.entries(goals).filter(([id]) =>
                projectedTaskIds.includes(id),
              ),
            );
          });
          const discardedAttachments = taskDrafts.pruneDrafts([
            ...projectedTaskIds,
            ...pendingTaskDraftRetention.current,
          ]);
          for (const attachment of discardedAttachments)
            void client
              .releaseAttachment(attachment.token)
              .catch(() => undefined);
          for (const taskId of projectedTaskIds)
            pendingTaskDraftRetention.current.delete(taskId);
          dispatchWorkbench({
            type: "snapshot.accepted",
            snapshot: next,
            receivedAt: performance.now(),
            generation,
          });
          const pendingTaskId = pendingTaskSelection.current;
          if (
            pendingTaskId &&
            next.taskIndex.some((task) => task.id === pendingTaskId)
          ) {
            const source = pendingTaskDraftSource.current;
            if (source?.taskId === pendingTaskId) {
              const draft = newTaskDrafts.currentDraft(source.draftId);
              if (draft && source.generation === bridgeGenerationRef.current) {
                taskDrafts.setDraft(pendingTaskId, draft);
                newTaskDrafts.clearDraft(source.draftId);
              }
              pendingTaskDraftSource.current = null;
            }
            pendingTaskSelection.current = null;
            dispatchWorkbench({
              type: "task.selected",
              taskId: pendingTaskId,
            });
          }
        }
      },
      onStatus: (next) => {
        if (!cancelled) {
          if (next.kind === "connected") setRootRenderBlockReason(null);
          else if (
            next.kind !== "recovering" &&
            next.failure === "bootstrap_failed"
          )
            setRootRenderBlockReason("bootstrap_failed");
          setConnectionBusy(next.kind === "recovering");
          setStatus(connectionStatus(next));
        }
      },
      onReady: (ready) => {
        if (!cancelled) setBridgeReady(ready);
      },
      onSecurityInvalidated: (securityEpoch, generation) => {
        if (cancelled) return;
        setRenameEditor(null);
        latestSnapshotRef.current = null;
        setHistoryRequests({});
        taskReadingMemory.reading.clear();
        taskReadingMemory.processDisclosure.clear();
        taskReadingMemory.toolDisclosure.clear();
        filePreviewTabs.clear();
        clearFileChanges();
        approvalRequestsRef.current.reset(generation);
        setApprovalRequests({});
        dispatchWorkbench({
          type: "security.invalidated",
          securityEpoch,
          generation,
        });
      },
      onGeneration: (generation) => {
        if (!cancelled) {
          setHistoryRequests({});
          taskReadingMemory.reading.clear();
          taskReadingMemory.processDisclosure.clear();
          taskReadingMemory.toolDisclosure.clear();
          setLocalSubmissions((entries) =>
            entries.map((entry) =>
              entry.state === "submitting" || entry.state === "accepted"
                ? { ...entry, state: "unknown" }
                : entry,
            ),
          );
          submissionSessions.current.clear();
          bridgeGenerationRef.current = generation;
          approvalRequestsRef.current.reset(generation);
          latestSnapshotRef.current = null;
          setArchiveNotice(null);
          setApprovalRequests({});
          if (attachmentOperation.current) {
            attachmentOperation.current.cancelled = true;
            void attachmentOperation.current.add
              .cancel()
              .catch(() => undefined);
          }
          dispatchWorkbench({ type: "generation.started", generation });
          setBridgeGeneration(generation);
        }
      },
      onViewSyncFailed: (failed) => {
        if (!cancelled) setViewSyncFailed(failed);
      },
    });
    connection.current = current;
    void current.start().catch(() => undefined);
    const onPageHide = () => {
      void current.stop();
    };
    window.addEventListener("pagehide", onPageHide);
    return () => {
      cancelled = true;
      if (connection.current === current) connection.current = null;
      setBridgeReady(false);
      setRootRenderBlockReason(null);
      window.removeEventListener("pagehide", onPageHide);
      void current.stop();
    };
  }, [client, observeUiResponseSnapshot, taskDrafts.pruneDrafts]);
  useEffect(() => {
    const management =
      route === "skills"
        ? "skills"
        : route === "mcp"
          ? "mcp"
          : route === "scheduled-tasks"
            ? "schedules"
            : "none";
    void connection.current
      ?.setScope({
        taskId: route === "workbench" ? workbench.activeTaskId : null,
        beforeRunId: route === "workbench" ? historyCursor : null,
        runLimit: 4,
        management,
        search: searchOpen,
        searchQuery: searchOpen ? searchHostQuery : "",
        searchCursor: searchOpen ? searchCursor : null,
        receipts: localSubmissions.flatMap((entry) =>
          entry.taskId &&
          (entry.state === "submitting" ||
            entry.state === "accepted" ||
            entry.state === "unknown")
            ? [{ taskId: entry.taskId, operationId: entry.operationId }]
            : [],
        ),
      })
      .catch(() => undefined);
  }, [
    route,
    workbench.activeTaskId,
    bridgeGeneration,
    searchOpen,
    localSubmissions,
    historyCursor,
    searchHostQuery,
    searchCursor,
  ]);
  useEffect(() => {
    const openSearch = (event: KeyboardEvent) => {
      if (!event.metaKey && !event.ctrlKey) return;
      const key = event.key.toLowerCase();
      if (key !== "k" && key !== "n") return;
      event.preventDefault();
      if (bridgeUnavailable || modelSetupOpen || renameEditor) return;
      if (key === "k") {
        setSearchOpen(true);
      } else {
        setRoute("workbench");
        beginNewTask();
      }
    };
    window.addEventListener("keydown", openSearch);
    return () => window.removeEventListener("keydown", openSearch);
  }, [bridgeUnavailable, modelSetupOpen, renameEditor]);
  useEffect(() => {
    if (!client.available()) return;
    return client.onShortcut((detail) => {
      if (detail.id !== "settings.open") return;
      if (bridgeUnavailable || renameEditor) return;
      openSettings();
    });
  }, [bridgeUnavailable, client, renameEditor]);
  useEffect(() => {
    taskPanelOpeners.current.clear();
  }, [workbench.activeTaskId]);
  useEffect(() => {
    if (
      !snapshot.newTaskAdmission.available ||
      workbench.activeTaskId !== null ||
      workbench.draftOpen
    )
      return;
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: null,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }, [
    workbench.activeTaskId,
    snapshot.newTaskAdmission.available,
    workbench.draftOpen,
  ]);
  function focusPendingRequest() {
    const requestId = activeTask?.pendingUi?.requestId;
    if (!requestId) return;
    const target = document.getElementById(`ui-request-${requestId}`);
    target?.scrollIntoView({ block: "center", behavior: "smooth" });
    window.requestAnimationFrame(() => target?.focus());
  }
  function dismissTaskPanel(restoreFocus = true) {
    const panel = document.getElementById("task-panel");
    const focusWasInside = panel?.contains(document.activeElement) === true;
    const activeOpener = taskPanel.activeTab
      ? (taskPanelOpeners.current.get(taskPanel.activeTab.tabId) ?? null)
      : null;
    const focusTarget = sidePanelFocusReturnTarget(
      activeOpener,
      taskPanelToggle.current,
    );
    setRightPanelOpen(false);
    if (restoreFocus && focusWasInside && focusTarget)
      window.requestAnimationFrame(() => focusTarget.focus());
  }
  function closeTaskPanelTab(tabId: string) {
    const tab = taskPanel.session.tabs.find(
      (candidate) => candidate.tabId === tabId,
    );
    if (!tab) return;
    const closingLastTab = taskPanel.session.tabs.length === 1;
    const focusTarget = closingLastTab
      ? sidePanelFocusReturnTarget(
          taskPanelOpeners.current.get(tabId) ?? null,
          taskPanelToggle.current,
        )
      : null;
    taskPanelOpeners.current.delete(tabId);
    if (tab.kind === "preview") filePreviewTabs.close(tabId);
    else clearFileChanges();
    taskPanel.closeTab(tabId);
    if (closingLastTab) {
      setRightPanelOpen(false);
      if (focusTarget) window.requestAnimationFrame(() => focusTarget.focus());
      return;
    }
    window.requestAnimationFrame(() => {
      const active = document.querySelector<HTMLButtonElement>(
        '#task-panel [role="tab"][aria-selected="true"]',
      );
      (active ?? taskPanelToggle.current)?.focus({
        preventScroll: true,
      });
    });
  }
  function focusPendingFromTaskPanel() {
    const panel = document.getElementById("task-panel");
    if (panel && window.getComputedStyle(panel).position === "fixed")
      dismissTaskPanel(false);
    window.requestAnimationFrame(focusPendingRequest);
  }
  function toggleRightPanel(_opener: HTMLButtonElement) {
    if (rightPanelOpen) {
      dismissTaskPanel(false);
      return;
    }
    setRightPanelOpen(true);
    if (taskPanel.activeTab) focusTaskPanelTab(taskPanel.activeTab.tabId);
  }
  function closeDeleteConfirmation() {
    const targetId = deleteTargetId;
    setDeleteTargetId(null);
    window.requestAnimationFrame(() => {
      if (deleteOpener.current?.isConnected) {
        deleteOpener.current.focus();
        return;
      }
      const archivedRow = document.querySelector<HTMLElement>(
        `[data-archived-task-id="${CSS.escape(targetId ?? "")}"] button`,
      );
      if (archivedRow) {
        archivedRow.focus();
        return;
      }
      const taskRow = document.querySelector<HTMLElement>(
        `[data-task-id="${CSS.escape(targetId ?? "")}"]`,
      );
      if (taskRow) taskRow.focus();
      else
        document.querySelector<HTMLElement>("#settings-archived h2")?.focus();
    });
  }
  function requestTaskDeletion(task: TaskSummary) {
    deleteOpener.current =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;
    setDeleteTargetId(task.id);
  }
  function beginTaskPendingOperation(scope: string, operation: string) {
    if (taskPendingScopes.current.has(scope)) return false;
    if (!taskPendingScopes.current.begin(scope)) return false;
    setTaskPending((current) => {
      return { ...current, [scope]: operation };
    });
    return true;
  }
  function endTaskPendingOperation(scope: string) {
    taskPendingScopes.current.end(scope);
    setTaskPending((current) => {
      if (!(scope in current)) return current;
      const next = { ...current };
      delete next[scope];
      return next;
    });
  }
  function setCancelPendingForTask(taskId: string, pending: boolean) {
    if (pending) cancelPendingTasks.current.begin(taskId);
    else cancelPendingTasks.current.end(taskId);
    setCancelPending((current) => {
      const next = { ...current };
      if (pending) next[taskId] = true;
      else delete next[taskId];
      return next;
    });
  }
  async function retryViewSynchronization(
    replaceConnection = false,
    expectedGeneration?: string,
  ): Promise<void> {
    if (
      expectedGeneration &&
      expectedGeneration !== bridgeGenerationRef.current
    )
      return;
    const pending = connectionRetryRef.current;
    if (pending) {
      await pending.promise;
      if (replaceConnection && !pending.replace)
        await retryViewSynchronization(true, expectedGeneration);
      return;
    }
    const promise = (async () => {
      connectionBusyRef.current = true;
      setConnectionBusy(true);
      try {
        const current = connection.current;
        if (!current) throw new Error("Workbench connection is not available");
        await current.retry({ replaceConnection });
      } catch {
        // The connection owner publishes the final failure and readiness.
      } finally {
        connectionBusyRef.current = false;
        setConnectionBusy(false);
      }
    })();
    connectionRetryRef.current = { promise, replace: replaceConnection };
    try {
      await promise;
    } finally {
      if (connectionRetryRef.current?.promise === promise)
        connectionRetryRef.current = null;
    }
  }
  async function runAccountCommand(
    invoke: () => Promise<{
      accepted: boolean;
      errorCode: string;
    }>,
  ) {
    if (bridgeUnavailable || accountBusyRef.current) return false;
    accountBusyRef.current = true;
    setAccountBusy(true);
    try {
      const result = await invoke();
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            result.errorCode === "generation_mismatch"
              ? "account.options_updated"
              : "account.command_rejected",
            { scope: "account" },
          ),
        );
        return false;
      }
      await refreshAfterCommit("account.updated", "operation.account", {
        scope: "account",
      });
      return true;
    } catch (error) {
      if (
        await reconcileCommandTimeout(error, "operation.account", {
          scope: "account",
        })
      )
        return false;
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus("account.command_failed", { scope: "account" }),
      );
      return false;
    } finally {
      accountBusyRef.current = false;
      setAccountBusy(false);
    }
  }
  async function openAccountRecharge() {
    if (bridgeUnavailable || accountBusyRef.current) return;
    accountBusyRef.current = true;
    setAccountBusy(true);
    try {
      const result = await client.openAccountRecharge();
      if (!result.accepted) {
        setStatus(
          attentionStatus("account.recharge_open_failed", {
            scope: "account",
          }),
        );
      }
    } catch {
      setStatus(
        attentionStatus("account.recharge_open_failed", {
          scope: "account",
        }),
      );
    } finally {
      accountBusyRef.current = false;
      setAccountBusy(false);
    }
  }
  async function runExecutionCommand(
    invoke: () => Promise<{
      accepted: boolean;
      errorCode: string;
    }>,
  ) {
    if (bridgeUnavailable || executionBusyRef.current) return false;
    executionBusyRef.current = true;
    setExecutionBusy(true);
    try {
      const result = await invoke();
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus("execution.command_rejected", {
            scope: "execution",
          }),
        );
        return false;
      }
      await refreshAfterCommit("execution.updated", "operation.execution", {
        scope: "execution",
      });
      return true;
    } catch (error) {
      if (
        await reconcileCommandTimeout(error, "operation.execution", {
          scope: "execution",
        })
      )
        return false;
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus("execution.command_failed", { scope: "execution" }),
      );
      return false;
    } finally {
      executionBusyRef.current = false;
      setExecutionBusy(false);
    }
  }
  async function mutateAutomaticWorkspaceRoot(
    invoke: () => Promise<{
      outcome: "applied" | "cancelled";
    }>,
  ): Promise<"applied" | "cancelled" | false> {
    if (bridgeUnavailable) return false;
    try {
      const result = await invoke();
      if (result.outcome === "applied") await refreshCommittedView();
      return result.outcome;
    } catch {
      await refreshSnapshot().catch(() => undefined);
      return false;
    }
  }
  function publishApprovalObservations(results: ApprovalObservation[]) {
    for (const result of results) {
      const audience = { scope: "task" as const, taskId: result.taskId };
      if (result.outcome === "completed")
        setStatus(quietStatus("permission.change.completed", audience));
      else if (result.outcome === "failed" && result.reason)
        setStatus(
          attentionStatus(
            `permission.change.failure.${result.reason}`,
            audience,
          ),
        );
      else
        setStatus(attentionStatus("permission.change.not_confirmed", audience));
    }
  }
  async function setTaskApprovalMode(targetMode: ApprovalMode) {
    const task = activeTask;
    if (!task || bridgeUnavailable) return;
    const requests = approvalRequestsRef.current;
    const intent = requests.begin(task, targetMode);
    if (!intent) return;
    setApprovalRequests(requests.view());
    try {
      const result = await client.setApprovalMode(
        intent.taskId,
        targetMode,
        intent.bindingEpoch,
        intent.revision,
      );
      if (!requests.current(intent)) return;
      if (result.accepted) requests.accept(intent, result.approvalRevision);
      else {
        requests.reject(intent);
        setStatus(
          attentionStatus(`permission.change.rejection.${result.reason}`, {
            scope: "task",
            taskId: intent.taskId,
          }),
        );
      }
      setApprovalRequests(requests.view());
      await refreshSnapshot();
    } catch {
      if (!requests.current(intent)) return;
      requests.requireSync(intent);
      setApprovalRequests(requests.view());
      // A lost response is not a rejection. Refresh only; never replay the intent.
      await refreshSnapshot().catch(() => undefined);
    }
  }
  async function refreshTaskApprovalMode() {
    const taskId = activeTask?.id;
    if (!taskId || bridgeUnavailable) return;
    const intent = approvalRequestsRef.current.view()[taskId]?.intent;
    try {
      await refreshSnapshot();
      const observed = latestSnapshotRef.current?.tasks.find(
        (task) => task.id === taskId,
      );
      if (intent && observed && !observed.approvalChange) {
        const result = approvalRequestsRef.current.unconfirmed(intent);
        if (result) publishApprovalObservations([result]);
        setApprovalRequests(approvalRequestsRef.current.view());
      }
    } catch {
      setStatus(
        attentionStatus("permission.change.sync_required", {
          scope: "task",
          taskId,
        }),
      );
    }
  }
  async function selectModelForTask(selectionId: string) {
    const task = activeTask;
    const option = taskModelOptions.find(
      (option) => option.selectionId === selectionId,
    );
    if (!task || !option || bridgeUnavailable) return;
    const scope = `task:${task.id}`;
    if (!beginTaskPendingOperation(scope, "model")) return;
    try {
      const result = await client.selectTaskModel(
        task.id,
        task.modelIntent?.selectionRevision ?? "0",
        option.modelRef,
        option.sourceGeneration,
        option.catalogGeneration,
      );
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason), {
            scope: "task",
            taskId: task.id,
          }),
        );
        return;
      }
      await refreshAfterCommit("task.model.updated", "operation.account", {
        scope: "task",
        taskId: task.id,
      });
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus(
          "mutation.reason.task_unavailable",
          {
            scope: "task",
            taskId: task.id,
          },
          { diagnostic: errorText(error) },
        ),
      );
    } finally {
      endTaskPendingOperation(scope);
    }
  }
  async function selectMetaskModel(modelId: string) {
    const provider = metaskProvider;
    if (!provider) return;
    const configured = await runExecutionCommand(() =>
      client.configureMetaskSelection({
        sourceId: "metask",
        modelId,
        expectedMetaskSelectionRevision:
          snapshot.models.metaskSelectionRevision,
        expectedCatalogGeneration: provider.catalogGeneration,
      }),
    );
    if (!configured) return;
    // The connection installs the committed view before resolving its refresh.
    // Use that view for the second CAS through the same serialized read owner.
    const current = latestSnapshotRef.current;
    if (!current) return;
    const currentProvider = current.models.providers.find(
      (candidate) => candidate.id === "metask",
    );
    const currentSelection = current.models.metaskSelection;
    if (
      !currentProvider ||
      !currentSelection ||
      currentSelection.modelId !== modelId
    )
      return;
    await runExecutionCommand(() =>
      client.selectModelsDefault({
        sourceId: currentSelection.sourceId,
        modelId,
        expectedSelectionRevision: current.models.selectionRevision,
        expectedSourceGeneration: currentProvider.sourceGeneration,
        expectedCatalogGeneration: currentProvider.catalogGeneration,
      }),
    );
  }
  async function cancelAccountOperation() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      accountCancelBusyRef.current ||
      !snapshot.account.canCancel
    )
      return;
    accountCancelBusyRef.current = true;
    setAccountCancelBusy(true);
    try {
      const result = await client.cancelAccountOperation();
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus(quietStatus("account.cancel_rejected", { scope: "account" }));
        return;
      }
      await refreshAfterCommit(
        "account.cancelled",
        "operation.account_cancel",
        { scope: "account" },
      );
    } catch (error) {
      if (
        await reconcileCommandTimeout(error, "operation.account_cancel", {
          scope: "account",
        })
      )
        return;
      await refreshSnapshot().catch(() => undefined);
      setStatus(attentionStatus("account.cancel_failed", { scope: "account" }));
    } finally {
      accountCancelBusyRef.current = false;
      setAccountCancelBusy(false);
    }
  }
  async function chooseWorkspaceForDraft() {
    if (workbenchMutationDisabled || workspaceBusyRef.current) return null;
    workspaceBusyRef.current = true;
    setWorkspaceBusy(true);
    try {
      const outcome = await chooseWorkspaceAndMigrateDraft({
        choose: () => client.chooseWorkspace(),
        refresh: refreshSnapshot,
        migratableDraftId:
          newTaskDraftId === unscopedNewTaskDraftId ? newTaskDraftId : null,
        moveDraft: (sourceId, targetId) =>
          newTaskDrafts.moveDraft(sourceId, targetId),
      });
      if (outcome.kind === "selected") {
        const { result } = outcome;
        dispatchWorkbench({
          type: "task.draft.opened",
          workspaceId: result.workspaceId,
        });
        setStatus(
          quietStatus("workspace.grant_confirmed", {
            scope: "workspace",
            workspaceId: result.workspaceId,
          }),
        );
        window.requestAnimationFrame(() => composer.current?.focus());
        return result;
      }
      setStatus(
        quietStatus("workspace.selection_cancelled", {
          scope: "workspace",
          workspaceId: workbench.draftWorkspaceId,
        }),
      );
      window.requestAnimationFrame(() => composer.current?.focus());
      return null;
    } catch (error) {
      setStatus(
        attentionStatus(
          "workspace.selection_failed",
          { scope: "workspace", workspaceId: null },
          {
            diagnostic: errorText(error),
          },
        ),
      );
      window.requestAnimationFrame(() => composer.current?.focus());
      return null;
    } finally {
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
    }
  }
  function setDraftWorkspaceById(workspaceId: string) {
    if (workbenchMutationDisabled) return;
    if (workspaceId === automaticWorkspaceOptionId) {
      if (newTaskDraftId && newTaskDraftId !== unscopedNewTaskDraftId)
        newTaskDrafts.moveDraft(newTaskDraftId, unscopedNewTaskDraftId);
      dispatchWorkbench({ type: "task.draft.opened", workspaceId: null });
      window.requestAnimationFrame(() => composer.current?.focus());
      return;
    }
    const workspace = snapshot.workspaces.find(
      (candidate) => candidate.id === workspaceId,
    );
    if (
      !workspace ||
      workspace.kind !== "manual" ||
      workspace.authorization !== "available"
    ) {
      setStatus(
        attentionStatus("workspace.selection_unavailable", {
          scope: "workspace",
          workspaceId: null,
        }),
      );
      return;
    }
    if (newTaskDraftId === unscopedNewTaskDraftId)
      newTaskDrafts.moveDraft(newTaskDraftId, workspace.id);
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: workspace.id,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }
  function beginNewTask() {
    pendingTaskSelection.current = null;
    newTaskSubmissionInstance.current += 1;
    // Retire lookup ownership; in-flight sessions still finish their own sends.
    const prefix = `${bridgeGenerationRef.current}:new-task:`;
    for (const key of submissionSessions.current.keys())
      if (key.startsWith(prefix)) submissionSessions.current.delete(key);
    setNewTaskApprovalOverride(null);
    setNewTaskRequestedModel(null);
    setRoute("workbench");
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: null,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }
  function openTask(taskId: string) {
    pendingTaskSelection.current = null;
    setRoute("workbench");
    dispatchWorkbench({ type: "task.selected", taskId });
  }
  function openSettings(target: SettingsFocusTarget = "title") {
    if (modelSetupOpen) {
      modelSetupReturnFocus.current = null;
      finishModelSetupIntroduction();
    }
    if (!settingsOpen) {
      settingsRestoreFocus.current = modelSetupOpen
        ? composer.current
        : document.activeElement instanceof HTMLElement
          ? document.activeElement
          : null;
    }
    setSettingsFocus(target);
    setSettingsOpen(true);
  }
  function closeSettings() {
    setSettingsOpen(false);
    window.requestAnimationFrame(() => {
      settingsRestoreFocus.current?.focus();
      settingsRestoreFocus.current = null;
    });
  }
  async function submitRun() {
    if (
      !canSubmit ||
      attachmentBusyRef.current ||
      attachmentRemoval.current.busy
    )
      return;
    const submitted = composerDraftRef.current;
    const input = composerDraftToRunInput(submitted);
    if (!input) return;
    const scope = composerDraftScope;
    const generation = bridgeGenerationRef.current;
    const operationId = newComposerOperationId();
    const draftId = newTaskDraftId;
    const taskId = !newTaskDraftActive ? (activeTask?.id ?? null) : null;
    const key = `${generation}:${scope}`;
    const audience = attachmentAudience.current;
    let session = submissionSessions.current.get(key);
    if (!session) {
      session = new TaskSubmissionSession({
        taskId,
        current: () => bridgeGenerationRef.current === generation,
        send: (id, target, value) => client.sendInput(id, target, value),
        stop: (target) => client.stopTask(target),
        create: () =>
          client.createTask(
            composerWorkspace
              ? {
                  kind: "manual",
                  workspaceId: composerWorkspace.id,
                  expectedWorkspaceEpoch: composerWorkspace.epoch,
                }
              : { kind: "automatic" },
            snapshot.newTaskAdmission.activeGeneration,
            snapshot.newTaskAdmission.activeSelectionRevision,
            newTaskModelState.intent,
            input.kind === "skill" ? input.catalogRevision : null,
            input.kind === "skill" ? input.selectionRevision : null,
            newTaskApprovalMode,
          ),
        onCreated: (id) => {
          pendingTaskDraftRetention.current.add(id);
          if (
            composerDraftScopeRef.current !== scope ||
            attachmentAudience.current !== audience ||
            submissionSessions.current.get(key) !== session
          )
            return;
          setNewTaskApprovalOverride(null);
          setNewTaskRequestedModel(null);
          pendingTaskSelection.current = id;
          if (draftId)
            pendingTaskDraftSource.current = {
              taskId: id,
              draftId,
              generation,
            };
        },
      });
      submissionSessions.current.set(key, session);
    }
    // The submission owns this draft now. Responses never clear a later draft.
    if (draftId) newTaskDrafts.clearDraft(draftId);
    else if (taskId) taskDrafts.clearDraft(taskId);
    composerDraftRef.current = emptyComposerDraft();
    const anchor = localReadingAnchor(
      latestSnapshotRef.current?.tasks.find((task) => task.id === taskId) ??
        null,
      ++localSubmissionSequence.current,
    );
    setLocalSubmissions((entries) => [
      ...entries.filter(
        (entry) =>
          entry.scope !== scope ||
          entry.state === "submitting" ||
          entry.state === "accepted" ||
          entry.state === "unknown",
      ),
      {
        operationId,
        taskId,
        scope,
        generation,
        draft: submitted,
        anchor,
        state: "submitting",
      },
    ]);
    const result = await session.submit(
      operationId,
      input,
      (target) => {
        setLocalSubmissions((entries) =>
          entries.map((entry) =>
            entry.operationId === operationId
              ? { ...entry, taskId: target }
              : entry,
          ),
        );
      },
      () => {
        setLocalSubmissions((entries) =>
          entries.map((entry) =>
            entry.operationId === operationId
              ? { ...entry, state: "cancelled" }
              : entry,
          ),
        );
      },
    );
    if (bridgeGenerationRef.current !== generation) return;
    const state =
      result.kind === "accepted"
        ? "accepted"
        : result.kind === "cancelled"
          ? "cancelled"
          : result.kind === "unknown"
            ? "unknown"
            : "failed";
    setLocalSubmissions((entries) =>
      entries.map((entry) =>
        entry.operationId === operationId
          ? {
              ...entry,
              state,
              reason: "reason" in result ? result.reason : undefined,
              blockingTaskId:
                "blockingTaskId" in result ? result.blockingTaskId : undefined,
            }
          : entry,
      ),
    );
    await refreshSnapshot().catch(() => undefined);
  }
  async function addAttachments(
    input?:
      | {
          paths: string[];
        }
      | {
          files: File[];
        },
  ) {
    if (attachmentBusyRef.current || attachmentRemoval.current.busy) {
      setAttachmentError("input_busy");
      return;
    }
    if (
      bridgeUnavailable ||
      !snapshot.capabilities.attachments.enabled ||
      !taskCanCompose ||
      composerDraftRef.current.kind === "skill"
    ) {
      setAttachmentError("input_unavailable");
      return;
    }
    const requestedScope = composerDraftScopeRef.current;
    const requestedGeneration = bridgeGenerationRef.current;
    const target = newTaskDraftActive ? newTaskDrafts : taskDrafts;
    const targetId = newTaskDraftActive
      ? newTaskDraftId
      : (activeTask?.id ?? null);
    if (!target.currentDraft(targetId)) return;
    let add: AttachmentAddOperation;
    try {
      add = client.createAttachmentAdd(async () => {
        if (requestedGeneration !== bridgeGenerationRef.current) return;
        taskDrafts.invalidateAttachments();
        newTaskDrafts.invalidateAttachments();
        await retryViewSynchronization(true, requestedGeneration);
      });
    } catch (error) {
      setAttachmentError(errorText(error));
      return;
    }
    const operation = { cancelled: false, add };
    attachmentOperation.current = operation;
    attachmentBusyRef.current = true;
    setAttachmentView("adding");
    setAttachmentError(null);
    const currentOperation = () =>
      attachmentOperation.current === operation &&
      composerDraftScopeRef.current === requestedScope &&
      bridgeGenerationRef.current === requestedGeneration &&
      !operation.cancelled;
    try {
      const source = input
        ? "files" in input
          ? { kind: "file_bytes" as const, files: input.files }
          : { kind: "native_paths" as const, paths: input.paths }
        : { kind: "picker" as const };
      const result = await add.run(source, (view) => {
        if (attachmentOperation.current === operation) setAttachmentView(view);
      });
      if (result.status === "cancelled") return;
      if (result.status === "rejected") {
        if (
          attachmentOperation.current === operation &&
          composerDraftScopeRef.current === requestedScope &&
          (result.reason === "cleanup_failed" || !operation.cancelled)
        )
          setAttachmentError(result.reason);
        return;
      }
      const current = target.currentDraft(targetId);
      if (!currentOperation() || !current || current.kind === "skill") {
        const cleanup = await add.cancel();
        if (
          cleanup.status === "cleanup_failed" &&
          composerDraftScopeRef.current === requestedScope
        )
          setAttachmentError("cleanup_failed");
        return;
      }
      const next: ComposerDraft = {
        kind: "multimodal",
        text: current.text,
        attachments: [
          ...(current.kind === "multimodal" ? current.attachments : []),
          ...result.attachments,
        ],
      };
      const handedOff = add.handoff(() => {
        if (!currentOperation() || !target.commitDraft(targetId, next))
          return false;
        composerDraftRef.current = next;
        return true;
      });
      if (!handedOff) {
        const cleanup = await add.cancel();
        if (
          cleanup.status === "cleanup_failed" &&
          composerDraftScopeRef.current === requestedScope
        )
          setAttachmentError("cleanup_failed");
      }
    } catch (error) {
      if (!(error instanceof AttachmentCleanupError) && currentOperation())
        setAttachmentError(errorText(error));
    } finally {
      if (attachmentOperation.current === operation) {
        attachmentOperation.current = null;
        attachmentBusyRef.current = false;
        setAttachmentView(null);
        setAttachmentError((reason) =>
          reason === "input_busy" ? null : reason,
        );
      }
    }
  }
  droppedAttachmentHandlerRef.current = (paths) => {
    if (
      paths.length === 0 ||
      route !== "workbench" ||
      settingsOpen ||
      searchOpen
    )
      return;
    void addAttachments({ paths });
  };
  useEffect(() => {
    if (!client.available()) return;
    return client.onFileDrop((paths) => {
      droppedAttachmentHandlerRef.current(paths);
    });
  }, [bridgeGeneration]);
  async function removeAttachment(token: string) {
    if (
      attachmentBusyRef.current ||
      bridgeUnavailable ||
      !taskCanCompose ||
      taskMutationDisabled
    )
      return;
    const target = newTaskDraftActive ? newTaskDrafts : taskDrafts;
    const targetId = newTaskDraftActive
      ? newTaskDraftId
      : (activeTask?.id ?? null);
    const requestedAudience = attachmentAudience.current;
    await attachmentRemoval.current.remove({
      generation: bridgeGenerationRef.current,
      targetId,
      token,
      target: {
        currentDraft: target.currentDraft,
        commitDraft: (id, next) => {
          if (!target.commitDraft(id, next)) return false;
          composerDraftRef.current = next;
          setAttachmentError(null);
          return true;
        },
      },
      release: (value) => client.releaseAttachment(value),
      unconfirmed: () => {
        if (attachmentAudience.current === requestedAudience)
          setAttachmentError("release_unconfirmed");
      },
      recover: async (generation) => {
        if (generation !== bridgeGenerationRef.current) return;
        taskDrafts.invalidateAttachments();
        newTaskDrafts.invalidateAttachments();
        await retryViewSynchronization(true, generation);
      },
    });
  }
  async function cancelRun() {
    if (bridgeUnavailable) return;
    const taskId = !newTaskDraftActive ? activeTask?.id : undefined;
    const session = submissionSessions.current.get(
      `${bridgeGenerationRef.current}:${composerDraftScope}`,
    );
    if (!taskId && !session) return;
    if (taskId && cancelPendingTasks.current.has(taskId)) return;
    if (taskId) setCancelPendingForTask(taskId, true);
    try {
      try {
        if (session) await session.stop();
        else if (taskId) await client.stopTask(taskId);
      } catch (error) {
        const audience = taskId
          ? { scope: "task" as const, taskId }
          : { scope: "workspace" as const, workspaceId: composerWorkspaceId };
        if (
          await reconcileCommandTimeout(error, "operation.run_stop", audience)
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus("run.stop_failed", audience, {
            diagnostic: errorText(error),
          }),
        );
        return;
      }
      if (taskId)
        await refreshAfterCommit("run.stop_requested", "operation.run_stop", {
          scope: "task",
          taskId,
        });
      else await refreshSnapshot().catch(() => undefined);
    } finally {
      if (taskId) setCancelPendingForTask(taskId, false);
    }
  }
  async function compactTask() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeTask ||
      activeTask.lifecycle !== "open" ||
      !activeTask.continuationAvailable ||
      activeTask.archived ||
      activeTask.activeOperation !== null ||
      activeTask.runs.length === 0
    )
      return;
    const taskId = activeTask.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "compact")) return;
    try {
      try {
        const result = await client.compact(taskId, activeTask.binding.epoch);
        if (!result.accepted) {
          await refreshSnapshot().catch(() => undefined);
          setStatus(
            attentionStatus(mutationReasonMessageId(result.reason), {
              scope: "task",
              taskId,
            }),
          );
          return;
        }
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.compact", {
            scope: "task",
            taskId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "compact.start_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      await refreshAfterCommit("compact.started", "operation.compact", {
        scope: "task",
        taskId,
      });
    } finally {
      endTaskPendingOperation(scope);
    }
  }
  function composerDraftFromRunInput(
    input: RunInputView,
  ): ComposerDraft | null {
    if (input.redacted) return null;
    if (input.kind === "text") return { kind: "text", text: input.text };
    if (input.kind === "multimodal")
      return {
        kind: "text",
        text: input.text ?? "",
        attachmentsReloadRequired: true,
      };
    const descriptor = skillCatalog.skills.find(
      (skill) => skill.skillId === input.skillId,
    );
    if (
      !descriptor ||
      !descriptor.enabled ||
      skillCatalog.revision !== input.catalogRevision ||
      skillCatalog.selectionRevision === null
    )
      return null;
    return {
      kind: "skill",
      skillId: input.skillId,
      invocationName: input.invocationName,
      displayName: input.displayName,
      catalogRevision: input.catalogRevision,
      selectionRevision: skillCatalog.selectionRevision,
      argumentNames: descriptor.argumentNames,
      argumentValues: input.argumentValues,
      maxValues: Math.min(descriptor.maxValues, maxSkillArguments),
    };
  }
  async function refreshComposerSkillCatalog() {
    if (
      skillCatalogBusy ||
      bridgeUnavailable ||
      !composerWorkspace ||
      !composerWorkspaceId
    )
      return;
    setSkillCatalogBusy(true);
    try {
      const refreshTarget = skillCatalogRefreshTarget(
        Boolean(activeTask) && !newTaskDraftActive,
        composerWorkspace.skillCatalog,
      );
      const audience: StatusAudience =
        refreshTarget === "workspace"
          ? { scope: "workspace", workspaceId: composerWorkspaceId }
          : { scope: "task", taskId: activeTask!.id };
      const result =
        refreshTarget === "workspace"
          ? await client.refreshWorkspaceSkillCatalog(
              composerWorkspaceId,
              composerWorkspace.epoch,
            )
          : await client.refreshTaskSkillCatalog(
              activeTask!.id,
              activeTask!.binding.epoch,
            );
      if (!result.accepted) {
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason!), audience),
        );
        return;
      }
      await refreshAfterCommit(
        "slash.catalog_refresh_started",
        "operation.skill_catalog_refresh",
        audience,
      );
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus(
          "slash.catalog_refresh_failed",
          skillCatalogRefreshTarget(
            Boolean(activeTask) && !newTaskDraftActive,
            composerWorkspace.skillCatalog,
          ) === "task"
            ? { scope: "task", taskId: activeTask!.id }
            : { scope: "workspace", workspaceId: composerWorkspaceId },
          { diagnostic: errorText(error) },
        ),
      );
    } finally {
      setSkillCatalogBusy(false);
    }
  }
  async function refreshSkillsPageCatalog(target: SkillRefreshTarget) {
    const key = skillRefreshKey(target);
    if (skillRefreshPending.current.has(key) || bridgeUnavailable) return;
    skillRefreshPending.current.add(key);
    setSkillRefreshRequests((requests) => ({
      ...requests,
      [key]: { busy: true, error: null },
    }));
    let failure: string | null = null;
    try {
      const result =
        target.scope === "personal"
          ? await client.refreshSkillCatalog()
          : await client.refreshWorkspaceSkillCatalog(
              target.workspaceId,
              target.expectedWorkspaceEpoch,
            );
      if (!result.accepted) failure = t("skills.catalog_refresh_failed");
      await refreshSnapshot();
    } catch {
      await refreshSnapshot().catch(() => undefined);
      failure = t("skills.catalog_refresh_failed");
    } finally {
      skillRefreshPending.current.delete(key);
      setSkillRefreshRequests((requests) => ({
        ...requests,
        [key]: { busy: false, error: failure },
      }));
    }
  }
  async function commitSkillSourceMutation(
    mutation: () => Promise<
      import("../bridge/contracts.ts").SkillSourceSettingsResult
    >,
  ) {
    // This window owns the latch: navigating away does not cancel a Host write.
    if (sourceMutationPending.current || bridgeUnavailable) return;
    sourceMutationPending.current = true;
    setSourceMutationBusy(true);
    setSourceMutationError(null);
    let applied = false;
    try {
      const result = await mutation();
      applied = result.applied;
      if (!result.applied)
        setSourceMutationError(t(`skills.sources.failure.${result.reason}`));
      // Failed commands can also change health and recovery capabilities.
      await refreshSnapshot();
    } catch {
      await refreshSnapshot().catch(() => undefined);
      setSourceMutationError(
        t(applied ? "skills.sources.saved_resync" : "skills.sources.uncertain"),
      );
    } finally {
      sourceMutationPending.current = false;
      setSourceMutationBusy(false);
    }
  }
  async function commitSkillMutation(
    mutation: () => Promise<SkillMutationResult>,
  ): Promise<SkillMutationResult> {
    const result = await mutation();
    if (result.accepted) await refreshCommittedView();
    return result;
  }
  async function setSkillEnabled(
    target:
      | {
          scope: "personal";
        }
      | {
          scope: "project";
          workspaceId: string;
          expectedWorkspaceEpoch: string;
        },
    skillPolicyKey: string,
    state: "inherit" | "enabled" | "disabled",
    expectedCatalogRevision: string,
    expectedSelectionRevision: string,
  ): Promise<SkillEnablementResult> {
    const result = await client.setSkillEnabled(
      target,
      skillPolicyKey,
      state,
      expectedCatalogRevision,
      expectedSelectionRevision,
    );
    await refreshCommittedView();
    return result;
  }
  async function commitMcpMutation(
    mutation: () => Promise<McpMutationResult>,
  ): Promise<McpMutationResult> {
    try {
      const result = await mutation();
      if (result.outcome !== "unchanged") await refreshCommittedView();
      return result;
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      throw error;
    }
  }
  async function refreshMcpCatalog(): Promise<McpRefreshResult> {
    try {
      const result = await client.refreshMcpCatalog();
      await refreshCommittedView();
      return result;
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      throw error;
    }
  }
  async function applyMcpConfiguration(): Promise<McpConfigurationApplyResult> {
    try {
      const result = await client.applyMcpConfiguration();
      await refreshCommittedView();
      return result;
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      throw error;
    }
  }
  async function testMcpConnection(
    expectedGeneration: string,
    serverId: string,
  ): Promise<McpConnectionTestResult> {
    try {
      const result = await client.testMcpConnection(
        expectedGeneration,
        serverId,
      );
      await refreshCommittedView();
      return result;
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      throw error;
    }
  }
  function runSlashCommand(command: SlashCommandName) {
    switch (command) {
      case "new":
        beginNewTask();
        return;
      case "compact":
        void compactTask();
        return;
    }
  }
  function closeRenameDialog() {
    if (
      renameEditor &&
      !taskPendingScopes.current.has(`task:${renameEditor.taskId}`)
    ) {
      setRenameEditor(null);
    }
  }
  async function renameTask() {
    const editor = renameEditor;
    const task = editor
      ? latestSnapshotRef.current?.taskIndex.find(
          (task) => task.id === editor.taskId,
        )
      : null;
    if (
      !editor ||
      !task ||
      task.archived ||
      task.historyReadOnly ||
      task.deletionStatus === "deleting" ||
      workbenchMutationDisabled ||
      `task:${task.id}` in taskPending ||
      renameComposing.current ||
      !editor.draft.trim()
    )
      return;
    const taskId = task.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "rename")) return;
    try {
      try {
        await client.renameTask(taskId, editor.draft.trim());
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.task_rename", {
            scope: "task",
            taskId,
          })
        ) {
          const confirmed =
            latestSnapshotRef.current?.taskIndex.find(
              (entry) => entry.id === taskId,
            )?.title === editor.draft.trim();
          setRenameEditor((current) =>
            current !== editor
              ? current
              : confirmed
                ? null
                : { ...editor, message: "task.rename_unconfirmed" },
          );
          return;
        }
        await refreshSnapshot().catch(() => undefined);
        setRenameEditor((current) =>
          current === editor
            ? { ...editor, message: "task.rename_failed" }
            : current,
        );
        return;
      }
      setRenameEditor((current) => (current === editor ? null : current));
      await refreshAfterCommit("task.renamed", "operation.task_rename", {
        scope: "task",
        taskId,
      });
    } finally {
      endTaskPendingOperation(scope);
    }
  }
  function publishArchiveResult(taskId: string, archived: boolean) {
    const task = latestSnapshotRef.current?.taskIndex.find(
      (entry) => entry.id === taskId,
    );
    if (!task || task.archived !== archived) return;
    if (archived)
      setArchiveNotice({
        id: ++archiveNoticeId.current,
        taskId,
        kind: "archived",
      });
    else
      setArchiveNotice((current) =>
        current?.taskId === taskId ? null : current,
      );
  }
  async function setArchived(
    archived: boolean,
    task: TaskSummary | TaskView | null = activeTask,
  ) {
    if (
      !task ||
      workbenchMutationDisabled ||
      `task:${task.id}` in taskPending ||
      task.activeOperation !== null
    )
      return;
    const taskId = task.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "archive")) return;
    setTaskArchiveErrors((current) => ({ ...current, [taskId]: "" }));
    try {
      try {
        await client.setTaskArchived(task.id, archived);
      } catch (error) {
        if (
          await reconcileCommandTimeout(
            error,
            archived ? "operation.task_archive" : "operation.task_restore",
            { scope: "task", taskId },
          )
        ) {
          publishArchiveResult(taskId, archived);
          return;
        }
        if (archived)
          setArchiveNotice({
            id: ++archiveNoticeId.current,
            taskId,
            kind: "failed",
          });
        await refreshSnapshot().catch(() => undefined);
        setTaskArchiveErrors((current) => ({
          ...current,
          [taskId]: t(archived ? "task.archive_failed" : "task.restore_failed"),
        }));
        setStatus(
          attentionStatus(
            archived ? "task.archive_failed" : "task.restore_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      await refreshAfterCommit(
        archived ? "task.archived_status" : "task.restored",
        archived ? "operation.task_archive" : "operation.task_restore",
        { scope: "task", taskId },
      );
      publishArchiveResult(taskId, archived);
    } finally {
      endTaskPendingOperation(scope);
    }
  }
  async function deleteTask(
    task: TaskSummary | TaskView | null = deleteTarget,
  ) {
    if (
      !task ||
      workbenchMutationDisabled ||
      `task:${task.id}` in taskPending ||
      task.deletionStatus === "deleting" ||
      (task.lifecycle === "closing" && task.deletionStatus !== "failed")
    )
      return;
    const taskId = task.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "delete")) return;
    try {
      try {
        await client.deleteTask(task.id);
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.task_delete", {
            scope: "task",
            taskId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "task.delete_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      setDeleteTargetId(null);
      await refreshAfterCommit(
        "task.delete_requested",
        "operation.task_delete",
        {
          scope: "task",
          taskId,
        },
      );
    } finally {
      endTaskPendingOperation(scope);
    }
  }
  function selectSearchResult(result: SearchResult) {
    openTask(result.taskId);
    setSearchOpen(false);
    setSearchQuery("");
  }
  function handleTaskAction(task: TaskSummary, action: TaskMenuAction) {
    if (action === "rename") {
      renameComposing.current = false;
      openTask(task.id);
      setRenameEditor({ taskId: task.id, draft: task.title, message: null });
      return;
    }
    if (action === "archive") {
      void setArchived(!task.archived, task);
      return;
    }
    requestTaskDeletion(task);
  }
  async function respondUi(payload: UiResponsePayload) {
    const pending = activeTask?.pendingUi;
    if (viewSyncFailed || !bridgeReady || !activeTask || !pending) return;
    const identity = uiRequestIdentity(activeTask.id, pending);
    const taskId = activeTask.id;
    if (!beginUiResponse(identity)) return;
    try {
      await client.respondUi(
        activeTask.id,
        pending.runId,
        pending.requestId,
        payload,
      );
    } catch (error) {
      failUiResponse(identity);
      if (
        await reconcileCommandTimeout(error, "operation.ui_response", {
          scope: "task",
          taskId,
        })
      )
        return;
      setStatus(
        attentionStatus(
          "approval.response_failed",
          { scope: "task", taskId },
          { diagnostic: errorText(error) },
        ),
      );
      await refreshSnapshot().catch(() => undefined);
      return;
    }
    acceptUiResponse(identity);
    await refreshAfterCommit(
      "approval.response_sent",
      "operation.ui_response",
      { scope: "task", taskId },
    );
  }
  const outputEditAudience = attachmentAudience.current;
  function prepareOutputEdit(
    taskId: string,
    runId: string,
    outputId: string,
  ): OutputEditResult {
    const current = outputEditContext.current;
    if (
      current.audience !== outputEditAudience ||
      !current.allowed ||
      current.task?.id !== taskId ||
      composerDraftScopeRef.current !== `task:${taskId}`
    )
      return "edit_unavailable";
    const output = current.task.runs
      .find((run) => run.id === runId)
      ?.outputs.find((record) => record.id === outputId);
    if (!output || output.redacted) return "edit_unavailable";
    const draft = taskDrafts.currentDraft(taskId);
    if (!draft) return "edit_unavailable";
    const prepared = prepareOutputEditDraft(
      draft,
      t("outputs.edit_reference", { path: JSON.stringify(output.displayPath) }),
    );
    if (prepared.kind === "preserved") return "edit_draft_busy";
    if (prepared.kind === "too_long") return "edit_too_long";
    if (!taskDrafts.commitDraft(taskId, prepared.draft))
      return "edit_unavailable";
    composerDraftRef.current = prepared.draft;
    window.requestAnimationFrame(() => {
      const latest = outputEditContext.current;
      if (
        latest.audience === outputEditAudience &&
        latest.allowed &&
        latest.task?.id === taskId
      ) {
        const input = composer.current;
        input?.focus();
        input?.setSelectionRange(input.value.length, input.value.length);
      }
    });
    return "edit_prepared";
  }
  function prepareRetry(input: RunInputView) {
    if (!activeTask || !taskCanCompose) return;
    if (input.kind === "skill") {
      if (composerDraftHasContent(composerDraft)) {
        setStatus(
          quietStatus("run.draft_preserved", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
      } else {
        const reusable = composerDraftFromRunInput(input);
        if (reusable) {
          updateComposerDraft(reusable);
          setStatus(
            quietStatus("run.retry_prepared", {
              scope: "task",
              taskId: activeTask.id,
            }),
          );
        } else {
          setStatus(
            attentionStatus("mutation.reason.stale_catalog", {
              scope: "task",
              taskId: activeTask.id,
            }),
          );
        }
      }
      return;
    }
    if (input.kind === "multimodal") {
      if (composerDraftHasContent(composerDraft)) {
        setStatus(
          quietStatus("run.draft_preserved", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
      } else {
        const reusable = composerDraftFromRunInput(input);
        if (reusable) updateComposerDraft(reusable);
        setStatus(
          quietStatus("run.retry_prepared", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
      }
      window.requestAnimationFrame(() => composer.current?.focus());
      return;
    }
    const prepared = prepareRetryDraft(composerDraft, input.text);
    switch (prepared.kind) {
      case "prepared":
        updateComposerDraft(prepared.draft);
        setStatus(
          quietStatus("run.retry_prepared", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
        break;
      case "preserved":
        setStatus(
          quietStatus("run.draft_preserved", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
        break;
      case "too_long":
        setStatus(
          attentionStatus("run.retry_too_long", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
        break;
    }
    window.requestAnimationFrame(() => composer.current?.focus());
  }
  async function refreshAfterCommit(
    success: MessageId,
    operation: MessageId,
    audience: StatusAudience,
  ) {
    try {
      await refreshSnapshot();
      setStatus(quietStatus(success, audience));
    } catch (error) {
      setStatus(
        attentionStatus("view.refresh_after_commit_failed", audience, {
          values: { operation: t(operation) },
          diagnostic: errorText(error),
        }),
      );
    }
  }
  async function reconcileCommandTimeout(
    error: unknown,
    operation: MessageId,
    audience: StatusAudience,
  ) {
    if (!(error instanceof BridgeCommandTimeoutError)) return false;
    try {
      await refreshSnapshot();
      setStatus(
        quietStatus("command.timeout_reconciled", audience, {
          values: { operation: t(operation) },
        }),
      );
    } catch {
      setStatus(
        attentionStatus("command.timeout_sync_failed", audience, {
          values: { operation: t(operation) },
        }),
      );
    }
    return true;
  }
  const connectionShellStatus = statuses.connection;
  const connectionFailure = connectionFailurePresentation(
    connectionShellStatus,
  );
  const connectionRetryable = connectionFailure.retryable;
  if (rootRenderBlockReason === "bootstrap_failed")
    return (
      <ConnectionFailureScreen
        titleId={connectionFailure.titleId}
        helpId={connectionFailure.helpId}
        sourceId={connectionShellStatus?.sourceId}
        diagnostic={connectionShellStatus?.diagnostic}
        retryable={connectionRetryable}
        retrying={connectionBusy}
        onRetry={() => void retryViewSynchronization()}
      />
    );
  const currentTaskState = activeTask ? taskDisplayState(activeTask) : null;
  const currentTaskStatus = !currentTaskState
    ? t(newTaskDraftActive ? "task.new" : "task.open")
    : currentTaskState.kind === "permission_review"
      ? t("task.phase.reviewing")
      : currentTaskState.kind === "phase"
        ? t(`task.phase.${currentTaskState.value}`)
        : currentTaskState.kind === "compact_phase"
          ? t(`compact.phase.${currentTaskState.value}`)
          : currentTaskState.kind === "recovery"
            ? t("run.preparing")
            : currentTaskState.kind === "lifecycle"
              ? t(`task.lifecycle.${currentTaskState.value}`)
              : currentTaskState.kind === "archived"
                ? t("task.archived")
                : currentTaskState.kind === "outcome"
                  ? t(`outcome.${currentTaskState.value}`)
                  : t("task.ready");
  const activeTaskTitle = activeTask
    ? activeTask.title || t("task.item", { id: activeTask.id })
    : selectedTaskSummary?.title ||
      t(newTaskDraftActive ? "task.new" : "task.open");
  const slashCommands: SlashCommandState[] = resolveSlashCommandStates({
    newTaskDraftActive,
    bridgeUnavailable,
    taskMutationDisabled,
    task: activeTask
      ? {
          lifecycleOpen: activeTask.lifecycle === "open",
          continuationAvailable: activeTask.continuationAvailable,
          archived: activeTask.archived,
          activeOperation: taskOperationInFlight,
          hasFinalizedRun: activeTask.runs.length > 0,
        }
      : null,
  });
  const commandBarStatus = selectCommandBarStatus(statuses, {
    route,
    settingsOpen,
    workspaceId: composerWorkspaceId ?? null,
    taskId: activeTask?.id ?? null,
  });
  const visibleSubmissions = localSubmissions.filter(
    (entry) =>
      (newTaskDraftActive
        ? entry.scope === composerDraftScope
        : entry.taskId === workbench.activeTaskId) &&
      !taskHasSubmission(activeTask ?? undefined, entry.operationId),
  );
  const localReadingInputs = visibleSubmissions.map((entry) => ({
    operationId: entry.operationId,
    anchor: entry.anchor,
    content: (
      <UserInputMessage
        className="local-input-submissions"
        operationId={entry.operationId}
        key={entry.operationId}
        notice={
          <>
            <p className="projection-note">
              {t(
                entry.state === "submitting"
                  ? "input.submitting"
                  : entry.state === "accepted"
                    ? "input.waiting"
                    : entry.state === "unknown"
                      ? "input.unknown"
                      : entry.state === "cancelled"
                        ? "input.cancelled"
                        : "input.unexecuted",
              )}
            </p>
            {entry.reason && (
              <p className="projection-note">
                {t(mutationReasonMessageId(entry.reason), {
                  task:
                    snapshot.taskIndex.find(
                      (task) => task.id === entry.blockingTaskId,
                    )?.title ||
                    entry.blockingTaskId ||
                    "",
                })}
              </p>
            )}
            {(entry.state === "failed" ||
              entry.state === "unknown" ||
              entry.state === "cancelled") && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => {
                  if (!composerDraftHasContent(composerDraftRef.current))
                    updateComposerDraft(
                      entry.draft.kind === "multimodal"
                        ? {
                            kind: "text",
                            text: entry.draft.text,
                            attachmentsReloadRequired: true,
                          }
                        : entry.draft,
                    );
                }}
              >
                {t("run.prepare_retry")}
              </Button>
            )}
          </>
        }
      >
        <div className="task-input-copy">
          {entry.draft.kind === "skill"
            ? `/${entry.draft.invocationName} ${entry.draft.argumentValues.join(" ")}`
            : entry.draft.text}
        </div>
        {entry.draft.kind === "multimodal" &&
          entry.draft.attachments.map((attachment) => (
            <p key={attachment.token}>{attachment.displayName}</p>
          ))}
      </UserInputMessage>
    ),
  }));
  const pendingMessages = localReadingInputs.length ? (
    <>{localReadingInputs.map((item) => item.content)}</>
  ) : null;
  const composerFooter = (
    <>
      {activeTask && (
        <ConversationContext key={activeTask.id} context={activeTask.context} />
      )}
      <ComposerFooter
        textareaRef={composer}
        sendDisabledReason={inputDisabledReason}
        approvalModeControl={
          newTaskDraftActive ? (
            <NewTaskApprovalModeMenu
              approvalModes={
                snapshot.capabilities.permissionProfiles
                  ? snapshot.permissions.availableModes
                  : []
              }
              approvalMode={newTaskApprovalMode}
              disabled={workbenchMutationDisabled}
              onApprovalModeChange={setNewTaskApprovalOverride}
            />
          ) : activeTask ? (
            <ApprovalModeMenu
              task={activeTask}
              request={approvalRequests[activeTask.id] ?? null}
              disabled={bridgeUnavailable}
              onSelect={(mode) => void setTaskApprovalMode(mode)}
              onRefresh={() => void refreshTaskApprovalMode()}
            />
          ) : null
        }
        archived={Boolean(activeTask?.archived)}
        closing={activeTask?.lifecycle === "closing"}
        unavailable={Boolean(
          activeTask &&
          activeTask.lifecycle === "open" &&
          !activeTask.continuationAvailable,
        )}
        unavailableReason={activeTask?.continuationUnavailableReason ?? null}
        draft={composerDraft}
        draftScope={`${bridgeGeneration}:${composerDraftScope}`}
        attachmentsEnabled={snapshot.capabilities.attachments.enabled}
        attachmentMaxFileBytes={snapshot.capabilities.attachments.maxFileBytes}
        attachmentBusy={attachmentBusy}
        attachmentCancelling={attachmentView === "cancelling"}
        attachmentRemoving={attachmentRemoving}
        attachmentError={attachmentError}
        attachmentModelWarning={attachmentModelWarning}
        skillCatalog={skillCatalog}
        slashCommands={slashCommands}
        composeDisabled={Boolean(
          selectedTaskSummary &&
          (selectedTaskSummary.archived ||
            selectedTaskSummary.deletionStatus === "deleting" ||
            selectedTaskSummary.lifecycle === "closing"),
        )}
        attachmentActionsDisabled={bridgeUnavailable}
        canSubmit={canSubmit}
        runInFlight={Boolean(taskCanCompose && taskOperationInFlight)}
        accessRequired={Boolean(
          newTaskDraftActive &&
          composerWorkspace &&
          composerWorkspace.authorization !== "available",
        )}
        workspaceMissing={Boolean(!newTaskDraftActive && !composerWorkspace)}
        workspaceLabel={
          newTaskDraftActive && !composerWorkspace
            ? t("workspace.default_directory")
            : composerWorkspace
              ? workspaceDirectoryLabel(
                  composerWorkspace,
                  t("workspace.default_directory"),
                )
              : t("workspace.none")
        }
        workspaceTitle={
          newTaskDraftActive && !composerWorkspace
            ? t("workspace.default_directory")
            : composerWorkspace
              ? workspaceDirectoryLabel(
                  composerWorkspace,
                  t("workspace.default_directory"),
                )
              : t("workspace.none")
        }
        workspaceOptions={[
          {
            id: automaticWorkspaceOptionId,
            label: t("workspace.default_directory"),
            authorization: "available" as const,
            disabled: !snapshot.capabilities.automaticWorkspaces,
          },
          ...manualWorkspaces.map((workspace) => ({
            id: workspace.id,
            label: workspace.canonicalRoot,
            description: workspace.displayName || undefined,
            authorization: workspace.authorization,
          })),
        ]}
        selectedWorkspaceOptionId={
          newTaskDraftActive
            ? (composerWorkspace?.id ?? automaticWorkspaceOptionId)
            : ""
        }
        workspaceEditable={newTaskDraftActive && !taskIdentityPending}
        modelLabel={
          newTaskDraftActive
            ? setupNotice?.action === "start" &&
              !newTaskModelState.selectedModelLabel
              ? t("model_setup.unconfigured")
              : selectedModelLabel
            : taskModelLabel || null
        }
        modelOptions={
          newTaskDraftActive
            ? newTaskModelState.options
            : taskModelPolicy.showsSelector
              ? taskModelOptions
              : []
        }
        selectedModelId={
          newTaskDraftActive
            ? newTaskModelState.selectedModelId
            : displayedTaskModelId
        }
        modelEditable={
          newTaskDraftActive
            ? newTaskModelState.editable && !taskIdentityPending
            : taskModelPolicy.showsSelector
        }
        modelSelectionDisabled={
          bridgeUnavailable ||
          (newTaskDraftActive
            ? newTaskModelState.options.length === 0
            : taskModelOptions.length === 0 || !taskModelPolicy.selectable)
        }
        modelSelectionPending={
          newTaskDraftActive
            ? newTaskModelState.options.length === 0 &&
              snapshot.models.operation === "refreshing_catalog"
            : taskModelPolicy.pending
        }
        modelContextTitle={
          setupNotice
            ? t(modelSetupMessage(setupNotice))
            : newTaskDraftActive &&
                newTaskRequestedModel !== null &&
                !newTaskModelState.valid
              ? t("settings.new_task_model_invalid")
              : activeTask?.modelIntent?.state === "outcome_unknown"
                ? t("mutation.reason.persistence_outcome_unknown")
                : newTaskDraftActive
                  ? t("settings.new_task_model_help")
                  : t(
                      taskModelPolicy.selectable &&
                        taskModelOptions.length === 0
                        ? "settings.task_model_catalog_unavailable"
                        : taskModelSelectionMessageId(
                            activeTask?.modelSelectionAvailability,
                          ),
                    )
        }
        modelNotice={
          setupNotice && (
            <ModelSetupNotice
              notice={setupNotice}
              disabled={
                bridgeUnavailable ||
                accountBusy ||
                executionBusy ||
                accountCancelBusy
              }
              onAction={runModelSetupAction}
              onChooseSetup={
                setupNotice.action === "login" && customProvidersAvailable
                  ? openModelSetup
                  : undefined
              }
            />
          )
        }
        actionDisabled={workbenchMutationDisabled || workspaceBusy}
        stopAction={
          taskOperationInFlight || localSubmissionCount > 0 ? "run" : null
        }
        stopDisabled={
          bridgeUnavailable ||
          Boolean(activeTask && activeTask.id in cancelPending) ||
          Boolean(
            activeTask?.currentRunPhase === "stopping" &&
            !activeTask.inputSubmissions.some(
              (record) => record.state === "waiting",
            ) &&
            localSubmissionCount === 0,
          )
        }
        onDraftChange={updateComposerDraft}
        onChooseAttachments={() => void addAttachments()}
        onDropFiles={(files) => {
          if (
            client.attachmentInputMode === "file_bytes" &&
            route === "workbench" &&
            !settingsOpen &&
            !searchOpen
          )
            void addAttachments({ files });
        }}
        onPasteImages={(files) => {
          if (route === "workbench" && !settingsOpen && !searchOpen)
            void addAttachments({ files });
        }}
        onCancelAttachments={
          attachmentOperation.current && attachmentView === "adding"
            ? () => {
                const operation = attachmentOperation.current;
                if (!operation) return;
                operation.cancelled = true;
                void operation.add.cancel().catch(() => undefined);
              }
            : undefined
        }
        onRemoveAttachment={(token) => void removeAttachment(token)}
        onSubmit={() => void submitRun()}
        onStop={() => void cancelRun()}
        onSlashCommand={runSlashCommand}
        onRefreshSkillCatalog={() => void refreshComposerSkillCatalog()}
        onConfirmAccess={() => void chooseWorkspaceForDraft()}
        onSelectWorkspace={(workspaceId) => setDraftWorkspaceById(workspaceId)}
        onSelectModel={(id) => {
          if (newTaskDraftActive) {
            const option = newTaskModelState.options.find(
              (candidate) => candidate.selectionId === id,
            );
            if (option) setNewTaskRequestedModel(option.modelRef);
            return;
          }
          void selectModelForTask(id);
        }}
      />
    </>
  );
  const activePreview =
    taskPanel.activeTab?.kind === "preview"
      ? filePreviewTabs.resources[taskPanel.activeTab.tabId]
      : undefined;
  const filePreviewViewState: FilePreviewViewState | null = !activePreview
    ? null
    : {
        selected: activePreview.reference,
        phase: activePreview.kind === "loading" ? "loading" : "settled",
        preview:
          activePreview.kind === "loading" ? null : activePreview.preview,
      };
  const activePanelView = taskPanel.activeTab
    ? taskPanelViews.stateFor(taskPanel.activeTab.tabId)
    : null;
  const previewMatchesTarget =
    panelTarget.kind === "preview" &&
    activePreview !== undefined &&
    panelTarget.taskId === activePreview.taskId &&
    panelTarget.runId === activePreview.runId &&
    panelTarget.referenceId === activePreview.reference.id;
  const reviewMatchesTarget =
    panelTarget.kind === "review" &&
    fileChanges.kind !== "closed" &&
    panelTarget.taskId === fileChanges.taskId &&
    panelTarget.runId === fileChanges.runId;
  const pendingLocator =
    panelTask?.pendingUi && taskSignals(panelTask).attention ? (
      <button
        type="button"
        className="task-attention-locator focus-ring"
        aria-label={t("inspector.needs_attention")}
        title={t("inspector.needs_attention")}
        onClick={focusPendingFromTaskPanel}
      >
        <Icon name="warning" />
        <span>{t("inspector.needs_attention")}</span>
      </button>
    ) : null;
  const panelTitle =
    panelTarget.kind === "empty"
      ? t("task_panel.title")
      : panelTarget.kind === "review"
        ? t("file_changes.review")
        : previewMatchesTarget && filePreviewViewState
          ? filePreviewViewState.selected.displayPath
          : t("file_preview.title");
  return (
    <AppShell
      taskTitle={
        settingsOpen
          ? t("settings.title")
          : route === "skills"
            ? t("skills.title")
            : route === "mcp"
              ? t("mcp.title")
              : route === "scheduled-tasks"
                ? t("scheduled.title")
                : activeTaskTitle
      }
      contextVisible={
        !settingsOpen && route === "workbench" && activeTask !== null
      }
      headerActions={
        !settingsOpen && route === "workbench" ? (
          <>
            {pendingLocator}
            {activeTask && (
              <TaskInformation
                key={activeTask.id}
                task={activeTask}
                models={snapshot.models}
                permissionProfilesEnabled={
                  snapshot.capabilities.permissionProfiles
                }
                triggerRef={taskInformationTrigger}
              />
            )}
          </>
        ) : null
      }
      onSearch={() => setSearchOpen(true)}
      attentionNotice={
        connectionBusy
          ? t("connection.sync_retrying")
          : commandBarStatus
            ? t(commandBarStatus.id, commandBarStatus.values)
            : null
      }
      attentionBusy={connectionBusy}
      attentionContent={
        connectionBusy ? (
          <p>{t("connection.sync_retrying")}</p>
        ) : commandBarStatus?.audience.scope === "connection" ? (
          <>
            <p>{t(connectionFailure.helpId)}</p>
            {connectionRetryable && (
              <Button
                type="button"
                variant="secondary"
                size="sm"
                onClick={() => void retryViewSynchronization()}
              >
                {t("connection.retry_sync")}
              </Button>
            )}
            {connectionShellStatus?.diagnostic && (
              <details className="connection-diagnostic">
                <summary className="focus-ring">
                  {t("connection.details")}
                </summary>
                <p>
                  {connectionShellStatus.sourceId
                    ? `${t(connectionShellStatus.sourceId)}: `
                    : ""}
                  {connectionShellStatus.diagnostic}
                </p>
              </details>
            )}
          </>
        ) : undefined
      }
      left={
        <div className="sidebar-frame">
          <div className="sidebar-primary">
            <p className="brand-name">
              <BrandLogo label={t("app.name")} showMark={false} />
            </p>
            <nav
              className="sidebar-capabilities"
              aria-label={t("skills.navigation_label")}
            >
              <button
                className="sidebar-capability focus-ring"
                data-active={route === "workbench" && newTaskDraftActive}
                disabled={viewSyncFailed || !bridgeReady}
                onClick={beginNewTask}
              >
                <span className="sidebar-capability-mark" aria-hidden="true">
                  <Icon name="new-task" />
                </span>
                <span>{t("task.new")}</span>
              </button>
              <button
                className="sidebar-capability focus-ring"
                data-active={route === "skills"}
                aria-current={route === "skills" ? "page" : undefined}
                onClick={() => {
                  pendingTaskSelection.current = null;
                  setRoute("skills");
                }}
              >
                <span className="sidebar-capability-mark" aria-hidden="true">
                  <Icon name="skills" />
                </span>
                <span>{t("skills.title")}</span>
              </button>
              <button
                className="sidebar-capability focus-ring"
                data-active={route === "mcp"}
                aria-current={route === "mcp" ? "page" : undefined}
                onClick={() => {
                  pendingTaskSelection.current = null;
                  setRoute("mcp");
                }}
              >
                <span className="sidebar-capability-mark" aria-hidden="true">
                  <Icon name="mcp" />
                </span>
                <span>{t("mcp.title")}</span>
              </button>
              {snapshot.capabilities.scheduledTaskPersistenceHealth !==
                "unavailable" && (
                <button
                  className="sidebar-capability focus-ring"
                  data-active={route === "scheduled-tasks"}
                  aria-current={
                    route === "scheduled-tasks" ? "page" : undefined
                  }
                  onClick={() => {
                    pendingTaskSelection.current = null;
                    setRoute("scheduled-tasks");
                  }}
                >
                  <span className="sidebar-capability-mark" aria-hidden="true">
                    <Icon name="scheduled-tasks" />
                  </span>
                  <span>{t("scheduled.title")}</span>
                </button>
              )}
            </nav>

            <div className="sidebar-navigation">
              {snapshot.capabilities.taskHistoryPersistenceHealth !== "ready" &&
                snapshot.capabilities.taskHistoryPersistenceHealth !==
                  "degraded" &&
                snapshot.capabilities.taskHistoryPersistenceHealth !==
                  "unavailable" && (
                  <ConfirmationNotice
                    className="task-persistence-error"
                    message={t(
                      `task.persistence.${snapshot.capabilities.taskHistoryPersistenceHealth}`,
                    )}
                    detail={t("persistence.recovery.original_retained")}
                    actionLabel={t("persistence.recovery.action")}
                    dialogTitle={t("persistence.recovery.task.title")}
                    dialogDescription={t("persistence.recovery.task.body")}
                    cancelLabel={t("persistence.recovery.cancel")}
                    confirmLabel={t("persistence.recovery.confirm")}
                    pendingLabel={t("persistence.recovery.running")}
                    failureMessage={t("persistence.recovery.failed")}
                    actionAvailable={
                      snapshot.capabilities.taskHistoryRecoveryAvailable
                    }
                    disabled={bridgeUnavailable}
                    onConfirm={async () => {
                      const result = await client.recoverTaskHistory(
                        snapshot.revision,
                      );
                      return result.outcome === "recovered"
                        ? null
                        : t(persistenceRecoveryErrorMessageId(result.outcome));
                    }}
                  />
                )}
              <TaskList
                tasks={navigableTaskItems}
                workspaces={snapshot.workspaces}
                activeTaskId={
                  route === "workbench" ? workbench.activeTaskId : null
                }
                suppressedCompletionTaskId={suppressedCompletionTaskId}
                onSelectTask={openTask}
                onTaskAction={handleTaskAction}
                taskMutationDisabled={workbenchMutationDisabled}
                synchronized={!bridgeUnavailable}
                retainedTaskCount={Number(
                  snapshot.capabilities.retainedTaskHistoryCount,
                )}
              />
            </div>
          </div>

          <AccountIdentity
            account={snapshot.account}
            active={settingsOpen}
            disabled={bridgeUnavailable || accountBusy}
            cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
            onOpenSettings={openSettings}
            onBeginLogin={() =>
              void runAccountCommand(() => client.beginLogin())
            }
            onCancel={() => void cancelAccountOperation()}
            onLogout={() => void runAccountCommand(() => client.logout())}
          />
        </div>
      }
      rightPanelOpen={rightPanelOpen && !settingsOpen}
      rightPanelToggleRef={taskPanelToggle}
      onTaskStageExposureChange={setTaskStageExposed}
      onToggleRightPanel={toggleRightPanel}
      onDismissRightPanel={dismissTaskPanel}
      rightPanel={
        !settingsOpen && rightPanelOpen ? (
          <TaskPanel
            title={panelTitle}
            tabs={taskPanel.session.tabs}
            activeTabId={taskPanel.session.activeTabId}
            attention={pendingLocator}
            actions={
              !taskPanel.waitingForRun &&
              panelTarget.kind === "preview" &&
              previewMatchesTarget &&
              filePreviewViewState ? (
                <FilePreviewRefreshAction
                  state={filePreviewViewState}
                  onRefresh={refreshFilePreview}
                />
              ) : null
            }
            onSelectTab={taskPanel.selectTab}
            onCloseTab={closeTaskPanelTab}
            onClose={dismissTaskPanel}
          >
            {taskPanel.waitingForRun ? (
              <p role="status" aria-busy="true">
                {t("common.loading")}
              </p>
            ) : panelTarget.kind === "empty" ? (
              <p className="task-panel-empty">{t("task_panel.empty")}</p>
            ) : panelTarget.kind === "preview" &&
              previewMatchesTarget &&
              filePreviewViewState ? (
              <FilePreviewView
                state={filePreviewViewState}
                webLink={markdownWebLink}
                mode={activePanelView?.previewMode ?? "preview"}
                scrollTop={activePanelView?.scrollTop ?? 0}
                onModeChange={(mode) => {
                  if (taskPanel.activeTab)
                    taskPanelViews.setPreviewMode(
                      taskPanel.activeTab.tabId,
                      mode,
                    );
                }}
                onScrollTopChange={(scrollTop) => {
                  if (taskPanel.activeTab)
                    taskPanelViews.setScrollTop(
                      taskPanel.activeTab.tabId,
                      scrollTop,
                    );
                }}
                onRetry={refreshFilePreview}
              />
            ) : panelTarget.kind === "review" && reviewMatchesTarget ? (
              <FileChangesView
                observation={fileChanges.observation}
                changes={fileChanges.changes}
                diffs={fileChanges.diffs}
                expandedFiles={activePanelView?.expandedFiles ?? {}}
                focus={fileChanges.focus}
                scrollTop={activePanelView?.scrollTop ?? 0}
                onFileExpandedChange={(displayPath, expanded) => {
                  if (taskPanel.activeTab)
                    taskPanelViews.setFileExpanded(
                      taskPanel.activeTab.tabId,
                      displayPath,
                      expanded,
                    );
                }}
                onFocusHandled={(requestId) =>
                  setFileChanges((current) =>
                    current.kind === "open" &&
                    current.focus?.requestId === requestId
                      ? { ...current, focus: null }
                      : current,
                  )
                }
                onScrollTopChange={(scrollTop) => {
                  if (taskPanel.activeTab)
                    taskPanelViews.setScrollTop(
                      taskPanel.activeTab.tabId,
                      scrollTop,
                    );
                }}
                onLoad={loadFileChangeDiff}
              />
            ) : null}
          </TaskPanel>
        ) : null
      }
      overlay={
        settingsOpen ? (
          <SettingsPage
            archiveManagement={{
              tasks: snapshot.taskIndex,
              workspaces: snapshot.workspaces,
              query: archivedQuery,
              pending: taskPending,
              errors: taskArchiveErrors,
              synchronized: !bridgeUnavailable,
              onQuery: setArchivedQuery,
              scrollTop: archiveView.current.scrollTop,
              focusTaskId: archiveView.current.focusTaskId,
              onScroll: (scrollTop) => {
                archiveView.current.scrollTop = scrollTop;
              },
              onOpen: (task) => {
                archiveView.current.focusTaskId = task.id;
                setSettingsOpen(false);
                openTask(task.id);
              },
              onRestore: (task) => void setArchived(false, task),
              onDelete: requestTaskDeletion,
            }}
            account={snapshot.account}
            models={snapshot.models}
            automaticWorkspaceRoot={snapshot.automaticWorkspaceRoot}
            customProviderCapabilities={{
              management: snapshot.capabilities.customProviderManagement,
              secretCapture: snapshot.capabilities.customProviderSecretCapture,
              modelTest: snapshot.capabilities.customModelTest,
            }}
            focusTarget={settingsFocus}
            disabled={bridgeUnavailable}
            accountDisabled={accountBusy}
            executionDisabled={executionBusy}
            cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
            onBack={closeSettings}
            onRefresh={() =>
              void runExecutionCommand(() => client.refreshModelsCatalog())
            }
            onResetModels={() =>
              runExecutionCommand(() =>
                client.resetModelsStore(snapshot.revision),
              )
            }
            onChooseAutomaticWorkspaceRoot={(expectedGeneration) =>
              mutateAutomaticWorkspaceRoot(() =>
                client.chooseAutomaticWorkspaceRoot(expectedGeneration),
              )
            }
            onResetAutomaticWorkspaceRoot={(expectedGeneration) =>
              mutateAutomaticWorkspaceRoot(() =>
                client.resetAutomaticWorkspaceRoot(expectedGeneration),
              )
            }
            onRetryAutomaticWorkspaceRoot={(expectedGeneration) =>
              mutateAutomaticWorkspaceRoot(() =>
                client.retryAutomaticWorkspaceRoot(expectedGeneration),
              )
            }
            onCancel={() => void cancelAccountOperation()}
            onSelectModel={(id) => void selectMetaskModel(id)}
            onCreateCustomProvider={(input) =>
              runExecutionCommand(() => client.createCustomProvider(input))
            }
            onCreateBuiltinProvider={(input) =>
              runExecutionCommand(() => client.createBuiltinProvider(input))
            }
            onUpdateBuiltinProviderBaseUrl={(input) =>
              runExecutionCommand(() =>
                client.updateBuiltinProviderBaseUrl(input),
              )
            }
            onUpdateCustomProvider={(input) =>
              runExecutionCommand(() =>
                client.updateCustomProvider({
                  providerId: input.providerId,
                  expectedProviderRevision: input.expectedProviderRevision,
                  displayName: input.displayName,
                  protocol: input.protocol,
                  normalizedBaseUrl: input.normalizedBaseUrl,
                }),
              )
            }
            onReplaceCustomProviderCredential={(providerId, revision, apiKey) =>
              runExecutionCommand(() =>
                client.replaceCustomProviderCredential(
                  providerId,
                  revision,
                  apiKey,
                ),
              )
            }
            onAddCustomModel={(
              providerId,
              providerRevision,
              catalogGeneration,
              modelId,
            ) =>
              runExecutionCommand(() =>
                client.addCustomModel({
                  providerId,
                  expectedProviderRevision: providerRevision,
                  expectedCatalogGeneration: catalogGeneration,
                  model: { id: modelId },
                }),
              )
            }
            onRemoveCustomModel={(
              providerId,
              providerRevision,
              catalogGeneration,
              modelId,
            ) =>
              runExecutionCommand(() =>
                client.removeCustomModel({
                  selection: { sourceId: providerId, modelId },
                  expectedProviderRevision: providerRevision,
                  expectedCatalogGeneration: catalogGeneration,
                }),
              )
            }
            onRemoveCustomProvider={(providerId, generation) =>
              runExecutionCommand(() =>
                client.removeCustomProvider(providerId, generation),
              )
            }
            onTestCustomModel={(
              providerId,
              revision,
              modelId,
              sourceGeneration,
              catalogGeneration,
            ) =>
              void runExecutionCommand(() =>
                client.testCustomModel(
                  providerId,
                  revision,
                  modelId,
                  sourceGeneration,
                  catalogGeneration,
                ),
              )
            }
            onSelectCustomModel={(providerId, generation, modelId) =>
              void runExecutionCommand(() =>
                client.selectModelsDefault({
                  sourceId: providerId,
                  modelId,
                  expectedSelectionRevision: snapshot.models.selectionRevision,
                  expectedSourceGeneration:
                    snapshot.models.customProviders.find(
                      (connection) => connection.id === providerId,
                    )?.sourceGeneration ?? "0",
                  expectedCatalogGeneration:
                    snapshot.models.customProviders.find(
                      (connection) => connection.id === providerId,
                    )?.catalogGeneration ?? "0",
                }),
              )
            }
            onBeginLogin={() =>
              void runAccountCommand(() => client.beginLogin())
            }
            onRetryRefresh={() =>
              void runAccountCommand(() => client.retryAccountRefresh())
            }
            onRefreshAccountSummary={() =>
              void runAccountCommand(() => client.refreshAccountSummary())
            }
            onOpenRecharge={() => void openAccountRecharge()}
            onLogout={() => void runAccountCommand(() => client.logout())}
          />
        ) : null
      }
    >
      {route === "skills" ? (
        snapshot.skillManagement ? (
          <SkillsPage
            management={snapshot.skillManagement}
            personalCatalog={snapshot.skillCatalog}
            workspaces={snapshot.workspaces}
            query={skillsQuery}
            refreshRequests={skillRefreshRequests}
            sourceBusy={sourceMutationBusy}
            sourceError={sourceMutationError}
            onSetSourceEnabled={(id, enabled, revision) =>
              void commitSkillSourceMutation(() =>
                client.setSkillSourceEnabled(id, enabled, revision),
              )
            }
            onRecoverSources={(action, token) =>
              void commitSkillSourceMutation(() =>
                client.recoverSkillSourceSettings(action, token),
              )
            }
            disabled={bridgeUnavailable}
            onQuery={setSkillsQuery}
            onRefresh={(target) => void refreshSkillsPageCatalog(target)}
            onSetEnabled={setSkillEnabled}
            onChooseImport={(kind) => client.chooseSkillImport(kind)}
            onInstall={(previewId, scope, allowReplace) =>
              commitSkillMutation(() =>
                client.installSkill(previewId, scope, allowReplace),
              )
            }
            onReimport={(installId, previewId) =>
              commitSkillMutation(() =>
                client.reimportSkill(installId, previewId),
              )
            }
            onUninstall={(installId) =>
              commitSkillMutation(() => client.uninstallSkill(installId))
            }
            onRetry={(installId) =>
              commitSkillMutation(() =>
                client.retrySkillVerification(installId),
              )
            }
            onExport={(installId) => client.exportSkill(installId)}
            onDetail={(installId) => client.skillDetail(installId)}
          />
        ) : (
          <p role="status" aria-busy="true">
            {t("common.loading")}
          </p>
        )
      ) : route === "mcp" ? (
        snapshot.mcp ? (
          <McpPage
            management={snapshot.mcp}
            capabilities={{
              connectionApproval: snapshot.capabilities.mcpConnectionApproval,
              secretCapture: snapshot.capabilities.mcpSecretCapture,
              secretMaxBytes: snapshot.capabilities.mcpSecretMaxBytes,
              oauth: snapshot.capabilities.mcpOAuth,
            }}
            query={mcpQuery}
            disabled={bridgeUnavailable || !snapshot.capabilities.mcpManagement}
            onQuery={setMcpQuery}
            onCreateStdio={(generation, input) =>
              commitMcpMutation(() =>
                client.createMcpStdioServer(generation, input),
              )
            }
            onCreateHttp={(generation, input) =>
              commitMcpMutation(() =>
                client.createMcpHttpServer(generation, input),
              )
            }
            onUpdateStdio={(generation, serverId, input) =>
              commitMcpMutation(() =>
                client.updateMcpStdioConnection(generation, serverId, input),
              )
            }
            onUpdateHttp={(generation, serverId, input) =>
              commitMcpMutation(() =>
                client.updateMcpHttpConnection(generation, serverId, input),
              )
            }
            onRename={(generation, serverId, displayName) =>
              commitMcpMutation(() =>
                client.renameMcpServer(generation, serverId, displayName),
              )
            }
            onApprove={(generation, serverId) =>
              commitMcpMutation(() =>
                client.approveMcpConnection(generation, serverId),
              )
            }
            onCaptureSecret={(generation, serverId, slot, secret) =>
              commitMcpMutation(() =>
                client.captureMcpSecret(generation, serverId, slot, secret),
              )
            }
            onAuthorize={(generation, serverId) =>
              client.authorizeMcpOAuth(generation, serverId)
            }
            onCancelAuthorization={(operationId) =>
              client.cancelMcpAuthorization(operationId)
            }
            onSetEnabled={(generation, serverId, enabled) =>
              commitMcpMutation(() =>
                client.setMcpServerEnabled(generation, serverId, enabled),
              )
            }
            onSetAllowedTools={(generation, serverId, toolNames) =>
              commitMcpMutation(() =>
                client.setMcpAllowedTools(generation, serverId, toolNames),
              )
            }
            onRemove={(generation, serverId) =>
              commitMcpMutation(() =>
                client.removeMcpServer(generation, serverId),
              )
            }
            onTest={testMcpConnection}
            onApply={applyMcpConfiguration}
            onRefresh={refreshMcpCatalog}
          />
        ) : (
          <p role="status" aria-busy="true">
            {t("common.loading")}
          </p>
        )
      ) : route === "scheduled-tasks" ? (
        snapshot.scheduledTasks ? (
          <ScheduledTasksPage
            snapshot={{
              ...snapshot,
              scheduledTasks: snapshot.scheduledTasks,
            }}
            disabled={
              bridgeUnavailable || !snapshot.capabilities.scheduledTasks
            }
            recoveryDisabled={bridgeUnavailable}
            onCreate={(input) => client.createScheduledTask(input)}
            onUpdate={(id, epoch, input) =>
              client.updateScheduledTask(id, epoch, input)
            }
            onSetEnabled={(id, epoch, enabled) =>
              client.setScheduledTaskEnabled(id, epoch, enabled)
            }
            onRunNow={(id, epoch) => client.runScheduledTaskNow(id, epoch)}
            onDelete={(id, epoch) => client.deleteScheduledTask(id, epoch)}
            onRecover={() =>
              client.recoverScheduledTaskStore(snapshot.revision)
            }
            onOpenTask={(taskId) => {
              const task = snapshot.taskIndex.find(
                (item) => item.id === taskId,
              );
              if (!task) return;
              openTask(taskId);
            }}
          />
        ) : (
          <p role="status" aria-busy="true">
            {t("common.loading")}
          </p>
        )
      ) : (
        <div
          className="workbench-view"
          data-view={newTaskDraftActive ? "new-task" : "task"}
        >
          <TaskWorkspace
            newTask={newTaskDraftActive}
            hasWorkspace={Boolean(composerWorkspace)}
            composer={
              activeTask?.archived ? (
                <div className="archived-task-banner">
                  <p>{t("archive.reading")}</p>
                  <div className="archived-task-actions">
                    <Button
                      variant="secondary"
                      size="sm"
                      onClick={() => openSettings("archived")}
                    >
                      {t("archive.back")}
                    </Button>
                    <Button
                      size="sm"
                      disabled={
                        taskMutationDisabled ||
                        selectedTaskSummary?.historyReadOnly ||
                        activeTask.lifecycle === "closing" ||
                        activeTask.activeOperation !== null ||
                        activeTask.deletionStatus === "deleting"
                      }
                      onClick={() => void setArchived(false, activeTask)}
                    >
                      {t("archive.restore")}
                    </Button>
                  </div>
                </div>
              ) : (
                composerFooter
              )
            }
            pendingContent={pendingMessages}
            taskContent={
              <TaskContent
                task={activeTask}
                memory={taskReadingMemory}
                history={{
                  available: Boolean(nextHistoryCursor),
                  loading: historyLoading,
                  onLoad: () => {
                    if (nextHistoryCursor && workbench.activeTaskId) {
                      const goal = earlierHistoryGoal(
                        snapshot,
                        workbench.activeTaskId,
                        nextHistoryCursor,
                      );
                      if (goal)
                        setHistoryRequests((current) => ({
                          ...current,
                          [goal.taskId]: goal,
                        }));
                    }
                  },
                }}
                localSubmissions={localReadingInputs}
                webLink={markdownWebLink}
                snapshotReceivedAt={workbench.snapshotReceivedAt}
                synchronized={!bridgeUnavailable}
                requestingStop={Boolean(
                  activeTask && activeTask.id in cancelPending,
                )}
                revision={snapshot.revision}
                composerHasDraft={composerDraftHasContent(composerDraft)}
                retryAvailable={taskCanCompose && !taskOperationInFlight}
                responseDisabled={bridgeUnavailable}
                fileChangesEnabled={snapshot.capabilities.typedFileChanges}
                outputsEnabled={snapshot.capabilities.typedOutputs}
                onOutputAction={(taskId, runId, outputId, action, signal) =>
                  client.outputAction(taskId, runId, outputId, action, signal)
                }
                onPrepareOutputEdit={
                  taskCanCompose && !newTaskDraftActive
                    ? prepareOutputEdit
                    : undefined
                }
                onPrepareRetry={prepareRetry}
                onPreviewFile={openFilePreview}
                loadFilePreview={loadFilePreview}
                onReviewFileChanges={openFileChanges}
                onRespond={(payload) => void respondUi(payload)}
                renderPendingUi={(props) => {
                  const { taskId, ...panelProps } = props;
                  const identity = uiRequestIdentity(taskId, props.pending);
                  return (
                    <ApprovalPanel
                      {...panelProps}
                      responsePhase={uiResponsePhase(
                        uiResponseStates,
                        identity,
                      )}
                    />
                  );
                }}
              />
            }
          />
        </div>
      )}
      <GlobalSearch
        open={searchOpen}
        query={searchQuery}
        results={searchResults}
        loading={
          Boolean(searchQuery.trim()) &&
          (!searchCurrent ||
            snapshot.searchIndex === null ||
            snapshot.searchIndex.stale ||
            (snapshot.searchIndex.results.length === 0 &&
              snapshot.searchIndex.nextCursor !== null))
        }
        hasMore={searchCurrent && snapshot.searchIndex?.nextCursor != null}
        onMore={() => {
          if (searchCurrent && snapshot.searchIndex?.nextCursor)
            setSearchCursor(snapshot.searchIndex.nextCursor);
        }}
        onFirst={
          searchCursor === null ? undefined : () => setSearchCursor(null)
        }
        onQuery={(query) => {
          setSearchQuery(boundedSearchQuery(query));
          setSearchCursor(null);
        }}
        onClose={() => {
          setSearchOpen(false);
          setSearchQuery("");
        }}
        onSelect={selectSearchResult}
      />
      <ModelSetupDialog
        open={
          modelSetupOpen &&
          route === "workbench" &&
          newTaskDraftActive &&
          !settingsOpen &&
          !searchOpen &&
          !bridgeUnavailable
        }
        customProvidersAvailable={customProvidersAvailable}
        returnFocus={modelSetupReturnFocus}
        disabled={accountBusy || executionBusy}
        onClose={finishModelSetupIntroduction}
        onLogin={() => runModelSetupAction("login")}
        onConfigure={() => openSettings("providers")}
      />

      {archiveNotice && (
        <ArchiveNotice
          key={archiveNotice.id}
          notice={archiveNotice}
          disabled={
            bridgeUnavailable ||
            !noticeTask ||
            !noticeTask.archived ||
            noticeTask.historyReadOnly ||
            noticeTask.lifecycle === "closing" ||
            noticeTask.deletionStatus === "deleting" ||
            `task:${noticeTask.id}` in taskPending
          }
          onDismiss={() => setArchiveNotice(null)}
          onView={() => {
            setArchiveNotice(null);
            openSettings("archived");
          }}
          onUndo={() => {
            const taskId = archiveNotice.taskId;
            const task = latestSnapshotRef.current?.taskIndex.find(
              (entry) => entry.id === taskId,
            );
            if (!task?.archived) return;
            void setArchived(false, task).then(() =>
              window.requestAnimationFrame(() => {
                if (activeTaskIdRef.current === taskId)
                  composer.current?.focus();
                else
                  document
                    .querySelector<HTMLElement>(
                      `[data-task-id="${CSS.escape(taskId)}"]`,
                    )
                    ?.focus();
              }),
            );
          }}
        />
      )}
      <Dialog.Root
        open={renameEditor !== null}
        onOpenChange={(open) => !open && closeRenameDialog()}
      >
        <Dialog.Portal>
          <Dialog.Backdrop />
          <Dialog.Popup
            initialFocus={() => {
              renameInput.current?.select();
              return renameInput.current ?? false;
            }}
          >
            <Dialog.Title>{t("task.rename_title")}</Dialog.Title>
            <form
              className="grid gap-4"
              aria-busy={renamePending}
              onSubmit={(event) => {
                event.preventDefault();
                void renameTask();
              }}
            >
              <div className="grid gap-2">
                <label htmlFor="task-rename-name" className="text-sm">
                  {t("task.rename_name")}
                </label>
                <Input
                  id="task-rename-name"
                  ref={renameInput}
                  maxLength={120}
                  value={renameEditor?.draft ?? ""}
                  disabled={renamePending}
                  aria-describedby={
                    renameEditor?.message ? "task-rename-error" : undefined
                  }
                  onChange={(event) => {
                    const draft = event.target.value;
                    setRenameEditor((current) =>
                      current ? { ...current, draft, message: null } : current,
                    );
                  }}
                  onCompositionStart={() => {
                    renameComposing.current = true;
                  }}
                  onCompositionEnd={() => {
                    renameComposing.current = false;
                  }}
                  onKeyDown={(event) => {
                    if (
                      (event.key === "Enter" || event.key === "Escape") &&
                      (renameComposing.current || event.nativeEvent.isComposing)
                    ) {
                      event.preventDefault();
                      event.stopPropagation();
                    }
                  }}
                />
              </div>
              {renameEditor?.message && (
                <p
                  id="task-rename-error"
                  role="alert"
                  className="text-sm text-(--ui-content-error)"
                >
                  {t(renameEditor.message)}
                </p>
              )}
              <div className="flex justify-end gap-2">
                <Button
                  type="button"
                  variant="secondary"
                  disabled={renamePending}
                  onClick={closeRenameDialog}
                >
                  {t("common.cancel")}
                </Button>
                <Button
                  type="submit"
                  disabled={
                    renamePending ||
                    workbenchMutationDisabled ||
                    !renameEditor?.draft.trim()
                  }
                >
                  {t(renamePending ? "common.saving" : "common.save")}
                </Button>
              </div>
            </form>
          </Dialog.Popup>
        </Dialog.Portal>
      </Dialog.Root>
      {deleteTarget && (
        <AlertDialog.Root
          open={confirmDelete}
          onOpenChange={(open) => !open && closeDeleteConfirmation()}
        >
          <AlertDialog.Portal>
            <AlertDialog.Backdrop />
            <AlertDialog.Popup
              initialFocus={() => deleteCancel.current ?? false}
            >
              <AlertDialog.Title id="task-delete-title">
                {t("task.delete_confirm_title", { title: deleteTarget.title })}
              </AlertDialog.Title>
              <AlertDialog.Description id="task-delete-description">
                {t("task.delete_confirm_body")}
              </AlertDialog.Description>
              <div className="delete-confirmation-actions">
                <Button
                  autoFocus
                  type="button"
                  variant="secondary"
                  size="md"
                  ref={deleteCancel}
                  onClick={closeDeleteConfirmation}
                >
                  {t("common.cancel")}
                </Button>
                <Button
                  type="button"
                  variant="danger"
                  size="md"
                  disabled={
                    workbenchMutationDisabled ||
                    `task:${deleteTarget.id}` in taskPending ||
                    deleteTarget.deletionStatus === "deleting"
                  }
                  onClick={() => void deleteTask()}
                >
                  {t(
                    deleteTarget.activeOperation
                      ? "task.stop_and_delete"
                      : "task.delete",
                  )}
                </Button>
              </div>
            </AlertDialog.Popup>
          </AlertDialog.Portal>
        </AlertDialog.Root>
      )}
    </AppShell>
  );
}
