import type { NativeSdkJson } from "@native-sdk/cli";
import type {
  FilePreview,
  FilePreviewImage,
  FilePreviewLoadOptions,
} from "./contracts.ts";
import { commands } from "./commands.ts";
import {
  decodeFilePreview,
  decodePreviewChunk,
  decodePreviewRelease,
} from "./decode-contracts.ts";

const abortError = () => new DOMException("Preview cancelled", "AbortError");
function check(signal: AbortSignal) {
  if (signal.aborted) throw abortError();
}
function delay(ms: number, signal: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    check(signal);
    const finish = () => {
      signal.removeEventListener("abort", abort);
      resolve();
    };
    const timer = setTimeout(finish, ms);
    const abort = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      reject(abortError());
    };
    signal.addEventListener("abort", abort, { once: true });
  });
}

// The same bounded queue mechanism is used for preparation, receipt and explicit
// DOM decode admission; it does not claim to control browser-internal workers.
class Slots {
  private used = 0;
  private waiting: {
    start: () => void;
    signal: AbortSignal;
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
      return Promise.reject(new Capacity());
    return new Promise((resolve, reject) => {
      const entry = { signal, priority, abort: () => {}, start: () => {} };
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
class Capacity extends Error {}
class StaleSecurity extends Error {}
type Invoke = (command: string, payload: NativeSdkJson) => Promise<unknown>;
const failed = (reason?: "capacity"): FilePreview => ({
  state: "error",
  content: "",
  truncated: false,
  redacted: false,
  ...(reason ? { reason } : {}),
});

export class FilePreviewLoader {
  private readonly preparations = new Slots(2, 8);
  private readonly receipts = new Slots(1, 8);
  private readonly decodes = new Slots(1, 32);
  private session = new AbortController();
  private nextId = 1n;
  private epoch: string | null = null;
  private readonly epochWaiters = new Set<() => void>();
  private readonly resources = new Set<() => void>();
  private bytes = 0;
  private pixels = 0;

  private readonly invoke: Invoke;
  private readonly generation: () => string | undefined;
  constructor(invoke: Invoke, generation: () => string | undefined) {
    this.invoke = invoke;
    this.generation = generation;
  }

  reset() {
    this.session.abort();
    this.session = new AbortController();
    this.epoch = null;
    for (const dispose of [...this.resources]) dispose();
    for (const notify of this.epochWaiters) notify();
  }
  observeSecurityEpoch(epoch: string) {
    if (this.epoch !== null && BigInt(epoch) < BigInt(this.epoch)) return;
    if (epoch === this.epoch) return;
    this.epoch = epoch;
    for (const dispose of [...this.resources]) dispose();
    for (const notify of this.epochWaiters) notify();
  }
  private waitForNewEpoch(previous: string | null, signal: AbortSignal) {
    if (this.epoch !== previous) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const finish = () => {
        this.epochWaiters.delete(notify);
        signal.removeEventListener("abort", abort);
      };
      const notify = () => {
        if (this.epoch !== previous) {
          finish();
          resolve();
        }
      };
      const abort = () => {
        finish();
        reject(abortError());
      };
      check(signal);
      this.epochWaiters.add(notify);
      signal.addEventListener("abort", abort, { once: true });
    });
  }
  async load(
    taskId: string,
    runId: string,
    fileReferenceId: string,
    options: FilePreviewLoadOptions = {},
  ): Promise<FilePreview> {
    const controller = new AbortController();
    const sessionSignal = this.session.signal;
    const abort = () => controller.abort();
    sessionSignal.addEventListener("abort", abort, { once: true });
    options.signal?.addEventListener("abort", abort, { once: true });
    if (sessionSignal.aborted || options.signal?.aborted) abort();
    const timer = setTimeout(abort, 30_000);
    const signal = controller.signal;
    const generation = this.generation();
    const priority = options.priority === "interactive";
    try {
      if (!generation) throw abortError();
      let busyCount = 0,
        securityRetry = false;
      for (;;) {
        check(signal);
        if (generation !== this.generation()) throw abortError();
        const releasePreparation = await this.preparations.acquire(
          signal,
          priority,
        );
        if (signal.aborted) {
          releasePreparation();
          check(signal);
        }
        const previewId = String(this.nextId++);
        const key = { generation, previewId };
        const observed = this.epoch;
        let released = false;
        let releasing: Promise<void> | undefined;
        let disposeReservation: (() => void) | undefined;
        const releaseHost = async () => {
          if (released) return;
          releasing ??= this.invoke(commands.releasePreview, key).then(
            (value) => {
              decodePreviewRelease(value, generation, previewId);
              released = true;
            },
          );
          return releasing;
        };
        const cancelHost = () => {
          void releaseHost().catch(() => {});
        };
        signal.addEventListener("abort", cancelHost, { once: true });
        try {
          const response = decodeFilePreview(
            await this.invoke(commands.previewFile, {
              ...key,
              taskId,
              runId,
              fileReferenceId,
            }),
          );
          releasePreparation();
          check(signal);
          if (response.state === "busy") {
            await releaseHost();
            await delay(
              Math.min(1000, 100 * 2 ** Math.min(busyCount++, 4)),
              signal,
            );
            continue;
          }
          if (response.state === "stale_security") throw new StaleSecurity();
          const descriptor = response.image;
          if (!descriptor)
            return {
              state: response.state,
              content: response.content,
              truncated: response.truncated,
              redacted: response.redacted,
              ...(response.reason ? { reason: response.reason } : {}),
            };
          if (this.epoch === null) this.epoch = descriptor.securityEpoch;
          if (this.epoch !== descriptor.securityEpoch)
            throw new StaleSecurity();
          const pixels = descriptor.width * descriptor.height;
          if (
            this.resources.size >= 32 ||
            this.bytes + descriptor.sizeBytes > 40 * 1024 * 1024 ||
            this.pixels + pixels > 33554432
          )
            throw new Capacity();
          this.bytes += descriptor.sizeBytes;
          this.pixels += pixels;
          let source = "",
            valid = true;
          const listeners = new Set<() => void>();
          const dispose = () => {
            if (!valid) return;
            valid = false;
            source = "";
            this.bytes -= descriptor.sizeBytes;
            this.pixels -= pixels;
            this.resources.delete(dispose);
            for (const changed of listeners) changed();
          };
          disposeReservation = dispose;
          this.resources.add(dispose);
          const releaseReceipt = await this.receipts.acquire(signal, priority);
          try {
            const parts: string[] = [];
            for (let offset = 0; offset < descriptor.sizeBytes;) {
              check(signal);
              if (!valid || this.epoch !== descriptor.securityEpoch)
                throw new StaleSecurity();
              const chunk = decodePreviewChunk(
                await this.invoke(commands.readPreviewImage, {
                  ...key,
                  token: descriptor.token,
                  securityEpoch: descriptor.securityEpoch,
                  offset: String(offset),
                }),
              );
              if (chunk.state === "stale_security") throw new StaleSecurity();
              if (chunk.state !== "ready")
                return {
                  ...failed(),
                  state: chunk.state === "restricted" ? "restricted" : "error",
                };
              const count = Math.min(
                descriptor.chunkBytes,
                descriptor.sizeBytes - offset,
              );
              if (
                chunk.token !== descriptor.token ||
                chunk.offset !== offset ||
                chunk.bytes !== count ||
                (count < descriptor.chunkBytes &&
                  offset + count !== descriptor.sizeBytes) ||
                (offset + count < descriptor.sizeBytes &&
                  chunk.dataBase64.includes("="))
              )
                throw Error("Invalid preview chunk identity");
              parts.push(chunk.dataBase64);
              offset += count;
            }
            await releaseHost();
            check(signal);
            if (!valid || this.epoch !== descriptor.securityEpoch)
              throw new StaleSecurity();
            source = `data:${descriptor.mediaType};base64,${parts.join("")}`;
            parts.length = 0;
          } finally {
            releaseReceipt();
          }
          const image: FilePreviewImage = {
            id: previewId,
            mediaType: descriptor.mediaType,
            width: descriptor.width,
            height: descriptor.height,
            securityEpoch: descriptor.securityEpoch,
            get src() {
              return source;
            },
            valid: () => valid,
            subscribe: (changed) => {
              listeners.add(changed);
              return () => {
                listeners.delete(changed);
              };
            },
            beginDecode: async (decodeSignal) => {
              if (!valid) throw abortError();
              const done = await this.decodes.acquire(decodeSignal, priority);
              if (!valid) {
                done();
                throw abortError();
              }
              return done;
            },
          };
          disposeReservation = undefined;
          return {
            state: "ready",
            content: "",
            truncated: false,
            redacted: false,
            image,
            release: dispose,
          };
        } catch (error) {
          if (error instanceof StaleSecurity && !securityRetry) {
            securityRetry = true;
            await releaseHost();
            await this.waitForNewEpoch(observed, signal);
            continue;
          }
          if (error instanceof Capacity) return failed("capacity");
          throw error;
        } finally {
          releasePreparation();
          disposeReservation?.();
          signal.removeEventListener("abort", cancelHost);
          if (!released) await releaseHost().catch(() => {});
        }
      }
    } catch (error) {
      if (error instanceof Capacity) return failed("capacity");
      throw error;
    } finally {
      clearTimeout(timer);
      sessionSignal.removeEventListener("abort", abort);
      options.signal?.removeEventListener("abort", abort);
    }
  }
}
