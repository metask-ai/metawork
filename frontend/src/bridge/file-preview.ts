import { Slots, PreviewCapacityError as Capacity } from "./preview-slots.ts";
import {
  PreviewImagePool,
  PreviewImageSecurityError as StaleSecurity,
} from "./preview-image-pool.ts";
import type { NativeSdkJson } from "@native-sdk/cli";
import { maxPreviewVideoBytes } from "./contracts.ts";
import type {
  FilePreview,
  FilePreviewLoadOptions,
  FilePreviewResponse,
  FilePreviewVideo,
  WorkspaceDirectory,
} from "./contracts.ts";
import { commands } from "./commands.ts";
import {
  decodeFilePreview,
  decodePreviewChunk,
  decodePreviewRelease,
  decodeWorkspaceDirectory,
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

type Invoke = (command: string, payload: NativeSdkJson) => Promise<unknown>;
type MediaDescriptor = NonNullable<FilePreviewResponse["video" | "image"]>;
type PreviewKey = { generation: string; previewId: string };
const failed = (reason?: "capacity"): FilePreview => ({
  state: "error",
  content: "",
  truncated: false,
  redacted: false,
  ...(reason ? { reason } : {}),
});

export class FilePreviewLoader {
  private readonly preparations = new Slots(2, 8);
  private session = new AbortController();
  private nextId = 1n;
  private epoch: string | null = null;
  private readonly epochWaiters = new Set<() => void>();

  private readonly invoke: Invoke;
  private readonly generation: () => string | undefined;
  private readonly images: PreviewImagePool;
  private readonly videos = new Map<() => void, string>();
  private videoBytes = 0;
  constructor(
    invoke: Invoke,
    generation: () => string | undefined,
    images = new PreviewImagePool(),
  ) {
    this.images = images;
    this.invoke = invoke;
    this.generation = generation;
  }

  reset() {
    this.session.abort();
    this.session = new AbortController();
    this.epoch = null;
    this.images.clear();
    for (const release of this.videos.keys()) release();
    for (const notify of this.epochWaiters) notify();
  }
  observeSecurityEpoch(epoch: string) {
    if (this.epoch !== null && BigInt(epoch) < BigInt(this.epoch)) return;
    if (epoch === this.epoch) return;
    this.epoch = epoch;
    this.images.observeSecurityEpoch(epoch);
    for (const [release, ownerEpoch] of this.videos)
      if (ownerEpoch !== epoch) release();
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
  load(
    taskId: string,
    runId: string,
    fileReferenceId: string,
    options: FilePreviewLoadOptions = {},
  ): Promise<FilePreview> {
    return this.loadTarget(taskId, { runId, fileReferenceId }, options);
  }
  loadWorkspace(
    taskId: string,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
    options: FilePreviewLoadOptions = {},
  ): Promise<FilePreview> {
    return this.loadTarget(
      taskId,
      { workspaceId, workspaceEpoch, path },
      options,
    );
  }
  async listDirectory(
    taskId: string | null,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
    options: FilePreviewLoadOptions = {},
  ): Promise<WorkspaceDirectory> {
    const controller = new AbortController();
    const session = this.session.signal;
    const abort = () => controller.abort();
    session.addEventListener("abort", abort, { once: true });
    options.signal?.addEventListener("abort", abort, { once: true });
    if (session.aborted || options.signal?.aborted) abort();
    const timer = setTimeout(abort, 30_000);
    const generation = this.generation();
    try {
      if (!generation) throw abortError();
      let busy = 0;
      for (;;) {
        check(controller.signal);
        if (generation !== this.generation()) throw abortError();
        const release = await this.preparations.acquire(
          controller.signal,
          true,
        );
        const previewId = String(this.nextId++);
        const cancel = () => {
          void this.invoke(commands.releasePreview, {
            generation,
            previewId,
          }).catch(() => {});
        };
        controller.signal.addEventListener("abort", cancel, { once: true });
        try {
          check(controller.signal);
          const result = decodeWorkspaceDirectory(
            await this.invoke(commands.listDirectory, {
              generation,
              previewId,
              taskId,
              workspaceId,
              workspaceEpoch,
              path,
            }),
          );
          check(controller.signal);
          if (result.state !== "busy") return result;
        } finally {
          release();
          controller.signal.removeEventListener("abort", cancel);
        }
        await delay(
          Math.min(1000, 100 * 2 ** Math.min(busy++, 4)),
          controller.signal,
        );
      }
    } finally {
      clearTimeout(timer);
      session.removeEventListener("abort", abort);
      options.signal?.removeEventListener("abort", abort);
    }
  }
  private async loadTarget(
    taskId: string,
    target:
      | { runId: string; fileReferenceId: string }
      | { workspaceId: string; workspaceEpoch: string; path: string },
    options: FilePreviewLoadOptions,
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
            await this.invoke(
              "runId" in target
                ? commands.previewFile
                : commands.previewWorkspaceFile,
              {
                ...key,
                taskId,
                ...target,
              },
            ),
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
          const descriptor = response.video ?? response.image;
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
          if (response.video) {
            const reservation = this.reserveVideo(
              response.video.sizeBytes,
              response.video.securityEpoch,
            );
            disposeReservation = reservation.release;
            const parts: Uint8Array<ArrayBuffer>[] = [];
            const error = await this.readMedia(
              key,
              response.video,
              signal,
              reservation.video.valid,
              (base64) => {
                const binary = atob(base64);
                const bytes = new Uint8Array(binary.length);
                for (let index = 0; index < binary.length; index++)
                  bytes[index] = binary.charCodeAt(index);
                parts.push(bytes);
              },
            );
            if (error) return { ...failed(), state: error };
            await releaseHost();
            check(signal);
            if (!reservation.video.valid()) throw new StaleSecurity();
            reservation.setSource(
              new Blob(parts, { type: response.video.mediaType }),
            );
            disposeReservation = undefined;
            return {
              state: "ready",
              content: "",
              truncated: false,
              redacted: false,
              video: reservation.video,
              release: reservation.release,
            };
          }
          const imageDescriptor = response.image!;
          const reservation = this.images.reserve(
            {
              ...imageDescriptor,
              id: `file:${generation}:${previewId}`,
            },
            priority,
          );
          const { image, release: dispose } = reservation;
          disposeReservation = dispose;
          const releaseReceipt = await this.images.receive(signal, priority);
          try {
            const parts: string[] = [];
            const error = await this.readMedia(
              key,
              imageDescriptor,
              signal,
              image.valid,
              (data) => parts.push(data),
            );
            if (error) return { ...failed(), state: error };
            await releaseHost();
            check(signal);
            if (!image.valid() || this.epoch !== descriptor.securityEpoch)
              throw new StaleSecurity();
            reservation.setSource(
              `data:${imageDescriptor.mediaType};base64,${parts.join("")}`,
            );
            parts.length = 0;
          } finally {
            releaseReceipt();
          }
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

  private async readMedia(
    key: PreviewKey,
    descriptor: MediaDescriptor,
    signal: AbortSignal,
    valid: () => boolean,
    append: (base64: string) => void,
  ): Promise<"restricted" | "error" | undefined> {
    const command =
      descriptor.mediaType === "video/mp4"
        ? commands.readPreviewVideo
        : commands.readPreviewImage;
    for (let offset = 0; offset < descriptor.sizeBytes;) {
      check(signal);
      if (!valid() || this.epoch !== descriptor.securityEpoch)
        throw new StaleSecurity();
      const chunk = decodePreviewChunk(
        await this.invoke(command, {
          ...key,
          token: descriptor.token,
          securityEpoch: descriptor.securityEpoch,
          offset: String(offset),
        }),
      );
      check(signal);
      if (chunk.state === "stale_security") throw new StaleSecurity();
      if (chunk.state !== "ready")
        return chunk.state === "restricted" ? "restricted" : "error";
      const count = Math.min(
        descriptor.chunkBytes,
        descriptor.sizeBytes - offset,
      );
      if (
        chunk.token !== descriptor.token ||
        chunk.offset !== offset ||
        chunk.bytes !== count ||
        (offset + count < descriptor.sizeBytes &&
          chunk.dataBase64.includes("="))
      )
        throw Error("Invalid preview chunk identity");
      append(chunk.dataBase64);
      offset += count;
    }
  }

  private reserveVideo(sizeBytes: number, securityEpoch: string) {
    if (
      this.videos.size >= 4 ||
      this.videoBytes + sizeBytes > maxPreviewVideoBytes
    )
      throw new Capacity();
    this.videoBytes += sizeBytes;
    let valid = true;
    let source = "";
    const listeners = new Set<() => void>();
    const release = () => {
      if (!valid) return;
      valid = false;
      this.videos.delete(release);
      this.videoBytes -= sizeBytes;
      if (source) URL.revokeObjectURL(source);
      source = "";
      for (const notify of listeners) notify();
      listeners.clear();
    };
    this.videos.set(release, securityEpoch);
    const video: FilePreviewVideo = {
      get src() {
        return source;
      },
      valid: () => valid,
      subscribe: (listener) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
    };
    return {
      video,
      release,
      setSource: (blob: Blob) => {
        if (valid) source = URL.createObjectURL(blob);
      },
    };
  }
}
