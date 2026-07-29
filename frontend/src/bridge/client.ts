import {
  commands,
  events,
  RENDERER_BRIDGE_CONTRACT_ID,
  RENDERER_BRIDGE_CONTRACT_REVISION,
} from "./commands.ts";
import type { NativeSdkJson, NativeSdkShortcutDetail } from "@native-sdk/cli";
import type {
  HostSignal,
  TaskRunInput,
  UiResponsePayload,
  WorkspaceChoice,
} from "./contracts.ts";
import {
  assertCancelAccepted,
  assertCloseAccepted,
  assertDisconnected,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  assertUiResponseAccepted,
  assertWindowDragStarted,
  assertWindowControlCompleted,
  decodeAccountCommandResult,
  decodeCatalogRefreshResult,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeRendererBridgeConnect,
  decodeRevisionNotification,
  decodeTaskCreateResult,
  decodeTaskRunResult,
  decodeWorkspaceMutationResult,
  decodeWorkspaceChoice,
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

  async beginWindowDrag(clicks: 1) {
    assertWindowDragStarted(
      await this.invoke(commands.windowBeginDrag, { clicks }),
    );
  }

  async controlWindow(action: "minimize" | "toggle_maximize" | "close") {
    assertWindowControlCompleted(
      await this.invoke(commands.windowControl, { action }),
    );
  }

  fetchSnapshot() {
    return fetchWorkbenchSnapshot((command, payload) =>
      this.invoke(command, payload),
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

  async selectWorkspace(workspaceId: string, expectedWorkspaceEpoch: string) {
    return decodeWorkspaceMutationResult(
      await this.invoke(commands.selectWorkspace, {
        workspaceId,
        expectedWorkspaceEpoch,
      }),
      workspaceId,
    );
  }

  async removeWorkspace(workspaceId: string, expectedWorkspaceEpoch: string) {
    return decodeWorkspaceMutationResult(
      await this.invoke(commands.removeWorkspace, {
        workspaceId,
        expectedWorkspaceEpoch,
      }),
      workspaceId,
    );
  }

  async beginLogin() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountBeginLogin, {}),
    );
  }

  async reopenLogin() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountReopenLogin, {}),
    );
  }

  async reauthenticate() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountReauthenticate, {}),
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

  async logout() {
    return decodeAccountCommandResult(
      await this.invoke(commands.accountLogout, {}),
    );
  }

  async createTask(
    workspaceId: string,
    expectedWorkspaceEpoch: string,
    expectedExecutionGeneration: string,
    expectedSkillCatalogRevision: string | null,
  ) {
    return decodeTaskCreateResult(
      await this.invoke(commands.createTask, {
        workspaceId,
        expectedWorkspaceEpoch,
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
}
