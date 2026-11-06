import {
  localReadingAnchor,
  type LocalReadingInput,
} from "../features/tasks/assistant-output.ts";
import { editCustomModel } from "./edit-custom-model.ts";
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
  TaskStopFeedbackController,
  type TaskStopFeedback,
} from "./task-stop-feedback.ts";
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
  beginFeedback,
  createFeedbackState,
  clearSecurityFeedback,
  dismissFeedback,
  observeFeedback,
  quietStatus,
  resetFeedback,
  selectCommandBarFeedback,
  settleFeedback,
  type FeedbackToken,
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
import { FeedbackNotice } from "../components/ui/FeedbackNotice.tsx";
import { DiagnosticDisclosure } from "../components/ui/DiagnosticDisclosure.tsx";
import { ConfirmationNotice } from "../components/ConfirmationNotice.tsx";
import { AlertDialog } from "../components/ui/alert-dialog.tsx";
import { Button } from "../components/ui/button.tsx";
import { Dialog } from "../components/ui/dialog.tsx";
import { Input } from "../components/ui/input.tsx";
import { AccountIdentity } from "../features/account/AccountIdentity.tsx";
import { ConnectionFailureScreen } from "../features/connection/ConnectionFailureScreen.tsx";
import { accountFeedback } from "../features/account/account-feedback.ts";
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
import { automaticWorkspaceOptionId } from "../features/composer/WorkspaceContextSelector.tsx";
import { createTaskInputHistoryReader } from "../features/composer/input-history.ts";
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
  createTaskPanelWorkspaceTab,
  createTaskPanelReviewTab,
} from "../features/task-panel/task-panel-state.ts";
import {
  WorkspaceFileTree,
  useWorkspaceFileTree,
} from "../features/task-panel/WorkspaceFileTree.tsx";
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
  remainingAttachmentFiles,
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
  reconcileSkillDraft,
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
  McpInstallationProposal,
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
  orderedProjects,
  pendingInputContinuation,
  taskDisplayState,
  taskSignals,
  type SearchResult,
} from "../workbench/selectors.ts";
import { WorkspaceRemovalMenu } from "../features/workspaces/WorkspaceRemovalMenu.tsx";
import { chooseWorkspaceAndMigrateDraft } from "../features/workspaces/chooseWorkspace.ts";
import { initialWorkbenchState, workbenchReducer } from "../workbench/store.ts";
import { navigableTasks } from "../workbench/task-visibility.ts";
import { PendingScopes } from "../workbench/pendingScopes.ts";
import {
  readyModelOptions,
  modelOptionId,
} from "./new-task-model-selection.ts";
import {
  taskModelCandidates,
  taskModelSelectionPolicy,
} from "./task-model-selection.ts";
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
  const [fileTreeOpen, setFileTreeOpen] = useState(false);
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
  const [mcpReview, setMcpReview] = useState<{
    id: string;
    taskId: string;
    runId: string;
    invalidated: boolean;
  } | null>(null);
  const [requestedMcpProposal, setRequestedMcpProposal] = useState<
    string | null
  >(null);
  function reviewMcpProposal(proposal: McpInstallationProposal) {
    setMcpReview({
      id: proposal.id,
      taskId: proposal.taskId,
      runId: proposal.runId,
      invalidated: false,
    });
    setRequestedMcpProposal(proposal.id);
    setRoute("mcp");
  }
  const [mcpQuery, setMcpQuery] = useState("");
  const [renameEditor, setRenameEditor] = useState<{
    taskId: string;
    draft: string;
    message: MessageId | null;
  } | null>(null);
  const renameInput = useRef<HTMLInputElement>(null);
  const renameComposing = useRef(false);
  const [deleteTargetId, setDeleteTargetId] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<MessageId | null>(null);
  const deleteDialogRevision = useRef(0);
  const confirmDelete = deleteTargetId !== null;
  const [fileChanges, setFileChanges] = useState<FileChangesUiState>({
    kind: "closed",
  });
  const fileChangesGeneration = useRef(0);
  const fileChangeRequestGeneration = useRef(0);
  const fileChangeFocusRequest = useRef(0);
  const fileChangeRequestsInFlight = useRef(new Set<string>());
  const [statuses, setStatuses] =
    useState<ShellStatusState>(createFeedbackState);
  const feedbackRef = useRef(statuses);
  const feedbackContext = useRef({
    taskId: null as string | null,
    scope: "",
    route: "workbench" as ShellRoute,
    settingsOpen: false,
  });
  const [stopFeedback, setStopFeedback] = useState<TaskStopFeedback[]>([]);
  const stopFeedbackController = useRef(
    new TaskStopFeedbackController(setStopFeedback),
  );
  const accountFeedbackRequest = useRef({
    serial: 0,
    awaitingSync: false,
    unknown: null as { observation: string | null } | null,
    observed: false,
    attemptId: null as string | null,
    lastObservation: null as string | null,
  });
  const [accountBusy, setAccountBusy] = useState(false);
  const [executionBusy, setExecutionBusy] = useState(false);
  const [workspaceBusy, setWorkspaceBusy] = useState(false);
  const [newTaskApprovalOverride, setNewTaskApprovalOverride] =
    useState<ApprovalMode | null>(null);
  const [newTaskRequestedModel, setNewTaskRequestedModel] =
    useState<ModelRef | null>(null);
  const composerCatalogRefreshPending = useRef(new Set<string>());
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
  const [notificationTarget, setNotificationTarget] = useState<{
    generation: string;
    taskId: string;
  } | null>(null);
  const notificationRequest = useRef(0);
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
  const accountBusyRef = useRef<object | null>(null);
  const executionBusyRef = useRef(false);
  const accountCancelBusyRef = useRef<object | null>(null);
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
  const composerModelTrigger = useRef<HTMLButtonElement>(null);
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
  function updateFeedbackState(
    update: (current: ShellStatusState) => ShellStatusState,
  ) {
    const next = update(feedbackRef.current);
    feedbackRef.current = next;
    setStatuses(next);
  }
  function beginOperationFeedback(source: string, audience: StatusAudience) {
    const started = beginFeedback(feedbackRef.current, source, {
      ...quietStatus("feedback.pending", audience),
      local: true,
    });
    updateFeedbackState(() => started.state);
    return started.token;
  }
  function settleOperationFeedback(
    token: FeedbackToken,
    status: ShellStatus | null,
    diagnosticSecurityEpoch?: string,
  ) {
    updateFeedbackState((current) =>
      settleFeedback(
        current,
        token,
        status
          ? {
              ...status,
              local: true,
              diagnostic:
                diagnosticSecurityEpoch &&
                diagnosticSecurityEpoch ===
                  latestSnapshotRef.current?.securityEpoch
                  ? status.diagnostic
                  : undefined,
            }
          : null,
        Boolean(status && localFeedbackApplicable(token.key, status.audience)),
      ),
    );
  }
  function observeLocalFeedback(source: string, status: ShellStatus | null) {
    updateFeedbackState((current) =>
      observeFeedback(
        current,
        source,
        "result",
        status ? { ...status, local: true } : null,
        Boolean(status && localFeedbackApplicable(source, status.audience)),
      ),
    );
  }
  function localFeedbackApplicable(source: string, audience: StatusAudience) {
    const context = feedbackContext.current;
    if (context.settingsOpen || context.route !== "workbench") return false;
    if (audience.scope === "task") return audience.taskId === context.taskId;
    if (audience.scope === "workspace")
      return source.endsWith(`:${context.scope}`);
    return audience.scope === "execution";
  }
  function observeAccountFeedback(
    account: WorkbenchSnapshot["account"],
    announce: boolean,
    force = false,
  ) {
    if (accountFeedbackRequest.current.awaitingSync) return;
    const observation = JSON.stringify([
      account.errorCode,
      account.safeDiagnostic,
    ]);
    const unknown = accountFeedbackRequest.current.unknown;
    if (unknown) {
      if (unknown.observation === null) {
        unknown.observation = observation;
        return;
      }
      if (unknown.observation === observation) return;
      // A changed recent fact is observable without attributing it to this request.
      accountFeedbackRequest.current.unknown = null;
      force = true;
    }
    if (
      !force &&
      accountFeedbackRequest.current.lastObservation === observation
    )
      return;
    accountFeedbackRequest.current.lastObservation = observation;
    const result = accountFeedback(account);
    updateFeedbackState((current) =>
      observeFeedback(
        current,
        "account:operation",
        "result",
        result
          ? attentionStatus(
              result.id,
              { scope: "account" },
              { diagnostic: result.diagnostic },
            )
          : null,
        announce,
      ),
    );
  }
  function resetFeedbackContext() {
    stopFeedbackController.current.reset();
    taskPendingScopes.current.clear();
    setTaskPending({});
    setTaskArchiveErrors({});
    setArchiveNotice(null);
    setRenameEditor(null);
    deleteDialogRevision.current++;
    setDeleteTargetId(null);
    setDeleteError(null);
    submissionSessions.current.clear();
    setLocalSubmissions((entries) =>
      entries.map((entry) =>
        entry.state === "submitting" || entry.state === "accepted"
          ? { ...entry, state: "unknown" }
          : entry,
      ),
    );
    cancelPendingTasks.current.clear();
    setCancelPending({});
    resetAccountFeedback();
    updateFeedbackState(resetFeedback);
    executionBusyRef.current = false;
    setExecutionBusy(false);
    sourceMutationPending.current = false;
    setSourceMutationBusy(false);
    setSourceMutationError(null);
    skillRefreshPending.current.clear();
    setSkillRefreshRequests({});
  }
  function resetAccountFeedback() {
    accountFeedbackRequest.current = {
      serial: accountFeedbackRequest.current.serial + 1,
      awaitingSync: false,
      unknown: null,
      observed: false,
      attemptId: null,
      lastObservation: null,
    };
    accountBusyRef.current = null;
    accountCancelBusyRef.current = null;
    setAccountBusy(false);
    setAccountCancelBusy(false);
  }
  function invalidateFeedbackSecurity() {
    resetAccountFeedback();
    stopFeedbackController.current.clearDiagnostics();
    updateFeedbackState(clearSecurityFeedback);
  }
  const snapshot = workbench.snapshot;
  const snapshotLoaded = workbench.snapshotReceivedAt !== null;
  useEffect(() => {
    stopFeedbackController.current.observe(snapshot);
  }, [snapshot]);
  const deleteTarget =
    snapshot.taskIndex.find((task) => task.id === deleteTargetId) ?? null;
  useEffect(() => {
    if (snapshotLoaded && deleteTargetId && !deleteTarget)
      setDeleteTargetId(null);
  }, [snapshotLoaded, deleteTargetId, deleteTarget]);
  const noticeTask = snapshot.taskIndex.find(
    (task) => task.id === archiveNotice?.taskId,
  );
  const newTaskApprovalMode =
    newTaskApprovalOverride ?? snapshot.permissions.defaultMode;
  const activeTask = useMemo(() => selectActiveTask(workbench), [workbench]);
  const [taskReadingMemory] = useState(createTaskReadingMemory);
  const [inputHistoryReader] = useState(createTaskInputHistoryReader);
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
      // Closing or invalidating the tab before this frame must not move
      // focus to an unrelated control.
      tab?.focus({
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
    if (active?.kind === "workspace") {
      filePreviewTabs.refreshWorkspace(
        active.taskId,
        active.workspaceId,
        active.workspaceEpoch,
        active.path,
      );
      return;
    }
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
  const panelWorkspace =
    snapshot.workspaces.find(
      (workspace) => workspace.id === panelTask?.workspaceId,
    ) ?? null;
  const taskPanel = useTaskPanelTarget(
    panelTask,
    snapshot.capabilities.typedFileChanges,
    snapshot.taskPage?.runManifest,
    panelWorkspace,
  );
  const previewTabIds = useMemo(
    () =>
      new Set(
        taskPanel.session.tabs.flatMap((tab) =>
          tab.kind !== "review" ? [tab.tabId] : [],
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
    useCallback(
      (
        taskId: string,
        workspaceId: string,
        workspaceEpoch: string,
        path: string,
        options?: import("../bridge/contracts.ts").FilePreviewLoadOptions,
      ) =>
        client.previewWorkspaceFile(
          taskId,
          workspaceId,
          workspaceEpoch,
          path,
          options,
        ),
      [client],
    ),
  );
  const workspaceFilesAvailable = Boolean(
    panelTask &&
    panelTask.lifecycle === "open" &&
    panelTask.deletionStatus === "idle" &&
    panelWorkspace?.authorization === "available" &&
    !panelWorkspace.redacted &&
    bridgeReady &&
    !viewSyncFailed,
  );
  const workspaceTreeScope = workspaceFilesAvailable
    ? JSON.stringify([
        panelTask!.id,
        panelWorkspace!.id,
        panelWorkspace!.epoch,
        snapshot.securityEpoch,
        bridgeGeneration,
      ])
    : null;
  const workspaceTree = useWorkspaceFileTree(
    workspaceTreeScope,
    panelTask?.id ?? null,
    panelWorkspace?.id ?? null,
    panelWorkspace?.epoch ?? null,
    rightPanelOpen && fileTreeOpen && !settingsOpen,
    useCallback(
      (
        taskId: string,
        workspaceId: string,
        workspaceEpoch: string,
        path: string,
        options?: import("../bridge/contracts.ts").FilePreviewLoadOptions,
      ) =>
        client.listWorkspaceDirectory(
          taskId,
          workspaceId,
          workspaceEpoch,
          path,
          options,
        ),
      [client],
    ),
  );
  function openWorkspaceFile(path: string, opener: HTMLButtonElement) {
    if (!workspaceFilesAvailable || !panelTask || !panelWorkspace) return;
    const tab = createTaskPanelWorkspaceTab(
      panelTask.id,
      panelWorkspace.id,
      panelWorkspace.epoch,
      path,
    );
    taskPanelOpeners.current.set(tab.tabId, opener);
    taskPanel.openWorkspace(
      panelTask.id,
      panelWorkspace.id,
      panelWorkspace.epoch,
      path,
    );
    filePreviewTabs.openWorkspace(
      panelTask.id,
      panelWorkspace.id,
      panelWorkspace.epoch,
      path,
    );
    focusTaskPanelTab(tab.tabId);
  }
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
  const projects = useMemo(
    () => orderedProjects(snapshot.workspaces),
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
  useEffect(() => {
    updateFeedbackState((current) => {
      const entries = { ...current.entries };
      let changed = false;
      for (const [key, entry] of Object.entries(entries)) {
        const staleDraft =
          (key.startsWith("workspace:selection:") ||
            key.startsWith("composer-catalog:")) &&
          !key.endsWith(`:${composerDraftScope}`);
        const audience = entry?.audience;
        const removedTask =
          snapshotLoaded &&
          entry?.local &&
          audience?.scope === "task" &&
          !snapshot.taskIndex.some((task) => task.id === audience.taskId);
        if (staleDraft || removedTask) {
          delete entries[key];
          changed = true;
        }
      }
      return changed ? { ...current, entries } : current;
    });
  }, [composerDraftScope, snapshot.taskIndex, snapshotLoaded]);
  feedbackContext.current = {
    taskId: newTaskDraftActive ? null : (activeTask?.id ?? null),
    scope: composerDraftScope,
    route,
    settingsOpen,
  };
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
      (settingsOpen ||
        route !== "workbench" ||
        (snapshotLoaded &&
          (!renameTarget ||
            renameTarget.archived ||
            renameTarget.historyReadOnly ||
            renameTarget.deletionStatus === "deleting")))
    )
      setRenameEditor(null);
  }, [renameEditor, renameTarget, settingsOpen, route, snapshotLoaded]);
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
  const composerWorkspaceLabel =
    composerWorkspace?.canonicalRoot || t("workspace.select");
  const newTaskWorkspaceReady = workbench.draftWorkspaceId
    ? composerWorkspace?.authorization === "available"
    : snapshot.capabilities.automaticWorkspaces;
  const skillCatalog = composerWorkspace?.skillCatalog ?? {
    availability: "unavailable" as const,
    redacted: false,
    revision: null,
    selectionRevision: null,
    skills: [],
    issues: [],
  };
  const currentComposerDraft = reconcileSkillDraft(composerDraft, skillCatalog);
  useEffect(() => {
    inputHistoryReader.clear();
  }, [
    inputHistoryReader,
    bridgeGeneration,
    snapshot.securityEpoch,
    snapshot.historyEpoch,
    workbench.activeTaskId,
    newTaskDraftActive,
  ]);
  useEffect(() => () => inputHistoryReader.clear(), [inputHistoryReader]);
  useEffect(() => {
    if (currentComposerDraft !== composerDraft) {
      composerDraftRef.current = currentComposerDraft;
      updateComposerDraft(currentComposerDraft);
    }
  }, [composerDraft, currentComposerDraft, updateComposerDraft]);
  const skillDraftCurrent =
    composerDraft.kind !== "skill" ||
    isSkillDraftCurrent(composerDraft, skillCatalog);
  const composerRunInput = composerDraftToRunInput(currentComposerDraft);
  const newTaskModelState = newTaskModelSelectionState(
    snapshot.models,
    newTaskRequestedModel,
  );
  const composerContentReady =
    composerDraftHasContent(composerDraft) &&
    composerRunInput !== null &&
    composerDraftWithinLimits(composerDraft) &&
    skillDraftCurrent;
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
    snapshot.newTaskAdmission.available &&
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
  const taskModelOptions = taskModelCandidates(
    snapshot.models,
    taskIntent?.modelRef ?? null,
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
          selected: newTaskRequestedModel ?? snapshot.models.defaultSelection,
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
      snapshot.capabilities.scheduledTaskRecoveryAvailable ||
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
    snapshot.capabilities.scheduledTaskRecoveryAvailable,
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
        {
          const token = beginOperationFeedback("models:catalog", {
            scope: "execution",
          });
          void runExecutionCommand(() => client.refreshModelsCatalog()).then(
            (accepted) =>
              settleOperationFeedback(
                token,
                accepted
                  ? null
                  : attentionStatus("model_setup.catalog_failed", {
                      scope: "execution",
                    }),
              ),
          );
        }
        break;
      case "choose_model":
        composerModelTrigger.current?.focus();
        composerModelTrigger.current?.click();
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
  function notificationUnavailable() {
    updateFeedbackState((current) =>
      observeFeedback(
        current,
        "notification:navigation",
        "result",
        attentionStatus("scheduled.notification_unavailable", {
          scope: "execution",
        }),
      ),
    );
  }
  // Subscribe before connection bootstrap, including a queued native click.
  useEffect(() => {
    if (!client.available()) return;
    return client.onTaskOpen((target) => {
      notificationRequest.current++;
      setNotificationTarget(target);
    }, notificationUnavailable);
  }, [client]);
  useEffect(() => {
    if (!notificationTarget) return;
    if (BigInt(notificationTarget.generation) < BigInt(bridgeGeneration)) {
      setNotificationTarget(null);
      return;
    }
    if (bridgeUnavailable || notificationTarget.generation !== bridgeGeneration)
      return;
    const target = notificationTarget;
    const request = notificationRequest.current;
    setNotificationTarget(null);
    setSettingsOpen(false);
    setModelSetupOpen(false);
    setSearchOpen(false);
    setRoute("workbench");
    pendingTaskSelection.current = target.taskId;
    void refreshSnapshot()
      .then(() => {
        if (
          request !== notificationRequest.current ||
          target.generation !== bridgeGenerationRef.current
        )
          return;
        if (
          !latestSnapshotRef.current?.taskIndex.some(
            (task) => task.id === target.taskId,
          )
        ) {
          pendingTaskSelection.current = null;
          notificationUnavailable();
        } else {
          updateFeedbackState((current) =>
            observeFeedback(current, "notification:navigation", "result", null),
          );
        }
      })
      .catch(() => {
        if (
          request === notificationRequest.current &&
          target.generation === bridgeGenerationRef.current
        ) {
          pendingTaskSelection.current = null;
          // Failed observation belongs to the connection, not notification delivery.
        }
      });
  }, [
    notificationTarget,
    bridgeGeneration,
    bridgeUnavailable,
    refreshSnapshot,
  ]);
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
          if (
            latestSnapshotRef.current &&
            (latestSnapshotRef.current.securityEpoch !== next.securityEpoch ||
              latestSnapshotRef.current.historyEpoch !== next.historyEpoch)
          )
            inputHistoryReader.clear();
          latestSnapshotRef.current = next;
          updateFeedbackState((current) =>
            observeFeedback(
              current,
              "models:preference",
              "condition",
              next.models.errorCode === "preference_not_saved"
                ? attentionStatus("model_setup.preference_not_saved", {
                    scope: "execution",
                  })
                : null,
              accountFeedbackRequest.current.observed,
            ),
          );
          observeAccountFeedback(
            next.account,
            accountFeedbackRequest.current.observed,
          );
          accountFeedbackRequest.current.observed = true;
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
          const status = connectionStatus(next);
          updateFeedbackState((current) =>
            observeFeedback(
              current,
              "connection",
              "condition",
              next.kind === "connected" ? null : status,
            ),
          );
        }
      },
      onReady: (ready) => {
        if (!cancelled) setBridgeReady(ready);
      },
      onSecurityInvalidated: (securityEpoch, generation) => {
        if (cancelled) return;
        inputHistoryReader.clear();
        invalidateFeedbackSecurity();
        latestSnapshotRef.current = null;
        setHistoryRequests({});
        taskReadingMemory.reading.clear();
        taskReadingMemory.processDisclosure.clear();
        taskReadingMemory.toolDisclosure.clear();
        filePreviewTabs.clear();
        clearFileChanges();
        dispatchWorkbench({
          type: "security.invalidated",
          securityEpoch,
          generation,
        });
      },
      onGeneration: (generation) => {
        if (!cancelled) {
          inputHistoryReader.clear();
          resetFeedbackContext();
          setHistoryRequests({});
          taskReadingMemory.reading.clear();
          taskReadingMemory.processDisclosure.clear();
          taskReadingMemory.toolDisclosure.clear();
          bridgeGenerationRef.current = generation;
          approvalRequestsRef.current.reset(generation);
          latestSnapshotRef.current = null;
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
    if (tab.kind !== "review") filePreviewTabs.close(tabId);
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
    deleteDialogRevision.current++;
    setDeleteError(null);
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
    deleteDialogRevision.current++;
    setDeleteError(null);
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
  function endTaskPendingOperation(scope: string, generation: string) {
    if (generation !== bridgeGenerationRef.current) return;
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
    invoke: () => Promise<
      import("../bridge/contracts.ts").AccountCommandResult
    >,
    cancelling = false,
  ) {
    if (
      bridgeUnavailable ||
      (cancelling ? accountCancelBusyRef.current : accountBusyRef.current)
    )
      return false;
    const pending = {};
    if (cancelling) {
      accountCancelBusyRef.current = pending;
      setAccountCancelBusy(true);
    } else {
      accountBusyRef.current = pending;
      setAccountBusy(true);
    }
    const request = ++accountFeedbackRequest.current.serial;
    const epoch = feedbackRef.current.epoch;
    const current = () =>
      request === accountFeedbackRequest.current.serial &&
      epoch === feedbackRef.current.epoch;
    accountFeedbackRequest.current.awaitingSync = true;
    accountFeedbackRequest.current.unknown = null;
    let token: FeedbackToken;
    function startCycle(id: ShellStatus["id"]) {
      const started = beginFeedback(
        feedbackRef.current,
        "account:operation",
        quietStatus(id, { scope: "account" }),
      );
      token = started.token;
      updateFeedbackState(() => started.state);
    }
    startCycle("account.feedback.sending");
    try {
      const result = await invoke();
      if (!current()) return false;
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        if (!current()) return false;
        accountFeedbackRequest.current.awaitingSync = false;
        if (latestSnapshotRef.current)
          observeAccountFeedback(
            latestSnapshotRef.current.account,
            false,
            true,
          );
        startCycle("account.feedback.sending");
        updateFeedbackState((state) =>
          settleFeedback(
            state,
            token,
            attentionStatus(
              result.errorCode === "generation_mismatch"
                ? "account.options_updated"
                : "account.command_rejected",
              { scope: "account" },
            ),
          ),
        );
        return false;
      }
      accountFeedbackRequest.current.attemptId = result.attemptId;
      accountFeedbackRequest.current.lastObservation = null;
      startCycle("account.feedback.received");
      try {
        await refreshSnapshot();
        if (!current()) return false;
        accountFeedbackRequest.current.awaitingSync = false;
        if (latestSnapshotRef.current)
          observeAccountFeedback(latestSnapshotRef.current.account, true, true);
      } catch {
        // Acceptance remains acceptance. The connection owns the sync failure.
        if (current()) accountFeedbackRequest.current.awaitingSync = false;
      }
      return true;
    } catch {
      if (!current()) return false;
      accountFeedbackRequest.current.awaitingSync = false;
      const observedAccount = latestSnapshotRef.current?.account;
      accountFeedbackRequest.current.unknown = {
        observation: observedAccount
          ? JSON.stringify([
              observedAccount.errorCode,
              observedAccount.safeDiagnostic,
            ])
          : accountFeedbackRequest.current.lastObservation,
      };
      updateFeedbackState((state) =>
        settleFeedback(
          state,
          token,
          attentionStatus("account.feedback.unknown", { scope: "account" }),
        ),
      );
      await refreshSnapshot().catch(() => undefined);
      return false;
    } finally {
      if (
        (cancelling ? accountCancelBusyRef.current : accountBusyRef.current) ===
        pending
      ) {
        if (cancelling) {
          accountCancelBusyRef.current = null;
          setAccountCancelBusy(false);
        } else {
          accountBusyRef.current = null;
          setAccountBusy(false);
        }
      }
    }
  }
  async function openAccountRecharge() {
    if (bridgeUnavailable || accountBusyRef.current) return;
    const pending = {};
    accountBusyRef.current = pending;
    setAccountBusy(true);
    const started = beginFeedback(
      feedbackRef.current,
      "account:recharge",
      quietStatus("account.feedback.sending", { scope: "account" }),
    );
    updateFeedbackState(() => started.state);
    const finish = (failed: boolean) =>
      updateFeedbackState((state) =>
        settleFeedback(
          state,
          started.token,
          failed
            ? attentionStatus("account.recharge_open_failed", {
                scope: "account",
              })
            : null,
        ),
      );
    try {
      const result = await client.openAccountRecharge();
      finish(!result.accepted);
    } catch {
      finish(true);
    } finally {
      if (accountBusyRef.current === pending) {
        accountBusyRef.current = null;
        setAccountBusy(false);
      }
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
    const generation = bridgeGenerationRef.current;
    try {
      const result = await invoke();
      if (generation !== bridgeGenerationRef.current) return false;
      await refreshCommittedView();
      return generation === bridgeGenerationRef.current && result.accepted;
    } catch {
      if (generation === bridgeGenerationRef.current)
        await refreshCommittedView();
      return false;
    } finally {
      if (generation === bridgeGenerationRef.current) {
        executionBusyRef.current = false;
        setExecutionBusy(false);
      }
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
      if (
        result.outcome === "completed" ||
        (result.outcome === "failed" &&
          latestSnapshotRef.current?.tasks.find(
            (task) => task.id === result.taskId,
          )?.approvalResult?.outcome === "failed")
      )
        observeLocalFeedback(`permission:${result.taskId}`, null);
      else if (result.outcome === "failed" && result.reason)
        observeLocalFeedback(
          `permission:${result.taskId}`,
          attentionStatus(
            `permission.change.failure.${result.reason}`,
            audience,
          ),
        );
      else
        observeLocalFeedback(
          `permission:${result.taskId}`,
          attentionStatus("permission.change.not_confirmed", audience),
        );
    }
  }
  async function setTaskApprovalMode(targetMode: ApprovalMode) {
    const task = activeTask;
    if (!task || bridgeUnavailable) return;
    const requests = approvalRequestsRef.current;
    const intent = requests.begin(task, targetMode);
    if (!intent) return;
    const feedbackToken = beginOperationFeedback(`permission:${task.id}`, {
      scope: "task",
      taskId: task.id,
    });
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
        settleOperationFeedback(
          feedbackToken,
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
      /* The connection owns failed observation. */
    }
  }
  async function selectModelForTask(selectionId: string) {
    const task = activeTask;
    const option = taskModelOptions.find(
      (option) => option.selectionId === selectionId,
    );
    if (!task || !option || bridgeUnavailable) return;
    const generation = bridgeGenerationRef.current;
    const scope = `task:${task.id}`;
    if (!beginTaskPendingOperation(scope, "model")) return;
    const feedbackToken = beginOperationFeedback(`task-model:${task.id}`, {
      scope: "task",
      taskId: task.id,
    });
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
        settleOperationFeedback(
          feedbackToken,
          attentionStatus(mutationReasonMessageId(result.reason), {
            scope: "task",
            taskId: task.id,
          }),
        );
        return;
      }
      settleOperationFeedback(feedbackToken, null);
      await refreshCommittedView();
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      settleOperationFeedback(
        feedbackToken,
        attentionStatus(
          "feedback.unconfirmed",
          {
            scope: "task",
            taskId: task.id,
          },
          {
            diagnostic: errorText(error),
            values: { operation: t("operation.execution") },
          },
        ),
        snapshot.securityEpoch,
      );
    } finally {
      endTaskPendingOperation(scope, generation);
    }
  }
  async function cancelAccountOperation() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      accountCancelBusyRef.current ||
      !snapshot.account.canCancel
    )
      return;
    await runAccountCommand(() => client.cancelAccountOperation(), true);
  }
  async function chooseWorkspaceForDraft() {
    if (workbenchMutationDisabled || workspaceBusyRef.current) return null;
    const requestedAudience = attachmentAudience.current;
    const scope = composerDraftScope;
    const token = beginOperationFeedback(`workspace:selection:${scope}`, {
      scope: "workspace",
      workspaceId: composerWorkspaceId ?? null,
    });
    const current = () => attachmentAudience.current === requestedAudience;
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
        current,
      });
      if (!current()) {
        settleOperationFeedback(token, null);
        return null;
      }
      if (outcome.kind === "superseded" || outcome.kind === "sync_failed") {
        settleOperationFeedback(token, null);
        return null;
      }
      if (outcome.kind === "selected") {
        const { result } = outcome;
        dispatchWorkbench({
          type: "task.draft.opened",
          workspaceId: result.workspaceId,
        });
        settleOperationFeedback(token, null);
        window.requestAnimationFrame(() => composer.current?.focus());
        return result;
      }
      settleOperationFeedback(token, null);
      window.requestAnimationFrame(() => composer.current?.focus());
      return null;
    } catch (error) {
      if (!current()) {
        settleOperationFeedback(token, null);
        return null;
      }
      settleOperationFeedback(
        token,
        attentionStatus(
          "workspace.selection_failed",
          { scope: "workspace", workspaceId: null },
          {
            diagnostic: errorText(error),
          },
        ),
        snapshot.securityEpoch,
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
      workspace.projectRemoved ||
      workspace.authorization !== "available"
    ) {
      const token = beginOperationFeedback(
        `workspace:selection:${composerDraftScope}`,
        { scope: "workspace", workspaceId: composerWorkspaceId ?? null },
      );
      settleOperationFeedback(
        token,
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
    const submitted = reconcileSkillDraft(
      composerDraftRef.current,
      skillCatalog,
    );
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
      if (!taskId && !newTaskModelState.intent) return;
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
            newTaskModelState.intent!,
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
    if (
      result.kind === "create_rejected" &&
      session.canReleaseAfterCreationRejection &&
      submissionSessions.current.get(key) === session
    )
      submissionSessions.current.delete(key);
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
    const requestedDraft = target.currentDraft(targetId);
    if (!requestedDraft) return;
    const maxFiles = snapshot.capabilities.attachments.maxFiles;
    const remainingFiles = remainingAttachmentFiles(requestedDraft, maxFiles);
    const selectedCount = input
      ? "files" in input
        ? input.files.length
        : input.paths.length
      : null;
    if (
      remainingFiles === 0 ||
      (selectedCount !== null && selectedCount > remainingFiles)
    ) {
      setAttachmentError("too_many_files");
      return;
    }
    let add: AttachmentAddOperation;
    try {
      add = client.createAttachmentAdd(async () => {
        if (requestedGeneration !== bridgeGenerationRef.current) return;
        taskDrafts.invalidateAttachments();
        newTaskDrafts.invalidateAttachments();
        await retryViewSynchronization(true, requestedGeneration);
      }, remainingFiles);
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
      if (
        result.attachments.length > remainingAttachmentFiles(current, maxFiles)
      ) {
        const cleanup = await add.cancel();
        if (currentOperation())
          setAttachmentError(
            cleanup.status === "cleanup_failed"
              ? "cleanup_failed"
              : "too_many_files",
          );
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
    const scope = composerDraftScope;
    const generation = bridgeGenerationRef.current;
    const diagnosticSecurityEpoch = snapshot.securityEpoch;
    const controller = stopFeedbackController.current;
    if (controller.pending(scope, taskId ? activeTask : null)) return;
    const session = submissionSessions.current.get(`${generation}:${scope}`);
    if (!taskId && !session) return;
    if (taskId && cancelPendingTasks.current.has(taskId)) return;
    if (taskId) setCancelPendingForTask(taskId, true);
    const token = controller.begin(
      scope,
      taskId
        ? (latestSnapshotRef.current?.tasks.find(
            (task) => task.id === taskId,
          ) ?? null)
        : null,
      localSubmissionsRef.current
        .filter(
          (entry) =>
            entry.scope === scope &&
            entry.generation === generation &&
            ["submitting", "accepted", "unknown"].includes(entry.state),
        )
        .map((entry) => entry.operationId),
    );
    const current = () => bridgeGenerationRef.current === generation;
    const target = (id: string) => {
      if (current()) controller.target(token, id);
    };
    try {
      let localOnly = false;
      try {
        if (session) ({ localOnly } = await session.stop(target));
        else if (taskId) {
          await client.stopTask(taskId);
          setMcpReview((current) =>
            current?.taskId === taskId &&
            current.runId === activeTask?.currentRunId
              ? { ...current, invalidated: true }
              : current,
          );
        }
      } catch (error) {
        if (!current()) return;
        controller.settle(
          token,
          error instanceof BridgeCommandTimeoutError ? "unknown" : "failed",
          diagnosticSecurityEpoch === latestSnapshotRef.current?.securityEpoch
            ? errorText(error)
            : undefined,
        );
        await refreshSnapshot().catch(() => undefined);
        return;
      }
      if (!current()) return;
      if (token.taskId && !localOnly) controller.settle(token, "awaiting");
      else controller.retire(token);
      await refreshSnapshot().catch(() => undefined);
    } finally {
      if (current() && taskId) setCancelPendingForTask(taskId, false);
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
    const generation = bridgeGenerationRef.current;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "compact")) return;
    const feedbackToken = beginOperationFeedback(`compact:${taskId}`, {
      scope: "task",
      taskId,
    });
    try {
      try {
        const result = await client.compact(taskId, activeTask.binding.epoch);
        if (!result.accepted) {
          await refreshSnapshot().catch(() => undefined);
          settleOperationFeedback(
            feedbackToken,
            attentionStatus(mutationReasonMessageId(result.reason), {
              scope: "task",
              taskId,
            }),
          );
          return;
        }
      } catch (error) {
        if (error instanceof BridgeCommandTimeoutError) {
          settleOperationFeedback(
            feedbackToken,
            attentionStatus(
              "feedback.unconfirmed",
              { scope: "task", taskId },
              {
                values: { operation: t("operation.compact") },
                diagnostic: errorText(error),
              },
            ),
            snapshot.securityEpoch,
          );
          await refreshCommittedView();
          return;
        }
        await refreshSnapshot().catch(() => undefined);
        settleOperationFeedback(
          feedbackToken,
          attentionStatus(
            "compact.start_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
          snapshot.securityEpoch,
        );
        return;
      }
      settleOperationFeedback(feedbackToken, null);
      await refreshCommittedView();
    } finally {
      endTaskPendingOperation(scope, generation);
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
    const confirmed =
      descriptor && skillCatalog.revision === input.catalogRevision;
    return {
      kind: "skill",
      skillId: input.skillId,
      ...(confirmed ? { skillPolicyKey: descriptor.skillPolicyKey } : {}),
      invocationName: input.invocationName,
      displayName: input.displayName,
      catalogRevision: input.catalogRevision,
      selectionRevision: skillCatalog.selectionRevision ?? "0",
      argumentNames: confirmed ? descriptor.argumentNames : [],
      argumentValues: input.argumentValues,
      maxValues: confirmed
        ? Math.min(descriptor.maxValues, maxSkillArguments)
        : maxSkillArguments,
    };
  }
  async function refreshComposerSkillCatalog() {
    if (bridgeUnavailable || !composerWorkspace || !composerWorkspaceId) return;
    const key = `${bridgeGenerationRef.current}:${composerWorkspaceId}:${composerWorkspace.epoch}`;
    if (composerCatalogRefreshPending.current.has(key)) return;
    composerCatalogRefreshPending.current.add(key);
    const audience: StatusAudience = {
      scope: "workspace",
      workspaceId: composerWorkspaceId,
    };
    const feedbackToken = beginOperationFeedback(
      `composer-catalog:${composerDraftScope}`,
      audience,
    );
    try {
      const result = await client.refreshWorkspaceSkillCatalog(
        composerWorkspaceId,
        composerWorkspace.epoch,
      );
      if (!result.accepted && result.reason !== "catalog_loading") {
        settleOperationFeedback(
          feedbackToken,
          attentionStatus(mutationReasonMessageId(result.reason!), audience),
        );
        return;
      }
      settleOperationFeedback(feedbackToken, null);
      await refreshCommittedView();
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      settleOperationFeedback(
        feedbackToken,
        attentionStatus("slash.catalog_refresh_failed", audience, {
          diagnostic: errorText(error),
        }),
        snapshot.securityEpoch,
      );
    } finally {
      composerCatalogRefreshPending.current.delete(key);
    }
  }
  async function refreshSkillsPageCatalog(target: SkillRefreshTarget) {
    const generation = bridgeGenerationRef.current;
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
      await refreshCommittedView();
    } catch {
      await refreshSnapshot().catch(() => undefined);
      failure = t("skills.catalog_refresh_failed");
    } finally {
      if (generation === bridgeGenerationRef.current) {
        skillRefreshPending.current.delete(key);
        setSkillRefreshRequests((requests) => ({
          ...requests,
          [key]: { busy: false, error: failure },
        }));
      }
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
    const generation = bridgeGenerationRef.current;
    try {
      const result = await mutation();
      if (generation !== bridgeGenerationRef.current) return;
      if (!result.applied)
        setSourceMutationError(t(`skills.sources.failure.${result.reason}`));
      // Failed commands can also change health and recovery capabilities.
      await refreshCommittedView();
    } catch {
      if (generation !== bridgeGenerationRef.current) return;
      await refreshSnapshot().catch(() => undefined);
      if (generation === bridgeGenerationRef.current)
        setSourceMutationError(t("skills.sources.uncertain"));
    } finally {
      if (generation === bridgeGenerationRef.current) {
        sourceMutationPending.current = false;
        setSourceMutationBusy(false);
      }
    }
  }
  async function commitSkillMutation(
    mutation: () => Promise<SkillMutationResult>,
  ): Promise<SkillMutationResult> {
    try {
      return await mutation();
    } finally {
      await refreshCommittedView();
    }
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
  async function commitScheduleMutation<T>(
    mutation: () => Promise<T>,
  ): Promise<T> {
    try {
      const result = await mutation();
      await refreshCommittedView();
      return result;
    } catch (error) {
      await refreshCommittedView();
      throw error;
    }
  }
  async function commitMcpMutation<T extends McpMutationResult>(
    mutation: () => Promise<T>,
  ): Promise<T> {
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
  async function applyMcpConfiguration(
    serverId?: string,
  ): Promise<McpConfigurationApplyResult> {
    try {
      const result = await client.applyMcpConfiguration(serverId);
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
    const generation = bridgeGenerationRef.current;
    try {
      try {
        await client.renameTask(taskId, editor.draft.trim());
      } catch (error) {
        if (await refreshAfterTimeout(error)) {
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
      await refreshCommittedView();
    } finally {
      endTaskPendingOperation(scope, generation);
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
    const generation = bridgeGenerationRef.current;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "archive")) return;
    const feedbackToken = beginOperationFeedback(`task-archive:${taskId}`, {
      scope: "task",
      taskId,
    });
    const current = () => generation === bridgeGenerationRef.current;
    setTaskArchiveErrors((current) => ({ ...current, [taskId]: "" }));
    try {
      try {
        await client.setTaskArchived(task.id, archived);
        if (!current()) return;
      } catch (error) {
        if (!current()) return;
        if (await refreshAfterTimeout(error)) {
          if (!current()) return;
          publishArchiveResult(taskId, archived);
          if (
            latestSnapshotRef.current?.taskIndex.find(
              (item) => item.id === taskId,
            )?.archived !== archived
          ) {
            setTaskArchiveErrors((current) => ({
              ...current,
              [taskId]: t("task.archive_unconfirmed"),
            }));
            if (archived)
              setArchiveNotice({
                id: ++archiveNoticeId.current,
                taskId,
                kind: "unconfirmed",
              });
          }
          settleOperationFeedback(
            feedbackToken,
            quietStatus(
              "task.archive_unconfirmed",
              { scope: "task", taskId },
              { diagnostic: errorText(error) },
            ),
            snapshot.securityEpoch,
          );
          return;
        }
        if (archived)
          setArchiveNotice({
            id: ++archiveNoticeId.current,
            taskId,
            kind: "failed",
          });
        await refreshSnapshot().catch(() => undefined);
        if (!current()) return;
        setTaskArchiveErrors((current) => ({
          ...current,
          [taskId]: t(archived ? "task.archive_failed" : "task.restore_failed"),
        }));
        settleOperationFeedback(
          feedbackToken,
          quietStatus(
            archived ? "task.archive_failed" : "task.restore_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
          snapshot.securityEpoch,
        );
        return;
      }
      await refreshCommittedView();
      if (!current()) return;
      publishArchiveResult(taskId, archived);
      settleOperationFeedback(feedbackToken, null);
    } finally {
      endTaskPendingOperation(scope, generation);
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
    const feedbackToken = beginOperationFeedback(`task-delete:${taskId}`, {
      scope: "task",
      taskId,
    });
    const dialogRevision = deleteDialogRevision.current;
    const generation = bridgeGenerationRef.current;
    const current = () =>
      generation === bridgeGenerationRef.current &&
      dialogRevision === deleteDialogRevision.current;
    setDeleteError(null);
    try {
      try {
        await client.deleteTask(task.id);
        setMcpReview((current) =>
          current?.taskId === task.id
            ? { ...current, invalidated: true }
            : current,
        );
      } catch (error) {
        if (await refreshAfterTimeout(error)) {
          if (current()) setDeleteError("task.delete_unconfirmed");
          settleOperationFeedback(
            feedbackToken,
            quietStatus(
              "task.delete_unconfirmed",
              { scope: "task", taskId },
              { diagnostic: errorText(error) },
            ),
            snapshot.securityEpoch,
          );
          return;
        }
        await refreshSnapshot().catch(() => undefined);
        if (current()) setDeleteError("task.delete_failed");
        settleOperationFeedback(
          feedbackToken,
          quietStatus(
            "task.delete_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
          snapshot.securityEpoch,
        );
        return;
      }
      if (current()) setDeleteTargetId(null);
      settleOperationFeedback(feedbackToken, null);
      await refreshCommittedView();
    } finally {
      endTaskPendingOperation(scope, generation);
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
    if (!beginUiResponse(identity)) return;
    try {
      await client.respondUi(
        activeTask.id,
        pending.runId,
        pending.requestId,
        payload,
      );
    } catch {
      failUiResponse(identity);
      await refreshSnapshot().catch(() => undefined);
      return;
    }
    acceptUiResponse(identity);
    await refreshCommittedView();
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
    const audience = attachmentAudience.current;
    const focusPreparedInput = () =>
      window.requestAnimationFrame(() => {
        if (attachmentAudience.current === audience) composer.current?.focus();
      });
    if (input.kind === "skill") {
      if (composerDraftHasContent(composerDraft)) {
        observeLocalFeedback(
          `prepare-retry:${activeTask.id}`,
          quietStatus("run.draft_preserved", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
      } else {
        const reusable = composerDraftFromRunInput(input);
        if (reusable) {
          updateComposerDraft(reusable);
          observeLocalFeedback(
            `prepare-retry:${activeTask.id}`,
            quietStatus("run.retry_prepared", {
              scope: "task",
              taskId: activeTask.id,
            }),
          );
        } else {
          observeLocalFeedback(
            `prepare-retry:${activeTask.id}`,
            attentionStatus("mutation.reason.stale_catalog", {
              scope: "task",
              taskId: activeTask.id,
            }),
          );
        }
      }
      focusPreparedInput();
      return;
    }
    if (input.kind === "multimodal") {
      if (composerDraftHasContent(composerDraft)) {
        observeLocalFeedback(
          `prepare-retry:${activeTask.id}`,
          quietStatus("run.draft_preserved", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
      } else {
        const reusable = composerDraftFromRunInput(input);
        if (reusable) updateComposerDraft(reusable);
        observeLocalFeedback(
          `prepare-retry:${activeTask.id}`,
          quietStatus("run.retry_prepared", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
      }
      focusPreparedInput();
      return;
    }
    const prepared = prepareRetryDraft(composerDraft, input.text);
    switch (prepared.kind) {
      case "prepared":
        updateComposerDraft(prepared.draft);
        observeLocalFeedback(
          `prepare-retry:${activeTask.id}`,
          quietStatus("run.retry_prepared", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
        break;
      case "preserved":
        observeLocalFeedback(
          `prepare-retry:${activeTask.id}`,
          quietStatus("run.draft_preserved", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
        break;
      case "too_long":
        observeLocalFeedback(
          `prepare-retry:${activeTask.id}`,
          attentionStatus("run.retry_too_long", {
            scope: "task",
            taskId: activeTask.id,
          }),
        );
        break;
    }
    focusPreparedInput();
  }
  async function refreshAfterTimeout(error: unknown) {
    if (!(error instanceof BridgeCommandTimeoutError)) return false;
    await refreshCommittedView();
    return true;
  }
  const connectionShellStatus = statuses.entries.connection;
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
  const commandBarFeedback = selectCommandBarFeedback(statuses);
  if (
    connectionBusy &&
    connectionShellStatus &&
    !commandBarFeedback.includes(connectionShellStatus)
  )
    commandBarFeedback.unshift(connectionShellStatus);
  const commandBarStatus = commandBarFeedback[0] ?? null;
  const accountFeedbackEntries = Object.values(statuses.entries).flatMap(
    (entry) =>
      entry && entry.audience.scope === "account" && !entry.dismissed
        ? [entry]
        : [],
  );
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
  const currentStopFeedback = stopFeedback.find((entry) =>
    newTaskDraftActive
      ? entry.scope === composerDraftScope
      : entry.taskId === activeTask?.id,
  );
  const stopRequestPending = stopFeedbackController.current.pending(
    composerDraftScope,
    newTaskDraftActive ? null : activeTask,
  );
  const workspaceSelectionFeedback =
    statuses.entries[`workspace:selection:${composerDraftScope}`];
  const taskOperationFeedback = Object.values(statuses.entries).filter(
    (entry) =>
      entry?.local &&
      entry.audience.scope === "task" &&
      entry.audience.taskId === activeTask?.id,
  );
  const composerCatalogFeedback =
    statuses.entries[`composer-catalog:${composerDraftScope}`];
  const modelsCatalogFeedback = statuses.entries["models:catalog"];
  const historyTaskId = newTaskDraftActive ? null : activeTask?.id;
  function composerHistoryIsCurrent() {
    const latest = latestSnapshotRef.current;
    return Boolean(
      historyTaskId &&
      composerDraftScopeRef.current === composerDraftScope &&
      bridgeGenerationRef.current === bridgeGeneration &&
      latest?.securityEpoch === snapshot.securityEpoch &&
      latest?.historyEpoch === snapshot.historyEpoch &&
      latest?.taskIndex.some(
        (task) =>
          task.id === historyTaskId &&
          !task.archived &&
          task.lifecycle === "open" &&
          task.deletionStatus !== "deleting",
      ),
    );
  }
  const composerInputHistory =
    historyTaskId && !bridgeUnavailable
      ? {
          currentDraft: () =>
            composerHistoryIsCurrent()
              ? taskDrafts.currentDraft(historyTaskId)
              : null,
          commitDraft: (draft: ComposerDraft) =>
            composerHistoryIsCurrent() &&
            taskDrafts.commitDraft(historyTaskId, draft),
          load: () => {
            const initial = latestSnapshotRef.current;
            const draft = taskDrafts.currentDraft(historyTaskId);
            if (!initial || !draft)
              return Promise.reject(new Error("Input history unavailable"));
            return inputHistoryReader.load(
              initial,
              historyTaskId,
              (scope) => client.fetchSnapshot(scope),
              () =>
                composerHistoryIsCurrent() &&
                taskDrafts.currentDraft(historyTaskId) === draft,
            );
          },
        }
      : undefined;
  const composerFooter = (
    <>
      {[
        ...taskOperationFeedback,
        composerCatalogFeedback,
        modelsCatalogFeedback,
      ].map((entry) =>
        entry && entry.tone === "attention" && !entry.dismissed ? (
          <FeedbackNotice
            key={`${statuses.epoch}:${entry.key}:${entry.cycle}`}
            title={t(entry.id, entry.values)}
            detailsLabel={t("feedback.details")}
            dismissLabel={t("feedback.dismiss")}
            onDismiss={() => {
              updateFeedbackState((current) =>
                dismissFeedback(current, entry.key, entry.cycle),
              );
              window.requestAnimationFrame(() => composer.current?.focus());
            }}
          />
        ) : null,
      )}
      {workspaceSelectionFeedback?.tone === "attention" &&
        !workspaceSelectionFeedback.dismissed && (
          <p
            className="projection-note workspace-selection-feedback"
            role="status"
          >
            {t(
              workspaceSelectionFeedback.id,
              workspaceSelectionFeedback.values,
            )}
          </p>
        )}
      {currentStopFeedback &&
        !(
          stopRequestPending &&
          currentStopFeedback.runId === activeTask?.currentRunId &&
          activeTask?.currentRunPhase
        ) && (
          <p className="projection-note task-stop-feedback" role="status">
            {t(
              currentStopFeedback.phase === "requesting" ||
                currentStopFeedback.phase === "awaiting"
                ? "run.activity.requesting_stop"
                : currentStopFeedback.phase === "failed"
                  ? "run.stop_failed"
                  : "run.stop_unconfirmed",
            )}
          </p>
        )}
      {activeTask && (
        <ConversationContext key={activeTask.id} context={activeTask.context} />
      )}
      <ComposerFooter
        modelTriggerRef={composerModelTrigger}
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
        draft={currentComposerDraft}
        draftScope={`${bridgeGeneration}:${snapshot.securityEpoch}:${snapshot.historyEpoch}:${composerDraftScope}`}
        inputHistory={composerInputHistory}
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
        workspaceLabel={composerWorkspaceLabel}
        workspaceTitle={composerWorkspaceLabel}
        workspaceDiagnostic={
          [
            workspaceSelectionFeedback?.diagnostic,
            composerCatalogFeedback?.diagnostic,
          ]
            .filter(Boolean)
            .join("\n\n") || undefined
        }
        workspaceOptions={[
          {
            id: automaticWorkspaceOptionId,
            label: t("workspace.automatic_directory"),
            triggerLabel: t("workspace.select"),
            authorization: "available" as const,
            disabled: !snapshot.capabilities.automaticWorkspaces,
          },
          ...projects.map((workspace) => ({
            id: workspace.id,
            label: workspace.displayName || workspace.canonicalRoot,
            authorization: workspace.authorization,
          })),
        ]}
        selectedWorkspaceOptionId={
          newTaskDraftActive
            ? (composerWorkspace?.id ?? automaticWorkspaceOptionId)
            : ""
        }
        workspaceEditable={newTaskDraftActive}
        workspaceSelectionPending={taskIdentityPending}
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
                  ? undefined
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
          <>
            {setupNotice && (
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
            )}
          </>
        }
        actionDisabled={workbenchMutationDisabled || workspaceBusy}
        stopAction={
          taskOperationInFlight || localSubmissionCount > 0 ? "run" : null
        }
        stopDisabled={
          bridgeUnavailable ||
          stopRequestPending ||
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
    taskPanel.activeTab && taskPanel.activeTab.kind !== "review"
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
    panelTarget.kind !== "empty" &&
    activePreview !== undefined &&
    panelTarget.taskId === activePreview.taskId &&
    ((panelTarget.kind === "preview" &&
      panelTarget.runId === activePreview.runId &&
      panelTarget.referenceId === activePreview.reference.id) ||
      (panelTarget.kind === "workspace" &&
        panelTarget.workspaceId === activePreview.workspaceId &&
        panelTarget.workspaceEpoch === activePreview.workspaceEpoch &&
        panelTarget.path === activePreview.reference.displayPath));
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
                workspace={composerWorkspace}
                workspaceOpenDisabled={workbenchMutationDisabled}
                onOpenWorkspace={
                  composerWorkspace
                    ? () =>
                        client.openWorkspace(
                          composerWorkspace.id,
                          composerWorkspace.epoch,
                        )
                    : undefined
                }
                workspaceDiagnostic={composerCatalogFeedback?.diagnostic}
                permissionProfilesEnabled={
                  snapshot.capabilities.permissionProfiles
                }
                triggerRef={taskInformationTrigger}
                diagnostics={
                  taskOperationFeedback.some((entry) => entry?.diagnostic) ||
                  currentStopFeedback?.diagnostic ? (
                    <DiagnosticDisclosure
                      label={t("task.operation_diagnostics")}
                    >
                      {currentStopFeedback?.diagnostic && (
                        <pre className="feedback-notice-details">
                          {currentStopFeedback.diagnostic}
                        </pre>
                      )}
                      {taskOperationFeedback.map((entry) =>
                        entry?.diagnostic ? (
                          <pre
                            className="feedback-notice-details"
                            key={entry.key}
                          >
                            {entry.diagnostic}
                          </pre>
                        ) : null,
                      )}
                    </DiagnosticDisclosure>
                  ) : null
                }
              />
            )}
          </>
        ) : null
      }
      onSearch={() => setSearchOpen(true)}
      attentionNotice={
        commandBarFeedback.length > 1
          ? t("feedback.open", { count: String(commandBarFeedback.length) })
          : connectionBusy
            ? t("connection.sync_retrying")
            : commandBarStatus
              ? commandBarStatus.audience.scope === "account"
                ? t("feedback.account")
                : t(commandBarStatus.id, commandBarStatus.values)
              : null
      }
      attentionAnnouncement={
        statuses.announcement
          ? {
              key: statuses.announcement.sequence,
              text: t(
                statuses.announcement.status.id,
                statuses.announcement.status.values,
              ),
            }
          : null
      }
      attentionBusy={connectionBusy}
      attentionContent={
        <div className="feedback-list">
          {commandBarFeedback.map((entry) =>
            entry.audience.scope === "account" ? (
              <Button
                key={entry.key}
                type="button"
                variant="secondary"
                size="sm"
                onClick={() => openSettings("account")}
              >
                {t("feedback.account")}
              </Button>
            ) : (
              <FeedbackNotice
                key={`${statuses.epoch}:${entry.key}:${entry.cycle}`}
                title={t(entry.id, entry.values)}
                message={
                  entry.audience.scope === "connection" && !connectionBusy
                    ? t(connectionFailurePresentation(entry).helpId)
                    : undefined
                }
                diagnostic={
                  entry.diagnostic
                    ? `${entry.sourceId ? `${t(entry.sourceId)}: ` : ""}${entry.diagnostic}`
                    : undefined
                }
                detailsLabel={t("feedback.details")}
                dismissLabel={t("feedback.dismiss")}
                onDismiss={
                  entry.key === "models:preference"
                    ? () =>
                        updateFeedbackState((current) =>
                          dismissFeedback(current, entry.key, entry.cycle),
                        )
                    : undefined
                }
                pending={
                  entry.audience.scope === "connection" && connectionBusy
                }
                actions={
                  entry.audience.scope === "connection" &&
                  connectionFailurePresentation(entry).retryable ? (
                    <Button
                      type="button"
                      variant="secondary"
                      size="sm"
                      disabled={connectionBusy}
                      onClick={() => void retryViewSynchronization()}
                    >
                      {t("connection.retry_sync")}
                    </Button>
                  ) : undefined
                }
              />
            ),
          )}
        </div>
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
                key={bridgeGeneration}
                tasks={navigableTaskItems}
                workspaces={snapshot.workspaces}
                activeTaskId={
                  route === "workbench" ? workbench.activeTaskId : null
                }
                suppressedCompletionTaskId={suppressedCompletionTaskId}
                onSelectTask={openTask}
                onTaskAction={handleTaskAction}
                renderWorkspaceHeading={(workspace, heading) => (
                  <WorkspaceRemovalMenu
                    workspace={workspace}
                    openDisabled={workbenchMutationDisabled}
                    onNewTask={() => {
                      beginNewTask();
                      setDraftWorkspaceById(workspace.id);
                    }}
                    onOpen={() =>
                      client.openWorkspace(workspace.id, workspace.epoch)
                    }
                    onRemove={async () => {
                      try {
                        const result = await client.removeProject(
                          workspace.id,
                          workspace.epoch,
                        );
                        return result.accepted;
                      } finally {
                        await refreshSnapshot();
                      }
                    }}
                  >
                    {heading}
                  </WorkspaceRemovalMenu>
                )}
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

            updates={snapshot.updates}
            updateControls={{
              disabled: bridgeUnavailable,
              generation: bridgeGeneration,
              check: async () => {
                const result = await client.checkUpdates();
                await refreshSnapshot();
                return result.outcome === "accepted";
              },
              download: async (version) => {
                const result = await client.openUpdateDownload(version);
                await refreshSnapshot();
                return result.outcome === "accepted";
              },
              website: async () =>
                (await client.openUpdateWebsite()).outcome === "opened",
            }}
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
            fileTreeOpen={fileTreeOpen}
            onToggleFileTree={() => setFileTreeOpen((open) => !open)}
            fileTree={
              <WorkspaceFileTree
                key={workspaceTreeScope}
                tree={workspaceTree}
                available={workspaceFilesAvailable}
                selectedPath={
                  taskPanel.activeTab && taskPanel.activeTab.kind !== "review"
                    ? taskPanel.activeTab.displayPath
                    : null
                }
                onOpen={openWorkspaceFile}
              />
            }
            tabs={taskPanel.session.tabs}
            activeTabId={taskPanel.session.activeTabId}
            attention={pendingLocator}
            actions={
              !taskPanel.waitingForRun &&
              (panelTarget.kind === "preview" ||
                panelTarget.kind === "workspace") &&
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
            ) : (panelTarget.kind === "preview" ||
                panelTarget.kind === "workspace") &&
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
            modelContext={`${bridgeGeneration}:${snapshot.securityEpoch}`}
            archiveManagement={{
              tasks: snapshot.taskIndex,
              workspaces: snapshot.workspaces,
              query: archivedQuery,
              pending: taskPending,
              errors: taskArchiveErrors,
              diagnostics: Object.fromEntries(
                snapshot.taskIndex
                  .map((task) => [
                    task.id,
                    Object.values(statuses.entries)
                      .filter(
                        (entry) =>
                          entry?.local &&
                          entry.audience.scope === "task" &&
                          entry.audience.taskId === task.id &&
                          entry.diagnostic,
                      )
                      .map((entry) => entry?.diagnostic)
                      .join("\n\n"),
                  ])
                  .filter(([, diagnostic]) => diagnostic),
              ),
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
            accountFeedback={accountFeedbackEntries.map((entry) => (
              <FeedbackNotice
                key={`${statuses.epoch}:${entry.key}:${entry.cycle}`}
                title={t(entry.id, entry.values)}
                detailsLabel={t("feedback.details")}
                dismissLabel={t("feedback.dismiss")}
                pending={entry.tone === "quiet"}
                onDismiss={() => {
                  updateFeedbackState((current) =>
                    dismissFeedback(current, entry.key, entry.cycle),
                  );
                  window.requestAnimationFrame(() =>
                    document
                      .querySelector<HTMLElement>("#settings-account h2")
                      ?.focus(),
                  );
                }}
              />
            ))}
            accountDiagnostics={
              Object.values(statuses.entries).some(
                (entry) =>
                  entry?.audience.scope === "account" && entry.diagnostic,
              ) ? (
                <DiagnosticDisclosure
                  label={t("account.diagnostics")}
                  key={`${statuses.epoch}:${snapshot.account.accountId}`}
                >
                  {Object.values(statuses.entries).map((entry) =>
                    entry?.audience.scope === "account" && entry.diagnostic ? (
                      <pre className="feedback-notice-details" key={entry.key}>
                        {entry.diagnostic}
                      </pre>
                    ) : null,
                  )}
                </DiagnosticDisclosure>
              ) : null
            }
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
            onCreateCustomProvider={(input) =>
              runExecutionCommand(() => client.createCustomProvider(input))
            }
            onCreateBuiltinProvider={(input) =>
              runExecutionCommand(() => client.createBuiltinProvider(input))
            }
            onSaveCustomModel={async (input) => {
              let outcome: Awaited<ReturnType<typeof editCustomModel>> = {
                accepted: false,
                applied: [],
                source: null,
                modelId: input.modelId,
                reviewRequired: true,
              };
              await runExecutionCommand(async () => {
                outcome = await editCustomModel(
                  client,
                  snapshot.models,
                  async () => {
                    await refreshSnapshot();
                    return latestSnapshotRef.current!.models;
                  },
                  input,
                );
                return {
                  accepted: outcome.accepted,
                  errorCode: outcome.accepted ? "none" : "invalid_provider",
                };
              });
              return outcome;
            }}
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
            onTestCustomModel={(
              providerId,
              revision,
              modelId,
              sourceGeneration,
              catalogGeneration,
            ) =>
              runExecutionCommand(() =>
                client.testCustomModel(
                  providerId,
                  revision,
                  modelId,
                  sourceGeneration,
                  catalogGeneration,
                ),
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
            onChooseImport={(kind, target) =>
              client.chooseSkillImport(kind, target)
            }
            onPrepareImport={(previewId, revision, target) =>
              client.prepareSkillImport(previewId, revision, target)
            }
            onInstall={(previewId, revision, confirmation) =>
              commitSkillMutation(() =>
                client.installSkill(previewId, revision, confirmation),
              )
            }
            onReimport={(previewId, revision, confirmation) =>
              commitSkillMutation(() =>
                client.reimportSkill(previewId, revision, confirmation),
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
            installationProposal={snapshot.mcpInstallation.proposal}
            installationRejected={snapshot.mcpInstallation.notice !== null}
            requestedProposalId={requestedMcpProposal}
            proposalSourceInvalidated={mcpReview?.invalidated ?? false}
            onReviewProposal={reviewMcpProposal}
            onProposalOpened={() => setRequestedMcpProposal(null)}
            onDismissProposal={async (id) => {
              const result = await client.dismissMcpInstallProposal(id);
              await refreshCommittedView();
              return result;
            }}
            capabilities={{
              connectionApproval: snapshot.capabilities.mcpConnectionApproval,
              secretCapture: snapshot.capabilities.mcpSecretCapture,
              secretMaxBytes: snapshot.capabilities.mcpSecretMaxBytes,
              oauth: snapshot.capabilities.mcpOAuth,
            }}
            query={mcpQuery}
            disabled={bridgeUnavailable || !snapshot.capabilities.mcpManagement}
            onQuery={setMcpQuery}
            onCreateStdio={(generation, input, proposalId) =>
              commitMcpMutation(() =>
                client.createMcpStdioServer(generation, input, proposalId),
              )
            }
            onCreateHttp={(generation, input, proposalId) =>
              commitMcpMutation(() =>
                client.createMcpHttpServer(generation, input, proposalId),
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
            onCreate={(input) =>
              commitScheduleMutation(() => client.createScheduledTask(input))
            }
            onUpdate={(id, epoch, input) =>
              commitScheduleMutation(() =>
                client.updateScheduledTask(id, epoch, input),
              )
            }
            onSetEnabled={(id, epoch, enabled) =>
              commitScheduleMutation(() =>
                client.setScheduledTaskEnabled(id, epoch, enabled),
              )
            }
            onRunNow={(id, epoch) =>
              commitScheduleMutation(() =>
                client.runScheduledTaskNow(id, epoch),
              )
            }
            onDelete={(id, epoch) =>
              commitScheduleMutation(() =>
                client.deleteScheduledTask(id, epoch),
              )
            }
            onRecover={() =>
              commitScheduleMutation(() =>
                client.recoverScheduledTaskStore(snapshot.revision),
              )
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
                key={`${bridgeGeneration}:${snapshot.securityEpoch}:${snapshot.historyEpoch}`}
                task={activeTask}
                mcpInstallationProposal={snapshot.mcpInstallation.proposal}
                onReviewMcpProposal={reviewMcpProposal}
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
                  stopRequestPending &&
                  currentStopFeedback?.runId === activeTask?.currentRunId,
                )}
                revision={snapshot.revision}
                composerHasDraft={composerDraftHasContent(composerDraft)}
                retryAvailable={
                  !bridgeUnavailable && taskCanCompose && !taskOperationInFlight
                }
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
                onOpenSettings={openSettings}
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
        onConfigure={() => openSettings("models")}
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
              {deleteError && <p role="alert">{t(deleteError)}</p>}
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
