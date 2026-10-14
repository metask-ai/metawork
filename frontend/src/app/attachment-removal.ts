import type { ComposerDraft } from "../features/composer/slash.ts";

type RemovalTarget = {
  currentDraft(id: string | null): ComposerDraft | null;
  commitDraft(id: string | null, draft: ComposerDraft): boolean;
};

type RemovalRequest = {
  generation: string;
  targetId: string | null;
  token: string;
  target: RemovalTarget;
  release(token: string): Promise<{ released: boolean }>;
  recover(generation: string): Promise<void>;
  unconfirmed(): void;
};

/** Owns the release lifetime; only the synchronous start can mutate a draft. */
export class AttachmentRemovalCoordinator {
  private generation = "0";
  private active: object | null = null;
  private readonly changed: (busy: boolean) => void;

  constructor(changed: (busy: boolean) => void) {
    this.changed = changed;
  }

  get busy() {
    return this.active !== null;
  }

  resetGeneration(generation: string) {
    if (generation === this.generation) return;
    this.generation = generation;
    this.active = null;
    this.changed(false);
  }

  dispose() {
    this.generation = "0";
    this.active = null;
  }

  async remove(request: RemovalRequest): Promise<void> {
    if (this.busy || request.generation !== this.generation) return;
    const current = request.target.currentDraft(request.targetId);
    if (
      current?.kind !== "multimodal" ||
      !current.attachments.some((item) => item.token === request.token)
    )
      return;
    const attachments = current.attachments.filter(
      (item) => item.token !== request.token,
    );
    if (
      !request.target.commitDraft(
        request.targetId,
        attachments.length
          ? { ...current, attachments }
          : { kind: "text", text: current.text },
      )
    )
      return;

    const operation = {};
    this.active = operation;
    this.changed(true);
    try {
      // false is the existing idempotent release result, not a new grant.
      await request.release(request.token);
    } catch {
      if (this.active !== operation) return;
      // The public SDK does not type Host command errors. A rejected release
      // cannot prove physical cleanup, and its grant may already be revoked.
      request.unconfirmed();
      try {
        await request.recover(request.generation);
      } catch {
        // The existing connection recovery surface owns recovery failures.
      }
    } finally {
      if (this.active === operation) {
        this.active = null;
        this.changed(false);
      }
    }
  }
}
