export class RevisionNotificationQueue {
  private pending = "0";
  private timer: number | null = null;
  private readonly consume: (revision: string) => void;
  private readonly delayMs: number;

  constructor(consume: (revision: string) => void, delayMs = 32) {
    this.consume = consume;
    this.delayMs = delayMs;
  }

  push(revision: string) {
    if (BigInt(revision) > BigInt(this.pending)) this.pending = revision;
    if (this.timer !== null) return;
    this.timer = window.setTimeout(() => {
      this.timer = null;
      const target = this.pending;
      this.pending = "0";
      this.consume(target);
    }, this.delayMs);
  }

  stop() {
    if (this.timer !== null) window.clearTimeout(this.timer);
    this.timer = null;
    this.pending = "0";
  }
}
