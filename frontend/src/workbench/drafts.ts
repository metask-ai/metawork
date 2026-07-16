const prefix = "metawork.task-draft.";

function storage(): Storage | null {
  if (typeof window === "undefined") return null;
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

export function readTaskDraft(sessionId: string): string {
  try {
    return storage()?.getItem(`${prefix}${sessionId}`) ?? "";
  } catch {
    return "";
  }
}

export function writeTaskDraft(sessionId: string, value: string): void {
  try {
    const target = storage();
    if (!target) return;
    if (value) target.setItem(`${prefix}${sessionId}`, value);
    else target.removeItem(`${prefix}${sessionId}`);
  } catch {
    // A local draft is helpful, but storage policy must not break the Composer.
  }
}

export function clearTaskDraft(sessionId: string): void {
  writeTaskDraft(sessionId, "");
}

export function pruneTaskDrafts(validSessionIds: ReadonlySet<string>): void {
  try {
    const target = storage();
    if (!target) return;
    const stale: string[] = [];
    for (let index = 0; index < target.length; index += 1) {
      const key = target.key(index);
      if (
        key?.startsWith(prefix) &&
        !validSessionIds.has(key.slice(prefix.length))
      )
        stale.push(key);
    }
    for (const key of stale) target.removeItem(key);
  } catch {
    // Storage cleanup follows the same fail-safe policy as draft persistence.
  }
}
