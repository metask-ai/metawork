// Drafts are local Composer state, never part of the Host projection.
const prefix = "metawork.task-draft.";
const newTaskPrefix = "metawork.new-task-draft.";
export const unscopedNewTaskDraftId = "unscoped";
export const maxComposerCharacters = 16 * 1024;

export function newTaskDraftStorageId(
  active: boolean,
  workspaceId: string | null,
) {
  return active ? workspaceId || unscopedNewTaskDraftId : null;
}

export function newTaskDraftMoveDecision(source: string, target: string) {
  if (!source) return "preserve_target" as const;
  if (target) return "conflict" as const;
  return "move" as const;
}

export function prepareRetryDraft(
  currentDraft: string,
  instruction: string,
): {
  draft: string;
  kind: "prepared" | "preserved" | "too_long";
} {
  if (currentDraft.trim().length > 0)
    return { draft: currentDraft, kind: "preserved" };
  if (instruction.length > maxComposerCharacters)
    return { draft: currentDraft, kind: "too_long" };
  return { draft: instruction, kind: "prepared" };
}

function storage(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function readTaskDraft(taskId: string): string {
  try {
    return storage()?.getItem(`${prefix}${taskId}`) ?? "";
  } catch {
    return "";
  }
}

export function writeTaskDraft(taskId: string, value: string): void {
  try {
    const target = storage();
    if (!target) return;
    if (value) target.setItem(`${prefix}${taskId}`, value);
    else target.removeItem(`${prefix}${taskId}`);
  } catch {
    // A local draft is helpful, but storage policy must not break the Composer.
  }
}

export function clearTaskDraft(taskId: string): void {
  writeTaskDraft(taskId, "");
}

export function readNewTaskDraft(workspaceId: string): string {
  try {
    return storage()?.getItem(`${newTaskPrefix}${workspaceId}`) ?? "";
  } catch {
    return "";
  }
}

export function writeNewTaskDraft(workspaceId: string, value: string): void {
  try {
    const target = storage();
    if (!target) return;
    if (value) target.setItem(`${newTaskPrefix}${workspaceId}`, value);
    else target.removeItem(`${newTaskPrefix}${workspaceId}`);
  } catch {
    // Draft persistence is helpful, but never a prerequisite for composing.
  }
}

export function clearNewTaskDraft(workspaceId: string): void {
  writeNewTaskDraft(workspaceId, "");
}

export function pruneTaskDrafts(validTaskIds: ReadonlySet<string>): void {
  try {
    const target = storage();
    if (!target) return;
    const stale: string[] = [];
    for (let index = 0; index < target.length; index += 1) {
      const key = target.key(index);
      if (
        key?.startsWith(prefix) &&
        !validTaskIds.has(key.slice(prefix.length))
      )
        stale.push(key);
    }
    for (const key of stale) target.removeItem(key);
  } catch {
    // Storage cleanup follows the same fail-safe policy as draft persistence.
  }
}
