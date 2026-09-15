import {
  commands,
  events,
  RENDERER_BRIDGE_CONTRACT_ID,
  RENDERER_BRIDGE_CONTRACT_REVISION,
} from "./commands.ts";
import type { NativeSdkJson, NativeSdkShortcutDetail } from "@native-sdk/cli";
import type {
  HostSignal,
  McpHttpConnectionInput,
  McpSecretSlot,
  McpStdioConnectionInput,
  PermissionProfile,
  Protocol,
  NewTaskModelSelectionIntent,
  ScheduledTaskMutation,
  TaskRunInput,
  TaskWorkspaceIntent,
  UiResponsePayload,
  WorkspaceChoice,
  FilePreview,
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
  decodeExecutionCommandResult,
  decodeCatalogRefreshResult,
  decodeSkillCatalogRefreshResult,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeRendererBridgeConnect,
  decodeRevisionNotification,
  decodeTaskCreateResult,
  decodeTaskCompactResult,
  decodeTaskRestoreResult,
  decodeTaskRunResult,
  decodeTaskCompletionSeenResult,
  decodeTaskModelSelectionResult,
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
  decodeFilePreview,
  decodeFileChangeDiff,
  decodeAttachmentChooseResult,
  decodeAttachmentReleaseResult,
  decodeAttachmentReceiveResult,
  decodeAttachmentReceiveAcceptance,
} from "./decode-contracts.ts";
import { RendererBridgeContractError } from "./contract-error.ts";
import { fetchWorkbenchSnapshot } from "./snapshot/snapshot-client.ts";
import { AttachmentReceive } from "./attachment-receive.ts";

export {
  RendererBridgeContractError,
  type RendererBridgeContractErrorCode,
} from "./contract-error.ts";

export type NativeBridge = NonNullable<typeof window.zero>;

