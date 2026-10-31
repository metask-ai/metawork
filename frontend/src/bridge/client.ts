import type { SkillImportTarget, SkillImportEffect } from "./contracts.ts";
import { PreviewImagePool } from "./preview-image-pool.ts";
import { FilePreviewLoader } from "./file-preview.ts";
import { object } from "./wire-codec.ts";
import {
  decodeOutputActionResult,
  decodeOutputActionCancel,
  decodeSendInputResult,
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
  OutputAction,
  OutputActionState,
  ViewScope,
  McpHttpConnectionInput,
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
  FilePreview,
  FilePreviewLoadOptions,
  FileChangeDiffResult,
  ModelMetadata,
  SkillSourceBrand,
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
  decodeExecutionCommandResult,
  decodeCatalogRefreshResult,
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
  decodeSkillSourceSettingsResult,
  decodeSkillExportResult,
  decodeSkillDetailResult,
  decodeMcpMutationResult,
  decodeMcpRefreshResult,
  decodeMcpConfigurationApplyResult,
  decodeMcpConnectionTestResult,
  decodeMcpAuthorizationResult,
  decodeMcpAuthorizationCancelResult,
  decodeFileChangeDiff,
  decodeAttachmentReleaseResult,
  decodeAttachmentAddBegin,
  decodeAttachmentAddAcceptance,
  decodeAttachmentAddResult,
  decodeAttachmentCancelResult,
  decodeAutomaticWorkspaceRootMutationResult,
  decodeExternalLinkOpenResult,
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
  private nextOutputOperation = 1n;
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
    this.nextOutputOperation = 1n;
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
  async openExternalLink(url: string) {
    return decodeExternalLinkOpenResult(
      await this.invoke(commands.openExternalLink, { url }),
    );
  }
  async outputAction(
    taskId: string,
    runId: string,
    outputId: string,
    action: OutputAction,
    signal: AbortSignal,
  ): Promise<OutputActionState> {
    const connection = this.attachmentConnection;
    if (!connection) throw new Error("Host connection is unavailable");
    if (signal.aborted)
      throw new DOMException("Output action cancelled", "AbortError");
    if (this.nextOutputOperation > 18446744073709551615n)
      throw new Error("Output operation identity exhausted");
    const key = {
      generation: connection.generation,
      operationId: String(this.nextOutputOperation++),
    };
    const matches = (result: { generation: string; operationId: string }) => {
      if (
        result.generation !== key.generation ||
        result.operationId !== key.operationId
      )
        throw new RendererBridgeContractError(
          "invalid_response",
          "Output operation identity mismatch",
        );
    };
    let cancelled = false;
    const cancel = () => {
      if (cancelled) return;
      cancelled = true;
      if (this.attachmentConnection?.generation !== key.generation) return;
      void this.invoke(commands.cancelOutputAction, key)
        .then(decodeOutputActionCancel)
        .then(matches)
        .catch(() => undefined);
    };
    signal.addEventListener("abort", cancel, { once: true });
    try {
      const result = decodeOutputActionResult(
        await this.invoke(
          commands.outputAction,
          { ...key, taskId, runId, outputId, action },
          action === "save" || this.commandTimeoutMs <= 0
            ? 0
            : Math.max(35000, this.commandTimeoutMs),
        ),
      );
      matches(result);
      if (
        (signal.aborted && action !== "save") ||
        this.attachmentConnection?.generation !== key.generation
      )
        throw new DOMException("Output action cancelled", "AbortError");
      if (
        (action === "check" && result.state === "revealed") ||
        (action === "reveal" && result.state === "ready") ||
        (action === "save" &&
          (result.state === "ready" || result.state === "revealed")) ||
        (action !== "save" &&
          ["saved", "save_failed", "target_changed", "cleanup_failed"].includes(
            result.state,
          ))
      )
        throw new RendererBridgeContractError(
          "invalid_response",
          "Output action result mismatch",
        );
      return result.state;
    } catch (error) {
      cancel();
      throw error;
    } finally {
      signal.removeEventListener("abort", cancel);
    }
  }
  previewFile(
    taskId: string,
    runId: string,
    fileReferenceId: string,
    options?: FilePreviewLoadOptions,
  ): Promise<FilePreview> {
    return this.previews.load(taskId, runId, fileReferenceId, options);
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
  previewWorkspaceFile(
    taskId: string,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
    options?: FilePreviewLoadOptions,
  ) {
    return this.previews.loadWorkspace(
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
  async setSkillSourceEnabled(
    sourceId: SkillSourceBrand,
    enabled: boolean,
    expectedRevision: string,
  ) {
    return decodeSkillSourceSettingsResult(
      await this.invoke(commands.setSkillSourceEnabled, {
        sourceId,
        enabled,
        expectedRevision,
      }),
    );
  }
  async recoverSkillSourceSettings(
    action: "reread" | "reset",
    expectedRecoveryToken: string,
  ) {
    return decodeSkillSourceSettingsResult(
      await this.invoke(commands.recoverSkillSourceSettings, {
        action,
        expectedRecoveryToken,
      }),
    );
  }
  async createMcpStdioServer(
    expectedDesiredGeneration: string,
    input: McpStdioConnectionInput,
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpCreateStdioServer, {
        expectedDesiredGeneration,
        ...input,
      }),
    );
  }
  async createMcpHttpServer(
    expectedDesiredGeneration: string,
    input: McpHttpConnectionInput,
  ) {
    return decodeMcpMutationResult(
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
      await this.invoke(commands.mcpApproveConnection, {
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
  async applyMcpConfiguration() {
    return decodeMcpConfigurationApplyResult(
      await this.invoke(commands.mcpApplyConfiguration, {}),
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
  async configureMetaskSelection(input: {
    sourceId: string;
    modelId: string;
    expectedMetaskSelectionRevision: string;
    expectedCatalogGeneration: string;
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.configureMetaskSelection, input),
    );
  }
  async selectModelsDefault(input: {
    sourceId: string;
    modelId: string;
    expectedSelectionRevision: string;
    expectedSourceGeneration: string;
    expectedCatalogGeneration: string;
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.selectModelsDefault, input),
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
    expectedExecutionGeneration: string,
    expectedSelectionRevision: string,
    modelSelection: NewTaskModelSelectionIntent | null,
    expectedSkillCatalogRevision: string | null,
    expectedSkillSelectionRevision: string | null,
    approvalMode: ApprovalMode,
  ) {
    return decodeTaskCreateResult(
      await this.invoke(commands.createTask, {
        workspace,
        expectedExecutionGeneration,
        expectedSelectionRevision,
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
  createAttachmentAdd(recover: () => Promise<void>) {
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
