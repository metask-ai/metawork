import {
  initialViewScope,
  cloneViewScope,
  sameViewScope,
  sameViewPageScope,
  type ViewScope,
  type WorkbenchSnapshot,
} from "./contracts.ts";
import { BridgeClient } from "./client.ts";
import {
  RendererBridgeContractError,
  type RendererBridgeContractErrorCode,
} from "./contract-error.ts";

export class WorkbenchScopeSupersededError extends Error {
  constructor() {
    super("Product consumer scope changed");
    this.name = "WorkbenchScopeSupersededError";
  }
}

export type WorkbenchConnectionCallbacks = {
  onSnapshot: (snapshot: WorkbenchSnapshot, generation: string) => void;
  onStatus: (status: WorkbenchConnectionStatus) => void;
  onReady: (ready: boolean) => void;
  onViewSyncFailed: (failed: boolean) => void;
  onGeneration?: (generation: string) => void;
  onSecurityInvalidated?: (securityEpoch: string, generation: string) => void;
};

export type WorkbenchConnectionFailure =
  | "bootstrap_failed"
  | "connection_unavailable"
  | "snapshot_sync_failed"
  | "snapshot_contract_failed";

export type WorkbenchConnectionStatus =
  | { kind: "connected"; recovered: boolean }
  | { kind: "recovering" }
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

type RefreshWaiter = {
  scopeBound: boolean;
  afterAttempt: number;
  resolve: () => void;
  reject: (error: unknown) => void;
};

type ConnectionReadState = {
  generation: string;
  latest: bigint;
  requested: bigint;
  attempt: number;
  failures: number;
  fault: unknown;
  confirmed: boolean;
  timer: { id: number; retry: boolean } | null;
  waiters: Set<RefreshWaiter>;
};

const retryDelays = [100, 250, 500, 1000];

export class WorkbenchConnection {
  private scope: ViewScope = { ...initialViewScope };
  private scopeGeneration = 0;
  private state: ConnectionReadState | null = null;
  private reading: Promise<void> | null = null;
  private recovery: Promise<void> | null = null;
  private operation = 0;
  private stopped = false;
  // Until one confirmed view exists, every failure leaves nothing trustworthy to show.
  private trusted = false;
  private contractFault: RendererBridgeContractError | null = null;
  private pendingRevision = 0n;
  private securityEpoch = 0n;
  private removeWorkbench: (() => void) | null = null;
  private removeHostSignal: (() => void) | null = null;

  private readonly client: BridgeClient;
  private readonly callbacks: WorkbenchConnectionCallbacks;

  constructor(client: BridgeClient, callbacks: WorkbenchConnectionCallbacks) {
    this.client = client;
    this.callbacks = callbacks;
  }

  setScope(scope: ViewScope): Promise<void> {
    if (sameViewScope(this.scope, scope)) return Promise.resolve();
    const pageChanged = !sameViewPageScope(this.scope, scope);
    this.scope = cloneViewScope(scope);
    this.scopeGeneration++;
    if (!this.state) return Promise.resolve();
    if (pageChanged) {
      for (const waiter of this.state.waiters) {
        if (!waiter.scopeBound) continue;
        waiter.reject(new WorkbenchScopeSupersededError());
        this.state.waiters.delete(waiter);
      }
    }
    return this.refreshView(true);
  }

  async start() {
    if (this.stopped) throw new Error("Workbench connection is stopped");
    if (!this.client.available()) {
      const error = new Error("Workbench connection is unavailable");
      this.failConnection("bootstrap_failed", error);
      throw error;
    }
    this.removeWorkbench ??= this.client.onWorkbenchRevision(
      (revision, securityEpoch) => this.notify(revision, securityEpoch),
      (error) => this.failContract("revision", error),
    );
    this.removeHostSignal ??= this.client.onHostSignal(
      (signal) => {
        if (this.stopped || this.contractFault || !this.state) return;
        const state = this.state;
        const operation = this.operation;
        void this.client.acknowledgeSignal(signal.sequence).catch((error) => {
          if (operation === this.operation && state === this.state)
            this.failContract("host_signal_ack", error);
        });
      },
      (error) => this.failContract("host_signal", error),
    );
    try {
      await this.recover(false, false);
    } catch (error) {
      // Unmount during bootstrap is cleanup, not a new visible failure.
      if (!this.stopped) throw error;
    }
  }

  retry(options: { replaceConnection?: boolean } = {}) {
    return this.recover(true, options.replaceConnection ?? false);
  }

  // Command reconciliation waits for a fresh installed view of the current
  // consumer scope. Paging/navigation may replace that scope while it waits.
  refresh(): Promise<void> {
    return this.refreshView(false);
  }

  private refreshView(scopeBound: boolean): Promise<void> {
    if (this.stopped)
      return Promise.reject(new Error("Workbench connection is stopped"));
    if (this.contractFault) return Promise.reject(this.contractFault);
    const state = this.state;
    if (!state)
      return Promise.reject(new Error("Workbench connection is disconnected"));
    if (state.fault) return Promise.reject(state.fault);
    return this.requestView(state, scopeBound);
  }

