import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";

import { AppShell } from "./AppShell.tsx";
import { Icon } from "../components/ui/Icon.tsx";
import { AccountIdentity } from "../features/account/AccountIdentity.tsx";
import { AccountGate } from "../features/account/AccountGate.tsx";
import { requiresAccountGate } from "../features/account/gating.ts";
import {
  SettingsPage,
  type SettingsFocusTarget,
} from "../features/settings/SettingsPage.tsx";
import { ComposerFooter } from "../features/composer/ComposerFooter.tsx";
import { ApprovalPanel } from "../features/approvals/ApprovalPanel.tsx";
import { UiRecordCard } from "../features/approvals/UiRecordCard.tsx";
import {
  uiRequestIdentity,
  uiResponsePhase,
} from "../features/approvals/response-state.ts";
import { useUiResponseStates } from "../features/approvals/useUiResponseStates.ts";
import { GlobalSearch } from "../features/search/GlobalSearch.tsx";
import { TaskActivity } from "../features/task-activity/TaskActivity.tsx";
import { TaskTimeline } from "../features/timeline/TaskTimeline.tsx";
import {
  TaskSignals,
  WorkspaceNavigation,
} from "../features/workspaces/WorkspaceNavigation.tsx";
import {
  useNewTaskDrafts,
  useTaskDrafts,
} from "../features/composer/useTaskDrafts.ts";
import {
  newTaskDraftStorageId,
  prepareRetryDraft,
} from "../features/composer/drafts.ts";
import { submitTaskInstruction } from "../features/composer/submitTaskInstruction.ts";
import { resolveFirstSendWorkspace } from "../features/composer/firstSendWorkspace.ts";
import {
  BridgeClient,
  BridgeCommandTimeoutError,
  RendererBridgeContractError,
} from "../bridge/client.ts";
import {
  WorkbenchConnection,
  type WorkbenchConnectionStatus,
} from "../bridge/connection.ts";
import type {
  TaskCreateReason,
  TaskRunReason,
  UiResponsePayload,
  WorkspaceMutationReason,
} from "../bridge/contracts.ts";
import { useI18n, type MessageId } from "../i18n/context.ts";
import { primaryShortcutModifier } from "../platform/keyboard.ts";
import {
  searchWorkbench,
  isRunInFlight,
  selectActiveTask,
  selectCurrentWorkspace,
  taskDisplayState,
  workspaceLabel,
  workspaceSummaries,
  type SearchResult,
} from "../workbench/selectors.ts";
import { chooseWorkspaceWithDraft } from "../features/workspaces/chooseWorkspace.ts";
import { initialWorkbenchState, workbenchReducer } from "../workbench/store.ts";
import {
  accountMutationBlocksTaskAdmission,
  PendingScopes,
} from "../workbench/pendingScopes.ts";

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

type MutationReason =
  TaskCreateReason | TaskRunReason | WorkspaceMutationReason;

function mutationReasonMessageId(reason: MutationReason): MessageId {
  return `mutation.reason.${reason}`;
}

type StatusState = {
  id: MessageId;
  values?: Record<string, string>;
  diagnostic?: string;
  sourceId?: MessageId;
};

function connectionStatus(status: WorkbenchConnectionStatus): StatusState {
  if (status.kind === "connected")
    return {
      id: status.recovered ? "connection.recovered" : "connection.connected",
    };
  if (status.kind === "refresh_failed")
    return {
      id: "connection.refresh_failed",
      diagnostic: status.diagnostic,
    };
  return {
    id: "connection.failed",
    diagnostic: status.diagnostic,
    sourceId: `connection.source.${status.source}`,
  };
}

