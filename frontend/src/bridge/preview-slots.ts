export class PreviewCapacityError extends Error {}
const abortError = () => new DOMException("Preview cancelled", "AbortError");
function check(signal: AbortSignal) {
  if (signal.aborted) throw abortError();
}
// The same bounded queue mechanism is used for preparation, receipt and explicit
// DOM decode admission; it does not claim to control browser-internal workers.
export class Slots {
  private used = 0;
  private waiting: {
    start: () => void;
    abort: () => void;
    priority: boolean;
  }[] = [];
  private readonly limit: number;
  private readonly queueLimit: number;
  constructor(limit: number, queueLimit: number) {
    this.limit = limit;
    this.queueLimit = queueLimit;
  }
  acquire(signal: AbortSignal, priority = false): Promise<() => void> {
    check(signal);
    if (this.waiting.length >= this.queueLimit)
      return Promise.reject(new PreviewCapacityError());
    return new Promise((resolve, reject) => {
      const entry = { priority, abort: () => {}, start: () => {} };
      entry.abort = () => {
        this.waiting = this.waiting.filter((item) => item !== entry);
        reject(abortError());
      };
      entry.start = () => {
        signal.removeEventListener("abort", entry.abort);
        this.used++;
        let released = false;
        resolve(() => {
          if (released) return;
          released = true;
          this.used--;
          const next = this.waiting.findIndex((item) => item.priority);
          this.waiting.splice(next < 0 ? 0 : next, 1)[0]?.start();
        });
      };
      if (this.used < this.limit) entry.start();
      else {
        this.waiting.push(entry);
        signal.addEventListener("abort", entry.abort, { once: true });
      }
    });
  }
}
