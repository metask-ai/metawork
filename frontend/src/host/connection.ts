import type { WorkbenchSnapshot } from "./contracts.ts";
import { HostClient, type NativeBridge } from "./client.ts";
import { RevisionNotificationQueue } from "./revision-notification.ts";
import { SnapshotDemand } from "./snapshot/snapshot-demand.ts";

export type WorkbenchConnectionCallbacks = {
  onSnapshot: (snapshot: WorkbenchSnapshot) => void;
  onStatus: (status: string) => void;
  onReady: (ready: boolean) => void;
  onViewSyncFailed: (failed: boolean) => void;
};

type Gate5FixtureModule = {
  installGate5Fixture: (
    bridge: NativeBridge,
    generation: () => string,
    onFailure: (error: unknown) => void,
  ) => { emit: () => Promise<unknown>; remove: () => void };
};

export type WorkbenchConnectionOptions = {
  gate5FixtureLoader?: () => Promise<Gate5FixtureModule>;
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
  private didGate5Fixture = false;
  private removeWorkbench: (() => void) | null = null;
  private removeHostSignal: (() => void) | null = null;
  private removeFixture: (() => void) | null = null;
  private readonly revisions: RevisionNotificationQueue;
  private readonly client: HostClient;
  private readonly callbacks: WorkbenchConnectionCallbacks;
  private readonly options: WorkbenchConnectionOptions;

  constructor(
    client: HostClient,
    callbacks: WorkbenchConnectionCallbacks,
    options: WorkbenchConnectionOptions = {},
  ) {
    this.client = client;
    this.callbacks = callbacks;
    this.options = options;
    this.revisions = new RevisionNotificationQueue((revision) => {
      void this.refresh(revision).catch((error) =>
        this.callbacks.onStatus(errorText(error)),
      );
    });
  }

  async start() {
    if (!this.client.available()) return;
    this.removeWorkbench = this.client.onWorkbenchRevision(
      (revision) => this.revisions.push(revision),
      (error) => this.failNotification("Workbench revision", error),
    );
    this.removeHostSignal = this.client.onHostSignal(
      (signal) => {
        void this.client
          .acknowledgeSignal(signal.sequence)
          .catch((error) => this.failNotification("Host signal ACK", error));
      },
      (error) => this.failNotification("Host signal", error),
    );
    await this.connect();
    if (this.stopped) return;
    try {
      await this.handshake(false);
    } catch (error) {
      await this.disconnectCurrent();
      throw error;
    }
  }

  async retry() {
    if (this.stopped) throw new Error("Workbench connection is stopped");
    this.demand.resetRetry();
    this.callbacks.onViewSyncFailed(false);
    if (this.generation !== "0") {
      const stale = this.generation;
      try {
        await this.refresh();
        return;
      } catch {
        this.markDisconnected();
        await this.client.disconnect(stale).catch(() => undefined);
      }
    }
    const errors: unknown[] = [];
    for (const delay of [0, 50, 200, 500, 1000]) {
      if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
      try {
        await this.connect();
        if (this.stopped) throw new Error("Workbench connection is stopped");
        await this.handshake(true);
        return;
      } catch (error) {
        await this.disconnectCurrent();
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
            this.callbacks.onSnapshot(next);
            if (this.demand.needsRefresh())
              throw new Error(
                "Host snapshot did not reach the notified Workbench revision",
              );
            this.callbacks.onViewSyncFailed(false);
            this.callbacks.onReady(true);
          } catch (error) {
            if (this.generation !== attemptGeneration || this.stopped) return;
            this.callbacks.onReady(false);
            const delay = this.demand.failAttempt();
            if (delay === null) {
              this.callbacks.onViewSyncFailed(true);
              this.callbacks.onReady(false);
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
    this.removeFixture?.();
    this.removeWorkbench = null;
    this.removeHostSignal = null;
    this.removeFixture = null;
    const active = this.generation;
    this.markDisconnected();
    if (active !== "0")
      await this.client.disconnect(active).catch(() => undefined);
  }

  private async connect() {
    const next = await this.client.connect();
    if (this.stopped) {
      await this.client.disconnect(next).catch(() => undefined);
      return;
    }
    this.generation = next;
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
    this.demand.beginGeneration("0");
    this.callbacks.onReady(false);
  }

  private async disconnectCurrent() {
    const active = this.generation;
    this.markDisconnected();
    if (active !== "0")
      await this.client.disconnect(active).catch(() => undefined);
  }

  private async handshake(recovered: boolean) {
    if (this.stopped) return;
    const signal = await this.client.ping();
    if (this.stopped) return;
    if (signal.gate5Fixture && !this.didGate5Fixture) {
      const loader = this.options.gate5FixtureLoader;
      if (!loader)
        throw new Error(
          "Host requested the Gate 5 fixture, but this Renderer build does not package it",
        );
      const { installGate5Fixture } = await loader();
      if (this.stopped) return;
      const fixture = installGate5Fixture(
        this.client.nativeBridgeForAutomationFixture(),
        () => this.generation,
        (error) => this.failNotification("Gate 5 fixture", error),
      );
      this.removeFixture = fixture.remove;
      if (this.stopped) {
        fixture.remove();
        this.removeFixture = null;
        return;
      }
      try {
        await fixture.emit();
        if (this.stopped) return;
        this.didGate5Fixture = true;
      } catch (error) {
        fixture.remove();
        if (this.removeFixture === fixture.remove) this.removeFixture = null;
        throw error;
      }
    }
    this.callbacks.onStatus(
      recovered
        ? "Workbench connection recovered with a new Host generation."
        : "Workbench connected.",
    );
  }

  private failNotification(label: string, error: unknown) {
    if (this.stopped) return;
    this.callbacks.onViewSyncFailed(true);
    this.callbacks.onReady(false);
    this.callbacks.onStatus(`${label} contract failed: ${errorText(error)}`);
  }
}