export default function App() {
  const { t } = useI18n();
  const shortcutModifier = primaryShortcutModifier();
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [showArchived, setShowArchived] = useState(false);
  const [route, setRoute] = useState<"workbench" | "settings">("workbench");
  const [settingsFocus, setSettingsFocus] =
    useState<SettingsFocusTarget>("title");
  const [workbenchEntered, setWorkbenchEntered] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [taskMenuOpen, setTaskMenuOpen] = useState(false);
  const [status, setStatus] = useState<StatusState>({
    id: "connection.connecting",
  });
  const [accountBusy, setAccountBusy] = useState(false);
  const [workspaceBusy, setWorkspaceBusy] = useState(false);
  const [taskPending, setTaskPending] = useState<Record<string, string>>({});
  const [cancelPending, setCancelPending] = useState<Record<string, true>>({});
  const [connectionBusy, setConnectionBusy] = useState(false);
  const [accountCancelBusy, setAccountCancelBusy] = useState(false);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [viewSyncFailed, setViewSyncFailed] = useState(false);
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
  const accountCancelBusyRef = useRef(false);
  const workspaceBusyRef = useRef(false);
  const connectionBusyRef = useRef(false);
  const taskMenu = useRef<HTMLDivElement>(null);
  const composer = useRef<HTMLTextAreaElement>(null);
  const snapshot = workbench.snapshot;
  const activeTask = useMemo(() => selectActiveTask(workbench), [workbench]);
  const currentWorkspaceId = selectCurrentWorkspace(workbench);
  const currentWorkspace = snapshot.workspaces.find(
    (workspace) => workspace.id === currentWorkspaceId,
  );
  const summaries = useMemo(() => workspaceSummaries(snapshot), [snapshot]);
  const currentTasks = useMemo(
    () =>
      snapshot.tasks.filter((task) => task.workspaceId === currentWorkspaceId),
    [currentWorkspaceId, snapshot],
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
  const prompt = newTaskDraftActive ? newTaskDrafts.draft : taskDrafts.draft;
  const updatePrompt = newTaskDraftActive
    ? newTaskDrafts.updateDraft
    : taskDrafts.updateDraft;
  const bridgeUnavailable = viewSyncFailed || !bridgeReady;
  const currentTaskScope = activeTask ? `task:${activeTask.id}` : "new-task";
  const taskMutationDisabled =
    bridgeUnavailable || currentTaskScope in taskPending;
  const taskCanCompose =
    newTaskDraftActive ||
    (activeTask?.lifecycle === "open" &&
      activeTask.continuationAvailable &&
      !activeTask.archived);
  const runInFlight = isRunInFlight(activeTask);
  const canSubmit =
    taskCanCompose &&
    (!newTaskDraftActive || snapshot.account.canCreateTask) &&
    !accountMutationBlocksTaskAdmission(newTaskDraftActive, accountBusy) &&
    !runInFlight &&
    prompt.trim().length > 0 &&
    !taskMutationDisabled &&
    !workspaceBusy;
  const selectedModel = snapshot.account.models.find(
    (model) => model.selectionId === snapshot.account.selectedModelSelectionId,
  );
  const selectedModelLabel =
    selectedModel?.displayName ||
    selectedModel?.selectionId ||
    t("account.choose_model");
  const selectedModelId = selectedModel?.selectionId ?? "";
  const composerWorkspaceId =
    activeTask?.workspaceId || workbench.draftWorkspaceId || currentWorkspaceId;
  const composerWorkspace = snapshot.workspaces.find(
    (workspace) => workspace.id === composerWorkspaceId,
  );

  const refreshSnapshot = useCallback(() => {
    const current = connection.current;
    return current ? current.refresh() : Promise.resolve();
  }, []);

  useEffect(() => {
    let cancelled = false;
    const current = new WorkbenchConnection(client, {
      onSnapshot: (next) => {
        if (!cancelled) {
          observeUiResponseSnapshot(next);
          const projectedTaskIds = next.tasks.map((task) => task.id);
          taskDrafts.pruneDrafts([
            ...projectedTaskIds,
            ...pendingTaskDraftRetention.current,
          ]);
          for (const taskId of projectedTaskIds)
            pendingTaskDraftRetention.current.delete(taskId);
          dispatchWorkbench({ type: "snapshot.accepted", snapshot: next });
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
        if (!cancelled) setStatus(connectionStatus(next));
      },
      onReady: (ready) => {
        if (!cancelled) setBridgeReady(ready);
      },
      onViewSyncFailed: (failed) => {
        if (!cancelled) setViewSyncFailed(failed);
      },
    });
    connection.current = current;
    void current.start().catch((error) => {
      if (!cancelled) {
        setViewSyncFailed(true);
        if (!(error instanceof RendererBridgeContractError))
          setStatus({
            id: "connection.failed",
            diagnostic: errorText(error),
          });
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
      window.removeEventListener("pagehide", onPageHide);
      void current.stop();
    };
  }, [client, observeUiResponseSnapshot, taskDrafts.pruneDrafts]);

  useEffect(() => {
    if (snapshot.account.readiness === "ready") setWorkbenchEntered(true);
    if (snapshot.account.sessionState === "signed_out") {
      setWorkbenchEntered(false);
      setRoute("workbench");
    }
  }, [snapshot.account.readiness, snapshot.account.sessionState]);

  useEffect(() => {
    const openSearch = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setSearchOpen(true);
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "n") {
        event.preventDefault();
        setRoute("workbench");
        beginNewTask();
      }
    };
    window.addEventListener("keydown", openSearch);
    return () => window.removeEventListener("keydown", openSearch);
  }, [currentWorkspaceId]);

  useEffect(() => {
    setEditingTitle(false);
    setConfirmDelete(false);
    setTaskMenuOpen(false);
  }, [activeTask?.id]);

  useEffect(() => {
    if (
      snapshot.account.readiness !== "ready" ||
      activeTask !== null ||
      workbench.draftOpen
    )
      return;
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: currentWorkspaceId,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }, [
    activeTask,
    currentWorkspaceId,
    snapshot.account.readiness,
    workbench.draftOpen,
  ]);

  function focusPendingRequest() {
    const requestId = activeTask?.pendingUi?.requestId;
    if (!requestId) return;
    const target = document.getElementById(`ui-request-${requestId}`);
    target?.scrollIntoView({ block: "center", behavior: "smooth" });
    window.requestAnimationFrame(() => target?.focus());
  }

  useEffect(() => {
    if (!taskMenuOpen) return;
    const dismiss = (event: MouseEvent) => {
      if (!taskMenu.current?.contains(event.target as Node))
        setTaskMenuOpen(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setTaskMenuOpen(false);
      taskMenu.current?.querySelector<HTMLButtonElement>("button")?.focus();
    };
    document.addEventListener("mousedown", dismiss);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("mousedown", dismiss);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [taskMenuOpen]);

  function closeTaskMenuAndRestoreFocus() {
    setTaskMenuOpen(false);
    window.requestAnimationFrame(() =>
      taskMenu.current?.querySelector<HTMLButtonElement>("button")?.focus(),
    );
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
      setStatus({ id: "connection.recovered" });
    } catch (error) {
      setViewSyncFailed(true);
      setBridgeReady(false);
      setStatus({
        id: "connection.failed",
        diagnostic: errorText(error),
      });
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
    if (bridgeUnavailable || accountBusyRef.current) return;
    accountBusyRef.current = true;
    setAccountBusy(true);
    try {
      const result = await invoke();
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id:
            result.errorCode === "generation_mismatch"
              ? "account.options_updated"
              : "account.command_rejected",
        });
        return;
      }
      await refreshAfterCommit("account.updated", "operation.account");
    } catch (error) {
      if (await reconcileCommandTimeout(error, "operation.account")) return;
      await refreshSnapshot().catch(() => undefined);
      setStatus({ id: "account.command_failed" });
    } finally {
      accountBusyRef.current = false;
      setAccountBusy(false);
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
    accountCancelBusyRef.current = true;
    setAccountCancelBusy(true);
    try {
      const result = await client.cancelAccountOperation();
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus({ id: "account.cancel_rejected" });
        return;
      }
      await refreshAfterCommit("account.cancelled", "operation.account_cancel");
    } catch (error) {
      if (await reconcileCommandTimeout(error, "operation.account_cancel"))
        return;
      await refreshSnapshot().catch(() => undefined);
      setStatus({ id: "account.cancel_failed" });
    } finally {
      accountCancelBusyRef.current = false;
      setAccountCancelBusy(false);
    }
  }

  async function chooseWorkspace(openDraft = false) {
    if (bridgeUnavailable || workspaceBusyRef.current) return null;
    workspaceBusyRef.current = true;
    setWorkspaceBusy(true);
    try {
      const outcome = await chooseWorkspaceWithDraft({
        choose: () => client.chooseWorkspace(),
        refresh: refreshSnapshot,
        openDraft,
        sourceDraftId: newTaskDraftId,
        moveDraft: (sourceId, targetId) =>
          newTaskDrafts.moveDraft(sourceId, targetId),
      });
      if (outcome.kind === "selected") {
        const { result } = outcome;
        dispatchWorkbench(
          openDraft
            ? {
                type: "task.draft.opened",
                workspaceId: result.workspaceId,
              }
            : {
                type: "workspace.selected",
                workspaceId: result.workspaceId,
              },
        );
        setStatus({ id: "workspace.grant_confirmed" });
        if (openDraft)
          window.requestAnimationFrame(() => composer.current?.focus());
        return result;
      }
      if (outcome.kind === "conflict") {
        dispatchWorkbench({
          type: "task.draft.opened",
          workspaceId: outcome.workspaceId,
        });
        setStatus({ id: "workspace.draft_conflict" });
        window.requestAnimationFrame(() => composer.current?.focus());
        return null;
      }
      setStatus({ id: "workspace.selection_cancelled" });
      if (openDraft)
        window.requestAnimationFrame(() => composer.current?.focus());
      return null;
    } catch (error) {
      setStatus({
        id: "workspace.selection_failed",
        values: { error: t("mutation.transport_failed") },
        diagnostic: errorText(error),
      });
      if (openDraft)
        window.requestAnimationFrame(() => composer.current?.focus());
      return null;
    } finally {
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
    }
  }

  async function selectWorkspaceById(
    workspaceId: string,
    taskId: string | null = null,
  ) {
    if (bridgeUnavailable || workspaceBusyRef.current) return;
    workspaceBusyRef.current = true;
    setWorkspaceBusy(true);
    try {
      const workspace = snapshot.workspaces.find(
        (candidate) => candidate.id === workspaceId,
      );
      if (!workspace) {
        setStatus({ id: "workspace.selection_unavailable" });
        return;
      }
      const result = await client.selectWorkspace(workspaceId, workspace.epoch);
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus({ id: mutationReasonMessageId(result.reason) });
        return;
      }
      await refreshSnapshot();
      dispatchWorkbench({ type: "workspace.selected", workspaceId });
      if (taskId !== null) dispatchWorkbench({ type: "task.selected", taskId });
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus({
        id: "workspace.selection_failed",
        values: { error: t("mutation.transport_failed") },
        diagnostic: errorText(error),
      });
    } finally {
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
    }
  }

  async function removeWorkspaceById(workspaceId: string) {
    if (bridgeUnavailable || workspaceBusyRef.current) return;
    workspaceBusyRef.current = true;
    setWorkspaceBusy(true);
    try {
      const workspace = snapshot.workspaces.find(
        (candidate) => candidate.id === workspaceId,
      );
      if (!workspace) {
        setStatus({ id: "workspace.selection_unavailable" });
        return;
      }
      const result = await client.removeWorkspace(workspaceId, workspace.epoch);
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus({ id: mutationReasonMessageId(result.reason) });
        return;
      }
      await refreshAfterCommit(
        "workspace.removal_started",
        "operation.workspace_remove",
      );
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus({
        id: "mutation.transport_failed",
        diagnostic: errorText(error),
      });
    } finally {
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
    }
  }

  function beginNewTask() {
    pendingTaskSelection.current = null;
    setRoute("workbench");
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: currentWorkspaceId,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }

  function openSettings(target: SettingsFocusTarget = "title") {
    setSettingsFocus(target);
    setRoute("settings");
  }

  async function submitRun() {
    if (!canSubmit) return;
    const submitted = prompt;
    const existingTaskId = activeTask?.id ?? null;
    let submittedDraftId = newTaskDraftId;
    const workspace = await resolveFirstSendWorkspace({
      taskId: existingTaskId,
      workspace:
        existingTaskId !== null ||
        composerWorkspace?.authorization === "available"
          ? composerWorkspace && composerWorkspaceId
            ? {
                workspaceId: composerWorkspaceId,
                workspaceEpoch: composerWorkspace.epoch,
              }
            : null
          : null,
      chooseWorkspace: async () => {
        const selected = await chooseWorkspace(true);
        if (selected) submittedDraftId = selected.workspaceId;
        if (!selected) return null;
        try {
          const latest = await client.fetchSnapshot();
          const chosenWorkspace = latest.workspaces.find(
            (candidate) => candidate.id === selected.workspaceId,
          );
          return chosenWorkspace
            ? {
                workspaceId: chosenWorkspace.id,
                workspaceEpoch: chosenWorkspace.epoch,
              }
            : null;
        } catch (error) {
          setStatus({
            id: "connection.refresh_failed",
            diagnostic: errorText(error),
          });
          return null;
        }
      },
    });
    if (workspace.kind === "cancelled") return;
    let pendingScope = currentTaskScope;
    if (!beginTaskPendingOperation(pendingScope, "run")) return;
    if (newTaskDraftActive && submittedDraftId)
      newTaskDrafts.clearDraft(submittedDraftId);
    else updatePrompt("");
    try {
      const result = await submitTaskInstruction({
        client,
        taskId: existingTaskId,
        workspaceId: workspace.workspaceId,
        expectedWorkspaceEpoch: workspace.workspaceEpoch,
        expectedExecutionGeneration: snapshot.account.executionGeneration,
        expectedBindingEpoch: activeTask?.binding.epoch ?? null,
        instruction: submitted,
        onTaskCreated: (taskId) => {
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
          await reconcileCommandTimeout(result.error, "operation.task_create")
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id: "task.create_failed",
          values: { error: t("mutation.transport_failed") },
          diagnostic: errorText(result.error),
        });
        return;
      }
      if (result.kind === "create_rejected") {
        if (submittedDraftId)
          newTaskDrafts.setDraft(submittedDraftId, submitted);
        await refreshSnapshot().catch(() => undefined);
        setStatus({ id: mutationReasonMessageId(result.reason) });
        return;
      }
      if (result.kind === "run_failed") {
        taskDrafts.setDraft(result.taskId, submitted);
        if (await reconcileCommandTimeout(result.error, "operation.run_submit"))
          return;
        setStatus({
          id: "run.start_failed",
          values: { error: t("mutation.transport_failed") },
          diagnostic: errorText(result.error),
        });
        await refreshSnapshot().catch(() => undefined);
        return;
      }
      if (result.kind === "run_rejected") {
        taskDrafts.setDraft(result.taskId, submitted);
        await refreshSnapshot().catch(() => undefined);
        setStatus({ id: mutationReasonMessageId(result.reason) });
        return;
      }
      taskDrafts.clearDraft(result.taskId);
      await refreshAfterCommit("run.started", "operation.run_submit");
    } finally {
      endTaskPendingOperation(pendingScope);
    }
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
        if (await reconcileCommandTimeout(error, "operation.run_stop")) return;
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id: "run.stop_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("run.stop_requested", "operation.run_stop");
    } finally {
      setCancelPendingForTask(taskId, false);
    }
  }

  async function closeTask() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      taskMutationDisabled ||
      !activeTask ||
      (activeTask.lifecycle === "closing" && !activeTask.closeFailed) ||
      activeTask.lifecycle === "closed"
    )
      return;
    const scope = `task:${activeTask.id}`;
    if (!beginTaskPendingOperation(scope, "close")) return;
    try {
      try {
        await client.closeTask(activeTask.id);
      } catch (error) {
        if (await reconcileCommandTimeout(error, "operation.task_close"))
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id: "task.close_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("task.close_requested", "operation.task_close");
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  async function renameTask() {
    if (!activeTask || taskMutationDisabled || !titleDraft.trim()) return;
    const scope = `task:${activeTask.id}`;
    if (!beginTaskPendingOperation(scope, "rename")) return;
    try {
      try {
        await client.renameTask(activeTask.id, titleDraft.trim());
      } catch (error) {
        if (await reconcileCommandTimeout(error, "operation.task_rename"))
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id: "task.rename_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      setEditingTitle(false);
      await refreshAfterCommit("task.renamed", "operation.task_rename");
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  async function setArchived(archived: boolean) {
    if (
      !activeTask ||
      taskMutationDisabled ||
      activeTask.currentRunPhase !== null
    )
      return;
    const scope = `task:${activeTask.id}`;
    if (!beginTaskPendingOperation(scope, "archive")) return;
    try {
      try {
        await client.setTaskArchived(activeTask.id, archived);
      } catch (error) {
        if (
          await reconcileCommandTimeout(
            error,
            archived ? "operation.task_archive" : "operation.task_restore",
          )
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id: archived ? "task.archive_failed" : "task.restore_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      if (archived) setShowArchived(true);
      await refreshAfterCommit(
        archived ? "task.archived_status" : "task.restored",
        archived ? "operation.task_archive" : "operation.task_restore",
      );
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  async function deleteTask() {
    if (
      !activeTask ||
      taskMutationDisabled ||
      activeTask.lifecycle !== "closed"
    )
      return;
    const scope = `task:${activeTask.id}`;
    if (!beginTaskPendingOperation(scope, "delete")) return;
    try {
      try {
        await client.deleteTask(activeTask.id);
      } catch (error) {
        if (await reconcileCommandTimeout(error, "operation.task_delete"))
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus({
          id: "task.delete_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      taskDrafts.clearDraft(activeTask.id);
      setConfirmDelete(false);
      await refreshAfterCommit("task.deleted", "operation.task_delete");
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  function selectSearchResult(result: SearchResult) {
    pendingTaskSelection.current = null;
    void selectWorkspaceById(result.workspaceId, result.taskId);
    setSearchOpen(false);
    setSearchQuery("");
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
    } catch (error) {
      failUiResponse(identity);
      if (await reconcileCommandTimeout(error, "operation.ui_response")) return;
      setStatus({
        id: "approval.response_failed",
        values: { error: errorText(error) },
      });
      await refreshSnapshot().catch(() => undefined);
      return;
    }
    acceptUiResponse(identity);
    await refreshAfterCommit("approval.response_sent", "operation.ui_response");
  }

  function prepareRetry(instruction: string) {
    if (!activeTask || !taskCanCompose) return;
    const prepared = prepareRetryDraft(prompt, instruction);
    switch (prepared.kind) {
      case "prepared":
        updatePrompt(prepared.draft);
        setStatus({ id: "run.retry_prepared" });
        break;
      case "preserved":
        setStatus({ id: "run.draft_preserved" });
        break;
      case "too_long":
        setStatus({ id: "run.retry_too_long" });
        break;
    }
    window.requestAnimationFrame(() => composer.current?.focus());
  }

  async function refreshAfterCommit(success: MessageId, operation: MessageId) {
    try {
      await refreshSnapshot();
      setStatus({ id: success });
    } catch (error) {
      setStatus({
        id: "view.refresh_after_commit_failed",
        values: {
          operation: t(operation),
          error: errorText(error),
        },
      });
    }
  }

  async function reconcileCommandTimeout(error: unknown, operation: MessageId) {
    if (!(error instanceof BridgeCommandTimeoutError)) return false;
    try {
      await refreshSnapshot();
      setStatus({
        id: "command.timeout_reconciled",
        values: { operation: t(operation) },
      });
    } catch {
      setStatus({
        id: "command.timeout_sync_failed",
        values: { operation: t(operation) },
      });
    }
    return true;
  }

  const accountGateRequired = requiresAccountGate(
    workbenchEntered,
    snapshot.account,
  );
  if (accountGateRequired)
    return (
      <AccountGate
        account={snapshot.account}
        disabled={bridgeUnavailable || accountBusy}
        cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
        connectionFailed={viewSyncFailed}
        connectionDiagnostic={status.diagnostic}
        reconnecting={connectionBusy}
        notice={t(status.id, status.values)}
        onReconnect={() => void retryViewSynchronization()}
        onBeginLogin={() => void runAccountCommand(() => client.beginLogin())}
        onReopenLogin={() => void runAccountCommand(() => client.reopenLogin())}
        onReauthenticate={() =>
          void runAccountCommand(() => client.reauthenticate())
        }
        onCancel={() => void cancelAccountOperation()}
        onRetry={() =>
          void runAccountCommand(() => client.refreshAccountCatalog())
        }
        onSelectApiKey={(id) =>
          void runAccountCommand(() =>
            client.selectApiKey(
              id,
              snapshot.account.catalogGeneration,
              snapshot.account.executionGeneration,
            ),
          )
        }
        onSelectModel={(id) =>
          void runAccountCommand(() =>
            client.selectModel(
              id,
              snapshot.account.catalogGeneration,
              snapshot.account.executionGeneration,
            ),
          )
        }
      />
    );

  const currentTaskState = activeTask ? taskDisplayState(activeTask) : null;
  const currentTaskStatus = !currentTaskState
    ? t(newTaskDraftActive ? "task.new" : "task.open")
    : currentTaskState.kind === "phase"
      ? t(`task.phase.${currentTaskState.value}`)
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

  return (
    <AppShell
      taskTitle={route === "settings" ? t("settings.title") : activeTaskTitle}
      onSearch={() => setSearchOpen(true)}
      workspaceLabel={
        route === "settings"
          ? t("settings.account_models")
          : currentWorkspace?.displayName ||
            currentWorkspace?.canonicalRoot ||
            t("workspace.none")
      }
      status={t(status.id, status.values)}
      left={
        <div className="sidebar-frame">
          <div className="sidebar-primary">
            <div className="brand-lockup">
              <span className="brand-mark" aria-hidden="true">
                M
              </span>
              <div>
                <p className="brand-name">{t("app.name")}</p>
                <p className="brand-subtitle">{t("app.window_label")}</p>
              </div>
            </div>
            <button
              className="new-task-button focus-ring"
              data-active={route === "workbench" && newTaskDraftActive}
              disabled={bridgeUnavailable}
              onClick={beginNewTask}
            >
              <Icon name="plus" />
              <span>{t("task.new")}</span>
              <kbd>{shortcutModifier}N</kbd>
            </button>

            <div className="sidebar-navigation">
              <WorkspaceNavigation
                summaries={summaries}
                currentWorkspaceId={currentWorkspaceId}
                tasks={currentTasks}
                activeTaskId={
                  route === "workbench" ? (activeTask?.id ?? null) : null
                }
                showArchived={showArchived}
                disabled={bridgeUnavailable || workspaceBusy}
                onChooseWorkspace={() => void chooseWorkspace(false)}
                onRemoveWorkspace={(workspaceId) =>
                  void removeWorkspaceById(workspaceId)
                }
                onRetryRemoval={(workspaceId) =>
                  void removeWorkspaceById(workspaceId)
                }
                onSelectWorkspace={(workspaceId) => {
                  pendingTaskSelection.current = null;
                  setRoute("workbench");
                  void selectWorkspaceById(workspaceId);
                }}
                onSelectTask={(taskId) => {
                  pendingTaskSelection.current = null;
                  setRoute("workbench");
                  dispatchWorkbench({ type: "task.selected", taskId });
                }}
                onToggleArchived={() => setShowArchived((shown) => !shown)}
              />
            </div>
          </div>

          <AccountIdentity
            account={snapshot.account}
            active={route === "settings"}
            disabled={bridgeUnavailable || accountBusy}
            onOpenSettings={openSettings}
            onReauthenticate={() =>
              void runAccountCommand(() => client.reauthenticate())
            }
          />
        </div>
      }
      activity={
        route === "workbench" && activeTask ? (
          <>
            <h2 className="activity-title">{t("activity.title")}</h2>
            {viewSyncFailed && (
              <section className="sync-failure" role="alert">
                <h3>{t("connection.failed")}</h3>
                <p>{t("connection.failed_help")}</p>
                <button
                  className="secondary-button focus-ring"
                  disabled={connectionBusy}
                  onClick={() => void retryViewSynchronization()}
                >
                  {connectionBusy
                    ? t("connection.retrying")
                    : t("connection.retry")}
                </button>
                {status.diagnostic && (
                  <details>
                    <summary>{t("connection.details")}</summary>
                    <p>
                      {status.sourceId ? `${t(status.sourceId)}: ` : ""}
                      {status.diagnostic}
                    </p>
                  </details>
                )}
              </section>
            )}

            <TaskActivity
              task={activeTask}
              draft={newTaskDraftActive}
              currentStatus={currentTaskStatus}
              onFocusPending={focusPendingRequest}
            />
          </>
        ) : null
      }
    >
      {route === "settings" ? (
        <SettingsPage
          account={snapshot.account}
          focusTarget={settingsFocus}
          disabled={bridgeUnavailable || accountBusy}
          cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
          onBack={() => setRoute("workbench")}
          onRefresh={() =>
            void runAccountCommand(() => client.refreshAccountCatalog())
          }
          onCancel={() => void cancelAccountOperation()}
          onSelectApiKey={(id) =>
            void runAccountCommand(() =>
              client.selectApiKey(
                id,
                snapshot.account.catalogGeneration,
                snapshot.account.executionGeneration,
              ),
            )
          }
          onSelectModel={(id) =>
            void runAccountCommand(() =>
              client.selectModel(
                id,
                snapshot.account.catalogGeneration,
                snapshot.account.executionGeneration,
              ),
            )
          }
          onReauthenticate={() =>
            void runAccountCommand(() => client.reauthenticate())
          }
          onLogout={() => void runAccountCommand(() => client.logout())}
        />
      ) : (
        <>
          <header className="task-header">
            <div className="min-w-0">
              <p className="task-header-workspace">
                {composerWorkspace?.canonicalRoot || t("workspace.none")}
              </p>
              {activeTask && editingTitle ? (
                <form
                  className="task-title-editor"
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
                      if (event.key === "Escape") setEditingTitle(false);
                    }}
                  />
                  <button
                    className="secondary-button focus-ring"
                    disabled={!titleDraft.trim() || taskMutationDisabled}
                  >
                    {t("common.save")}
                  </button>
                  <button
                    type="button"
                    className="text-button focus-ring"
                    onClick={() => setEditingTitle(false)}
                  >
                    {t("common.cancel")}
                  </button>
                </form>
              ) : (
                <div className="task-title-row">
                  <h1>
                    {activeTask
                      ? activeTaskTitle
                      : newTaskDraftActive
                        ? t("task.new")
                        : t("task.open")}
                  </h1>
                  {activeTask && <TaskSignals task={activeTask} />}
                </div>
              )}
            </div>
            <div className="task-actions">
              {activeTask &&
                activeTask.currentRunId !== "0" &&
                activeTask.currentRunPhase !== null &&
                activeTask.currentRunPhase !== "stopping" && (
                  <button
                    className="danger-button focus-ring"
                    disabled={
                      bridgeUnavailable || activeTask.id in cancelPending
                    }
                    onClick={() => void cancelRun()}
                  >
                    <Icon name="stop" />
                    {t("task.stop")}
                  </button>
                )}
              {activeTask && (
                <div className="task-menu" ref={taskMenu}>
                  <button
                    className="secondary-button focus-ring"
                    aria-expanded={taskMenuOpen}
                    aria-haspopup="menu"
                    onClick={() => setTaskMenuOpen((open) => !open)}
                  >
                    {t("task.actions")}
                  </button>
                  {taskMenuOpen && (
                    <div
                      className="task-menu-popover"
                      role="menu"
                      onKeyDown={(event) => {
                        if (
                          event.key !== "ArrowDown" &&
                          event.key !== "ArrowUp"
                        )
                          return;
                        const items = [
                          ...event.currentTarget.querySelectorAll<HTMLButtonElement>(
                            "button:not([disabled])",
                          ),
                        ];
                        if (items.length === 0) return;
                        event.preventDefault();
                        const index = items.indexOf(
                          document.activeElement as HTMLButtonElement,
                        );
                        const offset = event.key === "ArrowDown" ? 1 : -1;
                        const next =
                          index < 0
                            ? event.key === "ArrowDown"
                              ? 0
                              : items.length - 1
                            : (index + offset + items.length) % items.length;
                        items[next].focus();
                      }}
                    >
                      <button
                        role="menuitem"
                        disabled={taskMutationDisabled}
                        onClick={() => {
                          setTitleDraft(activeTask.title);
                          setEditingTitle(true);
                          setTaskMenuOpen(false);
                        }}
                      >
                        {t("task.rename")}
                      </button>
                      <button
                        role="menuitem"
                        disabled={
                          taskMutationDisabled ||
                          runInFlight ||
                          activeTask.lifecycle === "closing"
                        }
                        onClick={() => {
                          closeTaskMenuAndRestoreFocus();
                          void setArchived(!activeTask.archived);
                        }}
                      >
                        {activeTask.archived
                          ? t("task.restore")
                          : t("task.archive")}
                      </button>
                      <button
                        role="menuitem"
                        disabled={
                          (activeTask.lifecycle === "closing" &&
                            !activeTask.closeFailed) ||
                          activeTask.lifecycle === "closed" ||
                          taskMutationDisabled
                        }
                        onClick={() => {
                          closeTaskMenuAndRestoreFocus();
                          void closeTask();
                        }}
                      >
                        {activeTask.closeFailed
                          ? t("task.end_retry")
                          : activeTask.lifecycle === "closing"
                            ? t("task.ending")
                            : t("task.end")}
                      </button>
                      <button
                        role="menuitem"
                        className="is-danger"
                        disabled={
                          activeTask.lifecycle !== "closed" ||
                          taskMutationDisabled
                        }
                        onClick={() => {
                          setTaskMenuOpen(false);
                          setConfirmDelete(true);
                        }}
                      >
                        {t("task.delete")}
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          </header>

          {activeTask && confirmDelete && (
            <section
              className="delete-confirmation"
              role="alertdialog"
              aria-labelledby="task-delete-title"
              aria-describedby="task-delete-description"
            >
              <div>
                <strong id="task-delete-title">
                  {t("task.delete_confirm_title")}
                </strong>
                <span id="task-delete-description">
                  {t("task.delete_confirm_body")}
                </span>
              </div>
              <button
                autoFocus
                className="secondary-button focus-ring"
                onClick={() => setConfirmDelete(false)}
              >
                {t("common.cancel")}
              </button>
              <button
                className="danger-button focus-ring"
                disabled={taskMutationDisabled}
                onClick={() => void deleteTask()}
              >
                {t("task.delete")}
              </button>
            </section>
          )}

          <TaskTimeline
            task={activeTask}
            draft={newTaskDraftActive}
            draftHasWorkspace={Boolean(composerWorkspace)}
            revision={snapshot.revision}
            composerHasDraft={prompt.trim().length > 0}
            retryAvailable={taskCanCompose && !runInFlight}
            responseDisabled={bridgeUnavailable}
            onUseExample={(instruction) => {
              const prepared = prepareRetryDraft(prompt, instruction);
              if (prepared.kind === "prepared") updatePrompt(prepared.draft);
              else setStatus({ id: "run.draft_preserved" });
              window.requestAnimationFrame(() => composer.current?.focus());
            }}
            onPrepareRetry={prepareRetry}
            onRespond={(payload) => void respondUi(payload)}
            renderPendingUi={(props) => {
              const { taskId, ...panelProps } = props;
              const identity = uiRequestIdentity(taskId, props.pending);
              return (
                <ApprovalPanel
                  {...panelProps}
                  responsePhase={uiResponsePhase(uiResponseStates, identity)}
                />
              );
            }}
            renderUiRecord={(record) => <UiRecordCard record={record} />}
          />

          <ComposerFooter
            textareaRef={composer}
            archived={Boolean(activeTask?.archived)}
            closing={activeTask?.lifecycle === "closing"}
            closed={activeTask?.lifecycle === "closed"}
            unavailable={Boolean(
              activeTask &&
              activeTask.lifecycle === "open" &&
              !activeTask.continuationAvailable,
            )}
            prompt={prompt}
            composeDisabled={!taskCanCompose || taskMutationDisabled}
            canSubmit={canSubmit}
            runInFlight={Boolean(taskCanCompose && runInFlight)}
            accessRequired={Boolean(
              newTaskDraftActive &&
              composerWorkspace &&
              composerWorkspace.authorization !== "available",
            )}
            workspaceMissing={Boolean(newTaskDraftActive && !composerWorkspace)}
            workspaceLabel={
              composerWorkspace
                ? composerWorkspace.displayName ||
                  workspaceLabel(composerWorkspace.canonicalRoot)
                : t("workspace.none")
            }
            workspaceTitle={
              composerWorkspace?.canonicalRoot || t("workspace.none")
            }
            modelLabel={
              newTaskDraftActive
                ? selectedModelLabel
                : activeTask?.binding.modelDisplayName ||
                  activeTask?.binding.modelSelectionId ||
                  null
            }
            modelOptions={snapshot.account.models}
            selectedModelId={selectedModelId}
            modelEditable={newTaskDraftActive}
            modelSelectionDisabled={
              bridgeUnavailable ||
              accountBusy ||
              snapshot.account.operation !== "none" ||
              snapshot.account.models.length === 0
            }
            modelContextTitle={
              newTaskDraftActive
                ? t("settings.default_model_help")
                : t("settings.task_binding_model")
            }
            actionDisabled={bridgeUnavailable || workspaceBusy}
            onPromptChange={updatePrompt}
            onSubmit={() => void submitRun()}
            onConfirmAccess={() => void chooseWorkspace(true)}
            onSelectModel={(id) =>
              void runAccountCommand(() =>
                client.selectModel(
                  id,
                  snapshot.account.catalogGeneration,
                  snapshot.account.executionGeneration,
                ),
              )
            }
            onOpenModelSettings={() => openSettings("title")}
          />
        </>
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
