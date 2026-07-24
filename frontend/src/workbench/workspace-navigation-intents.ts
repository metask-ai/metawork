export type WorkspaceNavigationTarget =
  | { kind: "navigation"; taskId: string | null }
  | { kind: "draft"; migratableDraftId: string | null };

export type WorkspaceNavigationRequest = {
  workspaceId: string;
  workspaceEpoch: string;
  target: WorkspaceNavigationTarget;
  generation: number;
};

type WorkspaceNavigationInput = Omit<WorkspaceNavigationRequest, "generation">;

// Host selection is asynchronous, but Renderer navigation remains live. Keep
// only the newest explicit user destination while one selection is in flight.
export class WorkspaceNavigationIntents {
  private generation = 0;
  private queued: WorkspaceNavigationRequest | null = null;

  begin(input: WorkspaceNavigationInput): WorkspaceNavigationRequest {
    this.generation += 1;
    this.queued = null;
    return { ...input, generation: this.generation };
  }

  queue(input: WorkspaceNavigationInput): WorkspaceNavigationRequest {
    const request = this.begin(input);
    this.queued = request;
    return request;
  }

  isCurrent(request: WorkspaceNavigationRequest): boolean {
    return request.generation === this.generation;
  }

  invalidate(): void {
    this.generation += 1;
    this.queued = null;
  }

  takeQueued(): WorkspaceNavigationRequest | null {
    const request = this.queued;
    this.queued = null;
    return request && this.isCurrent(request) ? request : null;
  }
}
