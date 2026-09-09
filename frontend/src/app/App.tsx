import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";

import { AppShell } from "./AppShell.tsx";
import {
  attentionStatus,
  publishStatus,
  quietStatus,
  selectAccountGateStatus,
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
import { accountSurfacePolicy } from "./account-surface-policy.ts";
import { Icon } from "../components/ui/Icon.tsx";
import { ConfirmationNotice } from "../components/ConfirmationNotice.tsx";
import { AlertDialog } from "../components/ui/alert-dialog.tsx";
import { Button } from "../components/ui/button.tsx";
import { AccountIdentity } from "../features/account/AccountIdentity.tsx";
import { AccountGate } from "../features/account/AccountGate.tsx";
import { accountErrorMessageId } from "../i18n/account-error.ts";
import { persistenceRecoveryErrorMessageId } from "../i18n/persistence-recovery.ts";
import {
  SettingsPage,
  type SettingsFocusTarget,
} from "../features/settings/SettingsPage.tsx";
import { ComposerFooter } from "../features/composer/ComposerFooter.tsx";
import { ApprovalPanel } from "../features/approvals/ApprovalPanel.tsx";
import {
  uiRequestIdentity,
  uiResponsePhase,
} from "../features/approvals/response-state.ts";
import { useUiResponseStates } from "../features/approvals/useUiResponseStates.ts";
import { GlobalSearch } from "../features/search/GlobalSearch.tsx";
import { SkillsPage } from "../features/skills/SkillsPage.tsx";
import { McpPage } from "../features/mcp/McpPage.tsx";
import { ScheduledTasksPage } from "../features/scheduled-tasks/ScheduledTasksPage.tsx";
import { ToolDetailView } from "../features/task-panel/ToolDetailView.tsx";
import { TaskInformation } from "../features/tasks/TaskInformation.tsx";
import { ConversationContext } from "../features/composer/ConversationContext.tsx";
import { findRunFileReference } from "../workbench/run-file-references.ts";
import { TaskPanel } from "../features/task-panel/TaskPanel.tsx";
import {
  FilePreviewView,
  type FilePreviewViewState,
} from "../features/task-panel/FilePreviewView.tsx";
import {
  FileChangeDiffView,
  FileChangesView,
  type FileChangeDiffViewState,
} from "../features/task-panel/FileChangesView.tsx";
import { sidePanelFocusReturnTarget } from "./side-panel-interaction.ts";
import { useTaskPanelTarget } from "../features/task-panel/useTaskPanelTarget.ts";
import { TaskList, type TaskMenuAction } from "../features/tasks/TaskList.tsx";
import { NewTaskView } from "../features/tasks/NewTaskView.tsx";
import { TaskContent } from "../features/tasks/TaskContent.tsx";
import {
  useNewTaskDrafts,
  useTaskDrafts,
} from "../features/composer/useTaskDrafts.ts";
import {
  newTaskDraftStorageId,
  prepareRetryDraft,
  unscopedNewTaskDraftId,
} from "../features/composer/drafts.ts";
import {
  submitTaskInstruction,
  type EnsureTaskContinuationResult,
} from "../features/composer/submitTaskInstruction.ts";
import { newTaskModelSelectionState } from "./new-task-model-selection.ts";
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
  TaskModelSelectionReason,
  TaskModelSelectionAvailability,
  ModelRef,
  TaskView,
  FilePreview,
  FileReferenceView,
  FileChangeDiffResult,
  FileChangeView,
  RunFileChanges,
  PermissionProfile,
  WorkbenchSnapshot,
  UiResponsePayload,
} from "../bridge/contracts.ts";
import { useI18n, type MessageId } from "../i18n/context.ts";
import {
  searchWorkbench,
  selectActiveTask,
  taskDisplayState,
  workspaceDirectoryLabel,
  type SearchResult,
} from "../workbench/selectors.ts";
import { chooseWorkspaceAndMigrateDraft } from "../features/workspaces/chooseWorkspace.ts";
import { initialWorkbenchState, workbenchReducer } from "../workbench/store.ts";
import { navigableTasks } from "../workbench/task-visibility.ts";
import { PendingScopes } from "../workbench/pendingScopes.ts";
import { taskModelSelectionPolicy } from "./task-model-selection.ts";

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
    case "execution_replacing":
      return "settings.task_model_execution_replacing";
    case "runtime_detached":
      return "settings.task_model_runtime_detached";
    case "unsupported_source":
      return "settings.task_model_unsupported_source";
    case "authority_changed":
    default:
      return "settings.task_model_authority_changed";
  }
}

type MutationReason =
  | TaskCreateReason
  | TaskCompactReason
  | TaskRestoreReason
  | TaskRunReason
  | TaskModelSelectionReason;

function mutationReasonMessageId(reason: MutationReason): MessageId {
  return `mutation.reason.${reason}`;
}

const automaticWorkspaceOptionId = "automatic";
const continuationWaitTimeoutMs = 10_000;

type ContinuationWaitResult =
  | { kind: "ready" }
  | { kind: "cancelled"; error: Error }
  | { kind: "failed"; error: Error }
  | { kind: "timeout"; error: Error };

type ContinuationWaiter = {
  taskId: string;
  bindingEpoch: string;
  attemptId: string;
  resolve: (result: ContinuationWaitResult) => void;
  timeout: ReturnType<typeof setTimeout>;
};

type FilePreviewIdentity = {
  taskId: string;
  runId: string;
  reference: FileReferenceView;
  requestGeneration: number;
};

type FilePreviewUiState =
  | { kind: "closed" }
  | (FilePreviewIdentity & { kind: "loading" })
  | (FilePreviewIdentity & { kind: "ready"; preview: FilePreview })
  | (FilePreviewIdentity & { kind: "failed"; preview: FilePreview });

type FileChangesIdentity = {
  taskId: string;
  runId: string;
  observation: RunFileChanges["observation"];
  changes: FileChangeView[];
  selected: FileChangeView;
  requestGeneration: number;
};

type FileChangesUiState =
  | { kind: "closed" }
  | (FileChangesIdentity & { kind: "loading" })
  | (FileChangesIdentity & {
      kind: "settled";
      diff: FileChangeDiffResult;
    })
  | (FileChangesIdentity & { kind: "failed" });