  private requestView(
    state: ConnectionReadState,
    scopeBound: boolean,
  ): Promise<void> {
    const pending = new Promise<void>((resolve, reject) => {
      state.waiters.add({
        scopeBound,
        afterAttempt: state.attempt,
        resolve,
        reject,
      });
    });
    // An explicit refresh can skip notification coalescing, but shares backoff.
    if (state.timer && !state.timer.retry) this.clearTimer(state);
    this.schedule(state);
    return pending;
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    this.operation++;
    this.removeWorkbench?.();
    this.removeHostSignal?.();
    this.removeWorkbench = this.removeHostSignal = null;
    await this.disconnectCurrent(new Error("Workbench connection is stopped"));
  }

  private active(state: ConnectionReadState) {
    return (
      !this.stopped &&
      this.state === state &&
      !state.fault &&
      !this.contractFault
    );
  }

  private notify(revision: string, securityEpoch: string) {
    if (this.stopped || this.contractFault) return;
    const epoch = BigInt(securityEpoch);
    if (epoch < this.securityEpoch) return;
    if (epoch > this.securityEpoch) {
      this.securityEpoch = epoch;
      if (this.state) {
        this.state.latest = -1n;
        this.callbacks.onReady(false);
        this.callbacks.onSecurityInvalidated?.(
          String(epoch),
          this.state.generation,
        );
      }
    }
    const value = BigInt(revision);
    if (value > this.pendingRevision) this.pendingRevision = value;
    const state = this.state;
    if (!state) return;
    if (value > state.requested) state.requested = value;
    this.schedule(state, 32);
  }

  private needsRead(state: ConnectionReadState) {
    return state.waiters.size > 0 || state.requested > state.latest;
  }

  private schedule(state: ConnectionReadState, delay = 0, retry = false) {
    if (
      !this.active(state) ||
      !this.needsRead(state) ||
      state.timer ||
      this.reading
    )
      return;
    if (delay > 0) {
      state.timer = {
        retry,
        id: window.setTimeout(() => {
          state.timer = null;
          this.schedule(state);
        }, delay),
      };
      return;
    }
    // Register before any client/callback can synchronously finish or re-enter.
    const reading = Promise.resolve().then(() => this.read(state));
    this.reading = reading;
    void reading.finally(() => {
      if (this.reading !== reading) return;
      this.reading = null;
      const current = this.state;
      if (current) this.schedule(current);
    });
  }

  private async read(state: ConnectionReadState) {
    if (!this.active(state)) return;
    const target = state.requested;
    const scopeGeneration = this.scopeGeneration;
    const securityAtStart = this.securityEpoch;
    const scope = cloneViewScope(this.scope);
    const attempt = ++state.attempt;
    try {
      const next = await this.client.fetchSnapshot(scope);
      if (!this.active(state) || scopeGeneration !== this.scopeGeneration)
        return;
      {
        const epoch = BigInt(next.securityEpoch);
        if (epoch < this.securityEpoch)
          throw new Error("Host returned a revoked Product security epoch");
        if (epoch > this.securityEpoch) {
          this.securityEpoch = epoch;
          this.callbacks.onSecurityInvalidated?.(
            next.securityEpoch,
            state.generation,
          );
        }
      }
      const revision = BigInt(next.revision);
      if (revision < state.latest || revision < target)
        throw new Error("Host returned a stale Workbench revision");
      state.latest = revision;
      state.failures = 0;
      this.callbacks.onSnapshot(next, state.generation);
      if (!this.active(state) || scopeGeneration !== this.scopeGeneration)
        return;
      for (const waiter of state.waiters) {
        if (waiter.afterAttempt < attempt) {
          state.waiters.delete(waiter);
          waiter.resolve();
        }
      }
      if (state.confirmed) {
        this.callbacks.onViewSyncFailed(false);
        this.callbacks.onReady(true);
      }
    } catch (error) {
      if (
        !this.active(state) ||
        scopeGeneration !== this.scopeGeneration ||
        securityAtStart !== this.securityEpoch
      )
        return;
      this.callbacks.onReady(false);
      if (error instanceof RendererBridgeContractError) {
        this.failContract("snapshot", error);
        return;
      }
      const delay = retryDelays[state.failures++];
      if (delay === undefined) {
        state.fault = error;
        this.rejectWaiters(state, error);
        if (!this.recovery) this.failRefresh(error);
      } else {
        // Keep a demand even if a malformed/stale response had no newer notification.
        // The timer belongs to this shared retry chain, not to any single waiter.
        state.timer = {
          retry: true,
          id: window.setTimeout(() => {
            state.timer = null;
            this.schedule(state);
          }, delay),
        };
      }
    }
  }

