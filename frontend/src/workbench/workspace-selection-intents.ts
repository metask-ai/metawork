export type WorkspaceSelectionRequest = {
  workspaceId: string;
  workspaceEpoch: string;
  migratableDraftId: string | null;
  generation: number;
};

type WorkspaceSelectionInput = Omit<WorkspaceSelectionRequest, "generation">;

// Host selection is asynchronous. Keep only the newest explicit draft
// destination while one selection is in flight.
export class WorkspaceSelectionIntents {
  private generation = 0;
  private queued: WorkspaceSelectionRequest | null = null;

  begin(input: WorkspaceSelectionInput): WorkspaceSelectionRequest {
    this.generation += 1;
    this.queued = null;
    return { ...input, generation: this.generation };
  }

  queue(input: WorkspaceSelectionInput): WorkspaceSelectionRequest {
    const request = this.begin(input);
    this.queued = request;
    return request;
  }

  isCurrent(request: WorkspaceSelectionRequest): boolean {
    return request.generation === this.generation;
  }

  invalidate(): void {
    this.generation += 1;
    this.queued = null;
  }

  takeQueued(): WorkspaceSelectionRequest | null {
    const request = this.queued;
    this.queued = null;
    return request && this.isCurrent(request) ? request : null;
  }
}
