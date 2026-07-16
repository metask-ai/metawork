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
  assertUiResponseAccepted,
  decodeGeneration,
  decodeHostSignalEvent,
  decodePingResponse,
  decodeRevisionNotification,
  decodeSessionId,
  decodeWorkspaceChoice,
} from "./decode-contracts.ts";
import { fetchWorkbenchSnapshot } from "./snapshot/snapshot-client.ts";

export type NativeBridge = NonNullable<typeof window.zero>;

export class HostClient {
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

  async createSession(workspaceGrant: string) {
    return decodeSessionId(
      await this.bridge().invoke(commands.createSession, { workspaceGrant }),
    );
  }

  async run(sessionId: string, prompt: string) {
    return assertRunAccepted(
      await this.bridge().invoke(commands.run, { sessionId, prompt }),
      sessionId,
    );
  }

  async cancel(sessionId: string, runId: string) {
    assertCancelAccepted(
      await this.bridge().invoke(commands.cancel, { sessionId, runId }),
      sessionId,
      runId,
    );
  }

  async respondUi(
    sessionId: string,
    runId: string,
    requestId: string,
    response: UiResponsePayload,
  ) {
    assertUiResponseAccepted(
      await this.bridge().invoke(commands.respondUi, {
        sessionId,
        runId,
        requestId,
        ...response,
      }),
      sessionId,
      runId,
      requestId,
    );
  }

  async closeSession(sessionId: string) {
    assertCloseAccepted(
      await this.bridge().invoke(commands.closeSession, { sessionId }),
      sessionId,
    );
  }
}
