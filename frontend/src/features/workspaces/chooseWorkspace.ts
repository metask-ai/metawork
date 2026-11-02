export type WorkspaceChoice =
  { selected: false } | { selected: true; workspaceId: string };

export type WorkspaceChoiceOutcome =
  | { kind: "cancelled" }
  | { kind: "superseded" }
  | { kind: "sync_failed" }
  | { kind: "selected"; result: Extract<WorkspaceChoice, { selected: true }> };

export async function chooseWorkspaceAndMigrateDraft({
  choose,
  refresh,
  migratableDraftId,
  moveDraft,
  current,
}: {
  choose: () => Promise<WorkspaceChoice>;
  refresh: () => Promise<void>;
  migratableDraftId: string | null;
  moveDraft: (sourceId: string, targetId: string) => unknown;
  current: () => boolean;
}): Promise<WorkspaceChoiceOutcome> {
  const result = await choose();
  if (!current()) return { kind: "superseded" };
  if (!result.selected) return { kind: "cancelled" };

  // A picker result is not an authoritative product projection. Keep the
  // source draft untouched until the Host snapshot proves the Workspace.
  try {
    await refresh();
  } catch {
    return { kind: "sync_failed" };
  }
  if (!current()) return { kind: "superseded" };
  if (migratableDraftId !== null && migratableDraftId !== result.workspaceId)
    moveDraft(migratableDraftId, result.workspaceId);

  return { kind: "selected", result };
}
