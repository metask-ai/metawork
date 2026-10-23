import type { NativeSdkJson } from "@native-sdk/cli";
import type { FilePreviewImage } from "./contracts.ts";
import { commands } from "./commands.ts";
import { PreviewImagePool } from "./preview-image-pool.ts";
import {
  decodeDocumentOpen,
  decodeDocumentRead,
  decodeDocumentChunk,
  decodeDocumentClose,
  decodeDocumentReleaseRead,
  decodeDocumentInvalidated,
  type DocumentFailure,
  type DocumentOpen,
  type DocumentRegion,
  type DocumentSelection,
  type DocumentTarget,
} from "./document-contract.ts";

export type DocumentContent =
  | { state: "loading" }
  | DocumentFailure
  | { state: "ready"; kind: "page"; page: number; image: FilePreviewImage }
  | DocumentRegion;
export type DocumentSnapshot =
  | { state: "loading" }
  | DocumentFailure
  | { state: "ready"; document: DocumentOpen; content: DocumentContent };
export type DocumentPreview = {
  readonly id: string;
  getSnapshot: () => DocumentSnapshot;
  subscribe: (listener: () => void) => () => void;
  read: (selection: DocumentSelection) => Promise<void>;
  close: () => Promise<boolean>;
};
type Invoke = (
  command: string,
  payload: NativeSdkJson,
  timeoutMs: number,
) => Promise<unknown>;
type Owned = {
  invalidate: (reason: DocumentFailure["state"]) => void;
  fromHost: (token: string, reason: DocumentFailure["state"]) => void;
};

