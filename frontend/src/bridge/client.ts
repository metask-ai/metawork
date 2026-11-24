import type { SkillImportTarget, SkillImportEffect } from "./contracts.ts";
import { PreviewImagePool } from "./preview-image-pool.ts";
import { FilePreviewLoader } from "./file-preview.ts";
import { object } from "./wire-codec.ts";
import {
  decodeRunToolsPage,
  decodeFileActionResult,
  decodeFileActionCancel,
  decodeSendInputResult,
  decodeTaskProjectResult,
} from "./decode-contracts.ts";
import {
  commands,
  events,
  RENDERER_BRIDGE_CONTRACT_ID,
  RENDERER_BRIDGE_CONTRACT_REVISION,
} from "./commands.ts";
import type { NativeSdkJson, NativeSdkShortcutDetail } from "@native-sdk/cli";
import type {
  HostSignal,
  FileAction,
  FileActionState,
  RunToolsPage,
  ViewScope,
  McpHttpConnectionInput,
  McpHttpDraftHeader,
  McpSecretSlot,
  McpStdioConnectionInput,
  ApprovalMode,
  Protocol,
  NewTaskModelSelectionIntent,
  ScheduledTaskMutation,
  TaskRunInput,
  TaskWorkspaceIntent,
  UiResponsePayload,
  WorkspaceChoice,
  AttachmentThumbnailResult,
  FilePreview,
  FileTarget,
  FilePreviewLoadOptions,
  MediaTarget,
  FileChangeDiffResult,
  ModelMetadata,
  NotificationTextRegistration,
  InboxConversationPage,
  InboxTaskDetail,
  InboxFileOpen,
  InboxSendResult,
  InboxSendTarget,
  InboxPeople,
} from "./contracts.ts";
import {
  assertCancelAccepted,
  assertCompactCancelAccepted,
  assertDisconnected,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  assertUiResponseAccepted,
  decodeAccountCommandResult,
  decodeUpdateCommandResult,
  decodeUpdateWebsiteResult,
  decodeInboxCommandResult,
  decodeInboxConversationPage,
  decodeInboxTaskDetail,
  decodeInboxFileOpen,
  decodeInboxSendResult,
  decodeInboxPeople,
  decodeExecutionCommandResult,
  decodeCatalogRefreshResult,
  decodeWorkspaceRemovalResult,
  decodeSkillCatalogRefreshResult,
  decodeHostSignalEvent,
  decodeTaskOpenEvent,
  decodePingResponse,
  decodeRendererBridgeConnect,
  decodeRevisionNotification,
  decodeTaskCreateResult,
  decodeTaskCompactResult,
  decodeTaskRestoreResult,
  decodeTaskRunResult,
  decodeTaskCompletionSeenResult,
  decodeTaskModelSelectionResult,
  decodeTaskApprovalModeResult,
  decodeScheduledTaskMutationResult,
  decodeScheduledTaskEnabledResult,
  decodeScheduledTaskRunResult,
  decodePersistenceRecoveryResult,
  assertScheduledTaskDeleted,
  decodeWorkspaceChoice,
  decodeSkillImportPreview,
  decodeSkillMutationResult,
  decodeSkillEnablementResult,
  decodeSkillExportResult,
  decodeSkillDetailResult,
  decodeMcpMutationResult,
  decodeMcpCreateResult,
  decodeMcpRefreshResult,
  decodeMcpConfigurationApplyResult,
  decodeMcpConnectionTestResult,
  decodeMcpHttpDraftProbeResult,
  decodeMcpHttpDraftAddResult,
  decodeMcpAuthorizationResult,
  decodeMcpAuthorizationCancelResult,
  decodeFileChangeDiff,
  decodeAttachmentReleaseResult,
  decodeAttachmentAddBegin,
  decodeAttachmentAddAcceptance,
  decodeAttachmentAddResult,
  decodeAttachmentCancelResult,
  decodeAutomaticWorkspaceRootMutationResult,
  decodeGlobalInstructions,
  decodeGlobalInstructionsSaveResult,
  decodeExternalLinkOpenResult,
  decodeWorkspaceOpenResult,
} from "./decode-contracts.ts";
import { RendererBridgeContractError } from "./contract-error.ts";
import { ViewCache } from "./snapshot/view-cache.ts";
import { fetchWorkbenchSnapshot } from "./snapshot/snapshot-client.ts";
import { AttachmentAddOperation } from "./attachment-receive.ts";
export {
  RendererBridgeContractError,
  type RendererBridgeContractErrorCode,
} from "./contract-error.ts";
export type NativeBridge = NonNullable<typeof window.zero>;
const defaultCommandTimeoutMs = 10000;
// The state that says a file operation did what it was asked. Every other
// state is a refusal or a failure, which any operation may report.
const completedFileState: Record<FileAction | "register", FileActionState> = {
  open: "opened",
  reveal: "revealed",
  copy_path: "path_copied",
  check_current: "ready",
  save: "saved",
  check: "ready",
  register: "registered",
};
const completedFileStates = new Set(Object.values(completedFileState));
const saveOnlyFileStates = new Set<FileActionState>([
  "save_failed",
  "target_changed",
  "cleanup_failed",
]);
export class BridgeCommandTimeoutError extends Error {
  readonly command: string;
  readonly timeoutMs: number;
  constructor(command: string, timeoutMs: number) {
    super(`Native Host command timed out after ${timeoutMs} ms: ${command}`);
    this.name = "BridgeCommandTimeoutError";
    this.command = command;
    this.timeoutMs = timeoutMs;
  }
}
export type BridgeClientOptions = {
  bridge?: NativeBridge;
  commandTimeoutMs?: number;
};
export class BridgeClient {
  private readonly viewCache = new ViewCache();
  private readonly bridgeOverride?: NativeBridge;
  private readonly commandTimeoutMs: number;
  private attachmentConnection:
    | {
        generation: string;
        mode: "native_paths" | "file_bytes";
        maxChunkBytes: number;
      }
    | undefined;
  private nextReceiveBatch = 1n;
  private nextFileOperation = 1n;
  private nextRunToolsRequest = 1n;
  private nextInboxRequest = 1n;
  private readonly previewImages = new PreviewImagePool();
  private readonly previews = new FilePreviewLoader(
    (command, payload) => this.invoke(command, payload),
    () => this.attachmentConnection?.generation,
    this.previewImages,
  );
  constructor(options: BridgeClientOptions = {}) {
    this.bridgeOverride = options.bridge;
    this.commandTimeoutMs = options.commandTimeoutMs ?? defaultCommandTimeoutMs;
  }
  private bridge() {
    const bridge = this.bridgeOverride ?? window.zero;
    if (!bridge) throw new Error("Native Host bridge is unavailable");
    return bridge;
  }
  private invoke(
    command: string,
    payload: NativeSdkJson,
    timeoutMs = this.commandTimeoutMs,
  ) {
    const pending = this.bridge().invoke(command, payload);
    if (timeoutMs <= 0) return pending;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () => reject(new BridgeCommandTimeoutError(command, timeoutMs)),
        timeoutMs,
      );
    });
    return Promise.race([pending, timeout]).finally(() => {
      if (timer !== undefined) clearTimeout(timer);
    });
  }
  available() {
    return this.bridgeOverride !== undefined || window.zero !== undefined;
  }
  onShortcut(consume: (shortcut: NativeSdkShortcutDetail) => void) {
    return this.bridge().on("shortcut", consume);
  }
  onFileDrop(consume: (paths: string[]) => void) {
    if (this.attachmentConnection?.mode !== "native_paths") return () => {};
    return this.bridge().on("drop:files", ({ paths }) => consume(paths));
  }
  get attachmentInputMode() {
    return this.attachmentConnection?.mode;
  }
  onWorkbenchRevision(
    consume: (revision: string, securityEpoch: string) => void,
    reject: (error: unknown) => void,
  ) {
    return this.bridge().on<unknown>(events.workbench, (value) => {
      try {
        const notification = decodeRevisionNotification(value);
        if (notification.generation !== this.attachmentConnection?.generation)
          return;
        this.viewCache.observeSecurityEpoch(notification.securityEpoch);
        this.previews.observeSecurityEpoch(notification.securityEpoch);
        consume(notification.revision, notification.securityEpoch);
      } catch (error) {
        reject(error);
      }
    });
  }
  onHostSignal(
    consume: (signal: HostSignal) => void,
    reject: (error: unknown) => void,
  ) {
    return this.bridge().on<unknown>(events.hostSignal, (value) => {
      try {
        consume(decodeHostSignalEvent(value));
      } catch (error) {
        reject(error);
      }
    });
  }
  onTaskOpen(
    consume: (target: ReturnType<typeof decodeTaskOpenEvent>) => void,
    reject: (error: unknown) => void,
  ) {
    return this.bridge().on<unknown>(events.openTask, (value) => {
      try {
        consume(decodeTaskOpenEvent(value));
      } catch (error) {
        reject(error);
      }
    });
  }
  async connect() {
    this.previews.reset();
    this.viewCache.clear();
    const value = await this.invoke(commands.connect, {
      contractId: RENDERER_BRIDGE_CONTRACT_ID,
      contractRevision: RENDERER_BRIDGE_CONTRACT_REVISION,
    });
    let result: ReturnType<typeof decodeRendererBridgeConnect>;
    try {
      result = decodeRendererBridgeConnect(value);
    } catch (error) {
      throw new RendererBridgeContractError(
        "invalid_response",
        error instanceof Error ? error.message : String(error),
      );
    }
    if (!result.accepted)
      throw new RendererBridgeContractError(
        result.error,
        `Host requires ${result.contractId} revision ${result.contractRevision}`,
      );
    if (
      result.contractId !== RENDERER_BRIDGE_CONTRACT_ID ||
      result.contractRevision !== RENDERER_BRIDGE_CONTRACT_REVISION
    )
      throw new RendererBridgeContractError(
        "invalid_response",
        `Host accepted ${result.contractId} revision ${result.contractRevision}`,
      );
    this.attachmentConnection = {
      generation: result.generation,
      ...result.attachmentInput,
    };
    this.nextReceiveBatch = 1n;
    this.nextFileOperation = 1n;
    this.nextRunToolsRequest = 1n;
    return result.generation;
  }
  async disconnect(generation: string) {
    this.viewCache.clear();
    if (this.attachmentConnection?.generation === generation) {
      this.previews.reset();
      this.attachmentConnection = undefined;
    }
    assertDisconnected(
      await this.invoke(commands.disconnect, { generation }),
      generation,
    );
  }
  fetchSnapshot(scope: ViewScope) {
    return fetchWorkbenchSnapshot(
      (command, payload) => this.invoke(command, payload),
      scope,
      this.viewCache,
    );
  }
  async checkUpdates() {
    return decodeUpdateCommandResult(
      await this.invoke(commands.updatesCheck, {}),
    );
  }
  async openUpdateDownload(expectedVersion: string) {
    return decodeUpdateCommandResult(
      await this.invoke(commands.updatesOpenDownload, { expectedVersion }),
    );
  }
  async openUpdateWebsite() {
    return decodeUpdateWebsiteResult(
      await this.invoke(commands.updatesOpenWebsite, {}),
    );
  }
  /** Asks the Host for the unread facts and newer conversations now. */
  async refreshInbox(binding: string, explicit: boolean) {
    return decodeInboxCommandResult(
      await this.invoke(commands.inboxRefresh, { binding, explicit }),
    );
  }
  /** Extends the conversation list with earlier conversations. */
  async loadEarlierInbox(binding: string) {
    return decodeInboxCommandResult(
      await this.invoke(commands.inboxLoadEarlier, { binding }),
    );
  }
  private inboxRequest() {
    const connection = this.attachmentConnection;
    if (!connection) throw new Error("Host connection is unavailable");
    if (this.nextInboxRequest > 18446744073709551615n)
      throw new Error("Inbox request identity exhausted");
    return {
      generation: connection.generation,
      requestId: String(this.nextInboxRequest++),
    };
  }
  /**
   * One page of a conversation the user opened: the latest messages, the
   * ones before `anchorId`, or the ones after it.
   */
  async readInboxConversation(
    binding: string,
    target: string | { username: string },
    page: "latest" | "refresh" | "before" | "after",
    anchorId: string | null,
  ): Promise<InboxConversationPage> {
    const { generation, requestId } = this.inboxRequest();
    const result = decodeInboxConversationPage(
      await this.invoke(commands.inboxReadConversation, {
        generation,
        binding,
        requestId,
        ...(typeof target === "string" ? { peerId: target } : target),
        page,
        anchorId,
      }),
    );
    if (
      result.binding !== binding ||
      result.requestId !== requestId ||
      ((typeof target === "string" ||
        result.state !== "ready" ||
        !result.messages.length) &&
        result.peerId !==
          (typeof target === "string" ? target : target.username))
    )
      throw new RendererBridgeContractError(
        "invalid_response",
        "Inbox page identity mismatch",
      );
    return result;
  }
  /** The details of a task a message links to. */
  async readInboxTask(
    binding: string,
    taskId: string,
  ): Promise<InboxTaskDetail> {
    const { generation, requestId } = this.inboxRequest();
    const result = decodeInboxTaskDetail(
      await this.invoke(commands.inboxReadTask, {
        generation,
        binding,
        requestId,
        taskId,
      }),
    );
    if (result.binding !== binding || result.requestId !== requestId)
      throw new RendererBridgeContractError(
        "invalid_response",
        "Inbox task identity mismatch",
      );
    return result;
  }
  /**
   * Sends one message in an open conversation. `requestKey` identifies the
   * message to MetaTeam: a retry of the same message passes the same key,
   * so MetaTeam takes it at most once.
   */
  async sendInboxMessage(
    binding: string,
    to: InboxSendTarget,
    text: string,
    requestKey: string,
  ): Promise<InboxSendResult> {
    const { generation, requestId } = this.inboxRequest();
    const result = decodeInboxSendResult(
      await this.invoke(commands.inboxSend, {
        generation,
        binding,
        requestId,
        peerId: "peerId" in to ? to.peerId : null,
        username: "username" in to ? to.username : null,
        text,
        requestKey,
      }),
    );
    if (result.binding !== binding || result.requestId !== requestId)
      throw new RendererBridgeContractError(
        "invalid_response",
        "Inbox send identity mismatch",
      );
    return result;
  }
  /** The members a new conversation can start with; read on request only. */
  async listInboxPeople(binding: string): Promise<InboxPeople> {
    const { generation, requestId } = this.inboxRequest();
    const result = decodeInboxPeople(
      await this.invoke(commands.inboxListPeople, {
        generation,
        binding,
        requestId,
      }),
    );
    if (result.binding !== binding || result.requestId !== requestId)
      throw new RendererBridgeContractError(
        "invalid_response",
        "Inbox members identity mismatch",
      );
    return result;
  }
  /**
   * Opens a shared file's download in the system browser. The Host reads a
   * fresh download address and keeps it; only the outcome comes back.
   */
  async openInboxFile(binding: string, fileId: string): Promise<InboxFileOpen> {
    const { generation, requestId } = this.inboxRequest();
    const result = decodeInboxFileOpen(
      await this.invoke(commands.inboxOpenFile, {
        generation,
        binding,
        requestId,
        fileId,
      }),
    );
    if (result.binding !== binding || result.requestId !== requestId)
      throw new RendererBridgeContractError(
        "invalid_response",
        "Inbox file identity mismatch",
      );
    return result;
  }
  async openExternalLink(url: string) {
    return decodeExternalLinkOpenResult(
      await this.invoke(commands.openExternalLink, { url }),
    );
  }
  /**
   * Hands the Host the notification strings in the current language. Called
   * again on every language change; the Host replaces the whole table, and
   * refuses one that is missing a slot rather than showing a wordless banner.
   */
  async registerNotificationText(
    registration: NotificationTextRegistration,
  ): Promise<void> {
    await this.invoke(commands.registerNotificationText, { ...registration });
  }
  fileAction(
    target: FileTarget,
    action: FileAction,
    signal: AbortSignal,
  ): Promise<FileActionState> {
    return this.fileOperation(
      commands.fileAction,
      { target, action },
      action,
      signal,
    );
  }
  /** Records one applied change of a finished Run as an output. */
  registerOutput(
    taskId: string,
    runId: string,
    changeId: string,
    signal: AbortSignal,
  ): Promise<FileActionState> {
    return this.fileOperation(
      commands.registerOutput,
      { taskId, runId, changeId },
      "register",
      signal,
    );
  }
  private async fileOperation(
    command: string,
    request: Record<string, NativeSdkJson>,
    operation: FileAction | "register",
    signal: AbortSignal,
  ): Promise<FileActionState> {
    const connection = this.attachmentConnection;
    if (!connection) throw new Error("Host connection is unavailable");
    if (signal.aborted)
      throw new DOMException("File action cancelled", "AbortError");
    if (this.nextFileOperation > 18446744073709551615n)
      throw new Error("File operation identity exhausted");
    const key = {
      generation: connection.generation,
      operationId: String(this.nextFileOperation++),
    };
    const matches = (result: { generation: string; operationId: string }) => {
      if (
        result.generation !== key.generation ||
        result.operationId !== key.operationId
      )
        throw new RendererBridgeContractError(
          "invalid_response",
          "File operation identity mismatch",
        );
    };
    let cancelled = false;
    const cancel = () => {
      if (cancelled) return;
      cancelled = true;
      if (this.attachmentConnection?.generation !== key.generation) return;
      void this.invoke(commands.cancelFileAction, key)
        .then(decodeFileActionCancel)
        .then(matches)
        .catch(() => undefined);
    };
    signal.addEventListener("abort", cancel, { once: true });
    try {
      const result = decodeFileActionResult(
        await this.invoke(
          command,
          { ...key, ...request },
          operation === "save" || this.commandTimeoutMs <= 0
            ? 0
            : Math.max(35000, this.commandTimeoutMs),
        ),
      );
      matches(result);
      if (
        (signal.aborted && operation !== "save") ||
        this.attachmentConnection?.generation !== key.generation
      )
        throw new DOMException("File action cancelled", "AbortError");
      if (
        (completedFileStates.has(result.state) &&
          result.state !== completedFileState[operation]) ||
        (saveOnlyFileStates.has(result.state) && operation !== "save")
      )
        throw new RendererBridgeContractError(
          "invalid_response",
          "File action result mismatch",
        );
      return result.state;
    } catch (error) {
      cancel();
      throw error;
    } finally {
      signal.removeEventListener("abort", cancel);
    }
  }
  /**
   * One page of a Run's Tool records after `afterOrder`. The response must
   * answer this connection and request; the caller compares its security epoch.
   */
  async readRunTools(
    taskId: string,
    runId: string,
    afterOrder: string,
  ): Promise<RunToolsPage> {
    const connection = this.attachmentConnection;
    if (!connection) throw new Error("Host connection is unavailable");
    if (this.nextRunToolsRequest > 18446744073709551615n)
      throw new Error("Tool page request identity exhausted");
    const key = {
      generation: connection.generation,
      requestId: String(this.nextRunToolsRequest++),
    };
    const page = decodeRunToolsPage(
      await this.invoke(commands.readRunTools, {
        ...key,
        taskId,
        runId,
        afterOrder,
      }),
      afterOrder,
    );
    if (page.generation !== key.generation || page.requestId !== key.requestId)
      throw new RendererBridgeContractError(
        "invalid_response",
        "Tool page identity mismatch",
      );
    return page;
  }
  previewFile(
    target: FileTarget,
    options?: FilePreviewLoadOptions,
  ): Promise<FilePreview> {
    return this.previews.load(target, options);
  }
  /// The viewer tier for a registered image, draft or sent.
  previewAttachment(
    target: MediaTarget,
    options?: FilePreviewLoadOptions,
  ): Promise<FilePreview> {
    return this.previews.loadAttachment(target, options);
  }
  /// The thumbnail tier for a registered image, draft or sent.
  attachmentThumbnail(
    target: MediaTarget,
    options?: FilePreviewLoadOptions,
  ): Promise<AttachmentThumbnailResult> {
    return this.previews.loadThumbnail(target, options);
  }
  async fileChangeDiff(
    taskId: string,
    runId: string,
    fileChangeId: string,
  ): Promise<FileChangeDiffResult> {
    return decodeFileChangeDiff(
      await this.invoke(commands.fileChangeDiff, {
        taskId,
        runId,
        fileChangeId,
      }),
    );
  }
  listWorkspaceDirectory(
    taskId: string,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
    options?: FilePreviewLoadOptions,
  ) {
    return this.previews.listDirectory(
      taskId,
      workspaceId,
      workspaceEpoch,
      path,
      options,
    );
  }
  async ping() {
    return decodePingResponse(
      await this.invoke(commands.ping, {
        source: "workbench-renderer",
      }),
    );
  }
  async acknowledgeSignal(sequence: number) {
    assertSignalAcknowledged(
      await this.invoke(commands.pingAck, { sequence }),
      sequence,
    );
  }
  async chooseWorkspace(): Promise<WorkspaceChoice> {
    // Native file dialogs are user-controlled modal interactions, not bounded
    // Host work. Their lifetime must not be confused with a wedged command.
    return decodeWorkspaceChoice(
      await this.bridge().invoke(commands.chooseWorkspace, {}),
    );
  }
  async addProject(): Promise<WorkspaceChoice> {
    return decodeWorkspaceChoice(
      await this.bridge().invoke(commands.addProject, {}),
    );
  }
  async setTaskProject(taskId: string, projectId: string | null) {
    return decodeTaskProjectResult(
      await this.invoke(commands.setTaskProject, { taskId, projectId }),
      taskId,
    );
  }
  async openWorkspace(workspaceId: string, expectedWorkspaceEpoch: string) {
    return decodeWorkspaceOpenResult(
      await this.invoke(commands.openWorkspace, {
        workspaceId,
        expectedWorkspaceEpoch,
      }),
    );
  }
  async removeWorkspace(workspaceId: string, expectedWorkspaceEpoch: string) {
    return decodeWorkspaceRemovalResult(
      await this.invoke(commands.removeWorkspace, {
        workspaceId,
        expectedWorkspaceEpoch,
      }),
      workspaceId,
    );
  }
  async removeProject(workspaceId: string, expectedWorkspaceEpoch: string) {
    return decodeWorkspaceRemovalResult(
      await this.invoke(commands.removeProject, {
        workspaceId,
        expectedWorkspaceEpoch,
      }),
      workspaceId,
    );
  }
  async chooseAutomaticWorkspaceRoot(expectedGeneration: string) {
    // Native directory pickers are user-controlled modal interactions, so
    // their lifetime must not be mistaken for a wedged Host command.
    return decodeAutomaticWorkspaceRootMutationResult(
      await this.bridge().invoke(commands.chooseAutomaticWorkspaceRoot, {
        expectedGeneration,
      }),
    );
  }
  async resetAutomaticWorkspaceRoot(expectedGeneration: string) {
    return decodeAutomaticWorkspaceRootMutationResult(
      await this.invoke(commands.resetAutomaticWorkspaceRoot, {
        expectedGeneration,
      }),
    );
  }
  async retryAutomaticWorkspaceRoot(expectedGeneration: string) {
    return decodeAutomaticWorkspaceRootMutationResult(
      await this.invoke(commands.retryAutomaticWorkspaceRoot, {
        expectedGeneration,
      }),
    );
  }
  async readGlobalInstructions() {
    return decodeGlobalInstructions(
      await this.invoke(commands.readGlobalInstructions, {}),
    );
  }
  /** Replaces the global instructions file when it still has the revision
   * the editor loaded; an outside change answers `conflict`. */
  async saveGlobalInstructions(expectedRevision: string, text: string) {
    return decodeGlobalInstructionsSaveResult(
      await this.invoke(commands.saveGlobalInstructions, {
        expectedRevision,
        text,
      }),
    );
  }
  private skillImportTarget(target: SkillImportTarget) {
    return {
      kind: target.kind,
      workspaceId: target.kind === "project" ? target.workspaceId : null,
      expectedWorkspaceEpoch:
        target.kind === "project" ? target.workspaceEpoch : null,
      installId: target.kind === "reimport" ? target.installId : null,
    };
  }
  async chooseSkillImport(
    kind: "package" | "directory",
    target: SkillImportTarget,
  ) {
    return decodeSkillImportPreview(
      await this.bridge().invoke(commands.chooseSkillImport, {
        kind,
        target: this.skillImportTarget(target),
      }),
    );
  }
  async prepareSkillImport(
    previewId: string,
    preparationRevision: string,
    target: SkillImportTarget | null,
  ) {
    return decodeSkillImportPreview(
      await this.invoke(commands.prepareSkillImport, {
        previewId,
        preparationRevision,
        target: target === null ? null : this.skillImportTarget(target),
      }),
    );
  }
  async installSkill(
    previewId: string,
    preparationRevision: string,
    confirmation: SkillImportEffect,
  ) {
    return decodeSkillMutationResult(
      await this.invoke(commands.installSkill, {
        previewId,
        preparationRevision,
        confirmation,
      }),
    );
  }
  async reimportSkill(
    previewId: string,
    preparationRevision: string,
    confirmation: SkillImportEffect,
  ) {
    return decodeSkillMutationResult(
      await this.invoke(commands.reimportSkill, {
        previewId,
        preparationRevision,
        confirmation,
      }),
    );
  }
  async uninstallSkill(installId: string) {
    return decodeSkillMutationResult(
      await this.invoke(commands.uninstallSkill, { installId }),
    );
  }
  async retrySkillVerification(installId: string) {
    return decodeSkillMutationResult(
      await this.invoke(commands.retrySkill, { installId }),
    );
  }
  async exportSkill(installId: string) {
    return decodeSkillExportResult(
      await this.bridge().invoke(commands.exportSkill, { installId }),
    );
  }
  async skillDetail(installId: string) {
    return decodeSkillDetailResult(
      await this.invoke(commands.skillDetail, { installId }),
    );
  }
  async setSkillEnabled(
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
  ) {
    return decodeSkillEnablementResult(
      await this.invoke(commands.setSkillEnabled, {
        scope: target.scope,
        workspaceId: target.scope === "project" ? target.workspaceId : null,
        expectedWorkspaceEpoch:
          target.scope === "project" ? target.expectedWorkspaceEpoch : null,
        skillPolicyKey,
        state,
        expectedCatalogRevision,
        expectedSelectionRevision,
      }),
    );
  }
  async cancelMcpInstallation(serverId: string, installationRevision: string) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpCancelInstallation, {
        serverId,
        installationRevision,
      }),
    );
  }

  async createMcpStdioServer(
    expectedDesiredGeneration: string,
    input: McpStdioConnectionInput,
  ) {
    return decodeMcpCreateResult(
      await this.invoke(commands.mcpCreateStdioServer, {
        expectedDesiredGeneration,
        ...input,
      }),
    );
  }
  async probeMcpHttpDraft(
    expectedDesiredGeneration: string,
    displayName: string,
    endpoint: string,
  ) {
    return decodeMcpHttpDraftProbeResult(
      await this.invoke(
        commands.mcpProbeHttpDraft,
        {
          expectedDesiredGeneration,
          displayName,
          endpoint,
        },
        0,
      ),
    );
  }

  async verifyAndAddMcpHttpDraft(
    expectedDesiredGeneration: string,
    displayName: string,
    endpoint: string,
    headers: McpHttpDraftHeader[],
  ) {
    return decodeMcpHttpDraftAddResult(
      await this.invoke(
        commands.mcpVerifyAndAddHttpDraft,
        { expectedDesiredGeneration, displayName, endpoint, headers },
        0,
      ),
    );
  }

  async createMcpHttpServer(
    expectedDesiredGeneration: string,
    input: McpHttpConnectionInput,
  ) {
    return decodeMcpCreateResult(
      await this.invoke(commands.mcpCreateHttpServer, {
        expectedDesiredGeneration,
        ...input,
      }),
    );
  }
  async updateMcpStdioConnection(
    expectedDesiredGeneration: string,
    serverId: string,
    input: McpStdioConnectionInput,
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpUpdateStdioConnection, {
        expectedDesiredGeneration,
        serverId,
        ...input,
      }),
    );
  }
  async updateMcpHttpConnection(
    expectedDesiredGeneration: string,
    serverId: string,
    input: McpHttpConnectionInput,
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpUpdateHttpConnection, {
        expectedDesiredGeneration,
        serverId,
        ...input,
      }),
    );
  }
  async renameMcpServer(
    expectedDesiredGeneration: string,
    serverId: string,
    displayName: string,
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpRenameServer, {
        expectedDesiredGeneration,
        serverId,
        displayName,
      }),
    );
  }
  async setMcpServerEnabled(
    expectedDesiredGeneration: string,
    serverId: string,
    enabled: boolean,
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpSetServerEnabled, {
        expectedDesiredGeneration,
        serverId,
        enabled,
      }),
    );
  }
  async approveMcpConnection(
    expectedDesiredGeneration: string,
    serverId: string,
  ) {
    return decodeMcpMutationResult(
      await this.bridge().invoke(commands.mcpApproveConnection, {
        expectedDesiredGeneration,
        serverId,
      }),
    );
  }
  async captureMcpSecret(
    expectedDesiredGeneration: string,
    serverId: string,
    slot: McpSecretSlot,
    secret: string,
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpCaptureSecret, {
        expectedDesiredGeneration,
        serverId,
        slot,
        secret,
      }),
    );
  }
  async authorizeMcpOAuth(expectedDesiredGeneration: string, serverId: string) {
    return decodeMcpAuthorizationResult(
      await this.invoke(commands.mcpAuthorizeOAuth, {
        expectedDesiredGeneration,
        serverId,
      }),
    );
  }
  async cancelMcpAuthorization(operationId: string) {
    return decodeMcpAuthorizationCancelResult(
      await this.invoke(commands.mcpCancelAuthorization, { operationId }),
    );
  }
  async setMcpAllowedTools(
    expectedDesiredGeneration: string,
    serverId: string,
    toolNames: string[],
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpSetAllowedTools, {
        expectedDesiredGeneration,
        serverId,
        toolNames,
      }),
    );
  }
  async removeMcpServer(expectedDesiredGeneration: string, serverId: string) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpRemoveServer, {
        expectedDesiredGeneration,
        serverId,
      }),
    );
  }
  async refreshMcpCatalog() {
    return decodeMcpRefreshResult(
      await this.invoke(commands.mcpRefreshCatalog, {}),
    );
  }
  async applyMcpConfiguration(serverId?: string) {
    return decodeMcpConfigurationApplyResult(
      await this.invoke(
        commands.mcpApplyConfiguration,
        serverId === undefined ? {} : { serverId },
      ),
    );
  }
  async testMcpConnection(expectedDesiredGeneration: string, serverId: string) {
    return decodeMcpConnectionTestResult(
      await this.invoke(commands.mcpTestConnection, {
        expectedDesiredGeneration,
        serverId,
      }),
    );
  }
  async beginLogin() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountBeginLogin, {}),
    );
  }
  async cancelAccountOperation() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountCancelOperation, {}),
    );
  }
  async retryAccountRefresh() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountRetryRefresh, {}),
    );
  }
  async refreshAccountSummary() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountRefreshSummary, {}),
    );
  }
  async openAccountRecharge() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountOpenRecharge, {}),
    );
  }
  async refreshModelsCatalog() {
    return decodeExecutionCommandResult(
      await this.invoke(commands.modelsRefreshCatalog, {}),
    );
  }
  async resetModelsStore(expectedRevision: string) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.modelsResetStore, { expectedRevision }),
    );
  }
  async createCustomProvider(input: {
    displayName: string;
    protocol: Protocol;
    normalizedBaseUrl: string;
    apiKey: string;
    model?: { id: string };
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customProviderCreate, {
        displayName: input.displayName,
        protocol: input.protocol,
        normalizedBaseUrl: input.normalizedBaseUrl,
        apiKey: input.apiKey,
        ...(input.model ? { model: input.model } : {}),
      }),
    );
  }
  async createBuiltinProvider(input: {
    providerId: string;
    baseUrl: string;
    apiKey: string;
    model?: { id: string };
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.builtinProviderCreate, input),
    );
  }
  async updateBuiltinProviderBaseUrl(input: {
    providerId: string;
    expectedProviderRevision: string;
    baseUrl: string;
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.builtinProviderUpdateBaseUrl, input),
    );
  }
  async updateCustomProvider(input: {
    providerId: string;
    expectedProviderRevision: string;
    displayName: string;
    protocol: Protocol;
    normalizedBaseUrl: string;
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customProviderUpdate, input),
    );
  }
  async replaceCustomProviderCredential(
    providerId: string,
    expectedProviderRevision: string,
    apiKey: string,
  ) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customProviderReplaceCredential, {
        providerId,
        expectedProviderRevision,
        apiKey,
      }),
    );
  }
  async removeCustomProvider(
    providerId: string,
    expectedProviderRevision: string,
  ) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customProviderRemove, {
        providerId,
        expectedProviderRevision,
      }),
    );
  }
  async testCustomModel(
    sourceId: string,
    expectedProviderRevision: string,
    modelId: string,
    expectedSourceGeneration: string,
    expectedCatalogGeneration: string,
  ) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customModelTest, {
        model: { sourceId, modelId },
        expectedProviderRevision,
        expectedSourceGeneration,
        expectedCatalogGeneration,
      }),
    );
  }
  async addCustomModel(input: {
    providerId: string;
    expectedProviderRevision: string;
    expectedCatalogGeneration: string;
    model: {
      id: string;
      displayName?: string;
      metadata?: ModelMetadata;
    };
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customModelAdd, input),
    );
  }
  async replaceCustomModel(input: {
    selection: {
      sourceId: string;
      modelId: string;
    };
    expectedProviderRevision: string;
    expectedCatalogGeneration: string;
    replacement: {
      id: string;
      displayName?: string;
      metadata?: ModelMetadata;
    };
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customModelReplace, input),
    );
  }
  async removeCustomModel(input: {
    selection: {
      sourceId: string;
      modelId: string;
    };
    expectedProviderRevision: string;
    expectedCatalogGeneration: string;
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customModelRemove, input),
    );
  }
  async logout() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountLogout, {}),
    );
  }
  async createTask(
    workspace: TaskWorkspaceIntent,
    modelSelection: NewTaskModelSelectionIntent,
    expectedSkillCatalogRevision: string | null,
    expectedSkillSelectionRevision: string | null,
    approvalMode: ApprovalMode,
    projectId: string | null,
  ) {
    return decodeTaskCreateResult(
      await this.invoke(commands.createTask, {
        workspace,
        projectId,
        modelSelection,
        expectedSkillCatalogRevision,
        expectedSkillSelectionRevision,
        approvalMode,
      }),
    );
  }
  async run(taskId: string, expectedBindingEpoch: string, input: TaskRunInput) {
    return decodeTaskRunResult(
      await this.invoke(commands.run, { taskId, expectedBindingEpoch, input }),
      taskId,
    );
  }
  async sendInput(operationId: string, taskId: string, input: TaskRunInput) {
    return decodeSendInputResult(
      await this.invoke(commands.sendInput, { operationId, taskId, input }),
      taskId,
      operationId,
    );
  }
  /**
   * Replaces one earlier message and reruns the conversation from it. The
   * text is Product's own record of that input as the user edited it: Core
   * stores a user message wrapped in the Host context block, so the message
   * at a conversation position is not what MetaWork sent, and the Renderer
   * never reads it back.
   */
  async editInput(
    operationId: string,
    taskId: string,
    runId: string,
    input: TaskRunInput,
  ) {
    return decodeSendInputResult(
      await this.invoke(commands.editInput, {
        operationId,
        taskId,
        runId,
        input,
      }),
      taskId,
      operationId,
    );
  }
  async retryInput(
    taskId: string,
    originalOperationId: string,
    operationId: string,
  ) {
    return decodeSendInputResult(
      await this.invoke(commands.retryInput, {
        taskId,
        originalOperationId,
        operationId,
      }),
      taskId,
    );
  }
  async discardInputRetry(taskId: string, originalOperationId: string) {
    const item = object(
      await this.invoke(commands.discardInputRetry, {
        taskId,
        originalOperationId,
      }),
      "$",
      ["discarded"],
    );
    if (typeof item.discarded !== "boolean")
      throw new RendererBridgeContractError(
        "invalid_response",
        "Invalid input discard result",
      );
    return item.discarded;
  }
  async retrySessionClose(taskId: string, expectedBindingEpoch: string) {
    const item = object(
      await this.invoke(commands.retrySessionClose, {
        taskId,
        expectedBindingEpoch,
      }),
      "$",
      ["accepted"],
    );
    if (typeof item.accepted !== "boolean")
      throw new RendererBridgeContractError(
        "invalid_response",
        "Invalid Session close retry result",
      );
    return item.accepted;
  }
  async stopTask(taskId: string) {
    const item = object(await this.invoke(commands.stop, { taskId }), "$", [
      "taskId",
      "stopRequested",
    ]);
    if (item.taskId !== taskId || item.stopRequested !== true)
      throw new RendererBridgeContractError(
        "invalid_response",
        "Invalid task stop result",
      );
  }
  createAttachmentAdd(recover: () => Promise<void>, remainingFiles?: number) {
    const connection = this.attachmentConnection;
    if (!connection) throw new Error("Attachment input is unavailable");
    if (this.nextReceiveBatch > 18446744073709551615n)
      throw new Error("Attachment batch identity exhausted");
    const key = {
      generation: connection.generation,
      batchId: String(this.nextReceiveBatch++),
    };
    return new AttachmentAddOperation(
      {
        begin: async (source) => {
          if (
            source.kind === "native_paths" &&
            connection.mode !== "native_paths"
          )
            throw new Error("Attachment source does not match the connection");
          return decodeAttachmentAddBegin(
            await this.bridge().invoke(commands.beginAttachmentAdd, {
              ...key,
              ...(remainingFiles === undefined ? {} : { remainingFiles }),
              source,
            }),
          );
        },
        append: async (fileIndex, offset, dataBase64) =>
          decodeAttachmentAddAcceptance(
            await this.invoke(commands.appendAttachmentAdd, {
              ...key,
              fileIndex,
              offset,
              dataBase64,
            }),
          ),
        finish: async () =>
          decodeAttachmentAddResult(
            await this.bridge().invoke(commands.finishAttachmentAdd, key),
          ),
        cancel: async () =>
          decodeAttachmentCancelResult(
            await this.invoke(commands.cancelAttachmentAdd, key),
          ),
        recover,
      },
      connection.maxChunkBytes,
    );
  }
  async releaseAttachment(token: string) {
    return decodeAttachmentReleaseResult(
      await this.invoke(commands.releaseAttachment, { token }),
    );
  }
  async setApprovalMode(
    taskId: string,
    targetMode: ApprovalMode,
    expectedBindingEpoch: string,
    expectedApprovalRevision: string,
  ) {
    return decodeTaskApprovalModeResult(
      await this.invoke(commands.setApprovalMode, {
        taskId,
        targetMode,
        expectedBindingEpoch,
        expectedApprovalRevision,
      }),
      taskId,
    );
  }
  async selectTaskModel(
    taskId: string,
    expectedSelectionRevision: string,
    targetModelRef: {
      sourceId: string;
      modelId: string;
    },
    expectedSourceGeneration: string,
    expectedCatalogGeneration: string,
  ) {
    return decodeTaskModelSelectionResult(
      await this.invoke(commands.selectTaskModel, {
        taskId,
        expectedSelectionRevision,
        targetModelRef,
        expectedSourceGeneration,
        expectedCatalogGeneration,
      }),
      taskId,
    );
  }
  async compact(taskId: string, expectedBindingEpoch: string) {
    return decodeTaskCompactResult(
      await this.invoke(commands.compact, { taskId, expectedBindingEpoch }),
      taskId,
    );
  }
  async restoreTask(taskId: string, expectedBindingEpoch: string) {
    return decodeTaskRestoreResult(
      await this.invoke(commands.restoreTask, { taskId, expectedBindingEpoch }),
      taskId,
    );
  }
  async cancelCompact(taskId: string, operationId: string) {
    assertCompactCancelAccepted(
      await this.invoke(commands.cancelCompact, { taskId, operationId }),
      taskId,
      operationId,
    );
  }
  async refreshWorkspaceSkillCatalog(
    workspaceId: string,
    expectedWorkspaceEpoch: string,
  ) {
    return decodeCatalogRefreshResult(
      await this.invoke(commands.refreshWorkspaceSkillCatalog, {
        workspaceId,
        expectedWorkspaceEpoch,
      }),
      "workspaceId",
      workspaceId,
    );
  }
  async refreshSkillCatalog() {
    return decodeSkillCatalogRefreshResult(
      await this.invoke(commands.refreshSkillCatalog, {}),
    );
  }
  async refreshTaskSkillCatalog(taskId: string, expectedBindingEpoch: string) {
    return decodeCatalogRefreshResult(
      await this.invoke(commands.refreshTaskSkillCatalog, {
        taskId,
        expectedBindingEpoch,
      }),
      "taskId",
      taskId,
    );
  }
  async cancel(taskId: string, runId: string) {
    assertCancelAccepted(
      await this.invoke(commands.cancel, { taskId, runId }),
      taskId,
      runId,
    );
  }
  async respondUi(
    taskId: string,
    runId: string,
    requestId: string,
    response: UiResponsePayload,
  ) {
    assertUiResponseAccepted(
      await this.invoke(commands.respondUi, {
        taskId,
        runId,
        requestId,
        ...response,
      }),
      taskId,
      runId,
      requestId,
    );
  }
  async renameTask(taskId: string, title: string) {
    assertTaskFlag(
      await this.invoke(commands.renameTask, { taskId, title }),
      taskId,
      "renamed",
    );
  }
  async setTaskArchived(taskId: string, archived: boolean) {
    assertTaskArchived(
      await this.invoke(commands.archiveTask, {
        taskId,
        archived,
      }),
      taskId,
      archived,
    );
  }
  async markTaskCompletionSeen(taskId: string, runId: string) {
    return decodeTaskCompletionSeenResult(
      await this.invoke(commands.markTaskCompletionSeen, { taskId, runId }),
      taskId,
      runId,
    );
  }
  async deleteTask(taskId: string) {
    assertTaskFlag(
      await this.invoke(commands.deleteTask, { taskId }),
      taskId,
      "deleting",
    );
  }
  async recoverTaskHistory(expectedRevision: string) {
    return decodePersistenceRecoveryResult(
      await this.invoke(commands.recoverTaskHistory, { expectedRevision }),
    );
  }
  async createScheduledTask(input: ScheduledTaskMutation) {
    return decodeScheduledTaskMutationResult(
      await this.invoke(commands.createScheduledTask, input),
    );
  }
  async updateScheduledTask(
    scheduledTaskId: string,
    expectedEpoch: string,
    input: ScheduledTaskMutation,
  ) {
    return decodeScheduledTaskMutationResult(
      await this.invoke(commands.updateScheduledTask, {
        scheduledTaskId,
        expectedEpoch,
        ...input,
      }),
      scheduledTaskId,
    );
  }
  async setScheduledTaskEnabled(
    scheduledTaskId: string,
    expectedEpoch: string,
    enabled: boolean,
  ) {
    return decodeScheduledTaskEnabledResult(
      await this.invoke(commands.setScheduledTaskEnabled, {
        scheduledTaskId,
        expectedEpoch,
        enabled,
      }),
      scheduledTaskId,
    );
  }
  async runScheduledTaskNow(scheduledTaskId: string, expectedEpoch: string) {
    return decodeScheduledTaskRunResult(
      await this.invoke(commands.runScheduledTaskNow, {
        scheduledTaskId,
        expectedEpoch,
      }),
      scheduledTaskId,
    );
  }
  async deleteScheduledTask(scheduledTaskId: string, expectedEpoch: string) {
    assertScheduledTaskDeleted(
      await this.invoke(commands.deleteScheduledTask, {
        scheduledTaskId,
        expectedEpoch,
      }),
      scheduledTaskId,
    );
  }
  async recoverScheduledTaskStore(expectedRevision: string) {
    return decodePersistenceRecoveryResult(
      await this.invoke(commands.recoverScheduledTaskStore, {
        expectedRevision,
      }),
    );
  }
}
