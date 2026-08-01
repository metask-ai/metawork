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
import { SkillsPage } from "../features/skills/SkillsPage.tsx";
import { ScheduledTasksPage } from "../features/scheduled-tasks/ScheduledTasksPage.tsx";
import {
  TaskInspector,
  type InspectorFocusRequest,
} from "../features/inspector/TaskInspector.tsx";
import { inspectorFocusReturnTarget } from "../features/inspector/inspector-interaction.ts";
import type { InspectorSection } from "../features/inspector/inspector-state.ts";
import { useInspectorSession } from "../features/inspector/useInspectorSession.ts";
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
  unscopedNewTaskDraftId,
} from "../features/composer/drafts.ts";
import { submitTaskInstruction } from "../features/composer/submitTaskInstruction.ts";
import {
  composerDraftHasContent,
  composerDraftToRunInput,
  composerDraftWithinLimits,
  emptyComposerDraft,
  isSkillDraftCurrent,
  maxSkillArguments,
  skillCatalogRefreshTarget,
  slashCommandNames,
  type ComposerDraft,
  type SlashCommandName,
  type SlashCommandState,
} from "../features/composer/slash.ts";
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
  RunInputView,
  TaskRunReason,
  UiResponsePayload,
  WorkspaceMutationReason,
} from "../bridge/contracts.ts";
import { useI18n, type MessageId } from "../i18n/context.ts";
import { primaryShortcutModifier } from "../platform/keyboard.ts";
import {
  searchWorkbench,
  sidebarTasks,
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
  WorkspaceNavigationIntents,
  type WorkspaceNavigationRequest,
} from "../workbench/workspace-navigation-intents.ts";
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

function connectionStatus(status: WorkbenchConnectionStatus): ShellStatus {
  if (status.kind === "connected")
    return quietStatus(
      status.recovered ? "connection.recovered" : "connection.connected",
      { scope: "connection" },
    );
  if (status.kind === "refresh_failed")
    return attentionStatus(
      "connection.refresh_failed",
      { scope: "connection" },
      {
        diagnostic: status.diagnostic,
      },
    );
  return attentionStatus(
    "connection.contract_failed",
    { scope: "connection" },
    {
      diagnostic: status.diagnostic,
      sourceId: `connection.source.${status.source}`,
    },
  );
}