// One owner per Renderer connection. Host admission remains authoritative;
// local bounds also include closes whose physical cleanup is unconfirmed.
export class DocumentPreviewLoader {
  private readonly invoke: Invoke;
  private readonly generation: () => string | undefined;
  private readonly images: PreviewImagePool;
  private readonly now: () => number;
  private epoch: string | null = null;
  private nextId = 1n;
  private readonly owned = new Map<string, Owned>();
  constructor(
    invoke: Invoke,
    generation: () => string | undefined,
    images = new PreviewImagePool(),
    now = () => performance.now(),
  ) {
    this.invoke = invoke;
    this.generation = generation;
    this.images = images;
    this.now = now;
  }
  reset() {
    for (const value of [...this.owned.values()]) value.invalidate("cancelled");
    this.owned.clear();
    this.epoch = null;
  }
  observeSecurityEpoch(epoch: string) {
    if (this.epoch !== null && BigInt(epoch) <= BigInt(this.epoch)) return;
    const previous = this.epoch;
    this.epoch = epoch;
    this.images.observeSecurityEpoch(epoch);
    if (previous === null) return;
    for (const value of [...this.owned.values()])
      value.invalidate("stale_security");
  }
  invalidated(value: unknown) {
    const event = decodeDocumentInvalidated(value);
    if (event.generation !== this.generation()) return;
    const entry = this.owned.get(`${event.generation}:${event.previewId}`);
    entry?.fromHost(event.token, event.reason);
  }
  rejectEvents() {
    for (const value of [...this.owned.values()]) value.invalidate("error");
  }
  open(
    taskId: string,
    runId: string,
    target: DocumentTarget,
    signal?: AbortSignal,
  ): DocumentPreview {
    const generation = this.generation();
    const previewId = String(this.nextId++);
    const key = { generation: generation ?? "0", previewId };
    const identity = `${key.generation}:${previewId}`;
    let snapshot: DocumentSnapshot = { state: "loading" };
    const listeners = new Set<() => void>();
    let document: DocumentOpen | undefined;
    let earlyInvalidation:
      { token: string; reason: DocumentFailure["state"] } | undefined;
    const lifetime = new AbortController();
    let active = true,
      reading = false;
    let nextRead = 1n;
    let releaseImage: (() => void) | undefined;
    let closing: Promise<boolean> | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const openedAt = this.now();
    let idleAt = openedAt + 120000;
    const publish = (value: DocumentSnapshot) => {
      snapshot = value;
      for (const listener of listeners) listener();
    };
    const clearImage = () => {
      releaseImage?.();
      releaseImage = undefined;
    };
    const closeHost = () => {
      closing ??= Promise.resolve()
        .then(() => this.invoke(commands.closeDocument, key, 155000))
        .then((value) => {
          const result = decodeDocumentClose(value);
          if (
            result.state !== "ready" ||
            result.generation !== generation ||
            result.previewId !== previewId
          )
            return false;
          this.owned.delete(identity);
          return true;
        })
        .catch(() => false);
      return closing;
    };
    const invalidate = (reason: DocumentFailure["state"]) => {
      if (!active) return;
      active = false;
      lifetime.abort();
      if (timer !== undefined) clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      clearImage();
      document = undefined;
      publish({ state: reason });
      void closeHost().then((released) => {
        if (!released) publish({ state: "restart_required" });
      });
    };
    const abort = () => invalidate("cancelled");
    const check = (deadline = Infinity) => {
      if (!active || generation !== this.generation())
        throw Error("Document preview closed");
      if (this.now() >= Math.min(openedAt + 900000, idleAt, deadline)) {
        invalidate("expired");
        throw Error("Document preview expired");
      }
      if (
        document &&
        this.epoch !== null &&
        document.securityEpoch !== this.epoch
      ) {
        invalidate("stale_security");
        throw Error("Document preview security changed");
      }
    };
    const arm = () => {
      if (timer !== undefined) clearTimeout(timer);
      timer = setTimeout(
        () => invalidate("expired"),
        Math.max(0, Math.min(openedAt + 900000, idleAt) - this.now()),
      );
    };
    const read = async (selection: DocumentSelection) => {
      if (!active || !document || reading) return;
      const current = document;
      const readId = String(nextRead++);
      const request = {
        ...key,
        token: current.token,
        securityEpoch: current.securityEpoch,
        readId,
      };
      reading = true;
      clearImage();
      publish({
        state: "ready",
        document: current,
        content: { state: "loading" },
      });
      const sentAt = this.now();
      let held = false;
      let releaseReceipt: (() => void) | undefined;
      try {
        check();
        const response = decodeDocumentRead(
          await this.invoke(
            commands.readDocument,
            { ...request, selection },
            35000,
          ),
        );
        check();
        if (response.state !== "ready") {
          if (response.state === "busy") {
            publish({ state: "ready", document: current, content: response });
            return;
          }
          invalidate(response.state);
          return;
        }
        if (
          response.readId !== readId ||
          response.securityEpoch !== current.securityEpoch ||
          response.kind !== selection.kind
        )
          throw Error("Invalid document read identity");
        idleAt = sentAt + Number(current.idleMs);
        arm();
        if (response.kind === "region" && selection.kind === "region") {
          for (const name of [
            "sheet",
            "row",
            "column",
            "rows",
            "columns",
          ] as const)
            if (response[name] !== Number(selection[name]))
              throw Error("Invalid document region identity");
          publish({ state: "ready", document: current, content: response });
          return;
        }
        if (response.kind !== "page" || selection.kind !== "page")
          throw Error("Invalid document page");
        held = true;
        const deadline = sentAt + Number(response.transferMs);
        check(deadline);
        const descriptor = response.image;
        const reservation = this.images.reserve(
          {
            ...descriptor,
            sizeBytes: Number(descriptor.sizeBytes),
            securityEpoch: current.securityEpoch,
            id: `document:${identity}:${readId}`,
          },
          true,
        );
        releaseImage = reservation.release;
        releaseReceipt = await this.images.receive(lifetime.signal, true);
        check(deadline);
        const parts: string[] = [];
        for (let offset = 0; offset < Number(descriptor.sizeBytes);) {
          check(deadline);
          const chunk = decodeDocumentChunk(
            await this.invoke(
              commands.readDocumentChunk,
              { ...request, offset: String(offset) },
              10000,
            ),
          );
          check(deadline);
          if (chunk.state !== "ready") {
            invalidate(chunk.state);
            return;
          }
          const bytes = Math.min(
            Number(descriptor.chunkBytes),
            Number(descriptor.sizeBytes) - offset,
          );
          if (
            chunk.readId !== readId ||
            Number(chunk.offset) !== offset ||
            Number(chunk.bytes) !== bytes ||
            atob(chunk.dataBase64).length !== bytes ||
            btoa(atob(chunk.dataBase64)) !== chunk.dataBase64 ||
            (offset + bytes < Number(descriptor.sizeBytes) &&
              chunk.dataBase64.includes("="))
          )
            throw Error("Invalid document chunk identity");
          parts.push(chunk.dataBase64);
          offset += bytes;
        }
        const released = decodeDocumentReleaseRead(
          await this.invoke(commands.releaseDocumentRead, request, 10000),
        );
        held = false;
        if (released.state !== "ready" || released.readId !== readId)
          throw Error("Document page release failed");
        check(deadline);
        if (!reservation.image.valid())
          throw Error("Document image invalidated");
        reservation.setSource(`data:image/png;base64,${parts.join("")}`);
        parts.length = 0;
        publish({
          state: "ready",
          document: current,
          content: {
            state: "ready",
            kind: "page",
            page: Number(selection.page),
            image: reservation.image,
          },
        });
      } catch {
        if (active) invalidate("error");
      } finally {
        releaseReceipt?.();
        reading = false;
        // A failed transfer revokes the whole session. It never claims that an
        // outstanding read or an uncertain physical cleanup was released.
        if (held && active) invalidate("error");
      }
    };
    const handle: DocumentPreview = {
      id: identity,
      getSnapshot: () => snapshot,
      subscribe: (listener) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
      read,
      close: () => {
        invalidate("cancelled");
        return closing ?? Promise.resolve(true);
      },
    };
    if (!generation || this.owned.size >= 2 || signal?.aborted) {
      active = false;
      snapshot = {
        state: signal?.aborted
          ? "cancelled"
          : generation
            ? "busy"
            : "unavailable",
      };
      return handle;
    }
    this.owned.set(identity, {
      invalidate,
      fromHost: (token, reason) => {
        if (!document) earlyInvalidation = { token, reason };
        else if (document.token === token) invalidate(reason);
      },
    });
    signal?.addEventListener("abort", abort, { once: true });
    // Preparation has its own Host deadline. Do not apply the shorter idle
    // timer until a ready session is accepted.
    timer = setTimeout(() => invalidate("expired"), 150000);
    void (async () => {
      try {
        const response = decodeDocumentOpen(
          await this.invoke(
            commands.openDocument,
            { ...key, taskId, runId, target: { ...target } },
            155000,
          ),
        );
        if (!active) return;
        if (response.state !== "ready") {
          invalidate(response.state);
          return;
        }
        if (
          response.generation !== generation ||
          response.previewId !== previewId
        )
          throw Error("Invalid document identity");
        document = response;
        if (this.epoch === null) this.epoch = response.securityEpoch;
        if (earlyInvalidation?.token === response.token) {
          invalidate(earlyInvalidation.reason);
          return;
        }
        idleAt = openedAt + Number(response.idleMs);
        // The lifetime starts no later than this client's open send time.
        check();
        arm();
        publish({ state: "ready", document, content: { state: "loading" } });
      } catch {
        if (active) invalidate("error");
      }
    })();
    return handle;
  }
}
