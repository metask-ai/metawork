export type DeliveryBatch = { generation: string };

export type EventDeliveryOptions<T extends DeliveryBatch> = {
  connect: () => Promise<string>;
  disconnect: (generation: string) => Promise<void>;
  consume: (batch: T) => Promise<void>;
  onConnected: (generation: string, recovered: boolean) => Promise<void> | void;
  onDisconnected: () => void;
  onRecoveryFailure: (error: unknown) => void;
  retryDelaysMs?: readonly number[];
};

/** Gate 5 raw transport fixture. Product Renderer code must not import this. */
export class EventDelivery<T extends DeliveryBatch> {
  private readonly options: EventDeliveryOptions<T>;
  private generation = "0";
  private stopped = false;
  private chain: Promise<void> = Promise.resolve();

  constructor(options: EventDeliveryOptions<T>) {
    this.options = options;
  }

  async start() {
    if (this.stopped) throw new Error("Event delivery is stopped");
    await this.connect(false);
  }

  enqueue(batch: T) {
    this.chain = this.chain.then(async () => {
      if (this.stopped || batch.generation !== this.generation) return;
      try {
        await this.options.consume(batch);
      } catch (cause) {
        await this.recover(cause);
      }
    });
  }

  async idle() {
    await this.chain;
  }

  restart(cause: unknown = new Error("Event delivery restart requested")) {
    if (this.stopped)
      return Promise.reject(new Error("Event delivery is stopped"));
    this.chain = this.chain.then(() => this.recover(cause));
    return this.chain;
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    const active = this.generation;
    this.generation = "0";
    this.options.onDisconnected();
    if (active !== "0")
      await this.options.disconnect(active).catch(() => undefined);
  }

  private async recover(cause: unknown) {
    const failed = this.generation;
    this.generation = "0";
    this.options.onDisconnected();
    if (failed !== "0")
      await this.options.disconnect(failed).catch(() => undefined);
    if (this.stopped) return;
    const errors: unknown[] = [cause];
    const delays = this.options.retryDelaysMs ?? [0, 50, 200, 500, 1000];
    for (const delay of delays) {
      if (this.stopped) return;
      if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
      if (this.stopped) return;
      try {
        await this.connect(true);
        return;
      } catch (reconnectError) {
        errors.push(reconnectError);
      }
    }
    this.options.onRecoveryFailure(
      new AggregateError(
        errors,
        "Event delivery failed and the Host generation could not be reconnected",
      ),
    );
  }

  private async connect(recovered: boolean) {
    const next = await this.options.connect();
    if (this.stopped) {
      await this.options.disconnect(next).catch(() => undefined);
      return;
    }
    this.generation = next;
    try {
      await this.options.onConnected(next, recovered);
    } catch (error) {
      this.generation = "0";
      this.options.onDisconnected();
      await this.options.disconnect(next).catch(() => undefined);
      throw error;
    }
  }
}