export default function App() {
  const { t } = useI18n();
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [showArchived, setShowArchived] = useState(false);
  const [route, setRoute] = useState<ShellRoute>("workbench");
  const [rightPanelOpen, setRightPanelOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const settingsRestoreFocus = useRef<HTMLElement | null>(null);
  const [settingsFocus, setSettingsFocus] =
    useState<SettingsFocusTarget>("title");
  const [accountSetupRedirected, setAccountSetupRedirected] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [skillsQuery, setSkillsQuery] = useState("");
  const [mcpQuery, setMcpQuery] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [filePreview, setFilePreview] = useState<FilePreviewUiState>({
    kind: "closed",
  });
  const filePreviewGeneration = useRef(0);
  const [fileChanges, setFileChanges] = useState<FileChangesUiState>({
    kind: "closed",
  });
  const fileChangesGeneration = useRef(0);
  const [statuses, setStatuses] = useState<ShellStatusState>(() =>
    publishStatus(
      {},
      quietStatus("connection.connecting", { scope: "connection" }),
    ),
  );
  const [accountBusy, setAccountBusy] = useState(false);
  const [executionBusy, setExecutionBusy] = useState(false);
  const [workspaceBusy, setWorkspaceBusy] = useState(false);
  const [permissionBusy, setPermissionBusy] = useState(false);
  const [newTaskPermissionOverride, setNewTaskPermissionOverride] =
    useState<PermissionProfile | null>(null);
  const [newTaskRequestedModel, setNewTaskRequestedModel] =
    useState<ModelRef | null>(null);
  const [skillCatalogBusy, setSkillCatalogBusy] = useState(false);
  const [attachmentBusy, setAttachmentBusy] = useState(false);
  const [attachmentError, setAttachmentError] = useState<string | null>(null);
  const [taskPending, setTaskPending] = useState<Record<string, string>>({});
  const [pendingTaskModels, setPendingTaskModels] = useState<
    Record<string, string>
  >({});
  const [cancelPending, setCancelPending] = useState<Record<string, true>>({});
  const [connectionBusy, setConnectionBusy] = useState(false);
  const [accountCancelBusy, setAccountCancelBusy] = useState(false);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [bridgeGeneration, setBridgeGeneration] = useState("0");
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
  const pendingTaskDraftRetention = useRef(new Set<string>());
  const taskPendingScopes = useRef(new PendingScopes());
  const cancelPendingTasks = useRef(new PendingScopes());
  const accountBusyRef = useRef(false);
  const executionBusyRef = useRef(false);
  const accountCancelBusyRef = useRef(false);
  const workspaceBusyRef = useRef(false);
  const connectionBusyRef = useRef(false);
  const taskPanelToggle = useRef<HTMLButtonElement>(null);
  const taskInformationTrigger = useRef<HTMLButtonElement>(null);
  const taskPanelOpener = useRef<HTMLButtonElement | null>(null);
  const composer = useRef<HTMLTextAreaElement>(null);
  const continuationWaiters = useRef(new Map<string, ContinuationWaiter>());

  function setStatus(status: ShellStatus) {
    setStatuses((current) => publishStatus(current, status));
  }

  const snapshot = workbench.snapshot;
  const newTaskPermissionProfile =
    newTaskPermissionOverride ?? snapshot.permissions.defaultProfile;
  const activeTask = useMemo(() => selectActiveTask(workbench), [workbench]);
  useEffect(() => {
    setPendingTaskModels((current) => {
      let changed = false;
      const next = { ...current };
      for (const [taskId, model] of Object.entries(current)) {
        const task = snapshot.tasks.find(
          (candidate) => candidate.id === taskId,
        );
        if (!task || task.binding.model === model) {
          delete next[taskId];
          changed = true;
        }
      }
      return changed ? next : current;
    });
  }, [snapshot.tasks]);
  const activeTaskIdRef = useRef<string | null>(null);
  activeTaskIdRef.current = activeTask?.id ?? null;

  function closeFilePreview() {
    filePreviewGeneration.current += 1;
    setFilePreview({ kind: "closed" });
  }

  function requestFilePreview(
    taskId: string,
    runId: string,
    reference: FileReferenceView,
  ) {
    const requestGeneration = filePreviewGeneration.current + 1;
    filePreviewGeneration.current = requestGeneration;
    const identity: FilePreviewIdentity = {
      taskId,
      runId,
      reference,
      requestGeneration,
    };
    setFilePreview({ kind: "loading", ...identity });
    void client
      .previewFile(taskId, runId, reference.id)
      .then((preview) => {
        if (
          filePreviewGeneration.current !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setFilePreview((current) => {
          if (
            current.kind === "closed" ||
            current.requestGeneration !== requestGeneration ||
            current.taskId !== taskId ||
            current.runId !== runId ||
            current.reference.id !== reference.id
          )
            return current;
          return preview.state === "ready"
            ? { ...current, kind: "ready", preview }
            : { ...current, kind: "failed", preview };
        });
      })
      .catch(() => {
        if (
          filePreviewGeneration.current !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setFilePreview((current) => {
          if (
            current.kind === "closed" ||
            current.requestGeneration !== requestGeneration ||
            current.taskId !== taskId ||
            current.runId !== runId ||
            current.reference.id !== reference.id
          )
            return current;
          return {
            ...current,
            kind: "failed",
            preview: {
              state: "error",
              content: "",
              truncated: false,
              redacted: false,
            },
          };
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
    setRightPanelOpen(true);
    taskPanelOpener.current = opener;
    closeFileChanges();
    taskPanel.selectTarget({
      kind: "preview",
      taskId,
      runId,
      referenceId: selected.id,
    });
    requestFilePreview(taskId, runId, selected);
    window.requestAnimationFrame(() =>
      document.getElementById("task-panel-title")?.focus(),
    );
  }

  function refreshFilePreview() {
    if (filePreview.kind === "closed") return;
    requestFilePreview(
      filePreview.taskId,
      filePreview.runId,
      filePreview.reference,
    );
  }

  function closeFileChanges() {
    fileChangesGeneration.current += 1;
    setFileChanges({ kind: "closed" });
  }

  function requestFileChangeDiff(
    taskId: string,
    runId: string,
    observation: RunFileChanges["observation"],
    changes: FileChangeView[],
    selected: FileChangeView,
  ) {
    const requestGeneration = fileChangesGeneration.current + 1;
    fileChangesGeneration.current = requestGeneration;
    const identity: FileChangesIdentity = {
      taskId,
      runId,
      observation,
      changes,
      selected,
      requestGeneration,
    };
    if (!selected.diffAvailable) {
      setFileChanges({
        ...identity,
        kind: "settled",
        diff: {
          status: "unavailable",
          reason: "not_recorded",
          content: "",
        },
      });
      return;
    }
    setFileChanges({ ...identity, kind: "loading" });
    void client
      .fileChangeDiff(taskId, runId, selected.id)
      .then((diff) => {
        if (
          fileChangesGeneration.current !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setFileChanges((current) => {
          if (
            current.kind === "closed" ||
            current.requestGeneration !== requestGeneration ||
            current.taskId !== taskId ||
            current.runId !== runId ||
            current.selected.id !== selected.id
          )
            return current;
          return { ...current, kind: "settled", diff };
        });
      })
      .catch(() => {
        if (
          fileChangesGeneration.current !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setFileChanges((current) => {
          if (
            current.kind === "closed" ||
            current.requestGeneration !== requestGeneration ||
            current.taskId !== taskId ||
            current.runId !== runId ||
            current.selected.id !== selected.id
          )
            return current;
          return { ...current, kind: "failed" };
        });
      });
  }

  function openFileChanges(
    taskId: string,
    runId: string,
    opener: HTMLButtonElement,
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
    setRightPanelOpen(true);
    taskPanelOpener.current = opener;
    closeFilePreview();
    closeFileChanges();
    taskPanel.selectTarget({ kind: "review", taskId, runId });
    window.requestAnimationFrame(() =>
      document.getElementById("task-panel-title")?.focus(),
    );
  }

  function openFileChange(change: FileChangeView) {
    const review = taskPanel.target.kind === "review" ? taskPanel.target : null;
    if (!review || activeTaskIdRef.current !== review.taskId) return;
    const task = snapshot.tasks.find(
      (candidate) => candidate.id === review.taskId,
    );
    const run = task?.runs.find((candidate) => candidate.id === review.runId);
    const recorded = run?.fileChanges;
    const selected = recorded?.changes.find(
      (candidate) => candidate.id === change.id,
    );
    if (!recorded || !selected) return;
    taskPanel.selectTarget({
      kind: "review",
      taskId: review.taskId,
      runId: review.runId,
      selectedChangeId: selected.id,
    });
    requestFileChangeDiff(
      review.taskId,
      review.runId,
      recorded.observation,
      recorded.changes,
      selected,
    );
    window.requestAnimationFrame(() =>
      document.getElementById("task-panel-title")?.focus(),
    );
  }

  function refreshFileChangeDiff() {
    if (fileChanges.kind === "closed") return;
    requestFileChangeDiff(
      fileChanges.taskId,
      fileChanges.runId,
      fileChanges.observation,
      fileChanges.changes,
      fileChanges.selected,
    );
  }

  useEffect(() => {
    filePreviewGeneration.current += 1;
    setFilePreview({ kind: "closed" });
    fileChangesGeneration.current += 1;
    setFileChanges({ kind: "closed" });
  }, [activeTask?.id]);

  useEffect(() => {
    setFilePreview((current) => {
      if (current.kind === "closed") return current;
      const task = snapshot.tasks.find(
        (candidate) => candidate.id === current.taskId,
      );
      const run = task?.runs.find(
        (candidate) => candidate.id === current.runId,
      );
      const reference = run
        ? findRunFileReference(run, current.reference.id)
        : undefined;
      if (!task || !run || !reference) {
        filePreviewGeneration.current += 1;
        return { kind: "closed" };
      }
      return { ...current, reference };
    });
  }, [snapshot.revision, snapshot.tasks]);

  useEffect(() => {
    setFileChanges((current) => {
      if (current.kind === "closed") return current;
      const task = snapshot.tasks.find(
        (candidate) => candidate.id === current.taskId,
      );
      const run = task?.runs.find(
        (candidate) => candidate.id === current.runId,
      );
      const recorded = run?.fileChanges;
      const selected = recorded?.changes.find(
        (candidate) => candidate.id === current.selected.id,
      );
      if (!task || !run || !recorded || !selected) {
        fileChangesGeneration.current += 1;
        return { kind: "closed" };
      }
      return {
        ...current,
        observation: recorded.observation,
        changes: recorded.changes,
        selected,
      };
    });
  }, [snapshot.revision, snapshot.tasks]);

  const panelTask = route === "workbench" ? activeTask : null;
  const taskPanel = useTaskPanelTarget(
    panelTask,
    snapshot.capabilities.typedFileChanges,
  );
  const panelTarget = taskPanel.target;
  useEffect(() => {
    if (panelTarget.kind !== "preview") closeFilePreview();
    if (panelTarget.kind !== "review" || !panelTarget.selectedChangeId)
      closeFileChanges();
  }, [panelTarget]);
  const manualWorkspaces = useMemo(
    () =>
      snapshot.workspaces.filter((workspace) => workspace.kind === "manual"),
    [snapshot.workspaces],
  );
  const navigableTaskItems = useMemo(
    () => navigableTasks(snapshot),
    [snapshot],
  );
  const searchResults = useMemo(
    () => searchWorkbench(snapshot, searchQuery),
    [searchQuery, snapshot],
  );
  const taskDrafts = useTaskDrafts(activeTask?.id ?? null);
  const newTaskDraftActive = workbench.draftOpen || activeTask === null;
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
    ? `new-task:${newTaskDraftId ?? unscopedNewTaskDraftId}`
    : `task:${activeTask?.id ?? "missing"}`;
  const composerDraftScopeRef = useRef(composerDraftScope);
  composerDraftScopeRef.current = composerDraftScope;
  useEffect(() => setAttachmentError(null), [composerDraftScope]);
  const previousBridgeGeneration = useRef(bridgeGeneration);
  useEffect(() => {
    const previous = previousBridgeGeneration.current;
    previousBridgeGeneration.current = bridgeGeneration;
    if (previous === "0" || previous === bridgeGeneration) return;
    taskDrafts.invalidateAttachments();
    newTaskDrafts.invalidateAttachments();
    setAttachmentError(null);
  }, [
    bridgeGeneration,
    newTaskDrafts.invalidateAttachments,
    taskDrafts.invalidateAttachments,
  ]);
  const bridgeUnavailable = viewSyncFailed || !bridgeReady;
  const hasTasks = snapshot.tasks.length !== 0;
  const snapshotAcceptedForCurrentGeneration =
    workbench.connectionGeneration !== "0" &&
    workbench.snapshotGeneration === workbench.connectionGeneration;
  const accountSurface = accountSurfacePolicy(
    snapshot.account,
    snapshot.models,
    hasTasks,
  );
  const accountGateRequired =
    snapshotAcceptedForCurrentGeneration && accountSurface.gateRequired;
  const accountSetupRequired = accountSurface.setupRequired;

  useEffect(() => {
    if (accountSetupRedirected && hasTasks) {
      setAccountSetupRedirected(false);
      setSettingsFocus("title");
      setSettingsOpen(false);
      return;
    }
    if (accountSetupRedirected && snapshot.account.state !== "authenticated") {
      setAccountSetupRedirected(false);
      return;
    }
    if (accountSetupRequired && route === "workbench" && !settingsOpen) {
      setAccountSetupRedirected(true);
      openSettings("account");
      return;
    }
    if (
      !accountSetupRedirected ||
      accountSetupRequired ||
      route !== "workbench" ||
      snapshot.account.state !== "authenticated"
    )
      return;
    setAccountSetupRedirected(false);
    setSettingsFocus("title");
    setSettingsOpen(false);
    window.requestAnimationFrame(() => composer.current?.focus());
  }, [
    accountSetupRedirected,
    accountSetupRequired,
    hasTasks,
    route,
    settingsOpen,
    snapshot.account.state,
  ]);

  const workbenchMutationDisabled = bridgeUnavailable;
  const currentTaskScope = activeTask ? `task:${activeTask.id}` : "new-task";
  const taskMutationDisabled =
    workbenchMutationDisabled || currentTaskScope in taskPending;
  const taskCanCompose =
    newTaskDraftActive ||
    (activeTask?.lifecycle === "open" &&
      (activeTask.continuationAvailable ||
        activeTask.continuationRecoveryAvailable) &&
      !activeTask.archived);
  const taskOperationInFlight = Boolean(activeTask?.activeOperation);
  const composerWorkspaceId =
    activeTask?.workspaceId || workbench.draftWorkspaceId;
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
  const canSubmit =
    taskCanCompose &&
    (!newTaskDraftActive || snapshot.newTaskAdmission.available) &&
    (!newTaskDraftActive || newTaskWorkspaceReady) &&
    (!newTaskDraftActive || newTaskModelState.valid) &&
    !taskOperationInFlight &&
    composerDraftHasContent(composerDraft) &&
    composerRunInput !== null &&
    composerDraftWithinLimits(composerDraft) &&
    skillDraftCurrent &&
    (composerDraft.kind !== "skill" || !skillCatalogBusy) &&
    !attachmentBusy &&
    !taskMutationDisabled &&
    !workspaceBusy;
  const metaskProvider = snapshot.models.providers.find(
    (provider) => provider.id === "metask",
  );
  const metaskModelOptions = (metaskProvider?.models ?? []).map((model) => ({
    selectionId: model.id,
    displayName: model.displayName,
    metadata: model.metadata,
  }));
  const activeCustomProvider = snapshot.models.customProviders.find(
    (connection) =>
      connection.id === snapshot.newTaskAdmission.activeModelRef?.sourceId,
  );
  const customCustomProviderSelected = activeCustomProvider !== undefined;
  const composerModelMetadata = newTaskDraftActive
    ? newTaskModelState.selectedMetadata
    : (metaskProvider?.models.find(
        (model) => model.id === activeTask?.binding.model,
      )?.metadata ?? null);
  const imageDeclaredUnsupported =
    composerDraft.kind === "multimodal" &&
    composerModelMetadata?.capabilities.imageInput === false &&
    composerDraft.attachments.some((attachment) => attachment.kind === "image");
  const attachmentModelWarning = imageDeclaredUnsupported
    ? ("image" as const)
    : null;
  const customCustomProviderContext = activeCustomProvider
    ? `${activeCustomProvider.displayName} · ${t(
        `settings.custom_provider_protocol.${activeCustomProvider.protocol}`,
      )}`
    : "";
  const selectedModelLabel =
    newTaskModelState.selectedModelLabel || t("account.choose_model");
  const metaskDefaultRecoveryAvailable = Boolean(
    newTaskDraftActive &&
    snapshot.models.persistenceHealth === "ready" &&
    snapshot.models.defaultSelection === null &&
    snapshot.models.metaskSelection !== null &&
    metaskProvider?.catalogState === "ready" &&
    snapshot.models.metaskSelection.sourceId ===
      `metask:${metaskProvider.selectedApiKeyId}` &&
    metaskProvider.models.some(
      (model) => model.id === snapshot.models.metaskSelection?.modelId,
    ),
  );
  const taskModelId = activeTask?.binding.model ?? "";
  const pendingTaskModelId = activeTask
    ? (pendingTaskModels[activeTask.id] ?? null)
    : null;
  const pendingTaskModel = pendingTaskModelId
    ? metaskProvider?.models.find((model) => model.id === pendingTaskModelId)
    : null;
  const taskModelLabel = pendingTaskModelId
    ? t("task.model_pending", {
        model:
          pendingTaskModel?.displayName ||
          pendingTaskModel?.id ||
          pendingTaskModelId,
      })
    : (activeTask?.binding.model ?? selectedModelLabel);
  const displayedTaskModelId = pendingTaskModelId ?? taskModelId;
  const taskModelPolicy = taskModelSelectionPolicy(activeTask);

  const refreshSnapshot = useCallback(() => {
    const current = connection.current;
    return current ? current.refresh() : Promise.resolve();
  }, []);

  function settleContinuationWaiter(
    key: string,
    result: ContinuationWaitResult,
  ) {
    const waiter = continuationWaiters.current.get(key);
    if (!waiter) return;
    continuationWaiters.current.delete(key);
    clearTimeout(waiter.timeout);
    waiter.resolve(result);
  }

  function observeContinuationSnapshot(next: WorkbenchSnapshot) {
    for (const [key, waiter] of continuationWaiters.current) {
      const task = next.tasks.find(
        (candidate) => candidate.id === waiter.taskId,
      );
      if (!task) {
        settleContinuationWaiter(key, {
          kind: "failed",
          error: new Error("The Task disappeared during conversation restore"),
        });
        continue;
      }
      if (task.binding.epoch !== waiter.bindingEpoch) {
        settleContinuationWaiter(key, {
          kind: "failed",
          error: new Error(
            "The Task binding changed during conversation restore",
          ),
        });
        continue;
      }
      if (task.activeOperation?.kind === "restore") {
        if (task.activeOperation.id !== waiter.attemptId)
          settleContinuationWaiter(key, {
            kind: "failed",
            error: new Error("A different conversation restore is active"),
          });
        continue;
      }
      if (task.continuationAvailable && !task.continuationRecoveryAvailable) {
        settleContinuationWaiter(key, { kind: "ready" });
        continue;
      }
      if (
        task.continuationUnavailableReason !== "session_recovery_required" &&
        task.continuationUnavailableReason !== "session_recovery_in_progress"
      ) {
        settleContinuationWaiter(key, {
          kind: "failed",
          error: new Error(
            task.continuationUnavailableReason ??
              "Conversation restore did not produce a usable Session",
          ),
        });
      }
    }
  }

  function waitForTaskContinuation(
    taskId: string,
    bindingEpoch: string,
    attemptId: string,
  ): Promise<ContinuationWaitResult> {
    const key = `${taskId}:${attemptId}`;
    const existing = continuationWaiters.current.get(key);
    if (existing)
      return new Promise((resolve) => {
        const previousResolve = existing.resolve;
        existing.resolve = (result) => {
          previousResolve(result);
          resolve(result);
        };
      });
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        settleContinuationWaiter(key, {
          kind: "timeout",
          error: new Error("Timed out waiting for conversation restore"),
        });
      }, continuationWaitTimeoutMs);
      continuationWaiters.current.set(key, {
        taskId,
        bindingEpoch,
        attemptId,
        resolve,
        timeout,
      });
      observeContinuationSnapshot(workbench.snapshot);
    });
  }

  function cancelContinuationWaitersForTask(taskId: string | null) {
    for (const [key, waiter] of continuationWaiters.current) {
      if (taskId !== null && waiter.taskId === taskId) continue;
      settleContinuationWaiter(key, {
        kind: "cancelled",
        error: new Error("The active Task changed during conversation restore"),
      });
    }
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
          observeContinuationSnapshot(next);
          observeUiResponseSnapshot(next);
          const projectedTaskIds = next.tasks.map((task) => task.id);
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
            generation,
          });
          const pendingTaskId = pendingTaskSelection.current;
          if (
            pendingTaskId &&
            next.tasks.some((task) => task.id === pendingTaskId)
          ) {
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
          else if (next.failure === "bootstrap_failed")
            setRootRenderBlockReason("bootstrap_failed");
          setStatus(connectionStatus(next));
        }
      },
      onReady: (ready) => {
        if (!cancelled) setBridgeReady(ready);
      },
      onGeneration: (generation) => {
        if (!cancelled) {
          dispatchWorkbench({ type: "generation.started", generation });
          setBridgeGeneration(generation);
          if (generation !== "0") setRootRenderBlockReason(null);
        }
      },
      onViewSyncFailed: (failed) => {
        if (!cancelled) setViewSyncFailed(failed);
      },
    });
    connection.current = current;
    void current.start().catch((error) => {
      if (!cancelled) {
        setViewSyncFailed(true);
      }
    });

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
    const openSearch = (event: KeyboardEvent) => {
      if (!event.metaKey && !event.ctrlKey) return;
      const key = event.key.toLowerCase();
      if (key !== "k" && key !== "n") return;
      event.preventDefault();
      if (accountGateRequired || bridgeUnavailable) return;
      if (key === "k") {
        setSearchOpen(true);
      } else {
        setRoute("workbench");
        beginNewTask();
      }
    };
    window.addEventListener("keydown", openSearch);
    return () => window.removeEventListener("keydown", openSearch);
  }, [accountGateRequired, bridgeUnavailable]);

  useEffect(() => {
    if (!client.available()) return;
    return client.onShortcut((detail) => {
      if (detail.id !== "settings.open") return;
      if (accountGateRequired || bridgeUnavailable) return;
      openSettings();
    });
  }, [accountGateRequired, bridgeUnavailable, client]);

  useEffect(() => {
    setEditingTitle(false);
    setConfirmDelete(false);
    taskPanelOpener.current = null;
    cancelContinuationWaitersForTask(activeTask?.id ?? null);
  }, [activeTask?.id]);

  useEffect(() => () => cancelContinuationWaitersForTask(null), []);

  useEffect(() => {
    if (
      !snapshot.newTaskAdmission.available ||
      activeTask !== null ||
      workbench.draftOpen
    )
      return;
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: null,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }, [activeTask, snapshot.newTaskAdmission.available, workbench.draftOpen]);

  function focusPendingRequest() {
    const requestId = activeTask?.pendingUi?.requestId;
    if (!requestId) return;
    const target = document.getElementById(`ui-request-${requestId}`);
    target?.scrollIntoView({ block: "center", behavior: "smooth" });
    window.requestAnimationFrame(() => target?.focus());
  }

  function openToolDetail(
    runId: string,
    toolId: string,
    opener: HTMLButtonElement,
  ) {
    if (!activeTask) return;
    closeFilePreview();
    closeFileChanges();
    setRightPanelOpen(true);
    taskPanelOpener.current = opener;
    taskPanel.selectTarget({
      kind: "tool",
      taskId: activeTask.id,
      runId,
      toolId,
    });
    window.requestAnimationFrame(() =>
      document.getElementById("task-panel-title")?.focus(),
    );
  }

  function dismissTaskPanel(restoreFocus = true) {
    const panel = document.getElementById("task-panel");
    const focusWasInside = panel?.contains(document.activeElement) === true;
    const focusTarget = sidePanelFocusReturnTarget(
      taskPanelOpener.current,
      taskPanelToggle.current,
    );
    taskPanelOpener.current = null;
    closeFilePreview();
    closeFileChanges();
    setRightPanelOpen(false);
    taskPanel.clearTarget();
    if (restoreFocus && focusWasInside && focusTarget)
      window.requestAnimationFrame(() => focusTarget.focus());
  }

  function focusPendingFromTaskPanel() {
    const panel = document.getElementById("task-panel");
    if (panel && window.getComputedStyle(panel).position === "fixed")
      dismissTaskPanel(false);
    window.requestAnimationFrame(focusPendingRequest);
  }

  function toggleRightPanel(opener: HTMLButtonElement) {
    if (rightPanelOpen) {
      dismissTaskPanel(false);
      return;
    }
    taskPanelOpener.current = opener;
    setRightPanelOpen(true);
    window.requestAnimationFrame(() =>
      document.getElementById("task-panel-title")?.focus(),
    );
  }

  function returnToReview() {
    if (panelTarget.kind !== "review") return;
    closeFileChanges();
    taskPanel.selectTarget({
      kind: "review",
      taskId: panelTarget.taskId,
      runId: panelTarget.runId,
    });
    window.requestAnimationFrame(() =>
      document.getElementById("task-panel-title")?.focus(),
    );
  }

  function closeDeleteConfirmation() {
    setConfirmDelete(false);
    window.requestAnimationFrame(() => {
      const taskRow = document.querySelector<HTMLElement>(
        `[data-task-id="${CSS.escape(activeTaskIdRef.current ?? "")}"]`,
      );
      taskRow?.focus();
    });
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

  function moveTaskPendingOperation(from: string, to: string) {
    if (!taskPendingScopes.current.move(from, to)) return false;
    setTaskPending((current) => {
      const operation = current[from];
      if (!operation) return current;
      const next = { ...current };
      delete next[from];
      next[to] = operation;
      return next;
    });
    return true;
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

  async function retryViewSynchronization() {
    if (connectionBusyRef.current) return;
    connectionBusyRef.current = true;
    setConnectionBusy(true);
    setViewSyncFailed(false);
    try {
      const current = connection.current;
      if (!current) throw new Error("Workbench connection is not available");
      await current.retry();
      setBridgeReady(true);
      setStatus(quietStatus("connection.recovered", { scope: "connection" }));
    } catch (error) {
      setViewSyncFailed(true);
      setBridgeReady(false);
      // WorkbenchConnection has already published the typed failure status.
      // Keep the last classification intact so retry failures cannot become a
      // generic render-gate signal.
    } finally {
      connectionBusyRef.current = false;
      setConnectionBusy(false);
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

  async function selectModelForTask(selectionId: string) {
    const task = activeTask;
    if (!task || bridgeUnavailable) return;
    const wasBusy = task.activeOperation !== null;
    const scope = `task:${task.id}`;
    if (!beginTaskPendingOperation(scope, "model")) return;
    try {
      const result = await client.selectTaskModel(
        task.id,
        task.binding.model,
        task.binding.executionGeneration,
        {
          sourceId: snapshot.models.metaskSelection?.sourceId ?? "",
          modelId: selectionId,
        },
        metaskProvider?.sourceGeneration ?? "0",
        metaskProvider?.catalogGeneration ?? "0",
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
      setPendingTaskModels((current) => {
        const next = { ...current };
        if (wasBusy) next[task.id] = result.model;
        else delete next[task.id];
        return next;
      });
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
        sourceId: `metask:${provider.selectedApiKeyId}`,
        modelId,
        expectedMetaskSelectionRevision:
          snapshot.models.metaskSelectionRevision,
        expectedCatalogGeneration: provider.catalogGeneration,
      }),
    );
    if (!configured) return;
    // `runExecutionCommand` refreshes the rendered snapshot asynchronously;
    // do not reuse the pre-configuration revisions for the second CAS.
    const current = await client.fetchSnapshot();
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
    setNewTaskPermissionOverride(null);
    setNewTaskRequestedModel(null);
    setRoute("workbench");
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: null,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }

  async function setDefaultPermissionProfile(profile: PermissionProfile) {
    if (bridgeUnavailable || permissionBusy) return;
    setPermissionBusy(true);
    try {
      await client.setDefaultPermissionProfile(profile);
      await refreshAfterCommit(
        "permission.default_updated",
        "operation.permission_default",
        { scope: "account" },
      );
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus(
          "permission.default_update_failed",
          { scope: "account" },
          { diagnostic: errorText(error) },
        ),
      );
    } finally {
      setPermissionBusy(false);
    }
  }

  function openTask(taskId: string) {
    pendingTaskSelection.current = null;
    setRoute("workbench");
    dispatchWorkbench({ type: "task.selected", taskId });
  }

  function openSettings(target: SettingsFocusTarget = "title") {
    if (!settingsOpen) {
      settingsRestoreFocus.current =
        document.activeElement instanceof HTMLElement
          ? document.activeElement
          : null;
    }
    setSettingsFocus(target);
    setSettingsOpen(true);
  }

  function closeSettings() {
    // Leaving settings mid-reconfiguration abandons the unfinished change:
    // cancel the parked catalog transaction so the previous execution comes
    // back and the setup gate releases. First-time setup has nothing to fall
    // back to, so the gate keeps the surface open after the cancel.
    if (accountSetupRequired && snapshot.account.canCancel) {
      void cancelAccountOperation();
      return;
    }
    setSettingsOpen(false);
    window.requestAnimationFrame(() => {
      settingsRestoreFocus.current?.focus();
      settingsRestoreFocus.current = null;
    });
  }

  async function ensureTaskContinuation(
    taskId: string,
    bindingEpoch: string,
  ): Promise<EnsureTaskContinuationResult> {
    if (activeTaskIdRef.current !== taskId)
      return {
        kind: "failed",
        error: new Error("The active Task changed before conversation restore"),
      };
    const task = workbench.snapshot.tasks.find(
      (candidate) => candidate.id === taskId,
    );
    if (!task || task.binding.epoch !== bindingEpoch)
      return {
        kind: "failed",
        error: new Error("The Task binding is no longer current"),
      };
    if (task.continuationAvailable) return { kind: "ready" };
    if (
      task.continuationUnavailableReason !== "session_recovery_required" &&
      task.continuationUnavailableReason !== "session_recovery_failed"
    )
      return {
        kind: "failed",
        error: new Error("Conversation continuation is unavailable"),
      };
    let restored;
    try {
      restored = await client.restoreTask(taskId, bindingEpoch);
    } catch (error) {
      return { kind: "failed", error };
    }
    if (!restored.accepted)
      return { kind: "rejected", reason: restored.reason };
    const completion = await waitForTaskContinuation(
      taskId,
      bindingEpoch,
      restored.attemptId,
    );
    if (completion.kind === "ready") {
      if (activeTaskIdRef.current !== taskId)
        return {
          kind: "failed",
          error: new Error(
            "The active Task changed after conversation restore",
          ),
        };
      return { kind: "ready" };
    }
    return { kind: "failed", error: completion.error };
  }

  async function submitRun() {
    if (!canSubmit) return;
    const submitted = composerDraft;
    const input = composerDraftToRunInput(submitted);
    if (!input) return;
    const existingTaskId = activeTask?.id ?? null;
    const workspace =
      newTaskDraftActive && composerWorkspace
        ? {
            kind: "manual" as const,
            workspaceId: composerWorkspace.id,
            expectedWorkspaceEpoch: composerWorkspace.epoch,
          }
        : { kind: "automatic" as const };
    const submittedDraftId = newTaskDraftId;
    let pendingScope = currentTaskScope;
    if (!beginTaskPendingOperation(pendingScope, "run")) return;
    if (newTaskDraftActive && submittedDraftId)
      newTaskDrafts.clearDraft(submittedDraftId);
    else updateComposerDraft(emptyComposerDraft());
    try {
      const result = await submitTaskInstruction({
        client,
        taskId: existingTaskId,
        workspace,
        expectedExecutionGeneration: snapshot.newTaskAdmission.activeGeneration,
        expectedSelectionRevision:
          snapshot.newTaskAdmission.activeSelectionRevision,
        modelSelection: newTaskDraftActive ? newTaskModelState.intent : null,
        expectedBindingEpoch: activeTask?.binding.epoch ?? null,
        permissionProfile: newTaskPermissionProfile,
        input,
        continuationRecoveryAvailable: Boolean(
          activeTask?.continuationRecoveryAvailable,
        ),
        ensureContinuation: ensureTaskContinuation,
        onTaskCreated: (taskId) => {
          setNewTaskPermissionOverride(null);
          setNewTaskRequestedModel(null);
          pendingTaskSelection.current = taskId;
          pendingTaskDraftRetention.current.add(taskId);
          taskDrafts.setDraft(taskId, submitted);
          dispatchWorkbench({ type: "task.draft.closed" });
          const taskScope = `task:${taskId}`;
          if (moveTaskPendingOperation(pendingScope, taskScope))
            pendingScope = taskScope;
        },
      });
      if (result.kind === "create_failed") {
        if (submittedDraftId)
          newTaskDrafts.setDraft(submittedDraftId, submitted);
        if (
          await reconcileCommandTimeout(result.error, "operation.task_create", {
            scope: "workspace",
            workspaceId: composerWorkspaceId ?? null,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "task.create_failed",
            { scope: "workspace", workspaceId: composerWorkspaceId ?? null },
            {
              diagnostic: errorText(result.error),
            },
          ),
        );
        return;
      }
      if (result.kind === "create_rejected") {
        if (submittedDraftId)
          newTaskDrafts.setDraft(submittedDraftId, submitted);
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason), {
            scope: "workspace",
            workspaceId: composerWorkspaceId,
          }),
        );
        return;
      }
      if (result.kind === "continuation_rejected") {
        taskDrafts.setDraft(result.taskId, submitted);
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason), {
            scope: "task",
            taskId: result.taskId,
          }),
        );
        return;
      }
      if (result.kind === "continuation_failed") {
        taskDrafts.setDraft(result.taskId, submitted);
        if (
          await reconcileCommandTimeout(result.error, "operation.restore", {
            scope: "task",
            taskId: result.taskId,
          })
        )
          return;
        setStatus(
          attentionStatus(
            "recovery.start_failed",
            { scope: "task", taskId: result.taskId },
            { diagnostic: errorText(result.error) },
          ),
        );
        await refreshSnapshot().catch(() => undefined);
        return;
      }
      if (result.kind === "run_failed") {
        taskDrafts.setDraft(result.taskId, submitted);
        if (
          await reconcileCommandTimeout(result.error, "operation.run_submit", {
            scope: "task",
            taskId: result.taskId,
          })
        )
          return;
        setStatus(
          attentionStatus(
            "run.start_failed",
            { scope: "task", taskId: result.taskId },
            {
              diagnostic: errorText(result.error),
            },
          ),
        );
        await refreshSnapshot().catch(() => undefined);
        return;
      }
      if (result.kind === "run_rejected") {
        taskDrafts.setDraft(result.taskId, submitted);
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason), {
            scope: "task",
            taskId: result.taskId,
          }),
        );
        return;
      }
      taskDrafts.clearDraft(result.taskId);
      await refreshAfterCommit("run.started", "operation.run_submit", {
        scope: "task",
        taskId: result.taskId,
      });
    } finally {
      endTaskPendingOperation(pendingScope);
    }
  }

  async function chooseAttachments() {
    if (
      attachmentBusy ||
      bridgeUnavailable ||
      !snapshot.capabilities.attachments.enabled ||
      composerDraftRef.current.kind === "skill"
    )
      return;
    const requestedScope = composerDraftScopeRef.current;
    setAttachmentBusy(true);
    setAttachmentError(null);
    try {
      const result = await client.chooseAttachments();
      if (result.status === "cancelled") return;
      if (result.status === "rejected") {
        setAttachmentError(result.reason);
        return;
      }
      if (composerDraftScopeRef.current !== requestedScope) {
        await Promise.allSettled(
          result.attachments.map((attachment) =>
            client.releaseAttachment(attachment.token),
          ),
        );
        return;
      }
      const current = composerDraftRef.current as ComposerDraft;
      if (current.kind === "skill") {
        await Promise.allSettled(
          result.attachments.map((attachment) =>
            client.releaseAttachment(attachment.token),
          ),
        );
        return;
      }
      const existing = current.kind === "multimodal" ? current.attachments : [];
      updateComposerDraft({
        kind: "multimodal",
        text: current.text,
        attachments: [...existing, ...result.attachments],
      });
    } catch (error) {
      setAttachmentError(errorText(error));
    } finally {
      setAttachmentBusy(false);
    }
  }

  async function removeAttachment(token: string) {
    const current = composerDraftRef.current;
    if (current.kind !== "multimodal") return;
    await client.releaseAttachment(token).catch(() => undefined);
    const attachments = current.attachments.filter(
      (attachment) => attachment.token !== token,
    );
    updateComposerDraft(
      attachments.length === 0
        ? { kind: "text", text: current.text }
        : { ...current, attachments },
    );
  }

  async function cancelRun() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeTask ||
      cancelPendingTasks.current.has(activeTask.id) ||
      activeTask.currentRunId === "0" ||
      activeTask.currentRunPhase === null
    )
      return;
    const taskId = activeTask.id;
    setCancelPendingForTask(taskId, true);
    try {
      try {
        await client.cancel(activeTask.id, activeTask.currentRunId);
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.run_stop", {
            scope: "task",
            taskId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "run.stop_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      await refreshAfterCommit("run.stop_requested", "operation.run_stop", {
        scope: "task",
        taskId,
      });
    } finally {
      setCancelPendingForTask(taskId, false);
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

  async function cancelCompact() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeTask ||
      cancelPendingTasks.current.has(activeTask.id) ||
      activeTask.activeOperation?.kind !== "compact"
    )
      return;
    const taskId = activeTask.id;
    const operationId = activeTask.activeOperation.id;
    setCancelPendingForTask(taskId, true);
    try {
      try {
        await client.cancelCompact(taskId, operationId);
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.compact_stop", {
            scope: "task",
            taskId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "compact.stop_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      await refreshAfterCommit(
        "compact.stop_requested",
        "operation.compact_stop",
        { scope: "task", taskId },
      );
    } finally {
      setCancelPendingForTask(taskId, false);
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

  async function refreshSkillsPageCatalog() {
    if (skillCatalogBusy || bridgeUnavailable) return;
    const audience: StatusAudience = { scope: "skills" };
    setSkillCatalogBusy(true);
    try {
      const result = await client.refreshSkillCatalog();
      if (!result.accepted) {
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason!), audience),
        );
        return;
      }
      await refreshAfterCommit(
        "skills.catalog_refresh_started",
        "operation.skill_catalog_refresh",
        audience,
      );
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus("skills.catalog_refresh_failed", audience, {
          diagnostic: errorText(error),
        }),
      );
    } finally {
      setSkillCatalogBusy(false);
    }
  }

  async function commitSkillMutation(
    mutation: () => Promise<SkillMutationResult>,
  ): Promise<SkillMutationResult> {
    const result = await mutation();
    if (result.accepted) await refreshSnapshot();
    return result;
  }

  async function setSkillEnabled(
    target:
      | { scope: "personal" }
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
    await refreshSnapshot();
    return result;
  }

  async function commitMcpMutation(
    mutation: () => Promise<McpMutationResult>,
  ): Promise<McpMutationResult> {
    try {
      const result = await mutation();
      if (result.outcome !== "unchanged") await refreshSnapshot();
      return result;
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      throw error;
    }
  }

  async function refreshMcpCatalog(): Promise<McpRefreshResult> {
    try {
      const result = await client.refreshMcpCatalog();
      await refreshSnapshot();
      return result;
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      throw error;
    }
  }

  async function applyMcpConfiguration(): Promise<McpConfigurationApplyResult> {
    try {
      const result = await client.applyMcpConfiguration();
      await refreshSnapshot();
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
      await refreshSnapshot();
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

  async function renameTask(task = activeTask) {
    if (
      !task ||
      workbenchMutationDisabled ||
      task.id in taskPending ||
      !titleDraft.trim()
    )
      return;
    const taskId = task.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "rename")) return;
    try {
      try {
        await client.renameTask(task.id, titleDraft.trim());
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.task_rename", {
            scope: "task",
            taskId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "task.rename_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      setEditingTitle(false);
      await refreshAfterCommit("task.renamed", "operation.task_rename", {
        scope: "task",
        taskId,
      });
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  async function setArchived(archived: boolean, task = activeTask) {
    if (
      !task ||
      workbenchMutationDisabled ||
      task.id in taskPending ||
      task.activeOperation !== null
    )
      return;
    const taskId = task.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "archive")) return;
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
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            archived ? "task.archive_failed" : "task.restore_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      if (archived) setShowArchived(true);
      await refreshAfterCommit(
        archived ? "task.archived_status" : "task.restored",
        archived ? "operation.task_archive" : "operation.task_restore",
        { scope: "task", taskId },
      );
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  async function deleteTask(task = activeTask) {
    if (
      !task ||
      workbenchMutationDisabled ||
      task.id in taskPending ||
      !task.archived ||
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
      setConfirmDelete(false);
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

  function handleTaskAction(task: TaskView, action: TaskMenuAction) {
    openTask(task.id);
    if (action === "rename") {
      setTitleDraft(task.title);
      window.requestAnimationFrame(() => setEditingTitle(true));
      return;
    }
    if (action === "archive") {
      void setArchived(!task.archived, task);
      return;
    }
    window.requestAnimationFrame(() => setConfirmDelete(true));
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
  const accountGateStatus = selectAccountGateStatus(statuses);
  if (rootRenderBlockReason === "bootstrap_failed")
    return (
      <AccountGate
        account={snapshot.account}
        beginLoginDisabled={viewSyncFailed || !bridgeReady || accountBusy}
        cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
        connectionFailed={viewSyncFailed}
        connectionRetryable={connectionRetryable}
        connectionTitleId={connectionFailure.titleId}
        connectionHelpId={connectionFailure.helpId}
        connectionSourceId={connectionShellStatus?.sourceId}
        connectionDiagnostic={connectionShellStatus?.diagnostic}
        reconnecting={connectionBusy}
        notice={
          accountGateStatus
            ? t(accountGateStatus.id, accountGateStatus.values)
            : ""
        }
        onReconnect={() => void retryViewSynchronization()}
        onBeginLogin={() => void runAccountCommand(() => client.beginLogin())}
        onCancel={() => void cancelAccountOperation()}
      />
    );

  if (accountGateRequired)
    return (
      <AccountGate
        account={snapshot.account}
        beginLoginDisabled={viewSyncFailed || !bridgeReady || accountBusy}
        cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
        connectionFailed={viewSyncFailed}
        connectionRetryable={connectionRetryable}
        connectionTitleId={connectionFailure.titleId}
        connectionHelpId={connectionFailure.helpId}
        connectionSourceId={connectionShellStatus?.sourceId}
        connectionDiagnostic={connectionShellStatus?.diagnostic}
        reconnecting={connectionBusy}
        notice={
          accountGateStatus
            ? t(accountGateStatus.id, accountGateStatus.values)
            : ""
        }
        onReconnect={() => void retryViewSynchronization()}
        onBeginLogin={() => void runAccountCommand(() => client.beginLogin())}
        onCancel={() => void cancelAccountOperation()}
      />
    );

  const currentTaskState = activeTask ? taskDisplayState(activeTask) : null;
  const currentTaskStatus = !currentTaskState
    ? t(newTaskDraftActive ? "task.new" : "task.open")
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
    : t(newTaskDraftActive ? "task.new" : "task.open");
  const slashCommands: SlashCommandState[] = resolveSlashCommandStates({
    newTaskDraftActive,
    bridgeUnavailable,
    taskMutationDisabled,
    task: activeTask
      ? {
          lifecycleOpen: activeTask.lifecycle === "open",
          continuationAvailable: activeTask.continuationAvailable,
          archived: activeTask.archived,
          activeOperation: activeTask.activeOperation !== null,
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
  const composerFooter = (
    <>
      {activeTask && (
        <ConversationContext key={activeTask.id} context={activeTask.context} />
      )}
      <ComposerFooter
        textareaRef={composer}
        archived={Boolean(activeTask?.archived)}
        closing={activeTask?.lifecycle === "closing"}
        unavailable={Boolean(
          activeTask &&
          activeTask.lifecycle === "open" &&
          !activeTask.continuationAvailable,
        )}
        unavailableReason={activeTask?.continuationUnavailableReason ?? null}
        draft={composerDraft}
        attachmentsEnabled={snapshot.capabilities.attachments.enabled}
        attachmentBusy={attachmentBusy}
        attachmentError={attachmentError}
        attachmentModelWarning={attachmentModelWarning}
        skillCatalog={skillCatalog}
        slashCommands={slashCommands}
        composeDisabled={!taskCanCompose || taskMutationDisabled}
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
        workspaceEditable={newTaskDraftActive}
        modelLabel={
          newTaskDraftActive ? selectedModelLabel : taskModelLabel || null
        }
        modelOptions={
          newTaskDraftActive
            ? newTaskModelState.options
            : taskModelPolicy.showsSelector
              ? metaskModelOptions
              : []
        }
        selectedModelId={
          newTaskDraftActive
            ? newTaskModelState.selectedModelId
            : displayedTaskModelId
        }
        modelEditable={
          newTaskDraftActive
            ? newTaskModelState.editable
            : taskModelPolicy.showsSelector
        }
        modelSelectionDisabled={
          bridgeUnavailable ||
          (customCustomProviderSelected ? executionBusy : accountBusy) ||
          (newTaskDraftActive
            ? newTaskModelState.options.length === 0 ||
              (!customCustomProviderSelected &&
                snapshot.models.operation === "refreshing_catalog")
            : !taskModelPolicy.selectable)
        }
        modelSelectionPending={
          (customCustomProviderSelected ? executionBusy : accountBusy) ||
          (newTaskDraftActive
            ? !customCustomProviderSelected &&
              snapshot.models.operation === "refreshing_catalog"
            : taskModelPolicy.pending)
        }
        modelContextTitle={
          newTaskDraftActive && !newTaskModelState.valid
            ? t("settings.new_task_model_invalid")
            : newTaskDraftActive && customCustomProviderSelected
              ? customCustomProviderContext
              : newTaskDraftActive
                ? t("settings.new_task_model_help")
                : t(
                    taskModelSelectionMessageId(
                      activeTask?.modelSelectionAvailability,
                    ),
                  )
        }
        defaultSelectionMissing={metaskDefaultRecoveryAvailable}
        defaultRecoveryDisabled={bridgeUnavailable || executionBusy}
        actionDisabled={workbenchMutationDisabled || workspaceBusy}
        stopAction={
          activeTask?.activeOperation?.kind === "run" ||
          activeTask?.activeOperation?.kind === "compact"
            ? activeTask.activeOperation.kind
            : null
        }
        stopDisabled={
          bridgeUnavailable ||
          Boolean(activeTask && activeTask.id in cancelPending) ||
          activeTask?.currentRunPhase === "stopping" ||
          Boolean(
            activeTask?.activeOperation?.kind === "compact" &&
            activeTask.compacts.find(
              (compact) =>
                compact.operationId === activeTask.activeOperation?.id,
            )?.phase === "stopping",
          )
        }
        onDraftChange={updateComposerDraft}
        onChooseAttachments={() => void chooseAttachments()}
        onRemoveAttachment={(token) => void removeAttachment(token)}
        onSubmit={() => void submitRun()}
        onStop={() =>
          void (activeTask?.activeOperation?.kind === "compact"
            ? cancelCompact()
            : cancelRun())
        }
        onSlashCommand={runSlashCommand}
        onRefreshSkillCatalog={() => void refreshComposerSkillCatalog()}
        onConfirmAccess={() => void chooseWorkspaceForDraft()}
        onSelectWorkspace={(workspaceId) => setDraftWorkspaceById(workspaceId)}
        onSelectModel={(id) => {
          if (newTaskDraftActive) {
            const activeModel = snapshot.newTaskAdmission.activeModelRef;
            if (activeModel)
              setNewTaskRequestedModel(
                id === activeModel.modelId
                  ? null
                  : { sourceId: activeModel.sourceId, modelId: id },
              );
            return;
          }
          void selectModelForTask(id);
        }}
        onOpenModels={() => openSettings("models")}
      />
    </>
  );
  const filePreviewViewState: FilePreviewViewState | null =
    filePreview.kind === "closed"
      ? null
      : {
          selected: filePreview.reference,
          phase: filePreview.kind === "loading" ? "loading" : "settled",
          preview: filePreview.kind === "loading" ? null : filePreview.preview,
        };
  const fileChangeDiffViewState: FileChangeDiffViewState | null =
    fileChanges.kind === "closed"
      ? null
      : {
          observation: fileChanges.observation,
          selected: fileChanges.selected,
          phase:
            fileChanges.kind === "loading"
              ? "loading"
              : fileChanges.kind === "failed"
                ? "failed"
                : "settled",
          diff: fileChanges.kind === "settled" ? fileChanges.diff : null,
        };
  const panelRun =
    panelTarget.kind === "empty"
      ? null
      : activeTask?.runs.find((run) => run.id === panelTarget.runId);
  const reviewedFileChanges =
    panelTarget.kind === "review" ? panelRun?.fileChanges : null;
  const selectedTool =
    panelTarget.kind === "tool"
      ? panelRun?.tools.find((tool) => tool.id === panelTarget.toolId)
      : null;
  const previewMatchesTarget =
    panelTarget.kind === "preview" &&
    filePreview.kind !== "closed" &&
    panelTarget.taskId === filePreview.taskId &&
    panelTarget.runId === filePreview.runId &&
    panelTarget.referenceId === filePreview.reference.id;
  const diffMatchesTarget =
    panelTarget.kind === "review" &&
    fileChanges.kind !== "closed" &&
    panelTarget.taskId === fileChanges.taskId &&
    panelTarget.runId === fileChanges.runId &&
    panelTarget.selectedChangeId === fileChanges.selected.id;
  const pendingLocator = panelTask?.pendingUi ? (
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
      : panelTarget.kind === "tool"
        ? t("task_panel.tool")
        : panelTarget.kind === "review"
          ? t("task_panel.review")
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
      contextContent={
        !settingsOpen && route === "workbench" && activeTask && editingTitle ? (
          <form
            className="commandbar-task-editor"
            onSubmit={(event) => {
              event.preventDefault();
              void renameTask();
            }}
          >
            <input
              autoFocus
              maxLength={120}
              value={titleDraft}
              aria-label={t("task.rename")}
              placeholder={t("task.item", { id: activeTask.id })}
              onChange={(event) => setTitleDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key !== "Escape") return;
                event.preventDefault();
                setEditingTitle(false);
              }}
            />
            <Button
              variant="secondary"
              size="sm"
              disabled={!titleDraft.trim() || taskMutationDisabled}
            >
              {t("common.save")}
            </Button>
            <button
              type="button"
              className="text-button focus-ring"
              onClick={() => setEditingTitle(false)}
            >
              {t("common.cancel")}
            </button>
          </form>
        ) : undefined
      }
      headerActions={
        !settingsOpen && route === "workbench" ? (
          <>
            {pendingLocator}
            {activeTask && (
              <TaskInformation
                key={activeTask.id}
                task={activeTask}
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
        commandBarStatus
          ? t(commandBarStatus.id, commandBarStatus.values)
          : null
      }
      left={
        <div className="sidebar-frame">
          <div className="sidebar-primary">
            <p className="brand-name">{t("app.name")}</p>
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
                  route === "workbench" && activeTask !== null
                    ? activeTask.id
                    : null
                }
                showArchived={showArchived}
                onSelectTask={openTask}
                onToggleArchived={() => setShowArchived((shown) => !shown)}
                onTaskAction={handleTaskAction}
                taskMutationDisabled={workbenchMutationDisabled}
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
      onToggleRightPanel={toggleRightPanel}
      onDismissRightPanel={dismissTaskPanel}
      rightPanel={
        !settingsOpen && rightPanelOpen ? (
          <TaskPanel
            title={panelTitle}
            attention={pendingLocator}
            onBack={
              panelTarget.kind === "review" && panelTarget.selectedChangeId
                ? returnToReview
                : undefined
            }
            backLabel={t("task_panel.back_review")}
            onClose={dismissTaskPanel}
          >
            {panelTarget.kind === "empty" ? (
              <p className="task-panel-empty">{t("task_panel.empty")}</p>
            ) : panelTarget.kind === "tool" && selectedTool ? (
              <ToolDetailView tool={selectedTool} />
            ) : panelTarget.kind === "preview" &&
              previewMatchesTarget &&
              filePreviewViewState ? (
              <FilePreviewView
                key={`${panelTarget.taskId}:${panelTarget.runId}:${panelTarget.referenceId}`}
                state={filePreviewViewState}
                onRefresh={refreshFilePreview}
              />
            ) : panelTarget.kind === "review" &&
              panelTarget.selectedChangeId ? (
              diffMatchesTarget && fileChangeDiffViewState ? (
                <FileChangeDiffView
                  state={fileChangeDiffViewState}
                  onRefresh={refreshFileChangeDiff}
                />
              ) : null
            ) : reviewedFileChanges ? (
              <FileChangesView
                observation={reviewedFileChanges.observation}
                changes={reviewedFileChanges.changes}
                onSelect={openFileChange}
              />
            ) : null}
          </TaskPanel>
        ) : null
      }
      overlay={
        settingsOpen ? (
          <SettingsPage
            account={snapshot.account}
            models={snapshot.models}
            permissionProfiles={{
              enabled: snapshot.capabilities.permissionProfiles,
              available: snapshot.permissions.availableProfiles,
              defaultProfile: snapshot.permissions.defaultProfile,
              busy: permissionBusy,
            }}
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
            onCancel={() => void cancelAccountOperation()}
            onSelectApiKey={(id) =>
              metaskProvider
                ? void runExecutionCommand(() =>
                    client.selectMetaskApiKey({
                      sourceId: `metask:${id}`,
                      expectedMetaskSelectionRevision:
                        snapshot.models.metaskSelectionRevision,
                      expectedCatalogGeneration:
                        metaskProvider.catalogGeneration,
                    }),
                  )
                : undefined
            }
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
            onLogout={() => void runAccountCommand(() => client.logout())}
            onSetDefaultPermissionProfile={(profile) =>
              void setDefaultPermissionProfile(profile)
            }
          />
        ) : null
      }
    >
      {route === "skills" ? (
        <SkillsPage
          management={snapshot.skillManagement}
          personalCatalog={snapshot.skillCatalog}
          workspaces={snapshot.workspaces}
          query={skillsQuery}
          refreshing={
            skillCatalogBusy || snapshot.skillCatalog.availability === "loading"
          }
          disabled={bridgeUnavailable}
          onQuery={setSkillsQuery}
          onRefresh={() => void refreshSkillsPageCatalog()}
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
            commitSkillMutation(() => client.retrySkillVerification(installId))
          }
          onExport={(installId) => client.exportSkill(installId)}
          onDetail={(installId) => client.skillDetail(installId)}
        />
      ) : route === "mcp" ? (
        <McpPage
          management={snapshot.mcp}
          capabilities={{
            connectionApproval: snapshot.capabilities.mcpConnectionApproval,
            secretCapture: snapshot.capabilities.mcpSecretCapture,
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
          onCaptureSecret={(generation, serverId, slot) =>
            commitMcpMutation(() =>
              client.captureMcpSecret(generation, serverId, slot),
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
      ) : route === "scheduled-tasks" ? (
        <ScheduledTasksPage
          snapshot={snapshot}
          disabled={bridgeUnavailable || !snapshot.capabilities.scheduledTasks}
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
          onRecover={() => client.recoverScheduledTaskStore(snapshot.revision)}
          onOpenTask={(taskId) => {
            const task = snapshot.tasks.find((item) => item.id === taskId);
            if (!task) return;
            openTask(taskId);
          }}
        />
      ) : (
        <div
          className="workbench-view"
          data-view={newTaskDraftActive ? "new-task" : "task"}
        >
          {activeTask && (
            <AlertDialog.Root
              open={confirmDelete}
              onOpenChange={(open) => !open && closeDeleteConfirmation()}
            >
              <AlertDialog.Portal>
                <AlertDialog.Backdrop />
                <AlertDialog.Popup>
                  <AlertDialog.Title id="task-delete-title">
                    {t("task.delete_confirm_title")}
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
                      onClick={closeDeleteConfirmation}
                    >
                      {t("common.cancel")}
                    </Button>
                    <Button
                      type="button"
                      variant="danger"
                      size="md"
                      disabled={taskMutationDisabled}
                      onClick={() => void deleteTask()}
                    >
                      {t("task.delete")}
                    </Button>
                  </div>
                </AlertDialog.Popup>
              </AlertDialog.Portal>
            </AlertDialog.Root>
          )}

          {viewSyncFailed && (
            <section className="sync-failure task-sync-failure" role="alert">
              <h3>{t(connectionFailure.titleId)}</h3>
              <p>{t(connectionFailure.helpId)}</p>
              {connectionRetryable && (
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={connectionBusy}
                  onClick={() => void retryViewSynchronization()}
                >
                  {connectionBusy
                    ? t("connection.retrying")
                    : t("connection.retry")}
                </Button>
              )}
              {connectionShellStatus?.diagnostic && (
                <details>
                  <summary>{t("connection.details")}</summary>
                  <p>
                    {connectionShellStatus.sourceId
                      ? `${t(connectionShellStatus.sourceId)}: `
                      : ""}
                    {connectionShellStatus.diagnostic}
                  </p>
                </details>
              )}
            </section>
          )}

          {newTaskDraftActive ? (
            <NewTaskView
              hasWorkspace={Boolean(composerWorkspace)}
              composer={composerFooter}
              permissionProfiles={
                snapshot.capabilities.permissionProfiles
                  ? snapshot.permissions.availableProfiles
                  : []
              }
              permissionProfile={newTaskPermissionProfile}
              onPermissionProfileChange={setNewTaskPermissionOverride}
            />
          ) : (
            <>
              <TaskContent
                task={activeTask}
                revision={snapshot.revision}
                composerHasDraft={composerDraftHasContent(composerDraft)}
                retryAvailable={taskCanCompose && !taskOperationInFlight}
                responseDisabled={bridgeUnavailable}
                fileChangesEnabled={snapshot.capabilities.typedFileChanges}
                onPrepareRetry={prepareRetry}
                onOpenTool={openToolDetail}
                onPreviewFile={openFilePreview}
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
              {composerFooter}
            </>
          )}
        </div>
      )}
      <GlobalSearch
        open={searchOpen}
        query={searchQuery}
        results={searchResults}
        onQuery={setSearchQuery}
        onClose={() => {
          setSearchOpen(false);
          setSearchQuery("");
        }}
        onSelect={selectSearchResult}
      />
    </AppShell>
  );
}
