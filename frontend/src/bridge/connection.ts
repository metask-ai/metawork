import type { WorkbenchSnapshot } from "./contracts.ts";
import { BridgeClient } from "./client.ts";
import {
  RendererBridgeContractError,
  type RendererBridgeContractErrorCode,
} from "./contract-error.ts";
import { RevisionNotificationQueue } from "./revision-notification.ts";
import { SnapshotDemand } from "./snapshot/snapshot-demand.ts";

export type WorkbenchConnectionCallbacks = {
  onSnapshot: (snapshot: WorkbenchSnapshot, generation: string) => void;
  onStatus: (status: WorkbenchConnectionStatus) => void;
  onReady: (ready: boolean) => void;
  onViewSyncFailed: (failed: boolean) => void;
  onGeneration?: (generation: string) => void;
};

export type WorkbenchConnectionFailure =
  | "bootstrap_failed"
  | "connection_unavailable"
  | "snapshot_sync_failed"
  | "snapshot_contract_failed";

export type WorkbenchConnectionStatus =
  | { kind: "connected"; recovered: boolean }
  | {
      kind: "refresh_failed";
      failure: "snapshot_sync_failed";
      diagnostic: string;
    }
  | {
      kind: "connection_failed";
      failure: "bootstrap_failed" | "connection_unavailable";
      diagnostic: string;
    }
  | {
      kind: "contract_failed";
      failure:
        | "bootstrap_failed"
        | "connection_unavailable"
        | "snapshot_contract_failed";
      source:
        | "bootstrap"
        | "snapshot"
        | "revision"
        | "host_signal_ack"
        | "host_signal";
      code: RendererBridgeContractErrorCode;
      diagnostic: string;
    };

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function revisionValue(value: string) {
  try {
    return BigInt(value);
  } catch {
    return -1n;
  }
}

export class WorkbenchConnection {
  private generation = "0";
  private readonly demand = new SnapshotDemand();
  private snapshotInFlight: Promise<void> | null = null;
  private stopped = false;
  private removeWorkbench: (() => void) | null = null;
  private removeHostSignal: (() => void) | null = null;
  private readonly revisions: RevisionNotificationQueue;
  private readonly client: BridgeClient;
  private readonly callbacks: WorkbenchConnectionCallbacks;

  constructor(client: BridgeClient, callbacks: WorkbenchConnectionCallbacks) {
    this.client = client;
    this.callbacks = callbacks;
    this.revisions = new RevisionNotificationQueue((revision) => {
      void this.refresh(revision).catch((error) => {
        if (error instanceof RendererBridgeContractError) return;
        this.callbacks.onStatus({
          kind: "refresh_failed",
          failure: "snapshot_sync_failed",
          diagnostic: errorText(error),
        });
      });
    });
  }

  async start() {
    if (!this.client.available()) return;
    this.removeWorkbench = this.client.onWorkbenchRevision(
      (revision) => this.revisions.push(revision),
      (error) => this.failNotification("revision", error),
    );
    this.removeHostSignal = this.client.onHostSignal(
      (signal) => {
        void this.client
          .acknowledgeSignal(signal.sequence)
          .catch((error) => this.failNotification("host_signal_ack", error));
      },
      (error) => this.failNotification("host_signal", error),
    );
    await this.connect("bootstrap_failed");
    if (this.stopped) return;
    try {
      await this.confirmConnection(false);
    } catch (error) {
      await this.disconnectCurrent();
      if (error instanceof RendererBridgeContractError)
        this.failNotification("bootstrap", error);
      else this.failConnection("bootstrap_failed", error);
      throw error;
    }
  }

  async retry(options: { replaceConnection?: boolean } = {}) {
    if (this.stopped) throw new Error("Workbench connection is stopped");
    if (options.replaceConnection) await this.disconnectCurrent();
    this.demand.resetRetry();
    this.callbacks.onViewSyncFailed(false);
    if (this.generation !== "0") {
      const stale = this.generation;
      try {
        await this.refresh();
        return;
      } catch (error) {
        if (error instanceof RendererBridgeContractError) throw error;
        this.markDisconnected();
        await this.client.disconnect(stale).catch(() => undefined);
      }
    }
    const errors: unknown[] = [];
    for (const delay of [0, 50, 200, 500, 1000]) {
      if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
      try {
        await this.connect("connection_unavailable");
        if (this.stopped) throw new Error("Workbench connection is stopped");
        try {
          await this.confirmConnection(true);
        } catch (error) {
          if (error instanceof RendererBridgeContractError)
            this.failNotification("bootstrap", error, "connection_unavailable");
          else this.failConnection("connection_unavailable", error);
          throw error;
        }
        return;
      } catch (error) {
        await this.disconnectCurrent();
        if (error instanceof RendererBridgeContractError) throw error;
        errors.push(error);
      }
    }
    throw new AggregateError(
      errors,
      "Workbench Host connection recovery failed",
    );
  }

