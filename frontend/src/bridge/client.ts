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
  ScheduledTaskMutation,
  TaskRunInput,
  TaskWorkspaceIntent,
  UiResponsePayload,
  WorkspaceChoice,
  FilePreview,
} from "./contracts.ts";
import {
  assertCancelAccepted,
  assertCompactCancelAccepted,
  assertCloseAccepted,
  assertDisconnected,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  assertUiResponseAccepted,
  decodeAccountCommandResult,
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
  decodeTaskModelSelectionResult,
  decodeScheduledTaskMutationResult,
  decodeScheduledTaskEnabledResult,
  decodeScheduledTaskRunResult,
  assertScheduledTaskDeleted,
  decodeWorkspaceChoice,
  decodeSkillImportPreview,
  decodeSkillMutationResult,
  decodeSkillExportResult,
  decodeSkillDetailResult,
  decodeMcpMutationResult,
  decodeMcpRefreshResult,
  decodeMcpConnectionTestResult,
  decodeMcpAuthorizationResult,
  decodeMcpAuthorizationCancelResult,
  decodeFilePreview,
} from "./decode-contracts.ts";
import { RendererBridgeContractError } from "./contract-error.ts";
import { fetchWorkbenchSnapshot } from "./snapshot/snapshot-client.ts";

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
    return result.generation;
  }

  async disconnect(generation: string) {
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

  async previewFile(fileReferenceId: string): Promise<FilePreview> {
    return decodeFilePreview(
      await this.invoke(commands.previewFile, { fileReferenceId }),
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
  ) {
    return decodeMcpMutationResult(
      await this.invoke(commands.mcpCaptureSecret, {
        expectedDesiredGeneration,
        serverId,
        slot,
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

  async refreshAccountCatalog() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountRefreshCatalog, {}),
    );
  }

  async selectApiKey(
    selectionId: string,
    expectedCatalogGeneration: string,
    expectedExecutionGeneration: string,
  ) {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountSelectApiKey, {
        selectionId,
        expectedCatalogGeneration,
        expectedExecutionGeneration,
      }),
    );
  }

  async selectModel(
    selectionId: string,
    expectedCatalogGeneration: string,
    expectedExecutionGeneration: string,
  ) {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountSelectModel, {
        selectionId,
        expectedCatalogGeneration,
        expectedExecutionGeneration,
      }),
    );
  }

  async createModelConnection(input: {
    displayName: string;
    protocol:
      "anthropic_messages" | "openai_chat_completions" | "gemini_native";
    normalizedBaseUrl: string;
    modelId: string;
    modelDisplayName?: string;
  }) {
    return decodeAccountCommandResult(
      await this.invoke(commands.modelConnectionCreate, input),
    );
  }

  async updateModelConnection(input: {
    connectionId: string;
    expectedConnectionGeneration: string;
    displayName: string;
    protocol:
      "anthropic_messages" | "openai_chat_completions" | "gemini_native";
    normalizedBaseUrl: string;
  }) {
    return decodeAccountCommandResult(
      await this.invoke(commands.modelConnectionUpdate, input),
    );
  }

  async removeModelConnection(
    connectionId: string,
    expectedConnectionGeneration: string,
  ) {
    return decodeAccountCommandResult(
      await this.invoke(commands.modelConnectionRemove, {
        connectionId,
        expectedConnectionGeneration,
      }),
    );
  }

  async testModelConnection(
    connectionId: string,
    expectedConnectionGeneration: string,
    modelId: string,
  ) {
    return decodeAccountCommandResult(
      await this.invoke(commands.modelConnectionTest, {
        connectionId,
        expectedConnectionGeneration,
        modelId,
      }),
    );
  }

  async selectDefaultModelConnection(
    connectionId: string,
    expectedConnectionGeneration: string,
    modelId: string,
  ) {
    return decodeAccountCommandResult(
      await this.invoke(commands.modelConnectionSelectDefault, {
        connectionId,
        expectedConnectionGeneration,
        modelId,
      }),
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
    expectedSkillCatalogRevision: string | null,
  ) {
    return decodeTaskCreateResult(
      await this.invoke(commands.createTask, {
        workspace,
        expectedExecutionGeneration,
        expectedSkillCatalogRevision,
      }),
    );
  }

  async run(taskId: string, expectedBindingEpoch: string, input: TaskRunInput) {
    return decodeTaskRunResult(
      await this.invoke(commands.run, { taskId, expectedBindingEpoch, input }),
      taskId,
    );
  }

  async selectTaskModel(
    taskId: string,
    expectedModel: string,
    expectedCatalogGeneration: string,
    selectionId: string,
  ) {
    return decodeTaskModelSelectionResult(
      await this.invoke(commands.selectTaskModel, {
        taskId,
        expectedModel,
        expectedCatalogGeneration,
        selectionId,
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

  async closeTask(taskId: string) {
    assertCloseAccepted(
      await this.invoke(commands.closeTask, { taskId }),
      taskId,
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

  async deleteTask(taskId: string) {
    assertTaskFlag(
      await this.invoke(commands.deleteTask, { taskId }),
      taskId,
      "deleted",
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
}