  private recover(recovered: boolean, replace: boolean): Promise<void> {
    if (this.stopped)
      return Promise.reject(new Error("Workbench connection is stopped"));
    if (this.recovery) return this.recovery;
    const operation = ++this.operation;
    const pending = Promise.resolve().then(async () => {
      this.checkOperation(operation);
      // Startup is connecting, not recovering an existing view.
      if (recovered) this.callbacks.onStatus({ kind: "recovering" });
      this.callbacks.onReady(false);
      if (!replace && this.state && !this.contractFault) {
        const state = this.state;
        state.fault = null;
        state.failures = 0;
        try {
          await this.requestView(state, false);
          this.checkOperation(operation);
          // A retained generation is already confirmed; an unconfirmed one needs ping.
          if (!state.confirmed) await this.confirm(state, operation, recovered);
          else {
            this.callbacks.onViewSyncFailed(false);
            this.callbacks.onReady(true);
            this.callbacks.onStatus({ kind: "connected", recovered });
          }
          return;
        } catch (error) {
          this.checkOperation(operation);
          if (error instanceof RendererBridgeContractError) throw error;
        }
      }
      await this.disconnectCurrent(
        new Error("Workbench connection generation was replaced"),
      );
      this.checkOperation(operation);
      this.contractFault = null;
      let generation: string;
      this.securityEpoch = 0n;
      try {
        generation = await this.client.connect();
      } catch (error) {
        this.checkOperation(operation);
        if (error instanceof RendererBridgeContractError)
          this.failContract("bootstrap", error);
        else
          this.failConnection(
            recovered ? "connection_unavailable" : "bootstrap_failed",
            error,
          );
        throw error;
      }
      if (this.stopped || operation !== this.operation || this.contractFault) {
        await this.client.disconnect(generation).catch(() => undefined);
        this.checkOperation(operation);
        throw this.contractFault;
      }
      const state: ConnectionReadState = {
        generation,
        latest: 0n,
        requested: this.pendingRevision,
        attempt: 0,
        failures: 0,
        fault: null,
        confirmed: false,
        timer: null,
        waiters: new Set(),
      };
      this.state = state;
      this.callbacks.onGeneration?.(generation);
      try {
        await this.requestView(state, false);
        await this.confirm(state, operation, recovered);
      } catch (error) {
        if (operation !== this.operation || this.stopped) throw error;
        if (!(error instanceof RendererBridgeContractError))
          this.failConnection(
            recovered ? "connection_unavailable" : "bootstrap_failed",
            error,
          );
        await this.disconnectCurrent(error);
        throw error;
      }
    });
    this.recovery = pending;
    void pending
      .finally(() => {
        if (this.recovery === pending) this.recovery = null;
      })
      .catch(() => undefined);
    return pending;
  }

  private checkOperation(operation: number) {
    if (this.stopped) throw new Error("Workbench connection is stopped");
    if (this.operation !== operation)
      throw new Error("Workbench connection generation was replaced");
  }

  private async confirm(
    state: ConnectionReadState,
    operation: number,
    recovered: boolean,
  ) {
    try {
      await this.client.ping();
    } catch (error) {
      this.checkOperation(operation);
      if (this.state === state && error instanceof RendererBridgeContractError)
        this.failContract("bootstrap", error);
      throw error;
    }
    this.checkOperation(operation);
    if (!this.active(state))
      throw (
        this.contractFault ??
        state.fault ??
        new Error("Workbench connection generation was replaced")
      );
    state.confirmed = true;
    this.trusted = true;
    this.callbacks.onViewSyncFailed(false);
    this.callbacks.onReady(true);
    this.callbacks.onStatus({ kind: "connected", recovered });
  }

  private clearTimer(state: ConnectionReadState) {
    if (state.timer) window.clearTimeout(state.timer.id);
    state.timer = null;
  }

  private rejectWaiters(state: ConnectionReadState, error: unknown) {
    this.clearTimer(state);
    for (const waiter of state.waiters) waiter.reject(error);
    state.waiters.clear();
  }

  private async disconnectCurrent(error: unknown) {
    const state = this.state;
    if (!state) return;
    this.state = null;
    this.pendingRevision = 0n;
    this.rejectWaiters(state, error);
    this.callbacks.onGeneration?.("0");
    this.callbacks.onReady(false);
    await this.client.disconnect(state.generation).catch(() => undefined);
  }

  private failContract(
    source: Extract<
      WorkbenchConnectionStatus,
      { kind: "contract_failed" }
    >["source"],
    error: unknown,
  ) {
    if (this.stopped || this.contractFault) return;
    const fault =
      error instanceof RendererBridgeContractError
        ? error
        : new RendererBridgeContractError("invalid_response", errorText(error));
    this.contractFault = fault;
    if (this.state) {
      this.state.fault = fault;
      this.rejectWaiters(this.state, fault);
    }
    this.callbacks.onViewSyncFailed(true);
    this.callbacks.onReady(false);
    this.callbacks.onStatus({
      kind: "contract_failed",
      source,
      code: fault.code,
      diagnostic: errorText(fault),
      failure:
        source === "bootstrap" || !this.trusted
          ? "bootstrap_failed"
          : source === "snapshot"
            ? "snapshot_contract_failed"
            : "connection_unavailable",
    });
  }

  private failRefresh(error: unknown) {
    this.callbacks.onViewSyncFailed(true);
    this.callbacks.onStatus({
      kind: "refresh_failed",
      failure: "snapshot_sync_failed",
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