  refresh(targetRevision?: string): Promise<void> {
    if (targetRevision === undefined) {
      this.demand.request();
    } else {
      this.demand.request(revisionValue(targetRevision));
      if (!this.demand.needsRefresh() && !this.snapshotInFlight)
        return Promise.resolve();
    }
    if (this.snapshotInFlight) return this.snapshotInFlight;

    const pending = (async () => {
      try {
        while (this.demand.needsRefresh()) {
          if (this.generation === "0" || this.stopped) return;
          const attemptGeneration = this.generation;
          this.demand.beginAttempt();
          try {
            const next = await this.client.fetchSnapshot();
            if (this.generation !== attemptGeneration || this.stopped) return;
            const revision = revisionValue(next.revision);
            if (revision < 0n)
              throw new Error("Host returned an invalid Workbench revision");
            if (!this.demand.accept(revision))
              throw new Error("Host returned a stale Workbench revision");
            this.callbacks.onSnapshot(next, attemptGeneration);
            if (this.demand.needsRefresh())
              throw new Error(
                "Host snapshot did not reach the notified Workbench revision",
              );
            this.callbacks.onViewSyncFailed(false);
            this.callbacks.onReady(true);
          } catch (error) {
            if (this.generation !== attemptGeneration || this.stopped) return;
            this.callbacks.onReady(false);
            if (error instanceof RendererBridgeContractError) {
              this.failNotification("snapshot", error);
              throw error;
            }
            const delay = this.demand.failAttempt();
            if (delay === null) {
              this.callbacks.onViewSyncFailed(true);
              this.callbacks.onReady(false);
              this.callbacks.onStatus({
                kind: "refresh_failed",
                failure: "snapshot_sync_failed",
                diagnostic: errorText(error),
              });
              throw error;
            }
            await new Promise((resolve) => setTimeout(resolve, delay));
          }
        }
      } finally {
        this.snapshotInFlight = null;
      }
    })();
    this.snapshotInFlight = pending;
    return pending;
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    this.revisions.stop();
    this.removeWorkbench?.();
    this.removeHostSignal?.();
    this.removeWorkbench = null;
    this.removeHostSignal = null;
    const active = this.generation;
    this.markDisconnected();
    if (active !== "0")
      await this.client.disconnect(active).catch(() => undefined);
  }

  private async connect(
    connectFailure: "bootstrap_failed" | "connection_unavailable",
  ) {
    let next: string;
    try {
      next = await this.client.connect();
    } catch (error) {
      if (error instanceof RendererBridgeContractError)
        this.failNotification("bootstrap", error, "bootstrap_failed");
      else this.failConnection(connectFailure, error);
      throw error;
    }
    if (this.stopped) {
      await this.client.disconnect(next).catch(() => undefined);
      return;
    }
    this.generation = next;
    this.callbacks.onGeneration?.(next);
    this.demand.beginGeneration(next);
    this.callbacks.onViewSyncFailed(false);
    try {
      await this.refresh();
      if (this.generation !== next)
        throw new Error("Host generation changed during Workbench resync");
      if (this.demand.needsRefresh()) await this.refresh();
    } catch (error) {
      this.markDisconnected();
      await this.client.disconnect(next).catch(() => undefined);
      throw error;
    }
  }

  private markDisconnected() {
    this.generation = "0";
    this.callbacks.onGeneration?.("0");
    this.demand.beginGeneration("0");
    this.callbacks.onReady(false);
  }

  private async disconnectCurrent() {
    const active = this.generation;
    this.markDisconnected();
    if (active !== "0")
      await this.client.disconnect(active).catch(() => undefined);
  }

  private async confirmConnection(recovered: boolean) {
    if (this.stopped) return;
    const signal = await this.client.ping();
    if (this.stopped) return;
    this.callbacks.onStatus({ kind: "connected", recovered });
  }

  private failNotification(
    source: Extract<
      WorkbenchConnectionStatus,
      { kind: "contract_failed" }
    >["source"],
    error: unknown,
    failureOverride?:
      | "bootstrap_failed"
      | "connection_unavailable"
      | "snapshot_contract_failed",
  ) {
    if (this.stopped) return;
    this.callbacks.onViewSyncFailed(true);
    this.callbacks.onReady(false);
    this.callbacks.onStatus({
      kind: "contract_failed",
      failure:
        failureOverride ??
        (source === "bootstrap"
          ? "bootstrap_failed"
          : source === "snapshot"
            ? "snapshot_contract_failed"
            : "connection_unavailable"),
      source,
      code:
        error instanceof RendererBridgeContractError
          ? error.code
          : "invalid_response",
      diagnostic: errorText(error),
    });
  }

  private failConnection(
    failure: "bootstrap_failed" | "connection_unavailable",
    error: unknown,
  ) {
    if (this.stopped) return;
    this.callbacks.onViewSyncFailed(true);
    this.callbacks.onReady(false);
    this.callbacks.onStatus({
      kind: "connection_failed",
      failure,
      diagnostic: errorText(error),
    });
  }
}