const defaultCommandTimeoutMs = 10_000;

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

  constructor(options: BridgeClientOptions = {}) {
    this.bridgeOverride = options.bridge;
    this.commandTimeoutMs = options.commandTimeoutMs ?? defaultCommandTimeoutMs;
  }

  private bridge() {
    const bridge = this.bridgeOverride ?? window.zero;
    if (!bridge) throw new Error("Native Host bridge is unavailable");
    return bridge;
  }

  private invoke(command: string, payload: NativeSdkJson) {
    const pending = this.bridge().invoke(command, payload);
    if (this.commandTimeoutMs <= 0) return pending;

    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () =>
          reject(new BridgeCommandTimeoutError(command, this.commandTimeoutMs)),
        this.commandTimeoutMs,
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
    consume: (revision: string) => void,
    reject: (error: unknown) => void,
  ) {
    return this.bridge().on<unknown>(events.workbench, (value) => {
      try {
        consume(decodeRevisionNotification(value));
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

  async connect() {
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
    return result.generation;
  }

  async disconnect(generation: string) {
    if (this.attachmentConnection?.generation === generation)
      this.attachmentConnection = undefined;
    assertDisconnected(
      await this.invoke(commands.disconnect, { generation }),
      generation,
    );
  }

  fetchSnapshot() {
    return fetchWorkbenchSnapshot((command, payload) =>
      this.invoke(command, payload),
    );
  }

  async previewFile(
    taskId: string,
    runId: string,
    fileReferenceId: string,
  ): Promise<FilePreview> {
    return decodeFilePreview(
      await this.invoke(commands.previewFile, {
        taskId,
        runId,
        fileReferenceId,
      }),
    );
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

  async chooseSkillImport(kind: "package" | "directory") {
    return decodeSkillImportPreview(
      await this.bridge().invoke(commands.chooseSkillImport, { kind }),
    );
  }

  async installSkill(
    previewId: string,
    scope:
      | { kind: "personal" }
      | { kind: "project"; workspaceId: string; workspaceEpoch: string },
    allowReplace: boolean,
  ) {
    return decodeSkillMutationResult(
      await this.invoke(commands.installSkill, {
        previewId,
        scope: scope.kind,
        workspaceId: scope.kind === "project" ? scope.workspaceId : null,
        expectedWorkspaceEpoch:
          scope.kind === "project" ? scope.workspaceEpoch : null,
        allowReplace,
      }),
    );
  }

  async reimportSkill(installId: string, previewId: string) {
    return decodeSkillMutationResult(
      await this.invoke(commands.reimportSkill, { installId, previewId }),
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

  async selectMetaskApiKey(input: {
    sourceId: string;
    expectedMetaskSelectionRevision: string;
    expectedCatalogGeneration: string;
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.selectMetaskApiKey, input),
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
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customProviderCreate, {
        displayName: input.displayName,
        protocol: input.protocol,
        normalizedBaseUrl: input.normalizedBaseUrl,
        apiKey: input.apiKey,
      }),
    );
  }

  async createBuiltinProvider(input: {
    providerId: string;
    baseUrl: string;
    apiKey: string;
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
    model: { id: string; displayName?: string; metadata?: ModelMetadata };
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customModelAdd, input),
    );
  }

  async replaceCustomModel(input: {
    selection: { sourceId: string; modelId: string };
    expectedProviderRevision: string;
    expectedCatalogGeneration: string;
    replacement: { id: string; displayName?: string; metadata?: ModelMetadata };
  }) {
    return decodeExecutionCommandResult(
      await this.invoke(commands.customModelReplace, input),
    );
  }

  async removeCustomModel(input: {
    selection: { sourceId: string; modelId: string };
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
    permissionProfile: PermissionProfile,
  ) {
    return decodeTaskCreateResult(
      await this.invoke(commands.createTask, {
        workspace,
        expectedExecutionGeneration,
        expectedSelectionRevision,
        modelSelection,
        expectedSkillCatalogRevision,
        expectedSkillSelectionRevision,
        permissionProfile,
      }),
    );
  }

  async run(taskId: string, expectedBindingEpoch: string, input: TaskRunInput) {
    return decodeTaskRunResult(
      await this.invoke(commands.run, { taskId, expectedBindingEpoch, input }),
      taskId,
    );
  }

  async chooseAttachments() {
    // Like Workspace and Skill pickers, this command includes a user-controlled
    // native modal. A fixed Bridge timeout would abandon a valid selection and
    // leave the resulting staged grants without a Renderer consumer.
    return decodeAttachmentChooseResult(
      await this.bridge().invoke(commands.chooseAttachments, {}),
    );
  }

  createAttachmentReceive() {
    const connection = this.attachmentConnection;
    if (connection?.mode !== "file_bytes")
      throw new Error("File byte input is unavailable");
    if (this.nextReceiveBatch > 18446744073709551615n)
      throw new Error("Attachment batch identity exhausted");
    const key = {
      generation: connection.generation,
      batchId: String(this.nextReceiveBatch++),
    };
    return new AttachmentReceive(
      {
        begin: async (files) =>
          decodeAttachmentReceiveAcceptance(
            await this.invoke(commands.beginAttachmentReceive, {
              ...key,
              files,
            }),
          ),
        append: async (fileIndex, offset, dataBase64) =>
          decodeAttachmentReceiveAcceptance(
            await this.invoke(commands.appendAttachmentReceive, {
              ...key,
              fileIndex,
              offset,
              dataBase64,
            }),
          ),
        finish: async () =>
          decodeAttachmentReceiveResult(
            await this.invoke(commands.finishAttachmentReceive, key),
          ),
        cancel: async () =>
          decodeAttachmentReleaseResult(
            await this.invoke(commands.cancelAttachmentReceive, key),
          ),
      },
      connection.maxChunkBytes,
    );
  }

  async addDroppedAttachments(paths: string[]) {
    return decodeAttachmentChooseResult(
      await this.bridge().invoke(commands.addDroppedAttachments, { paths }),
    );
  }

  async releaseAttachment(token: string) {
    return decodeAttachmentReleaseResult(
      await this.invoke(commands.releaseAttachment, { token }),
    );
  }

  async selectTaskModel(
    taskId: string,
    expectedModel: string,
    expectedExecutionGeneration: string,
    targetModelRef: { sourceId: string; modelId: string },
    expectedSourceGeneration: string,
    expectedCatalogGeneration: string,
  ) {
    return decodeTaskModelSelectionResult(
      await this.invoke(commands.selectTaskModel, {
        taskId,
        expectedModel,
        expectedExecutionGeneration,
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
      enabled,
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
