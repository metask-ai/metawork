import type { AttachmentReceiveResult } from "./contracts.ts";

type Rejected = Extract<AttachmentReceiveResult, { status: "rejected" }>;
export type ReceivePort = {
  begin(
    files: { name: string; sizeBytes: string }[],
  ): Promise<{ status: "accepted" } | Rejected>;
  append(
    fileIndex: number,
    offset: string,
    dataBase64: string,
  ): Promise<{ status: "accepted" } | Rejected>;
  finish(): Promise<AttachmentReceiveResult>;
  cancel(): Promise<unknown>;
};

export class AttachmentCleanupError extends Error {
  constructor() {
    super("Attachment cleanup could not be confirmed");
  }
}

/** One transient input operation; ready attachments are owned by the draft after handoff. */
export class AttachmentReceive {
  private state: "active" | "cancelled" | "handed_off" = "active";
  private cleanup: Promise<void> | undefined;
  private readonly abort = new AbortController();

  private readonly port: ReceivePort;
  private readonly chunkBytes: number;
  constructor(port: ReceivePort, chunkBytes: number) {
    this.port = port;
    this.chunkBytes = chunkBytes;
  }

  handoff() {
    if (this.state !== "active") return false;
    this.state = "handed_off";
    return true;
  }

  cancel(): Promise<void> {
    if (this.state === "handed_off") return Promise.resolve();
    if (this.cleanup) return this.cleanup;
    this.state = "cancelled";
    this.abort.abort();
    this.cleanup = this.port.cancel().then(
      () => {},
      () => {
        throw new AttachmentCleanupError();
      },
    );
    return this.cleanup;
  }

  private async pending<T>(work: Promise<T>): Promise<T> {
    const signal = this.abort.signal;
    if (signal.aborted) throw new Error("Attachment receive cancelled");
    let stop: () => void = () => {};
    const cancelled = new Promise<never>((_, reject) => {
      stop = () => reject(new Error("Attachment receive cancelled"));
      signal.addEventListener("abort", stop, { once: true });
    });
    try {
      return await Promise.race([work, cancelled]);
    } finally {
      signal.removeEventListener("abort", stop);
    }
  }

  async run(files: readonly File[]): Promise<AttachmentReceiveResult> {
    try {
      if (this.state !== "active") return { status: "cancelled" };
      const begin = await this.pending(
        this.port.begin(
          files.map((file) => ({
            name: file.name,
            sizeBytes: String(file.size),
          })),
        ),
      );
      if (begin.status === "rejected") {
        await this.cancel();
        return begin;
      }
      for (let fileIndex = 0; fileIndex < files.length; fileIndex++) {
        const file = files[fileIndex]!;
        for (let offset = 0; offset < file.size; offset += this.chunkBytes) {
          const bytes = new Uint8Array(
            await this.pending(
              file.slice(offset, offset + this.chunkBytes).arrayBuffer(),
            ),
          );
          if (this.abort.signal.aborted)
            throw new Error("Attachment receive cancelled");
          let binary = "";
          for (let i = 0; i < bytes.length; i += 8192)
            binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
          const appended = await this.pending(
            this.port.append(fileIndex, String(offset), btoa(binary)),
          );
          if (appended.status === "rejected") {
            await this.cancel();
            return appended;
          }
        }
      }
      if (this.abort.signal.aborted)
        throw new Error("Attachment receive cancelled");
      const result = await this.pending(this.port.finish());
      if (result.status !== "ready") await this.cancel();
      return result;
    } catch (error) {
      const wasCancelled = this.state === "cancelled";
      await this.cancel();
      if (wasCancelled) return { status: "cancelled" };
      throw error;
    }
  }
}