export default function App() {
  const { t } = useI18n();
  const shortcutModifier = primaryShortcutModifier();
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [showArchived, setShowArchived] = useState(false);
  const [route, setRoute] = useState<ShellRoute>("workbench");
  const [settingsFocus, setSettingsFocus] =
    useState<SettingsFocusTarget>("title");
  const [workbenchEntered, setWorkbenchEntered] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [skillsQuery, setSkillsQuery] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [taskMenuOpen, setTaskMenuOpen] = useState(false);
  const [statuses, setStatuses] = useState<ShellStatusState>(() =>
    publishStatus(
      {},
      quietStatus("connection.connecting", { scope: "connection" }),
    ),
  );
  const [accountBusy, setAccountBusy] = useState(false);
  const [workspaceBusy, setWorkspaceBusy] = useState(false);
  const [skillCatalogBusy, setSkillCatalogBusy] = useState(false);
  const [taskPending, setTaskPending] = useState<Record<string, string>>({});
  const [cancelPending, setCancelPending] = useState<Record<string, true>>({});
  const [connectionBusy, setConnectionBusy] = useState(false);
  const [accountCancelBusy, setAccountCancelBusy] = useState(false);
  const [inspectorFocusRequest, setInspectorFocusRequest] =
    useState<InspectorFocusRequest>(null);
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
  const workspaceNavigationRunningRef = useRef(false);
  const workspaceNavigationIntents = useRef(new WorkspaceNavigationIntents());
  const connectionBusyRef = useRef(false);
  const taskMenu = useRef<HTMLDivElement>(null);
  const inspectorToggle = useRef<HTMLButtonElement>(null);
  const inspectorOpener = useRef<HTMLButtonElement | null>(null);
  const inspectorFocusSequence = useRef(0);
  const composer = useRef<HTMLTextAreaElement>(null);

  function setStatus(status: ShellStatus) {
    setStatuses((current) => publishStatus(current, status));
  }

  const snapshot = workbench.snapshot;
  const activeTask = useMemo(() => selectActiveTask(workbench), [workbench]);
  const inspector = useInspectorSession(activeTask);
  const currentWorkspaceId = selectCurrentWorkspace(workbench);
  const currentWorkspace = snapshot.workspaces.find(
    (workspace) => workspace.id === currentWorkspaceId,
  );
  const userWorkspaces = useMemo(
    () =>
      snapshot.workspaces.filter((workspace) => workspace.origin === "user"),
    [snapshot.workspaces],
  );
  const selectedUserWorkspaceId =
    userWorkspaces.find(
      (workspace) => workspace.id === snapshot.selectedWorkspaceId,
    )?.id ?? null;
  const navigationWorkspaceId =
    currentWorkspace?.origin === "user"
      ? currentWorkspace.id
      : selectedUserWorkspaceId;
  const summaries = useMemo(() => workspaceSummaries(snapshot), [snapshot]);
  const sidebarTaskItems = useMemo(
    () => sidebarTasks(snapshot, navigationWorkspaceId),
    [navigationWorkspaceId, snapshot],
  );
  const searchResults = useMemo(
    () => searchWorkbench(snapshot, searchQuery),
    [searchQuery, snapshot],
  );
  const taskDrafts = useTaskDrafts(activeTask?.id ?? null);
  const newTaskDraftActive = workbench.draftOpen || activeTask === null;
  const newTaskDraftId = newTaskDraftStorageId(
    newTaskDraftActive,
    workbench.draftWorkspaceId ?? navigationWorkspaceId,
  );
  const newTaskDrafts = useNewTaskDrafts(newTaskDraftId);
  const composerDraft = newTaskDraftActive
    ? newTaskDrafts.draft
    : taskDrafts.draft;
  const updateComposerDraft = newTaskDraftActive
    ? newTaskDrafts.updateDraft
    : taskDrafts.updateDraft;
  const bridgeUnavailable = viewSyncFailed || !bridgeReady;
  const accountGateRequired = requiresAccountGate(
    workbenchEntered,
    snapshot.account,
  );
  const currentTaskScope = activeTask ? `task:${activeTask.id}` : "new-task";
  const taskMutationDisabled =
    bridgeUnavailable || currentTaskScope in taskPending;
  const taskCanCompose =
    newTaskDraftActive ||
    (activeTask?.lifecycle === "open" &&
      activeTask.continuationAvailable &&
      !activeTask.archived);
  const runInFlight = isRunInFlight(activeTask);
  const composerWorkspaceId =
    activeTask?.workspaceId ||
    workbench.draftWorkspaceId ||
    navigationWorkspaceId;
  const composerWorkspace = snapshot.workspaces.find(
    (workspace) => workspace.id === composerWorkspaceId,
  );
  const composerWorkspaceReady =
    composerWorkspace?.authorization === "available";
  const skillCatalog = newTaskDraftActive
    ? (composerWorkspace?.skillCatalog ?? {
        availability: "unavailable" as const,
        redacted: false,
        revision: null,
        skills: [],
        issues: [],
      })
    : (activeTask?.skillCatalog ?? {
        availability: "unavailable" as const,
        redacted: false,
        revision: null,
        skills: [],
        issues: [],
      });
  const skillDraftCurrent =
    composerDraft.kind !== "skill" ||
    isSkillDraftCurrent(composerDraft, skillCatalog);
  const composerRunInput = composerDraftToRunInput(composerDraft);
  const canSubmit =
    taskCanCompose &&
    (!newTaskDraftActive || snapshot.account.canCreateTask) &&
    (!newTaskDraftActive || composerWorkspaceReady) &&
    !accountMutationBlocksTaskAdmission(newTaskDraftActive, accountBusy) &&
    !runInFlight &&
    composerDraftHasContent(composerDraft) &&
    composerRunInput !== null &&
    composerDraftWithinLimits(composerDraft) &&
    skillDraftCurrent &&
    (composerDraft.kind === "text" || !skillCatalogBusy) &&
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
          setStatus(
            attentionStatus(
              "connection.failed",
              { scope: "connection" },
              {
                diagnostic: errorText(error),
              },
            ),
          );
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
  }, [accountGateRequired, bridgeUnavailable, navigationWorkspaceId]);

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
    setTaskMenuOpen(false);
    setInspectorFocusRequest(null);
    inspectorOpener.current = null;
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
      workspaceId: navigationWorkspaceId,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }, [
    activeTask,
    navigationWorkspaceId,
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

  function openInspectorSection(
    section: InspectorSection,
    opener: HTMLButtonElement,
  ) {
    if (!activeTask || !inspector.available) return;
    inspectorOpener.current = opener;
    inspector.show();
    inspectorFocusSequence.current += 1;
    setInspectorFocusRequest({
      taskId: activeTask.id,
      section,
      nonce: inspectorFocusSequence.current,
    });
  }

  function dismissInspector(restoreFocus = true) {
    const panel = document.getElementById("task-inspector");
    const focusWasInside = panel?.contains(document.activeElement) === true;
    const focusTarget = inspectorFocusReturnTarget(
      inspectorOpener.current,
      inspectorToggle.current,
    );
    inspectorOpener.current = null;
    inspector.hide();
    setInspectorFocusRequest(null);
    if (restoreFocus && focusWasInside && focusTarget)
      window.requestAnimationFrame(() => focusTarget.focus());
  }

  function focusPendingFromInspector() {
    if (window.innerWidth <= 1100) dismissInspector(false);
    window.requestAnimationFrame(focusPendingRequest);
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

  function closeDeleteConfirmation() {
    setConfirmDelete(false);
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
      setStatus(quietStatus("connection.recovered", { scope: "connection" }));
    } catch (error) {
      setViewSyncFailed(true);
      setBridgeReady(false);
      setStatus(
        attentionStatus(
          "connection.failed",
          { scope: "connection" },
          {
            diagnostic: errorText(error),
          },
        ),
      );
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
        setStatus(
          attentionStatus(
            result.errorCode === "generation_mismatch"
              ? "account.options_updated"
              : "account.command_rejected",
            { scope: "account" },
          ),
        );
        return;
      }
      await refreshAfterCommit("account.updated", "operation.account", {
        scope: "account",
      });
    } catch (error) {
      if (
        await reconcileCommandTimeout(error, "operation.account", {
          scope: "account",
        })
      )
        return;
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus("account.command_failed", { scope: "account" }),
      );
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

  async function chooseWorkspace(openDraft = false) {
    if (bridgeUnavailable || workspaceBusyRef.current) return null;
    workspaceBusyRef.current = true;
    setWorkspaceBusy(true);
    try {
      const outcome = await chooseWorkspaceWithDraft({
        choose: () => client.chooseWorkspace(),
        refresh: refreshSnapshot,
        openDraft,
        migratableDraftId:
          newTaskDraftId === unscopedNewTaskDraftId ? newTaskDraftId : null,
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
        setStatus(
          quietStatus("workspace.grant_confirmed", {
            scope: "workspace",
            workspaceId: result.workspaceId,
          }),
        );
        if (openDraft)
          window.requestAnimationFrame(() => composer.current?.focus());
        return result;
      }
      setStatus(
        quietStatus("workspace.selection_cancelled", {
          scope: "workspace",
          workspaceId: navigationWorkspaceId,
        }),
      );
      if (openDraft)
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
      if (openDraft)
        window.requestAnimationFrame(() => composer.current?.focus());
      return null;
    } finally {
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
    }
  }

  async function executeWorkspaceNavigation(
    request: WorkspaceNavigationRequest,
  ) {
    workspaceBusyRef.current = true;
    workspaceNavigationRunningRef.current = true;
    setWorkspaceBusy(true);
    try {
      const result = await client.selectWorkspace(
        request.workspaceId,
        request.workspaceEpoch,
      );
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        if (workspaceNavigationIntents.current.isCurrent(request))
          setStatus(
            attentionStatus(mutationReasonMessageId(result.reason), {
              scope: "workspace",
              workspaceId: null,
            }),
          );
        return;
      }
      await refreshSnapshot();
      if (!workspaceNavigationIntents.current.isCurrent(request)) return;
      if (request.target.kind === "draft") {
        const sourceDraftId = request.target.migratableDraftId;
        if (sourceDraftId && sourceDraftId !== request.workspaceId)
          newTaskDrafts.moveDraft(sourceDraftId, request.workspaceId);
        dispatchWorkbench({
          type: "task.draft.opened",
          workspaceId: request.workspaceId,
        });
        window.requestAnimationFrame(() => composer.current?.focus());
      } else {
        dispatchWorkbench({
          type: "workspace.selected",
          workspaceId: request.workspaceId,
        });
        if (request.target.taskId !== null)
          dispatchWorkbench({
            type: "task.selected",
            taskId: request.target.taskId,
          });
      }
      setStatus(
        quietStatus("workspace.grant_confirmed", {
          scope: "workspace",
          workspaceId: request.workspaceId,
        }),
      );
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      if (workspaceNavigationIntents.current.isCurrent(request))
        setStatus(
          attentionStatus(
            "workspace.selection_failed",
            { scope: "workspace", workspaceId: null },
            {
              diagnostic: errorText(error),
            },
          ),
        );
    } finally {
      workspaceNavigationRunningRef.current = false;
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
      const queued = workspaceNavigationIntents.current.takeQueued();
      if (queued) void executeWorkspaceNavigation(queued);
    }
  }

  function selectWorkspaceById(
    workspaceId: string,
    target:
      { kind: "navigation"; taskId: string | null } | { kind: "draft" } = {
      kind: "navigation",
      taskId: null,
    },
  ) {
    if (bridgeUnavailable) return;
    const workspace = snapshot.workspaces.find(
      (candidate) => candidate.id === workspaceId,
    );
    if (!workspace || workspace.origin !== "user") {
      setStatus(
        attentionStatus("workspace.selection_unavailable", {
          scope: "workspace",
          workspaceId: null,
        }),
      );
      return;
    }
    const input = {
      workspaceId,
      workspaceEpoch: workspace.epoch,
      target:
        target.kind === "draft"
          ? {
              kind: "draft" as const,
              migratableDraftId:
                newTaskDraftId === unscopedNewTaskDraftId
                  ? newTaskDraftId
                  : null,
            }
          : target,
    };
    if (workspaceNavigationRunningRef.current) {
      workspaceNavigationIntents.current.queue(input);
      return;
    }
    if (workspaceBusyRef.current) return;
    const request = workspaceNavigationIntents.current.begin(input);
    void executeWorkspaceNavigation(request);
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
        setStatus(
          attentionStatus("workspace.selection_unavailable", {
            scope: "workspace",
            workspaceId,
          }),
        );
        return;
      }
      const result = await client.removeWorkspace(workspaceId, workspace.epoch);
      if (!result.accepted) {
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(mutationReasonMessageId(result.reason), {
            scope: "workspace",
            workspaceId,
          }),
        );
        return;
      }
      await refreshAfterCommit(
        "workspace.removal_started",
        "operation.workspace_remove",
        { scope: "workspace", workspaceId },
      );
    } catch (error) {
      await refreshSnapshot().catch(() => undefined);
      setStatus(
        attentionStatus(
          "mutation.transport_failed",
          { scope: "workspace", workspaceId },
          { diagnostic: errorText(error) },
        ),
      );
    } finally {
      workspaceBusyRef.current = false;
      setWorkspaceBusy(false);
    }
  }

  function beginNewTask() {
    pendingTaskSelection.current = null;
    setRoute("workbench");
    if (workspaceNavigationRunningRef.current) {
      if (navigationWorkspaceId)
        selectWorkspaceById(navigationWorkspaceId, { kind: "draft" });
      else workspaceNavigationIntents.current.invalidate();
    }
    dispatchWorkbench({
      type: "task.draft.opened",
      workspaceId: navigationWorkspaceId,
    });
    window.requestAnimationFrame(() => composer.current?.focus());
  }

  function openSettings(target: SettingsFocusTarget = "title") {
    setSettingsFocus(target);
    setRoute("settings");
    if (
      bridgeUnavailable ||
      accountBusyRef.current ||
      snapshot.account.sessionState !== "authenticated" ||
      snapshot.account.operation !== "none"
    )
      return;
    void runAccountCommand(() => client.refreshAccountCatalog());
  }

  async function submitRun() {
    if (!canSubmit) return;
    const submitted = composerDraft;
    const input = composerDraftToRunInput(submitted);
    if (!input) return;
    const existingTaskId = activeTask?.id ?? null;
    if (!composerWorkspace || !composerWorkspaceId) return;
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
        workspaceId: composerWorkspaceId,
        expectedWorkspaceEpoch: composerWorkspace.epoch,
        expectedExecutionGeneration: snapshot.account.executionGeneration,
        expectedBindingEpoch: activeTask?.binding.epoch ?? null,
        input,
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
          await reconcileCommandTimeout(result.error, "operation.task_create", {
            scope: "workspace",
            workspaceId: composerWorkspaceId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "task.create_failed",
            { scope: "workspace", workspaceId: composerWorkspaceId },
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

  function composerDraftFromRunInput(
    input: RunInputView,
  ): ComposerDraft | null {
    if (input.redacted) return null;
    if (input.kind === "text") return { kind: "text", text: input.text };
    const descriptor = skillCatalog.skills.find(
      (skill) => skill.skillId === input.skillId,
    );
    if (!descriptor || skillCatalog.revision !== input.catalogRevision)
      return null;
    return {
      kind: "skill",
      skillId: input.skillId,
      invocationName: input.invocationName,
      displayName: input.displayName,
      catalogRevision: input.catalogRevision,
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

  function runSlashCommand(command: SlashCommandName) {
    if (command === "new") beginNewTask();
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
    const taskId = activeTask.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "close")) return;
    try {
      try {
        await client.closeTask(activeTask.id);
      } catch (error) {
        if (
          await reconcileCommandTimeout(error, "operation.task_close", {
            scope: "task",
            taskId,
          })
        )
          return;
        await refreshSnapshot().catch(() => undefined);
        setStatus(
          attentionStatus(
            "task.close_failed",
            { scope: "task", taskId },
            { diagnostic: errorText(error) },
          ),
        );
        return;
      }
      await refreshAfterCommit("task.close_requested", "operation.task_close", {
        scope: "task",
        taskId,
      });
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  async function renameTask() {
    if (!activeTask || taskMutationDisabled || !titleDraft.trim()) return;
    const taskId = activeTask.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "rename")) return;
    try {
      try {
        await client.renameTask(activeTask.id, titleDraft.trim());
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

  async function setArchived(archived: boolean) {
    if (
      !activeTask ||
      taskMutationDisabled ||
      activeTask.currentRunPhase !== null
    )
      return;
    const taskId = activeTask.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "archive")) return;
    try {
      try {
        await client.setTaskArchived(activeTask.id, archived);
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

  async function deleteTask() {
    if (
      !activeTask ||
      taskMutationDisabled ||
      activeTask.lifecycle !== "closed"
    )
      return;
    const taskId = activeTask.id;
    const scope = `task:${taskId}`;
    if (!beginTaskPendingOperation(scope, "delete")) return;
    try {
      try {
        await client.deleteTask(activeTask.id);
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
      taskDrafts.clearDraft(activeTask.id);
      setConfirmDelete(false);
      await refreshAfterCommit("task.deleted", "operation.task_delete", {
        scope: "task",
        taskId,
      });
    } finally {
      endTaskPendingOperation(scope);
    }
  }

  function selectSearchResult(result: SearchResult) {
    pendingTaskSelection.current = null;
    const workspace = snapshot.workspaces.find(
      (candidate) => candidate.id === result.workspaceId,
    );
    if (workspace?.origin === "managed" && result.taskId) {
      setRoute("workbench");
      dispatchWorkbench({ type: "task.selected", taskId: result.taskId });
    } else {
      void selectWorkspaceById(result.workspaceId, {
        kind: "navigation",
        taskId: result.taskId,
      });
    }
    setSearchOpen(false);
    setSearchQuery("");
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
  const connectionRetryable =
    connectionShellStatus?.id !== "connection.contract_failed";
  const accountGateStatus = selectAccountGateStatus(statuses);
  if (accountGateRequired)
    return (
      <AccountGate
        account={snapshot.account}
        disabled={bridgeUnavailable || accountBusy}
        cancelDisabled={viewSyncFailed || !bridgeReady || accountCancelBusy}
        connectionFailed={viewSyncFailed}
        connectionRetryable={connectionRetryable}
        connectionDiagnostic={connectionShellStatus?.diagnostic}
        reconnecting={connectionBusy}
        notice={
          accountGateStatus
            ? t(accountGateStatus.id, accountGateStatus.values)
            : ""
        }
        onBeginWindowDrag={() => {
          void client.beginWindowDrag(1).catch(() => undefined);
        }}
        onWindowControl={(action) => {
          void client.controlWindow(action).catch(() => undefined);
        }}
        onReconnect={() => void retryViewSynchronization()}
        onBeginLogin={() => void runAccountCommand(() => client.beginLogin())}
        onReopenLogin={() => void runAccountCommand(() => client.reopenLogin())}
        onReauthenticate={() =>
          void runAccountCommand(() => client.reauthenticate())
        }
        onLogout={() => void runAccountCommand(() => client.logout())}
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
  const slashCommands: SlashCommandState[] = slashCommandNames.map((name) => {
    const unavailable = t("slash.disabled_unavailable");
    const enabled = !newTaskDraftActive && !bridgeUnavailable;
    return {
      name,
      enabled,
      disabledReason: enabled
        ? null
        : newTaskDraftActive
          ? t("slash.disabled_already_new_task")
          : unavailable,
    };
  });
  const commandBarStatus = selectCommandBarStatus(statuses, {
    route,
    workspaceId: currentWorkspaceId,
    taskId: activeTask?.id ?? null,
  });
  const composerFooter = (
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
      draft={composerDraft}
      skillCatalog={skillCatalog}
      slashCommands={slashCommands}
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
          ? composerWorkspace.origin === "managed"
            ? t("workspace.managed")
            : composerWorkspace.displayName ||
              workspaceLabel(composerWorkspace.canonicalRoot)
          : t("workspace.none")
      }
      workspaceTitle={
        composerWorkspace?.origin === "managed"
          ? t("workspace.managed")
          : composerWorkspace?.canonicalRoot || t("workspace.none")
      }
      workspaceOptions={userWorkspaces.map((workspace) => ({
        id: workspace.id,
        label: workspace.displayName || workspaceLabel(workspace.canonicalRoot),
        canonicalRoot: workspace.canonicalRoot,
        authorization: workspace.authorization,
      }))}
      selectedWorkspaceId={
        newTaskDraftActive ? (composerWorkspace?.id ?? "") : ""
      }
      workspaceEditable={newTaskDraftActive}
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
      modelSelectionPending={
        accountBusy || snapshot.account.operation !== "none"
      }
      modelContextTitle={
        newTaskDraftActive
          ? t("settings.default_model_help")
          : t("settings.task_binding_model")
      }
      actionDisabled={bridgeUnavailable || workspaceBusy}
      onDraftChange={updateComposerDraft}
      onSubmit={() => void submitRun()}
      onSlashCommand={runSlashCommand}
      onRefreshSkillCatalog={() => void refreshComposerSkillCatalog()}
      onConfirmAccess={() => void chooseWorkspace(true)}
      onSelectWorkspace={(workspaceId) =>
        void selectWorkspaceById(workspaceId, { kind: "draft" })
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

  return (
    <AppShell
      taskTitle={
        route === "settings"
          ? t("settings.title")
          : route === "skills"
            ? t("skills.title")
            : route === "scheduled-tasks"
              ? t("scheduled.title")
              : activeTaskTitle
      }
      contextVisible={route === "workbench" && activeTask !== null}
      onSearch={() => setSearchOpen(true)}
      onBeginWindowDrag={() => {
        void client.beginWindowDrag(1).catch(() => undefined);
      }}
      onWindowControl={(action) => {
        void client.controlWindow(action).catch(() => undefined);
      }}
      workspaceLabel={
        route === "settings"
          ? t("settings.account_models")
          : route === "scheduled-tasks"
            ? t("scheduled.title")
            : currentWorkspace?.origin === "managed"
              ? t("workspace.managed")
              : currentWorkspace?.displayName ||
                currentWorkspace?.canonicalRoot ||
                t("workspace.none")
      }
      attentionNotice={
        commandBarStatus
          ? t(commandBarStatus.id, commandBarStatus.values)
          : null
      }
      left={
        route === "settings" ? null : (
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
                    <Icon name="plus" />
                  </span>
                  <span>{t("task.new")}</span>
                  <kbd>{shortcutModifier}N</kbd>
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
                    /
                  </span>
                  <span>{t("skills.title")}</span>
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
                    <span
                      className="sidebar-capability-mark"
                      aria-hidden="true"
                    >
                      <Icon name="clock" />
                    </span>
                    <span>{t("scheduled.title")}</span>
                  </button>
                )}
              </nav>

              <div className="sidebar-navigation">
                <WorkspaceNavigation
                  summaries={summaries}
                  currentWorkspaceId={navigationWorkspaceId}
                  tasks={sidebarTaskItems}
                  activeTaskId={
                    route === "workbench" &&
                    activeTask !== null &&
                    sidebarTaskItems.some((task) => task.id === activeTask.id)
                      ? activeTask.id
                      : null
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
                    const task = snapshot.tasks.find(
                      (candidate) => candidate.id === taskId,
                    );
                    const taskWorkspace = task
                      ? snapshot.workspaces.find(
                          (workspace) => workspace.id === task.workspaceId,
                        )
                      : null;
                    if (
                      workspaceNavigationRunningRef.current &&
                      task &&
                      taskWorkspace?.origin === "user"
                    )
                      selectWorkspaceById(task.workspaceId, {
                        kind: "navigation",
                        taskId,
                      });
                    dispatchWorkbench({ type: "task.selected", taskId });
                  }}
                  onToggleArchived={() => setShowArchived((shown) => !shown)}
                />
              </div>
            </div>

            <AccountIdentity
              account={snapshot.account}
              active={false}
              disabled={bridgeUnavailable || accountBusy}
              onOpenSettings={openSettings}
              onReauthenticate={() =>
                void runAccountCommand(() => client.reauthenticate())
              }
            />
          </div>
        )
      }
      inspectorOpen={route === "workbench" && inspector.open}
      onDismissInspector={dismissInspector}
      inspector={
        route === "workbench" && activeTask && inspector.available ? (
          <TaskInspector
            task={activeTask}
            focusRequest={inspectorFocusRequest}
            onClose={() => dismissInspector()}
            onFocusPending={focusPendingFromInspector}
          />
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
      ) : route === "skills" ? (
        <SkillsPage
          catalog={snapshot.skillCatalog}
          query={skillsQuery}
          refreshing={
            skillCatalogBusy || snapshot.skillCatalog.availability === "loading"
          }
          disabled={bridgeUnavailable}
          onQuery={setSkillsQuery}
          onRefresh={() => void refreshSkillsPageCatalog()}
        />
      ) : route === "scheduled-tasks" ? (
        <ScheduledTasksPage
          snapshot={snapshot}
          disabled={bridgeUnavailable || !snapshot.capabilities.scheduledTasks}
          onCreate={(input) => client.createScheduledTask(input)}
          onUpdate={(id, epoch, input) =>
            client.updateScheduledTask(id, epoch, input)
          }
          onSetEnabled={(id, epoch, enabled) =>
            client.setScheduledTaskEnabled(id, epoch, enabled)
          }
          onRunNow={(id, epoch) => client.runScheduledTaskNow(id, epoch)}
          onDelete={(id, epoch) => client.deleteScheduledTask(id, epoch)}
          onOpenTask={(taskId) => {
            const task = snapshot.tasks.find((item) => item.id === taskId);
            if (!task) return;
            setRoute("workbench");
            dispatchWorkbench({ type: "task.selected", taskId });
          }}
        />
      ) : (
        <div
          className="workbench-view"
          data-view={newTaskDraftActive ? "new-task" : "task"}
        >
          {!newTaskDraftActive && (
            <header className="task-header">
              <div className="min-w-0">
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
                        if (event.key !== "Escape") return;
                        event.preventDefault();
                        setEditingTitle(false);
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
                {activeTask && inspector.available && (
                  <button
                    ref={inspectorToggle}
                    className="inspector-toggle icon-button focus-ring"
                    data-active={inspector.open}
                    aria-controls="task-inspector"
                    aria-expanded={inspector.open}
                    aria-label={t(
                      inspector.open ? "inspector.close" : "inspector.open",
                    )}
                    title={t(
                      inspector.open ? "inspector.close" : "inspector.open",
                    )}
                    onClick={(event) => {
                      setInspectorFocusRequest(null);
                      if (inspector.open) {
                        dismissInspector(false);
                        return;
                      }
                      inspectorOpener.current = event.currentTarget;
                      inspector.show();
                    }}
                  >
                    <Icon name="activity" />
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
          )}

          {activeTask && confirmDelete && (
            <section
              className="delete-confirmation"
              role="alertdialog"
              aria-labelledby="task-delete-title"
              aria-describedby="task-delete-description"
              onKeyDown={(event) => {
                if (event.key !== "Escape") return;
                event.preventDefault();
                event.stopPropagation();
                closeDeleteConfirmation();
              }}
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
                onClick={closeDeleteConfirmation}
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

          {viewSyncFailed && (
            <section className="sync-failure task-sync-failure" role="alert">
              <h3>
                {t(
                  connectionRetryable
                    ? "connection.failed"
                    : "connection.contract_failed",
                )}
              </h3>
              <p>
                {t(
                  connectionRetryable
                    ? "connection.failed_help"
                    : "connection.contract_failed_help",
                )}
              </p>
              {connectionRetryable ? (
                <button
                  className="secondary-button focus-ring"
                  disabled={connectionBusy}
                  onClick={() => void retryViewSynchronization()}
                >
                  {connectionBusy
                    ? t("connection.retrying")
                    : t("connection.retry")}
                </button>
              ) : (
                <button
                  className="secondary-button focus-ring"
                  onClick={() =>
                    void client.controlWindow("close").catch(() => undefined)
                  }
                >
                  {t("window.close")}
                </button>
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

          <TaskTimeline
            task={activeTask}
            draft={newTaskDraftActive}
            draftHasWorkspace={Boolean(composerWorkspace)}
            revision={snapshot.revision}
            composerHasDraft={composerDraftHasContent(composerDraft)}
            retryAvailable={taskCanCompose && !runInFlight}
            responseDisabled={bridgeUnavailable}
            draftComposer={newTaskDraftActive ? composerFooter : null}
            onUseExample={(instruction) => {
              const prepared = prepareRetryDraft(composerDraft, instruction);
              if (prepared.kind === "prepared")
                updateComposerDraft(prepared.draft);
              else if (activeTask)
                setStatus(
                  quietStatus("run.draft_preserved", {
                    scope: "task",
                    taskId: activeTask.id,
                  }),
                );
              window.requestAnimationFrame(() => composer.current?.focus());
            }}
            onPrepareRetry={prepareRetry}
            onInspect={openInspectorSection}
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
          {!newTaskDraftActive && composerFooter}
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
