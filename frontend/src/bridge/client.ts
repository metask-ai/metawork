import { commands, events } from "./commands.ts";
import type {
  HostSignal,
  UiResponsePayload,
  WorkspaceChoice,
} from "./contracts.ts";
import {
  assertCancelAccepted,
  assertCloseAccepted,
  assertDisconnected,
  assertRunAccepted,
  assertSignalAcknowledged,
  assertTaskArchived,
  assertTaskFlag,
  assertUiResponseAccepted,
  decodeAccountCommandResult,
  decodeGeneration,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeRevisionNotification,
  decodeTaskId,
  decodeWorkspaceChoice,
} from "./decode-contracts.ts";
import { fetchWorkbenchSnapshot } from "./snapshot/snapshot-client.ts";

export type NativeBridge = NonNullable<typeof window.zero>;

export class BridgeClient {
  private bridge() {
    const bridge = window.zero;
    if (!bridge) throw new Error("Native Host bridge is unavailable");
    return bridge;
  }

  available() {
    return window.zero !== undefined;
  }

  nativeBridgeForAutomationFixture() {
    return this.bridge();
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
    return decodeGeneration(await this.bridge().invoke(commands.connect, {}));
  }

  async disconnect(generation: string) {
    assertDisconnected(
      await this.bridge().invoke(commands.disconnect, { generation }),
      generation,
    );
  }

  fetchSnapshot() {
    return fetchWorkbenchSnapshot((command, payload) =>
      this.bridge().invoke(command, payload),
    );
  }

  async ping() {
    return decodePingResponse(
      await this.bridge().invoke(commands.ping, {
        source: "workbench-renderer",
      }),
    );
  }

  async acknowledgeSignal(sequence: number) {
    assertSignalAcknowledged(
      await this.bridge().invoke(commands.pingAck, { sequence }),
      sequence,
    );
  }

  async chooseWorkspace(): Promise<WorkspaceChoice> {
    return decodeWorkspaceChoice(
      await this.bridge().invoke(commands.chooseWorkspace, {}),
    );
  }

  async beginLogin() {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountBeginLogin, {}),
    );
  }

  async reopenLogin() {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountReopenLogin, {}),
    );
  }

  async reauthenticate() {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountReauthenticate, {}),
    );
  }

  async cancelAccountOperation() {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountCancelOperation, {}),
    );
  }

  async refreshAccountCatalog() {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountRefreshCatalog, {}),
    );
  }

  async selectApiKey(apiKeyId: string) {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountSelectApiKey, { apiKeyId }),
    );
  }

  async selectModel(modelId: string) {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountSelectModel, { modelId }),
    );
  }

  async logout() {
    return decodeAccountCommandResult(
      await this.bridge().invoke(commands.accountLogout, {}),
    );
  }

  async createTask(workspaceGrant: string) {
    return decodeTaskId(
      await this.bridge().invoke(commands.createTask, { workspaceGrant }),
    );
  }

  async run(taskId: string, prompt: string) {
    return assertRunAccepted(
      await this.bridge().invoke(commands.run, { taskId, prompt }),
      taskId,
    );
  }

  async cancel(taskId: string, runId: string) {
    assertCancelAccepted(
      await this.bridge().invoke(commands.cancel, { taskId, runId }),
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
      await this.bridge().invoke(commands.respondUi, {
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
      await this.bridge().invoke(commands.closeTask, { taskId }),
      taskId,
    );
  }

  async renameTask(taskId: string, title: string) {
    assertTaskFlag(
      await this.bridge().invoke(commands.renameTask, { taskId, title }),
      taskId,
      "renamed",
    );
  }

  async setTaskArchived(taskId: string, archived: boolean) {
    assertTaskArchived(
      await this.bridge().invoke(commands.archiveTask, {
        taskId,
        archived,
      }),
      taskId,
      archived,
    );
  }

  async deleteTask(taskId: string) {
    assertTaskFlag(
      await this.bridge().invoke(commands.deleteTask, { taskId }),
      taskId,
      "deleted",
    );
  }
}
