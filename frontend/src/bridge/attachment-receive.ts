import type {
  AttachmentAddResult,
  AttachmentAddBeginResult,
  AttachmentAddAcceptance,
  AttachmentCancelResult,
} from "./contracts.ts";
export type AddSource =
  | { kind: "picker" }
  | { kind: "native_paths"; paths: string[] }
  | { kind: "file_bytes"; files: readonly File[] };
export type AddWireSource =
  | { kind: "picker" }
  | { kind: "native_paths"; paths: string[] }
  | { kind: "file_bytes"; files: { name: string; sizeBytes: string }[] };
export type AddView = "adding" | "cancelling";
export type AddPort = {
  begin(source: AddWireSource): Promise<AttachmentAddBeginResult>;
  append(
    fileIndex: number,
    offset: string,
    dataBase64: string,
  ): Promise<AttachmentAddAcceptance>;
  finish(): Promise<AttachmentAddResult>;
  cancel(): Promise<AttachmentCancelResult>;
  recover(): Promise<void>;
};
export class AttachmentCleanupError extends Error {
  constructor() {
    super("Attachment cleanup could not be confirmed");
  }
}
/** One operation owns every source until a synchronous draft commit succeeds. */
export class AttachmentAddOperation {
  private state:
    "running" | "ready" | "cancel_requested" | "handed_off" | "settled" =
    "running";
  private started = false;
  private cleanup: Promise<AttachmentCancelResult> | undefined;
  private readonly abort = new AbortController();
  private view: (value: AddView) => void = () => {};
  private readonly port: AddPort;
  private readonly chunkBytes: number;
  primaryFailure: unknown;
  constructor(port: AddPort, chunkBytes: number) {
    if (
      !Number.isSafeInteger(chunkBytes) ||
      chunkBytes <= 0 ||
      chunkBytes > 128 * 1024
    )
      throw new Error("Invalid attachment chunk limit");
    this.port = port;
    this.chunkBytes = chunkBytes;
  }
  handoff(commitDraft: () => boolean): boolean {
    if (this.state !== "ready") return false;
    if (!commitDraft()) return false;
    this.state = "handed_off";
    return true;
  }
  cancel(): Promise<AttachmentCancelResult> {
    if (this.state === "handed_off")
      return Promise.resolve({ status: "cleaned", released: false });
    if (this.cleanup) return this.cleanup;
    this.state = "cancel_requested";
    this.abort.abort();
    this.view("cancelling");
    this.cleanup = this.port.cancel().then(
      (result) => {
        this.state = "settled";
        return result;
      },
      async () => {
        // A late raw response is never a substitute for timely cleanup proof.
        try {
          await this.port.recover();
        } catch {
          /* Recovery keeps its existing connection failure surface. */
        } finally {
          this.state = "settled";
        }
        throw new AttachmentCleanupError();
      },
    );
    return this.cleanup;
  }
  private async pending<T>(work: Promise<T>): Promise<T> {
    const signal = this.abort.signal;
    if (signal.aborted) throw new Error("Attachment add cancelled");
    let stop = () => {};
    const cancelled = new Promise<never>((_, reject) => {
      stop = () => reject(new Error("Attachment add cancelled"));
      signal.addEventListener("abort", stop, { once: true });
    });
    try {
      const value = await Promise.race([work, cancelled]);
      if (signal.aborted) throw new Error("Attachment add cancelled");
      return value;
    } finally {
      signal.removeEventListener("abort", stop);
    }
  }
  private async failure(
    result: AttachmentAddResult,
  ): Promise<AttachmentAddResult> {
    this.primaryFailure ??= result;
    const cleanup = await this.cancel();
    return cleanup.status === "cleanup_failed"
      ? { status: "rejected", reason: "cleanup_failed" }
      : result;
  }
  async run(
    source: AddSource,
    onViewChange: (value: AddView) => void = () => {},
  ): Promise<AttachmentAddResult> {
    if (this.started) throw new Error("Attachment operation already started");
    this.started = true;
    this.view = onViewChange;
    try {
      if (this.state !== "running")
        return this.failure({ status: "cancelled" });
      this.view("adding");
      const input: AddWireSource =
        source.kind === "file_bytes"
          ? {
              kind: "file_bytes",
              files: source.files.map((file) => ({
                name: file.name,
                sizeBytes: String(file.size),
              })),
            }
          : source;
      const begin = await this.pending(this.port.begin(input));
      if (begin.status === "ready") {
        this.state = "ready";
        return begin;
      }
      if (begin.status !== "accepted") return this.failure(begin);
      if (source.kind !== "file_bytes")
        throw new Error("Path input returned a byte writer acceptance");
      for (let fileIndex = 0; fileIndex < source.files.length; fileIndex++) {
        const file = source.files[fileIndex]!;
        for (let offset = 0; offset < file.size; offset += this.chunkBytes) {
          let bytes: Uint8Array;
          try {
            bytes = new Uint8Array(
              await this.pending(
                file.slice(offset, offset + this.chunkBytes).arrayBuffer(),
              ),
            );
          } catch (error) {
            if (this.abort.signal.aborted) throw error;
            this.primaryFailure = error;
            return this.failure({ status: "rejected", reason: "read_failed" });
          }
          if (this.abort.signal.aborted)
            throw new Error("Attachment add cancelled");
          let binary = "";
          for (let i = 0; i < bytes.length; i += 8192)
            binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
          const appended = await this.pending(
            this.port.append(fileIndex, String(offset), btoa(binary)),
          );
          if (appended.status !== "accepted") return this.failure(appended);
        }
      }
      const result = await this.pending(this.port.finish());
      if (result.status !== "ready") return this.failure(result);
      this.state = "ready";
      return result;
    } catch (error) {
      const wasCancelled = this.abort.signal.aborted;
      this.primaryFailure ??= error;
      const cleanup = await this.cancel();
      if (cleanup.status === "cleanup_failed")
        return { status: "rejected", reason: "cleanup_failed" };
      if (wasCancelled) return { status: "cancelled" };
      throw error;
    }
  }
}
