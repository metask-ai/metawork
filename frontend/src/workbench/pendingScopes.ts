export class PendingScopes {
  private readonly active = new Set<string>();

  begin(scope: string) {
    if (this.active.has(scope)) return false;
    this.active.add(scope);
    return true;
  }

  has(scope: string) {
    return this.active.has(scope);
  }

  move(from: string, to: string) {
    if (!this.active.has(from)) return false;
    if (from !== to && this.active.has(to)) return false;
    this.active.delete(from);
    this.active.add(to);
    return true;
  }

  end(scope: string) {
    return this.active.delete(scope);
  }
}

export function accountMutationBlocksTaskAdmission(
  newTaskDraftActive: boolean,
  accountMutationPending: boolean,
) {
  return newTaskDraftActive && accountMutationPending;
}
