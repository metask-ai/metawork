import type { FilePreviewImage, PreviewMediaType } from "./contracts.ts";
import { Slots, PreviewCapacityError } from "./preview-slots.ts";

export class PreviewImageSecurityError extends Error {}

// Shared by ordinary images and document pages in this Renderer connection.
// Owns encoded bytes and explicit DOM decode admission, not browser workers.
export class PreviewImagePool {
  private readonly receipts = new Slots(1, 8);
  receive(signal: AbortSignal, priority = false) {
    return this.receipts.acquire(signal, priority);
  }
  private readonly decodes = new Slots(1, 32);
  private readonly resources = new Map<() => void, string>();
  private epoch: string | null = null;
  private bytes = 0;
  private pixels = 0;

  clear() {
    for (const release of [...this.resources.keys()]) release();
    this.epoch = null;
  }

  observeSecurityEpoch(epoch: string) {
    if (this.epoch !== null && BigInt(epoch) <= BigInt(this.epoch)) return;
    this.epoch = epoch;
    for (const [release, ownerEpoch] of [...this.resources])
      if (ownerEpoch !== epoch) release();
  }

  reserve(
    descriptor: {
      id: string;
      mediaType: PreviewMediaType;
      sizeBytes: number;
      width: number;
      height: number;
      securityEpoch: string;
    },
    priority = false,
  ) {
    this.observeSecurityEpoch(descriptor.securityEpoch);
    if (descriptor.securityEpoch !== this.epoch)
      throw new PreviewImageSecurityError();
    const pixels = descriptor.width * descriptor.height;
    if (
      this.resources.size >= 32 ||
      this.bytes + descriptor.sizeBytes > 40 * 1024 * 1024 ||
      this.pixels + pixels > 33554432
    )
      throw new PreviewCapacityError();
    this.bytes += descriptor.sizeBytes;
    this.pixels += pixels;
    let source = "",
      valid = true;
    const listeners = new Set<() => void>();
    const release = () => {
      if (!valid) return;
      valid = false;
      source = "";
      this.bytes -= descriptor.sizeBytes;
      this.pixels -= pixels;
      this.resources.delete(release);
      for (const listener of listeners) listener();
    };
    this.resources.set(release, descriptor.securityEpoch);
    const image: FilePreviewImage = {
      id: descriptor.id,
      mediaType: descriptor.mediaType,
      width: descriptor.width,
      height: descriptor.height,
      securityEpoch: descriptor.securityEpoch,
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
      beginDecode: async (signal) => {
        if (!valid) throw new DOMException("Preview cancelled", "AbortError");
        const done = await this.decodes.acquire(signal, priority);
        if (!valid) {
          done();
          throw new DOMException("Preview cancelled", "AbortError");
        }
        return done;
      },
    };
    return {
      image,
      release,
      setSource: (value: string) => {
        if (valid) source = value;
      },
    };
  }
}
